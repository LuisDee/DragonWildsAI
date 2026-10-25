"""Event broker between the body and the Controller (streamline plan step 3, R3: event hygiene).

Live bug (2026-10-25 19:21-19:25): every body event went straight to speech. During one 71 s
blocking go_to the body queued task_failed / unreachable for the go_to's own retries, an
unreachable for a DIFFERENT walk (main's hand-driven leg to the grave, 357 m away), and two
vitals_low reports. All were voiced in the same second after he had already arrived next to the
player: "higher up than I can jump", "can't find a way to you", "really thirsty", "really hungry"
(he was carrying 23 sandwiches by then).

What the broker does (pattern adapted from bubus event debouncing, "reuse or merge matching
events per work key before triggering expensive work", https://bubus.sweeting.me/features/event-debouncing,
and from game bark managers, "validate against current state, drop stale lines rather than
backlog them"; we are synchronous and poll, so it is a small class, not an async bus):

1. ``triage(events)``, per polled batch: progress and task_done/task_failed (the executor already
   got those results synchronously) are dropped; an unreachable followed by a resumed is superseded;
   repeated unreachable / vitals_low / attacked collapse to the newest per work key.
2. Movement episodes (``action_started`` / ``action_finished``, fed by the Agent for every task it
   runs): an unreachable that belongs to a move that has since ended (arrived, or failed and was
   reported by the action result) is stale.
3. ``assess(event, state)`` against FRESH state: drop (stale, said already, not worse), inform
   (record it in the digest; it isn't the brain's business: e.g. a walk somebody else started to a
   spot that isn't a player), or decide (the Controller model gets the structured event: one
   model-phrased line, or an action that fixes it).
4. ``digest()``: a few truthful lines (``body_status`` in the Controller context) in place of the raw
   event list, so the model knows what each report was about ("not about a player").

Only state changes that need a decision reach the model. Classification is by event TYPE and
structured fields only: no phrase tables (Luis, 2026-10-25).
"""
from __future__ import annotations

import math
import re
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Callable

from .interface import (PROGRESS_EVENTS, Activity, Attacked, Event, Resumed, TaskDone, TaskFailed, Unreachable,
                        VitalsLow)

MOVE_TOOLS = {"follow", "go_to", "come_to"}
# Tools that run alongside a move instead of replacing it in the body's action slot.
NON_PREEMPTING = {"cast", "say", "look", "inspect", "inventory", "remember", "set_reflex_rule", "list_rules",
                  "clear_rule", "get_state"}
BODY_SITUATIONS = (Unreachable, Resumed, VitalsLow)
HELD_TOOLS = {"follow"}  # answer at their start, then keep running in the body

ARRIVED_M = 6.0  # within this of a player = "next to him": an "I can't reach you" is stale
PLAYER_MATCH_M = 10.0  # an unreachable whose leader_pos is this close to a player is about that player
UNREACHABLE_REPEAT_S = 60.0  # same reason, new episode: not again within this
RESUMED_WINDOW_S = 300.0  # "found you" only this soon after a voiced unreachable
VITALS_REPEAT_S = 150.0  # same stat, not worse: not again within this
VITALS_RECOVERED = 5.0  # the stat rose this much since the report: fixed (he ate/drank)
VITALS_WORSE = 0.6  # at or below this fraction of the value last voiced: worse, say it again
# The body protocol's own pairing (client_bridge.VITAL_NEEDS): which consumable fixes which stat.
VITAL_NEEDS = {"hydration": "drink", "sustenance": "food"}
DIGEST_KEEP_S = 180.0
ACTIVITY_KEEP = 8  # recent_activity lines in every Controller context

# Fallback lines, used only when the model call for a situation fails (main, 2026-10-25: the model
# phrases these; templates stay as the safety net). Keyed by the body's reason code.
UNREACHABLE_LINES = {
    "leader_windstepped": "You went up higher than I can jump, maybe with Windstep? I can't follow that yet.",
    "too_high": "I can't get up there, it's too high for me. Can you come back down?",
    "gap_too_wide": "That gap is too wide for me to jump. Can you come back over?",
    "no_route": "I can't find a way to you from here. Can you come back towards me?",
    "too_far": "You're too far away for me to catch up. Can you wait for me?",
    "stuck": "I got stuck and can't get to you. Can you come and get me?",
    "leader_double_jumped": "You double-jumped up there and I can't do that yet. Can you come back down?",
    "leader_above_jump_height": "You're higher up than I can jump. Can you come back down?",
}
NEED_WORDS = {"hydration": ("thirsty", "something to drink"), "sustenance": ("hungry", "something to eat")}


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _pos(v) -> list[float] | None:
    if isinstance(v, (list, tuple)) and len(v) >= 2 and all(_num(c) is not None for c in v[:3]):
        return [float(c) for c in v[:3]]
    return None


def player_near(state: dict, pos: list[float] | None, within: float = PLAYER_MATCH_M) -> str | None:
    """The player standing within ``within`` m of ``pos`` (nearest), if any."""
    if not pos:
        return None
    best, best_d = None, within
    for p in state.get("players") or []:
        pp = _pos(p.get("position")) if isinstance(p, dict) else None
        if pp and p.get("name"):
            d = math.dist(pp[:len(pos)], pos[:len(pp)])
            if d <= best_d:
                best, best_d = str(p["name"]), d
    return best


def player_distance(state: dict, name: str | None) -> float | None:
    for p in state.get("players") or []:
        if isinstance(p, dict) and p.get("name") == name:
            d = _num(p.get("distance"))
            if d is None and _pos(p.get("position")) and _pos(state.get("position")):
                d = math.dist(_pos(p["position"]), _pos(state["position"]))
            return d
    return None


def carried_consumables(state: dict) -> dict[str, str]:
    """consumable kind -> the name of one carried item of that kind (from the body's own
    ``consumable`` field on inventory rows)."""
    out: dict[str, str] = {}
    for row in state.get("inventory_items") or []:
        if isinstance(row, dict) and row.get("consumable") and (row.get("count") or 1) > 0:
            out.setdefault(str(row["consumable"]), str(row.get("name") or row.get("item") or "?"))
    return out


def facts(state: dict) -> dict[str, Any]:
    """The structured facts a spoken line can go stale on (compared before and after a model call)."""
    if not state or state.get("unavailable"):
        return {}
    dists = [_num(p.get("distance")) for p in state.get("players") or [] if isinstance(p, dict)]
    dists = [d for d in dists if d is not None]
    out: dict[str, Any] = {"near_player": bool(dists) and min(dists) <= ARRIVED_M}
    carried = carried_consumables(state)
    for stat, need in VITAL_NEEDS.items():
        cur, mx = _num(state.get(stat)), _num(state.get(f"{stat}_max"))
        if cur is not None:
            out[f"{stat}_low"] = cur < 0.2 * (mx or 100.0)
        out[f"has_{need}"] = need in carried
    return out


def fallback_line(events: list[dict]) -> str | None:
    """The template line for a situation (model call failed, or dry run)."""
    lines, needs = [], []
    for e in events:
        if e.get("type") == "unreachable":
            r = str(e.get("reason") or "")
            if e.get("about") == "place":
                lines.append(f"I can't get there: {(e.get('detail') or r).replace('_', ' ')}.")
                continue
            line = UNREACHABLE_LINES.get(r)
            if not line and r.startswith("needs:"):
                move = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", r.split(":", 1)[1]).strip() or "a move"
                line = f"I'd need {move} to get there, and I can't do that yet."
            lines.append(line or f"I can't reach you: {e.get('detail') or r.replace('_', ' ')}.")
        elif e.get("type") == "resumed":
            lines.append("Found you.")
        elif str(e.get("type", "")).endswith("_ended"):
            lines.append(f"I've stopped following you: {str(e.get('reason') or 'it ended').replace('_', ' ')}.")
        elif e.get("type") == "vitals_low":
            needs.append(NEED_WORDS.get(str(e.get("stat")), (f"low on {e.get('stat')}", "something for it")))
    if needs:
        feel = " and ".join(f for f, _ in needs)
        want = " and ".join(w for _, w in needs)
        lines.append(f"I'm really {feel} and have nothing left. Could you bring me {want}?")
    return " ".join(lines) or None


@dataclass
class Episode:
    """One movement the brain started: follow / go_to / come_to."""
    id: int
    tool: str
    target: Any
    player: str | None  # the target, when it is a player's name
    started: float
    ended: float | None = None
    ok: bool | None = None
    reason: str | None = None
    why: str | None = None
    voiced: set = field(default_factory=set)  # unreachable reasons said in this episode

    def label(self) -> str:
        if self.player:
            return f"{self.tool} {self.player}"
        if isinstance(self.target, list):
            return f"{self.tool} [{', '.join(f'{c:.0f}' for c in self.target[:3])}]"
        return f"{self.tool} {self.target}"


@dataclass
class Verdict:
    action: str  # drop | inform | decide
    why: str
    event: dict = field(default_factory=dict)  # the structured event for the model (decide)


class EventBroker:
    def __init__(self, log=None, clock: Callable[[], float] = time.monotonic,
                 tool_of: Callable[[str], str | None] | None = None):
        self.log = log
        self.clock = clock
        self.tool_of = tool_of or (lambda _id: None)  # bridge request id -> tool (BridgeClient.sent_tool)
        self.episode: Episode | None = None
        self._episodes = 0
        self._unreachable_said: dict[str, float] = {}  # reason -> when last voiced (any episode)
        self._unreachable_open: dict | None = None  # the last voiced unreachable not yet resumed
        self._vitals_said: dict[str, tuple[float, float]] = {}  # stat -> (when, value)
        self._reports: deque[tuple[float, str]] = deque(maxlen=4)  # informational lines for the digest
        self._activity: deque[tuple[float, Activity]] = deque(maxlen=ACTIVITY_KEEP)  # episodic memory

    def _log(self, kind: str, **f) -> None:
        if self.log is not None:
            self.log.log(kind, **f)

    # ---------------------------------------------------------------- what the brain itself does

    def action_started(self, tool: str, args: dict) -> None:
        now = self.clock()
        if tool in MOVE_TOOLS:
            self._end("replaced")
            target = args.get("player") or args.get("target")
            player = target if isinstance(target, str) and not target.startswith("place:") else None
            self._episodes += 1
            self.episode = Episode(self._episodes, tool, target, player, now)
        elif tool not in NON_PREEMPTING:
            self._end("stopped" if tool == "stop" else f"replaced by {tool}")

    def action_finished(self, tool: str, args: dict, ok: bool, reason: str | None = None,
                        data: dict | None = None) -> None:
        ep = self.episode
        if tool not in MOVE_TOOLS or ep is None or ep.ended is not None:
            return
        if tool == "follow" and ok:
            return  # a follow keeps running in the body after its reply
        ep.ended, ep.ok, ep.reason = self.clock(), ok, reason
        ep.why = str((data or {}).get("why") or (data or {}).get("detail") or "") or None

    def _end(self, why: str) -> None:
        ep = self.episode
        if ep is not None and ep.ended is None:
            ep.ended, ep.ok, ep.reason = self.clock(), None, why

    # ---------------------------------------------------------------- per batch

    def triage(self, events: list[Event]) -> list[Event]:
        """In-batch hygiene: drop duplicates of synchronous results, supersede, coalesce per work key."""
        out: list[Event] = []
        for i, ev in enumerate(events):
            why = None
            if isinstance(ev, PROGRESS_EVENTS):
                why = "progress: narrated live by the progress listener"
            elif isinstance(ev, TaskFailed) and self.held(ev.task_id):
                pass  # a held action (follow) ended by itself: the executor never saw that (review H1)
            elif isinstance(ev, (TaskDone, TaskFailed)):
                why = "action result: the executor already has it (synchronous reply)"
            elif isinstance(ev, Unreachable):
                later = events[i + 1:]
                if any(isinstance(e, Resumed) for e in later):
                    why = "superseded: reachable again later in the batch"
                elif any(isinstance(e, Unreachable) for e in later):
                    why = "coalesced: a newer unreachable in the batch"
            elif isinstance(ev, VitalsLow):
                if any(isinstance(e, VitalsLow) and e.stat == ev.stat for e in events[i + 1:]):
                    why = f"coalesced: a newer {ev.stat} report in the batch"
            elif isinstance(ev, Attacked):
                if any(isinstance(e, Attacked) and e.by == ev.by for e in events[i + 1:]):
                    why = f"coalesced: a newer hit from {ev.by} in the batch"
            if why:
                self._log("event_dropped", event=ev.model_dump(), why=why)
            else:
                out.append(ev)
        return out

    # ---------------------------------------------------------------- per event, against fresh state

    def assess(self, ev: Event, state: dict) -> Verdict:
        if isinstance(ev, TaskFailed):
            v = self._held_ended(ev)
        elif isinstance(ev, Unreachable):
            v = self._unreachable(ev, state)
        elif isinstance(ev, Resumed):
            v = self._resumed(ev)
        elif isinstance(ev, VitalsLow):
            v = self._vitals(ev, state)
        else:
            v = Verdict("inform", "not a body situation")
        self._log("event_triage", event=ev.model_dump(), verdict=v.action, why=v.why)
        return v

    def _about(self, ev: Unreachable, state: dict) -> tuple[str, str | None]:
        """("player", name) | ("place", None) | ("unknown", None): what the failing move was going to."""
        ep = self.episode
        name = player_near(state, _pos(ev.leader_pos))
        if name:
            return "player", name
        if ev.mode == "follow":
            return "player", ep.player if ep and ep.player else None
        if _pos(ev.leader_pos) and state.get("players"):
            return "place", None
        return "unknown", (ep.player if ep and ep.ended is None else None)

    def _unreachable(self, ev: Unreachable, state: dict) -> Verdict:
        now = self.clock()
        about, who = self._about(ev, state)
        ep = self.episode
        dist = player_distance(state, who) if who else None
        if about == "player" and dist is not None and dist <= ARRIVED_M:
            return Verdict("drop", f"stale: next to {who} now ({dist:.1f} m)")
        if ep is not None and ep.ended is not None:
            if ep.ok:
                return Verdict("drop", f"stale: its move ({ep.label()}) arrived")
            if ep.ok is False:
                return Verdict("drop", f"its move ({ep.label()}) failed and the result was already reported")
            return Verdict("drop", f"its move ({ep.label()}) was {ep.reason or 'ended'}")
        if about == "place" and (ep is None or ep.ended is not None or ep.player):
            m = re.search(r"\bd=([\d.]+)", ev.detail or "")
            where = f"a spot {float(m.group(1)):.0f} m away" if m else "a spot"
            self._reports.append((now, f"a {ev.mode or 'move'} to {where} (not a player, not a move "
                                       f"you started) failed: {ev.reason}"))
            return Verdict("inform", "not about a player and not the brain's own move")
        ep_id = ep.id if ep and ep.ended is None else 0
        if ep_id and ev.reason in ep.voiced:
            return Verdict("drop", f"said already in this episode ({ev.reason})")
        last = self._unreachable_said.get(ev.reason)
        if last is not None and now - last < UNREACHABLE_REPEAT_S:
            return Verdict("drop", f"said {now - last:.0f}s ago ({ev.reason})")
        data = {"type": "unreachable", "reason": ev.reason, "detail": ev.detail, "about": about,
                "target": who or (ep.label() if ep else None), "mode": ev.mode,
                "distance_m": dist, "my_pos": ev.my_pos, "target_pos": ev.leader_pos}
        return Verdict("decide", "the brain's own move can't reach its target", data)

    def held(self, task_id: str) -> bool:
        """Is this the id of a held action (one that answered at its start and keeps running)?"""
        return self.tool_of(task_id) in HELD_TOOLS

    def _held_ended(self, ev: TaskFailed) -> Verdict:
        ep = self.episode
        if ep is None or ep.tool not in HELD_TOOLS or ep.ended is not None:
            return Verdict("drop", f"its {self.tool_of(ev.task_id)} was already ended by the brain")
        ep.ended, ep.ok, ep.reason = self.clock(), False, ev.reason
        return Verdict("decide", f"{ep.tool} ended by itself",
                       {"type": f"{ep.tool}_ended", "reason": ev.reason, "target": ep.player, "about": "player"})

    def _resumed(self, ev: Resumed) -> Verdict:
        open_ = self._unreachable_open
        if not open_ or self.clock() - open_["at"] > RESUMED_WINDOW_S:
            return Verdict("drop", "no recent complaint to take back")
        return Verdict("decide", "reachable again after a voiced unreachable",
                       {"type": "resumed", "target": open_.get("target"), "after": open_.get("reason")})

    def _vitals(self, ev: VitalsLow, state: dict) -> Verdict:
        now = self.clock()
        cur = _num(state.get(ev.stat)) if state else None
        if cur is not None and cur >= ev.value + VITALS_RECOVERED:
            return Verdict("drop", f"stale: {ev.stat} is {cur:g} now (was {ev.value:g})")
        need = VITAL_NEEDS.get(ev.stat)
        carried = carried_consumables(state) if state else {}
        if need and need in carried:
            return Verdict("drop", f"stale: carries {carried[need]} now (the stay-fed reflex uses it)")
        last = self._vitals_said.get(ev.stat)
        if last is not None and now - last[0] < VITALS_REPEAT_S and not ev.value <= last[1] * VITALS_WORSE:
            return Verdict("drop", f"said {now - last[0]:.0f}s ago and not worse ({ev.value:g} vs {last[1]:g})")
        value = cur if cur is not None else ev.value
        return Verdict("decide", f"{ev.stat} low and nothing to fix it carried",
                       {"type": "vitals_low", "stat": ev.stat, "value": value, "max": ev.max,
                        "fixed_by": need, "carrying_one": False})

    def voiced(self, events: list[dict]) -> None:
        """A situation's line was spoken: remember it for cooldowns and 'found you'."""
        now = self.clock()
        for e in events:
            if e.get("type") == "unreachable":
                self._unreachable_said[str(e.get("reason"))] = now
                if self.episode and self.episode.ended is None:
                    self.episode.voiced.add(e.get("reason"))
                self._unreachable_open = {"at": now, "reason": e.get("reason"), "target": e.get("target")}
            elif e.get("type") == "resumed":
                self._unreachable_open = None
                if self.episode:
                    self.episode.voiced.clear()
            elif e.get("type") == "vitals_low":
                self._vitals_said[str(e.get("stat"))] = (now, float(e.get("value") or 0))

    def still_valid(self, events: list[dict], state: dict) -> list[dict]:
        """Re-check at speak time: the situation's events that fresh state hasn't fixed meanwhile."""
        keep = []
        f = facts(state)
        for e in events:
            if e.get("type") == "unreachable" and e.get("about") == "player" and f.get("near_player"):
                continue
            if e.get("type") == "vitals_low":
                need = e.get("fixed_by")
                if (need and f.get(f"has_{need}")) or f.get(f"{e.get('stat')}_low") is False:
                    continue
            keep.append(e)
        return keep

    # ---------------------------------------------------------------- episodic memory (activity)

    def remember_activity(self, ev: Activity) -> None:
        self._activity.append((self.clock(), ev))

    @staticmethod
    def describe_activity(ev: Activity) -> str:
        """'combat_end: target=Goblin Runt, outcome=killed, damage_taken=0, loot=Bones x1 (started by debug)'.
        Generic over the fields the body sent: no per-kind phrasing (the model words it)."""
        def val(v) -> str:
            if isinstance(v, list):
                return ", ".join(val(x) for x in v[:6]) or "none"
            if isinstance(v, dict) and v.get("name"):
                return str(v["name"]) + (f" x{v['count']}" if (v.get("count") or 1) > 1 else "")
            if isinstance(v, float):
                return f"{v:g}"
            return str(v)
        bits = [f"{k}={val(v)}" for k, v in ev.fields().items()]
        return f"{ev.kind}: {'; '.join(bits)}" + (f" (started by {ev.by})" if ev.by else "")

    @staticmethod
    def notable(ev: Activity) -> bool:
        """Worth a note that outlives the session: a kill, a death or respawn, or anything with a place."""
        f = ev.fields()
        return (ev.kind in ("death", "respawned") or (ev.kind == "combat_end" and f.get("outcome") == "killed")
                or _pos(f.get("where")) is not None)

    def activity_lines(self) -> list[str]:
        now = self.clock()
        return [f"{now - t:.0f}s ago: {self.describe_activity(ev)}" for t, ev in self._activity]

    # ---------------------------------------------------------------- what the model sees

    def digest(self) -> list[str]:
        now = self.clock()
        out: list[str] = []
        ep = self.episode
        if ep is not None:
            if ep.ended is None:
                out.append(f"Moving: {ep.label()} (for {now - ep.started:.0f}s)")
            elif now - ep.ended <= DIGEST_KEEP_S:
                how = "arrived" if ep.ok else (f"failed: {ep.reason}" + (f" ({ep.why})" if ep.why else "")
                                               if ep.ok is False else ep.reason or "ended")
                out.append(f"Last move: {ep.label()} {how}, {now - ep.ended:.0f}s ago")
        if self._unreachable_open and now - self._unreachable_open["at"] <= DIGEST_KEEP_S:
            u = self._unreachable_open
            out.append(f"You told the player {now - u['at']:.0f}s ago that you can't reach "
                       f"{u.get('target') or 'the target'} ({u.get('reason')})")
        for t, line in self._reports:
            if now - t <= DIGEST_KEEP_S:
                out.append(f"Body report {now - t:.0f}s ago: {line}")
        return out[-5:]

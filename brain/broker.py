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

from . import situation as sit
from .geom import direction
from .interface import (PROGRESS_EVENTS, Activity, Attacked, Event, ItemsDropped, Reason, Resumed, TaskDone,
                        TaskFailed, Unreachable, VitalsLow)

MOVE_TOOLS = {"follow", "go_to", "come_to"}
# Tools that run alongside a move instead of replacing it in the body's action slot.
NON_PREEMPTING = {"cast", "say", "look", "inspect", "inventory", "remember", "set_reflex_rule", "list_rules",
                  "clear_rule", "get_state"}
BODY_SITUATIONS = (Unreachable, Resumed, VitalsLow, ItemsDropped)
HELD_TOOLS = {"follow"}  # answer at their start, then keep running in the body
# The result of an action the brain stopped waiting for when the player spoke (still_running) and that nobody
# re-attached to or replaced: the model hears how it ended (co-play retro 2026-11-01, root cause 2).
RUNNING_RESULT = "running_action_result"

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
MOVING_MPS = 0.3  # slower than this between two observations = standing still
# Proactive behaviour (Luis, 2026-10-25): a "situation_review" for the model on meaningful STATE
# CHANGES only. These numbers say when something changed enough to look again, never what to do.
REVIEW_BANDS = (50.0, 30.0, 15.0)  # a stat's band = how many of these % lines it is below
REVIEW_MIN_GAP_S = 180.0  # between reviews, unless something got worse than at the last review
REVIEW_SAMPLE_S = 10.0  # the Agent reads get_state this often when idle (no model call unless a change); 30 s made
#   "exhausted" news 27 s late (rung 1 rest, live 16:07Z): a player sees his HUD at once
REVIEW_QUIET_AFTER_CMD_S = 20.0  # just talked to: the conversation already covers it
REVIEW_IDLE_S = 300.0  # no command or action this long with a player close by = an idle stretch
REVIEW_NEAR_M = 15.0
REVIEW_BAG_FULL = 0.9
FIGHT_QUIET_S = 30.0  # an attack this recent = in combat: no review
BODY_AWAY_S = 5.0  # no state for this long (out of the game world: a drop, a relaunch), then state again = a change
ACTIVITY_KEEP = 8  # recent_activity lines in every Controller context
ACTIONS_KEEP = 5  # recent brain actions in body_status
FAILURES_KEEP = 2  # failures older than those 5 still shown (within DIGEST_KEEP_S), so a run of ok steps
#                    can't push the reason a thing failed out of view (live 22:19-22:20: 4 x too_far)
NEAR_PLACES = 2  # named places (game data landmarks) in the Where line, nearest first
NEAR_PLACES_M = 400.0  # farther than this is not "near"
NAMES_KEEP = 256  # id -> in-game name, from what was perceived (state, looks)
ARG_TEXT_MAX = 40  # one free-text argument in the digest; ids and names are never cut

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
# The same, for a move to a point or an actor (move.lua: "target_*" reasons; "leader_*" are players only).
PLACE_LINES = {
    "target_above_jump_height": "That spot's higher up than I can jump, so I can't get there.",
    "too_high": "That spot's too high up for me to get to.",
    "gap_too_wide": "There's a gap too wide for me to jump on the way there.",
    "no_route": "I can't find a way there from here.",
    "stuck": "I got stuck on the way there.",
    "too_far": "That's too far away for me to get to.",
}
NEED_WORDS = {"hydration": ("thirsty", "something to drink"), "sustenance": ("hungry", "something to eat")}


def human_detail(detail) -> str | None:
    """The body's detail when it is words a player can read ("blocked by walls"), not measurements
    ("dz=3.3m d=22.9m lp_fail=verify_exhausted"). Generic: no phrase list."""
    if not isinstance(detail, str):
        return None
    d = detail.strip().rstrip(".")
    return d if " " in d and "=" not in d and "_" not in d else None


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
            why = human_detail(e.get("detail"))
            if e.get("about") == "place":
                line = PLACE_LINES.get(r) or "I can't get there."
            else:
                line = UNREACHABLE_LINES.get(r)
                if not line and r.startswith("needs:"):
                    move = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", r.split(":", 1)[1]).strip() or "a move"
                    line = f"I'd need {move} to get there, and I can't do that yet."
                if not line:
                    line, why = f"I can't reach you: {why or r.replace('_', ' ')}.", None
            if why:  # the body's own words, e.g. "blocked by walls" (no_route), after the line's first sentence
                head, _, tail = line.partition(". ")
                line = f"{head.rstrip('.')} ({why}).{(' ' + tail) if tail else ''}"
            lines.append(line)
        elif e.get("type") == "resumed":
            lines.append("Found you.")
        elif e.get("type") == RUNNING_RESULT and e.get("ok") is False:  # it ran on after he spoke, then failed
            why = human_detail(e.get("detail")) or str(e.get("reason") or "it stopped").replace("_", " ")
            lines.append(f"That didn't work out: {why}.")
        elif e.get("type") == "stuck":  # must be told: the template when the model is silent or fails
            from .controller import Controller  # local import: controller imports broker indirectly
            lines.append(Controller.stuck_line(str(e.get("goal") or "the job"), e.get("failed"), e.get("reason"),
                                               e.get("question")))
        elif e.get("type") == "chain_budget":  # agent._hand_on: the request's turns ran out (model silent or failed)
            req = str(e.get("request") or "").strip()
            lines.append(f"I've stopped partway through{' ' + repr(req[:80]) if req else ' that'}: I ran out of steps "
                         "before finishing. Tell me if I should keep going.")
        elif str(e.get("type", "")).endswith("_ended"):
            lines.append(f"I've stopped following you: {str(e.get('reason') or 'it ended').replace('_', ' ')}.")
        elif e.get("type") == "vitals_low" and not e.get("carrying_one"):  # carrying one: the model's call alone
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
    end_pos: list | None = None  # where the body said it ended

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


def arg_text(args: dict, name: str | None = None) -> str:
    """An action's arguments for body_status, cut per value and never inside an id (live 22:20: the
    target id was cut at 48 characters, so it no longer matched the id in look). The target's in-game
    name goes first when known: "Water Volume (BP_WaterVolume_..._2108496385)"."""
    vals = []
    for k, v in args.items():
        if v in (None, "", [], {}) or isinstance(v, bool):
            continue
        if isinstance(v, (list, tuple)):
            text = "[" + ", ".join(f"{x:.0f}" if isinstance(x, (int, float)) else str(x) for x in v) + "]"
        else:
            text = str(v)
            if any(c.isspace() for c in text) and len(text) > ARG_TEXT_MAX:  # free text: cut; ids have no spaces
                text = text[:ARG_TEXT_MAX].rstrip() + "..."
        if k == "target" and name and name != text:
            text = f"{name} ({text})"
        vals.append(text)
    return " ".join(vals)


class EventBroker:
    def __init__(self, log=None, clock: Callable[[], float] = time.monotonic,
                 tool_of: Callable[[str], str | None] | None = None,
                 abandoned: Callable[[str], bool] | None = None,
                 late_result: Callable[[str], dict | None] | None = None):
        self.log = log
        self.clock = clock
        self.tool_of = tool_of or (lambda _id: None)  # bridge request id -> tool (BridgeClient.sent_tool)
        self.abandoned = abandoned or (lambda _id: False)  # ids the brain stopped waiting for (chat interrupt)
        self.late_result = late_result or (lambda _id: None)  # the full result of such a request (BridgeClient)
        # the action the body is still doing after the player spoke (still_running): {id, tool, args, name, started,
        # detached, progress}; None once it is watched again, replaced or reported
        self.running: dict | None = None
        self._action_at: float | None = None  # when the brain's current action started
        self._replaced: dict[str, str] = {}  # request id of a running action -> the brain tool that replaced it
        self._running_results: dict[str, dict] = {}  # request id -> its running_action_result event (assess)
        self.places = None  # brain.places.Places (LiveSession): region / province / named places for the Where line
        self.episode: Episode | None = None
        self._episodes = 0
        self._unreachable_said: dict[str, float] = {}  # reason -> when last voiced (any episode)
        self._unreachable_open: dict | None = None  # the last voiced unreachable not yet resumed
        self._vitals_said: dict[str, tuple[float, float]] = {}  # stat -> (when, value)
        self._reports: deque[tuple[float, str]] = deque(maxlen=4)  # informational lines for the digest
        self._activity: deque[tuple[float, Activity]] = deque(maxlen=ACTIVITY_KEEP)  # episodic memory
        self._progress: tuple[float, str] | None = None  # the running job's latest progress note
        self._seen: dict | None = None  # the last observed state (where am I, who is in sight)
        # brain actions: (t, tool, args, ok, reason, why, name of the target thing)
        self._actions: deque[tuple] = deque(maxlen=ACTIONS_KEEP)
        self._failures: deque[tuple] = deque(maxlen=FAILURES_KEEP)  # the same rows, failed ones only
        self._names: dict[str, str] = {}  # id -> in-game name of things perceived lately
        # situation_review bookkeeping
        self._bands: dict[str, tuple[int, float]] = {}  # stat -> (band, pct) last observed
        self._reviewed_bands: dict[str, int] = {}  # stat -> band at the last review
        self._phase: str | None = None
        self._sleep_ok: bool | None = None
        self._bag_full: bool | None = None
        self._pending: list[dict] = []  # changes since the last review
        self._away: tuple[float, str] | None = None  # (since, why): get_state has failed since then
        self._last_review: dict | None = None  # {"at", "changes", "you_said"}
        self._last_busy: float | None = None  # last command / brain action (None: since the first observation)
        self._first_seen: float | None = None
        self._idle_reported = False
        self._attacked_at: float | None = None
        self._track: deque[tuple[float, list[float]]] = deque(maxlen=8)  # (t, position) observations
        self._still_since: float | None = None

    def _log(self, kind: str, **f) -> None:
        if self.log is not None:
            self.log.log(kind, **f)

    # ---------------------------------------------------------------- what the brain itself does

    def action_started(self, tool: str, args: dict, continuing: bool = False) -> None:
        """``continuing``: the same call as the action still running since the player spoke (the executor re-attaches
        to it): the same job and movement episode go on."""
        now = self.clock()
        run = self.running
        if run is not None and continuing and run["tool"] == tool:
            self.running = None  # watched again: its result is this call's
            self._action_at = run["started"]
            return
        self._action_at = now
        if run is not None and tool not in NON_PREEMPTING:
            self.running = None  # the body's action slot takes the new one: the running action ends "interrupted"
            self._replaced[run["id"]] = tool
            while len(self._replaced) > NAMES_KEEP:
                self._replaced.pop(next(iter(self._replaced)))
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
        if reason == Reason.STILL_RUNNING and isinstance(data, dict) and data.get("id"):
            # the player spoke: the brain stopped waiting, the body goes on (no result yet, no failure)
            self.running = {"id": str(data["id"]), "tool": tool, "args": dict(args or {}),
                            "name": self.name_of((args or {}).get("target")),
                            "started": self._action_at or self.clock(), "detached": self.clock(),
                            "progress": data.get("progress") if isinstance(data.get("progress"), dict) else None}
            self._log("action_left_running", id=data["id"], tool=tool, args=args, progress=self.running["progress"])
            return
        why = (data or {}).get("detail") or (data or {}).get("why")
        self._record(tool, dict(args or {}), ok, reason, str(why) if why else None,
                     self.name_of((args or {}).get("target")) or (data or {}).get("name"))
        ep = self.episode
        if tool not in MOVE_TOOLS or ep is None or ep.ended is not None:
            return
        if tool == "follow" and ok:
            return  # a follow keeps running in the body after its reply
        ep.ended, ep.ok, ep.reason = self.clock(), ok, reason
        ep.why = str((data or {}).get("why") or (data or {}).get("detail") or "") or None
        ep.end_pos = _pos((data or {}).get("position"))

    def _record(self, tool: str, args: dict, ok: bool, reason, why, name) -> None:
        row = (self.clock(), tool, args, ok, reason, why, name if isinstance(name, str) and name else None)
        self._actions.append(row)
        if not ok:
            self._failures.append(row)

    def learn_names(self, state: dict | None = None, looks=()) -> None:
        """Remember the in-game name of every perceived thing by id (state lists and this turn's looks),
        so body_status can say WHAT an action was on, matching the ids the model sees."""
        try:
            things = sit.perceived(state or {}, looks)
        except Exception:  # perception shapes vary by body; names are a nicety, never break a turn
            return
        for t in things:
            if t.id and t.name and str(t.id) != t.name:
                self._names.pop(str(t.id), None)
                self._names[str(t.id)] = t.name
        while len(self._names) > NAMES_KEEP:
            self._names.pop(next(iter(self._names)))

    def name_of(self, target) -> str | None:
        return self._names.get(target) if isinstance(target, str) else None

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
            elif isinstance(ev, (TaskDone, TaskFailed)) and self.abandoned(ev.task_id):
                # the brain stopped waiting (the player spoke) and the body went on: this is how it really ended
                why = self._late(ev)
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
        if isinstance(ev, (TaskDone, TaskFailed)) and ev.task_id in self._running_results:
            v = Verdict("decide", "an action left running when the player spoke has ended",
                        self._running_results.pop(ev.task_id))
        elif isinstance(ev, TaskFailed):
            v = self._held_ended(ev)
        elif isinstance(ev, Unreachable):
            v = self._unreachable(ev, state)
        elif isinstance(ev, Resumed):
            v = self._resumed(ev)
        elif isinstance(ev, VitalsLow):
            v = self._vitals(ev, state)
        elif isinstance(ev, ItemsDropped):
            v = self._dropped(ev, state)
        else:
            v = Verdict("inform", "not a body situation")
        self._log("event_triage", event=ev.model_dump(), verdict=v.action, why=v.why)
        return v

    def _about(self, ev: Unreachable, state: dict) -> tuple[str, str | None]:
        """("player", name) | ("place", None) | ("unknown", None): what the failing move was going to."""
        ep = self.episode
        kind = (ev.target_kind or "").lower()
        if kind == "player" and ev.target:  # move.lua says what the move was going to (v10+)
            return "player", ev.target
        if kind in ("point", "actor", "place"):
            return "place", None
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

    def running_result(self, task_id: str) -> bool:
        """Is this event the result of an action left running when the player spoke, for the model to hear?"""
        return task_id in self._running_results

    def _late(self, ev: TaskDone | TaskFailed) -> str | None:
        """The result of an action left running when the player spoke (triage). None: keep the event (assess gives it
        to the model); otherwise why it is dropped: the brain replaced that action, or called it again (re-attached)."""
        rid = ev.task_id
        run = self.running if self.running is not None and self.running["id"] == rid else None
        replaced = self._replaced.pop(rid, None)
        if run is None:
            return (f"late result of an action you replaced with {replaced}" if replaced else
                    "late result of an action you called again (that call has the result)")
        self.running = None
        res = self.late_result(rid) or ({"ok": True, "reason": None, "data": ev.data} if isinstance(ev, TaskDone)
                                        else {"ok": False, "reason": ev.reason, "data": {}})
        ok = bool(res.get("ok"))
        data = res.get("data") if isinstance(res.get("data"), dict) else {}
        reason = None if ok else (res.get("reason") or getattr(ev, "reason", None))
        why = data.get("why") or data.get("detail")
        tool, args, now = run["tool"], run["args"], self.clock()
        self._record(tool, args, ok, reason, (f"{why}; " if why and not ok else "") + "it ran on after the player spoke",
                     run.get("name") or data.get("name"))
        ep = self.episode
        if tool in MOVE_TOOLS and ep is not None and ep.ended is None and ep.tool == tool:
            ep.ended, ep.ok, ep.reason = now, ok, reason
            ep.why = str(why) if why else None
            ep.end_pos = _pos(data.get("position"))
        target = args.get("player") or args.get("target") or args.get("resource") or args.get("item")
        event = {"type": RUNNING_RESULT, "tool": tool, "target": run.get("name") or target, "args": args, "ok": ok,
                 "reason": reason, "detail": why, "ran_s": round(now - run["started"]),
                 "note": "you stopped waiting for it when the player spoke; it kept running and has now ended"}
        self._running_results[rid] = {k: v for k, v in event.items() if v is not None and v != ""}
        return None

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
        # Carrying one is not recovering (it may be in the bag, out of the reflex's reach): only a recovered stat
        # drops a survival alarm; the model hears what he carries (2026-10-31).
        last = self._vitals_said.get(ev.stat)
        if last is not None and now - last[0] < VITALS_REPEAT_S and not ev.value <= last[1] * VITALS_WORSE:
            return Verdict("drop", f"said {now - last[0]:.0f}s ago and not worse ({ev.value:g} vs {last[1]:g})")
        value = cur if cur is not None else ev.value
        carrying = bool(need and need in carried)
        return Verdict("decide", f"{ev.stat} low" + (f", carrying {carried[need]}" if carrying else
                                                     " and nothing to fix it carried"),
                       {"type": "vitals_low", "stat": ev.stat,
                        "feels": sit.feel(ev.stat, 100.0 * value / ev.max if value is not None and ev.max else None),
                        "value": value, "max": ev.max, "fixed_by": need, "carrying_one": carrying})

    def _dropped(self, ev: ItemsDropped, state: dict) -> Verdict:
        """Someone dropped things by him: the model decides (pick up? thanks?). Stale once they are gone."""
        here = {str(i.get("id")) for i in (state.get("nearby_items") or []) if isinstance(i, dict)} if state else set()
        items = [i for i in ev.items if isinstance(i, dict) and (not here or str(i.get("id")) in here)]
        if not items:
            return Verdict("drop", "stale: the dropped items are gone (picked up already)")
        return Verdict("decide", f"{ev.by or 'a player'} dropped items nearby",
                       {"type": "items_dropped", "by": ev.by, "players": ev.players, "items": items})

    def voiced(self, events: list[dict], text: str | None = None) -> None:
        """A situation's line was spoken: remember it for cooldowns and 'found you'."""
        now = self.clock()
        for e in events:
            if e.get("type") == "situation_review" and self._last_review is not None:
                self._last_review["you_said"] = text
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
            if e.get("type") == "items_dropped" and state and not state.get("unavailable"):
                here = {str(i.get("id")) for i in state.get("nearby_items") or [] if isinstance(i, dict)}
                if not any(str(i.get("id")) in here for i in e.get("items") or []):
                    continue
            if e.get("type") == "vitals_low":  # only a stat that really recovered drops a survival alarm
                cur = _num(state.get(str(e.get("stat")))) if state else None
                was = _num(e.get("value"))
                if cur is not None and was is not None and cur >= was + VITALS_RECOVERED:
                    continue
                need = e.get("fixed_by")
                e = {**e, "carrying_one": bool(need and f.get(f"has_{need}"))}
            keep.append(e)
        return keep

    # ---------------------------------------------------------------- episodic memory (activity)

    def remember_activity(self, ev: Activity) -> None:
        self._activity.append((self.clock(), ev))

    def killed(self, target: str, extra: list[Activity] = (), within_s: float = 120.0) -> str | None:
        """A target that is gone because a fight killed it, in words, from the kill the body reported (its own
        combat_end, outcome killed: by id, else by name): "That Giant Rat is dead: your combat reflex killed it 11 s
        ago." None when no such kill is known (live 20:09Z ClaudeQ4: go_to <rat id> said only target_not_visible)."""
        t = str(target or "").strip().lower()
        now = time.time()
        best = None
        for ev in [e for _, e in self._activity] + list(extra):
            f = ev.fields()
            if ev.kind != "combat_end" or f.get("outcome") != "killed":
                continue
            by_id = str(f.get("target_id") or "").lower() == t
            if not (by_id or str(f.get("target") or "").lower() == t):
                continue
            ago = now - float(ev.ts) if ev.ts else None
            if ago is not None and ago > within_s:
                continue
            if best is None or (by_id, -(ago or 0)) > (best[0], -(best[1] or 0)):  # the id's own kill, else the latest
                best = (by_id, ago, f.get("target") or target, ev.by)
        if best is None:
            return None
        by_id, ago, name, by = best
        who = {"reflex": "your combat reflex", "brain": "you"}.get(by or "", f"a fight started by {by or 'someone'}")
        when = f" {ago:.0f} s ago" if ago is not None else ""
        return (f"That {name} is dead: {who} killed it{when}." if by_id
                else f"A {name} is dead: {who} killed one{when}.")

    def busy_with(self, within_s: float = 20.0) -> dict | None:
        """Who else had the body just now, from the activity the body reported (a reflex drinking, eating,
        fleeing): for a busy result that doesn't name its owner. {by, name, what}; None when nothing recent."""
        now = self.clock()
        for t, ev in reversed(self._activity):
            if now - t > within_s:
                break
            if ev.by and ev.by != "brain":
                name = ev.fields().get("name")
                return {"by": ev.by, "name": name if isinstance(name, str) else None,
                        "what": f"{self.describe_activity(ev)}, {now - t:.0f}s ago"}
        return None

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
                return f"{round(v, 1):g}"
            return str(v)
        f = ev.fields()
        # an item id beside its in-game name is noise for the model (prompt diet 2026-10-31)
        bits = [f"{k}={val(v)}" for k, v in f.items() if not (k == "item" and f.get("name"))]
        return f"{ev.kind}: {'; '.join(bits)}" + (f" (started by {ev.by})" if ev.by else "")

    @staticmethod
    def notable(ev: Activity) -> bool:
        """Worth a note that outlives the session: a kill, a death or respawn, or anything with a place."""
        f = ev.fields()
        return (ev.kind in ("death", "respawned") or (ev.kind == "combat_end" and f.get("outcome") == "killed")
                or _pos(f.get("where")) is not None)

    def note_progress(self, text: str) -> None:
        self._progress = (self.clock(), text)

    def activity_lines(self) -> list[str]:
        """Oldest first; repeats of one thing (same kind, name, reason, outcome: the reflex holding back the same
        drink every minute) are one line, the newest, with how many times (prompt diet 2026-10-31)."""
        now = self.clock()
        rows: dict[tuple, list] = {}
        for t, ev in reversed(self._activity):
            f = ev.fields()
            key = (ev.kind, ev.by, str(f.get("name")), str(f.get("reason")), str(f.get("ok")), str(f.get("outcome")))
            if key in rows:
                rows[key][2] += 1
            else:
                rows[key] = [t, ev, 1]
        out = sorted(rows.values(), key=lambda r: r[0])
        return [f"{now - t:.0f}s ago: {self.describe_activity(ev)}" + (f" (x{n} lately)" if n > 1 else "")
                for t, ev, n in out]

    # ---------------------------------------------------------------- where am I (live 20:26:20)

    def observe(self, state: dict) -> None:
        """Every fresh get_state the brain reads: position track (moving or standing still) and who is
        in sight. Live 20:26:20: "I'm right behind you" while 1.8 km away and stopped, because the
        context said "following Zezima" and nothing about distance or motion."""
        if not state or state.get("unavailable"):
            return
        now, pos = self.clock(), _pos(state.get("position"))
        if self._away is not None:
            # Out of the game world and in it again (chain 20261116-201438: Epic's lobby dropped the client mid-gather,
            # the request's run ended on body_restarted, he was back 40 s later and stood 233 s until thirst woke a
            # review). The change goes to the model like any other; what to do about it is the model's.
            since, why = self._away
            self._away = None
            if now - since >= BODY_AWAY_S:
                self._change({"what": "body", "now": "back in the game world", "away_s": round(now - since),
                              "was": f"out of the game world ({why})"})
                self._still_since = None
                self._track.clear()  # where he stood before is no measure of how he moves now
        self._seen = state
        self.learn_names(state)
        if self._first_seen is None:
            self._first_seen = now
        self._watch(state)
        if pos is None:
            return
        if self._track:
            t0, p0 = self._track[-1]
            moved = math.dist(p0, pos) / max(now - t0, 1e-6) >= MOVING_MPS if now > t0 else False
            if moved:
                self._still_since = None
            elif self._still_since is None:
                self._still_since = t0
        self._track.append((now, pos))

    # ---------------------------------------------------------------- situation_review (proactive)

    @staticmethod
    def stats(state: dict) -> dict[str, float]:
        """Every survival stat the body reports, plus health, as % of max (generic: whatever it sends)."""
        out: dict[str, float] = {}
        surv = state.get("survival") if isinstance(state.get("survival"), dict) else {}
        for name, v in surv.items():
            if isinstance(v, (list, tuple)) and len(v) >= 2 and _num(v[0]) is not None and _num(v[1]):
                out[str(name)] = 100.0 * float(v[0]) / float(v[1])
        hp, mx = _num(state.get("health")), _num(state.get("max_health"))
        if hp is not None and mx:
            out["health"] = 100.0 * hp / mx
        return out

    @staticmethod
    def band(pct: float, name: str = "") -> int:
        # food and drink: the stay-fed reflex eats/drinks below 40 %, so 50 % is no news (passes audit: 25 of 40
        # silent reviews were "a bit thirsty")
        cuts = REVIEW_BANDS[1:] if name in VITAL_NEEDS else REVIEW_BANDS
        return sum(1 for cut in cuts if pct < cut)

    def _still_true(self, change: dict) -> dict | None:
        """A stat change waits while he is busy or fighting: re-read it against the current state before it goes out.
        Back up to (or above) the band of the last review: dropped; still down: the current level, in words and %
        (live 2026-11-01 23:39:48: "health now dying, 100 -> 0", pending since his death at 23:35:47, while he read
        64-76 HP)."""
        if change.get("direction") != "down" or change.get("what") not in self._bands:
            return change
        b, pct = self._bands[change["what"]]
        if b <= self._reviewed_bands.get(change["what"], 0):
            self._log("situation_change_stale", change=change, now_pct=round(pct))
            return None
        if round(pct) != change.get("to_pct"):
            return {**change, "now": sit.feel(change["what"], pct), "to_pct": round(pct)}
        return change

    def _change(self, change: dict) -> None:
        self._pending = [c for c in self._pending if c.get("what") != change.get("what")] + [change]

    def _watch(self, state: dict) -> None:
        for name, pct in self.stats(state).items():
            b = self.band(pct, name)
            prev = self._bands.get(name)
            self._bands[name] = (b, pct)
            if prev is not None and b > prev[0]:  # crossed a line downwards
                self._change({"what": name, "now": sit.feel(name, pct), "from_pct": round(prev[1]), "to_pct": round(pct),
                              "direction": "down"})  # "now": the words to relay; the numbers are for decisions
        tod = state.get("time_of_day") if isinstance(state.get("time_of_day"), dict) else None
        if tod:
            phase = tod.get("phase") or (("night" if tod.get("is_night") else "day") if "is_night" in tod else None)
            if phase and self._phase and phase != self._phase:
                self._change({"what": "time_of_day", "from": self._phase, "to": phase, "hour": tod.get("hour")})
            self._phase = phase or self._phase
            ok = tod.get("sleep_allowed")
            if isinstance(ok, bool):
                if ok and self._sleep_ok is False:
                    self._change({"what": "sleep_allowed", "to": True})
                self._sleep_ok = ok
        bag = state.get("bag") if isinstance(state.get("bag"), dict) else None
        if bag and _num(bag.get("used")) is not None and _num(bag.get("capacity")):
            full = float(bag["used"]) / float(bag["capacity"]) >= REVIEW_BAG_FULL
            if full and self._bag_full is False:
                self._change({"what": "bag", "used": bag["used"], "capacity": bag["capacity"]})
            self._bag_full = full

    def note_unavailable(self, why: str) -> None:
        """A get_state that failed, after the body had been seen in the world: he may be out of it (observe tells the
        model when he is back)."""
        if self._away is None and self._seen:
            self._away = (self.clock(), str(why))

    def note_busy(self) -> None:
        """A command arrived or the brain ran an action: not idle, and the conversation covers it."""
        self._last_busy = self.clock()
        self._idle_reported = False

    def note_attacked(self) -> None:
        self._attacked_at = self.clock()

    def review_due(self, busy: bool = False) -> dict | None:
        """A situation_review event when something meaningful changed and now is a fine moment, else None.
        Never a rule about what to do: the model gets the changes, the facts and its previous review."""
        now, st = self.clock(), self._seen or {}
        if not st:
            return None
        in_fight = bool(st.get("fight")) or (self._attacked_at is not None and now - self._attacked_at < FIGHT_QUIET_S)
        last_busy = self._last_busy if self._last_busy is not None else (self._first_seen or now)
        if busy or in_fight or (self._last_busy is not None and now - last_busy < REVIEW_QUIET_AFTER_CMD_S):
            return None
        near = [p for p in st.get("players") or [] if isinstance(p, dict)
                and (_num(p.get("distance")) or 1e9) <= REVIEW_NEAR_M]
        if near and not self._idle_reported and now - last_busy >= REVIEW_IDLE_S:
            self._idle_reported = True
            self._change({"what": "idle", "for_s": round(now - last_busy),
                          "near": [str(p.get("name")) for p in near]})
        self._pending = [c for c in (self._still_true(c) for c in self._pending) if c]
        if not self._pending:
            return None
        worse = any(c.get("direction") == "down" and self._bands.get(c["what"], (0, 0))[0] >
                    self._reviewed_bands.get(c["what"], 0) for c in self._pending)
        # day/night is time-critical (L10: he stayed in bed after day): no gap. The sleep window opening is not.
        # ...and so is being back in the world after a drop: what he was doing was cut off
        worse = worse or any(c.get("what") in ("time_of_day", "body") for c in self._pending)
        last = self._last_review
        if last and now - last["at"] < REVIEW_MIN_GAP_S and not worse:
            return None
        changes, self._pending = self._pending, []
        self._reviewed_bands = {k: b for k, (b, _) in self._bands.items()}
        ev = {"type": "situation_review", "changes": changes,
              "stats_pct": {k: round(p) for k, (_, p) in self._bands.items()},
              "time_of_day": st.get("time_of_day"), "bag": st.get("bag"),
              "players_near": [str(p.get("name")) for p in near]}
        if last:
            ev["previous_review"] = {"ago_s": round(now - last["at"]), "changes": last["changes"],
                                     "you_said": last.get("you_said")}
        self._last_review = {"at": now, "changes": changes, "you_said": None}
        self._log("situation_review", changes=changes, worse=worse)
        return ev

    def where_line(self) -> str | None:
        st = self._seen
        if not st:
            return None
        now = self.clock()
        bits = []
        if len(self._track) >= 2:
            (t0, p0), (t1, p1) = self._track[-2], self._track[-1]
            speed = math.dist(p0, p1) / max(t1 - t0, 1e-6)
            if self._still_since is not None:
                bits.append(f"you are standing still (for {now - self._still_since:.0f}s)")
            elif speed >= MOVING_MPS:
                bits.append(f"you are moving at {speed:.1f} m/s")
        if st.get("following"):
            bits.append(f"your body is set to follow {st['following']}")
        me = _pos(st.get("position"))
        bits = self._location(me) + bits
        seen = {}
        for p in st.get("players") or []:
            if isinstance(p, dict) and p.get("name"):
                d = _num(p.get("distance"))
                pp = _pos(p.get("position"))
                dz = (pp[2] - me[2]) if pp and me and len(pp) > 2 and len(me) > 2 else None
                h = f", {abs(dz):.0f} m {'higher' if dz > 0 else 'lower'}" if dz is not None and abs(dz) >= 2 else ""
                seen[str(p["name"])] = f"{p['name']} is {d:.0f} m away{h}" if d is not None else f"{p['name']} is in sight"
        bits += list(seen.values())
        wanted = [n for n in (st.get("following"), self.episode.player if self.episode else None) if n]
        for n in dict.fromkeys(wanted):
            if n not in seen:
                bits.append(f"{n} is NOT in sight (farther than you can see, distance unknown)")
        bits += self._target_bit(me)
        return ("Where: " + "; ".join(bits)) if bits else None

    def _location(self, me) -> list[str]:
        """'in <region> (<province>)' and the nearest named places with distance and compass direction, from the
        game's map data (brain.places): what a player reads off his map."""
        if me is None or self.places is None:
            return []
        out = []
        r = self.places.region_at(me)
        if r is not None:
            out.append(f"in {r['name']}" + (f" ({r['province']})" if r.get("province") else ""))
        near: dict[str, tuple[float, list[float]]] = {}
        for name, rows in self.places.landmarks.items():
            for row in rows:
                p = _pos(row.get("position"))
                d = math.dist(me[:2], p[:2]) if p else None
                if d is not None and d <= NEAR_PLACES_M and d < near.get(name, (1e12,))[0]:
                    near[name] = (d, p)
        if near:
            rows = sorted(near.items(), key=lambda kv: kv[1][0])[:NEAR_PLACES]
            out.append("near " + ", ".join(f"{n} {d:.0f} m {direction(me, p)}" if d >= 3 else f"{n} (here)"
                                          for n, (d, p) in rows))
        return out

    def _target_bit(self, me) -> list[str]:
        """The running go_to's point, from where you stand: how far, which way and how much higher or lower."""
        ep = self.episode
        t = _pos(ep.target) if ep is not None and ep.ended is None and isinstance(ep.target, list) else None
        if me is None or t is None:
            return []
        d = math.dist(me[:2], t[:2])
        dz = t[2] - me[2] if len(t) > 2 and len(me) > 2 else None
        h = f", {abs(dz):.0f} m {'higher' if dz > 0 else 'lower'}" if dz is not None and abs(dz) >= 2 else ""
        return [f"your go_to point is {d:.0f} m {direction(me, t)}{h}" if d >= 3 else f"your go_to point is here{h}"]

    # ---------------------------------------------------------------- what the model sees

    def _running_line(self, run: dict, now: float) -> str:
        """The action the body is still doing after the player spoke: what, for how long, how far to go."""
        bits = [f"for {now - run['started']:.0f}s"]
        prog = run.get("progress") or {}
        tp = _pos(prog.get("target_pos"))
        me = self._track[-1][1] if self._track else None
        if tp and me:  # from where you are now
            bits.append(f"about {math.dist(me[:2], tp[:2]):.0f} m to go")
        elif _num(prog.get("dist_m")) is not None:
            bits.append(f"{prog['dist_m']:.0f} m to go {now - run['detached']:.0f}s ago")
        if prog.get("verdict") not in (None, "ok"):
            bits.append(f"progress {prog['verdict']}" + (f": {prog['why']}" if prog.get("why") else ""))
        st = self._seen or {}
        if "action" in st and not st.get("action") and self._track and self._track[-1][0] > run["detached"]:
            bits.append("your body reports no action now: it may have just ended")
        return (f"Still running in your body: {run['tool']} {arg_text(run['args'], run.get('name'))} "
                f"({'; '.join(bits)}). You stopped waiting for it when the player spoke; it goes on. The same call "
                "again keeps it going without restarting it; another action replaces it.")

    def digest(self) -> list[str]:
        now = self.clock()
        out: list[str] = []
        if where := self.where_line():
            out.append(where)
        if self._progress and now - self._progress[0] <= DIGEST_KEEP_S:
            out.append(f"Job progress {now - self._progress[0]:.0f}s ago: {self._progress[1]}")
        ep = self.episode
        run = self.running
        if run is not None:
            out.append(self._running_line(run, now))
        if ep is not None:
            if ep.ended is None:
                if run is None or run["tool"] != ep.tool:
                    out.append(f"Moving: {ep.label()} (for {now - ep.started:.0f}s)")
            elif now - ep.ended <= DIGEST_KEEP_S:
                how = "arrived" if ep.ok else (f"failed: {ep.reason}" + (f" ({ep.why})" if ep.why else "")
                                               if ep.ok is False else ep.reason or "ended")
                here = self._track[-1][1] if self._track else None
                gone = math.dist(here[:2], ep.end_pos[:2]) if here and ep.end_pos else 0.0
                # moved since without walking (a teleport, a respawn, the dev harness): that arrival no longer
                # says where you are (chat run 5: "I'm at the lodestone now" 222 m off after a harness move)
                out.append(f"Last move: {ep.label()} {how}, {now - ep.ended:.0f}s ago"
                           + (f"; you are now {gone:.0f} m from where it ended" if gone > 15 else ""))
        if self._unreachable_open and now - self._unreachable_open["at"] <= DIGEST_KEEP_S:
            u = self._unreachable_open
            out.append(f"You told the player {now - u['at']:.0f}s ago that you can't reach "
                       f"{u.get('target') or 'the target'} ({u.get('reason')})")
        for t, line in self._reports:
            if now - t <= DIGEST_KEEP_S:
                out.append(f"Body report {now - t:.0f}s ago: {line}")
        recent = [r for r in self._actions if now - r[0] <= DIGEST_KEEP_S]
        older = [r for r in self._failures if now - r[0] <= DIGEST_KEEP_S and r not in recent]
        if recent or older:  # live 21:43: "what are you working on?" must be answered from what really happened

            def line(row) -> str:
                t, tool, args, ok, reason, why, name = row
                return (f"{tool} {arg_text(args, name)}".strip()
                        + (" ok" if ok else f" FAILED: {reason}" + (f" ({why})" if why else "")) + f", {now - t:.0f}s ago")
            if older:  # a failure the newer steps would have pushed out: still in view while it is recent
                out.append("Earlier failed actions: " + "; ".join(line(r) for r in older))
            if recent:
                out.append("Your recent actions (oldest first): " + "; ".join(line(r) for r in recent))
        return out[:8]

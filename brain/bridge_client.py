"""GameInterface over the bridge (file JSONL now, sockets later via Transport).

Each action sends ``{"type": "cmd", "id", "tool", "args"}`` and blocks until a
``result`` with the same id arrives or the per-tool timeout expires. Events that
arrive meanwhile are buffered for ``poll_events``; progress events are also handed
to the progress listener at once, so the brain can speak a progress line while a
long action (gather) is still running. Requests are re-entrant: a ``say`` sent from
the listener may read the long action's result off the wire, so results for any
in-flight id are parked until their own request picks them up. See BRIDGE_PROTOCOL.md.
"""
from __future__ import annotations

import time
import uuid
from typing import Callable

from pydantic import ValidationError

from . import protocol
from .interface import (EVENT_TYPES, PROGRESS_EVENTS, ActionResult, Coords, Event, GameInterface, Reason, fail,
                        from_wire, parse_event)
from .jsonl_log import JsonlLogger
from .transport import Transport


def _drop_none(v):
    """Remove None values recursively (optional args are simply absent on the wire)."""
    if isinstance(v, dict):
        return {k: _drop_none(x) for k, x in v.items() if x is not None}
    if isinstance(v, list):
        return [_drop_none(x) for x in v]
    return v


# Long actions need longer timeouts. Seconds of wall-clock time.
DEFAULT_TIMEOUTS = {"gather": 1800.0,  # body/gather.lua caps itself at 1700 s
                    "craft": 60.0, "attack": 140.0, "go_to": 300.0, "place": 60.0,  # go_to: may wait for a lead out (client)
                    "pickup": 120.0, "give": 70.0,  # the body's give walks to the player first
                    "interact": 120.0, "look": 15.0,  # interact walks there; look converts foliage first
                    "travel": 300.0}  # body/travel.lua caps itself at 280 s


WATCH_AFTER_S = 5.0  # waits longer than this are watched: addressed chat, bridge heartbeat (L2)
HEARTBEAT_S = 10.0  # ping the body this often during a watched wait
BEAT_TIMEOUT_S = 3.0
LOST_AFTER_BEATS = 2  # consecutive heartbeats without our id before a command counts as lost


class BridgeClient(GameInterface):
    def __init__(self, transport: Transport, logger: JsonlLogger | None = None,
                 default_timeout: float = 10.0, timeouts: dict[str, float] | None = None):
        self.transport = transport
        self.log = logger or JsonlLogger()
        self.default_timeout = default_timeout
        self.timeouts = {**DEFAULT_TIMEOUTS, **(timeouts or {})}
        self._events: list[Event] = []
        self._inflight: set[str] = set()  # request ids still waiting for their result
        self._sent: dict[str, str] = {}  # request id -> tool (broker: which task_failed is a held follow ending)
        self._abandoned: set[str] = set()  # ids the brain stopped waiting for (chat interrupt): still running in the body
        self._started = None  # the body bridge's start epoch, from the last ping that carried one
        # L2(a): set by the agent: True for an event that must get the floor now (an addressed chat line)
        self.interrupt_check: Callable[[Event], bool] | None = None
        self._parked: dict[str, dict] = {}  # results that arrived while some request was reading
        self._progress: list[Event] = []  # progress events not yet handed to the listener
        self._listener: Callable[[Event], None] | None = None
        self._notifying = False
        self._unknown_events: dict[str | None, int] = {}  # event type -> count (logged once each)
        # called with every successful get_state's data (map memory: observe + annotate remembered options)
        self.state_hooks: list[Callable[[dict], None]] = []

    # ---------------------------------------------------------------- plumbing

    def set_progress_listener(self, listener: Callable[[Event], None] | None) -> None:
        self._listener = listener

    def sent_tool(self, request_id: str) -> str | None:
        """The tool a request id was sent for (the body's task_done/task_failed carry that id)."""
        return self._sent.get(request_id)

    def _dispatch(self, msg: dict) -> None:
        """Route one incoming message: events are buffered, results parked for their request."""
        kind = msg.get("type")
        if kind == "event":
            etype = (msg.get("event") or {}).get("type") if isinstance(msg.get("event"), dict) else None
            if etype not in EVENT_TYPES:  # a body debug event (e.g. gather_status): note each type once
                n = self._unknown_events.get(etype, 0)
                self._unknown_events[etype] = n + 1
                if n == 0:
                    self.log.log("bridge_unknown_event", event_type=etype, sample=msg.get("event"))
                return
            try:
                ev = parse_event(msg.get("event") or {})
            except ValidationError as exc:
                self.log.log("bridge_bad_event", msg=msg, error=str(exc))
                return
            self._events.append(ev)
            if isinstance(ev, PROGRESS_EVENTS):
                self._progress.append(ev)
        elif kind in ("result", "error") and msg.get("id") in self._inflight:
            self._parked[msg["id"]] = msg
        elif kind in ("result", "error"):
            self.log.log("bridge_unmatched", msg=msg)  # late reply to a timed-out call, or body error
        else:
            self.log.log("bridge_unknown", msg=msg)

    def _notify_progress(self) -> None:
        """Hand progress events to the listener, outside the receive loop and never recursively
        (the listener's own ``say`` request also reads the wire)."""
        if self._listener is None:
            self._progress.clear()
            return
        if self._notifying:
            return
        self._notifying = True
        try:
            while self._progress:
                ev = self._progress.pop(0)
                try:
                    self._listener(ev)
                except Exception as exc:  # speech is best effort; never break the waiting action
                    self.log.log("progress_listener_error", error=repr(exc))
        finally:
            self._notifying = False

    def _drain_malformed(self) -> None:
        bad = getattr(self.transport, "malformed", None)
        while bad:
            self.log.log("bridge_malformed", line=bad.pop(0)[:500])

    def request(self, tool: str, args: dict | None = None, timeout: float | None = None,
                probe: bool = False) -> ActionResult:
        req_id = uuid.uuid4().hex[:12]
        msg = protocol.cmd(req_id, tool, args, probe=probe)
        timeout = timeout if timeout is not None else self.timeouts.get(tool, self.default_timeout)
        self.log.log("bridge_send", msg=msg)
        self._inflight.add(req_id)
        self._sent[req_id] = tool
        if len(self._sent) > 200:  # bounded: the oldest ids go first
            self._sent.pop(next(iter(self._sent)))
        watch = timeout > WATCH_AFTER_S and tool not in ("ping", protocol.CAPABILITIES)
        started0, seen, misses = self._started, len(self._events), 0
        try:
            self.transport.send(msg)
            deadline = time.monotonic() + timeout
            next_beat = time.monotonic() + HEARTBEAT_S
            while True:
                reply = self._parked.pop(req_id, None)
                if reply is not None:
                    self._drain_malformed()
                    self.log.log("bridge_recv", msg=reply)
                    if reply["type"] == "error":
                        return fail(reply.get("reason") or Reason.BODY_ERROR, detail=reply.get("detail"))
                    return from_wire(reply)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                for incoming in self.transport.receive(min(remaining, HEARTBEAT_S) if watch else remaining):
                    self._dispatch(incoming)
                self._drain_malformed()
                if req_id not in self._parked:
                    self._notify_progress()
                if not watch or req_id in self._parked:
                    continue
                # L2(a): an addressed chat line gets the floor; the body keeps working on the command
                if self.interrupt_check and any(self._safe_check(e) for e in self._events[seen:]):
                    self._abandoned.add(req_id)
                    self.log.log("bridge_wait_interrupted", id=req_id, tool=tool, why="addressed chat")
                    return fail(Reason.INTERRUPTED, tool=tool, id=req_id, by="chat",
                                detail="the player spoke; the body may still be doing it")
                seen = len(self._events)
                # L2(b): bridge heartbeat: a restart or a dropped command fails the request at once
                if time.monotonic() >= next_beat:
                    next_beat = time.monotonic() + HEARTBEAT_S
                    beat = self._beat()
                    if beat is not None and req_id not in self._parked:
                        started = beat.get("started")
                        if started is not None and started0 is not None and started != started0:
                            self.log.log("bridge_restart_detected", id=req_id, tool=tool, was=started0, now=started)
                            return fail(Reason.BODY_RESTARTED, tool=tool, id=req_id,
                                        detail="my body's bridge restarted and dropped the command")
                        started0 = started0 if started0 is not None else started
                        # a bridge that lists its waiters (cast, move_item, equip ... never sit in the action
                        # slot) tells "lost" from "waiting"; an older one only reports the slot
                        # Lost only when the body lists EVERYTHING it is still working on (the action slot AND
                        # its waiters: casts, equips, moves) and our id is in neither, on two beats in a row.
                        # A body without the waiters list is never declared lost (a 10 s cast came back
                        # lost_by_body while it was still running, 2026-10-26).
                        if "action" in beat and isinstance(beat.get("waiters"), list):
                            act = beat.get("action") or {}
                            alive = act.get("id") == req_id or req_id in beat["waiters"]
                            misses = 0 if alive else misses + 1
                            if misses >= LOST_AFTER_BEATS:
                                self.log.log("bridge_command_lost", id=req_id, tool=tool, slot=act,
                                             waiters=beat["waiters"])
                                return fail(Reason.LOST_BY_BODY, tool=tool, id=req_id, now_doing=act.get("kind"),
                                            detail="my body isn't working on it any more and never answered")
        finally:
            self._inflight.discard(req_id)
            self._parked.pop(req_id, None)
            if not self._inflight:
                self._progress.clear()  # progress that arrived with the final result is stale
        self.log.log("bridge_timeout", id=req_id, tool=tool, timeout=timeout)
        return fail(Reason.TIMEOUT, tool=tool, id=req_id)

    def ping(self, timeout: float = 5.0) -> float | None:
        """Round-trip time in seconds, or None on timeout."""
        start = time.perf_counter()
        res = self.request("ping", {}, timeout)
        if res["ok"] and res["data"].get("started") is not None:
            self._started = res["data"]["started"]
        return time.perf_counter() - start if res["ok"] else None

    def _beat(self) -> dict | None:
        """One heartbeat ping during a watched wait: its data ({started, action}) or None."""
        res = self.request("ping", {}, BEAT_TIMEOUT_S)
        if not res["ok"]:
            return None
        data = res["data"] or {}
        if data.get("started") is not None and self._started is None:
            self._started = data["started"]
        return data

    def _safe_check(self, ev: Event) -> bool:
        try:
            return bool(self.interrupt_check(ev))
        except Exception as exc:  # never let a predicate bug block the wait
            self.log.log("interrupt_check_error", error=repr(exc))
            return False

    def abandoned(self, request_id: str) -> bool:
        """The brain stopped waiting for this request (an addressed chat line came in)."""
        return request_id in self._abandoned

    def capabilities(self, timeout: float = 5.0) -> ActionResult:
        """Ask the body which tools it implements (``data.tools``). Older bodies answer unknown_tool."""
        return self.request(protocol.CAPABILITIES, {}, timeout)

    # ---------------------------------------------------------------- GameInterface

    def _tool(self, name: str, **args) -> ActionResult:
        return self.request(name, args)

    def get_state(self) -> ActionResult:
        res = self._tool("get_state")
        if res.get("ok") and isinstance(res.get("data"), dict):
            for hook in self.state_hooks:
                try:
                    hook(res["data"])
                except Exception as exc:  # memory is best effort; never break a state read
                    self.log.log("state_hook_error", error=repr(exc))
        return res

    def follow(self, player: str, distance: float = 3.0) -> ActionResult:
        return self._tool("follow", player=player, distance=distance)

    def stop(self) -> ActionResult:
        return self._tool("stop")

    def go_to(self, target: str | Coords) -> ActionResult:
        return self._tool("go_to", target=target)

    def attack(self, target: str) -> ActionResult:
        return self._tool("attack", target=target)

    def gather(self, resource: str, count: int, radius: float | None = None) -> ActionResult:
        args = {"resource": resource, "count": count}
        if radius is not None:
            args["radius"] = radius
        return self._tool("gather", **args)

    def craft(self, item: str, count: int = 1) -> ActionResult:
        return self._tool("craft", item=item, count=count)

    def place(self, blueprint: str, location: str | Coords) -> ActionResult:
        return self._tool("place", blueprint=blueprint, location=location)

    def give(self, player: str, item: str, count: int) -> ActionResult:
        return self._tool("give", player=player, item=item, count=count)

    def pickup(self, target: str, item: str | None = None, limit: int = 1) -> ActionResult:
        args = {"target": target, "limit": limit}
        if item is not None:
            args["item"] = item
        return self._tool("pickup", **args)

    def drop(self, item: str, count: int, at: str = "feet", player: str | None = None) -> ActionResult:
        return self.request("drop", _drop_none({"item": item, "count": count, "at": at, "player": player}))

    def say(self, text: str) -> ActionResult:
        return self._tool("say", text=text)

    def sleep(self, target: str | None = None, mode: str = "auto") -> ActionResult:
        return self.request("sleep", _drop_none({"target": target, "mode": mode}))

    def wake(self) -> ActionResult:
        return self._tool("wake")

    # spells (body/spells.lua) and reflex rules (body/rules.lua)
    def cast(self, spell: str, target: str | Coords | None = None) -> ActionResult:
        return self.request("cast", _drop_none({"spell": spell, "target": target}))

    def spells(self) -> ActionResult:
        return self.request("spells", {"compact": True})

    def set_reflex_rule(self, enemy: str = "*", trigger: dict | None = None, actions: list | None = None,
                        cooldown_s: float = 3.0, note: str | None = None) -> ActionResult:
        return self.request("set_reflex_rule", _drop_none(
            {"enemy": enemy, "trigger": trigger, "actions": actions, "cooldown_s": cooldown_s, "note": note}))

    def list_rules(self, enemy: str | None = None) -> ActionResult:
        return self.request("list_rules", _drop_none({"enemy": enemy}))

    def clear_rule(self, id: str | None = None, enemy: str | None = None, all: bool = False) -> ActionResult:
        return self.request("clear_rule", _drop_none({"id": id, "enemy": enemy, "all": all or None}))

    # perception (body/perception.lua) and the world id (per-world memory)
    def look(self, about: str | None = None, radius: float = 20.0, max: int = 15) -> ActionResult:
        return self.request("look", _drop_none({"about": about, "radius": radius, "max": max}))

    def inspect(self, target: str) -> ActionResult:
        return self._tool("inspect", target=target)

    def inventory(self) -> ActionResult:
        return self.request("inventory", {}, 10.0)

    def interact(self, target: str, secondary: bool = False) -> ActionResult:
        return self._tool("interact", target=target, secondary=secondary)

    def world_info(self) -> ActionResult:
        return self.request("world_info", {}, 5.0)

    def call_raw(self, tool: str, args: dict) -> ActionResult:
        # composite skills (fetch, consume, come_to, recover_grave) and manifest-only tools
        return self.request(tool, _drop_none(args))

    def poll_events(self) -> list[Event]:
        for msg in self.transport.receive(0.0):
            self._dispatch(msg)
        self._drain_malformed()
        self._progress.clear()  # the agent sees these in the returned list
        events, self._events = self._events, []
        return events

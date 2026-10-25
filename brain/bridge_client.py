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


class BridgeClient(GameInterface):
    def __init__(self, transport: Transport, logger: JsonlLogger | None = None,
                 default_timeout: float = 10.0, timeouts: dict[str, float] | None = None):
        self.transport = transport
        self.log = logger or JsonlLogger()
        self.default_timeout = default_timeout
        self.timeouts = {**DEFAULT_TIMEOUTS, **(timeouts or {})}
        self._events: list[Event] = []
        self._inflight: set[str] = set()  # request ids still waiting for their result
        self._parked: dict[str, dict] = {}  # results that arrived while some request was reading
        self._progress: list[Event] = []  # progress events not yet handed to the listener
        self._listener: Callable[[Event], None] | None = None
        self._notifying = False
        self._unknown_events: dict[str | None, int] = {}  # event type -> count (logged once each)

    # ---------------------------------------------------------------- plumbing

    def set_progress_listener(self, listener: Callable[[Event], None] | None) -> None:
        self._listener = listener

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
        try:
            self.transport.send(msg)
            deadline = time.monotonic() + timeout
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
                for incoming in self.transport.receive(remaining):
                    self._dispatch(incoming)
                self._drain_malformed()
                if req_id not in self._parked:
                    self._notify_progress()
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
        return time.perf_counter() - start if res["ok"] else None

    def capabilities(self, timeout: float = 5.0) -> ActionResult:
        """Ask the body which tools it implements (``data.tools``). Older bodies answer unknown_tool."""
        return self.request(protocol.CAPABILITIES, {}, timeout)

    # ---------------------------------------------------------------- GameInterface

    def _tool(self, name: str, **args) -> ActionResult:
        return self.request(name, args)

    def get_state(self) -> ActionResult:
        return self._tool("get_state")

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

    def drop(self, item: str, count: int, at: str = "feet") -> ActionResult:
        return self._tool("drop", item=item, count=count, at=at)

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

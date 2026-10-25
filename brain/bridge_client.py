"""GameInterface over the bridge (file JSONL now, sockets later via Transport).

Each action sends ``{"type": "cmd", "id", "tool", "args"}`` and blocks until a
``result`` with the same id arrives or the per-tool timeout expires. Events that
arrive meanwhile are buffered for ``poll_events``. See BRIDGE_PROTOCOL.md.
"""
from __future__ import annotations

import time
import uuid

from pydantic import ValidationError

from . import protocol
from .interface import ActionResult, Coords, Event, GameInterface, Reason, fail, from_wire, parse_event
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
DEFAULT_TIMEOUTS = {"gather": 180.0, "craft": 60.0, "attack": 60.0, "go_to": 120.0, "place": 60.0,
                    "pickup": 120.0, "give": 70.0}  # the body's give walks to the player first


class BridgeClient(GameInterface):
    def __init__(self, transport: Transport, logger: JsonlLogger | None = None,
                 default_timeout: float = 10.0, timeouts: dict[str, float] | None = None):
        self.transport = transport
        self.log = logger or JsonlLogger()
        self.default_timeout = default_timeout
        self.timeouts = {**DEFAULT_TIMEOUTS, **(timeouts or {})}
        self._events: list[Event] = []

    # ---------------------------------------------------------------- plumbing

    def _dispatch(self, msg: dict, waiting_for: str | None) -> dict | None:
        """Route one incoming message; return it if it answers ``waiting_for``."""
        kind = msg.get("type")
        if kind == "event":
            try:
                self._events.append(parse_event(msg.get("event") or {}))
            except ValidationError as exc:
                self.log.log("bridge_bad_event", msg=msg, error=str(exc))
        elif kind in ("result", "error") and msg.get("id") == waiting_for and waiting_for:
            return msg
        elif kind in ("result", "error"):
            self.log.log("bridge_unmatched", msg=msg)  # late reply to a timed-out call, or body error
        else:
            self.log.log("bridge_unknown", msg=msg)
        return None

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
        self.transport.send(msg)
        deadline = time.monotonic() + timeout
        while (remaining := deadline - time.monotonic()) > 0:
            for incoming in self.transport.receive(remaining):
                reply = self._dispatch(incoming, req_id)
                if reply is not None:
                    self._drain_malformed()
                    self.log.log("bridge_recv", msg=reply)
                    if reply["type"] == "error":
                        return fail(reply.get("reason") or Reason.BODY_ERROR, detail=reply.get("detail"))
                    return from_wire(reply)
            self._drain_malformed()
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

    def gather(self, resource: str, count: int) -> ActionResult:
        return self._tool("gather", resource=resource, count=count)

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

    def poll_events(self) -> list[Event]:
        for msg in self.transport.receive(0.0):
            self._dispatch(msg, None)
        self._drain_malformed()
        events, self._events = self._events, []
        return events

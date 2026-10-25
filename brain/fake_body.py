"""A stand-in for the Lua body: reads commands from the bridge, answers with the mock.

Lets the bridge round trip be tested without the game. Run standalone with
``python -m brain.fake_body [bridge_dir]`` and point a BridgeClient at the same dir.
"""
from __future__ import annotations

import sys
import threading
import time
from collections.abc import Iterable
from pathlib import Path

from . import paths, protocol
from .interface import BODY_TOOLS, PROGRESS_EVENTS, GameInterface, Reason, fail, ok
from .mock import MockGame
from .transport import BODY_TO_BRAIN, BRAIN_TO_BODY, JsonlFileTransport, Transport


class FakeBody:
    """``capabilities``: True answers the capabilities request truthfully, a list answers with
    that list (to fake a body that over-reports), False answers unknown_tool like an older body.
    ``not_implemented``: tools that answer not_implemented, like a stubbed Lua handler.
    ``progress_delay``: seconds to pause after each live progress event, standing in for the time a
    real gather takes between two progress events (the mock itself is instantaneous)."""

    def __init__(self, game: GameInterface, transport: Transport, capabilities: bool | list[str] = True,
                 not_implemented: Iterable[str] = (), progress_delay: float = 0.0):
        self.game = game
        self.transport = transport
        self.not_implemented = set(not_implemented)
        if capabilities is True:
            capabilities = [t for t in BODY_TOOLS if t not in self.not_implemented]
            capabilities += ["ping", protocol.CAPABILITIES]
        self.capabilities = capabilities
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        # Progress goes out live, while the action is still running (like body/gather.lua).
        self.progress_delay = progress_delay
        game.set_progress_listener(self._live_progress)

    def _live_progress(self, ev) -> None:
        self.transport.send(protocol.event(ev.model_dump()))
        if self.progress_delay:
            time.sleep(self.progress_delay)

    def _send_events(self) -> None:
        for ev in self.game.poll_events():
            if not isinstance(ev, PROGRESS_EVENTS):  # already sent live
                self.transport.send(protocol.event(ev.model_dump()))

    def handle(self, msg: dict) -> None:
        req_id = msg.get("id")
        if msg.get("type") != "cmd" or not isinstance(req_id, str) or not isinstance(msg.get("tool"), str):
            self.transport.send(protocol.error(req_id if isinstance(req_id, str) else None, "malformed",
                                               "expected type=cmd with string id and tool"))
            return
        tool = msg["tool"]
        if tool == "ping":
            res = ok(pong=True)
        elif tool == protocol.CAPABILITIES and self.capabilities is not False:
            res = ok(tools=list(self.capabilities))
        elif tool in self.not_implemented:
            res = fail(Reason.NOT_IMPLEMENTED, tool=tool)
        elif tool == "spells":  # the Controller's spell list (not a GameInterface tool)
            res = self.game.spells()
        elif tool == "world_info":  # the world id probe (per-world memory)
            res = self.game.world_info()
        elif msg.get("probe") and tool in BODY_TOOLS:
            res = ok(probe=True)  # implemented; a probe never acts
        else:
            args = msg.get("args") if isinstance(msg.get("args"), dict) else {}
            res = self.game.call(msg["tool"], args)
        self._send_events()  # events raised during the action go out before its result
        self.transport.send(protocol.result(req_id, res))

    def step(self, timeout: float = 0.05) -> None:
        msgs = self.transport.receive(timeout)
        bad = getattr(self.transport, "malformed", None)
        while bad:  # report malformed lines first, in arrival order
            self.transport.send(protocol.error(None, "malformed", bad.pop(0)[:200]))
        for msg in msgs:
            self.handle(msg)
        self._send_events()  # spontaneous events (e.g. a scripted chat line)

    def start(self) -> "FakeBody":
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def _loop(self) -> None:
        while not self._stop.is_set():
            self.step()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)


def main() -> None:
    d = Path(sys.argv[1]) if len(sys.argv) > 1 else paths.bridge_dir()
    body = FakeBody(MockGame.default_world(), JsonlFileTransport(d / BODY_TO_BRAIN, d / BRAIN_TO_BODY))
    print(f"fake body serving {d} (Ctrl+C to stop)")
    try:
        while True:
            body.step(0.25)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

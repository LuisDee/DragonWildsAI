"""A stand-in for the Lua body: reads commands from the bridge, answers with the mock.

Lets the bridge round trip be tested without the game. Run standalone with
``python -m brain.fake_body [bridge_dir]`` and point a BridgeClient at the same dir.
"""
from __future__ import annotations

import sys
import threading
from pathlib import Path

from . import paths, protocol
from .interface import GameInterface, ok
from .mock import MockGame
from .transport import BODY_TO_BRAIN, BRAIN_TO_BODY, JsonlFileTransport, Transport


class FakeBody:
    def __init__(self, game: GameInterface, transport: Transport):
        self.game = game
        self.transport = transport
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def _send_events(self) -> None:
        for ev in self.game.poll_events():
            self.transport.send(protocol.event(ev.model_dump()))

    def handle(self, msg: dict) -> None:
        req_id = msg.get("id")
        if msg.get("type") != "cmd" or not isinstance(req_id, str) or not isinstance(msg.get("tool"), str):
            self.transport.send(protocol.error(req_id if isinstance(req_id, str) else None, "malformed",
                                               "expected type=cmd with string id and tool"))
            return
        if msg["tool"] == "ping":
            res = ok(pong=True)
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

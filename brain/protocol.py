"""Bridge message envelopes (see BRIDGE_PROTOCOL.md), built in one place.

The brain sends ``cmd``; the body answers with ``result`` or ``error`` and emits
``event`` messages. The Lua body (mod/scripts/bridge.lua) implements the same
shapes; FakeBody uses these helpers so the Python stand-in cannot drift.
"""
from __future__ import annotations

import time
from typing import Any

from .interface import ActionResult

PROTOCOL_VERSION = 1


def cmd(req_id: str, tool: str, args: dict | None = None) -> dict:
    return {"v": PROTOCOL_VERSION, "type": "cmd", "id": req_id, "tool": tool, "args": args or {},
            "ts": round(time.time(), 3)}


def result(req_id: str, res: ActionResult) -> dict:
    return {"v": PROTOCOL_VERSION, "type": "result", "id": req_id, **res}


def error(req_id: str | None, reason: str, detail: Any) -> dict:
    return {"v": PROTOCOL_VERSION, "type": "error", "id": req_id, "reason": reason, "detail": detail}


def event(ev: dict) -> dict:
    return {"v": PROTOCOL_VERSION, "type": "event", "event": ev}

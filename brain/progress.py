"""No-progress breaker: what a turn's actions changed, and the same failure repeated without progress.

Brain-side, from the states before and after a turn (position, HP, inventory), so it needs nothing from the body.
It informs and caps spend; it never picks or rewrites the model's next call:
  - every body result gets a short ``change`` line ("moved 0.4 m; nothing gained") the model can read;
  - the same tool + rounded args + reason a 2nd time with < MOVED_M net movement and no inventory change since the
    first: the result says so plainly (``repeat``);
  - the PARK_AT-th time: the step is parked (``parked``): the model is told to tell the player the reason once, and
    the request's chain ends after that turn (no more model calls on it).

Prior art (search-before-building, 2026-10-31): OpenHands' StuckDetector flags the same action + the same error 3
times (and the same action + observation 4 times), comparing tool and content, not ids
(https://docs.openhands.dev/sdk/guides/agent-stuck-detector); Mindcraft's self-prompter stops after 3 turns without a
command (MAX_NO_COMMAND = 3, src/agent/self_prompter.js). A full detector framework is more than this needs (one
loop, one signal), so it is adapted here: 2 = tell, 3 = park.
"""
from __future__ import annotations

import json
import math
from typing import Any

from .situation import item_names, name_of_item

MOVED_M = 2.0  # less net movement than this between two identical failures = no progress
PARK_AT = 3  # identical no-progress failures before the step is parked (OpenHands: action + error x3)


def _pos(state: dict | None) -> list[float] | None:
    p = (state or {}).get("position")
    if isinstance(p, (list, tuple)) and len(p) >= 2 and all(isinstance(c, (int, float)) for c in p[:3]):
        return [float(c) for c in p[:3]]
    return None


def _inv(state: dict | None) -> dict[str, int]:
    inv = (state or {}).get("inventory")
    return {str(k): int(v) for k, v in inv.items() if isinstance(v, (int, float))} if isinstance(inv, dict) else {}


def _hp(state: dict | None):
    v = (state or {}).get("health")
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def inventory_delta(before: dict | None, after: dict | None) -> dict[str, int]:
    a, b = _inv(before), _inv(after)
    return {k: b.get(k, 0) - a.get(k, 0) for k in sorted(set(a) | set(b)) if b.get(k, 0) != a.get(k, 0)}


def change(before: dict | None, after: dict | None) -> str | None:
    """What changed between two states, in a few words ("moved 12 m; HP -30; +3 Ash Logs, -1 Water"); None when
    either state is unreadable."""
    p0, p1 = _pos(before), _pos(after)
    if p0 is None or p1 is None:
        return None
    bits = [f"moved {math.dist(p0[:2], p1[:2]):.1f} m"]
    h0, h1 = _hp(before), _hp(after)
    if h0 is not None and h1 is not None and abs(h1 - h0) >= 1:
        bits.append(f"HP {h1 - h0:+.0f}")
    names = {**item_names(before or {}), **item_names(after or {})}
    items = [f"{n:+d} {name_of_item(k, names)}" for k, n in inventory_delta(before, after).items()]
    bits.append(", ".join(items) if items else "inventory unchanged")
    return "; ".join(bits)


def _rounded(v: Any) -> Any:
    if isinstance(v, float):
        return round(v)
    if isinstance(v, (list, tuple)):
        return [_rounded(x) for x in v]
    if isinstance(v, dict):
        return {k: _rounded(x) for k, x in sorted(v.items())}
    return v


def signature(tool: str, args: dict, reason: str | None) -> str:
    return json.dumps([tool, _rounded(args or {}), reason], default=str, sort_keys=True)


class RepeatWatch:
    """Identical failures (tool + rounded args + reason) with no progress in between, over a session."""

    def __init__(self):
        self._seen: dict[str, tuple[int, list[float] | None, dict[str, int]]] = {}
        self.parked: set[str] = set()

    def note(self, tool: str, args: dict, reason: str | None, after: dict | None) -> int:
        """Count this failure; the count restarts at 1 when he moved MOVED_M or the inventory changed since the
        first of the run."""
        sig = signature(tool, args, reason)
        pos, inv = _pos(after), _inv(after)
        prev = self._seen.get(sig)
        same = (prev is not None and pos is not None and prev[1] is not None
                and math.dist(prev[1][:2], pos[:2]) < MOVED_M and prev[2] == inv)
        n = prev[0] + 1 if same else 1
        self._seen[sig] = (n, prev[1] if same else pos, prev[2] if same else inv)
        return n

    def progressed(self, tool: str, args: dict) -> None:
        """A success of this call: its failures so far are history."""
        head = json.dumps([tool, _rounded(args or {})], default=str, sort_keys=True)[:-1]
        for sig in [s for s in self._seen if s.startswith(head)]:
            self._seen.pop(sig, None)
            self.parked.discard(sig)

    def verdict(self, tool: str, args: dict, reason: str | None, n: int, player: str) -> dict:
        """The plain words for the model (empty below 2)."""
        call = f"{tool} {json.dumps(_rounded(args or {}), default=str)}"
        if n < 2:
            return {}
        if n < PARK_AT:
            return {"repeat": f"2nd time {call} failed the same way ({reason}), and you have not moved "
                              f"{MOVED_M:.0f} m or gained anything since the first: the same call again will very "
                              "likely fail again."}
        sig = signature(tool, args, reason)
        first = sig not in self.parked
        self.parked.add(sig)
        nth = {3: "3rd"}.get(n, f"{n}th")
        return {"parked": f"{nth} time {call} failed the same way ({reason}) with no progress: this step is parked "
                          "for now" + (f". Tell {player} in one short line what is stopping you (that reason, in "
                                       "plain words) and what would help." if first else
                                       " (you already told him why).")}

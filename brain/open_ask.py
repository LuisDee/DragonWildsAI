"""A player's ask still open when a turn calls nothing (variant C of docs/research/2026-11-17-open-ask-replay.md).

A turn with no call used to close the ask (agent ``request_closed``), and nothing read the game. Now that turn gets ONE
more Controller turn whose context carries the ask as data: the player's words, who asked and how long ago, and what
changed in the game since (bag, worn and held gear, quest steps), read from the body's own state rows. On that turn,
and only then, two tools are offered: ``request_done(evidence)`` and ``park_request(reason)``. Either closes the ask,
and so does the player's next line; nothing else does (2026-11-18): a second silent turn leaves it open
(``request_left_open``) and the next run carries it. Nothing here says what to do: the block is facts, the tools are
neutral.

The tool wording and the block are the ones the replay measured (tools/replay_open_ask.py imports them from here).
Pure functions only: no I/O, no model calls.
"""
from __future__ import annotations

import re

DONE, PARK = "request_done", "park_request"
ASK_TOOLS = (DONE, PARK)
NOTE_PREFIX = "Open request: "
OPEN_UNTIL = "request_done or park_request is called"

PARK_TOOL = {"type": "function", "function": {
    "name": PARK,
    "description": "Stop working on the player's open request for now. The player hears the reason. The request stays "
                   "open until park_request or request_done is called.",
    "parameters": {"type": "object", "properties": {"reason": {
        "type": "string", "description": "Why it stops here, in a few plain words the player reads."}},
        "required": ["reason"]}}}
DONE_TOOL = {"type": "function", "function": {
    "name": DONE,
    "description": "Close the player's open request as finished. The request stays open until request_done or "
                   "park_request is called.",
    "parameters": {"type": "object", "properties": {"evidence": {
        "type": "string", "description": "What in the game shows it is finished (quest log, bag, what you wear)."}},
        "required": ["evidence"]}}}
ASK_TOOL_SCHEMAS = (DONE_TOOL, PARK_TOOL)
ARG = {DONE: "evidence", PARK: "reason"}


# ------------------------------------------------------------------ facts


def _name(item: str, names: dict[str, str], cat: dict) -> str:
    if item in names:
        return names[item]
    n = (cat.get(item) or {}).get("name")
    return n or re.sub(r"^ITEM_", "", str(item)).replace("_", " ")


def _names_of(*states: dict | None) -> dict[str, str]:
    out = {}
    for s in states:
        for row in (s or {}).get("inventory_items") or []:
            if isinstance(row, dict) and row.get("item") and row.get("name"):
                out[row["item"]] = row["name"]
    return out


WORN = (("head", "Head"), ("body", "Body"), ("legs", "Legs"), ("right_hand", "held_right"), ("left_hand", "held_left"),
        ("back", "Back"))


def worn(state: dict | None, names: dict, cat: dict) -> dict[str, str | None]:
    g = (state or {}).get("gear") or {}
    return {slot: (_name(g[key], names, cat) if g.get(key) else None) for slot, key in WORN}


def quest_log(state: dict | None) -> dict:
    q = (state or {}).get("quests") or {}
    return {"active": [{"quest": a.get("quest"), "step": (a.get("step") or "").strip()}
                       for a in q.get("active") or [] if isinstance(a, dict)],
            "complete": list(q.get("complete") or [])}


def changes(before: dict | None, after: dict | None, cat: dict | None = None, limit: int = 12) -> dict:
    """What changed between two state reads: bag counts, worn slots, quest steps. Facts only."""
    cat = cat or {}
    names = _names_of(before, after)
    out: dict = {}
    b_inv = {k: int(v) for k, v in ((before or {}).get("inventory") or {}).items() if isinstance(v, (int, float))}
    a_inv = {k: int(v) for k, v in ((after or {}).get("inventory") or {}).items() if isinstance(v, (int, float))}
    delta = {k: a_inv.get(k, 0) - b_inv.get(k, 0) for k in set(b_inv) | set(a_inv)}
    delta = sorted(((k, d) for k, d in delta.items() if d), key=lambda kd: (-abs(kd[1]), kd[0]))
    out["bag"] = {_name(k, names, cat): (f"+{d}" if d > 0 else str(d)) for k, d in delta[:limit]} or "no change"
    wb, wa = worn(before, names, cat), worn(after, names, cat)
    out["worn"] = {s: f"{wb[s] or 'nothing'} -> {wa[s] or 'nothing'}" for s in wb if wb[s] != wa[s]} or "no change"
    qb, qa = quest_log(before), quest_log(after)
    steps_b = {a["quest"]: a["step"] for a in qb["active"]}
    q = {}
    for a in qa["active"]:
        if a["quest"] not in steps_b:
            q[a["quest"]] = f"new: {a['step']}"
        elif steps_b[a["quest"]] != a["step"]:
            q[a["quest"]] = f"{steps_b[a['quest']]} -> {a['step']}"
    for name in qa["complete"]:
        if name not in qb["complete"]:
            q[name] = "completed" + (f" (still active: {next(a['step'] for a in qa['active'] if a['quest'] == name)})"
                                     if any(a["quest"] == name for a in qa["active"]) else "")
    out["quests"] = q or "no change"
    return out


def readable(state: dict | None) -> bool:
    """A state read the facts can come from (an unavailable body gives {"unavailable": ...})."""
    return isinstance(state, dict) and "inventory" in state


# ------------------------------------------------------------------ what the extra turn is shown


def block(player: str | None, words: str, asked_s_ago: int | None, changed: dict | str) -> dict:
    """The open ask as data (the replay's variant C block): who, his words, how long ago, what changed since."""
    return {"open_request": {"player": player, "words": words, "asked_s_ago": asked_s_ago,
                             "changed_since_asked": changed, "open_until": OPEN_UNTIL}}

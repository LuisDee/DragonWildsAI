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


def block(player: str | None, words: str, asked_s_ago: int | None, changed: dict | str,
          known: list[str] | None = None) -> dict:
    """The open ask as data (the replay's variant C block): who, his words, how long ago, what changed since, and
    what the game told him about it while he worked on it (``facts_view``)."""
    return {"open_request": {"player": player, "words": words, "asked_s_ago": asked_s_ago,
                             "changed_since_asked": changed, **({"known_facts": known} if known else {}),
                             "open_until": OPEN_UNTIL}}


# ------------------------------------------------------------------ what the game told him about the open ask
# Live 2026-11-18 00:08Z (logs/brain-live-20261118-010135-17424.jsonl): at 244 s a failed explore for copper carried
# "Copper Ore Node ... tool: Bone pickaxe or better (tier 2) ... your best pickaxe: Stone Pickaxe (tier 1), below it";
# at 389 s, a thirst detour later, no part of his context held it: a Bone Pickaxe craft failed short and he chose "I'll
# mine the copper with my stone pickaxe instead". Replayed with that fact back in his context 4 of 4 kept the bone
# pickaxe, without it 0 of 4. So the facts the game and his knowledge gave him while he worked on an ask are kept with
# that ask (newest first, one per subject, bounded) and shown with it while it is open. Facts with their source only.

FACTS_CHARS = 720  # all kept facts of one ask, as shown (two whole facts: a node fact is up to ~350 with its source)
FACT_CHARS = 360  # one fact with its source and age (result_knowledge.MAX_CHARS 300 + its source)
FACTS_KEPT = 6


def _cut(s: str, n: int) -> str:
    return s if len(s) <= n else s[: n - 1].rsplit(" ", 1)[0] + "…"


def keep_fact(facts: list[dict], key: str, source: str, text: str, raw: str | None = None,
              t: float | None = None) -> list[dict]:
    """``facts`` with this one first: a fact with the same subject (key) or the same words is replaced (the newest
    reading of a thing wins: a node's distances change as he walks). ``source`` is the call that produced it (shown);
    ``raw`` the words as the result carried them (a fact already shown beside, in a step's result, is not repeated);
    ``t`` when it was read (shown as its age: "from you" distances are from where he stood then)."""
    text = " ".join(str(text or "").split())
    if not text:
        return list(facts)
    rest = [f for f in facts if f.get("key") != key and f.get("text") != text]
    return [{"key": key, "source": source, "text": text, "raw": " ".join(str(raw or text).split()), "t": t},
            *rest][:FACTS_KEPT]


def _age(t: float | None, now: float | None) -> str | None:
    if t is None or now is None:
        return None
    s = max(0, round(now - t))
    return f"{s} s ago" if s < 120 else f"{round(s / 60)} min ago"


def fact_line(f: dict, now: float | None = None) -> str:
    """'<source>, <age>: <text>' within FACT_CHARS."""
    head = ", ".join(x for x in (f.get("source"), _age(f.get("t"), now)) if x)
    return _cut(f"{head}: {f['text']}" if head else f["text"], FACT_CHARS)


def facts_view(facts: list[dict], exclude: str | None = None, limit: int = FACTS_CHARS,
               now: float | None = None) -> list[str]:
    """The kept facts as shown, newest first, within ``limit`` characters; a fact whose words are already in
    ``exclude`` (the step result shown beside it) is left out."""
    out, used = [], 0
    exclude = " ".join(str(exclude or "").split())
    for f in facts:
        raw = f.get("raw") or ""
        if exclude and raw and raw in exclude:
            continue
        line = fact_line(f, now)
        if used + len(line) > limit:
            if not out:  # one fact longer than the room: cut, never dropped
                out.append(line[: limit - 1].rsplit(" ", 1)[0] + "…")
            break
        out.append(line)
        used += len(line)
    return out


_AGE = re.compile(r", \d+ (?:s|min) ago(?=: )")


def facts_key(view: list[str] | None) -> tuple:
    """A shown list without its ages: the same facts shown a turn later compare equal."""
    return tuple(_AGE.sub("", s, count=1) for s in view or [])


def same_ask(a: tuple | None, b: tuple | None) -> bool:
    """One ask for another: the same player (or one unknown) and the same words, one possibly cut short (a goal's
    asked_at keeps 80 characters of them)."""
    if not a or not b:
        return False
    if a[0] and b[0] and str(a[0]).lower() != str(b[0]).lower():
        return False
    x, y = str(a[1] or ""), str(b[1] or "")
    return bool(x and y) and (x == y or x.startswith(y) or y.startswith(x))


# ------------------------------------------------------------------ a parked ask he takes up again
# Live 2026-11-18 (logs/brain-live-20261118-034204-21300.jsonl, run 20261118-024217-L2): he parked the copper ask at
# 48 s ("Need a spare pickaxe or leather to make a bone pickaxe"), took it up himself at 64 s in a review (craft_plan
# Leather, recipes Bone Pickaxe, gather ash: "I'll grab the ash logs here and hunt deer for hide"), went for water and
# food, and at 210 s stopped with no call for 12 minutes: the ask was parked, so no open-ask turn applied. A call of
# his that names a game item the parked ask names (in his words, the park reason or its kept facts) is a step on it:
# the ask is open again, with its facts. Bookkeeping of which ask a call serves, by game item names; he decides.

ARG_KEYS = ("item", "resource", "input", "about", "output")


def _tokens(s: str) -> frozenset:
    return frozenset(re.findall(r"[a-z0-9]+", str(s or "").lower()))


def names_in(text: str, names) -> set[str]:
    """The game item names (``names``: an iterable of display names) that appear in ``text``, whole words."""
    low = f" {' '.join(re.findall(r'[a-z0-9]+', str(text or '').lower()))} "
    return {n for n in names if n and f" {' '.join(re.findall(r'[a-z0-9]+', n.lower()))} " in low}


def serves(calls: list[dict], names: set[str]) -> tuple[str, str, str] | None:
    """(tool, the call's word, the item name) for the first call whose item argument is one of ``names`` (or one's
    shorter form: gather "ash" for Ash Logs), else None. ``calls``: [{tool, args}]."""
    want = [(n, _tokens(n)) for n in names]
    for c in calls:
        args = c.get("args") if isinstance(c.get("args"), dict) else {}
        for k in ARG_KEYS:
            v = args.get(k)
            if not isinstance(v, str) or not v.strip():
                continue
            t = _tokens(v)
            for n, nt in want:
                if t and nt and (t <= nt or nt <= t):
                    return str(c.get("tool")), v, n
    return None

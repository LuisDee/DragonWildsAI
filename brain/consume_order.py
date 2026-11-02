"""Food and drink use separate game locks (inventory.consume_busy is per kind; ~6 s each), but the brain runs one
reply's tool calls one after another. A run of consecutive consume calls like [Fillet, Fillet, Fillet, Clean Water]
then makes the drink wait behind both food locks (live r1-20261102T050223Z: water at 40 % only after 28 s, 3.1x the
human bar). interleave() takes the kinds in turn within such a run, keeping each kind's own order and every call:
[Fillet, Clean Water, Fillet, Fillet]. Only the head-of-line wait goes; what he eats and drinks, and how many, stays
the model's. Calls between other tools are never moved across them.
"""
from __future__ import annotations

from brain.situation import consumable_rows


def _kind_of(call, kinds: dict[str, str]) -> str | None:
    if getattr(call, "name", None) != "consume":
        return None
    what = str((getattr(call, "arguments", None) or {}).get("item") or "").strip().lower()
    if what in ("food", "drink"):
        return what
    return kinds.get(what)


def interleave(actions: list, state: dict | None) -> list:
    kinds: dict[str, str] = {}
    for k, r in consumable_rows(state or {}):
        for key in (r.get("item"), r.get("name")):
            if key:
                kinds[str(key).strip().lower()] = k
    out, i = [], 0
    while i < len(actions):
        j = i
        while j < len(actions) and getattr(actions[j], "name", None) == "consume":
            j += 1
        if j - i < 2:
            out.append(actions[i])
            i += 1
            continue
        run = actions[i:j]
        lanes: dict[str, list] = {}
        order: list[str] = []
        for c in run:
            k = _kind_of(c, kinds) or "other"
            if k not in lanes:
                lanes[k] = []
                order.append(k)
            lanes[k].append(c)
        if "other" in lanes or len(lanes) < 2:  # an unknown kind (a potion) waits for every lock: keep the model's order
            out.extend(run)
        else:
            while any(lanes.values()):
                for k in order:
                    if lanes[k]:
                        out.append(lanes[k].pop(0))
        i = j
    return out

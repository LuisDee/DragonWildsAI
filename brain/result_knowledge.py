"""What the brain's own knowledge says about where a thing is found, added to a gather or explore result that
failed because the thing was not found (live 2026-11-17, job "thirty copper ore in the chest at your base": two
explores of 8 legs around home, then gather "I can't find any copper within 90 m of me", and he parked the ask
asking the player for a patch; the wiki's Copper Ore Node page names three regions and he never called lookup).

Facts only, with their source: the node's location line and tool from the wiki. Nothing when the knowledge has no
node for the name. It tells him what the wiki says, never what to do (CLAUDE.md section 3).

With his state (live 2026-11-17 22:2xZ, brain-live-20261117-221939-19116: shown only the region names, he asked the
player where copper is and stopped; docs/research/2026-11-17-region-travel.md) it also says, from the game's map
data, which region he is in and how far and which way each named region is (the resolver go_to walks to for a
region name, brain/places.Places.where, so go_to <that name> goes where the numbers say), and his best carried tool
of the needed kind against the wiki's tool (tiers from the item catalog)."""
from __future__ import annotations

import re
from functools import lru_cache
from typing import Any, Callable

MAX_CHARS = 300
# gather's "not found" (client_mod/scripts/gather.lua): no_resource_nearby, and no_node_of_kind for a category;
# the older body (mod/body/gather.lua) gives no why. Nodes there but used up or left alone are not "not found".
GATHER_NOT_FOUND = (None, "no_resource_nearby", "no_node_of_kind")


def query_of(tool: str, args: dict | None, result: dict | None) -> str | None:
    """The thing a failed gather or explore looked for and did not find, else None."""
    if not isinstance(result, dict) or result.get("ok") is not False or result.get("reason") != "nothing_in_range":
        return None
    args = args if isinstance(args, dict) else {}
    data = result.get("data") if isinstance(result.get("data"), dict) else {}
    if tool == "gather":
        if data.get("why") not in GATHER_NOT_FOUND or data.get("used_up") or data.get("left_alone"):
            return None
        q = args.get("resource") or data.get("resource")
    elif tool == "explore":
        q = args.get("about") or data.get("about")
    else:
        return None
    return q if isinstance(q, str) and q.strip() else None


@lru_cache(maxsize=1)
def _default_places():
    from .places import Places  # the newest data/places_<build>.json, as go_to's resolver reads it
    return Places()


def _read_state(state: dict | Callable[[], dict] | None) -> dict | None:
    if callable(state):
        try:
            state = state()
        except Exception:  # an unreadable state is no state: the wiki fact stands alone
            return None
    return state if isinstance(state, dict) and not state.get("unavailable") else None


def _map_part(location: str | None, here, places) -> str | None:
    """'map, from you in <region>: <name> <d> m <dir>, ...' (nearest first) for the location line's names that are
    map regions or provinces, by the resolver go_to uses; None when none is."""
    from .geom import direction
    from .places import _pos
    here = _pos(here)
    if not location or here is None or places is None:
        return None
    rows = []
    for name in dict.fromkeys(n.strip() for n in location.split(",") if n.strip()):
        try:
            res = (places.where(name, here, limit=1).get("data") or {}).get("results") or []
        except Exception:  # map data is best effort
            continue
        best = res[0] if res else None
        if not best or best.get("match") != "exact" or best.get("kind") not in ("region", "province"):
            continue
        if best.get("you_are_inside"):
            rows.append((0, f"{name} (you are in it)"))
        elif isinstance(best.get("distance_m"), (int, float)) and _pos(best.get("position")):
            d = round(best["distance_m"])
            rows.append((d, f"{name} {d} m {direction(here, best['position'])}"))
    if not rows:
        return None
    rows.sort(key=lambda r: r[0])
    mine = places.region_name(here)
    return f"map, from you{f' in {mine}' if mine else ''}: " + ", ".join(t for _, t in rows)


def _tool_need(tool: str | None) -> tuple[str, int, str] | None:
    """The wiki's 'Bone pickaxe or better' / 'Any pickaxe' -> (category, tier, item name) from the item catalog."""
    from . import item_stats
    if not tool:
        return None
    t = tool.strip()
    m = re.match(r"any (\w+)$", t, re.I)
    if m:
        return m.group(1).lower(), 1, ""
    name = re.sub(r"\s+or better$", "", t, flags=re.I).strip().lower()
    for e in item_stats.catalog().values():
        if (e.get("name") or "").lower() == name and isinstance(e.get("tier"), int) and e.get("category"):
            return e["category"], e["tier"], e["name"]
    return None


def _carried_ids(state: dict) -> set[str]:
    ids = set()
    inv = state.get("inventory")
    if isinstance(inv, dict):
        ids |= {k for k, v in inv.items() if isinstance(k, str) and (not isinstance(v, (int, float)) or v > 0)}
    gear = state.get("gear")
    if isinstance(gear, dict):
        ids |= {v for v in gear.values() if isinstance(v, str)}
    for r in state.get("inventory_items") or []:
        if isinstance(r, dict) and isinstance(r.get("item"), str):
            ids.add(r["item"])
    return ids


def _tool_part(need: tuple[str, int, str], state: dict) -> str:
    """His best carried tool of the needed kind against the needed tier (bag, hotbar and gear)."""
    from . import item_stats
    cat_name, tier, _ = need
    cat = item_stats.catalog()
    have = [(e["tier"], e.get("name") or i) for i in _carried_ids(state)
            for e in [cat.get(i) or {}] if e.get("category") == cat_name and isinstance(e.get("tier"), int)]
    if not have:
        return f"you carry no {cat_name}"
    t, name = max(have)
    return f"your best {cat_name}: {name} (tier {t}), {'meets it' if t >= tier else 'below it'}"


def note(knowledge: Any, tool: str, args: dict | None, result: dict | None,
         state: dict | Callable[[], dict] | None = None, *, places: Any = None) -> tuple[str, str] | None:
    """(query, text) for a not-found gather/explore result whose thing the knowledge places, else None.
    ``state``: his get_state, or a reader of it called only when there is a fact; without it, no map or tool part.
    ``places``: a brain.places.Places (default: the newest map data file)."""
    q = query_of(tool, args, result)
    if q is None or knowledge is None or not hasattr(knowledge, "node_facts"):
        return None
    try:
        f = knowledge.node_facts(q)
    except Exception:  # knowledge is best effort; never break the turn on it
        return None
    if not f:
        return None
    st = _read_state(state) if state is not None else None
    need = None
    if st is not None and f.get("tool"):
        try:
            need = _tool_need(f["tool"])
        except Exception:
            need = None
    tool_s = f.get("tool") and (f"tool: {f['tool']}" + (f" (tier {need[1]})" if need and need[2] else ""))
    facts = [x for x in (f.get("location") and f"found in {f['location']}", tool_s) if x]
    wiki = f"wiki, {f['title']}: " + "; ".join(facts)
    extra: list[str] = []
    if st is not None:
        try:
            if places is None:
                places = _default_places()
            m = _map_part(f.get("location"), st.get("position"), places)
        except Exception:  # map data is best effort
            m = None
        if m:
            extra.append(m)
        if need:
            try:
                extra.append(_tool_part(need, st))
            except Exception:
                pass
    text = ". ".join([wiki, *extra])
    while len(text) > MAX_CHARS and extra and extra[0].startswith("map,") and ", " in extra[0].split(": ", 1)[1]:
        extra[0] = extra[0].rsplit(", ", 1)[0]  # drop the farthest region first
        text = ". ".join([wiki, *extra])
    if len(text) > MAX_CHARS:
        text = text[: MAX_CHARS - 1].rsplit(" ", 1)[0] + "…"
    return q, text


def enrich(knowledge: Any, tool: str, args: dict | None, result: dict, log=None,
           state: dict | Callable[[], dict] | None = None) -> bool:
    """Add ``result["knowledge"]`` (and log result_knowledge) when ``note`` has one. True when added."""
    got = note(knowledge, tool, args, result, state)
    if got is None:
        return False
    result["knowledge"] = got[1]
    if log is not None:
        log.log("result_knowledge", tool=tool, query=got[0], added=got[1])
    return True

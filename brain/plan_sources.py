"""Where the things a craft plan cannot make come from, and whether a station he lacks is a piece he can build: facts
from the game's own data and the wiki mirror, added to a ``craft_plan`` result (CLAUDE.md section 3: the plan tool
shows facts about the game; he decides).

Live 2026-11-17 (offline check of ``craft_plan Bone Pickaxe`` from a fresh fork, and the Bronze Pickaxe plan of
logs/brain-live-20261117-231925-27552): Animal Bone was a bare ``obtain`` though Bark to Bones was his to cast; Animal
Hide came only from a trader for Garou Chits he did not have (the one recipe for it), never from the cows, deer and
wolves that drop it; the Tannery was a bare ``find_station``, never the build-menu piece it is. He parked the ask.

What is added (bounded: MAX_ITEMS items, MAX_PER_ITEM sources each, every line at most LINE_CHARS):

* ``sources`` (on the thing's obtain step; else in a top-level {item name: [lines]}) for each thing in the tree the
  plan cannot craft from what he carries (a leaf marked obtain / cycle / depth, or a thing whose recipe is a
  trader's), from
  - spells that make it (data/spell_mechanics.json ``makes``, wiki-sourced), with whether it is among his spells now;
  - creatures that drop it (data/bestiary.json ``dropped_by``), with power level and where they live;
  - the wiki's resource node for it (``Knowledge.node_facts``);
  - traders that sell it (recipe data), with the price against what he carries.
  Ordered by what he can do now (a spell of his castable now, a creature in sight; then one in his region or a price
  he carries; then the rest), never by name. A thing the plan buys from a trader he can't pay, while the game has
  other ways to it, becomes an obtain step with its sources (the trader one of them), not "obtain the currency first".
* ``build`` on a ``find_station`` step the client could not answer from his unlocked pieces: the wiki's build-menu
  cost and unlock line for that station, and what of the cost he carries.
* ``is`` on the item planned (the root) and on each candidate of an ambiguous name: the item's own game card, its
  category, tier and description from the item data (``item_card``), as the crafting menu shows them.
"""
from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any

MAX_ITEMS = 6
MAX_PER_ITEM = 5
MAX_DROPS = 3
LINE_CHARS = 170
LEAF = ("obtain", "cycle", "depth")
NOW, NEAR, LATER = 0, 1, 2


def _data_dir() -> Path:
    from .knowledge import data_dir
    return data_dir()


@lru_cache(maxsize=2)
def bestiary(path: str | None = None) -> dict:
    try:
        return json.loads(Path(path or _data_dir() / "bestiary.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


@lru_cache(maxsize=2)
def spell_makes(path: str | None = None) -> dict[str, list[str]]:
    """item name (lower) -> [spell ids] from data/spell_mechanics.json ``makes``."""
    try:
        doc = json.loads(Path(path or _data_dir() / "spell_mechanics.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, list[str]] = {}
    for sid, m in (doc.get("spells") or {}).items():
        for name in (m or {}).get("makes") or []:
            out.setdefault(str(name).lower(), []).append(sid)
    return out


def _catalog() -> dict:
    from . import needs
    return needs.catalog()


def _clip(s: str) -> str:
    return s if len(s) <= LINE_CHARS else s[: LINE_CHARS - 1].rsplit(" ", 1)[0] + "…"


def counts(state: dict | None) -> dict[str, int]:
    """item id -> count carried (bag, hotbar), from get_state."""
    out: dict[str, int] = {}
    if not isinstance(state, dict):
        return out
    inv = state.get("inventory")
    if isinstance(inv, dict):
        for k, v in inv.items():
            if isinstance(k, str) and isinstance(v, (int, float)):
                out[k] = out.get(k, 0) + int(v)
    if not out:
        for r in state.get("inventory_items") or []:
            if isinstance(r, dict) and isinstance(r.get("item"), str):
                out[r["item"]] = out.get(r["item"], 0) + int(r.get("count") or 1)
    return out


def _in_sight(state: dict | None) -> set[str]:
    names: set[str] = set()
    if not isinstance(state, dict):
        return names
    for e in state.get("nearby_entities") or []:
        if isinstance(e, dict) and e.get("name") and e.get("alive", True):
            names.add(str(e["name"]).lower())
    for r in state.get("further_off") or []:
        if isinstance(r, dict) and r.get("name") and str(r.get("category")) == "creatures":
            names.add(str(r["name"]).lower())
    return names


def _region(state: dict | None, places) -> str | None:
    if places is None or not isinstance(state, dict) or state.get("position") is None:
        return None
    try:
        return places.region_name(state.get("position"))
    except Exception:  # map data is best effort
        return None


# ------------------------------------------------------------------------------ the sources of one item


def _spells(name: str, spells: list[dict] | None) -> list[tuple[int, int, str]]:
    from .spells import effects
    out = []
    mine = {str(r.get("name") or "").lower(): r for r in spells or [] if isinstance(r, dict)}
    for sid in spell_makes().get(name.lower(), []):
        e = effects().get(sid) or {}
        sname = e.get("name") or sid
        cost = " + ".join(f"{n} {r}" for r, n in (e.get("cost") or {}).items())
        req = ((e.get("requirement") or {}).get("text") or "").strip()
        row = mine.get(sname.lower())
        if spells is None:
            tier, status = NEAR, None
        elif row is not None and not row.get("note") and row.get("castable", True) is not False:
            tier, status = NOW, "yours, castable now"
        elif row is not None:
            tier, status = NEAR, f"yours, {row.get('note') or row.get('reason') or 'not castable right now'}"
        else:
            u = e.get("unlock") or {}
            need = f"{u.get('skill')} {u.get('level')}" if u.get("skill") and u.get("level") else "its unlock"
            tier, status = LATER, f"not among your spells now; needs {need}"
        bits = [b for b in (cost and f"{cost} runes", status) if b]
        out.append((tier, 0, _clip(f"spell {sname}: {req[:1].lower() + req[1:] if req else 'cast it'}"
                                   + (f" ({'; '.join(bits)})" if bits else ""))))
    return out


def _creature(name: str) -> dict:
    c = (bestiary().get("creatures") or {})
    if name in c:
        return c[name]
    low = name.lower()
    return next((v for k, v in c.items() if k.lower() == low), {})


def _pl(cr: dict) -> tuple[float, str]:
    pls = sorted({int(v["power_level"]) for v in cr.get("variants") or []
                  if isinstance(v, dict) and str(v.get("power_level", "")).lstrip("-").isdigit()
                  and int(v["power_level"]) >= 0})
    if not pls:
        return 99.0, ""
    return float(pls[0]), (f"PL {pls[0]}" if len(pls) == 1 else f"PL {pls[0]}-{pls[-1]}")


def _drops(name: str, sight: set[str], region: str | None) -> list[tuple[int, int, str]]:
    db = bestiary().get("dropped_by") or {}
    rec = db.get(name) or next((v for v in db.values() if name.lower() in
                                {a.lower() for a in [v.get("item") or "", *(v.get("aliases") or [])]}), None)
    rows = []
    for r in (rec or {}).get("rows") or []:
        who = str(r.get("from") or "")
        if not who:
            continue
        cr = _creature(who)
        pl, pl_s = _pl(cr)
        locs = [x for x in cr.get("locations") or [] if isinstance(x, str)]
        if who.lower() in sight:
            tier, where = NOW, "one in sight"
        elif region and region in locs:
            tier, where = NEAR, f"lives in {region}, your region"
        else:
            tier, where = LATER, (f"lives in {', '.join(locs[:2])}" if locs else "")
        how = str(r.get("how") or "drop")
        amt = ", ".join(x for x in (str(r.get("amount") or ""), str(r.get("rate") or "")) if x)
        line = f"{'drop' if how == 'drop' else how}: {who}" + (f" ({amt})" if amt else "") + \
            "".join(f"; {x}" for x in (pl_s, where) if x)
        always = 0 if str(r.get("rate")) == "always" else 1
        rows.append((tier, always, pl, _clip(line)))
    rows.sort(key=lambda x: x[:3])
    return [(t, 1, line) for t, _, _, line in rows[:MAX_DROPS]]


def _node(name: str, knowledge, region: str | None) -> list[tuple[int, int, str]]:
    if knowledge is None or not hasattr(knowledge, "node_facts"):
        return []
    try:
        f = knowledge.node_facts(name)
    except Exception:  # knowledge is best effort
        return []
    if not f:
        return []
    loc = f.get("location") or ""
    tier = NEAR if region and region in [x.strip() for x in loc.split(",")] else LATER
    bits = [b for b in (loc and f"found in {loc}", f.get("tool") and f"tool: {f['tool']}") if b]
    return [(tier, 2, _clip(f"node: {f['title']}" + (f" ({'; '.join(bits)})" if bits else "")))]


def _traders(item: str, have: dict[str, int]) -> list[tuple[int, int, str]]:
    from .knowledge import vendor_station
    cat = _catalog()
    stations = cat.get("stations") or {}
    out = []
    for rid, r in (cat.get("recipes") or {}).items():
        sids = r.get("stations") or []
        outs = [o for o in r.get("outputs") or [] if o.get("item") == item]
        if not outs or not sids or not all(vendor_station(s, stations) for s in sids) or r.get("test"):
            continue
        who = " or ".join(dict.fromkeys((stations.get(s) or {}).get("display_name") or s for s in sids))
        price = [(i.get("item"), i.get("name") or i.get("item"), int(i.get("count") or 1)) for i in r.get("inputs") or []]
        enough = all(have.get(i, 0) >= n for i, _, n in price)
        carry = ", ".join(f"{have.get(i, 0)} {nm}" for i, nm, _ in price)
        line = (f"trader {who}: {int(outs[0].get('count') or 1)} for "
                + " + ".join(f"{n} {nm}" for _, nm, n in price) + (f" (you carry {carry})" if carry else ""))
        out.append((NEAR if enough else LATER, 3, _clip(line)))
    return out


TRADER = 3


def _rows(item: str, name: str, *, state=None, spells=None, knowledge=None, places=None) -> list[tuple[int, int, str]]:
    """(tier, kind, line) for every non-crafting way to get ``item`` (id) / ``name``, can-do-now first (MAX_PER_ITEM)."""
    sight, region, have = _in_sight(state), _region(state, places), counts(state)
    rows = _spells(name, spells) + _drops(name, sight, region) + _node(name, knowledge, region) + _traders(item, have)
    rows.sort(key=lambda r: (r[0], r[1]))  # by what he can do now, then spell / drop / node / trader
    return rows[:MAX_PER_ITEM]


def sources_of(item: str, name: str, **kw) -> list[str]:
    """Every non-crafting way to get ``item`` (id) / ``name`` the data knows, can-do-now first (MAX_PER_ITEM)."""
    return [line for _, _, line in _rows(item, name, **kw)]


# ------------------------------------------------------------------------------ the plan


def _nodes(n: Any, depth: int = 0):
    if not isinstance(n, dict) or depth > 12:
        return
    yield n
    for c in n.get("inputs") or []:
        yield from _nodes(c, depth + 1)


def _trader_recipe(rid: str | None) -> bool:
    from .knowledge import vendor_station
    if not rid:
        return False
    cat = _catalog()
    r = (cat.get("recipes") or {}).get(rid) or {}
    sids = r.get("stations") or []
    return bool(sids) and all(vendor_station(s, cat.get("stations") or {}) for s in sids)


def _wants_sources(n: dict) -> bool:
    if n.get("status") == "have" or not n.get("item"):
        return False
    return n.get("status") in LEAF or _trader_recipe(n.get("recipe"))


def _ids_by_name() -> dict[str, str]:
    """{lowercased item display name: item id} from the catalog (the first id of a name)."""
    by_name: dict[str, str] = {}
    for iid, it in (_catalog().get("items") or {}).items():
        if isinstance(it, dict) and it.get("name"):
            by_name.setdefault(it["name"].lower(), iid)
    return by_name


def _build_fact(step: dict, knowledge, have: dict[str, int]) -> dict | None:
    name = step.get("name") or step.get("station")
    if not name or knowledge is None or not hasattr(knowledge, "build_facts"):
        return None
    try:
        f = knowledge.build_facts(str(name))
    except Exception:  # knowledge is best effort
        return None
    if not f:
        return None
    by_name = _ids_by_name()
    carry, short = [], []
    for nm, n in f["cost"]:
        iid = by_name.get(nm.lower())
        if iid is not None:
            carry.append(f"{have.get(iid, 0)} of {n} {nm}")
            if have.get(iid, 0) < n:
                short.append({"item": iid, "name": nm, "count": n - have.get(iid, 0)})
    out = {"piece": f["title"], "wiki": _clip(f"built from the build menu ({f['skill'] or 'Construction'}): "
                                              + " + ".join(f"{n} {nm}" for nm, n in f["cost"]))}
    if f.get("unlock"):
        out["unlock"] = _clip(f"wiki: {f['unlock']}")
    if step.get("build_unlocked") is False:
        out["unlocked"] = False
    if carry:
        out["you_carry"] = ", ".join(carry)
    if short:
        out["short_items"] = short
    return out


# ------------------------------------------------------------------------------ a build's short things
# Thread study 2026-11-18 (run 053839, planner state row 29): craft_plan Bone Pickaxe named Coarse Thread only in the
# Tannery's build cost ("I'm short of 11 Ash Logs + 2 Coarse Thread"). Nothing said thread is spun from the 7 Coarse
# Animal Fur he carried, at a Spinning Wheel he can build; the Planner asked the player for thread (5 of 6 replays).
# A build's short things now get the facts a failed craft's missing inputs get (``missing_facts``).

_SHORT_PART = re.compile(r"^\s*(\d+)\s+(.+?)\s*$")


def _build_short(build: dict) -> list[dict]:
    """The things a find_station ``build`` is short of, as {item, name, count}: the client's ``short_items``, or its
    ``short`` text ("11 Ash Logs + 2 Coarse Thread", from a client without the rows) read by item name, or the wiki
    build's own rows (``_build_fact``)."""
    rows = build.get("short_items")
    if isinstance(rows, list):
        return [r for r in rows if isinstance(r, dict) and isinstance(r.get("item"), str)]
    if not isinstance(build.get("short"), str):
        return []
    by_name, out = _ids_by_name(), []
    for part in build["short"].split(" + "):
        m = _SHORT_PART.match(part)
        iid = m and by_name.get(m.group(2).lower())
        if iid:
            out.append({"item": iid, "name": m.group(2), "count": int(m.group(1))})
    return out


def _build_sources(data: dict, found: dict, *, state=None, spells=None, knowledge=None, places=None) -> list[str]:
    """``short_sources`` ({name: lines}, ``missing_facts``) on each find_station ``build`` for the short things the
    plan gives no way to (not an input it gathers, obtains or crafts, not one it already named sources for). Bounded
    as ``missing_facts`` across the whole plan. The names that got lines."""
    covered = {n["item"] for n in _nodes(data["root"]) if n.get("item") and n.get("status") != "have"}
    done: set[str] = set()
    for st in data.get("steps") or []:
        b = st.get("build") if isinstance(st, dict) and st.get("do") == "find_station" else None
        if not isinstance(b, dict):
            continue
        rows = [r for r in _build_short(b) if r["item"] not in covered and str(r.get("name") or r["item"]) not in found
                and r["item"] not in done]
        b.pop("short_items", None)
        rows = rows[: max(0, MISSING_ITEMS - len(done))]
        if not rows:
            continue
        got = missing_facts(rows, state=state, spells=spells, knowledge=knowledge, places=places)
        done |= {r["item"] for r in rows}
        if got:
            b["short_sources"] = got
    names: list[str] = []
    for st in data.get("steps") or []:
        b = st.get("build") if isinstance(st, dict) else None
        if isinstance(b, dict) and isinstance(b.get("short_sources"), dict):
            names += list(b["short_sources"])
    return names


def _to_obtain(data: dict, n: dict, lines: list[str]) -> None:
    """A thing whose plan path is a trader he can't pay, while the game has other ways to it: the thing is to be
    obtained (its sources, the trader one of them), not the trader's currency first. The trader's recipe stays listed
    as an alternative; its steps (the currency to obtain, finding the trader, buying) and missing rows go."""
    sub_items: dict[str, int] = {}
    sub_recipes = set()
    for c in _nodes(n):
        if c is not n and c.get("item"):
            sub_items[c["item"]] = sub_items.get(c["item"], 0) + 1
        if c.get("recipe"):
            sub_recipes.add(c["recipe"])
    every: dict[str, int] = {}
    for c in _nodes(data["root"]):
        if c.get("item"):
            every[c["item"]] = every.get(c["item"], 0) + 1
    only = {i for i, k in sub_items.items() if every.get(i, 0) == k}
    steps, at, kept = data.get("steps") or [], None, []
    for i, st in enumerate(steps):
        gone = isinstance(st, dict) and (st.get("recipe") in sub_recipes
                                         or (st.get("do") in ("obtain", "gather") and st.get("item") in only))
        if gone and at is None:
            at = len(kept)
        if not gone:
            kept.append(st)
    count = n.get("short") or n.get("need") or 1
    step = {"do": "obtain", "item": n["item"], "name": n.get("name"), "count": count, "sources": lines}
    kept.insert(len(kept) if at is None else at, step)
    data["steps"] = kept
    data["missing"] = [m for m in data.get("missing") or [] if not (isinstance(m, dict) and m.get("item") in only)]
    data["missing"].append({"item": n["item"], "name": n.get("name"), "count": count})
    alt = {"recipe": n.get("recipe"), "status": "trader", "station": n.get("station_name") or n.get("station"),
           "detail": n.get("detail")}
    for k in ("recipe", "inputs", "station", "station_name", "station_id", "kind", "crafts", "detail", "unlock"):
        n.pop(k, None)
    n["status"] = "obtain"
    n["alternatives"] = [alt, *(n.get("alternatives") or [])]


# ------------------------------------------------------------------------------ the item's own card
# Planner stone study 2026-11-18 (runs 053839, 054931): craft_plan "Pickaxe" named 8 candidates as {name, status, item}
# and craft_plan Stone Pickaxe read "missing: []"; nothing on either said what a Stone Pickaxe mines. The Planner made a
# Stone Pickaxe first 3 of 3 for a copper job; a replay with the cards on the rows: 0 of 3.

CARD_CHARS = 240


def item_card(item: str | None, name: str | None = None) -> str | None:
    """'<name> (<category>, tier N): <description>' from the game's item data (data/items_<build>.json: ``category``,
    ``tier``, ``flavour``), or None when the data has neither a tier nor a description for ``item``."""
    from . import item_stats
    e = item_stats.catalog().get(item) if item else None
    if not e:
        return None
    flav = re.sub(r"\{[A-Za-z]+\}", "", str(e.get("flavour") or "")).strip()
    tier = e.get("tier")
    if not flav and not tier:
        return None
    what = ", ".join(str(b) for b in (e.get("category"), tier and f"tier {tier}") if b)
    card = f"{name or e.get('name') or item}" + (f" ({what})" if what else "") + (f": {flav}" if flav else "")
    return card if len(card) <= CARD_CHARS else card[: CARD_CHARS - 1].rsplit(" ", 1)[0] + "…"


def _carded(row: dict) -> tuple[dict, str | None]:
    """``row`` with ``is`` (its item card) right after its name or its item, whichever comes first, so it is read
    before the rest (a plan's root lists its name after the whole input tree)."""
    card = item_card(row.get("item"), row.get("name")) if isinstance(row.get("item"), str) else None
    if card is None or row.get("is") == card:
        return row, None
    after = next(k for k in row if k in ("name", "item"))
    out: dict = {}
    for k, v in row.items():
        if k != "is":
            out[k] = v
        if k == after:
            out["is"] = card
    return out, str(row.get("name") or row.get("item"))


def add_cards(data: dict) -> list[str]:
    """``is`` on the root of a plan and on each ``candidates`` row (in place); the names that got one."""
    named: list[str] = []
    if isinstance(data.get("root"), dict):
        data["root"], nm = _carded(data["root"])
        named += [nm] if nm else []
    if isinstance(data.get("candidates"), list):
        rows = []
        for c in data["candidates"]:
            if isinstance(c, dict):
                c, nm = _carded(c)
                named += [nm] if nm else []
            rows.append(c)
        data["candidates"] = rows
    return named


def enrich(data: dict, *, state=None, spells=None, knowledge=None, places=None, log=None, via: str | None = None) -> dict:
    """Add the sources of what the plan can't craft (on its obtain steps; ``sources`` for the rest) and find_station
    ``build`` facts to a craft_plan result's data (in place; returned). ``log``: a JsonlLogger for the plan_sources
    line (what was added), when anything was."""
    if not isinstance(data, dict) or not isinstance(data.get("root"), dict):
        return data
    have = counts(state)
    converted: list[str] = []
    found: dict[str, list[str]] = {}
    for n in _nodes(data["root"]):
        name = str(n.get("name") or n.get("item"))
        if name in found or len(found) >= MAX_ITEMS or not _wants_sources(n):
            continue
        try:
            rows = _rows(n["item"], name, state=state, spells=spells, knowledge=knowledge, places=places)
        except Exception:  # data is best effort: the plan stands without it
            rows = []
        if not rows:
            continue
        found[name] = [line for _, _, line in rows]
        payable = any(k == TRADER and t < LATER for t, k, _ in rows)
        if _trader_recipe(n.get("recipe")) and not payable and any(k != TRADER for _, k, _ in rows):
            _to_obtain(data, n, found[name])
            converted.append(name)
    on_steps = set()
    for st in data.get("steps") or []:
        if isinstance(st, dict) and st.get("do") == "obtain" and st.get("name") in found:
            st["sources"] = found[st["name"]]
            on_steps.add(st["name"])
    rest = {k: v for k, v in found.items() if k not in on_steps}
    if rest:
        data["sources"] = rest
    for st in data.get("steps") or []:
        if not isinstance(st, dict) or st.get("do") != "find_station":
            continue
        if not st.get("build"):
            b = _build_fact(st, knowledge, have)
            if b:
                st["build"] = b
        st.pop("build_unlocked", None)
    try:
        build_src = _build_sources(data, found, state=state, spells=spells, knowledge=knowledge, places=places)
    except Exception:  # data is best effort: the plan stands without it
        build_src = []
    builds = [st.get("name") for st in data.get("steps") or [] if isinstance(st, dict) and st.get("do") == "find_station"
              and isinstance(st.get("build"), dict) and "wiki" in st["build"]]
    try:
        cards = add_cards(data)
    except Exception:  # the plan stands without them
        cards = []
    _log(log, found, converted, builds, cards, via, build_src)
    return data


def _log(log, found, converted, builds, cards, via, build_src=None) -> None:
    if log is not None and (found or builds or cards or build_src):
        log.log("plan_sources", sources=sorted(found), trader_to_obtain=converted, wiki_builds=builds,
                **({"build_sources": sorted(build_src)} if build_src else {}),
                **({"cards": cards} if cards else {}), **({"via": via} if via else {}))


AMBIGUOUS = "ambiguous_target"


def enriches(res) -> bool:
    """A craft_plan result these facts go on: an ok plan, or a name that could be several things (its candidates)."""
    return isinstance(res, dict) and isinstance(res.get("data"), dict) and (
        bool(res.get("ok")) or res.get("reason") == AMBIGUOUS)


def enrich_result(res: dict, **kw) -> dict:
    """``enrich`` on an ok craft_plan tool result; an ambiguous name's candidates get their item cards; any other
    result unchanged."""
    if not enriches(res):
        return res
    try:
        if res.get("ok"):
            enrich(res["data"], **kw)
        else:
            _log(kw.get("log"), {}, [], [], add_cards(res["data"]), kw.get("via"))
    except Exception:  # never break a read on the facts it adds
        pass
    return res


def enrich_for(res: dict, ctl, state: dict | None, log=None, via: str | None = None) -> dict:
    """``enrich_result`` with what the Controller ``ctl`` knows (its knowledge index, map names, castable spells): the
    one way every brain caller of craft_plan gets these facts (the Controller's read, the Director's body read, the
    Planner's research). Runs on the agent loop's thread (castable spells may read the body)."""
    try:
        spells = ctl.castable_spells() if (ctl.has("spells") or ctl.has("cast")) else None
    except Exception:  # the facts that need no spells still come
        spells = None
    return enrich_result(res, state=state or {}, spells=spells, knowledge=getattr(ctl, "knowledge", None),
                         places=getattr(ctl, "places", None), log=log, via=via)


def body_read(agent, tool: str, args: dict, via: str | None = None) -> dict:
    """A body read as a brain caller off the Controller's turn gets it (the Director's reads, the Planner's research
    through its BodyProxy): the client's answer; a craft_plan's with ``enrich_for`` over fresh state. Park study
    2026-11-18 (run 053839): the Planner's craft_plan Bone Pickaxe went through the raw client call and read "24 Garou
    Chit, trader Iasadair", while the same read enriched showed Bark to Bones, Deer drops and a buildable Tannery; it
    chose the Stone Pickaxe, which cannot mine copper. None of three windows had a plan_sources row."""
    res = agent.game.call(tool, args)
    if tool == "craft_plan" and enriches(res):
        try:
            state = agent._fresh_state(reuse=True)
        except Exception:  # a state that can't be read leaves the facts that don't need it
            state = {}
        res = enrich_for(res, agent.controller, state, log=getattr(agent, "log", None), via=via)
    return res


# ------------------------------------------------------------------------------ a craft that failed short
# Live 2026-11-18 00:08Z (logs/brain-live-20261118-010135-17424.jsonl, 389 s): craft Bone Pickaxe failed "I need 8
# Animal Bone ... and 4 Leather and I have 0" and said nothing of where they come from; he said "the bone pickaxe
# needs stuff we don't have", went to mine copper with his stone pickaxe and died. craft_plan knew: Bark to Bones was
# his, cows and deer drop bone and hide, the Tannery is a build-menu piece. The failed craft now carries the same
# facts for what it lacks, from the same functions (``_rows``, ``_build_fact``), shorter.

MISSING_ITEMS = 4
MISSING_PER_ITEM = 3
MISSING_CHARS = 700


def _station_near(sids: list[str], names: list[str], state: dict | None) -> bool:
    want = {s.lower() for s in sids} | {n.lower() for n in names}
    for s in (state or {}).get("stations_nearby") or []:
        if isinstance(s, dict) and ({str(s.get("station") or "").lower(), str(s.get("name") or "").lower()} & want):
            return True
    return False


def _made(item: str, *, state=None, knowledge=None) -> tuple[list[str], list[tuple[str, str]]]:
    """How a recipe (not a trader's, not one that takes the thing itself) makes ``item``: one line per station, with
    what of each input he carries, then for a station not near him its build-menu facts (craft_plan's find_station
    ``build``). Also the inputs he carries none of (id, name). ([], []) when nothing makes it."""
    from .knowledge import vendor_station
    cat = _catalog()
    stations = cat.get("stations") or {}
    have = counts(state)
    unlocked = (state or {}).get("recipes_unlocked")
    unlocked = set(unlocked) if isinstance(unlocked, list) else None
    by_station: dict[tuple, list[tuple[bool, str]]] = {}
    lacking: list[tuple[str, str]] = []
    for rid, r in sorted((cat.get("recipes") or {}).items()):
        sids = [s for s in r.get("stations") or [] if isinstance(s, str)]
        ins = [i for i in r.get("inputs") or [] if isinstance(i, dict) and i.get("item")]
        if r.get("test") or not ins or not any(o.get("item") == item for o in r.get("outputs") or []):
            continue
        if (sids and all(vendor_station(s, stations) for s in sids)) or any(i["item"] == item for i in ins):
            continue
        names = list(dict.fromkeys((stations.get(s) or {}).get("display_name") or s for s in sids
                                   if (stations.get(s) or {}).get("display_name")))
        words = " + ".join(f"{int(i.get('count') or 1)} {i.get('name') or i['item']} (you carry {have.get(i['item'], 0)})"
                           for i in ins)
        if unlocked is not None and rid not in unlocked:
            words += ", not unlocked yet"
        enough = all(have.get(i["item"], 0) >= int(i.get("count") or 1) for i in ins)
        by_station.setdefault((tuple(sids), tuple(names)), []).append((not enough, words))
        for i in ins:
            if have.get(i["item"], 0) == 0 and (i["item"], i.get("name") or i["item"]) not in lacking:
                lacking.append((i["item"], i.get("name") or i["item"]))
    lines = []
    for (sids, names), ways in by_station.items():
        ways.sort()
        where = f"made at {' or '.join(names[:2])}" if names else "made"
        lines.append(_clip(f"{where} from " + " or ".join(w for _, w in ways[:2])))
        if names and not _station_near(list(sids), list(names), state):
            b = _build_fact({"name": names[0]}, knowledge, have)
            if b:
                cost = b["wiki"].split(": ", 1)[-1]
                lines.append(_clip(f"{names[0]}: none near you; a build-menu piece, {cost}"
                                   + (f" (you carry {b['you_carry']})" if b.get("you_carry") else "")))
    return lines, lacking


def missing_facts(missing: list[dict] | None, *, state=None, spells=None, knowledge=None, places=None) -> dict[str, list[str]]:
    """{name: lines} for the inputs a failed craft lacks: a thing a recipe makes gets where and from what (and the
    sources of an input he carries none of); anything else the sources craft_plan gives it (``_rows``). A row with
    gathered_before (he has gathered it: its spots say where) gets nothing. Bounded: MISSING_ITEMS items,
    MISSING_PER_ITEM lines each, LINE_CHARS a line."""
    out: dict[str, list[str]] = {}
    for m in missing or []:
        if len(out) >= MISSING_ITEMS:
            break
        if not isinstance(m, dict) or not isinstance(m.get("item"), str) or m.get("gathered_before"):
            continue
        name = str(m.get("name") or m["item"])
        try:
            lines, lacking = _made(m["item"], state=state, knowledge=knowledge)
            if not lines:
                lines = [line for _, _, line in _rows(m["item"], name, state=state, spells=spells, knowledge=knowledge,
                                                      places=places)]
            else:
                for iid, iname in lacking[:1]:
                    sub = _rows(iid, iname, state=state, spells=spells, knowledge=knowledge, places=places)
                    lines += [_clip(f"{iname}: {line}") for _, _, line in sub[:1]]
        except Exception:  # data is best effort: the failure stands without it
            lines = []
        if lines:
            out[name] = lines[:MISSING_PER_ITEM]
    return out


def missing_line(found: dict[str, list[str]]) -> str | None:
    """The words added to the failed craft's result: 'Where the missing things come from: <name>: a | b. <name>: ...'"""
    if not found:
        return None
    text = "Where the missing things come from: " + " ".join(f"{k}: {' | '.join(v)}." for k, v in found.items())
    return text if len(text) <= MISSING_CHARS else text[: MISSING_CHARS - 1].rsplit(" ", 1)[0] + "…"


def enrich_craft_failure(data: dict, *, state=None, spells=None, knowledge=None, places=None, log=None) -> str | None:
    """On a craft result's data with ``missing`` rows: each row gets ``sources`` (``missing_facts``); returns the line
    for the step's result words (``missing_line``) and logs craft_sources, or None when nothing was added."""
    if not isinstance(data, dict) or not isinstance(data.get("missing"), list):
        return None
    found = missing_facts(data["missing"], state=state, spells=spells, knowledge=knowledge, places=places)
    for m in data["missing"]:
        if isinstance(m, dict) and str(m.get("name") or m.get("item")) in found:
            m["sources"] = found[str(m.get("name") or m.get("item"))]
    line = missing_line(found)
    if line and log is not None:
        log.log("craft_sources", item=data.get("item"), sources=list(found), chars=len(line))
    return line



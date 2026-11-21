"""What a fishing spot gives, for the supplies block's sources line: perception from data, no advice.

Luis 2026-11-21: he must know fish is a food source. The `fish` tool nets fish end to end (DISCOVERIES "Live checks:
fishing", 2026-10-26: 2 Raw Shrimp in 17.8 s); a rod casts and hooks, but the fight is lost to stamina.

  catch     what a spot yields in the province it stands in: the wiki mirror's DropsLine rows, split by the page's own
            "===<Province>===" headings (data/wiki/pages/12819.json Net Fishing Spot, 12818.json Rod Fishing Spot; the
            mirror's flattened ``sections`` lose those headings, its ``wikitext`` keeps them). The page is found by the
            spot's own DisplayNameText, which is the page title ("Net Fishing Spot").
  where     the spot's region and province from its position (brain/places.py over data/places_<build>.json); when its
            position is not known, the province its blueprint class names (BP_FishingNodeV2_Net_Brynmoor_C), matched
            against the province names in the same map data. The catch tables are per province (the wiki's own split).
  tool      the spot's tool by its method word: the body's ``method`` is the last segment of the node's
            CompatibleToolCategory tag (fishing.lua method_of), and a carried item fits when its own category tag ends
            in the same segment (DISCOVERIES: the node tag IS the item Category tag, "Item.Equipment.Tool.Fishing.Net");
            without one, the recipes that make one (recipe catalog), whether each is unlocked, and the skill level its
            unlock query asks ("SKILL LEVEL 3[ Fishing ]" on the Ash Rod).
  facts     what the spot pages say in prose: catches per spot and the respawn ("Each fishing spot has 10-15
            catches ... Depleted fishing spots respawn after 72 in-game hours", Net Fishing Spot rev 66829), and any
            "level N in <Skill>" sentence (Rod Fishing Spot rev 74795: pristine fish at Fishing 17). Each with its rev.

Nothing here ranks a spot or says to fish; the model judges.
"""
from __future__ import annotations

import json
import re
from functools import lru_cache
from typing import Any

DROPS = re.compile(r"\{\{\s*DropsLine\s*\|([^}]*)\}\}", re.I)
H3 = re.compile(r"^===\s*([^=].*?)\s*===\s*$", re.M)  # exactly three '=': the province headings under Loot
H4 = re.compile(r"^====\s*([^=].*?)\s*====\s*$", re.M)
CATCH_HEAD = "fish catch"  # the page's own sub-heading over the fish rows (the other is "Junk pool")
UAID = re.compile(r"^([A-Za-z0-9_]+?)_UAID_[0-9A-Fa-f]+_\d+$")  # placed level actor: <Class>_UAID_<hex>_<n> (client_bridge)


# ------------------------------------------------------------------------------------------------ the wiki


@lru_cache(maxsize=16)
def page(title: str) -> dict:
    """The mirror's page for a title (data/wiki/manifest.json; DW_WIKI_DIR honoured), {} when absent."""
    from .knowledge import wiki_dir
    try:
        root = wiki_dir()
        rec = ((json.loads((root / "manifest.json").read_text(encoding="utf-8")).get("pages") or {}).get(title) or {})
        return json.loads((root / rec["file"]).read_text(encoding="utf-8")) if rec.get("file") else {}
    except (OSError, ValueError, KeyError):
        return {}


def _src(p: dict) -> str:
    return f"wiki {p.get('title')} rev {p.get('revid')}"


def _rows(text: str) -> list[dict]:
    out = []
    for m in DROPS.finditer(text):
        f = {k.strip().lower(): v.strip() for k, v in (x.split("=", 1) for x in m.group(1).split("|") if "=" in x)}
        if f.get("name"):
            q = re.findall(r"\d+", f.get("quantity") or "1")
            r = re.fullmatch(r"\s*([\d.]+)\s*/\s*(\d+)\s*", f.get("rarity") or "")
            out.append({"name": f["name"], "qty": int(q[0]) if q else 1,
                        "chance": round(float(r.group(1)) / float(r.group(2)), 4) if r and float(r.group(2)) else None})
    return out


@lru_cache(maxsize=16)
def catch_tables(title: str) -> dict[str, list[dict]]:
    """{province heading: [fish rows {name, qty, chance}]} from the page's wikitext ("===Brynmoor===" then
    "====Fish catch===="). {} when the page or the split is missing."""
    wt = page(title).get("wikitext") or ""
    heads = list(H3.finditer(wt))
    out: dict[str, list[dict]] = {}
    for i, h in enumerate(heads):
        body = wt[h.end():heads[i + 1].start() if i + 1 < len(heads) else len(wt)]
        body = body.split("\n== ", 1)[0]  # the next level-2 section (Update history) ends the last province
        subs = list(H4.finditer(body))
        for j, s in enumerate(subs):
            if s.group(1).strip().lower() == CATCH_HEAD:
                rows = _rows(body[s.end():subs[j + 1].start() if j + 1 < len(subs) else len(body)])
                if rows:
                    out[h.group(1).strip()] = rows
    return out


def catch(title: str, province: str | None) -> tuple[list[dict], str] | None:
    """(the fish rows of this spot in this province, source words), None when the wiki has no table for it."""
    if not province:
        return None
    rows = catch_tables(title).get(province)
    return (rows, _src(page(title))) if rows else None


@lru_cache(maxsize=16)
def spot_prose(title: str) -> dict:
    """What the spot page's lead says: {catches: '10-15', respawn: '72 in-game hours', gates: [(skill, level, words)],
    src}. Generic patterns over the prose; a page that does not say it gives nothing (the rod page names no count)."""
    p = page(title)
    secs = p.get("sections") or []
    lead = " ".join(str(s.get("text") or "") for s in secs if s.get("heading") in (None, "Loot"))
    out: dict[str, Any] = {"src": _src(p)} if p else {}
    if m := re.search(r"(\d+\s*-\s*\d+|\d+) catches", lead):
        out["catches"] = m.group(1).replace(" ", "")
    if m := re.search(r"respawn after ([\d.]+ in-game \w+)", lead):
        out["respawn"] = m.group(1)
    gates = []
    for m in re.finditer(r"level (\d+) in (\w+) to (?:be able to )?([^.]+)\.", lead):
        gates.append((m.group(2), int(m.group(1)), m.group(3).strip()))
    if gates:
        out["gates"] = gates
    return out


# ------------------------------------------------------------------------------------------------ where


@lru_cache(maxsize=1)
def _places():
    from .places import Places
    return Places()


def class_of(spot_id: str | None) -> str | None:
    """The blueprint class of a placed actor from its instance name ('BP_FishingNodeV2_Net_Brynmoor_C_UAID_..._1131309019'
    -> 'BP_FishingNodeV2_Net_Brynmoor_C'), the same rule as client_bridge find_actor_by_id."""
    m = UAID.match(str(spot_id or ""))
    return m.group(1) if m else None


def where(position=None, cls: str | None = None, places=None) -> dict:
    """{region?, province?, by: 'position'|'class'} of a spot: the map region at its position, else the province its
    class names (a whole '_<Province>_' token of the class, the province names from the same map data)."""
    pl = places if places is not None else _places()
    if isinstance(position, (list, tuple)) and len(position) >= 2:
        r = pl.region_at(position)
        if r:
            return {"region": r.get("name"), "province": r.get("province"), "by": "position"}
    if cls:
        tokens = "_" + str(cls) + "_"
        for p in pl.provinces:
            name = str(p.get("name") or "")
            if name and "_" + name.replace(" ", "") + "_" in tokens:
                return {"province": name, "by": "class"}
    return {}


# ------------------------------------------------------------------------------------------------ tools


def method_of(tag: str | None) -> str | None:
    """fishing.lua method_of: the last segment of a gameplay tag, lower case ('Item.Equipment.Tool.Fishing.Net' -> 'net')."""
    return str(tag).rsplit(".", 1)[-1].lower() if tag else None


def carried_tools(state: dict, method: str) -> list[str]:
    """Names of the carried items whose category tag ends in this method's segment (fishing.lua tag_fits over the
    same tag family), not broken."""
    out = []
    for r in state.get("inventory_items") or []:
        if isinstance(r, dict) and method_of(r.get("category")) == method and r.get("broken") is not True:
            out.append(str(r.get("name") or r.get("item")))
    return list(dict.fromkeys(out))


def _skill_level(state: dict, skill: str) -> int | None:
    sk = state.get("skills")
    if isinstance(sk, dict):
        v = sk.get(skill)
        v = v.get("level") if isinstance(v, dict) else v
        return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None
    for s in sk or []:
        if isinstance(s, dict) and s.get("skill") == skill and isinstance(s.get("level"), (int, float)):
            return int(s["level"])
    return None


SKILL_GATE = re.compile(r"SKILL LEVEL (\d+)\[\s*([^\]]+?)\s*\]")


def tool_recipes(method: str, cat: dict, state: dict) -> list[dict]:
    """The recipes whose output is a tool of this method (the item's category tag), each {name, inputs, at, unlocked,
    gate: (skill, level) | None}; unlocked ones first, then by the item's durability (the catalog's own number)."""
    from .needs import _station_names
    items = cat.get("items") or {}
    unlocked = set(state["recipes_unlocked"]) if isinstance(state.get("recipes_unlocked"), list) else None
    out = []
    for rid, r in (cat.get("recipes") or {}).items():
        outs = r.get("outputs") or []
        e = items.get(outs[0].get("item")) if outs else None
        if not e or method_of(e.get("category")) != method:
            continue
        gate = None
        for b in (r.get("unlock") or {}).get("bundles") or []:
            if m := SKILL_GATE.search(str(b.get("query") or "")):
                gate = (m.group(2), int(m.group(1)))
        ins = ", ".join(f"{int(i.get('count') or 1)} {i.get('name')}" if int(i.get("count") or 1) > 1 else str(i.get("name"))
                        for i in r.get("inputs") or [])
        out.append({"id": rid, "name": outs[0].get("name") or e.get("name"), "inputs": ins,
                    "at": _station_names(r.get("stations") or [], cat),
                    "unlocked": None if unlocked is None else rid in unlocked, "gate": gate,
                    "durability": e.get("durability") or 0})
    out.sort(key=lambda x: (x["unlocked"] is not True, x["durability"]))
    return out


def tool_words(state: dict, method: str, cat: dict) -> str:
    """'net: Coarse Net on you' / 'net: none on you; Coarse Net from 2 Coarse Thread at a Crafting Table (unlocked)'
    / '...; Ash Rod from Ash Logs, Coarse Thread at a Crafting Table (Fishing 3, you are Fishing 1; not unlocked)'."""
    have = carried_tools(state, method)
    if have:
        return f"{method}: {', '.join(have[:2])} on you"
    rec = tool_recipes(method, cat, state)
    if not rec:
        return f"{method}: none on you, no recipe makes one in the data"
    r = rec[0]
    bits = []
    if r["gate"]:
        lvl = _skill_level(state, r["gate"][0])
        bits.append(f"needs {r['gate'][0]} {r['gate'][1]}" + (f", you are {lvl}" if lvl is not None else ""))
    if r["unlocked"] is not None:
        bits.append("unlocked" if r["unlocked"] else "not unlocked")
    return f"{method}: none on you; {r['name']} from {r['inputs']} at a {r['at']}" + (f" ({'; '.join(bits)})" if bits else "")


def facts_words(titles: list[str], state: dict) -> str | None:
    """The spot pages' own facts, once per line: 'fishing (wiki Net Fishing Spot rev 66829: 10-15
    catches a spot, each fish or junk, respawn 72 in-game hours after it runs out; Rod Fishing Spot rev 74795: Fishing
    17 to catch a pristine one (you are 3))'. A 'level N in <Skill>' sentence only when he is below it or his level is
    unknown. The net page's count and respawn are said for the net page only: the rod page gives none."""
    parts = []
    for t in dict.fromkeys(titles):
        p = spot_prose(t)
        if not p:
            continue
        bits = []
        if p.get("catches"):
            bits.append(f"{p['catches']} catches a spot, each fish or junk")
        if p.get("respawn"):
            bits.append(f"respawn {p['respawn']} after it runs out")
        for skill, lvl, what in p.get("gates") or []:
            mine = _skill_level(state, skill)
            if mine is None or mine < lvl:
                bits.append(f"{skill} {lvl} to {what}" + (f" (you are {mine})" if mine is not None else ""))
        parts.append(f"{t} rev {page(t).get('revid')}" + (": " + ", ".join(bits) if bits else ""))
    return ("fishing (wiki " + "; ".join(parts) + ")") if parts else None

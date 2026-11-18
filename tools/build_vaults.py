"""Per dragonkin vault, what a player reads before going in: where it is (region, province, the door's map position),
its power level, who lives inside and the boss (level, health there, weak to, attacks, drops, from the bestiary), what
its chests and effigies give, and what opens it (key, lever, statues, quest). Output: the ``vaults`` section of
data/bestiary.json, enriched in place, which lookup serves as before (tools/build_bestiary.py ``Bestiary`` / ``merge``:
the entry a query names comes first). Knowledge he consults; nothing here tells him what to do (no route, no order of
actions, advice sentences are dropped). Offline: no model, no game, no network. Goal item 3,
docs/GOAL-2026-11-17-long-jobs.md.

Every fact says where it came from:
* game: the door of Crasorak Kara read by his own client (``look`` rows of BP_InteractablePlayerTeleporter_C, its
  DisplayName "Crasorak Kara", prompt "Enter"; build 26161880, 2026-11-01/02; the same always-loaded actor is in the
  build 26574459 object dump, l. 275023; docs/research/2026-11-17-crasorak-route.md). Regions, provinces and their
  power from data/places_<build>.json (BP_MapRegion_C, build 26161880). The game's landmark registry (same file) for
  the Umbral Sands vault guardians. The vault registry count (AGameplayObjectRegistry.Dungeons, 32 entries on his
  client, build 26574459, UE4SS.log 2026-11-17 19:45:10Z; names not logged yet) and the server dump's 17 ADungeon
  actors are kept as counts only.
* wiki (data/wiki mirror, RuneScape: Dragonwilds Wiki, CC BY-NC-SA 3.0; page ids): the vault pages' ``{{Map}}`` centre
  (converted to game metres as game x = wiki y / 100, game y = wiki x / 100: 17 m from the live Crasorak door; a map
  view centre, good to about 50 m), lead, Location and Unlocking sections, update notes that name levers; the
  "Dragonkin Vault" page (live 2026-11-18, last edited 2026-11-01) for the two Umbral Sands vaults the mirror lists as
  TBA; "Kalphite Queen" (page 13941).
* metabot.gg (https://metabot.gg/en/dragonwilds/map/vaults, fetched 2026-11-18; "datamined from the current build"):
  per vault its floor-plan size, chest and trap counts and its boss. Kept beside the wiki where they disagree.

    .venv\\Scripts\\python.exe -m tools.build_vaults                     # enrich data/bestiary.json in place
    .venv\\Scripts\\python.exe -m tools.build_vaults --wiki C:\\gameserver\\data\\wiki
    .venv\\Scripts\\python.exe -m tools.build_vaults show "Crasorak Kara"

tools/build_bestiary.py ``build`` calls ``add_vaults`` after the regions, so a full rebuild keeps these fields.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

DATA = ROOT / "data"
BESTIARY = DATA / "bestiary.json"
WIKI_BASE = "https://dragonwilds.runescape.wiki/w/"
ENTRY_CHARS = 1500  # build_bestiary.ENTRY_CHARS
GAME_BUILD = "26574459"  # the server build current on 2026-11-18

# Doors read by his own client. Only a door his body has stood near is here; every other position is the wiki's map
# centre. Crasorak Kara: 23 look rows 2026-11-01 13:12Z to 11-02 08:19Z (logs/brain-20261101.jsonl l. 8973,
# logs/brain-20261102.jsonl l. 23602), logs/state/worlds/dev_farm/map_memory.json (seen 13 times).
GAME_DOORS: dict[str, dict] = {
    "Crasorak Kara": {"position": [374.58, 1918.74, -2.76], "prompt": "Enter", "build": "26161880",
                      "actor": "BP_InteractablePlayerTeleporter_C_UAID_18C04D97CB3D30D401_1397338720",
                      "seen": "his look rows 2026-11-01/02 (23 reads); the actor is always loaded (dump 26574459)"},
}

# The game's own count of vault-like places (not names): what a full registry read will have to name.
GAME_REGISTRY = {"dungeons_client": 32, "dungeon_actors_server_dump": 17, "teleporters_server_dump": 21,
                 "build": GAME_BUILD,
                 "src": "client UE4SS.log 2026-11-17 19:45:10Z 'vault_list n=32 source=registry complete=false'; "
                        "dumps/26574459/UE4SS_ObjectDump.txt (Dungeon_UAID_*, BP_InteractablePlayerTeleporter_C)"}

METABOT_URL = "https://metabot.gg/en/dragonwilds/map/vaults"
METABOT_FETCHED = "2026-11-18"
# name: (floor plan size, chests, traps, boss or None). "None listed" on the site is None here.
METABOT_VAULTS: dict[str, tuple[str, int, int, str | None]] = {
    "Skeklac Kara": ("218x198 m", 5, 150, "Vault Corruptor"),
    "Chaktan Kara": ("221x205 m", 7, 15, "Vault Pyroclast"),
    "Thishepen Kara": ("176x180 m", 7, 16, "Vault Archon"),
    "Crasorak Kara": ("164x196 m", 6, 15, "Vault Overlord"),
    "Kletterbuja Kara": ("141x177 m", 5, 10, None),
    "Vertentis Kara": ("174x161 m", 6, 0, None),
    "Takla Kara": ("152x146 m", 6, 0, "Vault Incinerator"),
    "Manafem Kara": ("308x308 m", 8, 0, "Kalphite Queen"),
    "Skekven Kara": ("211x230 m", 9, 10, None),
    "Kalistrakthen Kara": ("304x204 m", 8, 0, "Vault Striker"),
    "Uzzer Kara": ("211x228 m", 8, 13, None),
    "Vekchenven Kara": ("239x212 m", 10, 20, "Dragon Wolves and Zogre"),
}

# The two Umbral Sands vaults (update 0.12.0, 23 June 2026): the mirror (2026-10-25) lists them as TBA; the live
# "Dragonkin Vault" page (last edited 2026-11-01) names them. They have no wiki page of their own (404 on 2026-11-18).
LIVE_DV = 1315  # the wiki's "Dragonkin Vault" page id; its live revision (2026-11-18, last edited 2026-11-01)
UMBRAL: dict[str, dict] = {
    "Uzzer Kara": {
        "area": "Umbral Sands", "where": "north-east of Umbral Sands", "power_level": "7", "order": "11",
        "enemies_note": "The wiki lists no enemies. metabot.gg: 14 Vault Guardian statues that wake as you pass, 13 "
                        "explosive traps, a maze; no boss listed.",
        "landmarks": ["Vault Guardian", "Vault Guardian Prime"],
        "aliases": ["Uzzer vault", "Mirrors vault", "Umbral Sands vault"],
    },
    "Manafem Kara": {
        "area": "Umbral Sands", "where": "south-west of Umbral Sands (metabot.gg: a pyramid south of the Manafem "
                                         "Plains)", "power_level": "7", "order": "11",
        "enemies": [{"name": "Kalphite Worker", "amount": "43 (metabot.gg)"},
                    {"name": "Kalphite Soldier", "amount": "11 (metabot.gg)"},
                    {"name": "Kalphite Queen", "amount": "1"}],
        "boss": [{"creature": "Kalphite Queen", "power_level": "7", "health": "5500"}],
        "aliases": ["Kalphite vault", "Manafem vault", "Kalphite Queen vault"],
    },
}
# Kalphite Queen (wiki page 13941, mirror rev of 2026-10-19; live 2026-11-18 the same): not a bestiary creature yet.
KALPHITE_QUEEN = ("Kalphite Queen (power level 7, health 5500; can be immune to any attack style: a red shade blocks "
                  "Attack damage, a blue shade Magic damage, a green shade Ranged damage; two forms, the second flies; "
                  "respawn 2 days; always drops Greater Kalphite Wing 2-4, Kalphite Shell 5-8, Kalphite Ichor 6-12, "
                  "Poison Ichor 3-6)")

ENRICHED = ("map_centre", "door", "game_region", "province", "entry", "levers", "metabot")
ENTRY = re.compile(r"\b(locked|unlock\w*|opens?|opened|keys?|requires?|must be|effig\w*|statues?|levers?|blocked|"
                   r"cleared|mined?|cut through|vines|boulders?|soul rift\w*|windstep|drop down|waterfall|"
                   r"upstream|river|door|entrance|quest|involved)\b", re.I)
MAP_CENTRE = re.compile(r"\{\{\s*Map\s*\|[^{}]*?center\s*=\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)", re.I)


def wiki_url(title: str) -> str:
    return WIKI_BASE + title.replace(" ", "_")


def map_centre(wikitext: str) -> list[float] | None:
    """A vault page's ``{{Map|...|center=A,B}}`` in game metres: (B / 100, A / 100)."""
    m = MAP_CENTRE.search(wikitext or "")
    if not m:
        return None
    a, b = float(m.group(1)), float(m.group(2))
    return [round(b / 100, 1), round(a / 100, 1)]


def entry_facts(wikitext: str) -> list[str]:
    """Sentences about getting in: from the lead (after its first sentence), Location and Unlocking sections, and the
    rows of an "Unlocking" table. Advice sentences are dropped (build_bestiary.facts_only)."""
    from tools.build_bestiary import facts_only, plain, sections, sentences
    secs = sections(wikitext)
    out: list[str] = []
    lead = facts_only(sentences(plain(secs[0]["body"]))) if secs else []
    out += [s for s in lead[1:] if ENTRY.search(s) and not re.search(r"\brecipes?\b", s, re.I)]
    for sec in secs[1:]:
        h = (sec["heading"] or "").lower()
        if h.startswith("location") or "unlock" in h or "entr" in h:
            body = re.sub(r"\{\{\s*Map[^{}]*\}\}", "", sec["body"])
            rows = re.findall(r"^\|\s*([^|{}\n][^|\n]{8,})$", body, re.M)  # table cells: one statue per row
            text = plain(re.sub(r"^\{\|.*?^\|\}", "", body, flags=re.S | re.M))
            out += [s for s in facts_only(sentences(text)) if s]
            out += [plain(r).strip() for r in rows if not re.match(r"\s*(File|\[\[File)", r)]
    seen, keep = set(), []
    for s in out:
        s = re.sub(r"\s+", " ", s).strip()
        if s and s.lower() not in seen and not s.lower().startswith("map:"):
            seen.add(s.lower())
            keep.append(s)
    return keep


def lever_notes(wikitext: str) -> list[str]:
    """Update-history lines that name a lever or a sealed vault: what the game's patch notes say about its levers."""
    from tools.build_bestiary import plain
    out = []
    for m in re.finditer(r"\|\s*update\s*=\s*(.+?)(?=\n\s*\}\}|\n\s*\|\s*\w+\s*=)", wikitext or "", re.S):
        t = re.sub(r"\s+", " ", plain(m.group(1))).strip(" *")
        if re.search(r"\blever|sealed\b", t, re.I):
            out.append(t)
    # a walkthrough's own words for what a lever opens ("the lever is to open the final door"), as a fact, no route
    for m in re.finditer(r"\[?\[?levers?\]?\]?\s+(?:is\s+)?to\s+open\s+(?:the\s+)?([\w ]{2,30}?(?:door|gate))", wikitext or "", re.I):
        out.insert(0, f"A lever opens the {m.group(1).strip()} (walkthrough).")
    return list(dict.fromkeys(out))


def _variant(c: dict, vault: str, pl: str | None) -> dict | None:
    vs = c.get("variants") or []
    for v in vs:
        if v.get("label") == vault:
            return v
    for v in vs:
        if pl and str(v.get("power_level")) == str(pl):
            return v
    return vs[0] if len(vs) == 1 else None


def _short_attack(name: str, creature: str) -> str:
    n = re.sub("^" + re.escape(creature.replace(" ", "")), "", name, flags=re.I)
    n = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", n).strip()
    return n or name


def boss_line(b: dict, creatures: dict, vault: str, pl: str | None, short: int = 0) -> str:
    """'Vault Overlord (power level 2, health 1300 here; weak to Crush; immune to Poison, Bleed and Burning; attacks:
    ...; drops: ...)'. short: 1 no drops, 2 also attack names only from the wiki or three from the game."""
    from tools.build_regions import _and
    name = b["creature"]
    if name == "Kalphite Queen":
        return KALPHITE_QUEEN
    c = creatures.get(name)
    if not c:
        fx = [f"power level {b['power_level']}" if b.get("power_level") else "",
              f"health {b['health']}" if b.get("health") else "", f"weak to {b['weakness']}" if b.get("weakness") else ""]
        return name + (f" ({'; '.join(x for x in fx if x)})" if any(fx) else "")
    v = _variant(c, vault, pl)
    bits = []
    if v:
        bits.append(", ".join(x for x in (f"power level {v.get('power_level')}" if v.get("power_level") else "",
                                          f"health {v.get('health')}" if v.get("health") else "") if x) + " here")
    elif b.get("power_level") or b.get("health"):
        bits.append(", ".join(x for x in (f"power level {b.get('power_level')}" if b.get("power_level") else "",
                                          f"health {b.get('health')}" if b.get("health") else "") if x))
    weak = c.get("weak") or ([b["weakness"]] if b.get("weakness") else [])
    bits.append(f"weak to {_and(weak)}" if weak else "weak to: not known")
    if c.get("resist") and c["resist"] != ["None"]:
        bits.append(f"resists {_and(c['resist'])}")
    if c.get("immune"):
        bits.append(f"immune to {_and(c['immune'])}")
    att = [a["name"] for a in c.get("attacks") or [] if a.get("name")]
    game = c.get("game_attacks") or []
    if att:
        bits.append("attacks: " + ", ".join(att))
    if game and (not att or short < 2):
        g = [f"{_short_attack(a['name'], name)} {int(a['damage'][0])}" for a in game if a.get("damage")]
        if short >= 2:
            g = g[:3]
        if g:
            bits.append("game attack damage: " + ", ".join(g))
    if not att and not game:
        bits.append("attacks: not in the mirror")
    if short < 1:
        dr = c.get("drops") or []
        always = [f"{d['item']} {d['amount']}".strip() for d in dr if d.get("rate") == "always"]
        other = list(dict.fromkeys(d["item"] for d in dr if d.get("rate") != "always"))
        if always or other:
            bits.append("drops: " + ", ".join(always) + (" always" if always else "")
                        + (("; chance of " if always else "chance of ") + ", ".join(other) if other else ""))
    return f"{c['name']} ({'; '.join(bits)})"


def _region_power(regions: dict, name: str | None) -> Any:
    r = regions.get(name or "") or {}
    return (r.get("power_level") or {}).get("game")


def enrich(e: dict, regions: dict, places, page_text: str | None, pid: int | None, extra_pages: dict) -> dict:
    """Add place, door, entry, mechanism and metabot fields to one vault entry (in place). ``places``: a
    brain.places.Places over data/places_<build>.json, or None."""
    name = e["name"]
    src = e.setdefault("src", {})
    for f in ENRICHED:  # a rerun over an enriched file starts from the bestiary's own fields
        e.pop(f, None)
        src.pop(f, None)
    area = e.get("area")
    centre = map_centre(page_text) if page_text else None
    if centre:
        e["map_centre"] = {"position": centre, "src": f"wiki {wiki_url(name)} {{{{Map}}}} centre (page {pid})",
                           "accuracy_m": 50}
        src.setdefault("map_centre", [pid])
    door = GAME_DOORS.get(name)
    if door:
        e["door"] = {**door, "src": "game"}
        src.setdefault("door", ["game"])
    at = (door or {}).get("position") or centre
    if places is not None and at:
        r = places.region_at(at)
        if r:
            e["game_region"] = {"name": r["name"], "province": r.get("province"), "power_level": r.get("power"),
                                "build": places.build, "at": "door" if door else "wiki map centre"}
            src.setdefault("game_region", ["game"])
    prov = (regions.get(area or "") or {}).get("province") if area else None
    if not prov and e.get("game_region"):
        prov = e["game_region"]["province"]
    if prov:  # the region's province is the game's MapRegionTag (data/places_<build>.json)
        e["province"] = prov
        src["province"] = ["game"]
    facts = list(e.get("opens") or [])  # build_bestiary's own opening sentences first, then this page's entry facts
    if page_text:
        facts += [f for f in entry_facts(page_text) if f not in facts]
    if facts:
        e["entry"] = facts[:4]
        src["entry"] = list(dict.fromkeys((src.get("opens") or []) + ([pid] if page_text else [])))
    if page_text:
        levers = lever_notes(page_text)
        if levers:
            e["levers"] = levers[:2]
            src.setdefault("levers", [pid])
    for t, (txt, tpid) in extra_pages.items():
        e.setdefault("entry", []).append(txt)
        src.setdefault("entry", []).append(tpid)
    mb = METABOT_VAULTS.get(name)
    if mb:
        e["metabot"] = {"size": mb[0], "chests": mb[1], "traps": mb[2], "boss": mb[3], "url": METABOT_URL,
                        "fetched": METABOT_FETCHED}
        src.setdefault("metabot", ["metabot.gg"])
    al = set(e.get("aliases") or [])
    for reg in {area, (e.get("game_region") or {}).get("name")} - {None}:
        al |= {f"{reg} vault", f"vault in {reg}", f"{reg} dungeon"}
    e["aliases"] = sorted(al)
    return e


def umbral_entry(name: str, landmarks: list[dict]) -> dict:
    u = UMBRAL[name]
    e: dict[str, Any] = {"kind": "vault", "name": name, "title": name, "page": None, "area": u["area"],
                         "province": "Umbral Sands", "power_level": u["power_level"], "order": u["order"],
                         "lead": f"{name} is a dragonkin vault in the {u['where']}, added in update 0.12.0 (23 June 2026).",
                         "aliases": sorted(set(u["aliases"]) | {f"{name.split()[0]} kara"}),
                         "live_wiki": "Dragonkin Vault, read live 2026-11-18 (last edited 2026-11-01); no page of its own",
                         "src": {"area": [LIVE_DV], "province": ["game"], "power_level": [LIVE_DV], "order": [LIVE_DV],
                                 "lead": [LIVE_DV], "live_wiki": [LIVE_DV]}}
    if u.get("enemies"):
        e["enemies"] = u["enemies"]
        e["listed_enemies"] = {"common": ["Kalphite Worker", "Kalphite Soldier"], "notable": ["Kalphite Queen"]}
        e["src"]["enemies"] = [LIVE_DV, "metabot.gg"]
        e["src"]["listed_enemies"] = [LIVE_DV]
    if u.get("enemies_note"):
        e["enemies_note"] = u["enemies_note"]
        e["src"]["enemies_note"] = [LIVE_DV, "metabot.gg"]
    if u.get("boss"):
        e["boss"] = u["boss"]
        e["src"]["boss"] = [13941, "metabot.gg"]
    lms = [lm for lm in landmarks if lm.get("name") in (u.get("landmarks") or [])]
    if lms:
        e["game_landmarks"] = [{"name": lm["name"], "position": lm["position"], "region": lm.get("region")} for lm in lms]
        e["src"]["game_landmarks"] = ["game"]
    return e


def _pos_text(p: list[float]) -> str:
    return "(" + ", ".join(f"{x:.1f}" for x in p[:3]) + ")"


# What is dropped, in this order, while an entry is over ENTRY_CHARS: the least needed first.
SHRINK = ("resources", "lead", "boss_drops", "every_vault", "order", "centre_note", "chest_rolls", "boss_game_attacks",
          "region_power", "levers", "hazards", "entry_3", "entry_2", "boss_short", "entry_1")


def _province_text(area: str | None, prov: str | None) -> str:
    return f" ({prov})" if prov and prov != area else ""


def _power_text(p: Any) -> str:
    if isinstance(p, list):
        lo, hi = min(p), max(p)
        return str(lo) if lo == hi else f"{lo}-{hi}"
    return str(p)


def text_of(e: dict, creatures: dict, regions: dict) -> str:
    """What a player reads: facts only, each with its source, at most ENTRY_CHARS."""
    name, pl = e["name"], e.get("power_level")
    area, prov = e.get("area"), e.get("province")
    gr = e.get("game_region") or {}
    area_is_region = (regions.get(area or "") or {}).get("kind") == "region"

    def build(drop: set) -> str:
        p = []
        head = f"{name}: dragonkin vault in {area or 'an unnamed area'}" + _province_text(area, prov)
        head += f", power level {pl} [wiki]" if pl else ""
        if e.get("order") and "order" not in drop:
            head += f"; number {e['order']} in the wiki's standard order"
        rp = _region_power(regions, area)
        if rp is not None and "region_power" not in drop:
            head += f"; power level of {area} {_power_text(rp)} [game]"
        p.append(head + ".")
        if e.get("lead") and "lead" not in drop:
            p.append(e["lead"])
        d, mc = e.get("door"), e.get("map_centre")
        if d:
            s = (f"Door: {_pos_text(d['position'])} m, the game's teleporter \"{name}\", prompt \"{d['prompt']}\" "
                 f"[game, read by his client, build {d['build']}]")
            if mc and "centre_note" not in drop:
                dist = ((d["position"][0] - mc["position"][0]) ** 2 + (d["position"][1] - mc["position"][1]) ** 2) ** .5
                s += f"; the wiki map centre {_pos_text(mc['position'])} is {dist:.0f} m from it"
            p.append(s + ".")
        elif mc:
            s = f"Door: not read by the game yet; the wiki map centre is {_pos_text(mc['position'])} m (within about 50 m)"
            if gr:
                s += (f"; the game's region at that point: {gr['name']}{_province_text(gr['name'], gr.get('province'))}, "
                      f"power level {gr.get('power_level')}")
                if area_is_region and gr.get("name") != area:  # sources differ: both kept
                    s += f" (the wiki says {area})"
            p.append(s + ".")
        elif e.get("game_landmarks"):
            lm = e["game_landmarks"]
            p.append("Door: no position known. The game's map registry has " +
                     "; ".join(f"{x['name']} at {_pos_text(x['position'])} m" for x in lm[:3]) +
                     f" in {lm[0].get('region')} [game, build 26161880].")
        else:
            p.append("Door: no position known.")
        if d and gr and area_is_region and gr.get("name") != area:
            p.append(f"Sources differ: the wiki puts it in {area}; the game's map puts its door in {gr['name']}.")
        ent = e.get("entry") or []
        cap = 1 if "entry_2" in drop else 2 if "entry_3" in drop else 4
        if "entry_1" in drop:
            ent = [x[:160].rsplit(" ", 1)[0] + "…" if len(x) > 160 else x for x in ent[:1]]
        if ent:
            p.append("To get in [wiki]: " + " ".join(x if x.endswith((".", "…")) else x + "." for x in ent[:cap]))
        else:
            p.append("To get in: the wiki names no key, lever, statue or quest for the door.")
        if e.get("levers") and "levers" not in drop:
            p.append("Levers [wiki]: " + " ".join(e["levers"][:1]))
        en = e.get("enemies") or []
        if en:
            groups: dict[str, list[str]] = {}
            for r in en:
                g = f"power level {r['power_level']}" if r.get("power_level") else (r.get("group") or "")
                groups.setdefault(g, []).append(f"{r['name']} {r['amount']}".strip() if r.get("amount") else r["name"])
            p.append("Inside [wiki]: " + "; ".join((f"{g}: " if g else "") + ", ".join(v) for g, v in groups.items()) + ".")
        if e.get("enemies_note"):
            p.append(e["enemies_note"])
        if e.get("hazards") and "hazards" not in drop:
            p.append(f"Hazards [wiki]: {', '.join(e['hazards'])}.")
        bosses = e.get("boss") or []
        if bosses:
            short = 2 if "boss_short" in drop else 1 if "boss_drops" in drop else 0
            if short == 1 and "boss_game_attacks" in drop:
                short = 2
            p.append("Boss [wiki + game]: " + "; ".join(boss_line(b, creatures, name, pl, short) for b in bosses) + ".")
        else:
            p.append("Boss: none named on the wiki.")
        mb = e.get("metabot")
        if mb:
            wb = {b["creature"] for b in bosses}
            s = f"Datamined [metabot.gg, {mb['fetched']}]: {mb['chests']} chests, {mb['traps']} traps, floor plan {mb['size']}"
            if mb.get("boss") and mb["boss"] not in wb:
                s += f"; boss {mb['boss']}"
            elif not mb.get("boss") and wb:
                s += "; no boss listed"
            p.append(s + ".")
        loot = []
        if e.get("recipes"):
            loot.append(f"recipes learned here: {', '.join(e['recipes'])}")
        if e.get("notable_loot"):
            loot.append(f"notable loot: {', '.join(x.split(' Can be')[0] for x in e['notable_loot'])}")
        if loot:
            p.append("Gives [wiki]: " + "; ".join(loot) + ".")
        if e.get("chest_items"):
            from tools.build_bestiary import _chest_line
            p.append(_chest_line(e["chest_items"]))
        if e.get("chests"):
            c = e["chests"] if "chest_rolls" not in drop else \
                e["chests"].split(" Extra rolls")[0].split(". An additional")[0].rstrip(".") + "."
            p.append(f"Chests [wiki]: {c}")
        if e["name"] not in UMBRAL:
            p.append("Every vault [wiki]: vault shards in chests and from vault monsters" +
                     ("" if "every_vault" in drop else
                      "; 3 vault cores on plinths (50 kg each); a death inside leaves the grave at the outside entrance")
                     + ".")
        res = e.get("resources") or {}
        if res and "resources" not in drop:
            p.append("Resources [wiki]: " + "; ".join(f"{k}: {', '.join(v)}" for k, v in res.items() if v) + ".")
        p.append(_src_line(e))
        from tools.build_bestiary import _tidy
        return "\n".join(_tidy(x) for x in p if x)

    drop: set = set()
    text = build(drop)
    for step in SHRINK:
        if len(text) <= ENTRY_CHARS:
            return text
        drop.add(step)
        text = build(drop)
    if len(text) <= ENTRY_CHARS:
        return text
    return text[:ENTRY_CHARS - 1].rsplit(" ", 1)[0] + "…"


def _src_line(e: dict) -> str:
    ids = sorted({i for v in (e.get("src") or {}).values() for i in v if isinstance(i, int)})
    named = sorted({i for v in (e.get("src") or {}).values() for i in v if isinstance(i, str)})
    bits = [f"wiki pages {', '.join(map(str, ids))}"] if ids else []
    if e.get("live_wiki"):
        bits.append("page 1315 read live 2026-11-18")
    if "game" in named:
        bits.append("game map data")
    if "metabot.gg" in named:
        bits.append("metabot.gg vault map")
    return "Sources: " + "; ".join(bits) + "." if bits else ""


def add_vaults(doc: dict, mirror=None, places_path: Path | None = None) -> dict:
    """Enrich (replace the fields of) every vault in a bestiary doc and add the Umbral Sands vaults. ``mirror``: a
    build_bestiary.Mirror or None (then only the game and metabot fields are added)."""
    from brain.places import Places
    from tools.build_regions import newest_places
    places_path = places_path or newest_places()
    places = Places(places_path) if places_path and Path(places_path).exists() else None
    regions = doc.get("regions") or {}
    creatures = doc.get("creatures") or {}
    vaults = doc.setdefault("vaults", {})
    landmarks = (places.data.get("landmarks") if places is not None else None) or []
    for name in UMBRAL:
        vaults[name] = umbral_entry(name, landmarks)
    for name, e in vaults.items():
        if e.get("kind") != "vault":
            continue
        wt, pid, extra = None, e.get("page"), {}
        if mirror is not None:
            t = mirror.resolve(name)
            if t:
                wt, pid = mirror.wikitext(t), mirror.pid(t)
            if name == "Vertentis Kara":  # the door's own name is on the Spitfoot page (Cathan's journal)
                sp = mirror.resolve("Spitfoot")
                if sp and "blue-flamed door" in mirror.wikitext(sp):
                    extra["Spitfoot"] = ("Cathan's journal calls it \"the blue-flamed door in the swamps\"; Spitfoot "
                                         "was to bring him its keys (wiki: Spitfoot).", mirror.pid(sp))
        enrich(e, regions, places, wt, pid, extra)
        e["text"] = text_of(e, creatures, regions)
    doc["vault_registry"] = GAME_REGISTRY
    doc.setdefault("counts", {})["vaults"] = sum(1 for v in vaults.values() if v.get("kind") == "vault")
    doc["counts"]["vault_doors_game"] = sum(1 for v in vaults.values() if v.get("door"))
    _boss_reverse(doc)
    return doc


def _boss_reverse(doc: dict) -> None:
    """Each vault boss's creature entry names the vault's door and province ("Vault Overlord" -> where Crasorak Kara
    is). Appended once to the creature text when it fits the cap."""
    for name, v in (doc.get("vaults") or {}).items():
        if v.get("kind") != "vault":
            continue
        for b in v.get("boss") or []:
            c = (doc.get("creatures") or {}).get(b["creature"])
            if not c or not isinstance(c.get("text"), str):
                continue
            where = v.get("door", {}).get("position") or (v.get("map_centre") or {}).get("position")
            line = (f"{name} is in {v.get('area')}" + (f" ({v['province']})" if v.get("province") else "") +
                    (f", door at {_pos_text(where)} m" + (" [game]" if v.get("door") else " [wiki map centre]") if where else "")
                    + ".")
            lines = [x for x in c["text"].split("\n") if not x.startswith(f"{name} is in ")]  # an earlier run's line
            new = "\n".join(lines[:-1] + [line] + lines[-1:]) if len(lines) > 1 else c["text"] + "\n" + line
            if len(new) <= ENTRY_CHARS:
                c["text"] = new


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", nargs="?", default="build", choices=["build", "show"])
    ap.add_argument("query", nargs="?")
    ap.add_argument("--wiki", help="the wiki mirror root (default DW_WIKI_DIR, data/wiki, or the main checkout's)")
    a = ap.parse_args(argv)
    if a.cmd == "show":
        from tools.build_bestiary import Bestiary
        b = Bestiary()
        for sec, k in b.match(a.query or ""):
            print(f"--- {sec}/{k} ({len(b.entry(sec, k)['text'])} chars)\n{b.entry(sec, k)['text']}\n")
        return 0
    from tools.build_bestiary import Mirror
    from tools.build_regions import wiki_root
    t0 = time.perf_counter()
    doc = json.loads(BESTIARY.read_text(encoding="utf-8"))
    add_vaults(doc, Mirror(wiki_root(a.wiki)))
    BESTIARY.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    va = [v for v in doc["vaults"].values() if v.get("kind") == "vault"]
    print(f"wrote {BESTIARY}: {len(va)} vaults ({doc['counts']['vault_doors_game']} doors from the game, "
          f"{sum(1 for v in va if v.get('map_centre'))} wiki map centres, {sum(1 for v in va if v.get('entry'))} with "
          f"entry facts), max text {max(len(v['text']) for v in va)} chars, in {time.perf_counter() - t0:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())

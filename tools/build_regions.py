"""Per map region and province: its power level, the creatures that live there (with their level) and the resource
nodes, trees, plants and fish found there; per resource node: the regions it grows in, with each region's power level
and its hostile residents. Output: the ``regions`` and ``resources`` sections of data/bestiary.json, which lookup
serves the same way as the bestiary's creatures and vaults (tools/build_bestiary.py ``Bestiary`` / ``merge``: the
entry a query names comes first). Offline: no model, no game, no network.

Luis 2026-11-18: copper, tin and coal grow in dangerous regions (garou in Fractured Plains, skeletons in Fellhollow);
he must be able to read, per region, its power, its residents with their level and its resources, and decide himself.

Sources (every fact in an entry says which one it came from):
* game, build 26161880: data/places_<build>.json (tools/build_places.py): each ``BP_MapRegion_C``'s ``PowerLevel`` and
  its ``MapRegionTag`` province, read live 2026-10-26. A province's power is the range over its regions.
* game, build 26574459: the journal in data/bestiary_probe_20261117.json (client_mod/commands/bestiary_tables_probe.lua,
  read live 2026-11-17): each ``JOURNAL_World_*`` entry's ``locations`` (one province). It disagrees with the wiki for
  many entries (every flora and ore entry says Ghornfell; Green Dragon and Dragon Wolf say Brynmoor); both are kept and
  the disagreement is written into the entry.
* wiki (data/wiki mirror, RuneScape: Dragonwilds Wiki, CC BY-NC-SA 3.0): region and province pages (lead power level;
  sections Nodes, Trees, Plants, Fish, Monsters / Aggressive / Enemies / ..., Mini-boss, Boss, Dragonkin vaults),
  resource node pages (infobox ``location``), and the creature pages through data/bestiary.json (``locations``,
  power-level variants with health). The wiki's "Power level" page: "Each region in Ashenfall has a power level, which
  most of the monsters in that region inherit."

    .venv\\Scripts\\python.exe -m tools.build_regions                 # adds the two sections to data/bestiary.json
    .venv\\Scripts\\python.exe -m tools.build_regions --wiki C:\\gameserver\\data\\wiki
    .venv\\Scripts\\python.exe -m tools.build_regions show "where is tin"

tools/build_bestiary.py ``build`` calls ``add_sections`` too, so a full bestiary rebuild keeps them.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from brain.knowledge import _stem, words  # noqa: E402

DATA = ROOT / "data"
BESTIARY = DATA / "bestiary.json"
JOURNAL = DATA / "bestiary_probe_20261117.json"
JOURNAL_BUILD = "26574459"  # the server build the 2026-11-17 journal probe ran against (appmanifest_4019830.acf)
WIKI_BASE = "https://dragonwilds.runescape.wiki/w/"
ENTRY_CHARS = 1500  # the bestiary's own cap per entry (build_bestiary.ENTRY_CHARS)
HOSTILE_IN_RESOURCE = 4  # hostile residents named per place in a resource entry
NODE_GENERIC = frozenset({"ore", "node", "tree", "plant", "bush", "rock", "deposit", "boulder"})
LEVEL_NOTE = ("Creature levels: the region's power level, which most monsters there inherit (wiki: Power level); a "
              "boss's from its own page. HP from the creature's wiki page at that level.")

CREATURE_HEAD = re.compile(r"monster|aggress|agress|enem|boss|fauna|black knight|^magi$|goblin|undead|demon", re.I)
PASSIVE_HEAD = re.compile(r"non-?\s*ag", re.I)
MINI_HEAD = re.compile(r"^mini-?boss", re.I)
BOSS_HEAD = re.compile(r"boss", re.I)
NODE_HEAD = re.compile(r"^(nodes?|unique to region|other resources|resources)$", re.I)
TREE_HEAD = re.compile(r"^trees?$", re.I)
PLANT_HEAD = re.compile(r"^plants?$", re.I)
FISH_HEAD = re.compile(r"^fish$", re.I)
VAULT_HEAD = re.compile(r"dragonkin vaults?", re.I)
POWER_RE = re.compile(r"power level (\d+)(?:\s*(?:-|to|–)\s*(\d+))?", re.I)


# ------------------------------------------------------------------------------ names


def key(name: str) -> tuple[str, ...]:
    """Words, plural-folded: 'Garou berserkers' == 'Garou Berserker', "Dragons' Run" == "Dragon's Run"."""
    return tuple(_stem(w) for w in words((name or "").replace("'", "")))


def keys(name: str) -> list[tuple[str, ...]]:
    """key() and a plain trailing-s fold ('zombies' -> 'zombie', which _stem makes 'zomby')."""
    k = key(name)
    out = [k]
    raw = words((name or "").replace("'", ""))
    if raw and raw[-1].endswith("s") and len(raw[-1]) > 3:
        out.append(tuple(_stem(w) for w in raw[:-1]) + (raw[-1][:-1],))
    return out


def own(title: str) -> frozenset[str]:
    """A node's own name less the generic words: 'Copper Ore Node' -> {copper}; 'Rune Essence (Rock)' -> {rune, essence}."""
    t = re.sub(r"\([^)]*\)", " ", title or "")
    return frozenset(key(t)) - NODE_GENERIC


def wiki_url(title: str, anchor: str | None = None) -> str:
    u = WIKI_BASE + title.replace(" ", "_")
    return u + ("#" + anchor.replace(" ", "_") if anchor else "")


def _int(x: Any) -> int | None:
    try:
        return int(str(x).strip())
    except (TypeError, ValueError):
        return None


# ------------------------------------------------------------------------------ wiki page parsing


def bullet_tree(text: str) -> list[tuple[str, list[str]]]:
    """'- A\n- - a1\n- B' -> [('A', ['a1']), ('B', [])] (the mirror flattens list levels to '- ' and '- - ')."""
    items: list[tuple[str, list[str]]] = []
    for line in (text or "").splitlines():
        m = re.match(r"^\s*-\s+-\s+(.+)$", line)
        if m and items:
            items[-1][1].append(m.group(1).strip())
            continue
        m = re.match(r"^\s*-\s+(.+)$", line)
        if m:
            items.append((m.group(1).strip(), []))
    return items


def split_item(s: str) -> tuple[str, str]:
    """'Blurite ore node - only inside of Takla Kara' -> ('Blurite ore node', 'only inside of Takla Kara');
    'Coal nodes: Two inside the cave.' -> ('Coal nodes', 'Two inside the cave'); long descriptions are dropped."""
    s = re.sub(r"\s*\([^)]*\)", "", s or "").strip()
    m = re.match(r"^(.+?)\s+-\s+(.+)$", s) or re.match(r"^([^:]+):\s*(.+)$", s)
    name, note = (m.group(1), m.group(2)) if m else (s, "")
    note = note.strip().rstrip(".")
    return name.strip(" .*-"), (note if len(note) <= 60 else "")


def lead_power(page: dict) -> tuple[int, int] | None:
    secs = page.get("sections") or []
    lead = secs[0]["text"] if secs else ""
    m = POWER_RE.search(lead)
    if not m:
        return None
    lo = int(m.group(1))
    return lo, int(m.group(2) or lo)


def section_lists(page: dict) -> dict[str, list[dict]]:
    """A region page's lists: creatures [{raw, note, passive, role, kids_of}], nodes/trees/plants/fish/vaults [{raw, note}]."""
    out: dict[str, list[dict]] = defaultdict(list)
    for sec in page.get("sections") or []:
        h = (sec.get("heading") or "").strip()
        if not h:
            continue
        items = bullet_tree(sec.get("text") or "")
        if CREATURE_HEAD.search(h):
            passive = bool(PASSIVE_HEAD.search(h))
            role = None if passive else ("mini boss" if MINI_HEAD.search(h) else
                                          ("boss or mini boss" if re.search(r"mini", h, re.I) else
                                           "boss" if BOSS_HEAD.search(h) else None))
            for name, kids in items:
                n, note = split_item(name)
                out["creatures"].append({"raw": n, "note": note, "passive": passive, "role": role, "group": bool(kids),
                                         "heading": h})
                for kid in kids:
                    kn, knote = split_item(kid)
                    out["creatures"].append({"raw": kn, "note": knote, "passive": passive, "role": role, "group": False,
                                             "heading": h, "parent": n})
            continue
        cat = ("nodes" if NODE_HEAD.match(h) else "trees" if TREE_HEAD.match(h) else "plants" if PLANT_HEAD.match(h)
               else "fish" if FISH_HEAD.match(h) else "vaults" if VAULT_HEAD.search(h) else None)
        if not cat:
            continue
        for name, kids in items:
            for raw in [name, *kids]:
                n, note = split_item(raw)
                if n and n.lower() not in ("salvage",):
                    out[cat].append({"raw": n, "note": note, "heading": h})
    return out


# ------------------------------------------------------------------------------ indexes


class Creatures:
    """Name and alias matching over data/bestiary.json creatures."""

    def __init__(self, creatures: dict[str, dict]):
        self.c = creatures
        self.idx: dict[tuple[str, ...], str] = {}
        for k, e in creatures.items():
            for n in {k, e.get("name") or k, *(e.get("aliases") or [])}:
                for kk in keys(n):
                    if kk:
                        self.idx.setdefault(kk, k)

    def find(self, name: str) -> str | None:
        for kk in keys(name):
            if kk in self.idx:
                return self.idx[kk]
        return None

    def level(self, name: str, power: int | None, role: str | None) -> tuple[int | None, str | None]:
        """(power level, health) of a creature in a place of ``power``: the region's level (most monsters inherit it);
        a boss or mini boss keeps its own (its variant at or above the region's, else its highest)."""
        e = self.c.get(name) or {}
        vs = [(p, v.get("health")) for v in e.get("variants") or [] if (p := _int(v.get("power_level"))) is not None]
        if role or "boss" in " ".join(e.get("role") or []):
            if not vs:
                return None, None
            above = sorted(v for v in vs if power is None or v[0] >= power)
            p, hp = above[0] if above else max(vs)
            return p, hp
        if power is None or power < 1:
            return (vs[0] if len(vs) == 1 else (None, None)) if vs else (None, None)
        hp = next((h for p, h in vs if p == power), None)
        return power, hp

    def passive(self, name: str) -> bool:
        return str((self.c.get(name) or {}).get("aggressive") or "").strip().lower() in ("no", "none", "n/a")


class Nodes:
    """Resource node pages of the wiki mirror (infobox Resource node), by their own name."""

    def __init__(self, pages: dict[str, dict]):
        self.pages = {t: p for t, p in pages.items() if (p.get("infobox") or "").lower() == "resource node"}
        self.idx: dict[frozenset, str] = {}
        for t in sorted(self.pages, key=len):
            o = own(t)
            if o:
                self.idx.setdefault(o, t)

    def find(self, name: str) -> str | None:
        o = own(name)
        if not o:
            return None
        if o in self.idx:
            return self.idx[o]
        raw = words(re.sub(r"\([^)]*\)", " ", name or ""))
        if raw and raw[-1].endswith("s"):
            o2 = frozenset(key(" ".join(raw[:-1] + [raw[-1][:-1]]))) - NODE_GENERIC
            return self.idx.get(o2)
        return None

    def location_line(self, title: str) -> str | None:
        secs = (self.pages.get(title) or {}).get("sections") or []
        m = re.search(r"^location: (.+)$", secs[0]["text"], re.M) if secs else None
        return m.group(1).strip() if m else None

    @staticmethod
    def category(title: str) -> str:
        t = title.lower()
        if "tree" in t:
            return "trees"
        if re.search(r"\(plant\)|bush|plant|root|cactus|mushroom|weed", t):
            return "plants"
        return "nodes"


def find_names(text: str, names: Iterable[str]) -> list[str]:
    """Every name of ``names`` that occurs in ``text`` (case-insensitive, word bounded), longest first, no overlaps."""
    low = " " + " ".join(key(text)) + " "  # plural-folded on both sides: "Green dragons nest" names Green Dragon
    hits: list[str] = []
    for n in sorted(set(names), key=lambda s: -len(s)):
        w = " " + " ".join(key(n)) + " "
        if w.strip() and w in low:
            hits.append(n)
            low = low.replace(w, " | ")
    return hits


# ------------------------------------------------------------------------------ build


def newest_places(data: Path = DATA) -> Path | None:
    files = sorted(Path(data).glob("places_*.json"), key=lambda p: int(re.sub(r"\D", "", p.stem) or 0))
    return files[-1] if files else None


def load_journal(path: Path | None = JOURNAL) -> list[dict]:
    try:
        d = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return []
    return [e for e in ((d.get("result") or d).get("journal") or {}).get("entries") or []
            if e.get("name") and e.get("locations")]


def build_sections(places: dict, pages: dict[str, dict], creatures: dict[str, dict], vaults: dict[str, dict] | None = None,
                   journal: list[dict] | None = None, places_file: str = "data/places_<build>.json",
                   resolve=None) -> dict[str, dict]:
    """{"regions": {name: entry}, "resources": {title: entry}}. ``pages`` maps wiki titles to mirror page dicts;
    ``resolve(name)`` maps a name to a page title (the mirror's redirects), default exact or case-insensitive title."""
    vaults = vaults or {}
    journal = journal or []
    build = str(places.get("build") or "?")
    lower = {t.lower(): t for t in pages}
    resolve = resolve or (lambda n: n if n in pages else lower.get((n or "").lower()))
    C = Creatures(creatures)
    N = Nodes(pages)

    # ---- areas: map regions and provinces from the game
    areas: dict[str, dict] = {}
    for r in places.get("regions") or []:
        areas[r["name"]] = {"name": r["name"], "kind": "region", "power": _int(r.get("power")),
                            "province": r.get("province"), "region_id": r.get("region_id"), "tag": r.get("tag")}
    for p in places.get("provinces") or []:
        regs = [areas[n] for n in p.get("regions") or [] if n in areas]
        pw = [a["power"] for a in regs if a["power"] is not None and a["power"] >= 0]
        if p["name"] in areas:  # Scorned Wilderness: a region and a province of one name -> one entry
            areas[p["name"]].update({"kind": "province", "regions": p.get("regions") or [],
                                     "quest_region_id": p.get("quest_region_id"),
                                     "power_range": [min(pw), max(pw)] if pw else None})
            continue
        areas[p["name"]] = {"name": p["name"], "kind": "province", "power": None,
                            "power_range": [min(pw), max(pw)] if pw else None, "province": p["name"],
                            "regions": p.get("regions") or [], "quest_region_id": p.get("quest_region_id")}
    area_by_key = {key(n): n for n in areas}

    def area_of(name: str) -> str | None:
        return area_by_key.get(key(name))

    def power_of(a: dict) -> int | None:
        if a.get("power") is not None and a["power"] >= 0:
            return a["power"]
        rng = a.get("power_range")
        return rng[1] if rng and rng[0] == rng[1] else None

    # ---- wiki: each area's page lists
    for a in areas.values():
        a.update({"residents": [], "nodes": [], "trees": [], "plants": [], "fish": [], "vaults": [], "differs": [],
                  "src": defaultdict(list)})
        title = resolve(a["name"])
        if title and key(title) != key(a["name"]) and a["kind"] == "region":
            title = None  # Rasthin's Rest redirects to Scorned Wilderness: that page is the province's, not this region's
        page = pages.get(title) if title else None
        a["page"] = title if page else None
        if page:
            wp = lead_power(page)
            if wp:
                a["wiki_power"] = list(wp)
            lists = section_lists(page)
            src = f"wiki {title}"
            a["src"]["wiki"].append(wiki_url(title))
            for it in lists.get("creatures", []):
                name = C.find(it["raw"])
                if it["group"] and not name:
                    continue  # a group label ("Skeletons", "Spirits"): its members follow
                _add_resident(a, name or it["raw"].strip()[:1].upper() + it["raw"].strip()[1:], bool(name), it, src, C)
            for cat in ("nodes", "trees", "plants", "fish"):
                for it in lists.get(cat, []):
                    node = N.find(it["raw"]) if cat != "fish" else None
                    c2 = N.category(node) if node and cat == "nodes" and it["heading"].lower() != "nodes" else cat
                    _add_thing(a, c2, node or it["raw"][:1].upper() + it["raw"][1:], node, it["note"], src)
            for it in lists.get("vaults", []):
                _add_thing(a, "vaults", it["raw"], None, "", src)
    # the wiki's "Power level" page table (Region | Power level) where an area's own lead names none (Umbral Sands)
    pl_title = resolve("Power level")
    for sec in (pages.get(pl_title) or {}).get("sections") or [] if pl_title else []:
        if re.match(r"region power levels?", sec.get("heading") or "", re.I):
            for line in (sec.get("text") or "").splitlines():
                m = re.match(r"^\s*([^|]+?)\s*\|\s*(\d+)(?:\s*-\s*(\d+))?\s*$", line)
                an = area_of(m.group(1)) if m else None
                if an and not areas[an].get("wiki_power"):
                    areas[an]["wiki_power"] = [int(m.group(2)), int(m.group(3) or m.group(2))]
                    areas[an]["src"]["wiki"].append(wiki_url(pl_title, sec["heading"]))
    # a region with no page of its own: the province page's section named after it (Fellhollow#Dragon's Run)
    for a in areas.values():
        if a["kind"] != "region" or a["page"] or not a.get("province"):
            continue
        pt = resolve(a["province"])
        for sec in (pages.get(pt) or {}).get("sections") or [] if pt else []:
            if key(sec.get("heading") or "") == key(a["name"]):
                src = f"wiki {pt}#{sec['heading']} (named in the text)"
                a["src"]["wiki"].append(wiki_url(pt, sec["heading"]))
                for n in find_names(sec.get("text") or "", list(creatures)):
                    _add_resident(a, n, True, {"note": "", "passive": False, "role": None}, src, C)
                for t in find_names(sec.get("text") or "", list(N.pages)):
                    _add_thing(a, N.category(t), t, t, "", src)
    # ---- wiki creature pages: their "locations"
    for name, e in creatures.items():
        for loc in e.get("locations") or []:
            an = area_of(loc)
            if an:
                _add_resident(areas[an], name, True, {"note": "", "passive": False, "role": None},
                              f"wiki {name} (creature page)", C)
                areas[an]["src"]["wiki creature pages"].append(name)
    # ---- the game's journal: one province per entry
    jprov: dict[str, list[dict]] = defaultdict(list)
    for e in journal:
        for loc in e.get("locations") or []:
            an = area_of(loc)
            if an:
                jprov[an].append(e)
    # ---- province lists: its own page plus its regions'
    for a in areas.values():
        if a["kind"] != "province":
            continue
        for rn in a.get("regions") or []:
            r = areas.get(rn)
            if not r or r is a:
                continue
            for res in r["residents"]:
                if not any(x["name"] == res["name"] for x in a["residents"]):
                    a["residents"].append({**res, "via": rn})
            for cat in ("nodes", "trees", "plants", "fish", "vaults"):
                for t in r[cat]:
                    if not any(x["name"] == t["name"] for x in a[cat]):
                        a[cat].append({**t, "via": rn})
    # ---- levels of residents
    for a in areas.values():
        for res in a["residents"]:
            if res["in_bestiary"]:  # in a province, the level of the region the resident was listed in
                pw = power_of(areas[res["via"]]) if res.get("via") in areas else power_of(a)
                lv, hp = C.level(res["name"], pw, res.get("role"))
                res["power_level"], res["health"] = lv, hp
        if a["kind"] == "province":  # the commonest across its regions first (skeletons before a single named spirit)
            n = defaultdict(int)
            for rn in a.get("regions") or []:
                for r in (areas.get(rn) or {}).get("residents") or []:
                    n[r["name"]] += 1
            a["residents"].sort(key=lambda r: -n[r["name"]])
    # ---- power: game vs wiki
    for a in areas.values():
        wp = a.get("wiki_power")
        game = [a["power"], a["power"]] if a["kind"] == "region" and a["power"] is not None and a["power"] >= 0 else \
            a.get("power_range")
        if wp and game and list(wp) != list(game):
            a["differs"].append(f"power level: game {_rng(game)}, wiki {_rng(wp)}")
    # ---- resources
    resources = _resources(areas, N, C, vaults, journal, area_of, power_of, build)
    # ---- journal disagreements on creatures (the province the journal names vs the wiki's places)
    for an, ents in jprov.items():
        a = areas[an]
        a["journal"] = []
        for e in ents:
            cname = C.find(e["name"])
            wiki_provs = sorted({areas[x]["province"] for loc in (creatures.get(cname) or {}).get("locations") or []
                                 if (x := area_of(loc)) and areas[x].get("province")}) if cname else []
            row = {"name": e["name"], "asset": e.get("asset"), "creature": cname}
            if cname and wiki_provs and a["province"] not in wiki_provs:
                row["differs"] = f"wiki places it in {_and(wiki_provs)}"
            a["journal"].append(row)
    regions = {n: _region_entry(a, areas, build, places_file) for n, a in areas.items()}
    return {"regions": regions, "resources": resources}


def _add_resident(a: dict, name: str, in_bestiary: bool, it: dict, src: str, C: Creatures) -> None:
    for r in a["residents"]:
        if r["name"] == name:
            if it.get("role") and not r.get("role"):
                r["role"] = it["role"]
            return
    passive = bool(it.get("passive")) or (in_bestiary and C.passive(name))
    a["residents"].append({"name": name, "in_bestiary": in_bestiary, "passive": passive, "role": it.get("role"),
                           "note": it.get("note") or "", "src": src})


def _add_thing(a: dict, cat: str, name: str, page: str | None, note: str, src: str) -> None:
    for t in a[cat]:
        if t["name"] == name:
            return
    a[cat].append({"name": name, "page": page, "note": note, "src": src})


def _rng(r) -> str:
    return str(r[0]) if r[0] == r[1] else f"{r[0]} to {r[1]}"


def _and(xs: list[str]) -> str:
    xs = [x for x in xs if x]
    return xs[0] if len(xs) == 1 else ", ".join(xs[:-1]) + " and " + xs[-1] if xs else ""


def _power_text(a: dict, build: str) -> str:
    if a["kind"] == "region":
        p = a["power"]
        g = f"Power level {p}" if p is not None and p >= 0 else f"No power level (the map says {p})"
    else:
        rng = a.get("power_range")
        g = f"Power level {_rng(rng)}" if rng else "Power level unknown"
    w = a.get("wiki_power")
    wt = (f"; wiki: power level {_rng(w)}" if w else "; the wiki page gives none")
    return f"{g} (game map, build {build}{wt})"


def _res_text(res: dict, hp: bool = True, area_power: int | None = None) -> str:
    """'Garou Berserker (292 HP)' in a power-3 region; the level is written only where it is not the area's."""
    bits = []
    if res.get("power_level") is not None and res["power_level"] != area_power:
        bits.append(f"power level {res['power_level']}")
    if hp and res.get("health") and str(res["health"]).lower() not in ("unknown", "?"):
        bits.append(f"{res['health']} HP")
    if res.get("note"):
        bits.append(res["note"])
    return res["name"] + (f" ({', '.join(bits)})" if bits else "")


def _hostile(a: dict) -> list[dict]:
    rows = [r for r in a["residents"] if not r["passive"] and not r.get("role")]
    return sorted(rows, key=lambda r: (not r["in_bestiary"], "creature page" in r["src"]))


def _bosses(a: dict) -> list[dict]:
    return [r for r in a["residents"] if r.get("role")]


def _list(items: list[str], cap: int | None) -> str:
    if cap is None or len(items) <= cap:
        return ", ".join(items)
    return ", ".join(items[:cap]) + f" and {len(items) - cap} more"


def _region_entry(a: dict, areas: dict, build: str, places_file: str) -> dict:
    name = a["name"]

    pw = a["power"] if a["kind"] == "region" and a["power"] is not None and a["power"] >= 0 else \
        (a["power_range"][0] if a.get("power_range") and a["power_range"][0] == a["power_range"][1] else None)

    def render(cap: int | None, hp: bool, notes: bool) -> str:
        if a["kind"] == "province":
            head = f"{name}: province (game EQuestRegion {a.get('quest_region_id')}). {_power_text(a, build)}."
            subs = [f"{r} {areas[r]['power'] if (areas.get(r) or {}).get('power', -1) >= 0 else 'none'}"
                    for r in a.get("regions") or [] if r != name]
            if subs:
                head += f"\nIts regions (game power level): {', '.join(subs)}."
        else:
            head = f"{name}: region of {a.get('province') or '?'} (game map). {_power_text(a, build)}."
        parts = [head]
        hostile, bosses = _hostile(a), _bosses(a)
        passive = [r for r in a["residents"] if r["passive"] and not r.get("role")]
        at = f"power level {pw} unless noted" if pw is not None else "power level by region"
        if hostile:
            parts.append(f"Hostile creatures (wiki; {at}): "
                         + _list([_res_text(r, hp, pw) for r in hostile], cap) + ".")
        if bosses:
            parts.append("Bosses (wiki): " + _list([_res_text(r, hp, None) + f" [{r['role']}]" for r in bosses], cap) + ".")
        if passive:
            parts.append("Passive (wiki): " + _list([r["name"] for r in passive], cap) + ".")
        if not a["residents"]:
            parts.append("Creatures: none listed on the wiki for this area.")
        for cat, label in (("nodes", "Resource nodes"), ("trees", "Trees"), ("plants", "Plants"), ("fish", "Fish"),
                           ("vaults", "Dragonkin vaults")):
            if a[cat]:
                parts.append(f"{label} (wiki): " + _list([t["name"] + (f" ({t['note']})" if t["note"] and notes else "")
                                                          for t in a[cat]], cap) + ".")
        if not any(a[c] for c in ("nodes", "trees", "plants")):
            parts.append("Resources: none listed on the wiki for this area.")
        if a.get("journal"):
            j = [r["name"] + (f" ({r['differs']})" if r.get("differs") else "") for r in a["journal"]
                 if r.get("creature")]
            if j:
                parts.append(f"Game journal (build {JOURNAL_BUILD}) names {name} for: " + _list(j, cap) + ".")
        if a["differs"]:
            parts.append("Game and wiki differ: " + "; ".join(a["differs"]) + ".")
        if a["residents"]:
            parts.append(LEVEL_NOTE)
        src = [f"game {places_file} (build {build})"]
        if a.get("page"):
            src.append(f"wiki {wiki_url(a['page'])}")
        if a["src"].get("wiki creature pages"):
            src.append("wiki creature pages")
        parts.append("Sources: " + "; ".join(src) + ".")
        return "\n".join(parts)

    text = ""
    for cap, hp, notes in ((None, True, True), (None, True, False), (None, False, False), (12, False, False),
                           (8, False, False), (5, False, False), (3, False, False)):
        text = render(cap, hp, notes)
        if len(text) <= ENTRY_CHARS:
            break
    if len(text) > ENTRY_CHARS:
        text = text[:ENTRY_CHARS - 1].rsplit(" ", 1)[0] + "…"
    aliases = sorted({name, *( [a["page"]] if a.get("page") and a["page"] != name else [])})
    if name == "Dragons' Run":
        aliases.append("Dragon's Run")
    e = {"kind": a["kind"], "name": name, "aliases": aliases, "province": a.get("province"),
         "power_level": {"game": a["power"] if a["kind"] == "region" else a.get("power_range"),
                         "game_build": build, "wiki": a.get("wiki_power")},
         "residents": [{k: v for k, v in r.items() if k != "in_bestiary"} | {"in_bestiary": r["in_bestiary"]}
                       for r in a["residents"]],
         **{cat: a[cat] for cat in ("nodes", "trees", "plants", "fish", "vaults")},
         "differs": a["differs"], "journal": a.get("journal") or [],
         "src": {"game": f"{places_file} (build {build})", "wiki": a["src"].get("wiki") or [],
                 "journal": f"{JOURNAL.relative_to(ROOT).as_posix()} (build {JOURNAL_BUILD})" if a.get("journal") else None},
         "lookup_source": f"regions (game map build {build} + wiki mirror)", "text": text}
    if a["kind"] == "province":
        e["regions"] = a.get("regions") or []
    return e


def _resources(areas, N: Nodes, C: Creatures, vaults, journal, area_of, power_of, build: str) -> dict[str, dict]:
    region_pages: dict[str, list[str]] = defaultdict(list)  # node page -> areas whose own page lists it
    for a in areas.values():
        for cat in ("nodes", "trees", "plants"):
            for t in a[cat]:
                if t.get("page") and not t.get("via") and a["name"] not in region_pages[t["page"]]:
                    region_pages[t["page"]].append(a["name"])
    jmat: dict[str, list[dict]] = defaultdict(list)
    for e in journal:
        if re.match(r"JOURNAL_(World_(Materials|Flora)|Recipe_Resources)", e.get("asset") or ""):
            t = N.find(e["name"])
            if t:
                jmat[t].append(e)
    vault_names = {v.get("name") or k: v for k, v in vaults.items()}
    out: dict[str, dict] = {}
    for title in sorted(N.pages):
        loc_line = N.location_line(title)
        named = find_names(loc_line or "", list(areas) + list(vault_names) + ["Dragon's Run", "Ashenfall"])
        wiki_places = []
        for n in named:
            an = area_of(n)
            wiki_places.append(an or n)
        listed = region_pages.get(title, [])
        if not (wiki_places or listed or jmat.get(title)):
            continue
        places: list[str] = list(dict.fromkeys(wiki_places + listed))
        rows, prov_set = [], set()
        for p in places:
            if p == "Ashenfall":
                rows.append(("throughout Ashenfall (wiki)", [], None))
                continue
            if p in vault_names:
                v = vault_names[p]
                rows.append((f"{p} (dragonkin vault in {v.get('area') or '?'}, power level {v.get('power_level') or '?'})",
                             [], None))
                if v.get("area") and area_of(v["area"]):
                    prov_set.add(areas[area_of(v["area"])].get("province"))
                continue
            a = areas.get(p)
            if not a:
                continue
            prov_set.add(a.get("province"))
            pw = power_of(a)
            if a["kind"] == "province":
                subs = [r for r in a.get("regions") or [] if r in listed and r != p]
                if subs and all(r in places for r in subs):
                    continue  # its regions that list it are rows of their own
                pwt = f"power level {_rng(a['power_range'])}" if a.get("power_range") else "power level unknown"
                hostile_from = [areas[r] for r in subs] or [a]
                where = f"{p} ({pwt}" + (f"; its regions listing it: {', '.join(subs)}" if subs else "")
            else:
                pwt = f"power level {pw}" if pw is not None else "no power level"
                hostile_from = [a]
                where = f"{p} ({a.get('province')}, {pwt}"
            hostile: list[str] = []
            for h in hostile_from:
                hp_ = h["power"] if h["kind"] == "region" else None
                for r in _hostile(h):
                    if r["in_bestiary"] and r["name"] not in [x.split(" (")[0] for x in hostile]:
                        hostile.append(_res_text(r, hp=False, area_power=hp_))
            src = []
            if p in wiki_places:
                src.append("node page")
            elif a.get("province") in wiki_places:
                src.append(f"node page: {a['province']}")
            if p in listed:
                src.append("region page")
            rows.append((where, hostile, f"[wiki {' + '.join(src)}]"))
        jrows, differs = [], []
        for e in jmat.get(title, []):
            locs = e.get("locations") or []
            jrows.append(f"{e['name']}: {', '.join(locs)}")
            bad = [l for l in locs if area_of(l) and areas[area_of(l)].get("province") not in prov_set]
            if bad and prov_set - {None}:
                differs.append(f"the game journal says {', '.join(bad)}; the wiki says "
                               f"{_and(sorted(x for x in prov_set if x))}")
        not_on_pages = [p for p in wiki_places if p in areas and areas[p]["kind"] == "region" and p not in listed
                        and areas[p].get("page")]
        if not_on_pages:
            differs.append(f"the node page names {_and(not_on_pages)}, whose own page does not list it")
        prov_pages = [p for p in wiki_places if p in areas and areas[p]["kind"] == "province"
                      and not any(r in listed for r in areas[p].get("regions") or []) and p not in listed]
        if prov_pages:
            differs.append(f"the node page names {_and(prov_pages)}, but no region page there lists it")
        produce = sorted({m for e in jmat.get(title, []) for m in e.get("materials") or []})
        def row_text(cap: int, tags: bool) -> str:
            out = []
            for where, hostile, tag in rows:
                if tag is None:
                    out.append(where)
                    continue
                h = hostile[:cap]
                out.append(where + (f"; hostile: {', '.join(h)}" if h else "") + ")" + (f" {tag}" if tags else ""))
            return "; ".join(out) if out else "no place named"

        parts = [f"{title}: resource node. Grows in: {{rows}}."]
        if loc_line:
            parts.append(f"Wiki node page location: {re.sub(r'\s+', ' ', loc_line.replace('*', '').strip(' -'))}.")
        if produce:
            parts.append(f"Gives (game journal): {', '.join(produce)}.")
        if jrows:
            parts.append(f"Game journal (build {JOURNAL_BUILD}) location: " + "; ".join(jrows) + ".")
        if differs:
            parts.append("Sources differ: " + "; ".join(differs) + ".")
        parts.append(f"Sources: power levels game map (build {build}); places and residents wiki {wiki_url(title)} "
                     "and the region and creature pages.")
        body = "\n".join(parts)
        text = ""
        for cap, tags in ((HOSTILE_IN_RESOURCE, True), (HOSTILE_IN_RESOURCE, False), (3, False), (2, False), (1, False),
                          (0, False)):
            text = body.replace("{rows}", row_text(cap, tags), 1)
            if len(text) <= ENTRY_CHARS:
                break
        if len(text) > ENTRY_CHARS:
            text = text[:ENTRY_CHARS - 1].rsplit(" ", 1)[0] + "…"
        bare = " ".join(w for w in words(re.sub(r"\([^)]*\)", " ", title)) if w not in ("ore", "node", "deposit", "rock"))
        base = " ".join(w for w in words(re.sub(r"\([^)]*\)", " ", title)) if _stem(w) not in NODE_GENERIC)
        aliases = {title, re.sub(r"\s*\([^)]*\)", "", title).strip(), *(e["name"] for e in jmat.get(title, []))}
        if base and Nodes.category(title) == "nodes":
            aliases |= {f"{base} ore", f"{base} ore node", f"{base} node", f"{base} deposit", f"{base} rock",
                        f"{base} ore rock", f"{base} rocks"}
        elif base and Nodes.category(title) == "trees":
            aliases |= {f"{base} tree", f"{base} trees"}
        elif base:
            aliases |= {f"{base} plant", f"{base} bush"}
        if bare and bare != base:
            aliases.add(bare)
        out[title] = {"kind": "resource", "name": title, "category": Nodes.category(title),
                      "aliases": sorted(a for a in aliases if a),
                      "loose_aliases": [base] if base else [],
                      "places": places, "wiki_location": loc_line, "region_pages": listed,
                      "journal": [{"name": e["name"], "locations": e.get("locations"), "materials": e.get("materials")}
                                  for e in jmat.get(title, [])],
                      "differs": differs,
                      "src": {"wiki": [wiki_url(title)] + [wiki_url(p) for p in listed],
                              "journal": f"{JOURNAL.relative_to(ROOT).as_posix()} (build {JOURNAL_BUILD})" if jmat.get(title) else None},
                      "lookup_source": f"regions (game map build {build} + wiki mirror)", "text": text}
    return out


# ------------------------------------------------------------------------------ in and out


def wiki_root(arg: str | None = None) -> Path:
    if arg:
        return Path(arg)
    env = os.environ.get("DW_WIKI_DIR")
    if env:
        return Path(env)
    local = DATA / "wiki"
    if (local / "manifest.json").exists():
        return local
    main = ROOT.parents[2] / "data" / "wiki" if ROOT.parent.name == "worktrees" else local  # a worktree: the main checkout's mirror
    return main


def add_sections(doc: dict, mirror=None, places_path: Path | None = None, journal_path: Path | None = JOURNAL) -> dict:
    """Add (replace) ``regions`` and ``resources`` in a bestiary doc. ``mirror``: a build_bestiary.Mirror."""
    places_path = places_path or newest_places()
    if not places_path or not Path(places_path).exists():
        return doc
    places = json.loads(Path(places_path).read_text(encoding="utf-8"))
    try:
        rel = Path(places_path).resolve().relative_to(ROOT).as_posix()
    except ValueError:
        rel = Path(places_path).name
    pages = mirror.pages if mirror is not None else {}
    secs = build_sections(places, pages, doc.get("creatures") or {}, doc.get("vaults") or {},
                          load_journal(journal_path) if journal_path else [], rel,
                          resolve=getattr(mirror, "resolve", None))
    doc["regions"], doc["resources"] = secs["regions"], secs["resources"]
    doc.setdefault("counts", {})["regions"] = len(secs["regions"])
    doc["counts"]["resources"] = len(secs["resources"])
    return doc


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
    t0 = time.perf_counter()
    doc = json.loads(BESTIARY.read_text(encoding="utf-8"))
    add_sections(doc, Mirror(wiki_root(a.wiki)))
    BESTIARY.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"wrote {BESTIARY}: {doc['counts']['regions']} regions and provinces, {doc['counts']['resources']} resource "
          f"nodes in {time.perf_counter() - t0:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())

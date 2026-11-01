"""What each food and drink restores, and where food comes from -> data/food_values_<build>.json (DATA, generated).

Sources, best first (each value carries its source):
  live   client_mod/commands/food_values_probe.lua on Claude's own client: every loaded FoodItemData / DrinkItemData
         joined through its row handles to DT_FoodSustenance (Sustenance, DecayBuffer), DT_DrinkHydration
         (Hydration, DecayBuffer), DT_Toxicity_V2 (Soulscourge), DT_Wither_V2, DT_RestEndurance, plus
         AmountToHealOnConsume (the game's own numbers; pass the probe's out file with --live).
  wiki   the mirror data/wiki/pages (CC BY-NC-SA, revids in data/wiki/manifest.json): Infobox Item sustenance /
         health / hydration / weight, "also N Soulscourge" in the prose; Infobox Monster + DropsLine rows (who drops
         what, power level, health, aggressive); Infobox Resource Node + DropsLine (a bush's yield, respawn).
  game   data/recipes_<build>.json: item ids, names, weights (wins over the wiki), the cook/boil recipes.

The brain (brain/needs_options.py) reads this to put value numbers next to every option; nothing here ranks or picks.
Usage: .venv\\Scripts\\python.exe -m tools.gen_food_values [--live client_io/out/food_values_probe.json]
"""
from __future__ import annotations

import argparse
import json
import re
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PAGES = REPO / "data/wiki/pages"
BUILD = "26161880"
CATALOG = REPO / f"data/recipes_{BUILD}.json"
OUT = REPO / f"data/food_values_{BUILD}.json"
SCHEMA = "dw_food_values/1"


def template(text: str, name: str) -> str | None:
    """The body of the first {{<name> ...}} template, braces balanced."""
    m = re.search(r"\{\{\s*" + re.escape(name) + r"\b", text, re.I)
    if not m:
        return None
    depth, i = 0, m.start()
    while i < len(text) - 1:
        two = text[i:i + 2]
        if two == "{{":
            depth += 1
            i += 2
            continue
        if two == "}}":
            depth -= 1
            i += 2
            if depth == 0:
                return text[m.end():i - 2]
            continue
        i += 1
    return text[m.end():]


def fields(body: str | None) -> dict[str, str]:
    out: dict[str, str] = {}
    if not body:
        return out
    for part in re.split(r"\n\s*\|", "\n" + body):
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        k = k.strip().lower().replace(" ", "_")
        v = re.sub(r"\[\[(?:[^|\]]*\|)?([^\]]*)\]\]", r"\1", v)  # [[a|b]] -> b
        v = re.sub(r"<[^>]+>", " ", v)
        v = re.sub(r"\s+", " ", v.replace("*", " ")).strip()
        if k and v:
            out.setdefault(k, v)
    return out


def num(v: str | None) -> float | None:
    m = re.match(r"\s*\+?(-?[\d,]*\.?\d+)", v or "")
    if not m:
        return None
    x = float(m.group(1).replace(",", ""))
    return int(x) if x == int(x) else x


def rarity(v: str) -> float | None:
    v = (v or "").strip().lower()
    if v.startswith("always"):
        return 1.0
    m = re.match(r"(\d+)\s*/\s*(\d+)", v)
    return round(int(m.group(1)) / int(m.group(2)), 3) if m and int(m.group(2)) else None


def drops(text: str) -> list[dict]:
    out = []
    for m in re.finditer(r"\{\{\s*DropsLine\s*\|([^}]*)\}\}", text, re.I):
        f = {k.strip().lower(): v.strip() for k, v in (p.split("=", 1) for p in m.group(1).split("|") if "=" in p)}
        if f.get("name"):
            q = f.get("quantity") or "1"
            qn = [num(x) for x in re.split(r"[-–]", q) if num(x) is not None]
            out.append({"name": f["name"], "qty": qn[0] if len(qn) == 1 else qn or 1, "chance": rarity(f.get("rarity", ""))})
    return out


def versions(f: dict[str, str], key: str) -> list:
    vals = [num(f.get(key))] + [num(f.get(f"{key}{i}")) for i in range(1, 8)]
    return [v for v in vals if v is not None]


def name_index(cat: dict) -> dict[str, str]:
    """display name (lower) -> item id, preferring live (non-deprecated) assets."""
    idx: dict[str, str] = {}
    for iid, e in sorted((cat.get("items") or {}).items(), key=lambda kv: ("Deprecated" in str(kv[1].get("path")) or kv[0].endswith("_OLD"), kv[0])):
        n = str(e.get("name") or "").lower()
        if n and n not in idx:
            idx[n] = iid
    return idx


def kind_of_class(cls: str) -> str | None:
    for kind, word in (("food", "Food"), ("drink", "Drink"), ("potion", "Potion")):
        if f"Consumables_{word}" in (cls or ""):
            return kind
    return None


def wiki_pass(cat: dict) -> tuple[dict, dict, dict, list]:
    names = name_index(cat)
    items, creatures, nodes, unmatched = {}, {}, {}, []
    for f in sorted(PAGES.glob("*.json")):
        d = json.loads(f.read_text(encoding="utf-8"))
        wt = d.get("wikitext") or ""
        src = {"title": d.get("title"), "revid": d.get("revid"), "url": d.get("url")}
        box = d.get("infobox")
        if box == "Item":
            fl = fields(template(wt, "Infobox Item"))
            itype = (fl.get("item_type") or "").lower()
            if not any(w in itype for w in ("food", "drink", "potion", "infusion", "consumable")):
                continue
            name = fl.get("name") or d.get("title")
            iid = names.get(str(name).lower()) or names.get(str(d.get("title")).lower())
            rec = {"name": name, "wiki": src}
            for k in ("sustenance", "health", "hydration", "weight", "duration"):
                v = num(fl.get(k))
                if v is not None:
                    rec["heal" if k == "health" else k] = v
            soul = re.search(r"(\d+)\s*\[*soulscourge", wt[:4000], re.I)
            if soul:
                rec["soulscourge"] = int(soul.group(1))
            perks = [fl[k] for k in ("perk", "perk1", "perk2", "perk3") if fl.get(k)]
            if perks:
                rec["perks"] = perks
            if iid:
                items[iid] = rec
            elif any(k in rec for k in ("sustenance", "heal", "hydration")):
                unmatched.append(name)
        elif box == "Monster":
            fl = fields(template(wt, "Infobox Monster"))
            name = fl.get("name") or d.get("title")
            rec = {"pl": versions(fl, "power_level"), "hp": versions(fl, "health"),
                   "aggressive": (fl.get("aggressive") or "").lower().startswith("yes"),
                   "drops": drops(wt), "wiki": src}
            for dr in rec["drops"]:
                dr["item"] = names.get(dr["name"].lower())
            if rec["drops"]:
                creatures[str(name)] = rec
        elif box == "Resource Node":
            fl = fields(template(wt, "Infobox Resource Node"))
            name = fl.get("name") or d.get("title")
            dr = drops(wt)
            for x in dr:
                x["item"] = names.get(x["name"].lower())
            if dr:
                nodes[str(name)] = {"drops": dr, "respawn": fl.get("respawn"), "wiki": src}
    return items, creatures, nodes, unmatched


def live_pass(path: Path | None) -> dict:
    if not path or not path.exists():
        return {}
    raw = json.loads(path.read_text(encoding="utf-8"))
    res = raw.get("result", raw) if isinstance(raw, dict) else {}
    return res if isinstance(res, dict) else {}


def merge(cat: dict, wiki_items: dict, live: dict) -> dict:
    out: dict[str, dict] = {}
    cat_items = cat.get("items") or {}
    for iid, e in cat_items.items():
        kind = kind_of_class(str(e.get("class")))
        if not kind:
            continue
        rec = {"name": e.get("name"), "kind": kind, "weight": e.get("weight"), "src": {}}
        w = wiki_items.get(iid) or {}
        for k in ("sustenance", "heal", "hydration", "soulscourge", "perks", "duration"):
            if w.get(k) is not None:
                rec[k] = w[k]
                rec["src"][k] = f"wiki rev {w['wiki'].get('revid')}"
        lv = (live.get("items") or {}).get(iid) or {}
        for key, fld, dst in (("sustenance", "Sustenance", "sustenance"), ("sustenance", "DecayBuffer", "decay_buffer"),
                              ("hydration", "Hydration", "hydration"), ("hydration", "DecayBuffer", "decay_buffer"),
                              ("toxicity", "Toxicity", "soulscourge"), ("wither", "Wither", "wither"),
                              ("shield", "VitalShield", "shield")):
            row = lv.get(key) if isinstance(lv.get(key), dict) else None
            v = row.get(fld) if row else None
            if isinstance(v, (int, float)) and (v != 0 or dst in ("sustenance", "hydration")):
                rec[dst] = round(v, 2)
                rec["src"][dst] = f"live {lv.get(key + '_table') or key} row {lv.get(key + '_row')}"
        if isinstance(lv.get("heal"), (int, float)) and kind == "food":
            rec["heal"] = round(lv["heal"], 2)
            rec["src"]["heal"] = "live AmountToHealOnConsume"
        if isinstance(lv.get("endurance"), dict):
            v = next((x for x in lv["endurance"].values() if isinstance(x, (int, float)) and x), None)
            if v:
                rec["endurance"] = round(v, 2)
                rec["src"]["endurance"] = f"live {lv.get('endurance_table')} row {lv.get('endurance_row')}"
        if lv:
            rec["live"] = True
        if any(k in rec for k in ("sustenance", "hydration", "heal")):
            out[iid] = rec
    return out


def cooks(cat: dict) -> dict:
    """raw input item -> [{recipe, output, stations, processing_time, burn_attr}] for single-input station recipes whose
    output is food or drink (Campfire/Grill processing). The brain chains raw meat -> cooked food from it."""
    items = cat.get("items") or {}
    out: dict[str, list] = {}
    for rid, r in (cat.get("recipes") or {}).items():
        ins, outs = r.get("inputs") or [], r.get("outputs") or []
        if len(ins) != 1 or not outs or "processing" not in (r.get("station_kinds") or []):
            continue
        o = outs[0]
        if not kind_of_class(str((items.get(o.get("item")) or {}).get("class"))):
            continue
        out.setdefault(ins[0]["item"], []).append({
            "recipe": rid, "output": o.get("item"), "stations": r.get("stations") or [],
            "processing_time": r.get("processing_time"),
            "burn_attr": (r.get("alternative") or {}).get("chance_attribute")})
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", type=Path, default=REPO / "client_io/out/food_values_probe.json")
    ap.add_argument("--out", type=Path, default=OUT)
    a = ap.parse_args(argv)
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    wiki_items, creatures, nodes, unmatched = wiki_pass(cat)
    live = live_pass(a.live)
    items = merge(cat, wiki_items, live)
    data = {
        "schema": SCHEMA, "build": BUILD, "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sources": {"live": str(a.live.relative_to(REPO)) if live and a.live.is_relative_to(REPO) else None,
                    "live_counts": live.get("counts"), "wiki": "data/wiki/pages (CC BY-NC-SA)",
                    "catalog": CATALOG.name, "wiki_unmatched": sorted(set(map(str, unmatched)))[:60]},
        "items": dict(sorted(items.items())),
        "cooks": dict(sorted(cooks(cat).items())),
        "creatures": dict(sorted(creatures.items())),
        "nodes": dict(sorted(nodes.items())),
    }
    a.out.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    nl = sum(1 for r in items.values() if r.get("live"))
    print(f"{len(items)} consumables ({nl} live), {len(creatures)} creatures with drops, {len(nodes)} nodes -> {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

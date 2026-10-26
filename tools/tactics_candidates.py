"""Dev-fact finder for the three unpinned GOAL tactics cases (goal_tactics_prep_hard_fight, _damage_trend,
_telegraph_dodges in evals/bench/goal_cases/tactics_knowledge.json). NOT a judge file and never edits one: it only
gathers, from data we already have, which creature class could fill each `<...>` placeholder, with the evidence
and what is still unverified, so main can fill the placeholders in goal_drafts.py after one live check.

Sources (read only):
  - live creature census rows in the brain logs (logs/*.jsonl: get_state/look "creatures" rows: class, name,
    power_level, max_health, archetype), plus full class paths the logs printed (GetFullName);
  - Claude's combat memory (data/skills/<world>/combat_memory_*.json): distinct telegraphed attack keys per
    creature (defense.attacks "<Name>:<ATK_...>", n, damage) and fight history (damage_taken, outcome);
  - the wiki knowledge DB (data/wiki/knowledge.sqlite, kind=monster): power level(s), health, weakness, location;
  - evals/bench/spawn_classes.json: whether the spawn fixture has a verified path (string), candidates (list) or none.

Criteria (the placeholders' own words):
  prep_hard_fight  "a creature PL >= gear PL + 2 near the start (data)"; + "<the boss weakness damage type>"
  damage_trend     "a creature that hurts a fresh character, with telegraphs"
  telegraph_dodges "a creature with >= 2 distinct telegraphed attacks"

  py tools/tactics_candidates.py [--gear-pl 1] [--out logs/dev_facts/tactics_candidates.json]
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROW = re.compile(r"\{[^{}]*\"class\": ?\"(BP_AI_[A-Za-z0-9_]+_C)\"[^{}]*\}")
PATH = re.compile(r"/Game/[A-Za-z0-9_/]*/(BP_AI_[A-Za-z0-9_]+)\.\1_C")
ATTACK = re.compile(r"^(?P<name>[^:]+):(?P<atk>ATK_[A-Za-z0-9_]+)$")  # DAA_* keys are AI actions, not attacks
MAX_LOG_BYTES = 400 * 1024 * 1024  # skip pathological files; the census rows are in the brain jsonl logs


def census(root: Path) -> dict[str, dict]:
    """class -> {names, power_levels, max_health, archetypes, rows, path} from live census rows in the logs."""
    out: dict[str, dict] = defaultdict(lambda: {"names": set(), "power_levels": set(), "max_health": set(),
                                                "archetypes": set(), "rows": 0, "path": None})
    files = sorted(glob.glob(str(root / "logs" / "*.jsonl"))) + sorted(glob.glob(str(root / "client_io" / "out" / "*.json")))
    for f in files:
        try:
            if os.path.getsize(f) > MAX_LOG_BYTES:
                continue
            txt = Path(f).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in PATH.finditer(txt):
            out[m.group(1) + "_C"]["path"] = m.group(0)
        for m in ROW.finditer(txt):
            try:
                r = json.loads(m.group(0))
            except ValueError:
                continue
            c = out[m.group(1)]
            c["rows"] += 1
            for k, dst in (("name", "names"), ("kind", "names"), ("archetype", "archetypes")):
                if isinstance(r.get(k), str):
                    c[dst].add(r[k])
            if isinstance(r.get("power_level"), (int, float)):
                c["power_levels"].add(int(r["power_level"]))
            if isinstance(r.get("max_health"), (int, float)) and r["max_health"] > 0:
                c["max_health"].add(round(float(r["max_health"])))
    return {k: v for k, v in out.items() if v["rows"] or v["path"]}


def combat_memory(root: Path) -> dict[str, dict]:
    """creature name (lower) -> {attacks: {ATK: {n, damage}}, fights, deaths, max_damage_taken} over all worlds."""
    out: dict[str, dict] = defaultdict(lambda: {"attacks": {}, "fights": 0, "deaths": 0, "max_damage_taken": 0.0, "worlds": set()})
    for f in glob.glob(str(root / "data" / "skills" / "*" / "combat_memory_*.json")):
        try:
            d = json.loads(Path(f).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        world = Path(f).parent.name
        for key, v in ((d.get("defense") or {}).get("attacks") or {}).items():
            m = ATTACK.match(key)
            if not m or not isinstance(v, dict) or not v.get("n"):
                continue
            a = out[m["name"].lower()]
            prev = a["attacks"].get(m["atk"], {"n": 0, "damage": 0.0})
            a["attacks"][m["atk"]] = {"n": prev["n"] + int(v["n"]), "damage": max(prev["damage"], float(v.get("damage") or 0))}
            a["worlds"].add(world)
        for name, fights in (d.get("history") or {}).items():
            a = out[name.lower()]
            a["worlds"].add(world)
            for h in fights if isinstance(fights, list) else []:
                a["fights"] += 1
                a["deaths"] += h.get("outcome") == "died"
                a["max_damage_taken"] = max(a["max_damage_taken"], float(h.get("damage_taken") or 0))
    return out


def wiki_monsters(root: Path) -> dict[str, dict]:
    """name (lower) -> {power_levels, health, weakness, resistance, locations} from the wiki infobox body."""
    db = root / "data" / "wiki" / "knowledge.sqlite"
    out: dict[str, dict] = {}
    if not db.exists():
        return out
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        rows = con.execute("select title, body from docs where kind = 'monster' and heading = ''").fetchall()
    finally:
        con.close()
    for title, body in rows:
        kv: dict[str, list[str]] = defaultdict(list)
        for line in (body or "").split("\n"):
            m = re.match(r"\s*([a-z ]+?)\d*:\s*(.+)$", line, re.I)
            if m:
                kv[m[1].strip().lower()].append(m[2].strip())
        pls = sorted({int(x) for v in kv.get("power level", []) for x in re.findall(r"\d+", v)})
        out[title.lower()] = {"title": title, "power_levels": pls, "health": kv.get("health", []),
                              "weakness": (kv.get("weakness") or [None])[0], "resistance": (kv.get("resistance") or [None])[0],
                              "locations": kv.get("location", [])}
    return out


def spawn_status(root: Path) -> dict[str, str]:
    try:
        sc = json.loads((root / "evals" / "bench" / "spawn_classes.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {k: ("path" if isinstance(v, str) else "candidates") for k, v in sc.items() if not k.startswith("_")}


def build(root: Path, gear_pl: int) -> dict:
    cen, mem, wiki, spawn = census(root), combat_memory(root), wiki_monsters(root), spawn_status(root)
    creatures = []
    for cls, c in sorted(cen.items()):
        names = sorted(c["names"])
        name = names[0] if names else None
        mm = mem.get((name or "").lower(), {})
        w = wiki.get((name or "").lower(), {})
        live_pl = sorted(c["power_levels"])
        atks = sorted((mm.get("attacks") or {}).keys())
        row = {
            "class": cls, "name": name, "live_rows": c["rows"], "live_power_levels": live_pl,
            "live_max_health": sorted(c["max_health"]), "archetypes": sorted(c["archetypes"]),
            "full_path_seen_live": c["path"],
            "spawn_fixture": spawn.get(cls, "none"),
            "telegraphed_attacks_seen": atks, "attack_damage": {k: v["damage"] for k, v in (mm.get("attacks") or {}).items()},
            "fights": mm.get("fights", 0), "deaths_to_it": mm.get("deaths", 0), "max_damage_taken": mm.get("max_damage_taken", 0.0),
            "wiki_power_levels": w.get("power_levels", []), "wiki_weakness": w.get("weakness"), "wiki_locations": w.get("locations", []),
        }
        hostile = any(a in ("Aggressive", "NeutralUntilAttacked") for a in c["archetypes"])
        row["meets"] = {
            "prep_hard_fight": bool(live_pl) and max(live_pl) >= gear_pl + 2,
            "damage_trend": hostile and bool(atks) and (row["max_damage_taken"] > 0 or bool(row["attack_damage"])),
            "telegraph_dodges": len(atks) >= 2,
        }
        creatures.append(row)
    # wiki-only creatures that could satisfy prep_hard_fight (never seen live: path and spawn PL unverified)
    seen = {(r["name"] or "").lower() for r in creatures}
    wiki_only = [{"name": w["title"], "wiki_power_levels": w["power_levels"], "weakness": w["weakness"], "locations": w["locations"]}
                 for k, w in sorted(wiki.items()) if k not in seen and w["power_levels"] and min(w["power_levels"]) >= gear_pl + 2
                 and min(w["power_levels"]) <= gear_pl + 3]
    return {"gear_pl_assumed": gear_pl, "creatures": creatures, "wiki_only_prep_candidates": wiki_only,
            "unverified": [
                "a SPAWNED creature's power level: the wiki shows one class at several PLs by region (Giant Rat 1-5, Goblin Runt "
                "1/3/6), so the fixture's spawn may take the spot's region PL or the class default; read PowerLevel after spawn",
                "the spawn fixture's LoadAsset path for any class with spawn_fixture != 'path' (and even 'path' entries are "
                "deployed, not yet verified live: DISCOVERIES M1 runt spawn)",
                "a fresh dev character's gear PL (DISCOVERIES: GetCurrentEquipmentPowerLevel 1 with nothing held)"]}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--gear-pl", type=int, default=1, help="a fresh character's gear power level (default 1)")
    ap.add_argument("--out", default=str(ROOT / "logs" / "dev_facts" / "tactics_candidates.json"))
    ap.add_argument("--root", default=str(ROOT))
    a = ap.parse_args(argv)
    rep = build(Path(a.root), a.gear_pl)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(rep, indent=1, default=sorted), encoding="utf-8")
    for r in rep["creatures"]:
        m = [k for k, v in r["meets"].items() if v]
        print(f"{r['class']:<36} {str(r['name']):<14} PL live {r['live_power_levels']} wiki {r['wiki_power_levels']} "
              f"atk {len(r['telegraphed_attacks_seen'])} spawn {r['spawn_fixture']:<10} meets {m}")
    print(f"wiki-only prep candidates (PL {a.gear_pl + 2}-{a.gear_pl + 3}): "
          + ", ".join(f"{w['name']} {w['wiki_power_levels']}" for w in rep["wiki_only_prep_candidates"]))
    print(f"-> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

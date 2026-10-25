"""Build data/recipes_<build>.json: every recipe and crafting/processing station, from LIVE game
data (design: docs/design/robustness-and-item-catalog.md sections 18-19; schema: data/README.md).

Drives mod/scripts/recipe_dump.lua (read-only) on the live server through debug_run, one stage
per call, with a ping and a crash-dump count after each stage (it stops at the first new dump):
  1. recipes   every loaded URecipeData (FindAllOf)
  2. stations  station component templates (paths from the build's object dump, because FindAllOf
               skips archetypes) plus live placed stations
  3. tables    DT_CraftingStationsDataTable / processing rows / DT_Progression_* unlock rows
  4. player    the connected player's RecipesUnlocked (the unlock mirror snapshot) + interaction ranges
  5. items     names, stack sizes, durability, fuel values of every referenced item
then merges and normalises. Optionally cross-checks against the community wiki's structured
`recipe` Bucket table (one API request, cached under logs/recipes/, which is gitignored: the wiki
is CC BY-NC-SA and stays out of git).

  .venv\\Scripts\\python.exe -m tools.build_recipes                         # live stages + merge
  .venv\\Scripts\\python.exe -m tools.build_recipes --stages recipes,stations   # a subset
  .venv\\Scripts\\python.exe -m tools.build_recipes --merge-only logs\\recipes\\26161880_<ts>
  .venv\\Scripts\\python.exe -m tools.build_recipes --merge-only <dir> --wiki-check   # + wiki diff
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

from brain.paths import REPO_ROOT

BUILD = "26161880"
SCHEMA = "dw_recipes/1"
STAGES = ("recipes", "stations", "tables", "player", "items")
CRASH_DIR = Path(os.environ.get("DW_UE4SS_DIR", r"C:\GameServers\Dragonwilds\RSDragonwilds\Binaries\Win64\ue4ss"))
WIKI_API = "https://dragonwilds.runescape.wiki/api.php"
WIKI_UA = "DWCompanion-recipe-check/1.0 (private research bot; one request per run)"
INTERACTION_DISTANCE = ["Short", "Medium", "Long", "Fishing"]


# ------------------------------------------------------------------------------ live

def station_paths_from_dump(build: str) -> list[str]:
    """Blueprint component templates of the station components, from the build's UE4SS object dump."""
    p = REPO_ROOT / "dumps" / build / "UE4SS_ObjectDump.txt"
    if not p.exists():
        return []
    txt = p.read_text(encoding="utf-8", errors="replace")
    return sorted(set(re.findall(r"\] (?:CraftingStationComponent|ProcessingStationComponent) (/\S+_GEN_VARIABLE)", txt)))


def crash_count() -> int:
    return len(list(CRASH_DIR.glob("crash_*.dmp"))) if CRASH_DIR.exists() else -1


def run_live(a, raw_dir: Path) -> None:
    from brain.bridge_client import BridgeClient
    from brain.transport import file_transport_pair

    brain_side, _ = file_transport_pair()
    client = BridgeClient(brain_side)
    paths = station_paths_from_dump(a.build)
    dumps0 = crash_count()
    print(f"crash dumps before: {dumps0}; station templates from the dump: {len(paths)}")
    for i, stage in enumerate(a.stages, 1):
        args = {s: (s == stage) for s in STAGES}
        args.update({"build": a.build, "out": (raw_dir / f"{i:02d}_{stage}.json").as_posix()})
        if stage == "tables":
            args["stations"] = True  # the station rows' data tables come from the components' row handles
        if stage == "items":
            # items describes what the recipes/stations/tables of the SAME call reference
            args.update({"recipes": True, "stations": True, "tables": True})
        if args["stations"]:
            args["station_paths"] = paths
        t = time.monotonic()
        res = client.request("debug_run", {"module": "recipe_dump", "args": args}, timeout=a.timeout)
        result = (res.get("data") or {}).get("result") or {}
        print(f"[{stage}] ok={res.get('ok')} counts={result.get('counts')} cpu={result.get('cpu_ms')} ms "
              f"wall={time.monotonic() - t:.1f} s errors={result.get('errors')}")
        ping = client.request("ping", {}, timeout=10)
        dumps = crash_count()
        if not ping.get("ok") or dumps != dumps0:
            raise RuntimeError(f"stopping after {stage}: ping ok={ping.get('ok')}, crash dumps {dumps0} -> {dumps}")
        if not res.get("ok") or not result.get("ok"):
            raise RuntimeError(f"stage {stage} failed: {json.dumps(res)[:1500]}")


# ------------------------------------------------------------------------------ merge + normalise

def merge_raw(raw_dir: Path) -> dict:
    files = sorted(raw_dir.glob("*.json"))
    if not files:
        raise SystemExit(f"no raw recipe files in {raw_dir}")
    m = {"recipes": {}, "stations": {}, "tables": {}, "progression": {}, "items": {}, "players": [],
         "interaction_ranges": None, "errors": [], "files": [], "build": None}
    for f in files:
        doc = json.loads(f.read_text(encoding="utf-8"))
        m["files"].append(f.name)
        m["build"] = m["build"] or doc.get("build")
        for r in doc.get("recipes") or []:
            m["recipes"][r["path"]] = r
        for s in doc.get("stations") or []:
            m["stations"][s["path"]] = s
        for t in doc.get("tables") or []:
            m["tables"][t["path"]] = t
        for t in doc.get("progression") or []:
            m["progression"][t["path"]] = t
        for k, v in (doc.get("items") or {}).items():
            if v.get("loaded") or k not in m["items"]:
                m["items"][k] = v
        if doc.get("players"):
            m["players"] = doc["players"]
        if doc.get("interaction_ranges"):
            m["interaction_ranges"] = doc["interaction_ranges"]
        m["errors"].extend(doc.get("errors") or [])
    return m


def asset(path: str | None) -> str | None:
    if not path:
        return None
    return path.rsplit(".", 1)[-1] if "." in path.rsplit("/", 1)[-1] else path.rsplit("/", 1)[-1]


def norm_path(p: str) -> str:
    """Soft paths may come back as a package path; give them the object path form."""
    if "." in p.rsplit("/", 1)[-1]:
        return p
    return f"{p}.{p.rsplit('/', 1)[-1]}"


def is_test_station(sid: str) -> bool:
    """Developer test rows in DT_ProcessingStationDataTable (TestOnlyFuel, OnlyCatalyst, ...): no actor uses them."""
    return re.match(r"^(Test|Only)[A-Z]", sid) is not None


def stacks(lst, items) -> list[dict]:
    out = []
    for c in lst or []:
        info = items.get(c["item"]) or {}
        out.append({"item": asset(c["item"]), "path": c["item"], "count": c.get("count"), "name": info.get("name")})
    return out


def _r(x):
    return round(x, 3) if isinstance(x, float) else x


def normalise(m: dict, build: str) -> dict:
    items_raw = m["items"]
    # --- stations: group components by the row they read (the station TYPE), else by class
    tables = m["tables"]
    rows_by = {}
    for t in tables.values():
        for row in t.get("rows") or []:
            rows_by[(t["path"], row["row"])] = (t.get("kind"), row)
    stations: dict[str, dict] = {}
    recipe_stations: dict[str, set] = defaultdict(set)
    # Station TYPE id = its data-table row name; the same row name in two tables (BrewingCauldron is
    # both a crafting row and a processing row) gets "@<kind>" on the second.
    row_ids: dict[tuple, str] = {}
    taken: dict[str, tuple] = {}
    for (tpath, rname), (kind, _row) in sorted(rows_by.items(), key=lambda kv: (kv[1][0] != "crafting", kv[0])):
        sid = rname if rname not in taken else f"{rname}@{kind}"
        taken[sid] = (tpath, rname)
        row_ids[(tpath, rname)] = sid

    def station_rec(sid: str) -> dict:
        return stations.setdefault(sid, {"id": sid, "kind": None, "display_name": None, "classes": [],
                                         "class_names": [], "row": None, "recipes": [], "labels": {},
                                         "live": 0, "sources": []})

    for comp in m["stations"].values():
        row = comp.get("row") or {}
        sid = row_ids.get((row.get("table"), row.get("row"))) or row.get("row") or comp.get("owner_class_name")             or asset(comp["path"])
        st = station_rec(sid)
        st["kind"] = st["kind"] or comp.get("kind")
        if comp.get("owner_class") and comp["owner_class"] not in st["classes"]:
            st["classes"].append(comp["owner_class"])
            st["class_names"].append(comp.get("owner_class_name"))
        if row:
            st["row"] = row
        st["display_name"] = st["display_name"] or comp.get("display_name")
        if comp.get("interaction") and not st.get("interaction"):
            st["interaction"] = comp["interaction"]
        if not comp.get("template"):
            st["live"] += 1
        for k in ("is_vendor", "has_repair", "has_masterwork", "accepted_fuels", "accepted_resources", "store_output",
                  "spawn_item_class"):
            if comp.get(k) not in (None, []) and st.get(k) in (None, []):
                st[k] = comp[k]
        for p in comp.get("valid_recipes") or []:
            recipe_stations[p].add(sid)
            if "live_valid_recipes" not in st["sources"]:
                st["sources"].append("live_valid_recipes")
        hit = rows_by.get((row.get("table"), row.get("row")))
        if hit:
            kind, r = hit
            st["display_name"] = r.get("display_name") or st["display_name"]
            for k in ("is_vendor", "has_repair", "has_masterwork", "building", "vendor_tag", "processing_rate",
                      "max_resource_slots", "max_fuel_slots", "auto_start", "starting_fuel", "starting_fuel_count",
                      "can_start_through_ui"):
                if r.get(k) is not None:
                    st[k] = r[k]
            if r.get("accepted_fuels"):
                st["accepted_fuels"] = r["accepted_fuels"]
            for lab in r.get("labeled") or []:
                ids = [norm_path(p) for p in lab.get("recipes") or []]
                st["labels"].setdefault(lab.get("label") or "", []).extend(asset(p) for p in ids)
                for p in ids:
                    recipe_stations[p].add(sid)
            for p in r.get("recipes") or []:
                recipe_stations[p].add(sid)
            if "data_table_row" not in st["sources"]:
                st["sources"].append("data_table_row")
    # crafting-table rows with no component template loaded: still a station type (no class known)
    for (tpath, rname), (kind, r) in rows_by.items():
        sid = row_ids[(tpath, rname)]
        if sid in stations or not (r.get("labeled") or r.get("recipes")):
            continue
        st = station_rec(sid)
        st["kind"], st["row"], st["display_name"] = kind, {"table": tpath, "row": rname}, r.get("display_name")
        st["sources"].append("data_table_row_only")
        for lab in r.get("labeled") or []:
            ids = [norm_path(p) for p in lab.get("recipes") or []]
            st["labels"].setdefault(lab.get("label") or "", []).extend(asset(p) for p in ids)
            for p in ids:
                recipe_stations[p].add(sid)
        for p in r.get("recipes") or []:
            recipe_stations[p].add(sid)

    ranges = ((m.get("interaction_ranges") or {}).get("ranges")) or {}
    for st in stations.values():
        it = st.get("interaction") or {}
        name = it.get("distance_name")
        if name and ranges.get(name) is not None:
            it["range_cm"] = ranges[name]
        st["accepted_fuels"] = [asset(p) for p in st.get("accepted_fuels") or []]
        st["accepted_resources"] = [asset(p) for p in st.get("accepted_resources") or []]

    # --- unlocks
    unlocks: dict[str, list] = defaultdict(list)
    for t in m["progression"].values():
        for row in t.get("rows") or []:
            for p in row.get("recipes") or []:
                unlocks[p].append({"table": asset(t["path"]), "row": row["row"], "query": row.get("query"),
                                   "manual": row.get("manual"), "milestone": row.get("milestone")})

    # --- recipes
    recipes = {}
    rid_of = {}
    names = Counter(asset(p) for p in m["recipes"])
    for path, r in sorted(m["recipes"].items()):
        rid = asset(path)
        if names[rid] > 1:  # same asset name under two mount roots: id@root (as the items catalog does)
            rid = f"{rid}@{path.split('/')[1]}"
        rid_of[path] = rid
        sts = sorted(s for s in recipe_stations.get(path) or [] if not is_test_station(s))
        rec = {
            "id": rid, "path": path, "class": r.get("class"),
            "outputs": stacks(r.get("created"), items_raw), "inputs": stacks(r.get("consumed"), items_raw),
            "stations": sts,
            "station_kinds": sorted({stations[s]["kind"] for s in sts if stations[s].get("kind")}),
            "craft_time": _r(r.get("craft_time")), "max_craft_time": _r(r.get("max_craft_time")),
            "craft_quantity_multiplier": _r(r.get("craft_quantity_multiplier")),
            "processing_time": [_r(r.get("min_processing_time")), _r(r.get("max_processing_time"))],
            "extra": {"items": stacks(r.get("extra"), items_raw), "chance": _r(r.get("extra_chance"))}
            if r.get("extra") else None,
            "alternative": dict(stacks([r["alternative"]], items_raw)[0],
                                chance_attribute=asset(r.get("alternative_chance_attribute")))
            if r.get("alternative") else None,
            "fuel_override": stacks(r.get("fuel_override"), items_raw) or None,
            "tools": [],  # URecipeData has no required-but-not-consumed field in this build (Dominion.hpp:31900)
            "skill": asset(r.get("skill")), "xp": r.get("xp"),
            "unlock": {"bundles": unlocks.get(path) or [], "ignore_automatic_unlocks": r.get("ignore_automatic_unlocks")},
            "vendor_reputation": r.get("vendor_reputation"),
            "consume_individually": r.get("consume_individually") or None,
            "rune_type": r.get("rune_type"),
            "test": ("/Test/" in path or "_TEST_" in path.upper()) or None,
            "soft_deleted": r.get("soft_deleted") or None,
        }
        recipes[rid] = {k: v for k, v in rec.items() if v is not None}
    for st in stations.values():
        if is_test_station(st["id"]):
            st["test"] = True
        st["recipes"] = sorted({rid_of.get(p) or asset(p) for p, ss in recipe_stations.items() if st["id"] in ss})
        st["labels"] = {k: sorted(set(v)) for k, v in st["labels"].items()}

    items = {}
    for p, v in sorted(items_raw.items()):
        items[asset(p)] = {k: v.get(k) for k in ("name", "class", "max_stack", "durability", "fuel_value", "weight",
                                                 "category") if v.get(k) is not None}
        items[asset(p)]["path"] = p
    players = [{"name": p.get("name"), "recipes_unlocked": sorted({asset(x) for x in p.get("recipes_unlocked") or []}),
                "not_persisted": sorted({asset(x) for x in p.get("not_persisted") or []})} for p in m["players"]]
    return {
        "schema": SCHEMA, "build": build, "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": {"raw_files": m["files"], "errors": m["errors"][:200],
                   "counts": {"recipes": len(recipes), "stations": len(stations), "items": len(items),
                              "station_components": len(m["stations"]), "tables": len(m["tables"]),
                              "progression_tables": len(m["progression"])}},
        "interaction_ranges": m.get("interaction_ranges"),
        "recipes": recipes, "stations": dict(sorted(stations.items())), "items": items, "players": players,
    }


def summary(cat: dict) -> str:
    rs = cat["recipes"].values()
    return json.dumps({
        "recipes": len(cat["recipes"]), "stations": len(cat["stations"]), "items": len(cat["items"]),
        "recipes_with_station": sum(1 for r in rs if r.get("stations")),
        "recipes_without_station": sum(1 for r in rs if not r.get("stations")),
        "recipes_with_inputs": sum(1 for r in rs if r.get("inputs")),
        "recipes_with_unlock_bundle": sum(1 for r in rs if (r.get("unlock") or {}).get("bundles")),
        "by_station_kind": dict(Counter(",".join(r.get("station_kinds") or ["none"]) for r in rs)),
        "stations": {k: {"kind": v.get("kind"), "name": v.get("display_name"), "recipes": len(v["recipes"]),
                         "classes": v.get("class_names")} for k, v in cat["stations"].items()},
        "players": [{"name": p["name"], "unlocked": len(p["recipes_unlocked"])} for p in cat["players"]],
        "errors": len(cat["source"]["errors"]),
    }, indent=1)


# ------------------------------------------------------------------------------ wiki cross-check

def fetch_wiki_recipes(cache: Path, refresh: bool = False) -> list[dict]:
    if cache.exists() and not refresh:
        return json.loads(cache.read_text(encoding="utf-8"))
    q = "bucket('recipe').select('output','json').limit(5000).run()"
    url = WIKI_API + "?" + urllib.parse.urlencode({"action": "bucket", "format": "json", "query": q})
    req = urllib.request.Request(url, headers={"User-Agent": WIKI_UA})
    with urllib.request.urlopen(req, timeout=60) as resp:
        rows = json.loads(resp.read().decode("utf-8")).get("bucket") or []
    out = []
    for r in rows:
        try:
            j = json.loads(r.get("json") or "{}")
        except json.JSONDecodeError:
            continue
        outp = j.get("output") or {}
        out.append({"facility": j.get("facility"), "output": outp.get("name"), "output_qty": _int(outp.get("quantity")),
                    "materials": {m.get("name"): _int(m.get("quantity")) for m in j.get("materials") or []}})
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(out, indent=0), encoding="utf-8")
    return out


def _int(v):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None


def _key(s: str | None) -> str:
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def wiki_check(cat: dict, wiki: list[dict]) -> dict:
    """Compare game recipes with wiki rows that have the same output name and the same material
    names; report exact matches, quantity mismatches and game recipes with no wiki row."""
    by_out = defaultdict(list)
    for w in wiki:
        if w.get("facility") == "Build Menu":
            continue
        by_out[_key(w["output"])].append(w)
    station_names = {k: v.get("display_name") for k, v in cat["stations"].items()}
    res = {"compared": 0, "match": 0, "qty_mismatch": [], "no_wiki_row": 0, "facility_mismatch": [], "examples": []}
    for rid, r in cat["recipes"].items():
        if r.get("test") or not r.get("outputs") or not r.get("inputs"):
            continue
        out = r["outputs"][0]
        cands = by_out.get(_key(out.get("name")))
        if not cands:
            res["no_wiki_row"] += 1
            continue
        mats = {_key(i.get("name")): i["count"] for i in r["inputs"]}
        best = None
        for w in cands:
            wm = {_key(k): v for k, v in w["materials"].items()}
            if set(wm) == set(mats):
                best = w
                break
        res["compared"] += 1
        if best is None:
            res["qty_mismatch"].append({"recipe": rid, "game": {i["name"]: i["count"] for i in r["inputs"]},
                                        "wiki": [w["materials"] for w in cands][:3], "why": "different materials"})
            continue
        wm = {_key(k): v for k, v in best["materials"].items()}
        same_qty = all(wm[k] == v for k, v in mats.items()) and (best.get("output_qty") in (None, out["count"]))
        game_fac = {station_names.get(s) for s in r.get("stations") or []}
        if best.get("facility") and game_fac and best["facility"] not in game_fac:
            res["facility_mismatch"].append({"recipe": rid, "game": sorted(x for x in game_fac if x),
                                             "wiki": best["facility"]})
        if same_qty:
            res["match"] += 1
            if len(res["examples"]) < 10 or "Iron Bar" in (out.get("name") or ""):
                res["examples"].append({"recipe": rid, "output": f"{out['count']} {out.get('name')}",
                                        "inputs": {i["name"]: i["count"] for i in r["inputs"]},
                                        "stations": sorted(x for x in game_fac if x), "wiki_facility": best["facility"]})
        else:
            res["qty_mismatch"].append({"recipe": rid, "game": {i["name"]: i["count"] for i in r["inputs"]},
                                        "game_output": out["count"], "wiki": best["materials"],
                                        "wiki_output": best.get("output_qty"), "why": "quantities differ"})
    res["qty_mismatch_count"] = len(res["qty_mismatch"])
    res["facility_mismatch_count"] = len(res["facility_mismatch"])
    return res


# ------------------------------------------------------------------------------ Lua data for the mod

LUA_OUT = REPO_ROOT / "mod" / "body" / "recipe_data.lua"


def lua(v) -> str:
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(round(v, 4) if isinstance(v, float) else v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(v, list):
        return "{" + ", ".join(lua(x) for x in v) + "}"
    if isinstance(v, dict):
        parts = []
        for k in sorted(v):
            key = k if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k) else f"[{lua(k)}]"
            parts.append(f"{key} = {lua(v[k])}")
        return "{" + ", ".join(parts) + "}"
    raise TypeError(type(v))


def lua_data(cat: dict) -> dict:
    """The compact table body/crafting.lua loads: only what the emulation needs, item paths as keys."""
    used = set()
    recipes = {}
    for rid, r in cat["recipes"].items():
        if r.get("test") or r.get("soft_deleted"):
            continue
        rec = {"path": r["path"],
               "inputs": [[i["path"], i["count"]] for i in r.get("inputs") or []],
               "outputs": [[o["path"], o["count"]] for o in r.get("outputs") or []],
               "stations": r.get("stations") or [],
               "t": r.get("craft_time"), "tmax": r.get("max_craft_time"), "qm": r.get("craft_quantity_multiplier"),
               "pt": r.get("processing_time")}
        if r.get("fuel_override"):
            rec["fuel"] = [[f["path"], f["count"]] for f in r["fuel_override"]]
        if r.get("extra") and (r["extra"].get("chance") or 0) > 0:
            rec["extra"] = {"chance": r["extra"]["chance"], "items": [[x["path"], x["count"]] for x in r["extra"]["items"]]}
        if r.get("vendor_reputation"):
            rec["rep"] = [r["vendor_reputation"].get("tag"), r["vendor_reputation"].get("amount")]
        for lst in (rec["inputs"], rec["outputs"], rec.get("fuel") or [], (rec.get("extra") or {}).get("items") or []):
            used.update(x[0] for x in lst)
        recipes[rid] = rec
    stations = {}
    for sid, st in cat["stations"].items():
        if st.get("test") or not st.get("recipes"):
            continue
        fuels = [cat["items"][f]["path"] for f in st.get("accepted_fuels") or [] if f in cat["items"]]
        used.update(fuels)
        stations[sid] = {"kind": st.get("kind"), "name": st.get("display_name"), "classes": st.get("class_names") or [],
                         "range": (st.get("interaction") or {}).get("distance_name"),
                         "rate": st.get("processing_rate"), "fuels": fuels, "vendor": st.get("is_vendor") or False}
    items = {}
    by_path = {v["path"]: (k, v) for k, v in cat["items"].items()}
    for p in sorted(used):
        k, v = by_path.get(p, (asset(p), {}))
        items[p] = {"id": k, "name": v.get("name"), "max_stack": v.get("max_stack"), "durability": v.get("durability"),
                    "fuel": v.get("fuel_value")}
    snap = (cat.get("players") or [{}])[0]
    return {"schema": "dw_recipe_data/1", "build": cat["build"],
            "interaction_ranges": ((cat.get("interaction_ranges") or {}).get("ranges")) or {},
            "recipes": recipes, "stations": stations, "items": items,
            "unlocked_snapshot": {"player": snap.get("name"), "ids": snap.get("recipes_unlocked") or []}}


def write_lua(cat: dict, path: Path = LUA_OUT) -> Path:
    d = lua_data(cat)
    lines = [f"-- GENERATED by tools/build_recipes.py from data/recipes_{cat['build']}.json. Do not edit by hand.",
             "-- Recipes/stations/items for body/crafting.lua (schema dw_recipe_data/1, see data/README.md).",
             "local D = {}",
             f"D.schema = {lua(d['schema'])}", f"D.build = {lua(d['build'])}",
             f"D.interaction_ranges = {lua(d['interaction_ranges'])}",
             f"D.unlocked_snapshot = {lua(d['unlocked_snapshot'])}",
             "D.stations = {"]
    lines += [f"  [{lua(k)}] = {lua(v)}," for k, v in sorted(d["stations"].items())]
    lines += ["}", "D.items = {"]
    lines += [f"  [{lua(k)}] = {lua(v)}," for k, v in sorted(d["items"].items())]
    lines += ["}", "D.recipes = {"]
    lines += [f"  [{lua(k)}] = {lua(v)}," for k, v in sorted(d["recipes"].items())]
    lines += ["}", "return D", ""]
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    return path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", default=BUILD)
    ap.add_argument("--stages", default=",".join(STAGES), help=f"comma list of {STAGES}")
    ap.add_argument("--timeout", type=float, default=90.0)
    ap.add_argument("--merge-only", metavar="RAW_DIR", help="skip the server; merge an existing raw directory")
    ap.add_argument("--wiki-check", action="store_true", help="compare with the wiki's recipe Bucket table")
    ap.add_argument("--wiki-refresh", action="store_true", help="re-download the wiki table (else the cache)")
    ap.add_argument("--out", help="default data/recipes_<build>.json")
    ap.add_argument("--no-lua", action="store_true", help="do not regenerate mod/body/recipe_data.lua")
    a = ap.parse_args()
    a.stages = [s for s in a.stages.split(",") if s]
    bad = [s for s in a.stages if s not in STAGES]
    if bad:
        raise SystemExit(f"unknown stage(s) {bad}; known: {STAGES}")

    if a.merge_only:
        raw_dir = Path(a.merge_only)
    else:
        raw_dir = REPO_ROOT / "logs" / "recipes" / f"{a.build}_{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
        raw_dir.mkdir(parents=True, exist_ok=True)
        try:
            run_live(a, raw_dir)
        except RuntimeError as exc:
            print(f"live run stopped: {exc}\nmerging what was written so far from {raw_dir}", file=sys.stderr)
    cat = normalise(merge_raw(raw_dir), a.build)
    if a.wiki_check:
        wiki = fetch_wiki_recipes(REPO_ROOT / "logs" / "recipes" / "wiki_recipe_bucket.json", a.wiki_refresh)
        chk = wiki_check(cat, wiki)
        report = REPO_ROOT / "logs" / "recipes" / f"wiki_check_{a.build}.json"
        report.write_text(json.dumps(chk, indent=1, ensure_ascii=False), encoding="utf-8")
        cat["wiki_check"] = {k: chk[k] for k in ("compared", "match", "qty_mismatch_count", "facility_mismatch_count",
                                                 "no_wiki_row")}
        cat["wiki_check"]["report"] = report.relative_to(REPO_ROOT).as_posix()
        print("wiki check:", json.dumps(cat["wiki_check"]), "\nexamples:", json.dumps(chk["examples"][:12], indent=1))
    out = Path(a.out) if a.out else REPO_ROOT / "data" / f"recipes_{a.build}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(cat, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {out}\n{summary(cat)}")
    if not a.no_lua:
        print(f"wrote {write_lua(cat)}")


if __name__ == "__main__":
    main()

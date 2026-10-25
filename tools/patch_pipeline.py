"""Game-patch delta pipeline (CLAUDE.md section 2 "Game patches"; design: docs/design/
robustness-and-item-catalog.md section 11; runbook: docs/RUNBOOK-patch.md).

After a patch, one command tells an agent what changed and what needs work:

  .venv\\Scripts\\python.exe -m tools.patch_pipeline snapshot                  # copy the fresh UE4SS dumps to dumps/<build>/
  .venv\\Scripts\\python.exe -m tools.patch_pipeline deps                      # write data/dependencies.json
  .venv\\Scripts\\python.exe -m tools.patch_pipeline diff 26161880 <new>       # dump diff + BREAKING deps
  .venv\\Scripts\\python.exe -m tools.patch_pipeline catalog-diff 26161880 <new>
  .venv\\Scripts\\python.exe -m tools.patch_pipeline report 26161880 <new>     # combined: docs/patches/<old>_to_<new>.md/.json

What it reads (never the live server):
  * dumps/<build>/CXXHeaderDump/*.hpp : classes, structs, parents, properties (type, offset), functions
    (parameter lists), enums. Stream-parsed line by line.
  * dumps/<build>/UE4SS_ObjectDump.txt : stream-parsed (about 50 MB, never held in memory) for the
    asset list (every non-/Script top-level object) and the members of Blueprint classes.
    CAVEAT: it lists LOADED objects only, so an asset missing from a new dump may just be unloaded.
    Asset findings are therefore cross-checked against the new catalog before they count as BROKEN.
  * data/items_<build>.json (+ spells_<build>.json, enemies_<build>.json when present).
  * mod/**/*.lua and brain/BRIDGE_PROTOCOL.md for the dependency list.

Offsets are recorded but never relied on (CLAUDE.md section 7): an offset-only change is "info".
The parsed dump is cached as dumps/<build>/index.json.gz (gitignored) so a diff takes seconds.
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import shutil
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
INDEX_SCHEMA = "dw_dump_index/1"
DEPS_SCHEMA = "dw_deps/1"
APP_ID = 4019830

# Tiers: where a dependency is used. core = the live body; tooling = catalog/dump scripts (a break
# stops the post-patch rebuild); debug = experiments, probes, tests (a break is a review item).
TOOLING_STEMS = {"catalog", "spell_dump", "dumper", "perf_sampler"}
DEBUG_RE = re.compile(r"(_test|_probe|_x\d+)$|^test_")

# Class families that matter to the companion. A NEW class under one of these roots gets flagged.
FAMILIES = {
    "UPlayerAction": "player action / attack set (combat profile, catalog attack sets)",
    "UPlayerAttackData": "player attack data (swing damage, chain)",
    "UHeldEquipmentData": "held equipment data class (weapons, tools)",
    "UWearableEquipmentData": "wearable equipment data class (armour)",
    "UItemData": "item data class",
    "ADominionAICharacter": "creature / enemy class (enemy catalog, combat behaviour)",
    "UDominionSpellData": "spell data class (spell catalog role tags)",
    "UDominionSpellModule_Static": "spell module kind (spell casting route)",
}
# Classes whose field names data/README.md says the catalog reads. Any change there = rebuild + review.
CATALOG_CLASSES = ["UItemData", "UEquipmentData", "UHeldEquipmentData", "UWearableEquipmentData", "UPlayerAction",
                   "UPlayerMeleeAttackAction", "UPlayerAttackData", "UPlayerRangedAttackCollection"]
# Asset types whose individual paths are not worth listing in the report (still counted, still in JSON).
NOISE_ASSET_TYPES = {"Texture2D", "SoundWave", "StaticMesh", "SkeletalMesh", "Material", "MaterialInstanceConstant",
                     "MaterialInstanceDynamic", "MaterialFunction", "Texture2DDynamic", "TextureRenderTarget2D",
                     "SoundCue", "SoundClass", "SoundMix", "AnimSequence", "AnimMontage", "NiagaraSystem",
                     "NiagaraEmitter", "ParticleSystem", "StaticMeshComponent", "SceneComponent", "OverlaySlot",
                     "SCS_Node", "WorldPartitionRuntimeLevelStreamingCell", "WorldPartitionRuntimeCellDataSpatialHash",
                     "WorldPartitionLevelStreamingDynamic", "MovieSceneBuiltInEasingFunction", "PhysicsAsset",
                     "BlendSpace", "CurveFloat", "CurveLinearColor", "Font", "FontFace", "PhysicalMaterial"}
REPORT_LIST_CAP = 40
MIN_HPP = 50  # a finished GenerateSDK writes thousands of headers; fewer means it is still running


# ------------------------------------------------------------------------------ context / paths

@dataclass
class Ctx:
    dumps_dir: Path = field(default_factory=lambda: Path(os.environ.get("DW_DUMPS_DIR", REPO_ROOT / "dumps")))
    data_dir: Path = field(default_factory=lambda: Path(os.environ.get("DW_DATA_DIR", REPO_ROOT / "data")))
    out_dir: Path = field(default_factory=lambda: Path(os.environ.get("DW_PATCH_DOCS_DIR", REPO_ROOT / "docs" / "patches")))
    mod_dir: Path = field(default_factory=lambda: REPO_ROOT / "mod")
    protocol_md: Path = field(default_factory=lambda: REPO_ROOT / "brain" / "BRIDGE_PROTOCOL.md")
    py_sources: list = field(default_factory=lambda: [REPO_ROOT / "tools" / "build_catalog.py",
                                                      REPO_ROOT / "tools" / "gen_attack_data.py"])
    use_py_enum_maps: bool = True

    def dump_dir(self, build: str) -> Path:
        return self.dumps_dir / str(build)


def server_root() -> Path:
    return Path(os.environ.get("DW_SERVER_ROOT") or r"C:\GameServers\Dragonwilds")


def server_build_id() -> str | None:
    """Same source as tools/config.ps1 Get-ServerBuildId: the SteamCMD appmanifest."""
    acf = server_root() / "steamapps" / f"appmanifest_{APP_ID}.acf"
    if not acf.exists():
        return None
    m = re.search(r'"buildid"\s+"(\d+)"', acf.read_text(errors="replace"))
    return m.group(1) if m else None


def ue4ss_dir() -> Path:
    env = os.environ.get("DW_UE4SS_DIR")
    return Path(env) if env else server_root() / "RSDragonwilds" / "Binaries" / "Win64" / "ue4ss"


# ------------------------------------------------------------------------------ hpp parsing

CLS_RE = re.compile(r"^(class|struct)\s+(\w+)\s*(?::\s*(.*?))?\s*$")
PROP_RE = re.compile(r"^\s{4}(?P<type>.+?)\s+(?P<name>\w+)(?P<arr>\[\w+\])?\s*;\s*//\s*0x(?P<off>[0-9A-Fa-f]+)")
FUNC_RE = re.compile(r"^\s{4}(?:static\s+)?(?P<ret>[\w:<>*&\s,]+?)\s+(?P<name>\w+)\((?P<params>.*)\)\s*(?:const\s*)?;\s*$")
END_RE = re.compile(r"^\};\s*//\s*Size:\s*0x(?P<size>[0-9A-Fa-f]+)")
ENUM_RE = re.compile(r"^enum\s+(?:class\s+)?(\w+)(?:\s*:\s*[\w:]+)?\s*\{?\s*$")
NS_RE = re.compile(r"^namespace\s+(\w+)\s*\{?\s*$")
ENUM_VAL_RE = re.compile(r"^\s+(\w+)\s*(?:=\s*(-?(?:0[xX][0-9A-Fa-f]+|\d+)))?\s*,?\s*(?://.*)?$")
PARENT_RE = re.compile(r"public\s+([\w:<>]+)")


def parse_hpp_file(path: Path):
    """Yield ('class'|'enum', record) for one header. Line-based; never holds the whole file."""
    stem = path.stem
    module = stem[:-6] if stem.endswith("_enums") else stem
    cur = None
    enum = None
    ns = None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if cur is not None:
                if line.startswith("};"):
                    m = END_RE.match(line)
                    cur["size"] = int(m.group("size"), 16) if m else None
                    yield "class", cur
                    cur = None
                    continue
                m = PROP_RE.match(line)
                if m:
                    cur["props"][m.group("name")] = [m.group("type").strip() + (m.group("arr") or ""), int(m.group("off"), 16)]
                    continue
                m = FUNC_RE.match(line)
                if m:
                    cur["funcs"][m.group("name")] = m.group("params").strip()
                continue
            if enum is not None:
                if line.startswith("}") or line.strip().startswith("};"):
                    yield "enum", enum
                    enum = None
                    continue
                m = ENUM_VAL_RE.match(line)
                if m:
                    val = m.group(2)
                    enum["values"][m.group(1)] = int(val, 0) if val is not None else len(enum["values"])
                continue
            if not line.strip() or line.startswith(("#", "//")):
                continue
            if line.startswith("}"):
                ns = None
                continue
            m = CLS_RE.match(line)
            if m:
                parent_m = PARENT_RE.search(m.group(3) or "")
                cur = {"kind": m.group(1), "name": m.group(2), "module": module, "stem": stem,
                       "parent": parent_m.group(1) if parent_m else None, "props": {}, "funcs": {}, "size": None}
                continue
            m = NS_RE.match(line)
            if m:
                ns = m.group(1)
                continue
            m = ENUM_RE.match(line.strip())
            if m:
                name = m.group(1)
                if name == "Type" and ns:
                    name = ns
                enum = {"name": name, "module": module, "stem": stem, "values": {}}
    if cur is not None:  # truncated file: keep what we got
        yield "class", cur
    if enum is not None:
        yield "enum", enum


def parse_cxx_dir(cxx_dir: Path):
    classes: dict[str, dict] = {}
    enums: dict[str, dict] = {}
    seen: dict[str, list] = defaultdict(list)  # name -> [records] to resolve duplicates
    for p in sorted(cxx_dir.glob("*.hpp")):
        for kind, rec in parse_hpp_file(p):
            if kind == "class":
                seen[rec["name"]].append(rec)
            else:
                enums.setdefault(rec["name"], rec)
    for name, recs in seen.items():
        # Same name defined in several headers (for example the per-animation-blueprint
        # FAnimBlueprintGeneratedConstantData structs): disambiguate deterministically.
        keys = [name] if len(recs) == 1 else [f"{name}@{r['stem']}" for r in recs]
        for key, r in zip(keys, recs):
            classes[key] = {"kind": r["kind"], "module": r["module"], "parent": r["parent"], "size": r["size"],
                            "props": r["props"], "funcs": r["funcs"]}
    for e in enums.values():
        e.pop("stem", None)
    return classes, enums


# ------------------------------------------------------------------------------ object dump parsing

CLASSY_TYPES = ("Class", "BlueprintGeneratedClass", "WidgetBlueprintGeneratedClass", "AnimBlueprintGeneratedClass")


def parse_object_dump(path: Path):
    """Stream the UE4SS object dump. Returns (assets, bp_members, stats).

    assets: {object path: type} for every non-/Script top-level object (no ':' in the path).
    bp_members: {class path: {member: "Function(P:Type,...)" | "<Type>Property"}} for non-/Script classes.
    """
    assets: dict[str, str] = {}
    members: dict[str, dict[str, str]] = {}
    class_owners: set[str] = set()
    func_params: dict[tuple[str, str], list[str]] = {}
    stats = Counter()
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.startswith("["):
                continue
            parts = line.split(None, 3)
            if len(parts) < 3:
                continue
            otype, opath = parts[1], parts[2]
            stats["lines"] += 1
            if otype == "Package" or opath.startswith("/Script/"):
                continue
            colon = opath.find(":")
            if colon < 0:
                assets[opath] = otype
                if otype in CLASSY_TYPES:
                    class_owners.add(opath)
                continue
            owner, rest = opath[:colon], opath[colon + 1:]
            if owner not in class_owners:
                stats["member_owner_not_class"] += 1
                continue
            if otype == "Function":
                members.setdefault(owner, {})[rest] = "Function()"
                func_params[(owner, rest)] = []
            elif ":" in rest:  # a function parameter
                fn, pname = rest.split(":", 1)
                if (owner, fn) in func_params and "." not in pname:
                    func_params[(owner, fn)].append(f"{pname}:{otype}")
            elif "." not in rest:
                members.setdefault(owner, {})[rest] = otype
    for (owner, fn), params in func_params.items():
        members[owner][fn] = "Function(" + ",".join(params) + ")"
    stats["assets"] = len(assets)
    stats["bp_classes"] = len(members)
    return assets, members, dict(stats)


# ------------------------------------------------------------------------------ index

def _sources_stamp(dump_dir: Path) -> dict:
    cxx = dump_dir / "CXXHeaderDump"
    obj = dump_dir / "UE4SS_ObjectDump.txt"
    files = list(cxx.glob("*.hpp")) if cxx.is_dir() else []
    return {"hpp_count": len(files), "hpp_bytes": sum(f.stat().st_size for f in files),
            "objdump_bytes": obj.stat().st_size if obj.exists() else None}


def build_index(dump_dir: Path, build: str) -> dict:
    cxx = dump_dir / "CXXHeaderDump"
    if not cxx.is_dir():
        raise SystemExit(f"error: {cxx} not found (run `snapshot --build {build}` first)")
    classes, enums = parse_cxx_dir(cxx)
    assets, bp_members, ostats = {}, {}, {}
    obj = dump_dir / "UE4SS_ObjectDump.txt"
    if obj.exists():
        assets, bp_members, ostats = parse_object_dump(obj)
    return {"schema": INDEX_SCHEMA, "build": str(build), "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "sources": _sources_stamp(dump_dir), "object_dump_stats": ostats,
            "classes": classes, "enums": enums, "assets": assets, "bp_members": bp_members}


class Index:
    """Parsed dump with lookup helpers."""

    PREFIX_RE = re.compile(r"^[UAFEI](?=[A-Z])")

    def __init__(self, data: dict):
        self.data = data
        self.build = data["build"]
        self.classes: dict = data["classes"]
        self.enums: dict = data["enums"]
        self.assets: dict = data["assets"]
        self.bp_members: dict = data["bp_members"]
        self.has_object_dump = bool(self.assets)
        self._by_short: dict[str, list[str]] | None = None
        self._base_map: dict[str, list[str]] | None = None
        self._owners: dict[str, list[tuple[str, str]]] | None = None
        self.modules = {c["module"] for c in self.classes.values()} | {e["module"] for e in self.enums.values()}

    # -- classes
    @staticmethod
    def base_name(key: str) -> str:
        return key.split("@", 1)[0]

    @property
    def by_short(self) -> dict[str, list[str]]:
        if self._by_short is None:
            d: dict[str, list[str]] = defaultdict(list)
            for key in self.classes:
                name = self.base_name(key)
                d[name].append(key)
                stripped = self.PREFIX_RE.sub("", name, count=1)
                if stripped != name:
                    d[stripped].append(key)
            self._by_short = d
        return self._by_short

    def resolve_class(self, module: str | None, short: str) -> str | None:
        """Class/struct key for a `/Script/<module>.<short>` style name (short has no U/A/F prefix)."""
        if short.startswith("Default__"):
            short = short[len("Default__"):]
        for key in self.by_short.get(short, []):
            if module is None or self.classes[key]["module"] == module:
                return key
        e = self.enums.get(short)
        if e and (module is None or e["module"] == module):
            return "enum:" + short
        return None

    def parent_key(self, key: str) -> str | None:
        parent = self.classes.get(key, {}).get("parent")
        if not parent:
            return None
        if parent in self.classes:
            return parent
        alts = self.base_map.get(parent)
        return alts[0] if alts else None

    @property
    def base_map(self) -> dict[str, list[str]]:
        if self._base_map is None:
            d: dict[str, list[str]] = defaultdict(list)
            for key in self.classes:
                d[self.base_name(key)].append(key)
            self._base_map = d
        return self._base_map

    def ancestors(self, key: str, limit: int = 40):
        seen = 0
        while key and seen < limit:
            yield key
            key = self.parent_key(key)
            seen += 1

    def find_member(self, key: str, name: str):
        """('prop', type) / ('func', params) for a member on the class or an ancestor, else None."""
        for k in self.ancestors(key):
            c = self.classes[k]
            if name in c["props"]:
                return "prop", c["props"][name][0]
            if name in c["funcs"]:
                return "func", c["funcs"][name]
        return None

    # -- members by bare name (for dependency owner lookups)
    @property
    def owners(self) -> dict[str, list[tuple[str, str]]]:
        if self._owners is None:
            d: dict[str, list[tuple[str, str]]] = defaultdict(list)
            for key, c in self.classes.items():
                for n in c["props"]:
                    d[n].append((key, "prop"))
                for n in c["funcs"]:
                    d[n].append((key, "func"))
            for owner, ms in self.bp_members.items():
                for n, t in ms.items():
                    d[n].append(("bp:" + owner, "func" if t.startswith("Function") else "prop"))
            self._owners = d
        return self._owners

    def member_sig(self, owner: str, name: str):
        """(kind, signature) for an owner from `owners` (class key, or 'bp:<path>')."""
        if owner.startswith("bp:"):
            t = self.bp_members.get(owner[3:], {}).get(name)
            return None if t is None else (("func" if t.startswith("Function") else "prop"), t)
        if owner not in self.classes:
            return None
        return self.find_member(owner, name)

    def owner_exists(self, owner: str) -> bool:
        return owner[3:] in self.assets if owner.startswith("bp:") else owner in self.classes


def ensure_index(ctx: Ctx, build: str, write_cache: bool = True) -> Index:
    dump_dir = ctx.dump_dir(build)
    cache = dump_dir / "index.json.gz"
    if cache.exists():
        try:
            with gzip.open(cache, "rt", encoding="utf-8") as fh:
                data = json.load(fh)
            if data.get("schema") == INDEX_SCHEMA and data.get("sources") == _sources_stamp(dump_dir):
                return Index(data)
        except (OSError, ValueError, KeyError):
            pass
    data = build_index(dump_dir, build)
    if write_cache:
        try:
            tmp = cache.with_suffix(".tmp")
            with gzip.open(tmp, "wt", encoding="utf-8", compresslevel=6) as fh:
                json.dump(data, fh, separators=(",", ":"))
            tmp.replace(cache)
        except OSError as exc:
            print(f"warning: could not write index cache {cache}: {exc}", file=sys.stderr)
    return Index(data)


# ------------------------------------------------------------------------------ params / diff

def split_params(s: str) -> list[tuple[str, str]]:
    """'const TArray<FFoo>& A, int32 B' -> [('const TArray<FFoo>&', 'A'), ('int32', 'B')]."""
    out, depth, cur = [], 0, []
    for ch in s:
        if ch in "<(":
            depth += 1
        elif ch in ">)":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        out.append("".join(cur))
    res = []
    for p in out:
        p = re.sub(r"\s+", " ", p.strip())
        m = re.match(r"^(.*?[\s&*>])(\w+)$", p)
        res.append((m.group(1).strip(), m.group(2)) if m else (p, ""))
    return res


def func_change(old: str, new: str) -> str | None:
    """None if identical; 'renamed' if only parameter names differ; else 'signature'."""
    if old == new:
        return None
    po, pn = split_params(old), split_params(new)
    if [t for t, _ in po] == [t for t, _ in pn]:
        return "renamed"
    return "signature"


def _dict_diff(old: dict, new: dict):
    added = {k: new[k] for k in new if k not in old}
    removed = {k: old[k] for k in old if k not in new}
    common = [k for k in old if k in new]
    return added, removed, common


def diff_dumps(old: Index, new: Index) -> dict:
    out: dict = {"old": old.build, "new": new.build}
    # classes and structs
    added = sorted(k for k in new.classes if k not in old.classes)
    removed = sorted(k for k in old.classes if k not in new.classes)
    changed: dict[str, dict] = {}
    offset_only = 0
    for k in old.classes:
        if k not in new.classes:
            continue
        o, n = old.classes[k], new.classes[k]
        ch: dict = {}
        if o["parent"] != n["parent"]:
            ch["parent"] = [o["parent"], n["parent"]]
        pa, pr, pc = _dict_diff(o["props"], n["props"])
        ptype = {x: [o["props"][x][0], n["props"][x][0]] for x in pc if o["props"][x][0] != n["props"][x][0]}
        poff = {x: [o["props"][x][1], n["props"][x][1]] for x in pc
                if o["props"][x][1] != n["props"][x][1] and x not in ptype}
        if pa:
            ch["props_added"] = {x: v[0] for x, v in pa.items()}
        if pr:
            ch["props_removed"] = {x: v[0] for x, v in pr.items()}
        if ptype:
            ch["props_type_changed"] = ptype
        fa, fr, fc = _dict_diff(o["funcs"], n["funcs"])
        fchg = {}
        for x in fc:
            kind = func_change(o["funcs"][x], n["funcs"][x])
            if kind:
                fchg[x] = {"old": o["funcs"][x], "new": n["funcs"][x], "kind": kind}
        if fa:
            ch["funcs_added"] = fa
        if fr:
            ch["funcs_removed"] = fr
        if fchg:
            ch["funcs_changed"] = fchg
        if o["module"] != n["module"]:
            ch["module"] = [o["module"], n["module"]]
        if poff or (o["size"] != n["size"]):
            ch["offset_info"] = {"size": [o["size"], n["size"]], "offset_changed_count": len(poff),
                                 "offset_changed_sample": {x: [hex(a), hex(b)] for x, (a, b) in list(poff.items())[:8]}}
        if ch:
            if set(ch) == {"offset_info"}:
                offset_only += 1
            changed[k] = ch
    out["classes"] = {"added": added, "removed": removed, "changed": changed}
    # enums
    e_added = sorted(k for k in new.enums if k not in old.enums)
    e_removed = sorted(k for k in old.enums if k not in new.enums)
    e_changed = {}
    for k in old.enums:
        if k not in new.enums:
            continue
        va, vr, vc = _dict_diff(old.enums[k]["values"], new.enums[k]["values"])
        vchg = {x: [old.enums[k]["values"][x], new.enums[k]["values"][x]] for x in vc
                if old.enums[k]["values"][x] != new.enums[k]["values"][x]}
        if va or vr or vchg:
            e_changed[k] = {"values_added": va, "values_removed": vr, "values_changed": vchg}
    out["enums"] = {"added": e_added, "removed": e_removed, "changed": e_changed}
    # assets (loaded-object list: see module docstring caveat)
    a_added = defaultdict(list)
    a_removed = defaultdict(list)
    for p, t in new.assets.items():
        if p not in old.assets:
            a_added[t].append(p)
    for p, t in old.assets.items():
        if p not in new.assets:
            a_removed[t].append(p)
    out["assets"] = {"added": {t: sorted(v) for t, v in sorted(a_added.items())},
                     "removed": {t: sorted(v) for t, v in sorted(a_removed.items())},
                     "both_have_object_dump": old.has_object_dump and new.has_object_dump}
    # Blueprint class members
    bp_changed = {}
    for owner, om in old.bp_members.items():
        nm = new.bp_members.get(owner)
        if nm is None:
            continue
        a, r, c = _dict_diff(om, nm)
        chg = {x: [om[x], nm[x]] for x in c if om[x] != nm[x]}
        if a or r or chg:
            bp_changed[owner] = {"added": a, "removed": r, "changed": chg}
    out["bp_members"] = {"changed": bp_changed}
    out["summary"] = {
        "classes_added": len(added), "classes_removed": len(removed), "classes_changed": len(changed),
        "classes_changed_offset_only": offset_only,
        "props_added": sum(len(c.get("props_added", {})) for c in changed.values()),
        "props_removed": sum(len(c.get("props_removed", {})) for c in changed.values()),
        "props_type_changed": sum(len(c.get("props_type_changed", {})) for c in changed.values()),
        "funcs_added": sum(len(c.get("funcs_added", {})) for c in changed.values()),
        "funcs_removed": sum(len(c.get("funcs_removed", {})) for c in changed.values()),
        "funcs_changed": sum(len(c.get("funcs_changed", {})) for c in changed.values()),
        "enums_added": len(e_added), "enums_removed": len(e_removed), "enums_changed": len(e_changed),
        "assets_added": sum(len(v) for v in a_added.values()), "assets_removed": sum(len(v) for v in a_removed.values()),
        "bp_classes_changed": len(bp_changed),
    }
    out["summary"]["total_changes"] = sum(v for k, v in out["summary"].items() if k != "classes_changed_offset_only")
    return out


def new_family_classes(old: Index, new: Index, d: dict) -> list[dict]:
    """Added classes that descend from one of FAMILIES' roots."""
    res = []
    for key in d["classes"]["added"]:
        for anc in new.ancestors(key):
            if anc != key and anc in FAMILIES:
                res.append({"class": key, "family": anc, "why": FAMILIES[anc], "module": new.classes[key]["module"]})
                break
    return res


# ------------------------------------------------------------------------------ Lua scanning

def lex_lua(src: str):
    """Return (literals [(line, text)], code with strings blanked and comments removed, newlines kept)."""
    lits: list[tuple[int, str]] = []
    code: list[str] = []
    i, n, line = 0, len(src), 1
    long_re = re.compile(r"\[(=*)\[")
    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):
            m = long_re.match(src, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                j = n if j < 0 else j + len(close)
                nl = src.count("\n", i, j)
                code.append("\n" * nl)
                line += nl
                i = j
                continue
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if c in "\"'":
            j, buf = i + 1, []
            while j < n and src[j] != c and src[j] != "\n":
                if src[j] == "\\" and j + 1 < n:
                    buf.append(src[j + 1])
                    j += 2
                    continue
                buf.append(src[j])
                j += 1
            lits.append((line, "".join(buf)))
            code.append('""')
            i = j + 1
            continue
        if c == "[":
            m = long_re.match(src, i)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                j = n if j < 0 else j + len(close)
                lits.append((line, src[m.end():j - len(close)]))
                nl = src.count("\n", i, j)
                code.append('""' + "\n" * nl)
                line += nl
                i = j
                continue
        if c == "\n":
            line += 1
        code.append(c)
        i += 1
    return lits, "".join(code)


PATH_RE = re.compile(r"/(?:Script|Game)/[\w./:\-]*")
CLASS_CALL_RE = re.compile(r"\b(?:FindAllOf|FindFirstOf)\s*\(\s*(?:\"([^\"]+)\"|'([^']+)')")
DOT_RE = re.compile(r"(?<!\.)\.\s*([A-Z]\w*)")
COLON_RE = re.compile(r"(?<!:):\s*([A-Z]\w*)\s*\(")
DEF_RES = [re.compile(r"function\s+[\w.]*[.:]([A-Za-z_]\w*)\s*\("), re.compile(r"local\s+function\s+([A-Za-z_]\w*)"),
           re.compile(r"\b([A-Za-z_]\w*)\s*=\s*function\b")]
CAP_LIT_RE = re.compile(r"^[A-Z][A-Za-z0-9_]{5,}$")
ALLCAPS_RE = re.compile(r"^[A-Z0-9_]+$")


def tier_for(rel: str) -> str:
    p = Path(rel)
    parts = p.parts
    stem = p.stem
    if parts and parts[0] in ("experiments", "tests"):
        return "debug"
    if DEBUG_RE.search(stem):
        return "debug"
    if stem in TOOLING_STEMS:
        return "tooling"
    return "core"


def classify_path(raw: str) -> dict | None:
    p = raw.rstrip(".:/")
    if raw.endswith(":") or p.count("/") < 2:
        return None  # a stub such as "/Script/AssetRegistry.AssetRegistry:" or a bare mount root
    if p.startswith("/Script/"):
        m = re.match(r"^/Script/(\w+)(?:\.(\w+))?(?::(\w+))?$", p)
        if not m:
            return None
        mod, cls, member = m.groups()
        if not cls:
            return {"path": p, "kind": "script_module", "module": mod}
        if cls.startswith("Default__"):
            cls = cls[len("Default__"):]
        if member:
            return {"path": f"/Script/{mod}.{cls}:{member}", "kind": "script_member", "module": mod,
                    "class": cls, "member": member}
        return {"path": f"/Script/{mod}.{cls}", "kind": "script_class", "module": mod, "class": cls}
    # /Game/... assets
    if ":" in p:
        owner, rest = p.split(":", 1)
        if re.fullmatch(r"\w+", rest):
            return {"path": p, "kind": "asset_member", "owner": owner, "member": rest}
        p = owner  # sub-object path (PersistentLevel.X): depend on the asset
    if "." not in p.rsplit("/", 1)[-1]:
        return None  # a folder or a package path with no object name
    return {"path": p, "kind": "asset"}


def iter_lua_files(mod_dir: Path):
    for p in sorted(mod_dir.rglob("*.lua")):
        rel = p.relative_to(mod_dir).as_posix()
        if rel.startswith("tests/") or "/vendor/" in "/" + rel or p.name == "dkjson.lua":
            continue
        yield p, rel


def parse_bridge_tools(md_path: Path) -> dict:
    if not md_path.exists():
        return {"protocol": [], "extra": []}
    text = md_path.read_text(encoding="utf-8", errors="replace")
    protocol: list[str] = []
    m = re.search(r"`tool`:\s*one of\s*((?:`[^`]*`[\s,]*(?:and\s*)?)+)", text, re.S)
    if m:
        for blob in re.findall(r"`([^`]*)`", m.group(1)):
            protocol += [t.strip() for t in blob.split(",") if t.strip()]
    extra = []
    for name in ("ping", "capabilities", "debug_run", "probe"):
        if re.search(rf"`{name}`", text) and name not in protocol:
            extra.append(name)
    return {"protocol": protocol, "extra": extra}


def _add_use(rec: dict, rel: str, line: int, cap: int = 6) -> None:
    uses = rec.setdefault("uses", [])
    if len(uses) < cap and not any(u["file"] == rel and u["line"] == line for u in uses):
        uses.append({"file": rel, "line": line})


def _merge_tier(rec: dict, tier: str) -> None:
    order = {"core": 0, "tooling": 1, "debug": 2}
    if "tier" not in rec or order[tier] < order[rec["tier"]]:
        rec["tier"] = tier


def extract_deps(ctx: Ctx, baseline: Index | None) -> dict:
    paths: dict[str, dict] = {}
    classnames: dict[str, dict] = {}
    members: dict[str, dict] = {}
    defined: set[str] = set()
    scanned: list[str] = []
    pending_members: list[tuple[str, str, int, str, str]] = []  # name, rel, line, via, tier

    def add_path(raw: str, rel: str, line: int, tier: str):
        info = classify_path(raw)
        if not info:
            return
        rec = paths.setdefault(info["path"], dict(info))
        _add_use(rec, rel, line)
        _merge_tier(rec, tier)

    for p, rel in iter_lua_files(ctx.mod_dir):
        scanned.append(rel)
        src = p.read_text(encoding="utf-8", errors="replace")
        tier = tier_for(rel)
        lits, code = lex_lua(src)
        for line, text in lits:
            for m in PATH_RE.finditer(text):
                add_path(m.group(0), rel, line, tier)
            if CAP_LIT_RE.match(text):
                pending_members.append((text, rel, line, "literal", tier))
        for m in CLASS_CALL_RE.finditer(src):
            name = m.group(1) or m.group(2)
            if not name.startswith("/"):
                rec = classnames.setdefault(name, {"name": name})
                _add_use(rec, rel, src.count("\n", 0, m.start()) + 1)
                _merge_tier(rec, tier)
        for rx in DEF_RES:
            defined.update(rx.findall(code))
        for via, rx in (("dot", DOT_RE), ("colon", COLON_RE)):
            for m in rx.finditer(code):
                pending_members.append((m.group(1), rel, code.count("\n", 0, m.start()) + 1, via, tier))

    # Python-side dependencies on the dump: enums named in the catalog tools, hard-coded asset paths.
    enum_refs: dict[str, dict] = {}
    enum_values: dict[str, dict] = {}
    for src_path in ctx.py_sources:
        if not src_path.exists():
            continue
        rel = src_path.relative_to(REPO_ROOT).as_posix() if src_path.is_relative_to(REPO_ROOT) else src_path.name
        scanned.append(rel)
        text = src_path.read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(r"\bE[A-Z][A-Za-z0-9]{3,}\b", text):
            name = m.group(0)
            if baseline is None or name in baseline.enums:
                rec = enum_refs.setdefault(name, {"name": name, "tier": "tooling"})
                _add_use(rec, rel, text.count("\n", 0, m.start()) + 1)
        for m in re.finditer(r"\"(/Game/[\w./\-]+)\"", text):
            add_path(m.group(1), rel, text.count("\n", 0, m.start()) + 1, "tooling")
    if ctx.use_py_enum_maps:
        try:
            sys.path.insert(0, str(REPO_ROOT))
            from tools import build_catalog as bc  # noqa: WPS433 (local import: optional)
            if "ELoadoutSlotStrategy" in (baseline.enums if baseline else {"ELoadoutSlotStrategy": 1}):
                enum_values["ELoadoutSlotStrategy"] = {"values": sorted(bc.SLOT), "source": "tools/build_catalog.py SLOT",
                                                       "tier": "tooling"}
            for cat, ap in bc.CATEGORY_ACTION_FALLBACK.items():
                add_path(ap, "tools/build_catalog.py", 0, "tooling")
        except Exception as exc:  # noqa: BLE001
            print(f"warning: could not import tools.build_catalog for enum maps: {exc}", file=sys.stderr)

    # Resolve identifier candidates against the baseline dump.
    for name, rel, line, via, tier in pending_members:
        if ALLCAPS_RE.match(name) or len(name) < 4 or (via != "literal" and name in defined):
            continue
        if baseline is not None and name not in baseline.owners:
            continue
        rec = members.setdefault(name, {"name": name, "via": set()})
        rec["via"].add(via)
        _add_use(rec, rel, line)
        _merge_tier(rec, tier)
    for rec in members.values():
        rec["via"] = sorted(rec["via"])
        if baseline is not None:
            ow = baseline.owners.get(rec["name"], [])
            rec["owner_count"] = len(ow)
            rec["baseline_owners"] = [o for o, _ in ow[:10]]
            rec["kinds"] = sorted({k for _, k in ow})
    if baseline is not None:  # class-name refs that do not resolve in the baseline are not ours (or never valid)
        for name in list(classnames):
            classnames[name]["resolves_in_baseline"] = baseline.resolve_class(None, name) is not None

    deps = {
        "schema": DEPS_SCHEMA,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "baseline_build": baseline.build if baseline else None,
        "files_scanned": scanned,
        "paths": sorted(paths.values(), key=lambda r: r["path"]),
        "class_names": sorted(classnames.values(), key=lambda r: r["name"]),
        "members": sorted(members.values(), key=lambda r: r["name"]),
        "enums": sorted(enum_refs.values(), key=lambda r: r["name"]),
        "enum_values": enum_values,
        "bridge_tools": parse_bridge_tools(ctx.protocol_md),
    }
    deps["counts"] = deps_counts(deps)
    return deps


def deps_counts(deps: dict) -> dict:
    kinds = Counter(p["kind"] for p in deps["paths"])
    c = {"paths": len(deps["paths"]), **{f"paths_{k}": v for k, v in sorted(kinds.items())},
         "class_names": len(deps["class_names"]), "members": len(deps["members"]), "enums": len(deps["enums"]),
         "enum_values": sum(len(v["values"]) for v in deps["enum_values"].values()),
         "bridge_tools": len(deps["bridge_tools"]["protocol"]) + len(deps["bridge_tools"]["extra"])}
    c["total"] = c["paths"] + c["class_names"] + c["members"] + c["enums"] + c["bridge_tools"]
    return c


# ------------------------------------------------------------------------------ dependency checks

def catalog_paths(ctx: Ctx, build: str) -> set[str] | None:
    """Every '/...' string in data/items|spells|enemies|recipes_<build>.json (what the catalog loaded), or None."""
    found = None
    for prefix in ("items", "spells", "enemies", "recipes"):
        p = ctx.data_dir / f"{prefix}_{build}.json"
        if not p.exists():
            continue
        found = found or set()
        doc = json.loads(p.read_text(encoding="utf-8"))

        def walk(v):
            if isinstance(v, str):
                if v.startswith("/") and "." in v:
                    found.add(v.split(":")[0])
            elif isinstance(v, dict):
                for k, x in v.items():
                    walk(k)
                    walk(x)
            elif isinstance(v, list):
                for x in v:
                    walk(x)
        walk(doc)
    return found


def _item(dep: dict, kind: str, what: str, reason: str, **extra) -> dict:
    return {"dep": what, "kind": kind, "reason": reason, "tier": dep.get("tier"),
            "uses": [f"{u['file']}:{u['line']}" for u in dep.get("uses", [])[:4]], **extra}


def _type_changed(kind_old, sig_old, kind_new, sig_new) -> str | None:
    if kind_old != kind_new:
        return f"changed from {kind_old} to {kind_new}"
    if kind_old == "prop":
        return None if sig_old == sig_new else f"type {sig_old} -> {sig_new}"
    c = func_change(sig_old, sig_new)
    if c == "signature":
        return f"signature ({sig_old}) -> ({sig_new})"
    if c == "renamed":
        return "RENAMED:" + f"({sig_old}) -> ({sig_new})"
    return None


def check_deps(deps: dict, old: Index, new: Index, new_cat: set[str] | None) -> dict:
    """Evaluate every dependency against the old and new dumps.

    broken: removed or changed in a way that fails core/tooling code. review: same but only for
    debug code, or non-fatal (renamed params, new enum values, assets that may just be unloaded).
    unresolved: not in the OLD dump either (never valid, or unloaded in the baseline): not caused by the patch.
    """
    broken: list[dict] = []
    review: list[dict] = []
    unresolved: list[dict] = []
    ok = 0

    def flag(dep, kind, what, reason, **extra):
        item = _item(dep, kind, what, reason, **extra)
        (broken if dep.get("tier") in ("core", "tooling") else review).append(item)
        if dep.get("tier") == "debug":
            item["reason"] = "[debug code only] " + item["reason"]

    def soft(dep, kind, what, reason, **extra):
        review.append(_item(dep, kind, what, reason, **extra))

    for dep in deps["paths"]:
        kind, path = dep["kind"], dep["path"]
        if kind == "script_module":
            if dep["module"] in old.modules and dep["module"] not in new.modules:
                flag(dep, kind, path, "module no longer present in the dump")
            elif dep["module"] not in old.modules:
                unresolved.append(_item(dep, kind, path, "module not in baseline dump"))
            else:
                ok += 1
        elif kind in ("script_class", "script_member"):
            ko, kn = old.resolve_class(dep["module"], dep["class"]), new.resolve_class(dep["module"], dep["class"])
            if ko is None and kn is None:
                unresolved.append(_item(dep, kind, path, "class not in baseline dump"))
                continue
            if ko is not None and kn is None:
                flag(dep, kind, path, "class/struct/enum removed or moved to another module")
                continue
            if kind == "script_class":
                po = old.classes.get(ko, {}).get("parent")
                pn = new.classes.get(kn, {}).get("parent")
                if ko and not ko.startswith("enum:") and po != pn and ko in old.classes:
                    soft(dep, kind, path, f"parent class changed {po} -> {pn}")
                else:
                    ok += 1
                continue
            mo = old.find_member(ko, dep["member"]) if not ko.startswith("enum:") and ko in old.classes else None
            mn = new.find_member(kn, dep["member"]) if kn in new.classes else None
            if mo is None:
                if mn is None:
                    unresolved.append(_item(dep, kind, path, "member not in baseline dump"))
                else:
                    ok += 1
                continue
            if mn is None:
                flag(dep, kind, path, "member removed")
                continue
            why = _type_changed(mo[0], mo[1], mn[0], mn[1])
            if why is None:
                ok += 1
            elif why.startswith("RENAMED:"):
                soft(dep, kind, path, "parameter names changed " + why[8:])
            else:
                flag(dep, kind, path, why)
        elif kind in ("asset", "asset_member"):
            owner = dep["path"] if kind == "asset" else dep["owner"]
            in_old = owner in old.assets
            in_new = owner in new.assets
            in_cat = bool(new_cat and owner in new_cat)
            if kind == "asset":
                if not in_old:
                    unresolved.append(_item(dep, kind, path, "asset not in baseline object dump (unloaded at dump time?)"))
                elif in_new or in_cat:
                    ok += 1
                elif new_cat is None:
                    soft(dep, kind, path, "not in the new object dump and there is no new catalog to cross-check "
                                          "(object dumps list loaded objects only): verify with StaticFindObject/LoadAsset")
                else:
                    flag(dep, kind, path, "asset missing from the new object dump AND the new catalog")
                continue
            mo = old.bp_members.get(owner, {}).get(dep["member"])
            if mo is None:
                unresolved.append(_item(dep, kind, path, "Blueprint member not in baseline dump"))
                continue
            if not in_new:
                if in_cat:
                    ok += 1
                else:
                    soft(dep, kind, path, "owning Blueprint class not in the new object dump (removed or just unloaded)")
                continue
            mn = new.bp_members.get(owner, {}).get(dep["member"])
            if mn is None:
                flag(dep, kind, path, "Blueprint member removed")
            elif mn != mo:
                flag(dep, kind, path, f"Blueprint member changed {mo} -> {mn}")
            else:
                ok += 1

    for dep in deps["class_names"]:
        if not dep.get("resolves_in_baseline", True):
            unresolved.append(_item(dep, "class_name", dep["name"], "not a class in the baseline dump"))
            continue
        if new.resolve_class(None, dep["name"]) is None:
            flag(dep, "class_name", dep["name"], "class removed or renamed (used with FindAllOf/FindFirstOf)")
        else:
            ok += 1

    for dep in deps["enums"]:
        if dep["name"] in old.enums and dep["name"] not in new.enums:
            flag(dep, "enum", dep["name"], "enum removed or renamed")
        elif dep["name"] in old.enums:
            ov, nv = old.enums[dep["name"]]["values"], new.enums[dep["name"]]["values"]
            gone = sorted(set(ov) - set(nv))
            moved = sorted(k for k in ov if k in nv and ov[k] != nv[k])
            if gone or moved:
                flag(dep, "enum", dep["name"], f"values removed {gone} / renumbered {moved}")
            else:
                ok += 1
        else:
            unresolved.append(_item(dep, "enum", dep["name"], "enum not in baseline dump"))

    for ename, spec in deps["enum_values"].items():
        d = {"tier": spec.get("tier", "tooling"), "uses": [{"file": spec.get("source", "?"), "line": 0}]}
        if ename not in new.enums:
            if ename in old.enums:
                flag(d, "enum_values", ename, "enum removed or renamed")
            continue
        nv = set(new.enums[ename]["values"])
        ov = set(old.enums.get(ename, {}).get("values", {}))
        missing = sorted(set(spec["values"]) - nv)
        unmapped = sorted(nv - set(spec["values"]) - {"MAX"} - {v for v in nv if v.endswith("_MAX") or v.endswith("MAX")})
        if missing:
            flag(d, "enum_values", ename, f"mapped values no longer in the enum: {missing}")
        if unmapped and (nv - ov):
            soft(d, "enum_values", ename, f"new enum values with no mapping in {spec.get('source')}: {sorted(nv - ov)}")
        if not missing:
            ok += 1

    # Bare member names (identifiers used as .Name / :Name() / "Name"). Attribution is heuristic, so
    # only name-gone-everywhere and all-owners-lost are failures; partial loss is a review item.
    noisy = 0
    for dep in deps["members"]:
        name = dep["name"]
        owners = old.owners.get(name, [])
        if not owners:
            continue
        new_owners = new.owners.get(name, [])
        if not new_owners:
            flag(dep, "member", name, f"member gone from every class (was on {len(owners)}: {dep.get('baseline_owners', [])[:4]})")
            continue
        lost, changed = [], []
        for o, _ in owners:
            if not old.owner_exists(o):
                continue
            if not new.owner_exists(o):
                lost.append(o)
                continue
            so, sn = old.member_sig(o, name), new.member_sig(o, name)
            if sn is None:
                lost.append(o)
            elif so is not None:
                why = _type_changed(so[0], so[1], sn[0], sn[1])
                if why and not why.startswith("RENAMED:"):
                    changed.append((o, why))
        if not lost and not changed:
            ok += 1
        elif len(owners) <= 8:
            hit = len(lost) + len(changed)
            what = f"{name} on {len(owners)} owner(s): lost {lost[:3]}, changed {changed[:3]}"
            if hit >= len(owners):
                flag(dep, "member", name, "every known owner lost or changed it: " + what)
            else:
                soft(dep, "member", name, "some owners lost or changed it: " + what)
        else:
            noisy += 1
    return {"broken": broken, "review": review, "unresolved": unresolved, "ok": ok, "ambiguous_ignored": noisy}


def dep_classes(deps: dict, old: Index) -> set[str]:
    """Class keys the deps point at (explicit paths, FindAllOf names, and distinctive member owners)."""
    keys = set()
    for p in deps["paths"]:
        if p["kind"] in ("script_class", "script_member"):
            k = old.resolve_class(p["module"], p["class"])
            if k and k in old.classes:
                keys.add(k)
    for c in deps["class_names"]:
        k = old.resolve_class(None, c["name"])
        if k and k in old.classes:
            keys.add(k)
    for m in deps["members"]:
        ow = old.owners.get(m["name"], [])
        if 0 < len(ow) <= 4:
            keys.update(o for o, _ in ow if o in old.classes)
    return keys


# ------------------------------------------------------------------------------ catalog diff

IGNORE_ITEM_KEYS = {"source", "held_actor_class_inferred"}


def _flat(v, prefix="", out=None):
    out = {} if out is None else out
    if isinstance(v, dict):
        for k, x in v.items():
            _flat(x, f"{prefix}.{k}" if prefix else str(k), out)
    else:
        out[prefix] = v
    return out


def flat_diff(old: dict, new: dict, ignore=()) -> dict:
    fo, fn = _flat(old), _flat(new)
    res = {}
    for k in sorted(set(fo) | set(fn)):
        if k.split(".")[0] in ignore:
            continue
        if fo.get(k, "<absent>") != fn.get(k, "<absent>"):
            res[k] = [fo.get(k, "<absent>"), fn.get(k, "<absent>")]
    return res


def _collection(doc: dict, *prefer: str) -> dict:
    for k in prefer:
        v = doc.get(k)
        if isinstance(v, dict):
            return v
        if isinstance(v, list):
            return {str(x.get("id") or x.get("name") or x.get("path") or i): x for i, x in enumerate(v) if isinstance(x, dict)}
    best = {}
    for v in doc.values():
        if isinstance(v, dict) and len(v) > len(best) and all(isinstance(x, dict) for x in v.values()):
            best = v
    return best


def _load(ctx: Ctx, prefix: str, build: str) -> dict | None:
    p = ctx.data_dir / f"{prefix}_{build}.json"
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def _chain_of(doc: dict, action: str | None):
    s = (doc.get("attack_sets") or {}).get(action or "")
    return None if s is None else s.get("chain")


def catalog_diff(ctx: Ctx, old_b: str, new_b: str) -> dict:
    res: dict = {"old": old_b, "new": new_b, "available": {}, "items": None, "spells": None, "enemies": None,
                 "needs_review": [], "auto_supported": []}
    o_items, n_items = _load(ctx, "items", old_b), _load(ctx, "items", new_b)
    res["available"]["items"] = [o_items is not None, n_items is not None]
    if o_items is not None and n_items is not None:
        oi, ni = _collection(o_items, "items"), _collection(n_items, "items")
        added = sorted(set(ni) - set(oi))
        removed = sorted(set(oi) - set(ni))
        changed = {}
        for k in sorted(set(oi) & set(ni)):
            d = flat_diff(oi[k], ni[k], IGNORE_ITEM_KEYS)
            if d:
                changed[k] = d
        old_cats = {i.get("category") for i in oi.values()}
        new_cat_items = defaultdict(list)
        new_chain, no_attack, auto = [], [], []
        for k in added:
            it = ni[k]
            if it.get("role") == "weapon" and it.get("category") not in old_cats:
                new_cat_items[it.get("category")].append(k)
        # weapons with new/changed attack chains (among added or changed items)
        for k in list(added) + list(changed):
            it = ni[k]
            if it.get("kind") != "held":
                continue
            for slot, aset in (it.get("attacks") or {}).items():
                act = (aset or {}).get("action")
                cn = _chain_of(n_items, act)
                co = _chain_of(o_items, act)
                if act and co is None and cn is not None:
                    new_chain.append({"item": k, "slot": slot, "action": act, "chain": cn, "why": "new attack set"})
                elif cn is not None and co is not None and cn != co:
                    new_chain.append({"item": k, "slot": slot, "action": act, "chain": cn, "old_chain": co,
                                      "why": "attack chain changed"})
            if k in added:
                if it.get("role") == "weapon" and it.get("attack_source") != "item":
                    no_attack.append({"item": k, "attack_source": it.get("attack_source"), "category": it.get("category")})
                elif it.get("category") in old_cats or it.get("role") != "weapon":
                    auto.append(k)
        for k in added:
            if ni[k].get("kind") == "wearable":
                auto.append(k)
        sets_o, sets_n = o_items.get("attack_sets") or {}, n_items.get("attack_sets") or {}
        res["items"] = {
            "added": [{"id": k, "category": ni[k].get("category"), "role": ni[k].get("role"),
                       "range_type": ni[k].get("range_type"), "attack_source": ni[k].get("attack_source"),
                       "tier": ni[k].get("tier")} for k in added],
            "removed": removed, "changed": changed,
            "new_weapon_categories": dict(new_cat_items), "new_or_changed_attack_chains": new_chain,
            "weapons_without_own_attack_data": no_attack,
            "attack_sets_added": sorted(set(sets_n) - set(sets_o)), "attack_sets_removed": sorted(set(sets_o) - set(sets_n)),
            "attack_sets_changed": sorted(k for k in set(sets_o) & set(sets_n)
                                          if sets_o[k].get("chain") != sets_n[k].get("chain")
                                          or sets_o[k].get("damage") != sets_n[k].get("damage")),
            "attacks_changed": sorted(k for k in set(o_items.get("attacks") or {}) & set(n_items.get("attacks") or {})
                                      if o_items["attacks"][k] != n_items["attacks"][k]),
            "catalog_errors": (n_items.get("source") or {}).get("errors") or [],
            "missing_from_catalog": (n_items.get("source") or {}).get("missing_from_catalog") or [],
            "counts": {"old": len(oi), "new": len(ni)},
        }
        for cat, ids in new_cat_items.items():
            res["needs_review"].append(f"new weapon category '{cat}' ({', '.join(ids[:4])}): needs a combat profile "
                                       f"(range/approach/swing) in the body and a role check")
        for c in new_chain:
            res["needs_review"].append(f"{c['item']} ({c['slot']}): {c['why']} {c['action'].rsplit('/', 1)[-1]} -> "
                                       f"{len(c['chain'])} swing(s): confirm the combat profile handles it")
        for w in no_attack:
            res["needs_review"].append(f"new weapon {w['item']} has no attack data of its own "
                                       f"(attack_source={w['attack_source']}, category {w['category']}): verify the guess")
        if res["items"]["missing_from_catalog"] or res["items"]["catalog_errors"]:
            res["needs_review"].append(f"new items catalog has {len(res['items']['missing_from_catalog'])} missing and "
                                       f"{len(res['items']['catalog_errors'])} error entries: rerun tools.build_catalog")
        if auto:
            res["auto_supported"].append(f"{len(auto)} new item(s) described by the catalog with known category/attack data "
                                         f"({', '.join(auto[:6])}{', ...' if len(auto) > 6 else ''})")
        if changed:
            res["needs_review"].append(f"{len(changed)} existing item(s) changed (stats/slots/attacks): "
                                       f"{', '.join(list(changed)[:6])}{', ...' if len(changed) > 6 else ''}")
    for prefix, coll_keys, label in (("spells", ("spells",), "spell"), ("enemies", ("enemies", "creatures", "npcs"), "enemy"),
                                     ("recipes", ("recipes",), "recipe")):
        o, n = _load(ctx, prefix, old_b), _load(ctx, prefix, new_b)
        res["available"][prefix] = [o is not None, n is not None]
        if o is None or n is None:
            continue
        oc, nc = _collection(o, *coll_keys), _collection(n, *coll_keys)
        added, removed = sorted(set(nc) - set(oc)), sorted(set(oc) - set(nc))
        changed = {}
        for k in sorted(set(oc) & set(nc)):
            d = flat_diff(oc[k], nc[k], {"usage"} if label == "spell" else ())
            if d:
                changed[k] = d
        res[prefix] = {"added": added, "removed": removed, "changed": changed, "counts": {"old": len(oc), "new": len(nc)}}
        if label == "spell":
            res[prefix]["needs_role_tags"] = [
                {"spell": k, "name": nc[k].get("name") or (nc[k].get("usage") or {}).get("name"),
                 "role": (nc[k].get("usage") or {}).get("role", nc[k].get("role"))} for k in added]
            if added:
                res["needs_review"].append(f"{len(added)} new spell(s) need role tags / use_when / preconditions "
                                           f"(LLM-drafted, human-reviewed): {', '.join(added[:8])}")
            if changed:
                res["needs_review"].append(f"{len(changed)} existing spell(s) changed (cost/cooldown/modules): "
                                           f"{', '.join(list(changed)[:6])}")
        else:
            if added:
                res["auto_supported"].append(f"{len(added)} new {label}(s) in the catalog: {', '.join(added[:6])}")
            if changed:
                res["needs_review"].append(f"{len(changed)} {label}(s) changed: {', '.join(list(changed)[:6])}")
            if label == "recipe" and (added or changed or removed):
                res["needs_review"].append("recipes changed: regenerate mod/body/recipe_data.lua (tools.build_recipes) "
                                           "and re-run the crafting drift check (tools.craft_drift run, one real craft)")
        if removed:
            res["needs_review"].append(f"{len(removed)} {label}(s) removed: {', '.join(removed[:6])}")
    if res["items"] and res["items"]["removed"]:
        res["needs_review"].append(f"{len(res['items']['removed'])} item(s) removed from the catalog: "
                                   f"{', '.join(res['items']['removed'][:6])}")
    return res


# ------------------------------------------------------------------------------ report

def _cap(items, n=REPORT_LIST_CAP):
    items = list(items)
    return items[:n], max(0, len(items) - n)


def full_delta(ctx: Ctx, old_b: str, new_b: str, with_catalog: bool = True) -> dict:
    old, new = ensure_index(ctx, old_b), ensure_index(ctx, new_b)
    d = diff_dumps(old, new)
    deps = extract_deps(ctx, old)
    cat = catalog_paths(ctx, new_b) if with_catalog else None
    chk = check_deps(deps, old, new, cat)
    dep_cls = dep_classes(deps, old)
    touched = {}
    for k in sorted(dep_cls & set(d["classes"]["changed"])):
        ch = d["classes"]["changed"][k]
        if set(ch) - {"offset_info"}:
            touched[k] = {x: (len(v) if isinstance(v, dict) else v) for x, v in ch.items() if x != "offset_info"}
    catalog_schema = {}
    for k in CATALOG_CLASSES:
        ch = d["classes"]["changed"].get(k)
        if ch and set(ch) - {"offset_info"}:
            catalog_schema[k] = {x: v for x, v in ch.items() if x != "offset_info"}
    return {"old": old_b, "new": new_b, "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "dump": d, "deps": {"counts": deps["counts"], "check": chk, "touched_classes": touched,
                                "baseline_build": old_b},
            "new_family_classes": new_family_classes(old, new, d), "catalog_schema_changes": catalog_schema,
            "catalog": None, "new_catalog_available": cat is not None,
            "object_dump": {"old": old.has_object_dump, "new": new.has_object_dump}}


def _section_lines(title: str) -> list[str]:
    return [f"## {title}", ""]


def render_markdown(delta: dict) -> str:
    o, n = delta["old"], delta["new"]
    d, chk = delta["dump"], delta["deps"]["check"]
    cat = delta.get("catalog")
    s = d["summary"]
    broken = list(chk["broken"])
    review = list(chk["review"])
    auto: list[str] = []
    review_txt: list[str] = []
    if cat:
        review_txt += cat["needs_review"]
        auto += cat["auto_supported"]
        if cat["items"] and cat["items"]["removed"]:
            pass
    if not delta["object_dump"]["old"] or not delta["object_dump"]["new"]:
        review_txt.append("an object dump is missing for one build: asset and Blueprint checks were skipped")
    for fam in delta["new_family_classes"]:
        review_txt.append(f"new class `{fam['class']}` ({fam['family']}: {fam['why']})")
    for k, v in delta["catalog_schema_changes"].items():
        review_txt.append(f"catalog source class `{k}` changed ({', '.join(sorted(v))}): rebuild the catalog and review "
                          f"tools/build_catalog.py and mod/scripts/catalog.lua")
    for k, v in delta["deps"]["touched_classes"].items():
        review_txt.append(f"dependency class `{k}` changed: " + ", ".join(f"{a}={b}" for a, b in v.items()))
    if s["classes_added"] or s["funcs_added"] or s["props_added"]:
        auto.append(f"{s['classes_added']} new classes, {s['funcs_added']} new functions and {s['props_added']} new properties "
                    f"in the dump (additive: nothing in our dependency list uses them)")
    if s["classes_changed_offset_only"]:
        auto.append(f"{s['classes_changed_offset_only']} classes changed only in size/offsets (we never rely on offsets)")
    a_added = d["assets"]["added"]
    interesting = {t: v for t, v in a_added.items() if t not in NOISE_ASSET_TYPES}
    if not d["assets"]["both_have_object_dump"]:
        pass
    elif interesting:
        auto.append(f"{sum(len(v) for v in interesting.values())} newly loaded gameplay assets in the object dump "
                    f"(loaded-object list: not a full asset list)")
    verdict = "NO CHANGES" if (s["total_changes"] == 0 and not broken and not review and not review_txt) else \
        f"{len(broken)} BROKEN, {len(review) + len(review_txt)} to review"
    L = [f"# Patch delta: build {o} -> {n}", "",
         f"Generated {delta['generated_at']} by `tools/patch_pipeline.py report {o} {n}`. Verdict: **{verdict}**.", ""]
    L += ["| Dump diff | count |", "|---|---|"]
    for k in ("classes_added", "classes_removed", "classes_changed", "classes_changed_offset_only", "props_added",
              "props_removed", "props_type_changed", "funcs_added", "funcs_removed", "funcs_changed", "enums_added",
              "enums_removed", "enums_changed", "assets_added", "assets_removed", "bp_classes_changed"):
        L.append(f"| {k.replace('_', ' ')} | {s[k]} |")
    dc = delta["deps"]["counts"]
    L += ["", f"Dependencies checked: {dc['total']} ({dc['paths']} paths, {dc['members']} member names, "
              f"{dc['class_names']} class names, {dc['enums']} enums, {dc['bridge_tools']} bridge tools); "
              f"{chk['ok']} still valid, {len(chk['unresolved'])} unresolved in the baseline (not caused by this patch), "
              f"{chk['ambiguous_ignored']} ambiguous names ignored.", ""]
    if delta["object_dump"]["old"] and delta["object_dump"]["new"]:
        L += ["Note: `UE4SS_ObjectDump.txt` lists objects loaded at dump time, so asset adds/removals are a "
              "loaded-set diff. Asset breakage is cross-checked against the new catalog"
              + ("." if delta["new_catalog_available"] else " (not available yet: those items are in review).") , ""]

    L += _section_lines("BROKEN (fix before play)")
    if not broken:
        L += ["None.", ""]
    else:
        L += ["| Dependency | Kind | Problem | Used in |", "|---|---|---|---|"]
        for b in broken:
            L.append(f"| `{b['dep']}` | {b['kind']} | {b['reason']} | {', '.join(b['uses'])} |")
        L.append("")
    L += _section_lines("Needs review")
    if not review and not review_txt:
        L += ["None.", ""]
    else:
        for r in review_txt:
            L.append(f"- {r}")
        shown, more = _cap(review, 60)
        for r in shown:
            L.append(f"- `{r['dep']}` ({r['kind']}, {r.get('tier')}): {r['reason']} ({', '.join(r['uses'][:2])})")
        if more:
            L.append(f"- ... and {more} more (see the JSON)")
        L.append("")
    L += _section_lines("Auto-supported")
    if not auto:
        L += ["Nothing new detected.", ""]
    else:
        L += [f"- {a}" for a in auto] + [""]
    if cat is None:
        L += [f"> Catalog diff not included (this is the dump-only `diff`): run `report {o} {n}` for the combined report.", ""]
    elif not all(cat["available"].get("items", [False, False])):
        L += ["> The items catalog is missing for one or both builds: run `tools.build_catalog` on the new build, "
              "then rerun `report`.", ""]

    L += _section_lines("Checklist for the agent")
    L += [f"- [ ] Fix every BROKEN row ({len(broken)}), then rerun `deps` and `report {o} {n}` until BROKEN is empty.",
          "- [ ] For each removed/changed member: find the replacement in `dumps/<new>/CXXHeaderDump`, hook it, record in `docs/DISCOVERIES.md` with the new build id.",
          "- [ ] Work the \"Needs review\" list; for new spells add role tags in `data/spells_<new>.json`; for new weapon categories add a combat profile.",
          f"- [ ] `.venv\\Scripts\\python.exe -m tools.smoke_test` passes (needs the server up; player-only checks need Luis).",
          "- [ ] Update `docs/DISCOVERIES.md`, `docs/PROGRESS.md`, `docs/tasks.json`, and rerun `pytest tests -q`.",
          "- [ ] Commit (dumps/ is gitignored; docs/patches and data/ are committed).", ""]

    L += _section_lines("Appendix: dump diff details (capped; full lists in the JSON)")
    ch = d["classes"]
    for title, lst in (("Classes added", ch["added"]), ("Classes removed", ch["removed"])):
        shown, more = _cap(lst)
        if lst:
            L += [f"### {title} ({len(lst)})", ""] + [f"- `{x}`" for x in shown] + ([f"- ... {more} more"] if more else []) + [""]
    fchg = [(k, f, v) for k, c in ch["changed"].items() for f, v in c.get("funcs_changed", {}).items()]
    if fchg:
        shown, more = _cap(fchg)
        L += [f"### Function signatures changed ({len(fchg)})", ""]
        L += [f"- `{k}::{f}`: `({v['old']})` -> `({v['new']})` [{v['kind']}]" for k, f, v in shown]
        L += ([f"- ... {more} more"] if more else []) + [""]
    frem = [(k, f) for k, c in ch["changed"].items() for f in c.get("funcs_removed", {})]
    if frem:
        shown, more = _cap(frem)
        L += [f"### Functions removed ({len(frem)})", ""] + [f"- `{k}::{f}`" for k, f in shown] + ([f"- ... {more} more"] if more else []) + [""]
    pchg = [(k, p, v) for k, c in ch["changed"].items() for p, v in c.get("props_type_changed", {}).items()]
    if pchg:
        shown, more = _cap(pchg)
        L += [f"### Property types changed ({len(pchg)})", ""] + [f"- `{k}.{p}`: `{v[0]}` -> `{v[1]}`" for k, p, v in shown]
        L += ([f"- ... {more} more"] if more else []) + [""]
    prem = [(k, p) for k, c in ch["changed"].items() for p in c.get("props_removed", {})]
    if prem:
        shown, more = _cap(prem)
        L += [f"### Properties removed ({len(prem)})", ""] + [f"- `{k}.{p}`" for k, p in shown] + ([f"- ... {more} more"] if more else []) + [""]
    for e, v in list(d["enums"]["changed"].items())[:REPORT_LIST_CAP]:
        L.append(f"- enum `{e}`: +{list(v['values_added'])} -{list(v['values_removed'])} changed {list(v['values_changed'])}")
    if d["enums"]["changed"]:
        L.append("")
    if interesting:
        L += ["### Newly loaded assets by type", ""]
        for t, v in list(interesting.items())[:25]:
            shown, more = _cap(v, 8)
            L.append(f"- {t} ({len(v)}): " + ", ".join(f"`{x.rsplit('/', 1)[-1]}`" for x in shown) + (f", ... {more} more" if more else ""))
        L.append("")
    if cat and cat.get("items"):
        it = cat["items"]
        L += ["### Item catalog", "",
              f"- items {it['counts']['old']} -> {it['counts']['new']}: {len(it['added'])} added, {len(it['removed'])} removed, {len(it['changed'])} changed",
              f"- attack sets: {len(it['attack_sets_added'])} added, {len(it['attack_sets_removed'])} removed, {len(it['attack_sets_changed'])} changed", ""]
    if cat and cat.get("spells"):
        sp = cat["spells"]
        L += ["### Spell catalog", "", f"- spells {sp['counts']['old']} -> {sp['counts']['new']}: {len(sp['added'])} added "
              f"(need role tags), {len(sp['removed'])} removed, {len(sp['changed'])} changed", ""]
    if cat and cat.get("recipes"):
        rc = cat["recipes"]
        L += ["### Recipe catalog", "", f"- recipes {rc['counts']['old']} -> {rc['counts']['new']}: {len(rc['added'])} added, "
              f"{len(rc['removed'])} removed, {len(rc['changed'])} changed (any change: regenerate recipe_data.lua and "
              f"re-run `tools.craft_drift run`)", ""]
    return "\n".join(L).rstrip() + "\n"


def write_report(ctx: Ctx, delta: dict, md: bool = True) -> tuple[Path, Path]:
    ctx.out_dir.mkdir(parents=True, exist_ok=True)
    base = ctx.out_dir / f"{delta['old']}_to_{delta['new']}"
    jp, mp = base.with_suffix(".json"), base.with_suffix(".md")
    jp.write_text(json.dumps(delta, indent=1, sort_keys=False, default=list), encoding="utf-8")
    mp.write_text(render_markdown(delta), encoding="utf-8")
    return jp, mp


def delta_counts(delta: dict) -> tuple[int, int]:
    chk = delta["deps"]["check"]
    n_review = len(chk["review"]) + (len(delta["catalog"]["needs_review"]) if delta.get("catalog") else 0)
    return len(chk["broken"]), n_review


# ------------------------------------------------------------------------------ snapshot

def snapshot(ctx: Ctx, build: str | None, src: Path | None, force: bool, dry_run: bool, with_uht: bool = True) -> int:
    live = server_build_id()
    build = build or live
    if not build:
        print("error: no --build given and no SteamCMD appmanifest found", file=sys.stderr)
        return 1
    if live and build != live and not force:
        print(f"error: --build {build} does not match the installed server build {live} (use --force)", file=sys.stderr)
        return 1
    src = src or ue4ss_dir()
    cxx, obj = src / "CXXHeaderDump", src / "UE4SS_ObjectDump.txt"
    problems = []
    if not obj.exists():
        problems.append(f"{obj} missing")
    if not cxx.is_dir() or len(list(cxx.glob("*.hpp"))) < MIN_HPP:
        problems.append(f"{cxx} missing or incomplete (GenerateSDK may still be running)")
    exe = server_root() / "RSDragonwilds" / "Binaries" / "Win64" / "RSDragonwildsServer-Win64-Shipping.exe"
    if obj.exists() and exe.exists() and obj.stat().st_mtime < exe.stat().st_mtime and not force:
        problems.append(f"the dump ({time.ctime(obj.stat().st_mtime)}) is older than the server binary "
                        f"({time.ctime(exe.stat().st_mtime)}): it is from the PREVIOUS build. Deploy with -Dump, restart, wait ~2-4 min")
    if (src / "UE4SS.log").exists() and not problems:
        pass
    if problems:
        for p in problems:
            print("error:", p, file=sys.stderr)
        return 1
    dest = ctx.dump_dir(build)
    if dest.exists() and any(dest.iterdir()) and not force:
        print(f"error: {dest} already holds a snapshot (use --force to overwrite)", file=sys.stderr)
        return 1
    plan = [(obj, dest / "UE4SS_ObjectDump.txt"), (cxx, dest / "CXXHeaderDump")]
    if with_uht and (src / "UHTHeaderDump").is_dir():
        plan.append((src / "UHTHeaderDump", dest / "UHTHeaderDump"))
    types = src / "Mods" / "shared" / "types"
    if types.is_dir():
        plan.append((types, dest / "luatypes"))
    for a, b in plan:
        print(f"{'would copy' if dry_run else 'copy'} {a} -> {b}")
    if dry_run:
        print(f"dry run: build {build}, dump age {(time.time() - obj.stat().st_mtime) / 60:.0f} min")
        return 0
    dest.mkdir(parents=True, exist_ok=True)
    for a, b in plan:
        if b.exists():
            shutil.rmtree(b) if b.is_dir() else b.unlink()
        shutil.copytree(a, b) if a.is_dir() else shutil.copy2(a, b)
    idx = dest / "index.json.gz"
    if idx.exists():
        idx.unlink()
    t0 = time.time()
    index = ensure_index(ctx, build)
    print(f"snapshot {build}: {len(index.classes)} classes, {len(index.enums)} enums, {len(index.assets)} assets "
          f"(index built in {time.time() - t0:.0f}s) -> {dest}")
    return 0


# ------------------------------------------------------------------------------ CLI

def _newest_build(ctx: Ctx) -> str | None:
    cands = [p.name for p in ctx.dumps_dir.glob("*") if p.is_dir() and p.name.isdigit()] if ctx.dumps_dir.exists() else []
    return max(cands, key=int) if cands else None


def cmd_deps(ctx: Ctx, a) -> int:
    build = a.build or _newest_build(ctx)
    baseline = ensure_index(ctx, build) if build and ctx.dump_dir(build).exists() else None
    if baseline is None:
        print("warning: no baseline dump found: member names are unfiltered (run snapshot first)", file=sys.stderr)
    deps = extract_deps(ctx, baseline)
    out = Path(a.out) if a.out else ctx.data_dir / "dependencies.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(deps, indent=1), encoding="utf-8")
    c = deps["counts"]
    print(f"dependencies: {c['total']} total -> {out}")
    print("  " + ", ".join(f"{k}={v}" for k, v in c.items() if k != "total"))
    print(f"  baseline build {deps['baseline_build']}, {len(deps['files_scanned'])} files scanned")
    return 0


def cmd_diff(ctx: Ctx, a) -> int:
    delta = full_delta(ctx, a.old, a.new, with_catalog=True)
    jp, mp = write_report(ctx, delta)
    b, r = delta_counts(delta)
    s = delta["dump"]["summary"]
    print(f"dump diff {a.old} -> {a.new}: {s['total_changes']} change(s) "
          f"(classes +{s['classes_added']} -{s['classes_removed']} ~{s['classes_changed']}, funcs +{s['funcs_added']} "
          f"-{s['funcs_removed']} ~{s['funcs_changed']}, props +{s['props_added']} -{s['props_removed']} "
          f"~{s['props_type_changed']}, assets +{s['assets_added']} -{s['assets_removed']})")
    print(f"BREAKING dependencies: {b}; review items: {r}")
    for item in delta["deps"]["check"]["broken"][:20]:
        print(f"  BROKEN {item['kind']} {item['dep']}: {item['reason']}")
    print(f"wrote {jp} and {mp}")
    return 2 if (a.strict and b) else 0


def cmd_catalog_diff(ctx: Ctx, a) -> int:
    cd = catalog_diff(ctx, a.old, a.new)
    ctx.out_dir.mkdir(parents=True, exist_ok=True)
    out = ctx.out_dir / f"{a.old}_to_{a.new}.catalog.json"
    out.write_text(json.dumps(cd, indent=1), encoding="utf-8")
    print("catalog availability (old, new):", cd["available"])
    if cd["items"]:
        it = cd["items"]
        print(f"items: {it['counts']['old']} -> {it['counts']['new']}: +{len(it['added'])} -{len(it['removed'])} ~{len(it['changed'])}")
    for k in ("spells", "enemies"):
        if cd[k]:
            print(f"{k}: +{len(cd[k]['added'])} -{len(cd[k]['removed'])} ~{len(cd[k]['changed'])}")
    for line in cd["needs_review"]:
        print("  review:", line)
    for line in cd["auto_supported"]:
        print("  auto:", line)
    print("wrote", out)
    return 0


def cmd_report(ctx: Ctx, a) -> int:
    delta = full_delta(ctx, a.old, a.new)
    delta["catalog"] = catalog_diff(ctx, a.old, a.new)
    jp, mp = write_report(ctx, delta)
    b, r = delta_counts(delta)
    print(f"report {a.old} -> {a.new}: BROKEN {b}, needs review {r}")
    for item in delta["deps"]["check"]["broken"][:30]:
        print(f"  BROKEN {item['kind']} {item['dep']}: {item['reason']}")
    print(f"wrote {mp}\nwrote {jp}")
    return 2 if (a.strict and b) else 0


def cmd_snapshot(ctx: Ctx, a) -> int:
    return snapshot(ctx, a.build, Path(a.src) if a.src else None, a.force, a.dry_run, not a.no_uht)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dumps-dir")
    ap.add_argument("--data-dir")
    ap.add_argument("--out-dir")
    ap.add_argument("--mod-dir")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("snapshot", help="copy the current UE4SS dumps into dumps/<build>/ and index them")
    p.add_argument("--build", help="default: the SteamCMD appmanifest build id")
    p.add_argument("--src", help="UE4SS dir holding the dumps (default: the server's ue4ss folder)")
    p.add_argument("--force", action="store_true", help="overwrite an existing snapshot / skip the staleness checks")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-uht", action="store_true", help="skip the 86 MB UHTHeaderDump copy")
    p.set_defaults(fn=cmd_snapshot)
    p = sub.add_parser("deps", help="write data/dependencies.json from mod/**/*.lua and BRIDGE_PROTOCOL.md")
    p.add_argument("--build", help="baseline dump used to resolve names (default: newest in dumps/)")
    p.add_argument("--out")
    p.set_defaults(fn=cmd_deps)
    for name, fn, h in (("diff", cmd_diff, "diff two dumps and flag BREAKING dependencies"),
                        ("catalog-diff", cmd_catalog_diff, "diff data/items|spells|enemies_<build>.json"),
                        ("report", cmd_report, "combined delta report (Auto-supported / Needs review / BROKEN)")):
        p = sub.add_parser(name, help=h)
        p.add_argument("old")
        p.add_argument("new")
        p.add_argument("--strict", action="store_true", help="exit 2 when anything is BROKEN")
        p.set_defaults(fn=fn)
    a = ap.parse_args(argv)
    ctx = Ctx()
    if a.dumps_dir:
        ctx.dumps_dir = Path(a.dumps_dir)
    if a.data_dir:
        ctx.data_dir = Path(a.data_dir)
    if a.out_dir:
        ctx.out_dir = Path(a.out_dir)
    if a.mod_dir:
        ctx.mod_dir = Path(a.mod_dir)
    return a.fn(ctx, a)


if __name__ == "__main__":
    sys.exit(main())

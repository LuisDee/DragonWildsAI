"""Patch pipeline tests on tiny synthetic dumps (no game, no server, no real dump needed)."""
import json
import os
import shutil
from pathlib import Path

import pytest

from tools import patch_pipeline as pp

OLD_HPP = """#ifndef UE4SS_SDK_Game_HPP
#define UE4SS_SDK_Game_HPP

#include "Game_enums.hpp"

struct FThing
{
    int32 A;                                                                          // 0x0000 (size: 0x4)

}; // Size: 0x4

class UItemData : public UObject
{
    FString Name;                                                                     // 0x0030 (size: 0x10)
}; // Size: 0x40

class UHeldEquipmentData : public UItemData
{
    float Damage;                                                                     // 0x0040 (size: 0x4)
}; // Size: 0x50

class UInv : public UObject
{
    int32 Count;                                                                      // 0x0030 (size: 0x4)
    void AddItem(class UItemData* Item, int32 Amount);
    void RemoveItem(class UItemData* Item);
    void Legacy();
    void Stable(float X, const TArray<FThing>& Things);
}; // Size: 0x40

class UGone : public UObject
{
}; // Size: 0x30
"""

NEW_HPP = """#ifndef UE4SS_SDK_Game_HPP
#define UE4SS_SDK_Game_HPP

#include "Game_enums.hpp"

struct FThing
{
    int32 A;                                                                          // 0x0000 (size: 0x4)

}; // Size: 0x4

class UItemData : public UObject
{
    FString Name;                                                                     // 0x0038 (size: 0x10)
}; // Size: 0x48

class UHeldEquipmentData : public UItemData
{
    float Damage;                                                                     // 0x0048 (size: 0x4)
}; // Size: 0x58

class UWhip : public UHeldEquipmentData
{
}; // Size: 0x58

class UInv : public UObject
{
    int64 Count;                                                                      // 0x0030 (size: 0x8)
    void AddItem(class UItemData* Item, float Amount);
    void Brand(int32 NewThing);
    void Stable(float Y, const TArray<FThing>& Things);
}; // Size: 0x48
"""

OLD_ENUMS = """enum class EKind {
    Sword = 0,
    Mace = 1,
    Bow = 2,
};

namespace EMode {
    enum Type {
        Walk = 0,
        Run = 1,
    };
}
"""
NEW_ENUMS = OLD_ENUMS.replace("    Bow = 2,\n", "    Bow = 3,\n    Whip = 4,\n")

OBJ_OLD = """[0000000000000001] Package /Game/A/BP_X
[0000000000000002] BlueprintGeneratedClass /Game/A/BP_X.BP_X_C [n: 1] [c: 0]
[0000000000000003] Function /Game/A/BP_X.BP_X_C:DoIt [n: 2] [c: 0]
[0000000000000004] IntProperty /Game/A/BP_X.BP_X_C:DoIt:Amount [o: 0] [n: 3]
[0000000000000005] BoolProperty /Game/A/BP_X.BP_X_C:bReady [o: 0] [n: 3]
[0000000000000006] DataAsset /Game/Items/ITEM_Sword.ITEM_Sword [n: 4]
[0000000000000007] DataAsset /Game/Items/ITEM_Gone.ITEM_Gone [n: 4]
[0000000000000008] Class /Script/Game.UInv [n: 1]
"""
OBJ_NEW = """[0000000000000001] Package /Game/A/BP_X
[0000000000000002] BlueprintGeneratedClass /Game/A/BP_X.BP_X_C [n: 1] [c: 0]
[0000000000000003] Function /Game/A/BP_X.BP_X_C:DoIt [n: 2] [c: 0]
[0000000000000004] FloatProperty /Game/A/BP_X.BP_X_C:DoIt:Amount [o: 0] [n: 3]
[0000000000000006] DataAsset /Game/Items/ITEM_Sword.ITEM_Sword [n: 4]
[0000000000000009] DataAsset /Game/Items/ITEM_New.ITEM_New [n: 4]
"""

CORE_LUA = '''
-- RegisterHook("/Script/Game.Gone:Commented", f)   <- a comment must not count
local M = {}
RegisterHook("/Script/Game.Inv:AddItem", function() end)
RegisterHook("/Script/Game.Inv:RemoveItem", function() end)
RegisterHook("/Script/Game.Inv:Stable", function() end)
local g = FindAllOf("Gone")
local x = obj:Legacy()
local y = StaticFindObject("/Game/Items/ITEM_Gone.ITEM_Gone")
local z = StaticFindObject("/Game/Items/ITEM_Sword.ITEM_Sword")
local c = inv.Count
local d = bp:DoIt(1)
--[[ block comment
RegisterHook("/Script/Game.Gone:InBlock", f)
]]
return M
'''
DEBUG_LUA = 'local a = StaticFindObject("/Game/Items/ITEM_Gone.ITEM_Gone")\nRegisterHook("/Script/Game.Inv:RemoveItem", f)\n'


def write(p: Path, text: str) -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")
    return p


def make_dump(root: Path, build: str, hpp: str, enums: str, obj: str) -> None:
    d = root / build
    write(d / "CXXHeaderDump" / "Game.hpp", hpp)
    write(d / "CXXHeaderDump" / "Game_enums.hpp", enums)
    write(d / "UE4SS_ObjectDump.txt", obj)


@pytest.fixture
def ctx(tmp_path):
    c = pp.Ctx(dumps_dir=tmp_path / "dumps", data_dir=tmp_path / "data", out_dir=tmp_path / "out",
               mod_dir=tmp_path / "mod", protocol_md=tmp_path / "PROTO.md", py_sources=[], use_py_enum_maps=False)
    make_dump(c.dumps_dir, "100", OLD_HPP, OLD_ENUMS, OBJ_OLD)
    make_dump(c.dumps_dir, "200", NEW_HPP, NEW_ENUMS, OBJ_NEW)
    write(c.mod_dir / "body" / "inv.lua", CORE_LUA)
    write(c.mod_dir / "experiments" / "probe.lua", DEBUG_LUA)
    write(c.mod_dir / "tests" / "ignored.lua", 'RegisterHook("/Script/Game.Zzz:Never", f)')
    write(c.protocol_md, "- `tool`: one of `get_state, follow, stop`, `say`.\n- `ping` takes no args\n")
    return c


# ---------------------------------------------------------------- parsing

def test_parse_classes_enums_and_params(ctx):
    idx = pp.ensure_index(ctx, "100")
    inv = idx.classes["UInv"]
    assert inv["parent"] == "UObject" and inv["props"]["Count"] == ["int32", 0x30]
    assert set(inv["funcs"]) == {"AddItem", "RemoveItem", "Legacy", "Stable"}
    assert idx.enums["EKind"]["values"] == {"Sword": 0, "Mace": 1, "Bow": 2}
    assert idx.enums["EMode"]["values"] == {"Walk": 0, "Run": 1}  # namespace-style enum
    assert idx.assets["/Game/Items/ITEM_Sword.ITEM_Sword"] == "DataAsset"
    assert idx.bp_members["/Game/A/BP_X.BP_X_C"]["DoIt"] == "Function(Amount:IntProperty)"
    assert idx.bp_members["/Game/A/BP_X.BP_X_C"]["bReady"] == "BoolProperty"
    assert (ctx.dumps_dir / "100" / "index.json.gz").exists()
    assert pp.ensure_index(ctx, "100").classes.keys() == idx.classes.keys()  # from the cache


def test_cache_invalidated_when_sources_change(ctx):
    pp.ensure_index(ctx, "100")
    write(ctx.dumps_dir / "100" / "CXXHeaderDump" / "Game.hpp", NEW_HPP)
    assert "UWhip" in pp.ensure_index(ctx, "100").classes


def test_split_params_and_func_change():
    assert pp.split_params("const TArray<FA, FB>& A, int32 B") == [("const TArray<FA, FB>&", "A"), ("int32", "B")]
    assert pp.split_params("") == []
    assert pp.func_change("int32 A", "int32 A") is None
    assert pp.func_change("int32 A", "int32 B") == "renamed"
    assert pp.func_change("int32 A", "float A") == "signature"
    assert pp.func_change("int32 A", "int32 A, int32 B") == "signature"


def test_lex_lua_strips_comments_and_keeps_literals():
    lits, code = pp.lex_lua('a = "x" -- "no"\n--[[ "no2"\n]] b = \'/Game/Y.Y\'\nc = [[/Script/Z.Z]]')
    assert [t for _, t in lits] == ["x", "/Game/Y.Y", "/Script/Z.Z"]
    assert "no" not in code and code.count("\n") == 3


# ---------------------------------------------------------------- diff

def test_identical_dumps_have_no_changes(ctx):
    idx = pp.ensure_index(ctx, "100")
    d = pp.diff_dumps(idx, idx)
    assert d["summary"]["total_changes"] == 0 and not d["classes"]["changed"]


def test_diff_added_removed_changed(ctx):
    old, new = pp.ensure_index(ctx, "100"), pp.ensure_index(ctx, "200")
    d = pp.diff_dumps(old, new)
    c = d["classes"]
    assert c["added"] == ["UWhip"] and c["removed"] == ["UGone"]
    inv = c["changed"]["UInv"]
    assert "RemoveItem" in inv["funcs_removed"] and "Legacy" in inv["funcs_removed"]
    assert "Brand" in inv["funcs_added"]
    assert inv["funcs_changed"]["AddItem"]["kind"] == "signature"  # int32 Amount -> float Amount
    assert inv["funcs_changed"]["Stable"]["kind"] == "renamed"     # X -> Y only
    assert inv["props_type_changed"]["Count"] == ["int32", "int64"]
    # offset-only change: noted, not counted as a functional change
    assert set(c["changed"]["UItemData"]) == {"offset_info"}
    assert d["summary"]["classes_changed_offset_only"] >= 1
    e = d["enums"]["changed"]["EKind"]
    assert "Whip" in e["values_added"] and e["values_changed"] == {"Bow": [2, 3]}
    assert d["assets"]["added"] == {"DataAsset": ["/Game/Items/ITEM_New.ITEM_New"]}
    assert d["assets"]["removed"] == {"DataAsset": ["/Game/Items/ITEM_Gone.ITEM_Gone"]}
    assert d["bp_members"]["changed"]["/Game/A/BP_X.BP_X_C"]["removed"] == {"bReady": "BoolProperty"}
    assert pp.new_family_classes(old, new, d)[0]["class"] == "UWhip"


# ---------------------------------------------------------------- dependencies

def test_deps_extraction(ctx):
    deps = pp.extract_deps(ctx, pp.ensure_index(ctx, "100"))
    paths = {p["path"]: p for p in deps["paths"]}
    assert "/Script/Game.Inv:AddItem" in paths and paths["/Script/Game.Inv:AddItem"]["tier"] == "core"
    assert "/Script/Game.Gone:Commented" not in paths and "/Script/Game.Gone:InBlock" not in paths
    assert "/Script/Game.Zzz:Never" not in paths  # mod/tests is not deployed
    assert paths["/Script/Game.Inv:RemoveItem"]["tier"] == "core"  # core wins over the debug use
    assert paths["/Game/Items/ITEM_Gone.ITEM_Gone"]["tier"] == "core"
    assert [c["name"] for c in deps["class_names"]] == ["Gone"]
    names = {m["name"] for m in deps["members"]}
    assert {"Legacy", "Count", "DoIt"} <= names
    assert deps["bridge_tools"]["protocol"] == ["get_state", "follow", "stop", "say"]
    assert deps["counts"]["total"] == sum(deps["counts"][k] for k in ("paths", "class_names", "members", "enums", "bridge_tools"))


def test_breaking_dependencies_are_flagged(ctx):
    old, new = pp.ensure_index(ctx, "100"), pp.ensure_index(ctx, "200")
    deps = pp.extract_deps(ctx, old)
    chk = pp.check_deps(deps, old, new, new_cat=None)
    broken = {b["dep"]: b["reason"] for b in chk["broken"]}
    assert "signature" in broken["/Script/Game.Inv:AddItem"]
    assert broken["/Script/Game.Inv:RemoveItem"] == "member removed"
    assert "Legacy" in broken and "gone from every class" in broken["Legacy"]
    assert "Gone" in broken  # FindAllOf("Gone")
    assert "/Script/Game.Inv:Stable" not in broken  # parameter rename is non-breaking
    assert any(r["dep"] == "/Script/Game.Inv:Stable" for r in chk["review"])
    assert "Count" in broken  # int32 -> int64
    assert "DoIt" in broken or any("DoIt" in k for k in broken)  # Blueprint function parameter type changed
    # without a new catalog, a vanished asset cannot be proved removed: review, not BROKEN
    assert "/Game/Items/ITEM_Gone.ITEM_Gone" not in broken
    assert any(r["dep"] == "/Game/Items/ITEM_Gone.ITEM_Gone" for r in chk["review"])
    # with a new catalog that does not list it, it is BROKEN; if the catalog lists it, it is fine
    chk2 = pp.check_deps(deps, old, new, new_cat={"/Game/Items/ITEM_Sword.ITEM_Sword"})
    assert any(b["dep"] == "/Game/Items/ITEM_Gone.ITEM_Gone" for b in chk2["broken"])
    chk3 = pp.check_deps(deps, old, new, new_cat={"/Game/Items/ITEM_Gone.ITEM_Gone"})
    assert not any(b["dep"] == "/Game/Items/ITEM_Gone.ITEM_Gone" for b in chk3["broken"] + chk3["review"])


def test_no_false_breaks_when_nothing_changed(ctx):
    old = pp.ensure_index(ctx, "100")
    chk = pp.check_deps(pp.extract_deps(ctx, old), old, old, new_cat=None)
    assert chk["broken"] == [] and chk["review"] == []


# ---------------------------------------------------------------- catalogs

def _items(build):
    sword = {"id": "ITEM_Sword", "kind": "held", "category": "sword", "role": "weapon", "attack_source": "item",
             "range_type": "melee", "stats": {"damage_multiplier": 1.0}, "source": "loaded",
             "attacks": {"primary": {"action": "/G/PA_Sword.PA_Sword_C"}}}
    return {"build": build, "items": {"ITEM_Sword": sword},
            "attack_sets": {"/G/PA_Sword.PA_Sword_C": {"chain": ["a", "b"], "damage": [1, 2]}},
            "attacks": {}, "source": {"errors": [], "missing_from_catalog": []}}


def test_catalog_diff(ctx):
    whip = {"id": "ITEM_Whip", "kind": "held", "category": "whip", "role": "weapon", "attack_source": "category_table",
            "attacks": {"primary": {"action": "/G/PA_Whip.PA_Whip_C"}}}
    old = _items("100")
    new = _items("200")
    new["items"]["ITEM_Whip"] = whip
    new["items"]["ITEM_Sword"]["stats"]["damage_multiplier"] = 1.5
    new["attack_sets"]["/G/PA_Whip.PA_Whip_C"] = {"chain": ["w1", "w2", "w3"], "damage": [1, 1, 1]}
    write(ctx.data_dir / "items_100.json", json.dumps(old))
    write(ctx.data_dir / "items_200.json", json.dumps(new))
    write(ctx.data_dir / "spells_100.json", json.dumps({"spells": {"USD_A": {"name": "A", "usage": {"role": "combat_damage"}}}}))
    write(ctx.data_dir / "spells_200.json", json.dumps({"spells": {"USD_A": {"name": "A", "usage": {"role": "combat_damage"}},
                                                                   "USD_B": {"name": "B", "usage": {"role": "other"}}}}))
    cd = pp.catalog_diff(ctx, "100", "200")
    assert [i["id"] for i in cd["items"]["added"]] == ["ITEM_Whip"]
    assert cd["items"]["changed"]["ITEM_Sword"] == {"stats.damage_multiplier": [1.0, 1.5]}
    assert cd["items"]["new_weapon_categories"] == {"whip": ["ITEM_Whip"]}
    assert cd["items"]["new_or_changed_attack_chains"][0]["chain"] == ["w1", "w2", "w3"]
    assert cd["spells"]["added"] == ["USD_B"]
    assert any("USD_B" in line and "role tags" in line for line in cd["needs_review"])
    assert any("whip" in line for line in cd["needs_review"])
    same = pp.catalog_diff(ctx, "100", "100")
    assert same["items"]["added"] == [] and not same["items"]["changed"] and same["needs_review"] == []


def test_catalog_missing_is_reported_not_fatal(ctx):
    cd = pp.catalog_diff(ctx, "100", "200")
    assert cd["available"]["items"] == [False, False] and cd["items"] is None


# ---------------------------------------------------------------- report / CLI / snapshot

def test_report_sections_and_files(ctx):
    write(ctx.data_dir / "items_100.json", json.dumps(_items("100")))
    write(ctx.data_dir / "items_200.json", json.dumps(_items("200")))
    delta = pp.full_delta(ctx, "100", "200")
    delta["catalog"] = pp.catalog_diff(ctx, "100", "200")
    jp, mp = pp.write_report(ctx, delta)
    md = mp.read_text(encoding="utf-8")
    for heading in ("## BROKEN (fix before play)", "## Needs review", "## Auto-supported", "## Checklist for the agent"):
        assert heading in md
    assert "/Script/Game.Inv:AddItem" in md and "member removed" in md
    assert json.loads(jp.read_text(encoding="utf-8"))["deps"]["check"]["broken"]
    b, _ = pp.delta_counts(delta)
    assert b >= 4


def _argv(ctx):
    return ["--dumps-dir", str(ctx.dumps_dir), "--data-dir", str(ctx.data_dir), "--out-dir", str(ctx.out_dir),
            "--mod-dir", str(ctx.mod_dir)]


def test_cli_diff_same_build_reports_no_changes(ctx, capsys):
    assert pp.main(_argv(ctx) + ["diff", "100", "100", "--strict"]) == 0
    out = capsys.readouterr().out
    assert "0 change(s)" in out and "BREAKING dependencies: 0" in out
    assert pp.main(_argv(ctx) + ["diff", "100", "200", "--strict"]) == 2  # strict: exit 2 on BROKEN


def test_snapshot_copies_and_indexes(ctx, tmp_path, monkeypatch):
    monkeypatch.setenv("DW_SERVER_ROOT", str(tmp_path / "no_server"))
    monkeypatch.setattr(pp, "MIN_HPP", 1)
    src = tmp_path / "ue4ss"
    make_dump(tmp_path, "src", NEW_HPP, NEW_ENUMS, OBJ_NEW)
    shutil.copytree(tmp_path / "src", src)
    assert pp.snapshot(ctx, "300", src, force=False, dry_run=True) == 0
    assert not (ctx.dumps_dir / "300").exists()
    assert pp.snapshot(ctx, "300", src, force=False, dry_run=False) == 0
    assert (ctx.dumps_dir / "300" / "UE4SS_ObjectDump.txt").exists()
    assert (ctx.dumps_dir / "300" / "index.json.gz").exists()
    assert pp.snapshot(ctx, "300", src, force=False, dry_run=False) == 1  # refuses to overwrite
    assert pp.snapshot(ctx, "300", src, force=True, dry_run=False) == 0


def test_snapshot_refuses_stale_dump_or_wrong_build(ctx, tmp_path, monkeypatch):
    root = tmp_path / "server"
    exe = root / "RSDragonwilds" / "Binaries" / "Win64" / "RSDragonwildsServer-Win64-Shipping.exe"
    write(exe, "x")
    write(root / "steamapps" / "appmanifest_4019830.acf", '"AppState"\n{\n\t"buildid"\t\t"300"\n}\n')
    monkeypatch.setenv("DW_SERVER_ROOT", str(root))
    monkeypatch.setattr(pp, "MIN_HPP", 1)
    src = tmp_path / "ue4ss_dir"
    make_dump(tmp_path, "ue4ss_dir", NEW_HPP, NEW_ENUMS, OBJ_NEW)
    os.utime(src / "UE4SS_ObjectDump.txt", (1, 1))  # older than the server binary: the previous build's dump
    assert pp.server_build_id() == "300"
    assert pp.snapshot(ctx, None, src, force=False, dry_run=True) == 1
    os.utime(src / "UE4SS_ObjectDump.txt", None)
    assert pp.snapshot(ctx, "999", src, force=False, dry_run=True) == 1  # build does not match the manifest
    assert pp.snapshot(ctx, None, src, force=False, dry_run=True) == 0   # fresh dump, build read from the manifest

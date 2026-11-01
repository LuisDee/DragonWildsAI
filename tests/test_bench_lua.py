"""The benchmark's Lua parts (design §4.1, §7.2): the client probe and the dev referee are read-only, the fixture verbs
are frozen and guarded (review findings 1, 13). Static checks plus a stubbed run of the guards."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "client_mod" / "commands" / "bench_probe.lua"
REFEREE = ROOT / "mod" / "bench" / "referee.lua"
FIXTURES = ROOT / "mod" / "bench" / "fixtures.lua"
FROZEN_VERBS = ["grant", "grant_runes", "unlock", "set_time", "spawn", "reset_skills", "teleport", "clear_area",
                "set_health", "raise_skills", "grant_to_ground", "spawn_tester"]
# Calls only (`:Name(`): hook paths that NAME an RPC (read-only post-hooks, e.g. the referee's) are fine.
WRITES = re.compile(r"[:.](Server_|Client_|Multicast_)\w*\s*\(|Inject|SetActorLocation|K2_Set|K2_Destroy|DestroyActor|SpawnActor|"
                    r"SetLifeSpan|:Set[A-Z]\w*\(|AddItem|RemoveItem")


def code(p: Path) -> str:
    return "\n".join(line.split("--", 1)[0] for line in p.read_text(encoding="utf-8").splitlines())


@pytest.mark.parametrize("path", [PROBE, REFEREE])
def test_observers_are_read_only(path):
    hits = [m.group(0) for m in WRITES.finditer(code(path))]
    assert not hits, f"{path.name} must only read the game: {hits}"


def test_probe_is_independent_of_the_skills_under_test():
    src = code(PROBE)
    for mod in ("spells.lua", "sense.lua", "inventory.lua", "combat.lua", "gather.lua", "client_bridge.lua"):
        assert mod not in src


def test_fixture_verbs_are_frozen():
    m = re.search(r"M\.VERBS\s*=\s*\{([^}]*)\}", FIXTURES.read_text(encoding="utf-8"))
    assert m and re.findall(r'"(\w+)"', m.group(1)) == FROZEN_VERBS


def lua() -> str | None:
    for c in (os.environ.get("DW_LUA"), r"C:\Program Files\WinGet\Links\lua.exe", shutil.which("lua")):
        if c and Path(c).exists():
            return c
    return None


STUB = r"""
FindAllOf = function() return {} end
StaticFindObject = function() return nil end
LoopInGameThreadWithDelay = function() return 1 end
local M = assert(loadfile(arg[1]))()
local out = {}
for _, a in ipairs({ {verb="grant"}, {verb="nope"}, {verb="spawn"} }) do
  local r = M.run(nil, a)
  out[#out+1] = tostring(r.ok) .. ":" .. tostring(r.error)
end
print(table.concat(out, ","))
"""


@pytest.mark.skipif(lua() is None, reason="no Lua interpreter")
def test_fixtures_refuse_off_the_dev_server_and_unverified_verbs(tmp_path):
    stub = tmp_path / "stub.lua"
    stub.write_text(STUB, encoding="utf-8")
    env = {k: v for k, v in os.environ.items() if k != "DW_SERVER_ROLE"}
    env["DW_MOD_ROOT"] = str(ROOT / "mod")
    out = subprocess.run([lua(), str(stub), str(FIXTURES)], capture_output=True, text=True, env=env, timeout=60)
    assert out.stdout.strip() == "false:not_dev_server,false:unknown_verb,false:not_dev_server", out.stderr
    env["DW_SERVER_ROLE"] = "dev"
    out = subprocess.run([lua(), str(stub), str(FIXTURES)], capture_output=True, text=True, env=env, timeout=60)
    # no character GUID given: refused before anything happens
    assert out.stdout.strip() == "false:no_character_guid,false:unknown_verb,false:no_character_guid", out.stderr

TELEPORT_STUB = r"""
FindAllOf = function() return {} end
StaticFindObject = function() return nil end
LoopInGameThreadWithDelay = function() return 1 end
local real = arg[2] .. "/body/util.lua"
local U = assert(loadfile(real))()
-- a pawn whose capsule does not fit within 1.2 m of the blocked point (something built over the ladder's start)
local BX, BY = tonumber(arg[3]) * 100, tonumber(arg[4]) * 100
local pawn = { loc = { X = 0, Y = 0, Z = 0 }, tries = 0 }
function pawn:IsValid() return true end
function pawn:K2_GetActorLocation() return self.loc end
function pawn:K2_TeleportTo(l)
  self.tries = self.tries + 1
  if math.sqrt((l.X - BX) ^ 2 + (l.Y - BY) ^ 2) < 120 then return false end
  self.loc = { X = l.X, Y = l.Y, Z = l.Z }; return true
end
pawn.PlayerState = { OwnerGuid = { CharacterGuid = { InnerGuid = {} } } }
U.find_all = function() return { pawn } end
U.guid_hex = function() return "G" end
package.loaded["__util"] = U
local orig = loadfile
loadfile = function(path, ...) if path:find("body/util%.lua$") then return function() return U end end return orig(path, ...) end
local M = assert(orig(arg[1]))()
local out = {}
for _, a in ipairs({ { 10, 20, 0 }, { 50, 60, 0 } }) do
  pawn.tries = 0
  local r = M.run(nil, { verb = "teleport", character_guid = "G", at = a })
  local o = r.offset_m
  out[#out + 1] = string.format("%s:%s:%s:%.2f", tostring(r.ok), tostring(r.error), o and "moved" or "exact",
    math.sqrt((pawn.loc.X / 100 - a[1]) ^ 2 + (pawn.loc.Y / 100 - a[2]) ^ 2))
end
local r = M.run(nil, { verb = "teleport", character_guid = "G", at = { 10, 20, 0 }, exact = true })
out[#out + 1] = tostring(r.ok) .. ":" .. tostring(r.error)
print(table.concat(out, ","))
"""


@pytest.mark.skipif(lua() is None, reason="no Lua interpreter")
def test_teleport_takes_the_nearest_free_spot_when_its_own_is_built_over(tmp_path):
    """Live 2026-11-01 14:43Z: K2_TeleportTo answered false at the chat ladder's start (pieces built over it), the
    fixture said ok=false with no error and two legs were skipped. Now: the nearest spot that fits within 2.5 m, the
    offset reported; exact=true keeps the old refusal, now with a reason."""
    stub = tmp_path / "tp.lua"
    stub.write_text(TELEPORT_STUB, encoding="utf-8")
    env = {**os.environ, "DW_SERVER_ROLE": "dev", "DW_MOD_ROOT": str(ROOT / "mod")}
    out = subprocess.run([lua(), str(stub), str(FIXTURES), str(ROOT / "mod"), "10", "20"], capture_output=True,
                         text=True, env=env, timeout=60)
    rows = out.stdout.strip().split(",")
    assert len(rows) == 3, out.stderr + out.stdout
    ok, err, how, dist = rows[0].split(":")
    assert (ok, err, how) == ("true", "nil", "moved") and 1.2 <= float(dist) <= 2.5, rows[0]
    assert rows[1] == "true:nil:exact:0.00", rows[1]  # a free spot: exactly there, as before
    assert rows[2] == "false:destination_blocked", rows[2]

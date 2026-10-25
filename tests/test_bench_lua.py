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

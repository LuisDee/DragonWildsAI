"""The spells service and the reflex rules engine against fake UE objects:
mod/tests/test_spells.lua (body/spells.lua) and mod/tests/test_rules.lua (body/rules.lua plus the
combat hook wiring). Skipped when no Lua interpreter is found; set DW_LUA to point at one.
"""
import subprocess

import pytest

from tests.test_lua_bridge import LUA, MOD_TESTS

pytestmark = pytest.mark.skipif(LUA is None, reason="no Lua interpreter on PATH (set DW_LUA)")


@pytest.mark.parametrize("suite", ["test_spells.lua", "test_rules.lua", "test_sleep.lua"])
def test_lua_spells_and_rules(suite, tmp_path):
    proc = subprocess.run([LUA, str(MOD_TESTS / suite), str(tmp_path)], capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "FAIL" not in proc.stdout

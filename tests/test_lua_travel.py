"""Lodestone travel, regions and where (mod/body/travel.lua) against fake UE objects (mod/tests/test_travel.lua)."""
import subprocess

import pytest

from tests.test_lua_bridge import LUA, MOD_TESTS

pytestmark = pytest.mark.skipif(LUA is None, reason="no Lua interpreter on PATH (set DW_LUA)")


def test_lua_travel_unit_tests(tmp_path):
    proc = subprocess.run([LUA, str(MOD_TESTS / "test_travel.lua"), str(tmp_path)],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "FAIL" not in proc.stdout

"""Strict crafting emulation (mod/tests/test_crafting.lua): every refusal path, exact consumption and
production, craft time, fuel, refunds, and the generated mod/body/recipe_data.lua.

Runs under a standalone Lua 5.4 interpreter with the UE4SS globals stubbed. Skipped when no
interpreter is found; set DW_LUA to point at one explicitly.
"""
import subprocess

import pytest

from tests.test_lua_bridge import LUA, MOD_TESTS

pytestmark = pytest.mark.skipif(LUA is None, reason="no Lua interpreter on PATH (set DW_LUA)")


def test_lua_crafting_unit_tests(tmp_path):
    proc = subprocess.run([LUA, str(MOD_TESTS / "test_crafting.lua"), str(tmp_path)],
                          capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "FAIL" not in proc.stdout
    assert " 0 failures" in proc.stdout

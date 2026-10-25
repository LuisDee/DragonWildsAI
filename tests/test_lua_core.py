"""The shared Lua core and promoted services (mod/tests/test_core.lua): body/util.lua,
body/removal.lua, the body/speech.lua relay, debug_run's scripts-then-experiments lookup and the
bridge's top-level probe flag.

Runs under a standalone Lua 5.4 interpreter with the UE4SS globals stubbed. Skipped when no
interpreter is found; set DW_LUA to point at one explicitly.
"""
import subprocess

import pytest

from tests.test_lua_bridge import LUA, MOD_TESTS

pytestmark = pytest.mark.skipif(LUA is None, reason="no Lua interpreter on PATH (set DW_LUA)")


def test_lua_core_unit_tests(tmp_path):
    proc = subprocess.run([LUA, str(MOD_TESTS / "test_core.lua"), str(tmp_path)],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "FAIL" not in proc.stdout

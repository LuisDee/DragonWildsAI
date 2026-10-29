"""Run the bounded read-only navigation probe's fake-native Lua checks."""
import subprocess

import pytest

from tests.test_lua_bridge import LUA, MOD_TESTS

pytestmark = pytest.mark.skipif(LUA is None, reason="no Lua interpreter on PATH (set DW_LUA)")


def test_nav_route_probe():
    proc = subprocess.run([LUA, str(MOD_TESTS / "test_nav_route_probe.lua")],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "focused checks passed" in proc.stdout

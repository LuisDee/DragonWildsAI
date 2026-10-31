"""Run EVERY client_mod Lua test suite (auto-discovered), so no suite can be forgotten.

Each suite is `lua client_mod/tests/test_*.lua <empty_dir>` and must exit 0 without printing FAIL.
New suites are picked up automatically by name; this is the regression gate for the client body.
"""
import subprocess
from pathlib import Path

import pytest

from tests.test_lua_bridge import LUA

SUITES = sorted((Path(__file__).resolve().parents[1] / "client_mod" / "tests").glob("test_*.lua"))

pytestmark = pytest.mark.skipif(LUA is None, reason="no Lua interpreter on PATH (set DW_LUA)")


@pytest.mark.parametrize("suite", SUITES, ids=[s.stem for s in SUITES])
def test_client_lua_suite(suite, tmp_path):
    proc = subprocess.run([LUA, str(suite), str(tmp_path)], capture_output=True, text=True,
                          timeout=180, cwd=str(suite.parents[2]))
    out = proc.stdout + proc.stderr
    assert proc.returncode == 0, out[-4000:]
    assert "FAIL" not in proc.stdout, out[-4000:]

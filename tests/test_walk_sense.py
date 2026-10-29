"""Fake native tests for the sampled-walk sensor adapter."""
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
LUA = (os.environ.get("DW_LUA") or shutil.which("lua") or
       str(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "WinGet" / "Links" / "lua.exe"))


def test_walk_sense():
    if not Path(LUA).exists() and not shutil.which(LUA):
        pytest.skip("Lua interpreter unavailable")
    result = subprocess.run([LUA, str(ROOT / "client_mod/tests/test_walk_sense.lua")],
                            capture_output=True, text=True, timeout=30, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "FAIL" not in result.stdout

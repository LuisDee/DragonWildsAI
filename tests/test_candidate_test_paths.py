"""Candidate tests must not silently load nested Lua from the deployed checkout."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

from tests.test_lua_bridge import LUA

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(LUA is None, reason="no Lua interpreter on PATH (set DW_LUA)")
def test_candidate_python_and_nested_lua_override_stale_root(tmp_path):
    marker = "candidate-path-" + tmp_path.name
    wrapper = tmp_path / "inspect.lua"
    wrapper.write_text(r'''
local suite, output, expected, marker = arg[1], arg[2], arg[3], arg[4]
local oldload, oldexit = loadfile, os.exit
local seen = false
loadfile = function(path, ...)
    if path:gsub("\\", "/"):lower():match("/mod/body/util%.lua$") then
        assert(path:gsub("\\", "/"):lower() == expected:gsub("\\", "/"):lower(),
               "nested util loaded outside checkout: " .. path)
        local chunk, err = oldload(path, ...)
        assert(chunk, err)
        seen = true
        local f = assert(io.open(output, "w")); f:write(marker); f:close()
        return chunk
    end
    return oldload(path, ...)
end
os.exit = function(code, ...)
    assert(seen, "suite never loaded nested util")
    return oldexit(code, ...)
end
arg[1] = arg[5]
assert(oldload(suite))()
''', encoding="utf-8")
    output = tmp_path / "lua-sentinel.txt"
    # Start a fresh interpreter with an intentionally stale inherited root: loading
    # conftest must replace it before the real suite's subprocess inherits it.
    script = r'''
import os, pathlib, subprocess, sys
import tests.conftest
import brain.agent
root = pathlib.Path(sys.argv[1]).resolve()
assert pathlib.Path(os.environ["DW_CLIENT_ROOT"]).resolve() == root
assert pathlib.Path(brain.agent.__file__).resolve() == root / "brain" / "agent.py"
print(sys.argv[7], flush=True)
p = subprocess.run([sys.argv[2], sys.argv[3], str(root / "client_mod/tests/test_gather.lua"),
                    sys.argv[4], str(root / "mod/body/util.lua"), sys.argv[7], sys.argv[5]],
                   cwd=root, capture_output=True, text=True, timeout=180)
print(p.stdout, p.stderr)
sys.exit(p.returncode)
'''
    stale = tmp_path / "stale-runtime"
    env = dict(os.environ, DW_CLIENT_ROOT=str(stale))
    proc = subprocess.run([sys.executable, "-c", script, str(ROOT), str(LUA), str(wrapper),
                           str(output), str(tmp_path), "unused", marker], cwd=ROOT, env=env,
                          capture_output=True, text=True, timeout=200)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert marker in proc.stdout
    assert output.read_text(encoding="utf-8") == marker
    assert "FAIL" not in proc.stdout

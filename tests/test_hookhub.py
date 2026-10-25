"""BUGS L24: the shared hook hub (client_mod/scripts/hookhub.lua) and no direct RegisterHook/UnregisterHook
elsewhere in the client mod."""
import re
import subprocess
from pathlib import Path

import pytest

from tests.test_lua_bridge import LUA

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(LUA is None, reason="no Lua interpreter")
def test_hookhub_lua():
    p = subprocess.run([LUA, str(ROOT / "client_mod/tests/test_hookhub.lua")], capture_output=True, text=True, timeout=60)
    assert p.returncode == 0, p.stdout + p.stderr


def test_only_the_hub_registers_and_nothing_unregisters():
    hits = []
    for f in (ROOT / "client_mod" / "scripts").glob("*.lua"):
        if f.name == "hookhub.lua":
            continue
        for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("--", 1)[0]
            if re.search(r"\bpcall\(\s*RegisterHook\b|\bRegisterHook\s*\(|\bUnregisterHook\b", code):
                hits.append(f"{f.name}:{i}: {line.strip()}")
    assert not hits, "hooks must go through hookhub.lua (BUGS L24):\n" + "\n".join(hits)

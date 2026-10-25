"""The real Lua body (mod/scripts/bridge.lua) against the Python BridgeClient.

Runs under a standalone Lua 5.4 interpreter with the UE4SS globals stubbed
(mod/tests/bridge_harness.lua). Skipped when no interpreter is on PATH; set DW_LUA
to point at one explicitly.
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from brain.bridge_client import BridgeClient
from brain.interface import CommandReceived
from brain.jsonl_log import JsonlLogger, read_jsonl
from brain.transport import BODY_TO_BRAIN, BRAIN_TO_BODY, JsonlFileTransport

MOD_TESTS = Path(__file__).resolve().parents[1] / "mod" / "tests"


def _find_lua() -> str | None:
    if os.environ.get("DW_LUA"):
        return os.environ["DW_LUA"]
    for name in ("lua", "lua5.4", "lua54"):
        if path := shutil.which(name):
            return path
    # winget's DEVCOM.Lua link, in case this shell's PATH predates the install.
    winget = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "WinGet" / "Links" / "lua.exe"
    return str(winget) if winget.exists() else None


LUA = _find_lua()
pytestmark = pytest.mark.skipif(LUA is None, reason="no Lua interpreter on PATH (set DW_LUA)")


def test_lua_unit_tests(tmp_path):
    proc = subprocess.run([LUA, str(MOD_TESTS / "test_bridge.lua"), str(tmp_path)],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "FAIL" not in proc.stdout


@pytest.fixture
def lua_body(tmp_path):
    d = tmp_path / "bridge_io"
    d.mkdir()
    # Brain side first, reading from the start so the body's startup event is seen.
    transport = JsonlFileTransport(d / BRAIN_TO_BODY, d / BODY_TO_BRAIN, from_start=True)
    log = JsonlLogger(tmp_path / "bridge.jsonl")
    proc = subprocess.Popen([LUA, str(MOD_TESTS / "run_bridge.lua"), str(d), "30"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert proc.stdout.readline().strip() == "ready", proc.stderr.read()
        yield BridgeClient(transport, log, default_timeout=5.0), d, log
    finally:
        (d / "stop.flag").touch()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def test_ping_round_trip(lua_body):
    client, *_ = lua_body
    rtts = [client.ping() for _ in range(5)]
    assert all(r is not None and r < 2.0 for r in rtts), rtts
    res = client.request("ping")
    assert res["ok"] and res["reason"] is None and res["data"]["pong"] is True
    assert isinstance(res["data"]["server_clock"], (int, float))


def test_not_implemented_and_unknown_tool(lua_body):
    client, *_ = lua_body
    assert client.gather("log", 5) == {"ok": False, "reason": "not_implemented", "data": {"tool": "gather"}}
    assert client.follow("Luis")["reason"] == "not_implemented"
    assert client.say("hi")["reason"] == "not_implemented"
    assert client.request("fly")["reason"] == "unknown_tool"


def test_get_state_stub(lua_body):
    client, *_ = lua_body
    res = client.get_state()
    assert res["ok"] is False and res["reason"] == "not_implemented"
    data = res["data"]
    assert data["position"] is None and data["inventory"] == {} and data["players"] == []
    assert set(data["not_implemented"]) == {"position", "health", "inventory", "following", "players",
                                            "nearby_entities", "nearby_resources", "structures", "places"}


def test_events_and_malformed_lines(lua_body):
    client, d, log = lua_body
    assert client.ping() is not None
    assert CommandReceived(player="Luis", text="!ping") in client.poll_events()
    with (d / BRAIN_TO_BODY).open("a") as f:
        f.write("this is not json\n[1,2,3]\n")
    assert client.ping() is not None  # the body carries on
    lines = read_jsonl(d / BODY_TO_BRAIN)
    assert sum(1 for m in lines if m.get("type") == "error" and m["id"] is None) == 2
    assert "bridge_unmatched" in [r["kind"] for r in log.read_all()]  # id=null errors are logged

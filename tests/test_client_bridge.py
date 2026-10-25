"""The client body's brain bridge (client_mod/scripts/client_bridge.lua, route R2) and the brain's
body switch (DW_BODY / --body client).

Lua parts run under a standalone Lua 5.4 with the UE4SS globals stubbed (mod/tests/bridge_harness.lua)
and the fake client modules in client_mod/tests/fakes/. Skipped when no interpreter is found.
"""
import json
import subprocess
import time
from pathlib import Path

import pytest

from brain import paths, run_live
from brain.bridge_client import BridgeClient
from brain.capabilities import discover
from brain.dry_run_llm import DryRunController, DryRunPlanner
from brain.fake_body import FakeBody
from brain.interface import CommandReceived
from brain.jsonl_log import JsonlLogger
from brain.mock import MockGame
from brain.run_live import LiveOptions, LiveSession
from brain.transport import (BODY_TO_BRAIN, BRAIN_TO_BODY, BRAIN_TO_CLIENT, CLIENT_TO_BRAIN, JsonlFileTransport,
                             endpoint_files, file_transport_pair)
from tests.test_lua_bridge import LUA

CLIENT_TESTS = Path(__file__).resolve().parents[1] / "client_mod" / "tests"
needs_lua = pytest.mark.skipif(LUA is None, reason="no Lua interpreter on PATH (set DW_LUA)")


# --------------------------------------------------------------------------- brain-side switch


def test_body_kind_and_default_dirs(monkeypatch):
    monkeypatch.delenv("DW_BODY", raising=False)
    monkeypatch.delenv("DW_BRIDGE_DIR", raising=False)
    assert paths.body_kind() == "server"
    assert paths.bridge_dir() == paths.REPO_ROOT / "bridge_io"
    assert paths.bridge_dir("client") == paths.REPO_ROOT / "client_io" / "bridge"
    monkeypatch.setenv("DW_BODY", "Client")
    assert paths.body_kind() == "client" and paths.bridge_dir() == paths.REPO_ROOT / "client_io" / "bridge"
    assert endpoint_files() == (BRAIN_TO_CLIENT, CLIENT_TO_BRAIN)
    assert endpoint_files("server") == (BRAIN_TO_BODY, BODY_TO_BRAIN)
    monkeypatch.setenv("DW_BRIDGE_DIR", "/somewhere")
    assert paths.bridge_dir("client") == Path("/somewhere")
    monkeypatch.setenv("DW_BODY", "puppet")
    with pytest.raises(ValueError):
        paths.body_kind()


def test_client_transport_pair_uses_its_own_files(tmp_path):
    brain_t, body_t = file_transport_pair(tmp_path, "client")
    brain_t.send({"v": 1, "type": "cmd", "id": "a", "tool": "ping", "args": {}})
    assert (tmp_path / BRAIN_TO_CLIENT).exists() and not (tmp_path / BRAIN_TO_BODY).exists()
    assert body_t.receive(1.0)[0]["id"] == "a"
    body_t.send({"v": 1, "type": "result", "id": "a", "ok": True, "reason": None, "data": {}})
    assert (tmp_path / CLIENT_TO_BRAIN).exists() and brain_t.receive(1.0)[0]["type"] == "result"


def test_parse_args_body(monkeypatch):
    monkeypatch.delenv("DW_BODY", raising=False)
    assert run_live.parse_args(["--body", "client"]).body == "client"
    assert run_live.parse_args([]).body is None
    with pytest.raises(SystemExit):
        run_live.parse_args(["--body", "puppet"])


def test_live_session_drives_a_client_body(tmp_path):
    """The fake body pattern on the client endpoint: same brain, client file names, body in the banner."""
    d = tmp_path / "client_bridge"
    _, body_t = file_transport_pair(d, "client")
    game = MockGame.default_world()
    body = FakeBody(game, body_t, capabilities=["ping", "capabilities", "get_state", "say", "follow", "stop",
                                                "go_to"]).start()
    banner: list[str] = []
    try:
        session = LiveSession(LiveOptions(body="client", bridge_dir=d, state_dir=tmp_path / "state",
                                          log_dir=tmp_path / "logs", dry_run=True, wait=5.0, probe_timeout=1.0),
                              DryRunController(), DryRunPlanner(), out=banner.append)
        text = "\n".join(banner)
        assert "body         : client" in text and "client_mod" in text
        # tools the client body doesn't list are unavailable: hidden from the Controller and the Planner
        assert session.store.skills.names() == ["go_to", "follow", "stop"]
        assert "gather" in session.caps.missing and "attack" in session.caps.missing
        assert not (d / BRAIN_TO_BODY).exists()
        game.player_say("!c follow me")
        deadline = time.monotonic() + 5
        while game.following != "Luis":
            assert time.monotonic() < deadline, "follow never happened"
            session.step()
            time.sleep(0.02)
        start = [r for r in session.log.read_all() if r["kind"] == "session_start"][0]
        assert start["body"] == "client"
    finally:
        body.stop()


# --------------------------------------------------------------------------- Lua client bridge


@needs_lua
def test_lua_unit_tests(tmp_path):
    proc = subprocess.run([LUA, str(CLIENT_TESTS / "test_client_bridge.lua"), str(tmp_path)],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "FAIL" not in proc.stdout


class LuaClient:
    """The real client_bridge.lua with fake client modules, as a subprocess."""

    def __init__(self, base: Path):
        self.base = base
        self.bridge = base / "bridge"
        self.chat = base / "chat.jsonl"
        self.proc = subprocess.Popen([LUA, str(CLIENT_TESTS / "run_client_bridge.lua"), str(base), "40"],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert self.proc.stdout.readline().strip() == "ready", self.proc.stderr.read()

    def player_says(self, text: str, who: str = "Luis") -> None:
        with self.chat.open("a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps({"type": "chat", "from": who, "text": text, "self": False}) + "\n")

    def echoes(self) -> list[str]:
        return [m["text"] for line in self.chat.read_text(encoding="utf-8").splitlines()
                if (m := json.loads(line)).get("self")]

    def close(self) -> None:
        (self.base / "stop.flag").touch()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


@pytest.fixture
def lua_client(tmp_path):
    body = LuaClient(tmp_path)
    to_body, to_brain = endpoint_files("client")
    log = JsonlLogger(tmp_path / "brain.jsonl")
    client = BridgeClient(JsonlFileTransport(body.bridge / to_body, body.bridge / to_brain), log, default_timeout=5.0)
    try:
        yield client, body, log
    finally:
        body.close()


@needs_lua
def test_capabilities_and_registry(lua_client, tmp_path):
    client, *_ = lua_client
    assert client.ping() is not None
    caps = discover(client, timeout=3.0)
    assert caps.source == "capabilities"
    for tool in ("get_state", "say", "follow", "stop", "go_to", "drop"):
        assert caps.has(tool), tool
    assert caps.skills() == ["go_to", "follow", "stop", "drop"]
    assert not caps.has("gather") and not caps.has("attack") and not caps.has("craft")


@needs_lua
def test_state_follow_say_and_chat(lua_client):
    client, body, _ = lua_client
    state = client.get_state()
    assert state["ok"], state
    d = state["data"]
    assert d["position"] == [1, 2, 3] and d["inventory"] == {"ITEM_Resources_Wood_Oak": 8} and d["body"] == "client"
    assert d["players"][0]["name"] == "Luis" and d["following"] is None
    assert client.follow("Luis")["ok"]
    assert client.get_state()["data"]["following"] == "Luis"
    said = client.say("hello from the client")
    assert said["ok"] and said["data"]["verified"] is True, said  # the server echo arrived
    assert "hello from the client" in body.echoes()
    body.player_says("claude, come here")
    body.player_says("nice weather")  # not addressed: stays off the wire
    deadline = time.monotonic() + 3
    events = []
    while not events:
        assert time.monotonic() < deadline, "no command_received"
        events = [e for e in client.poll_events() if isinstance(e, CommandReceived)]
        time.sleep(0.02)
    time.sleep(0.2)
    events += [e for e in client.poll_events() if isinstance(e, CommandReceived)]
    assert events == [CommandReceived(player="Luis", text="claude, come here")]
    dropped = client.drop("oak", 2)  # waits for the (fake) server to confirm: the inventory shrinks
    assert dropped["ok"] and dropped["data"]["item"] == "ITEM_Resources_Wood_Oak", dropped
    assert client.get_state()["data"]["inventory"] == {"ITEM_Resources_Wood_Oak": 6}
    go = client.go_to([7.0, 8.0, 3.0])
    assert go["ok"] and go["data"]["target_position"] == [7, 8, 3], go
    assert client.get_state()["data"]["following"] is None  # go_to pre-empted follow


@needs_lua
def test_live_session_end_to_end_on_lua_client(lua_client, tmp_path):
    """run_live (dry run) -> real client_bridge.lua -> fake client modules: !ping, follow me, come here."""
    _, body, _ = lua_client
    session = LiveSession(LiveOptions(body="client", bridge_dir=body.bridge, state_dir=tmp_path / "state",
                                      log_dir=tmp_path / "logs", dry_run=True, wait=5.0, probe_timeout=1.0),
                          DryRunController(), DryRunPlanner(), out=lambda s: None)
    assert session.store.skills.names() == ["go_to", "follow", "stop", "drop"]

    def run_until(pred, what):
        deadline = time.monotonic() + 8
        while not pred():
            assert time.monotonic() < deadline, what
            session.step()
            time.sleep(0.02)

    body.player_says("!ping")
    run_until(lambda: "pong" in body.echoes(), "pong never said")
    body.player_says("!c follow me")
    run_until(lambda: any(r["kind"] == "task_done" and r.get("skill", r.get("task", {}).get("skill")) == "follow"
                          or (r["kind"] == "tool_result" and r.get("tool") == "follow")
                          for r in session.log.read_all()), "follow never ran")
    body.player_says("!c come here")
    run_until(lambda: "(dry run) On my way." in body.echoes(), "go_to never acknowledged")
    results = [r for r in session.log.read_all() if r["kind"] == "tool_result"]
    by_tool = {r["tool"]: r for r in results}
    assert by_tool["follow"]["result"]["ok"] and by_tool["go_to"]["result"]["ok"], by_tool

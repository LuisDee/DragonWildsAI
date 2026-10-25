"""run_live in dry-run mode against the fake body over the real JSONL bridge files (no game, no API)."""
import time

import pytest

from brain import run_live
from brain.capabilities import discover
from brain.bridge_client import BridgeClient
from brain.dry_run_llm import DryRunController, DryRunPlanner
from brain.fake_body import FakeBody
from brain.jsonl_log import JsonlLogger
from brain.mock import MockGame
from brain.run_live import LiveOptions, LiveSession, chat_route
from brain.tail_logs import format_line, latest_log
from brain.transport import file_transport_pair

PREFIXES = run_live.DEFAULT_PREFIXES


class Live:
    def __init__(self, tmp_path, **body_kwargs):
        self.dir = tmp_path / "bridge_io"
        _, body_t = file_transport_pair(self.dir)
        self.game = MockGame.default_world()
        self.body = FakeBody(self.game, body_t, **body_kwargs).start()
        opts = LiveOptions(bridge_dir=self.dir, state_dir=tmp_path / "state", log_dir=tmp_path / "logs",
                           dry_run=True, wait=5.0, probe_timeout=1.0)
        self.controller_llm, self.planner_llm = DryRunController(), DryRunPlanner()
        self.banner: list[str] = []
        self.session = LiveSession(opts, self.controller_llm, self.planner_llm, out=self.banner.append)

    def said(self) -> list[str]:
        return [text for who, text in self.game.chat if who == "companion"]

    def chat(self, text: str, until=None, timeout: float = 5.0) -> None:
        """Luis types ``text``; step the live loop until ``until()`` holds."""
        before = len(self.said())
        until = until or (lambda: len(self.said()) > before)
        self.game.player_say(text)
        deadline = time.monotonic() + timeout
        while not until():
            assert time.monotonic() < deadline, f"no reaction to {text!r}; said {self.said()}"
            self.session.step()
            time.sleep(0.02)

    def kinds(self) -> list[str]:
        return [r["kind"] for r in self.session.log.read_all()]

    def close(self) -> None:
        self.body.stop()


@pytest.fixture
def live(tmp_path):
    rig = Live(tmp_path)
    yield rig
    rig.close()


def test_chat_route():
    assert chat_route("!ping", PREFIXES) == ("ping", None)
    assert chat_route("  !PING hello", PREFIXES) == ("ping", None)
    assert chat_route("!c follow me", PREFIXES) == ("command", "follow me")
    assert chat_route("Companion, come here", PREFIXES) == ("command", "come here")
    assert chat_route("follow me", PREFIXES) == ("ignore", None)  # players talking to each other
    assert chat_route("!c", PREFIXES) == ("ignore", None)
    assert chat_route("!pinging", PREFIXES) == ("ignore", None)


def test_startup_banner_and_capabilities(live):
    banner = "\n".join(live.banner)
    assert "DRY RUN" in banner and "dry-run/rules" in banner and "dry-run/planner" in banner
    assert live.session.caps.source == "capabilities"
    assert live.session.store.skills.names() == ["go_to", "follow", "stop", "attack", "gather", "craft",
                                                 "give", "place", "pickup", "drop", "cast", "sleep", "wake",
                                                 "interact"]
    assert live.session.log.path.name.startswith("brain-live-")


def test_ping_replies_pong_without_llm(live):
    live.chat("!ping")
    assert live.said() == ["pong"]
    assert live.controller_llm.calls == [] and live.planner_llm.calls == []
    reply = [r for r in live.session.log.read_all() if r["kind"] == "ping_reply"]
    assert reply and reply[0]["ok"] is True and reply[0]["say_round_trip_ms"] >= 0


def test_unaddressed_chat_is_ignored(live):
    live.game.player_say("follow me")  # no prefix: Luis is talking to someone else
    for _ in range(10):
        live.session.step()
        time.sleep(0.02)
    assert live.controller_llm.calls == [] and live.game.following is None
    assert any(r.get("route") == "ignore" for r in live.session.log.read_all() if r["kind"] == "event")


def test_follow_me_calls_follow(live):
    live.chat("!c follow me")
    assert live.game.following == "Luis"
    assert [n for n, _ in live.game.calls if n != "get_state"] == ["follow", "say"]
    assert live.said() == ["(dry run) Right behind you."]
    assert len(live.controller_llm.calls) == 1
    # every step is in the session log
    kinds = live.kinds()
    for kind in ("session_start", "capabilities", "event", "prompt", "llm_response", "tool_call",
                 "tool_result", "task_done", "say", "say_result"):
        assert kind in kinds, kind
    calls = [r for r in live.session.log.read_all() if r["kind"] == "tool_call"]
    assert calls[0]["tool"] == "follow" and calls[0]["args"]["player"] == "Luis"


def test_goal_in_dry_run_asks_for_help(live):
    live.chat("companion, gather 3 logs and bring them to me")
    assert "dry-run mode" in live.said()[-1] and "stuck" in live.said()[-1]


def test_not_implemented_at_call_time(tmp_path):
    """The body lists follow but its handler is still a stub: say so, don't pretend."""
    rig = Live(tmp_path, capabilities=["get_state", "follow", "say", "ping"], not_implemented={"follow"})
    try:
        assert rig.session.store.skills.names() == ["follow"]
        rig.chat("!c follow me")
        assert rig.said() == ["Sorry, I can't follow you yet."]
        assert rig.game.following is None
    finally:
        rig.close()


def test_old_body_without_capabilities_is_probed(tmp_path):
    """No capabilities request: probe each tool; not_implemented ones stay out of the registry."""
    rig = Live(tmp_path, capabilities=False, not_implemented={"follow", "attack", "place"})
    try:
        caps = rig.session.caps
        assert caps.source == "probe"
        assert caps.missing["follow"] == "not_implemented" and "capabilities" in caps.missing
        assert rig.session.store.skills.names() == ["go_to", "stop", "gather", "craft", "give", "pickup", "drop",
                                                    "cast", "sleep", "wake", "interact"]
        assert rig.game.calls == []  # probes never act on the fake body
        rig.chat("!c follow me")
        assert rig.said() == ["Sorry, I can't follow you yet."]
        assert "follow" not in [n for n, _ in rig.game.calls]
        rig.chat("!c come here")
        assert rig.said()[-1] == "(dry run) On my way."
    finally:
        rig.close()


def test_missing_get_state_refuses_actions(tmp_path):
    rig = Live(tmp_path, not_implemented={"get_state"})
    try:
        assert "no 'get_state'" in "\n".join(rig.banner)
        rig.chat("!c follow me")
        assert rig.said() == ["I can't follow you yet: I can't read the game state."]
        assert rig.game.following is None
    finally:
        rig.close()


def test_discover_against_body_without_any_skills(tmp_path):
    brain_t, body_t = file_transport_pair(tmp_path)
    body = FakeBody(MockGame(), body_t, capabilities=["ping"]).start()
    try:
        caps = discover(BridgeClient(brain_t, JsonlLogger(tmp_path / "l.jsonl")))
        assert caps.tools == [] and caps.registry().names() == []
    finally:
        body.stop()


def test_refuses_to_start_without_key(tmp_path, monkeypatch, capsys):
    for var in ("DW_CONTROLLER_MODEL", "DW_PLANNER_MODEL", "ANTHROPIC_API_KEY"):
        monkeypatch.delenv(var, raising=False)
    assert run_live.main(["--bridge-dir", str(tmp_path)]) == 2
    assert "DW_CONTROLLER_MODEL is not set" in capsys.readouterr().err
    monkeypatch.setenv("DW_CONTROLLER_MODEL", "anthropic/some-model")
    monkeypatch.setenv("DW_PLANNER_MODEL", "anthropic/some-model")
    assert run_live.main(["--bridge-dir", str(tmp_path)]) == 2
    assert "ANTHROPIC_API_KEY" in capsys.readouterr().err


def test_tail_logs_formats_session(live):
    live.chat("!ping")
    live.chat("!c follow me")
    assert latest_log(live.session.log.path.parent) == live.session.log.path
    lines = [s for raw in live.session.log.path.read_text(encoding="utf-8").splitlines()
             if (s := format_line(raw))]
    text = "\n".join(lines)
    assert "chat Luis: '!ping' [ping]" in text and "SAY 'pong'" in text
    assert "call follow(player=" in text and "result follow: ok" in text
    assert "bridge_send" not in text  # raw bridge traffic hidden by default

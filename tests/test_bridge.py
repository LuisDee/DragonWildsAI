"""JSONL bridge round trip through the fake body (no game needed)."""
import json

import pytest
from conftest import Rig

from brain.bridge_client import BridgeClient
from brain.fake_body import FakeBody
from brain.interface import Attacked, CommandReceived
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM
from brain.mock import MockGame
from brain.transport import BRAIN_TO_BODY, BODY_TO_BRAIN, file_transport_pair


@pytest.fixture
def bridge(tmp_path):
    brain_t, body_t = file_transport_pair(tmp_path / "bridge_io")
    game = MockGame.default_world()
    body = FakeBody(game, body_t).start()
    log = JsonlLogger(tmp_path / "bridge.jsonl")
    client = BridgeClient(brain_t, log, default_timeout=5.0)
    yield client, game, body, tmp_path / "bridge_io", log
    body.stop()


def test_ping_round_trip(bridge):
    client, *_ = bridge
    rtt = client.ping()
    assert rtt is not None and rtt < 2.0


def test_actions_round_trip(bridge):
    client, game, *_ = bridge
    state = client.get_state()
    assert state["ok"] and state["data"]["position"] == [0.0, 0.0, 0.0]
    assert client.gather("log", 2)["ok"]
    assert client.get_state()["data"]["inventory"] == {"log": 2}
    res = client.gather("gold", 1)
    assert res == {"ok": False, "reason": "nothing_in_range", "data": {"resource": "gold"}}
    assert game.inventory["log"] == 2


def test_events_cross_the_bridge(bridge):
    client, game, *_ = bridge
    game.script_failure("gather", "attacked")
    res = client.gather("log", 4)
    assert res["reason"] == "attacked"
    events = client.poll_events()
    progress = [e for e in events if e.type == "gather_progress"]
    others = [e for e in events if e.type != "gather_progress"]
    assert [(p.have, p.want) for p in progress] == [(2, 4)]  # sent live, before the result
    assert len(others) == 1 and isinstance(others[0], Attacked) and others[0].by == res["data"]["by"]


def test_unsolicited_chat_event(bridge):
    client, game, *_ = bridge
    game.player_say("!ping")
    for _ in range(50):
        if events := client.poll_events():
            break
        client.ping()
    assert CommandReceived(player="Luis", text="!ping") in events


def test_malformed_lines_are_skipped(bridge):
    client, game, body, d, log = bridge
    with (d / BRAIN_TO_BODY).open("a") as f:
        f.write("this is not json\n[1,2,3]\n")
    with (d / BODY_TO_BRAIN).open("a") as f:
        f.write("{broken json\n")
    assert client.ping() is not None  # both sides carry on
    kinds = [r["kind"] for r in log.read_all()]
    assert "bridge_malformed" in kinds
    # the body reported each malformed command line with id=null
    lines = [json.loads(x) for x in (d / BODY_TO_BRAIN).read_text().splitlines() if x.startswith('{"')]
    assert sum(1 for m in lines if m.get("type") == "error" and m["id"] is None) == 2


def test_timeout_when_body_is_down(tmp_path):
    brain_t, _ = file_transport_pair(tmp_path)
    client = BridgeClient(brain_t, JsonlLogger(tmp_path / "l.jsonl"))
    res = client.request("get_state", timeout=0.2)
    assert res["ok"] is False and res["reason"] == "timeout"


def test_partial_line_waits_for_completion(tmp_path):
    brain_t, body_t = file_transport_pair(tmp_path)
    with (tmp_path / BODY_TO_BRAIN).open("a") as f:
        f.write('{"v":1,"type":"event","event":{"type":"attac')
    assert brain_t.receive() == []
    with (tmp_path / BODY_TO_BRAIN).open("a") as f:
        f.write('ked","by":"wolf_1"}}\n')
    assert brain_t.receive() == [{"v": 1, "type": "event", "event": {"type": "attacked", "by": "wolf_1"}}]


def test_agent_runs_over_bridge(bridge, tmp_path):
    """The same agent code drives the bridge client as drives the mock (principle 7)."""
    client, game, *_ = bridge
    rig = Rig(tmp_path, game=client)
    rig.planner_llm.push(FakeLLM.plan([
        {"skill": "gather", "args": {"resource": "log", "count": 2}},
        {"skill": "go_to", "args": {"target": "Luis"}},
        {"skill": "give", "args": {"player": "Luis", "item": "log", "count": 2}},
    ]))
    assert rig.agent.run_goal("bring Luis 2 logs") == "done"
    assert game.players["Luis"].inventory["log"] == 2
    assert game.chat[-1][1].startswith("Done")

"""Stage1 terrain delivery: real published manifest and Python adapters, fake transport/provider only."""
import copy
import json
import subprocess
import sys
import types
from pathlib import Path

import pytest

from brain import director as D
from brain import llm as L
from brain import predicates as P
from brain.board import Step
from brain.bridge_client import BridgeClient
from brain.capabilities import ManifestError, discover
from brain.controller import Controller, _model_read_view, continuation_observation
from brain.jsonl_log import JsonlLogger
from brain.state_store import StateStore
from tests.test_lua_bridge import LUA
from test_director import decision, make, step
from test_model_interface_contract import provider_response


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def published(tmp_path_factory):
    if LUA is None:
        pytest.skip("Lua interpreter unavailable for real manifest dump")
    folder = tmp_path_factory.mktemp("terrain-manifest")
    result = subprocess.run([LUA, str(ROOT / "client_mod/tests/dump_manifest.lua"), str(folder)],
                            cwd=ROOT, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    data = json.loads(result.stdout)
    entries = data["manifest"]
    entries = {entry["name"]: entry for entry in entries} if isinstance(entries, list) else entries
    assert "terrain" in data["tools"] and "terrain" in entries
    return data, entries["terrain"]


def terrain_packet():
    return {"version": 1, "mode": "history", "status": "historical", "window_id": "window-7", "revision": 7,
            "request_id": "recorded-body-request", "world": "held-out-world", "build": "unknown",
            "provenance": "unknown", "source": {"actual_capsule_center_m": [12, 34, -30],
                "half_height_m": .88, "observed_at": 17.25, "clock": "unix_seconds", "age_s": "unknown"},
            "objective_center_m": [80, 80, -35],
            "coverage": {"sampled_columns": 361, "total_columns": 361, "unvisited_columns": 0,
                "new_columns": 179, "overlap_columns": 182, "relative_to_window_ids": ["window-6"],
                "history_truncated": False},
            "candidates": [{"observation_candidate_id": f"candidate-{i}", "window_id": "window-7",
                "floor_position_m": [10 + i, 34, -32], "derived_capsule_center_m": [10 + i, 34, -31.12],
                "half_height_m": .88, "derivation": "floor_plus_current_half_height", "source": "line_hit_candidate",
                "connection": "planner_ray_checks", "ray_scope": "knee_height_with_self_region_exclusion",
                "capsule_clearance": "unknown",
                "path_length_m": i + 1, "predicted_new_columns": 170 - i} for i in range(3)],
            "layered_columns": {"total": 8, "returned": 8, "truncated": False, "columns": [
                {"column_m": [40 + i, 30], "floor_heights_m": [-36.7, -28.8],
                 "source": "line_hit_candidate", "layer_identity": "unknown"}
                for i in range(8)]},
            "attempts": [{"request_id": f"old-move-{i}", "tool": "go_to", "requested_target": [80, 80, -35],
                "actual_end": [12, 34, -30], "ok": False, "endpoint_convention": "reported_by_mover",
                "reason": "verification_failed", "detail": "route ended short", "observation_revision": 6,
                "observed_at": 15 + i, "clock": "unix_seconds", "provenance": "unknown"} for i in range(4)],
            "limitations": ["Directed rays are not capsule clearance.", "Layers may have unknown connectivity."]}


class TerrainTransport:
    def __init__(self, published, *, partial=False, plain=False):
        self.published = published
        self.sent, self.pending = [], []
        self.packet = terrain_packet()
        self.partial, self.plain = partial, plain

    def send(self, msg):
        self.sent.append(copy.deepcopy(msg))
        data, ok, reason = copy.deepcopy(self.published), True, None
        if msg["tool"] == "terrain":
            packet = copy.deepcopy(self.packet)
            packet["request_id"] = msg["id"]
            packet["mode"] = msg["args"].get("mode", "survey")
            packet["status"] = "complete" if packet["mode"] == "survey" else "historical"
            if packet["mode"] == "history":
                packet["windows"] = [{"window_id": f"window-{i}", "status": "partial" if i == 4 else "complete",
                    "source": copy.deepcopy(packet["source"])} for i in range(4, 8)]
            elif packet["mode"] == "window":
                rows = [{"column_m": [20 + i, 30], "floor_heights_m": [], "source": "no_candidate_observed",
                         "layer_identity": "unknown"} for i in range(16)] + packet["layered_columns"]["columns"]
                if "column_m" in msg["args"]:
                    rows = [row for row in rows if row["column_m"] == msg["args"]["column_m"]]
                cursor, limit = msg["args"].get("cursor", 0), msg["args"].get("limit", 8)
                packet.update(columns=copy.deepcopy(rows[cursor:cursor + limit]), cursor=cursor, total=len(rows))
                if cursor + limit < len(rows):
                    packet["next_cursor"] = cursor + limit
            if self.partial:
                packet["status"], ok, reason = "partial", False, "timeout"
            if self.plain and "toward" not in msg["args"]:
                packet["candidates"] = []
                packet.pop("objective_center_m", None)
            data = {"terrain": packet, "detail": "partial observation" if self.partial else "recorded observation"}
        self.pending.append({"type": "result", "id": msg["id"], "ok": ok, "reason": reason, "data": data})

    def receive(self, timeout):
        rows, self.pending = self.pending, []
        return rows


def adapters(tmp_path, published, **kw):
    transport = TerrainTransport(published[0], **kw)
    log = JsonlLogger(tmp_path / "boundary.jsonl")
    client = BridgeClient(transport, log)
    caps = discover(client)
    return transport, client, caps, log


def scripted_provider(monkeypatch, responses):
    sent, script = [], iter(responses)
    def complete(**kwargs):
        sent.append(copy.deepcopy(kwargs))
        return next(script)
    monkeypatch.setitem(sys.modules, "litellm", types.SimpleNamespace(completion=complete))
    return sent


def request_tool(name, args, call_id):
    return provider_response(None, "tool_calls", [types.SimpleNamespace(id=call_id,
        function=types.SimpleNamespace(name=name, arguments=json.dumps(args)))])


def message_json(message):
    content = message["content"]
    if isinstance(content, list):
        content = content[0]["text"]
    return json.loads(content)


def test_actual_manifest_discovery_read_classification_and_exact_argument_dispatch(tmp_path, published):
    transport, client, caps, log = adapters(tmp_path, published)
    entry = published[1]
    assert entry["kind"] == "read" and entry["moves"] is False and entry["llm"] is True
    assert set(entry["args"]["properties"]) == {"mode", "toward", "window_id", "column_m", "cursor", "limit"}
    controller = Controller(L.FakeLLM(), client, StateStore(tmp_path / "state"), log, caps=caps)
    assert "terrain" in controller.read_tools and "terrain" in controller.offered()
    offered = next(t for t in controller.tools if t["function"]["name"] == "terrain")
    assert offered["function"]["parameters"] == caps.function_schema("terrain")["function"]["parameters"]
    for args in [{}, {"mode": "survey", "toward": [80, 80, -35]}, {"mode": "history", "cursor": 0, "limit": 4},
                 {"mode": "window", "window_id": "window-7", "column_m": [40, 30], "cursor": 2, "limit": 24}]:
        clean = controller._validate("terrain", args)
        result = client.call("terrain", clean)
        assert result["ok"] and transport.sent[-1]["args"] == clean
        for key, value in args.items():
            assert clean[key] == value
        assert ("toward" in clean) is ("toward" in args)
    before = len(transport.sent)
    for bad in [{"mode": "teleport"}, {"limit": 25}, {"cursor": -1}, {"toward": [1, 2]},
                {"mode": "window"}, {"mode": "history", "toward": [1, 2, 3]}, {"route": "candidate-1"}]:
        with pytest.raises(ManifestError):
            controller._validate("terrain", bad)
    assert len(transport.sent) == before


@pytest.mark.parametrize("partial,plain", [(False, False), (True, False), (False, True)])
def test_actual_haiku_requests_preserve_read_result_cached_state_and_continuation(tmp_path, published, monkeypatch, partial, plain):
    transport, client, caps, log = adapters(tmp_path, published, partial=partial, plain=plain)
    args = {"mode": "survey"} if plain else {"mode": "survey", "toward": [80, 80, -35]}
    sent = scripted_provider(monkeypatch, [request_tool("terrain", args, "haiku-terrain-1"), provider_response(""),
                                         provider_response("")])
    c = Controller(L.LiteLLMClient("anthropic/haiku-test", max_tokens=1024), client,
                   StateStore(tmp_path / "state"), log, caps=caps)
    cached = terrain_packet()
    state = {"position": [12, 34, -30], "health": 100, "max_health": 100, "terrain": cached}
    event = {"type": "board_step", "board_task_id": "actual-task", "step_id": "actual-step", "attempt": 2}
    choice = c.decide("Luis", "", state, None, body_event=event)
    assert not choice.actions and not choice.interrupts
    initial = message_json(sent[0]["messages"][1])
    assert initial["terrain"] == cached and initial["body_event"] == event
    tool_result = next(m for m in sent[1]["messages"] if m["role"] == "tool")
    raw = message_json(tool_result)
    request = next(m for m in transport.sent if m["tool"] == "terrain")
    assert tool_result["tool_call_id"] == "haiku-terrain-1"
    assert raw["ok"] is (not partial) and raw["data"]["terrain"]["request_id"] == request["id"]
    assert raw["data"]["terrain"]["source"] == cached["source"]
    assert raw["data"]["terrain"]["layered_columns"] == cached["layered_columns"]
    assert raw["data"]["terrain"]["attempts"] == cached["attempts"]
    if plain:
        assert raw["data"]["terrain"]["candidates"] == [] and "objective_center_m" not in raw["data"]["terrain"]
    elif partial:
        assert raw["data"]["terrain"]["status"] == "partial" and raw["reason"] == "timeout"
    else:
        assert raw["data"]["terrain"]["candidates"] == cached["candidates"]
    c.next_turn(choice, {}, state)
    observation = next(m for m in sent[2]["messages"] if m["role"] == "user" and
                       isinstance(m["content"], str) and m["content"].startswith("Current observation: "))
    assert json.loads(observation["content"].split(": ", 1)[1])["terrain"] == cached
    assert not any(caps.manifest.get(m["tool"], {}).get("moves") is True for m in transport.sent)


@pytest.mark.parametrize("args", [{"mode": "survey", "toward": [80, 80, -35]}, {"mode": "history"},
                                  {"mode": "window", "window_id": "window-7", "column_m": [40, 30]},
                                  {"mode": "window", "window_id": "window-7", "limit": 24}])
def test_actual_sonnet_research_and_current_task_snapshot_preserve_terrain(tmp_path, published, monkeypatch, args):
    transport, client, caps, _ = adapters(tmp_path, published)
    goal = {"near": {"position": [80, 80, -35], "within_m": 3}}
    sent = scripted_provider(monkeypatch, [request_tool("terrain", args, "sonnet-terrain-1"),
        provider_response(decision(task_success=goal, steps=[step("continue the journey", goal)]))])
    d, port, world, _, _ = make(tmp_path / "director")
    d.caps, d.body_tools = caps, {n: e.get("description", n) for n, e in caps.manifest.items()}
    d.llm = L.LiteLLMClient("anthropic/sonnet-test", max_tokens=4096)
    d.proxy = D.BodyProxy(client.call)
    d.proxy.serve()
    packet = terrain_packet()
    world.state["terrain"] = packet
    task = d.ops.add_task("reach the original far destination", by="player:Luis")
    task.success = {"predicate": goal}
    task.steps = [Step(title="failed earlier attempt", success=goal, status="failed", attempts=2)]
    snapshot = d._snapshot(task, {"kind": "replan", "detail": {"failed": {"board_task_id": task.id,
        "step_id": task.steps[0].id, "attempt": 2}}}, world.state)
    outcome = d._decide(snapshot)
    assert not outcome.error
    initial = message_json(sent[0]["messages"][1])
    assert initial["me"]["terrain"] == packet and initial["job"]["id"] == task.id
    assert initial["steps_so_far"][0]["id"] == task.steps[0].id
    assert initial["detail"]["failed"]["attempt"] == 2
    schema = next(t for t in sent[0]["tools"] if t["function"]["name"] == "terrain")
    assert schema["function"]["parameters"] == published[1]["args"]
    result_msg = next(m for m in sent[1]["messages"] if m["role"] == "tool")
    terrain = message_json(result_msg)["data"]["terrain"]
    assert result_msg["tool_call_id"] == "sonnet-terrain-1"
    assert terrain["request_id"] == next(m for m in transport.sent if m["tool"] == "terrain")["id"]
    assert terrain["layered_columns"] == packet["layered_columns"] and terrain["attempts"] == packet["attempts"]
    if args["mode"] == "history":
        assert len(terrain["windows"]) == 4 and terrain["windows"][0]["status"] == "partial"
    elif args["mode"] == "window":
        assert terrain["status"] == "historical"
        if "column_m" in args:
            assert terrain["columns"] == [packet["layered_columns"]["columns"][0]]
        else:
            assert terrain["total"] == len(terrain["columns"]) == 24
            assert terrain["columns"][16:] == packet["layered_columns"]["columns"]
            assert terrain["columns"][0]["floor_heights_m"] == []
    assert not P.evaluate(goal, world.state).passed and not port.events
    packet["source"]["observed_at"] = 999  # the frozen worker/model packet does not alias mutable state
    assert snapshot["compact"]["terrain"]["source"]["observed_at"] == 17.25


def test_existing_result_compaction_preserves_maximum_compact_terrain_and_rare_layers():
    packet = terrain_packet()
    result = {"ok": False, "reason": "timeout", "data": {"terrain": packet, "detail": "partial observation"}}
    before = copy.deepcopy(result)
    assert _model_read_view(result) == before
    retained, = D._result_summaries([{"tool": "terrain", "args": {"mode": "survey"}, "origin": "board", **result}])
    assert retained["data"]["terrain"] == packet and result == before
    assert "data_truncated" not in retained


@pytest.mark.parametrize("entry", [{"kind": "action", "moves": False, "args": {}},
                                   {"kind": "read", "moves": True, "args": {}},
                                   {"kind": "read", "moves": False}])
def test_unverified_terrain_manifest_cannot_be_director_research(entry):
    research = D.Research({"facts": {}, "state": {}}, proxy=D.BodyProxy(lambda *a: pytest.fail("body called")),
                          body_tools={"terrain"}, manifest={"terrain": entry})
    assert "terrain" not in {t["function"]["name"] for t in research.tools()}
    assert research.run("terrain", {})["ok"] is False


def test_absent_cached_terrain_is_not_synthesized():
    assert "terrain" not in D._compact_state({"position": [0, 0, 0]})
    assert "terrain" not in continuation_observation({"position": [0, 0, 0]})

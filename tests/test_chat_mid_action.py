"""A chat line must not derail the running action (co-play retro 2026-11-01, root cause 2).

Live (logs/brain-live-20261101-115554-7128.jsonl): 28 waits came back ``interrupted`` ("the player spoke; the body
may still be doing it"). The model read a failure and re-issued the same go_to, which restarts the trip in the body:
"where are you going?" stopped the walk it asked about (11:20:51), and "claude you aren't moving - why not" came right
after a re-issued go_to (11:25:19). Now:

- the bridge detaches the wait (``still_running``): the model gets the floor at once, the body keeps going;
- body_status shows the action as running (what, for how long, metres to go), never as a failure;
- the same call again re-attaches to the running request (no new command); another action replaces it;
- the result of an action nobody re-attached to or replaced reaches the model as a body_event when it comes.
"""
from __future__ import annotations

import copy

from brain import bridge_client as bc
from brain.controller import Controller
from brain.executor import Executor, same_args
from brain.interface import ChatHeard, fail, ok
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM
from brain.planner import Planner
from brain.run_live import LiveAgent
from brain.state_store import StateStore, Task

from test_event_hygiene import STATES, Clock, FakeModel, ReplayBody

LAKE = [10.0, 20.0, 0.0]


# --------------------------------------------------------------------------- bridge


class Body:
    """A JSONL body stub: answers pings and move_status; holds every action until ``finish`` is called."""

    def __init__(self, move_status=None):
        self.sent, self.push = [], []
        self.malformed: list = []
        self.move_status = move_status or {"mode": "go_to", "dist_m": 41.7, "target_pos": LAKE, "speed_ms": 3.1,
                                           "progress": {"verdict": "ok"}}
        self.on_send = None

    def send(self, msg):
        self.sent.append(msg)
        if msg["tool"] == "ping":
            self.push.append(_result(msg["id"], True, {"pong": True}))
        elif msg["tool"] == "move_status":
            self.push.append(_result(msg["id"], True, self.move_status))
        if self.on_send:
            self.on_send(msg)

    def receive(self, timeout):
        out, self.push = self.push, []
        return out

    def actions(self, tool=None):
        return [m for m in self.sent if m["tool"] not in ("ping", "move_status") and (tool is None or m["tool"] == tool)]

    def finish(self, msg_id, ok_=True, data=None, reason=None, event=True):
        self.push.append(_result(msg_id, ok_, data or {}, reason))
        if event:  # the body's finish() also emits task_done / task_failed for the id
            ev = {"type": "task_done", "task_id": msg_id, "data": data or {}} if ok_ else \
                {"type": "task_failed", "task_id": msg_id, "reason": reason}
            self.push.append({"v": 1, "type": "event", "event": ev})


def _result(msg_id, ok_, data, reason=None):
    return {"v": 1, "type": "result", "id": msg_id, "ok": ok_, "reason": reason, "data": data}


def _chat(text, player="Tester"):
    return {"v": 1, "type": "event", "event": {"type": "chat_heard", "player": player, "text": text}}


def _client(tmp_path, monkeypatch, body):
    monkeypatch.setattr(bc, "HEARTBEAT_S", 0.0)
    monkeypatch.setattr(bc, "DETACH_AFTER_S", 0.0)
    c = bc.BridgeClient(body, JsonlLogger(tmp_path / f"b-{id(body)}.jsonl"))
    c.interrupt_check = lambda ev: isinstance(ev, ChatHeard) and ev.text.startswith("claude")
    return c


def test_a_line_mid_walk_leaves_the_walk_running_and_says_how_far(tmp_path, monkeypatch):
    body = Body()
    body.push.append(_chat("claude where are you going?"))
    c = _client(tmp_path, monkeypatch, body)
    res = c.request("go_to", {"target": LAKE}, timeout=60)
    assert res["reason"] == "still_running" and res["data"]["running"] is True
    assert res["data"]["progress"]["dist_m"] == 41.7 and res["data"]["progress"]["target_pos"] == LAKE
    gid = body.actions("go_to")[0]["id"]
    assert c.abandoned(gid) and [d["id"] for d in c.detached()] == [gid]
    assert [e.text for e in c.poll_events()] == ["claude where are you going?"]  # the line is kept for the agent


def test_the_same_call_reattaches_to_the_running_request_instead_of_restarting_it(tmp_path, monkeypatch):
    body = Body()
    body.push.append(_chat("claude where are you going?"))
    c = _client(tmp_path, monkeypatch, body)
    first = c.request("go_to", {"target": LAKE}, timeout=60)
    gid = first["data"]["id"]
    c.poll_events()
    body.on_send = lambda msg: body.finish(gid, True, {"position": LAKE, "target_position": LAKE}) \
        if msg["tool"] == "ping" else None
    res = c.reattach(gid)
    assert res["ok"] and res["data"]["position"] == LAKE
    assert len(body.actions("go_to")) == 1  # no second go_to went to the body
    assert not c.abandoned(gid) and c.detached() == []
    # its task_done is the re-attached call's own result: not a late report
    assert not any(c.abandoned(getattr(e, "task_id", "")) for e in c.poll_events())
    assert c.reattach(gid) is None  # finished: nothing to re-attach to (the caller sends it again)


def test_the_late_result_of_a_detached_action_is_reported_once_with_its_data(tmp_path, monkeypatch):
    body = Body()
    body.push.append(_chat("claude where are you going?"))
    c = _client(tmp_path, monkeypatch, body)
    gid = c.request("go_to", {"target": LAKE}, timeout=60)["data"]["id"]
    c.poll_events()
    body.finish(gid, False, {"detail": "a cliff 29 m down", "position": [5, 5, 0]}, reason="no_route")
    evs = c.poll_events()
    assert [(e.type, e.task_id, e.reason) for e in evs] == [("task_failed", gid, "no_route")]  # body's dup dropped
    assert c.late_result(gid)["data"]["detail"] == "a cliff 29 m down"
    assert c.abandoned(gid) and c.detached() == []


def test_quick_reads_and_short_waits_never_detach(tmp_path, monkeypatch):
    body = Body()
    c = _client(tmp_path, monkeypatch, body)
    c._events.append(ChatHeard(player="Tester", text="claude hi"))
    body.on_send = lambda msg: body.push.append(_result(msg["id"], True, {"position": [0, 0, 0]})) \
        if msg["tool"] == "get_state" else None
    assert c.request("get_state", {}, timeout=10)["ok"]  # the brain needs it: never left running
    monkeypatch.setattr(bc, "DETACH_AFTER_S", 5.0)  # a 0.2 s go_to answers before a line could detach it
    body.on_send = lambda msg: body.finish(msg["id"], True, {"position": LAKE}, event=False) \
        if msg["tool"] == "go_to" else None
    assert c.request("go_to", {"target": LAKE}, timeout=60)["ok"]


def test_same_args_matches_the_same_call_only():
    assert same_args({"target": [10.0, 20.0, 0.0]}, {"target": [10.4, 20.3, 0.1]})
    assert not same_args({"target": [10.0, 20.0, 0.0]}, {"target": [14.0, 20.0, 0.0]})
    assert same_args({"target": "Forgotten Temple", "tolerance": None}, {"target": "forgotten temple"})
    assert not same_args({"resource": "Ash Logs", "count": 5}, {"resource": "Ash Logs", "count": 3})
    assert not same_args({"target": "a"}, {"target": "a", "secondary": True})


# --------------------------------------------------------------------------- agent (real Controller, Executor, broker)


class DetachBody(ReplayBody):
    """ReplayBody with the bridge's detach API: a scripted ``still_running`` result leaves the action running;
    ``reattach`` returns what ``finish_with`` set for it; ``end`` delivers a late result."""

    def __init__(self, state):
        super().__init__(state)
        self.running: dict[str, dict] = {}  # id -> its result once it finishes (None: still going)
        self.late: dict[str, dict] = {}
        self.left: set[str] = set()

    def _act(self, tool, **args):
        res = super()._act(tool, **args)
        if res.get("reason") == "still_running":
            self.left.add(res["data"]["id"])
            self.running[res["data"]["id"]] = None
        return res

    def reattach(self, request_id):
        self.calls.append(("reattach", {"id": request_id}))
        if request_id not in self.running:
            return None
        self.left.discard(request_id)
        return self.running.pop(request_id) or ok(position=self.state["position"])

    def abandoned(self, request_id):
        return request_id in self.left

    def late_result(self, request_id):
        return self.late.get(request_id)

    def end(self, request_id, result):
        """The detached action finished in the body (nobody waits on it)."""
        self.running.pop(request_id, None)
        self.late[request_id] = result
        ev = {"type": "task_done", "task_id": request_id, "data": result.get("data") or {}} if result["ok"] else \
            {"type": "task_failed", "task_id": request_id, "reason": result["reason"]}
        self.emit(ev)


def _agent(tmp_path):
    clock = Clock()
    state = copy.deepcopy(STATES[5])
    body = DetachBody(state)
    log = JsonlLogger(tmp_path / "logs" / "brain.jsonl")
    store = StateStore(tmp_path / "state")
    model = FakeModel()
    executor = Executor(body, store, log, max_attempts=1)
    controller = Controller(model, body, store, log, name="Claude", player="Zezima",
                            available_tools={"get_state", "follow", "stop", "go_to", "attack", "drop", "say",
                                             "interact", "gather"}, clock=clock)
    agent = LiveAgent(body, controller, Planner(FakeLLM(), store.skills, log), executor, store, log,
                      prefixes=["claude "], calls_per_min=100, debounce_s=0.0, clock=clock)
    agent.broker.clock = clock
    agent.chat.clock = clock
    return agent, body, model, log


def _left_running(state, rid="r1"):
    return fail("still_running", tool="go_to", id=rid, by="chat", running=True, running_s=17.0,
                detail="the player spoke, so you stopped waiting; your body is still doing it",
                progress={"dist_m": 41.7, "target_pos": LAKE})


def test_where_are_you_going_mid_walk_answers_and_the_repeat_reattaches(tmp_path):
    """11:20:51 replayed: "where are you going" mid go_to. The model hears the walk is still running (not failed);
    its repeat of the same go_to watches that walk (no second go_to to the body) and the plan goes on."""
    agent, body, model, log = _agent(tmp_path)
    seen = {}
    model.replies["go to the lake"] = FakeLLM.say("heading over", FakeLLM.call("go_to", target=LAKE))

    def answer(ctx):
        seen["status"] = ctx.get("body_status") or []
        return FakeLLM.say("to the lake, nearly there", FakeLLM.call("go_to", target=LAKE))
    model.replies["where are you going"] = answer
    body.act("go_to", _left_running(body.state), emitted=[{"type": "chat_heard", "player": "Zezima",
                                                            "text": "claude where are you going?"}])
    body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude go to the lake"})
    agent.step()
    agent.step()
    status = " | ".join(seen["status"])
    assert "Still running in your body: go_to" in status and "m to go" in status, status
    assert "FAILED" not in status and "interrupted" not in status, status
    assert [c[0] for c in body.calls] == ["go_to", "reattach"]  # the walk was watched again, never restarted
    assert "to the lake, nearly there" in body.said
    assert agent.broker.running is None and agent.executor.running is None


def test_a_question_only_answered_leaves_the_walk_running_and_its_end_is_reported(tmp_path):
    agent, body, model, log = _agent(tmp_path)
    model.replies["go to the lake"] = FakeLLM.say("heading over", FakeLLM.call("go_to", target=LAKE))
    model.replies["where are you going"] = FakeLLM.say("the lake, nearly there")  # talk only: no action
    events = []
    model.body_reply = lambda ctx: events.append(ctx["body_event"]) or FakeLLM.say("made it")
    body.act("go_to", _left_running(body.state), emitted=[{"type": "chat_heard", "player": "Zezima",
                                                            "text": "claude where are you going?"}])
    body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude go to the lake"})
    agent.step()
    agent.step()
    assert [c[0] for c in body.calls] == ["go_to"]  # nothing replaced or restarted it
    assert "the lake, nearly there" in body.said
    assert agent.broker.running is not None
    body.end("r1", ok(position=LAKE, target_position=LAKE))
    agent.step()
    assert events and events[0]["type"] == "running_action_result" and events[0]["ok"] is True, events
    assert events[0]["tool"] == "go_to"
    assert "made it" in body.said
    digest = " | ".join(agent.broker.digest())
    assert "go_to [10, 20, 0] arrived" in digest, digest  # the walk's episode ended with what really happened


def test_another_action_replaces_the_running_one_and_its_late_interrupt_is_not_news(tmp_path):
    agent, body, model, log = _agent(tmp_path)
    model.replies["go to the lake"] = FakeLLM.say("heading over", FakeLLM.call("go_to", target=LAKE))
    model.replies["stop"] = FakeLLM.say("ok", FakeLLM.call("stop"))
    body.act("go_to", _left_running(body.state), emitted=[{"type": "chat_heard", "player": "Zezima",
                                                            "text": "claude stop"}])
    body.act("stop", ok(stopped="go_to"))
    body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude go to the lake"})
    agent.step()
    agent.step()
    assert [c[0] for c in body.calls] == ["go_to", "stop"]
    body.end("r1", fail("interrupted", by="stop"))  # the body's slot ended it for the stop
    n = len(model.contexts)
    agent.step()
    assert len(model.contexts) == n  # the brain's own stop replaced it: no model call about it
    drops = [r for r in log.read_all() if r["kind"] == "event_dropped" and "replaced with stop" in r.get("why", "")]
    assert drops, "the late interrupt is dropped as the brain's own replacement"


def test_a_goal_task_resumes_by_reattaching(tmp_path):
    """run_goal resumes the same task after the chat: it re-attaches to the walk instead of sending it again."""
    agent, body, model, log = _agent(tmp_path)
    body.act("go_to", _left_running(body.state))
    t = Task(skill="go_to", args={"target": LAKE})
    out = agent._run_task(t)
    assert out.interrupt and out.reason == "still_running"
    assert agent.executor.continues(Task(skill="go_to", args={"target": [10.2, 20.1, 0.0]}))
    out2 = agent._run_task(t)
    assert out2.ok, out2
    assert [c[0] for c in body.calls] == ["go_to", "reattach"]


def test_an_answer_written_as_plain_text_gets_one_turn_to_be_said(tmp_path):
    """11:50:11: "so why couldn't you validate ..." was answered in plain text (a private note), so he heard nothing.
    The model is told once that nobody heard it and decides; code never speaks the note."""
    agent, body, model, log = _agent(tmp_path)
    agent.controller.say_channel = True
    model.replies["why couldnt you"] = FakeLLM.say("fair question. I took the build result at face value")
    model.turns.append(FakeLLM.say("", FakeLLM.call("say", text="fair, I trusted the result and didn't look")))
    body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude so why couldnt you validate it"})
    agent.step()
    assert body.said == ["fair, I trusted the result and didn't look"]
    notes = [m["content"] for c in model.calls for m in c["messages"] if m.get("role") == "user"
             and "Nobody heard that" in str(m.get("content"))]
    assert notes, "the model was told its text was not heard"
    assert not [r for r in log.read_all() if r["kind"] == "reply_silent"]

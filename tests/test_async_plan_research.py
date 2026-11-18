"""The Planner's research (f51fa70) inside a background plan (DW_ASYNC_PLAN, 8abcf32).

Live 2026-11-18 (Luis: "haiku can be busy with the start whilst sonnet is asynchronously planning all the steps in the
bg"). The research loop runs unchanged inside the worker's Planner call; what it may not do is talk to the body
itself (the bridge has one owner, the agent loop). Its body reads (craft_plan, buildables) queue on a BodyProxy and
were answered only in Agent.pump, so a read queued while Haiku's first step ran waited 20 s and came back "the body
is busy right now; plan without it", which was not what happened. Now the loop serves the queue between his calls
and inside every body wait, a read it never reached is answered at once with what held the loop (never sent), a
read it did send is waited for, and the worker gets private copies of its inputs.
"""
from __future__ import annotations

import json
import threading
import time

from conftest import Rig

from brain import plan_async
from brain.bridge_client import WAIT_HOOK_POLL_S, BridgeClient
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM, LLMResponse
from brain.protocol import result as wire_result
from brain.tool_registry import BodyProxy, planner_research
from brain.transport import Transport

PLAN = [{"skill": "gather", "args": {"resource": "log", "count": 2}},
        {"skill": "go_to", "args": {"target": "Luis"}},
        {"skill": "give", "args": {"player": "Luis", "item": "log", "count": 2}}]
CRAFT_PLAN = {"craft_plan": {"kind": "read", "moves": False, "description": "The recipe tree of an item.",
                             "args": {"type": "object", "properties": {"item": {"type": "string"}},
                                      "required": ["item"]}}}


def _rows(log, kind: str) -> list[dict]:
    return [r for r in log.read_all() if r["kind"] == kind]


def _wait(pred, s: float = 5.0) -> bool:
    end = time.monotonic() + s
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.01)
    return False


# ------------------------------------------------------------------ the agent: research inside the background plan


def test_a_background_plans_body_read_is_answered_between_his_calls_not_after_his_turn(tmp_path, monkeypatch):
    monkeypatch.setenv(plan_async.ENV, "1")
    rig = Rig(tmp_path)
    reads: list[tuple] = []

    def body(tool, args):
        reads.append((tool, dict(args), threading.get_ident()))
        return {"ok": True, "reason": None, "data": {"item": args.get("item"), "steps": ["Bone Pickaxe at a table"]}}

    proxy = BodyProxy(body, timeout_s=5, log=rig.log, label="planner")
    rig.agent.planner_proxy = proxy
    rig.planner.research = planner_research(None, proxy, set(CRAFT_PLAN), CRAFT_PLAN)
    rig.planner_llm.push(FakeLLM.say("", FakeLLM.call("craft_plan", item="Bone Pickaxe")), FakeLLM.plan(PLAN))
    rig.game.player_say("get me 2 logs")
    rig.controller_llm.push(FakeLLM.say("On it.", FakeLLM.call("start_goal", goal="gather 2 logs and give them to Luis")))
    seen = {}

    def first_step(messages, tools):  # Haiku's start of the job, while the Planner researches
        assert _wait(lambda: proxy.q.qsize() > 0), "the Planner never asked the body"
        seen["unanswered_at_his_call"] = not reads
        return FakeLLM.say("", FakeLLM.call("go_to", target="Luis"))

    def next_call(messages, tools):
        seen["answered_before_his_next_call"] = bool(reads)  # served between his calls, not after his turn
        return LLMResponse(content="")

    rig.controller_llm.push(first_step, next_call)
    assert rig.agent.step() == "done"
    assert seen == {"unanswered_at_his_call": True, "answered_before_his_next_call": True}
    assert reads == [("craft_plan", {"item": "Bone Pickaxe"}, threading.get_ident())]  # on the loop thread
    (row,) = _rows(rig.log, "body_read_queued")
    assert (row["component"], row["tool"], row["served_in"], row["answered"]) == ("planner", "craft_plan", "turn", True)
    (research,) = _rows(rig.log, "planner_research")
    assert "Bone Pickaxe at a table" in research["result"] and "busy" not in research["result"]
    (arrived,) = _rows(rig.log, "plan_arrived")
    assert arrived["applied"] is True and arrived["steps"] == 3
    assert rig.game.players["Luis"].inventory["log"] == 2


def test_the_worker_plans_on_private_copies_of_state_and_tree(tmp_path, monkeypatch):
    monkeypatch.setenv(plan_async.ENV, "1")
    rig = Rig(tmp_path)
    got = {}
    real_plan = rig.planner.plan

    def plan(goal, state, notes):
        got["state"], got["thread"] = state, threading.get_ident()
        return real_plan(goal, state, notes)

    rig.planner.plan = plan
    states = []
    real_state = rig.executor.state

    def state(*a, **kw):  # every state object the loop holds (the executor caches and re-serves them)
        s = real_state(*a, **kw)
        states.append(s)
        return s

    rig.executor.state = state
    rig.planner_llm.push(FakeLLM.plan(PLAN))
    rig.game.player_say("get me 2 logs")
    rig.controller_llm.push(FakeLLM.say("On it.", FakeLLM.call("start_goal", goal="gather 2 logs and give them to Luis")),
                            LLMResponse(content=""))
    assert rig.agent.step() == "done"
    assert got["thread"] != threading.get_ident()
    nested = [(k, v) for s in states for k, v in s.items() if isinstance(v, (dict, list)) and v]
    assert nested  # the test means something: the loop's states have nested parts
    assert all(got["state"].get(k) is not v for k, v in nested)  # none shared with the worker


# ------------------------------------------------------------------ BodyProxy: honest, never a long block


def test_a_read_the_loop_never_reached_says_what_held_it_and_was_not_sent(tmp_path):
    log = JsonlLogger(tmp_path / "b.jsonl")
    sent = []
    proxy = BodyProxy(lambda t, a: sent.append(t) or {"ok": True}, timeout_s=0.2, log=log, label="planner",
                      holder=lambda: "your Controller's model call, 3.0 s so far")
    out = {}
    t = threading.Thread(target=lambda: out.update(res=proxy.request("craft_plan", {"item": "Bone Pickaxe"})))
    t0 = time.monotonic()
    t.start()
    t.join(5)
    assert time.monotonic() - t0 < 2  # answered at its wait, never a 20 s block
    res = out["res"]
    assert res["ok"] is False and res["reason"] == "busy" and res["data"]["read_sent"] is False
    assert "your Controller's model call" in res["data"]["detail"] and "nothing was asked of the body" in res["data"]["detail"]
    assert res["data"]["busy_with"] == "your Controller's model call, 3.0 s so far"
    proxy.serve()  # the loop comes back: the cancelled read is not sent after its answer
    assert sent == []
    (row,) = _rows(log, "body_read_queued")
    assert row["answered"] is False and row["served_in"] is None and row["busy_with"].startswith("your Controller")


def test_a_read_already_sent_is_waited_for_never_dropped_as_busy():
    gate = threading.Event()

    def slow_body(tool, args):
        gate.wait(5)
        return {"ok": True, "data": {"tree": "x"}}

    proxy = BodyProxy(slow_body, timeout_s=0.2)
    out = {}
    t = threading.Thread(target=lambda: out.update(res=proxy.request("craft_plan", {"item": "x"})))
    t.start()
    assert _wait(lambda: proxy.q.qsize() > 0)
    timer = threading.Timer(0.5, gate.set)  # the body answers after the worker's wait has run out
    timer.start()
    proxy.serve("body_wait")
    t.join(5)
    assert out["res"] == {"ok": True, "data": {"tree": "x"}}


def test_serve_is_never_reentered_from_a_reads_own_body_wait():
    calls = []
    proxy = BodyProxy(lambda t, a: (calls.append(t), proxy.serve("body_wait"), {"ok": True})[2], timeout_s=2)
    outs = []
    threads = [threading.Thread(target=lambda: outs.append(proxy.request("craft_plan", {}))) for _ in range(2)]
    for t in threads:
        t.start()
    assert _wait(lambda: proxy.q.qsize() == 2)
    proxy.serve()
    for t in threads:
        t.join(5)
    assert calls == ["craft_plan", "craft_plan"] and outs == [{"ok": True}, {"ok": True}]


# ------------------------------------------------------------------ the bridge serves queued reads while it waits


class ReplyLater(Transport):
    """Answers every command after ``delay_s`` (a body still walking for the Controller's go_to)."""

    def __init__(self, delay_s: float):
        self.delay_s = delay_s
        self.due: list[tuple[float, dict]] = []
        self.sent: list[dict] = []

    def send(self, msg: dict) -> None:
        self.sent.append(msg)
        delay = 0.05 if msg["tool"] == "craft_plan" else self.delay_s
        self.due.append((time.monotonic() + delay, wire_result(msg["id"], {"ok": True, "data": {"tool": msg["tool"]}})))

    def receive(self, timeout: float = 0.0) -> list[dict]:
        end = time.monotonic() + timeout
        while True:
            now = time.monotonic()
            ready = [m for t, m in self.due if t <= now]
            if ready:
                self.due = [(t, m) for t, m in self.due if t > now]
                return ready
            if now >= end:
                return []
            time.sleep(0.01)


def test_wait_hooks_answer_a_queued_read_during_a_long_body_wait(tmp_path):
    transport = ReplyLater(delay_s=1.0)
    client = BridgeClient(transport, JsonlLogger(tmp_path / "b.jsonl"), default_timeout=4.0)
    proxy = BodyProxy(client.request, timeout_s=3)
    client.wait_hooks.append(lambda: proxy.serve("body_wait"))
    out = {}
    worker = threading.Thread(target=lambda: out.update(res=proxy.request("craft_plan", {"item": "Bone Pickaxe"})))
    worker.start()
    assert _wait(lambda: proxy.q.qsize() > 0)
    res = client.request("go_to", {"target": "Luis"})  # the Controller's own walk, on the loop thread
    worker.join(5)
    assert res["ok"] is True and res["data"] == {"tool": "go_to"}
    assert out["res"]["ok"] is True and out["res"]["data"] == {"tool": "craft_plan"}
    assert [m["tool"] for m in transport.sent][:2] == ["go_to", "craft_plan"]  # sent during the go_to's wait


def test_without_wait_hooks_a_body_wait_is_unchanged(tmp_path):
    """Flag off (run_live adds the hook only under DW_ASYNC_PLAN=1): no hook, the wait is one receive to the reply."""
    transport = ReplyLater(delay_s=3 * WAIT_HOOK_POLL_S)
    client = BridgeClient(transport, JsonlLogger(tmp_path / "b.jsonl"), default_timeout=4.0)
    seen = []
    real = transport.receive
    transport.receive = lambda timeout=0.0: (seen.append(timeout), real(timeout))[1]
    assert client.wait_hooks == [] and client.request("go_to", {"target": "Luis"})["ok"] is True
    assert seen and seen[0] > 1.0  # not cut to the hook's poll


# ------------------------------------------------------------------ the knowledge index under two threads


def test_knowledge_kinds_and_meta_take_the_lock(tmp_path):
    from test_knowledge import make_data, make_wiki
    from brain.knowledge import Knowledge
    k = Knowledge(data=make_data(tmp_path / "data"), wiki=make_wiki(tmp_path / "wiki"))
    held = []

    class Recording:
        def __init__(self, inner):
            self.inner = inner

        def __enter__(self):
            held.append(True)
            return self.inner.__enter__()

        def __exit__(self, *a):
            return self.inner.__exit__(*a)

    k._lock = Recording(k._lock)
    k.kinds()
    assert held, "kinds() read the shared connection without the lock"
    held.clear()
    k.stats()
    assert len(held) >= 2  # the kinds count and each meta read
    errors = []

    def hammer(fn):
        try:
            for _ in range(50):
                fn()
        except Exception as exc:  # noqa: BLE001 - any error is the finding
            errors.append(repr(exc))

    threads = [threading.Thread(target=hammer, args=(f,)) for f in (k.kinds, lambda: k.lookup("glowcap"), k.stats)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    assert errors == []
    assert json.dumps(k.lookup("glowcap"))  # still answers

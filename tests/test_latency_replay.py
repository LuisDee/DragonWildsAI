"""Speed plan §2 (docs/design/autonomy-plan.md): chat line -> first response, BEFORE vs AFTER, on a replay.

The 42 real chat lines of 20:40-21:03 (tests/fixtures/chat_2026-10-25_2040.json, from
logs/brain-live-20261025-214057-8860.jsonl) are fed through the REAL LiveAgent / Controller /
Executor / broker on a virtual clock. Each model call costs the measured Haiku p50 (1.9 s) and each
get_state the measured round trip (0.25 s). A line the live brain answered with an action gets an
action again (a go_to); the others a spoken line. The measure is chat_heard -> the first `say` or
action start.

BEFORE = the 21:04 brain: 2.0 s burst window, unnamed lines unaddressed, no state reuse.
AFTER  = now: 0.8 s window, the player he is with counts as addressed, one state read per turn.
Effort "low" (fewer thinking tokens per call) is NOT measured offline: "after_effort_low" is a
PROJECTION with the model call at 1.2 s (live: ~170 of ~266 completion tokens per call were thinking).
Measure it live with tools/turn_latency.py after the restart.
"""
import copy
import json
import statistics
from pathlib import Path

import pytest

from brain import executor as executor_mod
from brain.interface import ok
from brain.llm import FakeLLM, LLMResponse
from brain.run_live import LiveAgent
from test_event_hygiene import STATES, FakeModel, Replay, ReplayBody

LINES = json.loads((Path(__file__).parent / "fixtures" / "chat_2026-10-25_2040.json").read_text(encoding="utf-8"))["lines"]
MODEL_S, READ_S, ACTION_S = 1.9, 0.25, 2.0


class TimedBody(ReplayBody):
    def __init__(self, state, clock):
        super().__init__(state)
        self.clock = clock
        self.responses: list[float] = []

    def get_state(self):
        self.clock.t += READ_S
        return super().get_state()

    def say(self, text):
        self.responses.append(self.clock.t)
        return super().say(text)

    def go_to(self, target):
        self.responses.append(self.clock.t)
        self.clock.t += ACTION_S
        return ok(target=target, dist_m=1.2)


class TimedModel(FakeModel):
    def __init__(self, clock):
        super().__init__()
        self.clock = clock
        self.acted: set[str] = set()

    model_s = MODEL_S
    cold_s = 0.0  # extra cost of the session's first call (L27: litellm import + TLS + first cache write)

    def complete(self, messages, tools=None):
        self.clock.t += self.model_s + self.cold_s
        self.cold_s = 0.0
        last = messages[-1]
        if last.get("role") == "tool" or (last.get("role") == "user" and not last["content"].startswith("{")):
            self.calls.append({"messages": messages, "tools": tools})
            return LLMResponse(content="")
        ctx = json.loads(messages[1]["content"])
        self.calls.append({"messages": messages, "tools": tools})
        text = ctx["command"]["text"]
        if not text:
            return LLMResponse(content="")
        if any(t in text for t in self.acted):
            return FakeLLM.say("On my way.", FakeLLM.call("go_to", target="Zezima"))
        return LLMResponse(content="Sure.")


def simulate(tmp_path, before: bool, monkeypatch, model_s: float = MODEL_S, cold_s: float = 0.0,
             warm: bool = False) -> list[float]:
    r = Replay(tmp_path, copy.deepcopy(STATES[5]))
    state = copy.deepcopy(STATES[5])
    state["players"] = [{"name": "Zezima", "distance": 4.0, "position": [59.26, 1881.85, -35.45]}]
    r.body = TimedBody(state, r.clock)
    r.model = TimedModel(r.clock)
    r.model.model_s = model_s
    r.model.cold_s = cold_s
    if warm:  # session start (before the first line): the warm-up call pays the cold start (L27)
        r.model.complete([{"role": "system", "content": ""}, {"role": "user", "content": "warm-up"}])
    r.model.acted = {ln["text"] for ln in LINES if ln["acted"]}
    r.executor.game = r.body
    r.executor.max_attempts = 3 if before else 1
    r.controller.llm, r.controller.game = r.model, r.body
    agent = LiveAgent(r.body, r.controller, r.agent.planner, r.executor, r.store, r.log, prefixes=["claude "],
                      calls_per_min=100, debounce_s=2.0 if before else 0.8, clock=r.clock)
    agent.broker.clock = r.clock
    agent.chat.clock = r.clock
    agent.check_promises = not before
    if before:
        monkeypatch.setattr(executor_mod, "STATE_REUSE_S", -1.0)  # no reuse: every read is a round trip
        monkeypatch.setattr(LiveAgent, "_with", lambda self, player: None)  # unnamed lines wait for the burst
    lat = []
    start = r.clock.t
    for ln in LINES:
        r.clock.t = max(r.clock.t, start + ln["t"])
        t_heard = r.clock.t
        n = len(r.body.responses)
        text = ("claude " + ln["text"]) if ln["mentions_me"] else ln["text"]
        r.body.emit({"type": "chat_heard", "player": ln["player"], "text": text})
        for _ in range(400):  # step the loop in 0.1 s ticks until something is said or started
            agent.step()
            if len(r.body.responses) > n:
                break
            r.clock.t += 0.1
        if len(r.body.responses) > n:
            lat.append(r.body.responses[n] - t_heard)
    return lat


def pct(xs, p):
    xs = sorted(xs)
    return xs[max(0, min(len(xs) - 1, round(p / 100 * (len(xs) - 1))))]


def test_chat_to_first_response_before_and_after(tmp_path, monkeypatch, capsys):
    after = simulate(tmp_path / "after", False, monkeypatch)
    projected = simulate(tmp_path / "after_low", False, monkeypatch, model_s=1.2)
    with monkeypatch.context() as m:
        before = simulate(tmp_path / "before", True, m)
    report = {k: {"n": len(v), "p50_s": round(pct(v, 50), 2), "p90_s": round(pct(v, 90), 2),
                  "mean_s": round(statistics.mean(v), 2)}
              for k, v in (("before", before), ("after", after), ("after_effort_low_projection", projected))}
    with capsys.disabled():
        print("\nlatency replay (virtual clock, Haiku 1.9 s/call, get_state 0.25 s):", json.dumps(report))
    assert len(after) >= 35 and len(before) >= 35
    # with the model at 1.9 s the floor is 0.8 s window + 0.25 s read + 1.9 s = ~3 s; the 2.5 s target
    # (speed plan §2.1) needs the cheaper model call (effort low), projected here, measured live
    assert report["after"]["p50_s"] <= report["before"]["p50_s"] - 1.0
    assert report["after"]["p50_s"] <= 3.1
    assert report["after_effort_low_projection"]["p50_s"] <= 2.5


COLD_S = 9.5  # live dev run 23:32:58: 11.2 s first call vs ~1.7 s warm (litellm import ~5 s, TLS, cache write)


def test_l27_cold_start_before_and_after_the_warm_up(tmp_path, monkeypatch, capsys):
    """BUGS.md L27: the worst chat -> first action (12.8 s) was the session's first model call. With the
    warm-up at session start the first line costs what every other line costs."""
    cold = simulate(tmp_path / "cold", False, monkeypatch, cold_s=COLD_S)
    warm = simulate(tmp_path / "warm", False, monkeypatch, cold_s=COLD_S, warm=True)
    report = {k: {"first_s": round(v[0], 2), "p50_s": round(pct(v, 50), 2), "p90_s": round(pct(v, 90), 2),
                  "max_s": round(max(v), 2)} for k, v in (("cold_start", cold), ("warmed_up", warm))}
    with capsys.disabled():
        print("\nL27 replay (first line of a fresh session):", json.dumps(report))
    assert report["cold_start"]["first_s"] > 10 and report["warmed_up"]["first_s"] < 3.5
    assert report["warmed_up"]["max_s"] < 4.0  # M1: p90 <= 4 s

"""Event hygiene, single voice, grounding as information, episodic memory (streamline plan steps 3+4).

The replay tests drive the REAL Agent/LiveAgent, Controller, Executor and EventBroker with the event
sequence and get_state snapshots recorded live on 2026-10-25 19:21-19:25 UTC
(tests/fixtures/episode_2026-10-25_1921.json, from logs/brain-live-20261025-194540-4808.jsonl).
The "model" is a deterministic fake: these tests check what the code does around the model (what
reaches it, what is dropped, what is said), not what a real model would choose.
"""
import copy
import json
from pathlib import Path

import pytest

from brain import grounding
from brain import situation as sit
from brain.broker import EventBroker, facts, fallback_line
from brain.controller import Controller
from brain.executor import Executor
from brain.interface import (Activity, GameInterface, Resumed, Unreachable, VitalsLow, fail, ok, parse_event)
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM, LLMResponse, ToolCall
from brain.planner import Planner
from brain.run_live import LiveAgent
from brain.state_store import StateStore
from brain.voice import Voice

FIX = json.loads((Path(__file__).parent / "fixtures" / "episode_2026-10-25_1921.json").read_text(encoding="utf-8"))
STATES = [s["state"] for s in FIX["states"]]  # 0: 19:22:34 far; 1: 19:23:05 next to him; 2: 19:23:39 far
EVENTS = [e["event"] for e in FIX["events"]]  # 3: 19:24:50 next to him, 23 sandwiches; 4/5: 19:24:59/19:25:16
INFUSION = next(i["id"] for i in STATES[5]["nearby_items"] if i["name"] == "Pumpkin Spice Infusion")


def events_between(lo: float, hi: float) -> list[dict]:
    return [copy.deepcopy(e["event"]) for e in FIX["events"] if lo <= e["ts"] < hi]


class Clock:
    def __init__(self, t: float = 1000.0):
        self.t = t

    def __call__(self) -> float:
        return self.t


class ReplayBody(GameInterface):
    """Serves recorded get_state snapshots and events. An action returns its scripted result after
    queueing the events the real body emitted WHILE it ran (the live go_to blocked for 71 s)."""

    def __init__(self, state: dict):
        self.state = copy.deepcopy(state)
        self.queue: list[dict] = []
        self.said: list[str] = []
        self.calls: list[tuple[str, dict]] = []
        self.timeline: list[tuple[str, str]] = []  # ("say", text) / ("call", tool), in order
        self.script: dict[str, list[tuple[dict, list[dict], dict | None]]] = {}

    def emit(self, *events: dict) -> None:
        self.queue.extend(copy.deepcopy(list(events)))

    def act(self, tool: str, result: dict, emitted: list[dict] = (), state_after: dict | None = None) -> None:
        self.script.setdefault(tool, []).append((result, list(emitted), state_after))

    def _act(self, tool: str, **args) -> dict:
        self.calls.append((tool, args))
        self.timeline.append(("call", tool))
        if not self.script.get(tool):
            return fail("not_implemented", tool=tool)
        res, emitted, after = self.script[tool].pop(0)
        self.queue.extend(copy.deepcopy(emitted))
        if after is not None:
            self.state = copy.deepcopy(after)
        return res

    def get_state(self):
        return ok(**copy.deepcopy(self.state))

    def poll_events(self):
        q, self.queue = self.queue, []
        return [parse_event(e) for e in q]

    def say(self, text):
        self.said.append(text)
        self.timeline.append(("say", text))
        return ok()

    def cast(self, spell, target=None):
        return self._act("cast", spell=spell)

    look_things: list | None = None

    def look(self, about=None, radius=20.0, max=15):
        if self.look_things is None:
            return fail("not_implemented", tool="look")
        return ok(about=about, things=self.look_things)

    def follow(self, player, distance=3.0):
        return self._act("follow", player=player, distance=distance)

    def stop(self):
        return self._act("stop")

    def go_to(self, target):
        return self._act("go_to", target=target)

    def attack(self, target):
        return self._act("attack", target=target)

    def gather(self, resource, count, radius=None):
        return self._act("gather", resource=resource, count=count)

    def craft(self, item, count=1):
        return self._act("craft", item=item, count=count)

    def place(self, blueprint, location):
        return self._act("place", blueprint=blueprint, location=location)

    def give(self, player, item, count):
        return self._act("give", player=player, item=item, count=count)

    def pickup(self, target, item=None, limit=1):
        return self._act("pickup", target=target, item=item, limit=limit)

    def drop(self, item, count, at="feet"):
        return self._act("drop", item=item, count=count)

    def interact(self, target, secondary=False):
        return self._act("interact", target=target)


class FakeModel(FakeLLM):
    """A deterministic stand-in for the Controller model. It records every context it is given;
    body-initiated runs get a line naming the event types; chat runs get ``replies[text]`` (a
    response or a callable ctx -> response), else a short generic reply."""

    def __init__(self):
        super().__init__(model="fake/replay")
        self.contexts: list[dict] = []
        self.replies: dict[str, object] = {}
        self.body_reply = None  # callable ctx -> response for body-initiated runs
        self.turns: list = []  # scripted responses for the agent loop's continuation turns

    def complete(self, messages, tools=None):
        self.calls.append({"messages": messages, "tools": tools})
        last = messages[-1]
        if last.get("role") == "tool" or (last.get("role") == "user" and not last["content"].startswith("{")):
            # a continuation / follow-up turn: the next scripted one, else nothing more to say
            return self.turns.pop(0) if self.turns else LLMResponse(content="")
        ctx = json.loads(messages[1]["content"])
        self.contexts.append(ctx)
        text = ctx["command"]["text"]
        if ctx.get("body_event") and not text:
            if self.body_reply:
                return self.body_reply(ctx)
            evs = ctx["body_event"].get("events") or [ctx["body_event"]]
            return LLMResponse(content="(model) about " + ", ".join(
                f"{e['type']} {e.get('stat') or e.get('reason') or ''}".strip() for e in evs))
        for key, reply in self.replies.items():
            if key in text:
                return reply(ctx) if callable(reply) else reply
        return LLMResponse(content=f"(model) reply #{len(self.contexts)}")


class Replay:
    def __init__(self, tmp_path, state: dict, tools: set[str] | None = None):
        self.clock = Clock()
        self.body = ReplayBody(state)
        self.log = JsonlLogger(tmp_path / "logs" / "brain.jsonl")
        self.store = StateStore(tmp_path / "state")
        self.model = FakeModel()
        self.executor = Executor(self.body, self.store, self.log, max_attempts=1)
        self.controller = Controller(self.model, self.body, self.store, self.log, name="Claude", player="Zezima",
                                     available_tools=tools or {"get_state", "follow", "stop", "go_to", "attack",
                                                               "drop", "say", "interact"},
                                     clock=self.clock)
        self.agent = LiveAgent(self.body, self.controller, Planner(FakeLLM(), self.store.skills, self.log),
                               self.executor, self.store, self.log, prefixes=["claude "], calls_per_min=100,
                               debounce_s=2.0, clock=self.clock)
        self.agent.broker.clock = self.clock
        self.agent.chat.clock = self.clock

    def at(self, t: float) -> "Replay":
        self.clock.t = 1000.0 + t
        return self

    def step(self):
        self.agent.step()

    def records(self, kind: str) -> list[dict]:
        return [r for r in self.log.read_all() if r["kind"] == kind]


def go_to_ok(state: dict) -> dict:
    return ok(position=state["position"], dist_m=1.4, target="Zezima")


# --------------------------------------------------------------------------- the 19:21-19:25 replay


def test_replay_1921_no_stale_contradictory_or_duplicate_lines(tmp_path):
    r = Replay(tmp_path, STATES[0])
    T0 = FIX["events"][0]["ts"]
    batches = []  # (label, lines said in that step)

    def run(label: str, events: list[dict], dt: float, *extra_steps: float):
        n = len(r.body.said)
        r.body.emit(*events)
        r.at(dt).step()
        for later in extra_steps:  # let the chat burst go quiet, then the run happens
            r.at(later).step()
        batches.append((label, r.body.said[n:]))

    # 19:21:27 hydration low, nothing to drink, Zezima 37 m away: ONE model-phrased line
    run("thirsty", events_between(T0, T0 + 1), 0)
    # 19:22:21 a walk the BRAIN didn't start (main's leg to the grave, 357 m, not a player): not voiced
    run("main's leg", events_between(T0 + 50, T0 + 60), 54)
    digest = r.agent.broker.digest()
    assert any("not a player" in line and "357" in line for line in digest), digest
    # 19:22:32-39 three chat lines in 7 s: one controller run with all three
    run("why stuck", events_between(T0 + 60, T0 + 80), 72.5, 75.0)
    # 19:22:50 another of main's legs (target 26 m from Zezima): not voiced
    run("main's 2nd leg", events_between(T0 + 80, T0 + 85), 83.8)
    # 19:22:56-19:23:09 "dwcome to me" / "come to me now": the brain's go_to arrives next to him
    r.body.act("go_to", go_to_ok(STATES[1]), state_after=STATES[1])
    r.model.replies["come to me"] = FakeLLM.say("", FakeLLM.call("go_to", target="Zezima"))
    run("come to me", events_between(T0 + 85, T0 + 100), 90, 93)
    # 19:23:19-35 "dsgrab those" / "sonon the floor near me" + main's leg again, while he walks back
    r.body.state = copy.deepcopy(STATES[2])
    run("dsgrab", events_between(T0 + 110, T0 + 128), 121, 124)
    # 19:23:35 "come to me grab these infr0ont of me": go_to blocks 71 s; the body queues its retries'
    # task_failed/unreachable, main's other leg, chat, two vitals_low and task_done meanwhile
    during = events_between(T0 + 200, T0 + 205)
    r.body.act("go_to", go_to_ok(STATES[3]), emitted=during, state_after=STATES[3])
    r.body.act("go_to", go_to_ok(STATES[3]))  # "find a path and come to me": already there
    run("come grab", events_between(T0 + 128, T0 + 129), 128.5, 131, 205, 208)

    said = r.body.said
    # no stale movement complaints at all: every unreachable was someone else's walk or had arrived
    sent = [c.get("body_event") for c in r.model.contexts if c.get("body_event")]
    kinds = [e["type"] for b in sent for e in (b.get("events") or [b])]
    assert "unreachable" not in kinds, sent
    # sustenance: he carried 23 sandwiches by then (the stay-fed reflex eats them): never sent
    assert not any(e.get("stat") == "sustenance" for b in sent for e in (b.get("events") or [b]))
    # at most ONE line per batch, and no line twice
    assert all(len(lines) <= 1 for _, lines in batches), batches
    assert len(said) == len(set(said)), said
    # the 19:24:50 batch: hydration rode along in the chat run (one line covers both)
    last = r.model.contexts[-1]
    assert last["command"]["text"] == ("come to me this way / path to me- figure out the path / theres food and "
                                       "water infront of my character / find a path and come to me")
    assert last["body_event"]["type"] == "vitals_low" and last["body_event"]["stat"] == "hydration"
    assert any("Last move: go_to Zezima arrived" in line for line in last["body_status"])
    # what was dropped, and why, is in the log
    whys = [x["why"] for x in r.records("event_triage") if x["verdict"] == "drop"] + \
        [x["why"] for x in r.records("event_dropped")]
    assert any("arrived" in w or "next to Zezima" in w for w in whys), whys
    assert any("carries Forager's Sandwich" in w for w in whys), whys
    assert any("synchronous" in w for w in whys), whys


def test_replay_burst_is_one_run_with_every_line(tmp_path):
    r = Replay(tmp_path, STATES[0])
    T0 = FIX["events"][0]["ts"]
    r.body.emit(*events_between(T0 + 60, T0 + 80))
    r.at(72.5).step()
    assert not r.model.contexts  # still typing (2 s quiet not reached)
    r.at(75).step()
    assert [c["command"]["text"] for c in r.model.contexts] == [
        "sure - why are you stuck ? / can you not plan a route to me / What is blocking you"]


# --------------------------------------------------------------------------- grounding (information only)


def test_drink_the_pumkin_spice_infusuion_resolves_to_the_infusion(tmp_path):
    """19:25:14-17 "drink the pumkin spice infusuion" / "thats drink" / "smh": one run; the typos are
    resolved to the perceived Pumpkin Spice Infusion and handed to the model as references (ids); the
    model's call reaches the body unchanged; nothing is ever said back from "smh"."""
    r = Replay(tmp_path, STATES[5], tools={"get_state", "say", "follow", "go_to", "stop", "interact"})
    r.body.act("interact", ok(target=INFUSION))

    def model(ctx):  # a model that uses the references it was given
        ref = next(x for x in ctx["references"] if "infusion" in (x.get("read_as") or x["said"]))
        return FakeLLM.say("Drinking it now.", FakeLLM.call("interact", target=ref["matches"][0]["id"]))
    r.model.replies["pumkin"] = model
    T0 = FIX["events"][0]["ts"]
    r.body.emit(*events_between(T0 + 227, T0 + 232))
    r.at(231.5).step()
    r.at(234).step()
    ctx = r.model.contexts[-1]
    assert ctx["command"]["text"] == "drink the pumkin spice infusuion / thats drink / smh"
    refs = {x["said"]: x for x in ctx["references"]}
    assert refs["pumkin"]["read_as"] == "pumpkin" and refs["infusuion"]["read_as"] == "infusion"
    assert refs["infusuion"]["matches"][0] == {"name": "Pumpkin Spice Infusion", "id": INFUSION, "kind": "item",
                                              "distance_m": 1.8}
    assert "smh" not in refs and "thats" not in refs
    assert r.body.calls == [("interact", {"target": INFUSION})]
    assert r.body.said == ["Drinking it now."]
    assert not any("smh" in s or "can't see any" in s for s in r.body.said)


def test_food_and_water_in_front_of_me_the_model_sees_both_with_ids(tmp_path):
    """19:24:14 "theres food and water infront of my character": no word table maps food/water; the
    model gets the sandwich and the infusion in situation (with ids) and the line itself, and decides.
    Its choice (here: the infusion) reaches the body unchanged."""
    r = Replay(tmp_path, STATES[3], tools={"get_state", "say", "follow", "go_to", "stop", "interact"})
    r.body.act("interact", ok(target=INFUSION))
    r.model.replies["food and water"] = FakeLLM.say("Grabbing the drink first.", FakeLLM.call("interact", target=INFUSION))
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "theres food and water infront of my character"})
    r.at(0).step()
    r.at(3).step()
    ctx = r.model.contexts[-1]
    ground = next(line for line in ctx["situation"] if line.startswith("On the ground:"))
    assert "Forager's Sandwich" in ground and "Pumpkin Spice Infusion" in ground and INFUSION in ground
    assert r.body.calls == [("interact", {"target": INFUSION})] and r.body.said == ["Grabbing the drink first."]


@pytest.mark.parametrize("line", ["dsgrab those", "look on the floor then", "smh", "find a path and come to me",
                                  "sonon the floor near me", "what is blocking you", "come to me grab these infr0ont of me"])
def test_words_that_match_nothing_perceived_are_never_references(line):
    things = sit.perceived(STATES[5])
    assert grounding.read(line, things, exclude=["Zezima", "Claude"]).refs == []


def test_typos_resolve_and_false_friends_dont():
    things = sit.perceived(STATES[3])
    r = grounding.read("have you got the sandwhiches i dropped those too", things)
    assert [(x.said, x.word) for x in r.refs] == [("sandwhiches", "sandwich")]
    assert grounding.similar("pumkin", "pumpkin") and grounding.similar("infusuion", "infusion")
    assert not grounding.similar("what", "wheat") and not grounding.similar("bring", "ring")
    assert not grounding.similar("sonon", "onion")
    assert grounding.read("Zezima wants it", things, exclude=["Zezima"]).refs == []


# --------------------------------------------------------------------------- broker units


def _state(dist: float, hyd: float = 50.0, carried=()) -> dict:
    return {"position": [0, 0, 0], "hydration": hyd, "hydration_max": 75.0, "sustenance": 50.0, "sustenance_max": 75.0,
            "players": [{"name": "Zezima", "distance": dist, "position": [dist, 0, 0]}],
            "inventory_items": [{"name": n, "consumable": k, "count": 1} for n, k in carried]}


def test_unreachable_next_to_the_player_is_stale():
    b = EventBroker()
    b.action_started("follow", {"player": "Zezima"})
    v = b.assess(Unreachable(reason="no_route", leader_pos=[3, 0, 0], mode="follow"), _state(3))
    assert v.action == "drop" and "next to Zezima" in v.why


def test_unreachable_of_a_move_that_arrived_is_stale():
    b = EventBroker()
    b.action_started("go_to", {"target": "Zezima"})
    b.action_finished("go_to", {"target": "Zezima"}, True)
    v = b.assess(Unreachable(reason="leader_above_jump_height", leader_pos=[30, 0, 0], mode="go_to"), _state(30))
    assert v.action == "drop" and "arrived" in v.why


def test_unreachable_while_following_is_voiced_once_per_episode_and_reason():
    clock = Clock()
    b = EventBroker(clock=clock)
    b.action_started("follow", {"player": "Zezima"})
    ev = Unreachable(reason="leader_windstepped", leader_pos=[40, 0, 0], mode="follow")
    v = b.assess(ev, _state(40))
    assert v.action == "decide" and v.event["about"] == "player" and v.event["target"] == "Zezima"
    b.voiced([v.event])
    assert b.assess(ev, _state(40)).action == "drop"
    clock.t += 1
    r = b.assess(Resumed(), _state(5))
    assert r.action == "decide" and r.event["type"] == "resumed"
    assert b.assess(Resumed(), _state(5)).action == "decide"  # until it is voiced
    b.voiced([r.event])
    assert b.assess(Resumed(), _state(5)).action == "drop"


def test_unreachable_of_someone_elses_walk_to_a_place_is_information_only():
    b = EventBroker()
    v = b.assess(Unreachable(reason="no_route", detail="dz=-0.4m d=357.2m", leader_pos=[438, 0, 0], mode="go_to"),
                 _state(37))
    assert v.action == "inform"
    assert b.digest() == ["Body report 0s ago: a go_to to a spot 357 m away (not a player, not a move you "
                          "started) failed: no_route"]


def test_vitals_stale_cooldown_and_worse():
    clock = Clock()
    b = EventBroker(clock=clock)
    assert b.assess(VitalsLow(stat="hydration", value=10, max=75), _state(5, hyd=40)).action == "drop"  # drank
    assert b.assess(VitalsLow(stat="hydration", value=10, max=75),
                    _state(5, hyd=10, carried=[("Tea", "drink")])).action == "drop"  # carries one now
    v = b.assess(VitalsLow(stat="hydration", value=10, max=75), _state(5, hyd=10))
    assert v.action == "decide"
    b.voiced([v.event])
    clock.t += 30
    assert b.assess(VitalsLow(stat="hydration", value=9, max=75), _state(5, hyd=9)).action == "drop"  # not worse
    assert b.assess(VitalsLow(stat="hydration", value=4, max=75), _state(5, hyd=4)).action == "decide"  # worse


def test_triage_coalesces_and_supersedes():
    b = EventBroker()
    evs = [parse_event(e) for e in (
        {"type": "unreachable", "reason": "no_route"}, {"type": "resumed"},
        {"type": "vitals_low", "stat": "hydration", "value": 9}, {"type": "vitals_low", "stat": "hydration", "value": 6},
        {"type": "task_failed", "task_id": "x", "reason": "path_blocked"}, {"type": "task_done", "task_id": "y"},
        {"type": "chat_heard", "player": "Zezima", "text": "hi"})]
    out = b.triage(evs)
    assert [e.type for e in out] == ["resumed", "vitals_low", "chat_heard"] and out[1].value == 6


def test_fallback_line_is_the_template_safety_net():
    assert fallback_line([{"type": "vitals_low", "stat": "hydration"}, {"type": "vitals_low", "stat": "sustenance"}]) == \
        "I'm really thirsty and hungry and have nothing left. Could you bring me something to drink and something to eat?"
    assert fallback_line([{"type": "unreachable", "reason": "too_high", "about": "player"}]).startswith("I can't get up")


def test_facts_compare_what_a_line_can_go_stale_on():
    assert facts(STATES[2])["near_player"] is False and facts(STATES[3])["near_player"] is True
    assert facts(STATES[3])["has_food"] is True and facts(STATES[3])["hydration_low"] is True


# --------------------------------------------------------------------------- single voice


def test_voice_blocks_near_duplicates_within_the_window():
    clock = Clock()
    v = Voice(clock=clock, dup_window_s=30)
    v.record("I can't find a way to you from here. Can you come back towards me?")
    clock.t += 1
    assert v.gate("I can't find a way to you from here, can you come back towards me?")
    assert v.gate("pong", kind="system") is None
    assert v.gate("Doing well, thanks for asking!") is None
    clock.t += 31
    assert v.gate("I can't find a way to you from here. Can you come back towards me?") is None


def test_a_reply_whose_facts_changed_while_thinking_is_decided_again(tmp_path):
    """He arrived next to the player while the model was thinking: the reply is re-decided on fresh state."""
    r = Replay(tmp_path, STATES[2])
    first = {"n": 0}

    def model(ctx):
        first["n"] += 1
        if first["n"] == 1:
            r.body.state = copy.deepcopy(STATES[3])  # the world moved on during the call
            return FakeLLM.say("I still can't reach you.")
        return FakeLLM.say("Here now, right next to you.")
    r.model.replies["where are you"] = model
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude where are you"})
    r.at(0).step()
    assert r.body.said == ["Here now, right next to you."]
    assert r.records("speech_redecided")[0]["changed"]["near_player"] == [False, True]


def test_body_situation_fixed_while_thinking_is_not_said(tmp_path):
    r = Replay(tmp_path, STATES[0])

    def drink_meanwhile(ctx):
        r.body.state = {**copy.deepcopy(STATES[0]), "hydration": 70.0}
        return FakeLLM.say("I'm parched, can you bring me a drink?")
    r.model.body_reply = drink_meanwhile
    r.body.emit({"type": "vitals_low", "stat": "hydration", "value": 10.0, "max": 75.0})
    r.at(0).step()
    assert r.body.said == [] and r.records("situation_stale")
    assert len(r.model.contexts) == 1  # no second model call: the situation itself was gone


# --------------------------------------------------------------------------- episodic memory


GOBLIN = {"type": "activity", "kind": "combat_end", "by": "debug", "ts": 1792957860.0, "dur_s": 49.1,
          "target": "Goblin Runt", "outcome": "killed", "damage_taken": 0, "damage_dealt": 156,
          "loot": [{"name": "Bones", "count": 1}], "why": "commanded"}


def test_what_did_you_just_do_answers_from_activity_it_did_not_start(tmp_path):
    """Live 19:56: "you just killed goblin? don't you remember?" -> "I don't remember the fight": the
    fight came from a test command, so the brain never heard of it. Now every completed body episode
    is an ``activity`` event: progress log, notes for notable ones, recent_activity in every context."""
    from brain.dry_run_llm import DryRunController
    r = Replay(tmp_path, STATES[5])
    r.controller.llm = DryRunController()
    r.body.emit(GOBLIN)
    r.at(0).step()
    assert r.body.said == []  # memory, not a notice
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude what did you just do?"})
    r.at(60).step()
    ctx = json.loads(r.controller.llm.calls[-1]["messages"][1]["content"])
    assert ctx["recent_activity"] == ["60s ago: combat_end: dur_s=49.1; target=Goblin Runt; outcome=killed; "
                                      "damage_taken=0; damage_dealt=156; loot=Bones; why=commanded (started by debug)"]
    assert "Goblin Runt" in r.body.said[-1] and "killed" in r.body.said[-1]
    assert "Goblin Runt" in r.store.notes()["last_combat_end"]
    assert "activity" in r.store.progress_path.read_text(encoding="utf-8")


def test_activity_keeps_unknown_kinds_and_fields():
    ev = parse_event({"type": "activity", "kind": "trap_escaped", "by": "reflex", "where": [1, 2, 3], "how": "jump"})
    assert isinstance(ev, Activity) and ev.fields() == {"where": [1, 2, 3], "how": "jump"}
    assert EventBroker.notable(ev)  # it has a place


def test_death_with_a_place_becomes_the_grave_place(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.body.emit({"type": "activity", "kind": "death", "by": "unknown", "ts": 1792955640.0, "cause": "Giant Rat",
                 "where": [438.7, 1837.5, -35.0]})
    r.at(0).step()
    assert r.store.places()["grave"]["position"] == [438.7, 1837.5, -35.0]


def test_multi_step_turn_runs_in_order_and_stops_at_the_first_failure(tmp_path):
    """PRINCIPLES 4b: the model composes primitives in ONE message ("walk to him, then drop the logs").
    Steps run in order, stop at the first failure, and the follow-up gives the model every step's
    real result (the successful go_to, the failed drop, the step that never ran)."""
    r = Replay(tmp_path, STATES[2])
    r.body.act("go_to", go_to_ok(STATES[3]), state_after=STATES[3])
    r.body.act("drop", fail("not_in_inventory", item="Ash Logs"))
    r.model.replies["give me the logs"] = FakeLLM.say("Coming over with them.", FakeLLM.call("go_to", target="Zezima"),
                                                      FakeLLM.call("drop", item="Ash Logs", count=2),
                                                      FakeLLM.call("follow", player="Zezima"))
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude give me the logs"})
    r.at(0).step()
    assert [c[0] for c in r.body.calls] == ["go_to", "drop"]  # follow never ran
    follow = r.model.calls[-1]["messages"]
    results = [json.loads(m["content"]) for m in follow if m["role"] == "tool"]
    assert [x.get("ok") for x in results] == [True, False, None]
    assert results[2]["note"] == "not run: an earlier step failed"


# --------------------------------------------------------------------------- live 20:21:53 and 20:26:20

HUNGRY = json.loads((Path(__file__).parent / "fixtures" / "episode_2026-10-25_2021_hungry.json").read_text(encoding="utf-8"))


def test_replay_2021_model_fixed_hunger_so_no_nothing_left_line(tmp_path):
    """Live 20:21:53: vitals_low sustenance; the model picked up 4 sandwiches (interact, no speech) and
    the template "I'm really hungry and have nothing left" was said right after. Speak-time re-check:
    the fix happened, so that line is never said."""
    r = Replay(tmp_path, HUNGRY["before"], tools={"get_state", "say", "follow", "go_to", "stop", "interact"})
    r.body.act("interact", HUNGRY["interact"]["result"], state_after=HUNGRY["after"])
    r.model.body_reply = lambda ctx: FakeLLM.say("", FakeLLM.call("interact", target=HUNGRY["interact"]["target"]))
    r.body.emit(HUNGRY["event"])
    r.at(0).step()
    assert r.body.calls == [("interact", {"target": HUNGRY["interact"]["target"]})]
    assert not any("hungry" in s or "nothing left" in s for s in r.body.said), r.body.said
    assert r.records("situation_unspoken")[0]["why"] == "fixed by the model's own action"


def test_replay_2021_template_is_rechecked_at_speak_time(tmp_path):
    """Same event, the model says nothing and does nothing, but meanwhile the stay-fed reflex / a pickup
    put food in the bag: the template is re-checked on fresh state and not said."""
    r = Replay(tmp_path, HUNGRY["before"])

    def silent(ctx):
        r.body.state = copy.deepcopy(HUNGRY["after"])  # food arrived while the model was thinking
        return FakeLLM.say("")
    r.model.body_reply = silent
    r.body.emit(HUNGRY["event"])
    r.at(0).step()
    assert r.body.said == []


def test_replay_2026_where_are_you_gets_distance_and_motion(tmp_path):
    """Live 20:26:20: "where are you" -> "I'm right behind you, following your lead. I'm carrying 9 ..."
    while 1.8 km away and stopped (Zezima was out of census range; the context only said "following
    Zezima"). body_status now says where he is, that he is standing still and that Zezima is NOT in
    sight; the persona says to answer only what was asked, from current state."""
    far = {"position": [270.27, 1753.0, -39.82], "following": "Zezima", "action": "follow", "players": [],
           "inventory": {"ITEM_Consumable_Tea_Pumpkin": 9, "ITEM_Consumable_Sandwich_Veggie": 3},
           "health": 100, "max_health": 100}
    r = Replay(tmp_path, far)
    r.agent._fresh_state()  # an earlier observation, 10 s before: same spot
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "where are you"})
    r.at(10).step()
    r.at(13).step()
    ctx = r.model.contexts[-1]
    where = next(line for line in ctx["body_status"] if line.startswith("Where:"))
    assert "standing still" in where and "Zezima is NOT in sight" in where and "follow Zezima" in where, where
    persona = r.model.calls[-1]["messages"][0]["content"]
    assert "Answer only what was asked, from the CURRENT state" in persona and "Don't list what you" in persona
    assert "Never invent reasons" in persona


def test_where_line_with_the_player_in_sight_and_moving():
    clock = Clock()
    b = EventBroker(clock=clock)
    b.observe({"position": [0, 0, 0], "players": [{"name": "Zezima", "distance": 30, "position": [30, 0, 6]}]})
    clock.t += 2
    b.observe({"position": [8, 0, 0], "players": [{"name": "Zezima", "distance": 22, "position": [30, 0, 6]}]})
    assert b.where_line() == "Where: you are moving at 4.0 m/s; Zezima is 22 m away, 6 m higher"


def test_items_dropped_is_a_model_decision_and_goes_stale_when_gone(tmp_path):
    """Another player dropped food by him: one controller run with the structured event; the model's
    choice (pick it up) reaches the body; no code rule thanks or picks up by itself."""
    r = Replay(tmp_path, STATES[3], tools={"get_state", "say", "follow", "go_to", "stop", "interact"})
    sandwich = next(i for i in STATES[3]["nearby_items"] if i["name"] == "Forager's Sandwich")
    r.body.act("interact", ok(target=sandwich["id"]))
    r.model.body_reply = lambda ctx: FakeLLM.say("Thanks for the sandwiches!", FakeLLM.call("interact", target=sandwich["id"]))
    ev = {"type": "items_dropped", "by": "Zezima", "players": ["Zezima"],
          "items": [{"id": sandwich["id"], "name": "Forager's Sandwich", "count": 23, "consumable": "food",
                     "dropped_by": "Zezima"}]}
    r.body.emit(ev)
    r.at(0).step()
    assert r.model.contexts[-1]["body_event"]["type"] == "items_dropped"
    assert r.body.calls == [("interact", {"target": sandwich["id"]})] and r.body.said == ["Thanks for the sandwiches!"]
    gone = Replay(tmp_path / "gone", STATES[5])  # the sandwiches are no longer on the ground
    gone.body.emit(ev)
    gone.at(0).step()
    assert gone.model.contexts == [] and gone.body.said == []


# --------------------------------------------------------------------------- proactive: situation_review


def _vitals_state(endurance: float, phase: str = "day", sleep_allowed: bool = False, dist: float = 4.0) -> dict:
    st = copy.deepcopy(STATES[5])
    st["players"] = [{"name": "Zezima", "distance": dist, "position": [59.26, 1881.85, -35.45]}]
    st["survival"] = {"endurance": [endurance, 100.0], "hydration": [60.0, 75.0], "sustenance": [60.0, 75.0]}
    st["health"], st["max_health"] = 100.0, 100.0
    st["time_of_day"] = {"phase": phase, "hour": 22.0 if phase == "night" else 15.0, "is_night": phase == "night",
                         "sleep_allowed": sleep_allowed}
    return st


def _proactive_rig(tmp_path, said: str = ""):
    r = Replay(tmp_path, _vitals_state(60))
    r.model.body_reply = lambda ctx: FakeLLM.say(said)
    r.at(0).step()  # first observation: the baseline, nothing changed yet
    assert r.model.contexts == []
    return r


def test_night_and_low_endurance_the_model_suggests_resting(tmp_path):
    """Luis: at night, with endurance low, he says so and asks to rest. The broker only notices the
    STATE CHANGE (endurance crossed 50/30 %, day -> night) and hands it to the model; the words are the
    model's (here a fake)."""
    r = _proactive_rig(tmp_path, said="Guys, my endurance is at 20%, can we rest for the night?")
    r.body.state = _vitals_state(20, phase="night", sleep_allowed=True)
    r.at(40).step()  # the 30 s state sample sees it
    ev = r.model.contexts[-1]["body_event"]
    assert ev["type"] == "situation_review" and r.model.contexts[-1]["command"]["text"] == ""
    whats = {c["what"]: c for c in ev["changes"]}
    assert whats["endurance"]["direction"] == "down" and whats["endurance"]["to_pct"] == 20
    assert whats["time_of_day"] == {"what": "time_of_day", "from": "day", "to": "night", "hour": 22.0}
    assert whats["sleep_allowed"]["to"] is True and ev["stats_pct"]["endurance"] == 20
    assert r.body.said == ["Guys, my endurance is at 20%, can we rest for the night?"]
    persona = r.model.calls[-1]["messages"][0]["content"]
    assert "You may proactively" in persona and "respect the player's answers" in persona


def test_suggested_two_minutes_ago_and_told_no_stays_silent(tmp_path):
    """He suggested resting, the player said no: two minutes later a small further change brings no new
    review (rate limit, not worse); when a review does come, it carries what he said before, and the
    model may (and here does) stay silent."""
    r = _proactive_rig(tmp_path, said="Guys, my endurance is at 20%, can we rest?")
    r.body.state = _vitals_state(20, phase="night")
    r.at(40).step()
    assert len(r.body.said) == 1
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude no, not now, keep going"})
    r.at(45).step()
    n_ctx, n_said = len(r.model.contexts), len(r.body.said)
    r.body.state = _vitals_state(18, phase="night", sleep_allowed=True)  # same band; the sleep window opened
    r.at(160).step()  # 2 min after the suggestion: no review yet
    assert len(r.model.contexts) == n_ctx and len(r.body.said) == n_said
    r.model.body_reply = lambda ctx: FakeLLM.say("")  # the model respects his "no"
    r.at(230).step()  # past the 3 min gap: the pending change is reviewed, with the history
    ev = r.model.contexts[-1]["body_event"]
    assert ev["previous_review"]["you_said"] == "Guys, my endurance is at 20%, can we rest?"
    assert any(c["text"] == "claude no, not now, keep going" for c in r.model.contexts[-1]["chat"])
    assert len(r.body.said) == n_said  # silence is a valid choice: no template, no default reply


def test_getting_worse_bypasses_the_gap(tmp_path):
    r = _proactive_rig(tmp_path, said="Getting really tired now.")
    r.body.state = _vitals_state(25)
    r.at(40).step()
    r.body.state = _vitals_state(10)  # crossed 15 %: worse than at the last review
    r.at(80).step()
    assert [c["body_event"]["changes"][0]["to_pct"] for c in r.model.contexts] == [25, 10]


def test_no_review_in_combat_during_a_command_or_a_job(tmp_path):
    r = _proactive_rig(tmp_path, said="Tired.")
    r.body.emit({"type": "attacked", "by": "rat_1", "name": "Giant Rat"})
    r.body.state = _vitals_state(20)
    r.at(40).step()
    assert r.model.contexts == []  # attacked 0 s ago: in combat
    r.agent.active_goal = "gather 10 logs"
    r.at(75).step()
    assert r.model.contexts == []  # a job is running
    r.agent.active_goal = None
    r.at(80).step()
    assert len(r.model.contexts) == 1


def test_idle_near_the_player_is_a_change_worth_a_review(tmp_path):
    r = _proactive_rig(tmp_path, said="")
    r.at(200).step()
    assert r.model.contexts == []
    r.at(310).step()
    ev = r.model.contexts[-1]["body_event"]
    assert ev["changes"] == [{"what": "idle", "for_s": 310, "near": ["Zezima"]}] and r.body.said == []


# --------------------------------------------------------------------------- the agent loop (live 20:43)

SPOT = [382.64462211155, 1744.29481585, -42.468945506218]
SHELTER = "BP_Magic_SummonShelter_C_2147450308"


def test_replay_2043_shelter_plan_is_carried_through(tmp_path):
    """Live 20:42-20:43: Luis "why are you asking me - you have the available tools ... do this on your
    own". The model cast Summon Shelter (blocked: ground not flat), then go_to a flatter spot... and the
    plan died there: the go_to finished and the model never got another turn. At 20:43:49 it told him
    "I'm walking to a flatter spot" while standing still. Now every turn's results go back to the
    model, which carries the plan through: walk, recast, get in the bed, report. The walk's line is
    said as the walk starts, never after arriving."""
    here = copy.deepcopy(STATES[5])
    there = {**copy.deepcopy(STATES[5]), "position": [381.87, 1745.43, -41.57]}
    tools = {"get_state", "say", "follow", "go_to", "stop", "interact", "cast"}
    r = Replay(tmp_path, here, tools=tools)
    r.body.act("cast", fail("nothing_in_range", rejected=[{"spot": SPOT, "game": "UI.Notification.SpellPlacement.Blocked"}]))
    r.body.act("go_to", ok(target_position=SPOT, dist_m=1.47, position=there["position"]), state_after=there)
    r.body.act("cast", ok(spell="Summon Shelter", placed=SHELTER))
    r.body.act("interact", ok(target=SHELTER, prompt="Sleep"))
    r.model.replies["you can do this on your own"] = FakeLLM.say(
        "You're right, I'll handle it. Trying the shelter again on my own now.", FakeLLM.call("cast", spell="Summon Shelter"))
    r.model.turns = [
        FakeLLM.say("Ground's not flat here, walking to a flatter spot 25 m away to try again.",
                    FakeLLM.call("go_to", target=SPOT)),
        FakeLLM.say("", FakeLLM.call("cast", spell="Summon Shelter")),
        FakeLLM.say("", FakeLLM.call("interact", target=SHELTER)),
        FakeLLM.say("Shelter's up and I'm in bed. Come join me."),
    ]
    r.body.emit({"type": "chat_heard", "player": "Zezima",
                 "text": "why are you asking me -  you have the available tools to solve the problem. you can do this on your own"})
    r.at(0).step()
    r.at(3).step()
    assert [c[0] for c in r.body.calls] == ["cast", "go_to", "cast", "interact"]
    # the walk's line came BEFORE the walk; the failed first cast's line was never said (failure overrides)
    tl = r.body.timeline
    walk_line = ("say", "Ground's not flat here, walking to a flatter spot 25 m away to try again.")
    assert tl.index(walk_line) < tl.index(("call", "go_to"))
    assert r.body.said == [walk_line[1], "Shelter's up and I'm in bed. Come join me."]
    # the second turn saw the failure with the body's truthful data
    follow = r.model.calls[1]["messages"]
    failed = json.loads(next(m for m in reversed(follow) if m["role"] == "tool")["content"])
    assert failed["ok"] is False and failed["reason"] == "nothing_in_range" and failed["data"]["rejected"]
    turns = [x["turn"] for x in r.records("chain_turn")]
    assert turns == [1, 2, 3, 4]

    # 20:43:49 "what are you working on?": the context says what really happened, and where he is
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "what are you working on?"})
    r.at(30).step()
    r.at(33).step()
    status = r.model.contexts[-1]["body_status"]
    recent = next(line for line in status if line.startswith("Your recent actions"))
    assert "cast Summon Shelter FAILED: nothing_in_range" in recent and "go_to" in recent and " ok" in recent
    assert recent.index("FAILED") < recent.rindex("interact")
    assert any(line.startswith("Last move: go_to") and "arrived" in line for line in status)


def test_chain_is_bounded_and_yields_to_a_new_chat_line(tmp_path):
    r = Replay(tmp_path, STATES[5], tools={"get_state", "say", "follow", "go_to", "stop", "interact"})
    for _ in range(8):
        r.body.act("interact", ok(target=INFUSION))
    r.model.replies["keep grabbing"] = FakeLLM.say("On it.", FakeLLM.call("interact", target=INFUSION))
    r.model.turns = [FakeLLM.say("", FakeLLM.call("interact", target=INFUSION)) for _ in range(8)]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude keep grabbing"})
    r.at(0).step()
    from brain.agent import MAX_TURNS
    assert len(r.body.calls) == 1 + MAX_TURNS  # the first turn plus MAX_TURNS continuations, no more
    assert r.records("chain_stopped")[0]["why"] == "budget"
    # a new chat line from the player ends a chain at once (he has the floor)
    r2 = Replay(tmp_path / "two", STATES[5], tools={"get_state", "say", "follow", "go_to", "stop", "interact"})
    r2.body.act("interact", ok(target=INFUSION), emitted=[{"type": "chat_heard", "player": "Zezima", "text": "stop that"}])
    r2.model.replies["keep grabbing"] = FakeLLM.say("On it.", FakeLLM.call("interact", target=INFUSION))
    r2.model.turns = [FakeLLM.say("", FakeLLM.call("interact", target=INFUSION))]
    r2.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude keep grabbing"})
    r2.at(0).step()
    assert len(r2.body.calls) == 1 and r2.records("chain_stopped")[0]["why"] == "the player spoke"


def test_a_follow_needs_no_continuation_turn(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.body.act("follow", ok(following="Zezima"), state_after={**copy.deepcopy(STATES[5]), "following": "Zezima"})
    r.model.replies["follow me"] = FakeLLM.say("Right behind you.", FakeLLM.call("follow", player="Zezima"))
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude follow me"})
    r.at(0).step()
    assert len(r.model.calls) == 1 and r.body.said == ["Right behind you."]


def test_unknown_target_goes_back_with_the_tools_own_argument_help(tmp_path):
    """Live 20:46: "I couldn't go to: unknown_target." twice (a raw code, from the template fallback,
    because the follow-up's own fix failed / its look was never run). Now the failure and the tool's
    argument descriptions go back to the model, a read in the next turn is run, and no raw code is said."""
    tools = {"get_state", "say", "follow", "go_to", "stop", "interact", "look"}
    r = Replay(tmp_path, STATES[5], tools=tools)
    r.body.act("go_to", fail("unknown_target", detail="target_not_visible"))
    r.body.act("interact", ok(target=SHELTER))
    r.body.look_things = [{"id": SHELTER, "name": "Summon Shelter", "kind": "interactable", "distance": 3.0, "match": 1}]
    r.model.replies["get in it"] = FakeLLM.say("", FakeLLM.call("go_to", target=SHELTER))
    r.model.turns = [FakeLLM.say("", FakeLLM.call("look", about="shelter")),
                     FakeLLM.say("Getting in from the front.", FakeLLM.call("interact", target=SHELTER)),
                     FakeLLM.say("")]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude get in it by interacting with it at the front"})
    r.at(0).step()
    failed = json.loads(next(m for m in reversed(r.model.calls[1]["messages"]) if m["role"] == "tool")["content"])
    assert failed["reason"] == "unknown_target" and "target" in failed["args_help"]
    assert [c[0] for c in r.body.calls] == ["go_to", "interact"]
    assert r.body.said == ["Getting in from the front."]
    assert not any("unknown_target" in s for s in r.body.said)


def test_persona_says_act_on_your_own_and_carry_plans_through(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude hi"})
    r.at(0).step()
    persona = r.model.calls[-1]["messages"][0]["content"]
    assert "act on your own plan and report" in persona and "Carry your plans through" in persona
    assert "Ask Zezima only when it is genuinely ambiguous, risky or beyond your tools" in persona


# --------------------------------------------------------------------------- docs/BUGS.md L2, L5, L6, L10


class StubTransport:
    """A body that answers pings (with a scripted heartbeat) and holds every other command forever,
    or pushes the scripted messages while a command waits."""

    def __init__(self, beats=(), push=()):
        self.sent, self.beats, self.push = [], list(beats), list(push)
        self.malformed: list = []

    def send(self, msg):
        self.sent.append(msg)
        if msg["tool"] == "ping":
            data = self.beats.pop(0) if self.beats else {"pong": True}
            self.push.insert(0, {"v": 1, "type": "result", "id": msg["id"], "ok": True, "reason": None, "data": data})

    def receive(self, timeout):
        out, self.push = self.push, []
        return out


def _client(transport, monkeypatch, tmp_path):
    from brain import bridge_client as bc
    monkeypatch.setattr(bc, "HEARTBEAT_S", 0.0)
    return bc.BridgeClient(transport, JsonlLogger(tmp_path / f"bridge-{len(transport.sent)}-{id(transport)}.jsonl"))


def test_l2a_an_addressed_line_stops_the_wait_for_a_running_tool(monkeypatch, tmp_path):
    """L2 (20:58-21:01): chat queued for 3 min behind a go_to. Now an addressed chat line arriving while
    a long tool runs ends the wait at once (interrupted); the body keeps going until told otherwise."""
    chat = {"v": 1, "type": "event", "event": {"type": "chat_heard", "player": "Zezima", "text": "claude get out of the shelter"}}
    t = StubTransport(push=[chat])
    client = _client(t, monkeypatch, tmp_path)
    client.interrupt_check = lambda ev: getattr(ev, "text", "").startswith("claude")
    res = client.request("go_to", {"target": "Zezima"}, timeout=60)
    assert res["ok"] is False and res["reason"] == "interrupted" and res["data"]["by"] == "chat"
    assert client.abandoned(t.sent[0]["id"])
    assert [e.text for e in client.poll_events()] == ["claude get out of the shelter"]  # the line is kept for the agent
    # an unaddressed line does not interrupt
    t2 = StubTransport(push=[{"v": 1, "type": "event", "event": {"type": "chat_heard", "player": "Bob", "text": "lol"}}],
                       beats=[{"pong": True, "started": 7, "action": {"id": "x"}}])
    c2 = _client(t2, monkeypatch, tmp_path)
    c2._started = 7
    c2.interrupt_check = lambda ev: getattr(ev, "text", "").startswith("claude")
    assert c2.request("go_to", {"target": "Zezima"}, timeout=60)["reason"] == "lost_by_body"


def test_l2b_a_bridge_restart_or_a_dropped_command_fails_the_request_at_once(monkeypatch, tmp_path):
    t = StubTransport(beats=[{"pong": True, "started": 200, "action": None}])
    client = _client(t, monkeypatch, tmp_path)
    client._started = 100  # from the session's first ping
    res = client.request("go_to", {"target": "Zezima"}, timeout=125)
    assert res["reason"] == "body_restarted" and "restarted" in res["data"]["detail"]
    t2 = StubTransport()
    client2 = _client(t2, monkeypatch, tmp_path)
    client2._started = 100

    def beat_with_our_id(msg, orig=t2.send):
        orig(msg)
        if msg["tool"] == "go_to":
            t2.beats = [{"pong": True, "started": 100, "action": {"id": msg["id"], "kind": "go_to"}}] * 2 + \
                       [{"pong": True, "started": 100, "action": None}]
    t2.send = beat_with_our_id
    res2 = client2.request("go_to", {"target": "Zezima"}, timeout=125)
    assert res2["reason"] == "lost_by_body"  # it worked on it for two beats, then the slot was empty, no reply
    assert [m["tool"] for m in t2.sent].count("ping") == 3


def test_l2c_timeouts_and_restarts_are_not_retried_blindly(tmp_path):
    from brain.interface import Reason
    assert {Reason.TIMEOUT, Reason.BODY_RESTARTED, Reason.LOST_BY_BODY, Reason.RESTING} <= Reason.DETERMINISTIC
    r = Replay(tmp_path, STATES[5])
    r.executor.max_attempts = 3
    r.body.act("go_to", fail("timeout", detail="timeout"))
    r.body.act("go_to", ok(target="Zezima"))  # would succeed on a retry: must not be tried blindly
    r.model.replies["get out of the shelter"] = FakeLLM.say("", FakeLLM.call("go_to", target="Zezima"))
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude get out of the shelter now its day"})
    r.at(0).step()
    assert [c[0] for c in r.body.calls] == ["go_to"]  # one try; the timeout went back to the model
    result = json.loads(next(m for m in reversed(r.model.calls[1]["messages"]) if m["role"] == "tool")["content"])
    assert result["reason"] == "timeout"


def test_l2a_live_agent_marks_addressed_lines_as_interrupting(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.body.interrupt_check = None
    agent = LiveAgent(r.body, r.controller, Planner(FakeLLM(), r.store.skills, r.log), r.executor, r.store, r.log,
                      prefixes=["claude "], clock=r.clock)
    from brain.interface import ChatHeard
    assert r.body.interrupt_check is not None
    assert r.body.interrupt_check(ChatHeard(player="Zezima", text="claude stop"))
    assert not r.body.interrupt_check(ChatHeard(player="Bob", text="nice weather"))
    assert agent


def test_l5_replay_2102_promise_without_a_tool_call_gets_a_turn(tmp_path):
    """Live 21:02:56 ("what do you mean", not addressed): "...I'll walk closer and cast it on the tree."
    with NO tool call, and nothing happened. A talk-only first turn now gets ONE more turn to call what
    it said it would do (information, not a veto); here the model calls go_to + cast in order."""
    tree = "fol:BP_InteractableFoliageISMC_Tree_C_7:2"
    r = Replay(tmp_path, STATES[5], tools={"get_state", "say", "follow", "go_to", "stop", "interact", "cast"})
    r.body.act("go_to", ok(target=tree))
    r.body.act("cast", ok(spell="Axtral Projection"))
    r.model.replies["what do you mean"] = FakeLLM.say(
        "Sorry, I said \"Done\" too early. I never cast Axtral Projection. The tree I tried to reach is out of sight, "
        "so I'm standing still. I'll walk closer and cast it on the tree.")
    r.model.turns = [FakeLLM.say("", FakeLLM.call("go_to", target=tree), FakeLLM.call("cast", spell="Axtral Projection", target=tree)),
                     FakeLLM.say("Cast it on the tree.")]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude what do you mean"})
    r.at(0).step()
    assert [c[0] for c in r.body.calls] == ["go_to", "cast"]
    note = r.model.calls[1]["messages"][-1]["content"]
    assert note.startswith("You replied without calling any tool.")
    assert r.body.said[0].endswith("I'll walk closer and cast it on the tree.") and r.body.said[-1] == "Cast it on the tree."


def test_l5_a_plain_answer_costs_one_check_turn_and_stays_one_line(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.model.replies["how are you"] = FakeLLM.say("Doing well, thanks!")
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude how are you"})
    r.at(0).step()
    assert r.body.said == ["Doing well, thanks!"] and r.body.calls == [] and len(r.model.calls) == 2


def test_l6_one_state_read_before_an_action(tmp_path):
    """L6 (20:58:39-40): three get_state round trips before each tool. Now the turn's read is reused by
    the executor (<= 1 s, invalidated by any action); verification after the action stays fresh."""
    r = Replay(tmp_path, STATES[5])
    reads = []
    orig = r.body.get_state
    r.body.get_state = lambda: (reads.append(r.body.timeline[-1] if r.body.timeline else None), orig())[1]
    r.agent._fresh_state()
    n0 = len(reads)
    r.body.act("go_to", ok(target="Zezima"))
    out = r.executor.run_task(__import__("brain.state_store", fromlist=["Task"]).Task(skill="go_to", args={"target": "Zezima"}))
    assert out.ok and len(reads) - n0 == 1  # only the verification read (was 3: baseline, attempt, verify)


def test_l10_house_rules_file_is_in_the_persona_and_re_read_on_edit(tmp_path, monkeypatch):
    rules = tmp_path / "house_rules.md"
    rules.write_text("# rules\n- Sleep in your own shelter.\n- PvP is off: never attack a player.\n", encoding="utf-8")
    monkeypatch.setenv("DW_HOUSE_RULES", str(rules))
    r = Replay(tmp_path, STATES[5])
    persona = r.controller.persona()
    assert "House rules from Zezima" in persona and "- Sleep in your own shelter." in persona
    import os
    rules.write_text("- Get up and out of bed as soon as it's day.\n", encoding="utf-8")
    os.utime(rules, (rules.stat().st_atime + 5, rules.stat().st_mtime + 5))
    assert "- Get up and out of bed as soon as it's day." in r.controller.persona()
    shipped = (Path(__file__).resolve().parents[1] / "brain" / "house_rules.md").read_text(encoding="utf-8")
    for line in ("- Sleep in your own shelter.", "- Get up and out of bed as soon as it's day.",
                 "- Don't use another player's shelter or bed unless that player asked you to."):
        assert line in shipped


def test_l10_day_while_resting_is_reviewed_at_once(tmp_path):
    """L10: he stayed in bed after day. The night -> day change while resting is reviewed even inside
    the 3 min gap; the model (house rule: get up as soon as it's day) gets up with interact on the bed."""
    bed = "BP_Magic_SummonShelter_C_2147450308"
    r = _proactive_rig(tmp_path, said="Night, see you in the morning.")
    r.body.state = _vitals_state(25, phase="night", sleep_allowed=True)
    r.at(40).step()  # a review (endurance down, night)
    resting = _vitals_state(25, phase="day")
    resting["time_of_day"].update(sleeping=True, resting_in=bed)
    r.body.state = resting
    r.body.act("interact", ok(target=bed))
    r.model.body_reply = lambda ctx: FakeLLM.say("Morning! Getting up.", FakeLLM.call("interact", target=bed))
    r.at(100).step()  # 60 s after the last review: still reviewed (day change)
    ev = r.model.contexts[-1]["body_event"]
    assert any(c["what"] == "time_of_day" and c["to"] == "day" for c in ev["changes"])
    assert ev["time_of_day"]["resting_in"] == bed and r.body.calls == [("interact", {"target": bed})]
    assert r.body.said[-1] == "Morning! Getting up."

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
        self.script: dict[str, list[tuple[dict, list[dict], dict | None]]] = {}

    def emit(self, *events: dict) -> None:
        self.queue.extend(copy.deepcopy(list(events)))

    def act(self, tool: str, result: dict, emitted: list[dict] = (), state_after: dict | None = None) -> None:
        self.script.setdefault(tool, []).append((result, list(emitted), state_after))

    def _act(self, tool: str, **args) -> dict:
        self.calls.append((tool, args))
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
        return ok()

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

    def complete(self, messages, tools=None):
        self.calls.append({"messages": messages, "tools": tools})
        if messages[-1].get("role") == "user" and not messages[-1]["content"].startswith("{"):
            return LLMResponse(content="")  # failure follow-up: say nothing, the template answers
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

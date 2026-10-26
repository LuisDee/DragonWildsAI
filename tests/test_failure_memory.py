"""Failure memory in the Controller's context (live 22:19-22:20, review-0006: interact on a Water Volume failed
too_far 4 x across 2 episodes). body_status cut the failed target's id at 48 characters, so it no longer
matched the id the model saw in look, and never said WHAT the thing was. Then a failure template said the
raw id in chat (22:20:56, a raw_code_spoken anomaly). Fixes: ids are never cut and the thing's in-game
name goes first; a failure stays in view while newer ok steps arrive; chat lines don't push body results
out of the recent_events window; failure templates say names, not ids."""
from __future__ import annotations

from brain.broker import DIGEST_KEEP_S, EventBroker, arg_text
from brain.controller import player_words
from brain.interface import CommandReceived, TaskFailed
from brain.llm import FakeLLM

from test_event_hygiene import STATES, Replay

WATER = "BP_WaterVolume_C_UAID_00BE4395530E72EB01_2108496385"
LOOK = {"things": [{"name": "Water Volume", "id": WATER, "distance": 3.2, "kind": "interactable",
                    "verb": "interact"}]}


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def _status(b: EventBroker) -> str:
    return "\n".join(b.digest())


def test_arg_text_never_cuts_an_id_and_names_the_target_first():
    assert arg_text({"target": WATER}, "Water Volume") == f"Water Volume ({WATER})"
    assert arg_text({"target": WATER}) == WATER  # unknown name: the whole id, still matchable
    assert arg_text({"target": [46.77, 1791.41, -34.95]}) == "[47, 1791, -35]"
    long = "a very long free text argument that goes on and on and on"
    assert arg_text({"about": long}).endswith("...") and len(arg_text({"about": long})) <= 43


def test_a_failed_action_on_a_looked_at_thing_shows_its_name_and_whole_id():
    b = EventBroker(clock=Clock())
    b.learn_names(looks=[LOOK])
    b.action_started("interact", {"target": WATER})
    b.action_finished("interact", {"target": WATER}, False, "too_far",
                      {"target": WATER, "detail": "I can't get close enough to the Water Volume."})
    assert f"interact Water Volume ({WATER}) FAILED: too_far" in _status(b)


def test_names_come_from_observed_state_too():
    b = EventBroker(clock=Clock())
    b.observe({"position": [0, 0, 0], "interactables": [{"name": "Water Volume", "id": WATER, "prompt": "Collect Water"}]})
    assert b.name_of(WATER) == "Water Volume"


def test_a_failure_stays_in_view_after_five_newer_ok_actions_then_ages_out():
    clock = Clock()
    b = EventBroker(clock=clock)
    b.learn_names(looks=[LOOK])
    b.action_finished("interact", {"target": WATER}, False, "too_far", {})
    for i in range(5):
        clock.t += 1
        b.action_finished("go_to", {"target": [i, 0, 0]}, True)
    status = _status(b)
    assert "Earlier failed actions: interact Water Volume" in status and "FAILED: too_far" in status
    assert status.count("go_to") == 5
    clock.t += DIGEST_KEEP_S + 1
    assert "too_far" not in _status(b)


def test_chat_commands_dont_push_failures_out_of_recent_events(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.controller.note_event(TaskFailed(task_id="t1", reason="too_far"))
    for i in range(20):
        r.controller.note_event(CommandReceived(player="Zezima", text=f"line {i}"))
    ctx = r.controller.context("Zezima", "hi", r.body.get_state()["data"], None)
    assert [e["type"] for e in ctx["recent_events"]] == ["task_failed"]


def test_failure_template_says_the_name_not_the_id():
    detail = f"Water Volume is already in sight (3.23 m, id {WATER})"
    assert player_words(detail, "Water Volume") == "Water Volume is already in sight"
    assert player_words(f"I can't reach {WATER} from here.", "Water Volume") == "I can't reach Water Volume from here."
    assert player_words("Fine (as it is).") == "Fine (as it is)."


def test_report_failure_never_speaks_a_raw_id(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.controller.report_failure("gather", "already_in_sight",
                                {"detail": f"Water Volume is already in sight (3.23 m, id {WATER})",
                                 "found": {"name": "Water Volume", "id": WATER}})
    r.controller.report_failure("explore", "odd_reason", {"detail": f"stuck next to {WATER} for a while"})
    assert r.body.said == ["Water Volume is already in sight",
                           "Sorry, I couldn't explore: stuck next to it for a while."]
    assert not any("BP_" in s for s in r.body.said)

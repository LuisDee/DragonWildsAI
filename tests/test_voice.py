"""Voice workstream V (docs/design/companion-quality.md §3): the persona file and the voice eval, offline.

No model calls: FakeLLM stands in for Haiku and the Sonnet judge."""
import importlib.util
import json
import os
import re
import time
from pathlib import Path

import pytest

from brain import persona as persona_file
from brain.llm import FakeLLM, LLMResponse, ToolCall

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("voice_eval", ROOT / "evals" / "voice_eval.py")
ve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ve)

VALUES = dict(name="Claude", player="Zezima", triggers="telegraph, own_hp_below", look_rule=" -> LOOK RULE",
              lookup_rule="\n- LOOKUP RULE")


def cases():
    return ve.read_jsonl(ve.CASES)


# ------------------------------------------------------------------ persona file


def test_persona_renders_with_exactly_the_known_placeholders():
    text = persona_file.template(persona_file.DEFAULT_PATH)
    fields = set(re.findall(r"\{(\w*)\}", text))
    assert fields == set(persona_file.PLACEHOLDERS)
    out = persona_file.render(text, **VALUES)
    assert "{" not in out and "}" not in out
    assert "LOOK RULE" in out and "LOOKUP RULE" in out and "telegraph, own_hp_below" in out


def test_persona_keeps_every_functional_instruction():
    """The rewrite may shorten them, never drop them (the brief: keep every functional instruction)."""
    out = persona_file.render(persona_file.template(persona_file.DEFAULT_PATH), **VALUES)
    for anchor in ["addressed=true", "addressed=false", "EMPTY", "Never butt into", "in ONE message",
                   "never pair an action with stop", "run_skill", "start_goal", "list_skills", "remember",
                   '"place:<name>"', "at=self", "at=player", "never substitute", "references", "read_as",
                   "command.player", "body_status", "unreachable", "resumed", "follow_ended", "vitals_low",
                   "items_dropped", "situation_review", "previous_review.you_said", "recent_activity",
                   "castable_spells", "set_reflex_rule", "reflex_rules", "list_rules", "clear_rule",
                   "Never invent reasons", "CURRENT state", "you=true"]:
        assert anchor in out, anchor


def test_persona_carries_the_speech_rules_luis_asked_for():
    out = persona_file.render(persona_file.template(persona_file.DEFAULT_PATH), **VALUES).lower()
    for rule in ["stay quiet", "the action is the answer", "same reply", "never read out numbers",
                 "metres", "one line per moment", "stock lines", "bad -> good"]:
        assert rule in out, rule
    assert len(re.findall(r"^\d\. ", out, re.M)) >= 6  # few-shot bad -> good pairs from the real chat


def test_persona_names_no_player_literally():
    """The player's name is a placeholder: the persona works for any player (PRINCIPLES #3)."""
    assert "Zezima" not in persona_file.template(persona_file.DEFAULT_PATH)


def test_render_refuses_a_missing_placeholder():
    with pytest.raises(KeyError):
        persona_file.render("{name}", name="Claude")


def test_template_is_re_read_when_the_file_changes_and_falls_back_when_missing(tmp_path, monkeypatch):
    p = tmp_path / "persona.md"
    p.write_text("one {name}", encoding="utf-8")
    assert persona_file.template(p) == "one {name}"
    p.write_text("two {name}", encoding="utf-8")
    os.utime(p, (time.time() + 5, time.time() + 5))
    assert persona_file.template(p) == "two {name}"
    monkeypatch.setenv("DW_PERSONA", str(p))
    assert persona_file.persona_path() == p and persona_file.template() == "two {name}"
    assert persona_file.template(tmp_path / "gone.md", fallback="old") == "old"
    with pytest.raises(OSError):
        persona_file.template(tmp_path / "gone.md")


def test_old_persona_fixture_renders_and_both_get_the_house_rules(tmp_path):
    ctl = ve.make_controller(tmp_path)
    for v in ("old", "new"):
        prompt = ve.system_prompt(v, ctl)
        assert prompt.startswith("You are Claude") and "{" not in prompt.split("House rules")[0]
        if ctl.house_rules():
            assert "House rules from Zezima" in prompt


# ------------------------------------------------------------------ case file


def test_case_file_is_small_valid_and_has_a_held_out_split():
    cs = cases()
    assert len(cs) == 25 and len({c["id"] for c in cs}) == 25
    assert sum(c["split"] == "held_out" for c in cs) >= 5
    for c in cs:
        assert {"id", "split", "speech", "tool", "ideal", "context", "player"} <= c.keys(), c["id"]
        assert c["speech"] in ("required", "forbidden", "optional") and c["tool"] in ("required", "optional")
        assert isinstance(c["context"].get("command"), dict)
        if c["kind"] == "follow_up":
            assert c["history"] and c["note"]
    # body situations, chat and follow-ups are all represented
    assert {c["kind"] for c in cs} == {"chat", "body_event", "follow_up"}


def test_tool_list_comes_from_the_real_body_manifest(tmp_path):
    names = {t["function"]["name"] for t in ve.make_controller(tmp_path).tools}
    assert {"cast", "go_to", "interact", "gather", "look", "inventory", "consume", "start_goal"} <= names
    assert "say" not in names and "get_state" not in names  # llm:false in the manifest


# ------------------------------------------------------------------ deterministic checks


CASE = {"id": "t", "speech": "optional", "tool": "optional", "context": {"chat": [
    {"who": "Claude", "you": True, "text": "Casting Splinter took too long, so I stopped."}]}}


@pytest.mark.parametrize("line", ["Food is at 14% and I have nothing", "I'm 21 m from you now",
                                  "walking to [382, 1744, -42]", "my hydration is low"])
def test_numbers_and_stats_are_caught(line):
    assert ve.checks(CASE, line, [])["no_numbers"] is False


@pytest.mark.parametrize("line", ["got 4 logs", "starving, got any food?", "nearly there"])
def test_human_lines_pass_the_number_check(line):
    assert ve.checks(CASE, line, [])["no_numbers"] is True


def test_asked_for_stats_turns_the_number_check_off():
    assert ve.checks({**CASE, "asked_stats": True}, "food's at 14%", [])["no_numbers"] is None


def test_promise_without_a_tool_call_fails_and_with_one_passes():
    line = "my bad, the shelter's there, so I'll hop in it."
    assert ve.checks(CASE, line, [])["promise_has_tool"] is False
    assert ve.checks(CASE, line, [{"tool": "interact", "args": {}}])["promise_has_tool"] is True


@pytest.mark.parametrize("line", ["want me to chop it?", "I can't get the game to let me use the shelter.",
                                  "walking to a flatter spot"])
def test_offers_questions_and_present_tense_are_not_promises(line):
    assert ve.checks(CASE, line, [])["promise_has_tool"] is None


def test_internal_codes_length_and_duplicates():
    assert ve.checks(CASE, "I couldn't go to: unknown_target.", [])["no_internal"] is False
    assert ve.checks(CASE, "go_to BP_SplittableLog_Ash_C_1", [])["no_internal"] is False
    assert ve.checks(CASE, "x" * 151, [])["length"] is False
    assert ve.checks(CASE, "casting Splinter took too long so I stopped", [])["no_duplicate"] is False
    assert ve.checks(CASE, "no nature runes, got any?", [])["no_duplicate"] is True


def test_silence_and_acting_requirements():
    quiet = {**CASE, "speech": "forbidden", "tool": "required"}
    assert ve.checks(quiet, None, [])["silence"] is True and ve.checks(quiet, None, [])["acted"] is False
    assert ve.checks(quiet, "hm", [{"tool": "cast"}])["silence"] is False
    talk = {**CASE, "speech": "required"}
    assert ve.checks(talk, "", [])["silence"] is False and ve.checks(talk, "nope", [])["silence"] is True
    # n/a checks stay None when nothing was said
    assert ve.checks(CASE, None, [])["no_numbers"] is None


# ------------------------------------------------------------------ replay loop, judge, runner


def test_reads_are_answered_from_the_log_or_the_situation():
    case = {"context": {"situation": ["You: HP 100%", "Carrying: Air Rune x5", "Players: Zezima 3 m"]},
            "reads": [{"tool": "look", "args": {"about": "tree"}, "result": {"ok": True, "data": {"things": ["Ash Tree"]}}}]}
    assert ve.read_result(case, "look", {"about": "tree"})["data"]["things"] == ["Ash Tree"]
    inv = ve.read_result(case, "inventory", {})["data"]
    assert inv["from_situation"] == ["Carrying: Air Rune x5"] and "not logged" in inv["note"]


def test_decide_loops_reads_like_the_live_controller(tmp_path):
    case = cases()[0]
    ctl = ve.make_controller(tmp_path)
    llm = FakeLLM()
    llm.push(LLMResponse(tool_calls=[ToolCall("look", {"about": "shelter"}, "c1")]),
             FakeLLM.say("yep", FakeLLM.call("cast", spell="Summon Shelter")))
    budget = ve.Budget(10)
    rep, reads, _ = ve.decide(case, ve.system_prompt("new", ctl), ctl, llm, budget)
    assert budget.used == 2 and reads == [{"tool": "look", "args": {"about": "shelter"}}]
    assert rep["calls"] == [{"tool": "cast", "args": {"spell": "Summon Shelter"}}] and rep["speech"] == "yep"


def test_decide_stops_looping_when_the_budget_is_reserved(tmp_path):
    case = cases()[0]
    ctl = ve.make_controller(tmp_path)
    llm = FakeLLM()
    llm.push(*[LLMResponse(tool_calls=[ToolCall("look", {"about": "x"}, "c")])] * 3)
    budget = ve.Budget(3)
    _, reads, _ = ve.decide(case, ve.system_prompt("new", ctl), ctl, llm, budget, reserve=2)
    assert budget.used == 1 and reads == []  # one call, the rest is kept for other cases / the judge


def test_parse_judge_is_tolerant_and_strict_about_ids():
    raw = 'Here:\n```json\n[{"id": "a", "human": null, "silence": 5, "match": 4, "why": "ok"}, {"id": "zz", "human": 1}]\n```'
    assert ve.parse_judge(raw, ["a", "b"]) == {"a": {"human": None, "silence": 5, "match": 4, "why": "ok"}}
    assert ve.parse_judge("no json", ["a"]) == {}


def test_judge_prompt_is_blind_to_the_persona():
    c = cases()[0]
    msgs = ve.judge_prompt([(c, {"speech": "hey", "calls": [], "reads": []})])
    body = msgs[1]["content"]
    assert "persona" not in body.lower() and "old" not in json.loads(body)[0]["reply"]
    assert json.loads(body)[0]["wanted"] == c["ideal"]


def test_dry_run_end_to_end_reports_seen_and_held_out(tmp_path):
    ctl_llm, judge_llm = ve._dry_llms()
    out = ve.run(["old", "new"], cases(), ctl_llm, judge_llm, tmp_path)
    assert out["calls"] == ve.plan_calls(25, 2)["total"] == 54
    assert {"old", "new", "old/seen", "old/held_out", "new/seen", "new/held_out"} <= out["summary"].keys()
    assert out["summary"]["new/held_out"]["cases"] >= 5
    assert all(r.get("judge") for r in out["results"]["new"])


def test_runner_refuses_without_yes_and_over_the_cap(monkeypatch, capsys):
    monkeypatch.delenv("DW_CONTROLLER_MODEL", raising=False)
    assert ve.main([]) == 2
    assert "planned calls: 54-154" in capsys.readouterr().out
    assert ve.main(["--max-calls", "10", "--yes"]) == 2
    assert ve.main(["--plan"]) == 0

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
    for anchor in ["addressed=true", "addressed=false", "no text", "Never butt into", "in ONE message",
                   "never pair an action with stop", "run_skill", "start_goal", "list_skills", "remember",
                   '"place:<name>"', "at=self", "at=player", "never substitute", "references", "read_as",
                   "command.player", "body_status", "unreachable", "resumed", "follow_ended", "vitals_low",
                   "items_dropped", "situation_review", "goal_done", "stuck", "args_help", "previous_review.you_said", "recent_activity",
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
    seen = []
    rep, reads, usages = ve.decide(case, ve.system_prompt("new", ctl), ctl, llm, budget,
                                   on_call=lambda step, u: seen.append(step))
    assert seen == [0, 1] and [u["step"] for u in usages] == [0, 1]  # every call reported (spend ledger)
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
    assert "planned calls: 81-456" in capsys.readouterr().out  # k=3 x 25 cases of the live persona + 6 judge calls
    assert ve.main(["--max-calls", "10", "--yes"]) == 2
    assert ve.main(["--plan"]) == 0



def test_every_model_call_is_one_priced_spend_row(tmp_path):
    """tools/spend.py prices each row with a top-level "usage" by its "model": one row per call, read-loop
    steps and judge calls included, none counted twice (the per-case row carries no top-level usage)."""
    import sys
    sys.path.insert(0, str(ROOT / "tools"))
    import spend
    usage = {"prompt": 1000, "completion": 50, "cached": 0, "cache_write": 0}
    first = [True]

    def step(_msgs, _tools):  # the first case reads first (two calls); the rest answer at once
        if first[0]:
            first[0] = False
            return LLMResponse(tool_calls=[ToolCall("look", {"about": "x"}, "c1")], usage=usage)
        return LLMResponse(content="ok", usage=usage)

    def grade(msgs, _tools):
        ids = [x["id"] for x in json.loads(msgs[-1]["content"])]
        return LLMResponse(content=json.dumps([{"id": i, "human": 4, "silence": 4, "match": 4} for i in ids]), usage=usage)

    ctl_llm = FakeLLM([step] * 20, model="anthropic/claude-haiku-5-5")
    judge_llm = FakeLLM([grade] * 4, model="anthropic/claude-sonnet-5-5")
    log = ve.JsonlLogger(tmp_path / "voice-eval-test.jsonl")
    out = ve.run(["old", "new"], cases()[:3], ctl_llm, judge_llm, tmp_path, log, live_continuation=False)
    rows = [r for r in ve.read_jsonl(log.path) if isinstance(r.get("usage"), dict)]
    assert len(rows) == out["calls"] == 7 + 2  # 6 cases + 1 read-loop step + 2 judge calls
    assert sum(r["kind"] == "voice_llm_call" for r in rows) == 7
    assert all(r.get("model") and r.get("source") == "evals" for r in rows)
    st = spend._FileState(log.path, "evals")
    st.update()
    assert len(st.rows) == 9 and {r["model"] for r in st.rows} == {ctl_llm.model, judge_llm.model}


def test_k_samples_live_continuation_and_spread(tmp_path):
    """Voice agent findings (2026-10-26): k=3 samples per case scored on the k-mean with the spread reported;
    a talk-only first reply gets the live continuation (PROMISE_NOTE on turn 0, TALK_ONLY_NOTE on follow-ups)
    and the score reads what the live loop would say and do; the first reply stays a diagnostic."""
    seen = []

    def step(msgs, _tools):
        seen.append(msgs[-1]["content"])
        if msgs[-1]["content"] in (ve.PROMISE_NOTE, ve.TALK_ONLY_NOTE):  # the continuation acts
            return LLMResponse(tool_calls=[ToolCall("gather", {"resource": "tree", "count": 1}, "c9")])
        return LLMResponse(content="I'll grab some logs")  # a promise with no tool

    def grade(msgs, _tools):
        ids = [x["id"] for x in json.loads(msgs[-1]["content"])]
        return LLMResponse(content=json.dumps([{"id": i, "human": 4, "silence": 4, "match": 5} for i in ids]))

    cs = cases()[:2]
    out = ve.run(["new"], cs, FakeLLM([step] * 40), FakeLLM([grade] * 10), tmp_path, k=3, max_calls=40)
    rows = out["results"]["new"]
    assert len(rows) == 6 and {r["sample"] for r in rows} == {0, 1, 2}
    assert all(r["calls"] and r["first"]["calls"] == [] and r["continuation"]["calls"] for r in rows)
    assert all(r["checks"]["promise_has_tool"] is True and r["first"]["checks"]["promise_has_tool"] is False for r in rows)
    sm = out["summary"]["new"]
    assert sm["cases"] == 2 and sm["samples"] == 6 and sm["first_reply"]["continuation_added_action"] == 6
    assert sm["spread"]["k"] == 3 and sm["spread"]["sd"] == 0.0 and all(r.get("judge") for r in rows)
    assert ve.plan_calls(25, 1, k=3)["total"] == 75 + 6


def test_voice_fixtures_refresh_truncated_bag_and_redraw_heldout(tmp_path):
    """Main's findings c/d: a truncated bag ("+16 more") is re-rendered by the current perception from the last
    logged get_state (so a carried pickaxe shows as Spare gear) and served as the inventory read; the held-out
    redraw is seeded and never picks a case an agent has read."""
    from evals import voice_fixtures as vf
    log = tmp_path / "logs" / "brain-live-20261025-204111-1.jsonl"
    log.parent.mkdir(parents=True)
    st = {"inventory": {"ITEM_Pickaxe_Mithril": 1, "ITEM_Rune_Law": 9999}, "health": 100.0}
    log.write_text(json.dumps({"ts": 1792958600.0, "kind": "bridge_recv", "msg": {"data": st}}) + "\n", encoding="utf-8")
    case = {"id": "h5", "source": "logs/brain-live-20261025-204111-1.jsonl", "at_utc": "20:05:09",
            "context": {"situation": ["Carrying: Law Rune x9999; +16 more"]}}
    assert vf.refresh_truncated([case], root=tmp_path) and case["context"]["situation"] != ["Carrying: Law Rune x9999; +16 more"]
    inv = [r for r in case["reads"] if r["tool"] == "inventory"][0]
    assert inv["result"]["data"]["inventory"]["ITEM_Pickaxe_Mithril"] == 1
    cs = [{"id": f"c{i}"} for i in range(10)]
    a = vf.redraw_heldout(cs, {"c1", "c2"}, 3, seed=7)
    b = vf.redraw_heldout([{"id": f"c{i}"} for i in range(10)], {"c1", "c2"}, 3, seed=7)
    assert a == b and not {"c1", "c2"} & set(a) and sum(c["split"] == "held_out" for c in cs) == 3


def test_a_continuation_lost_to_the_cap_is_flagged_and_followups_use_the_corrected_line(tmp_path):
    def talk(msgs, _tools):
        if msgs[-1]["content"] == ve.TALK_ONLY_NOTE:
            return LLMResponse(content="corrected line")  # new text, no calls: live says the corrected line
        return LLMResponse(content="I'll do it")
    cs = cases()[:1]
    out = ve.run(["new"], cs, FakeLLM([talk] * 5), None, tmp_path, k=1, max_calls=1)  # no room to continue
    assert out["summary"]["new"]["continuation_skipped"] == 1 and out["results"]["new"][0]["continuation"] == {"skipped": "budget"}
    follow = [{**c, "history": [{"tool": "look"}], "note": "go on"} for c in cases()[:1]]
    out = ve.run(["new"], follow, FakeLLM([talk] * 5), None, tmp_path, k=1, max_calls=5)
    assert out["results"]["new"][0]["speech"] == "corrected line"


def test_judge_sees_needs_and_named_targets_and_the_final_pass_mirrors_live(tmp_path):
    """Voice agent fidelity fixes: the judge digest carries the Need line and names each call's target; when
    the read budget runs out, decide() makes the live Controller._final_pass (reads 'not run', FINAL_PASS_NOTE,
    acting tools only)."""
    case = {"id": "x", "context": {"situation": [
        "You: HP 100%", "Need food (7%) -> eat: Redberry Bush (5 m, id fol:BP_RedberryBush_C@1)",
        "Around: Redberry Bush (5 m, id fol:BP_RedberryBush_C@1, gather)"], "command": {"text": "eat something"}},
        "history": [{"tool": "interact", "args": {"target": "fol:BP_RedberryBush_C@1"}, "ok": True}]}
    dg = ve.situation_digest(case)
    assert any(f.startswith("Need food") for f in dg["facts"]) and "-> Redberry Bush" in dg["this_turn_so_far"][0]
    offered = []

    def look_only(msgs, tools):
        offered.append({t["function"]["name"] for t in tools})
        if msgs[-1]["content"] == ve.FINAL_PASS_NOTE:
            return LLMResponse(content="nothing to eat here", tool_calls=[])
        return LLMResponse(tool_calls=[ToolCall("look", {"about": "food"}, f"c{len(offered)}")])
    ctl = ve.make_controller(tmp_path)
    rep, reads, usages = ve.decide(cases()[0], ve.system_prompt("new", ctl), ctl, FakeLLM([look_only] * 5),
                                   ve.Budget(10))
    assert len(usages) == ve.MAX_STEPS + 1 and rep["speech"] == "nothing to eat here"
    assert "look" in offered[0] and "look" not in offered[-1]


def test_the_baseline_measures_the_committed_persona_not_a_working_edit(tmp_path):
    """Main 2026-10-26: the voice agent's A/B edits live in the working tree; a GOAL baseline reads HEAD."""
    import hashlib
    import subprocess
    path, sha = ve.persona_at_ref("HEAD", tmp_path / "p.md")
    head = subprocess.run(["git", "show", "HEAD:brain/persona.md"], cwd=ROOT, capture_output=True, text=True,
                          encoding="utf-8", check=True).stdout
    assert path.read_text(encoding="utf-8") == head and sha == hashlib.sha256(head.encode("utf-8")).hexdigest()
    wpath, _ = ve.persona_at_ref("worktree", tmp_path / "w.md")
    assert wpath == ve.persona_file.DEFAULT_PATH


def test_refresh_status_replays_the_live_broker_and_flags_what_the_log_lacks(tmp_path):
    from evals import voice_fixtures as vf
    log = tmp_path / "logs" / "brain-live-20261025-204111-1.jsonl"
    log.parent.mkdir(parents=True)
    rows = [{"ts": 1792958400.0, "kind": "tool_call", "tool": "gather", "args": {"resource": "ash", "count": 5}},
            {"ts": 1792958430.0, "kind": "tool_result", "tool": "gather", "result": {"ok": True, "reason": None, "data": {}}}]
    log.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    case = {"id": "h1", "source": "logs/brain-live-20261025-204111-1.jsonl", "at_utc": "20:02:00", "context": {}}
    vf.refresh_status([case], root=tmp_path)
    assert any("gather" in ln and "ok" in ln for ln in case["context"]["body_status"])  # what he really did
    assert case["context"]["recent_activity"] == [] and case["fixture_gaps"] == ["recent_activity"]


def test_each_head_run_gets_its_own_worktree_dir(tmp_path):
    a = ve.snapshot_dir(tmp_path, "94b3c5e395b71c19", now=1793000000.0, pid=10)
    b = ve.snapshot_dir(tmp_path, "94b3c5e395b71c19", now=1793000001.0, pid=10)
    c = ve.snapshot_dir(tmp_path, "94b3c5e395b71c19", now=1793000000.0, pid=11)
    assert len({a, b, c}) == 3 and a.parent == tmp_path / "logs" / "tmp" and a.name.startswith("voice-94b3c5e395b7-")

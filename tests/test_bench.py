"""Benchmark harness (evals/bench, design eval-benchmark.md rev 2): spec lint, observer + sensor_mismatch, leaves,
T0/T1 generation from data, controls as lint on the mock, the companion loop, reports, the proposer, held-out split,
spend preflight. All offline: BenchWorld + FakeLLM."""
from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from brain import predicates as P
from brain.llm import FakeLLM, LLMResponse, ToolCall
from evals.bench import CANARY, generator, leaves, report, runner
from evals.bench.agents import CONTROLS, NEGATIVE
from evals.bench.observer import ObservedGame, evidence_ctx
from evals.bench.spec import Case, case_hash, lint
from evals.bench.world import BenchWorld, load_spell_data

SPELLS, CATALOG = load_spell_data()


def mk(**kw) -> Case:
    base = dict(id="c1", tier="T0", family="spell_cast", chat=[{"at_s": 0, "text": "hey, use Windstep for me"}],
                success={"spell_effect": {"spell": "USD_Windstep"}},
                fixtures={"setup": [{"verb": "unlock", "spell": "USD_Windstep"}, {"verb": "grant_runes", "runes": {"Air": 20}}]},
                oracle={"mock": [{"tool": "cast", "args": {"spell": "Windstep"}}]}, controls={"na": {"partial": "one step"}})
    base.update(kw)
    return Case.model_validate(base)


# ------------------------------------------------------------------ spec


def test_lint_rejects_tool_identifiers_asset_ids_and_forbidden_terms():
    assert lint(mk()) == []
    assert any("tool name" in p for p in lint(mk(chat=[{"text": "please go_to the base"}])))
    assert any("asset id" in p for p in lint(mk(chat=[{"text": "cast USD_Windstep now"}])))
    assert any("tool call syntax" in p for p in lint(mk(chat=[{"text": "cast(Windstep)"}])))
    assert any("forbidden term" in p for p in lint(mk(chat=[{"text": "can you cast windstep"}], forbid_terms=["Windstep"])))
    assert lint(mk(chat=[{"text": "follow me and drop the logs"}])) == []  # plain English verbs are player language


def test_lint_requires_a_delivery_predicate_when_the_player_asks_for_it():
    c = mk(chat=[{"text": "can you get me 50 coal"}], success={"gained": {"item": "Coal", "at_least": 50}})
    assert any("delivery" in p for p in lint(c))


def test_case_hash_changes_with_scoring_inputs_not_status():
    a, b = mk(), mk(status="draft")
    assert case_hash(a) == case_hash(b)
    assert case_hash(a) != case_hash(mk(success={"spell_effect": {"spell": "USD_TempestShield"}}))
    assert mk().canary == CANARY


# ------------------------------------------------------------------ observer + leaves


def cast_once(world: BenchWorld, spell="Windstep", target=None) -> dict:
    g = ObservedGame(world, world.probe, clock=lambda: world.time)
    g.start()
    g.call("cast", {"spell": spell, **({"target": target} if target else {})})
    g.finish()
    st = runner.probe_state(g.rec.probe1)
    ctx = evidence_ctx(g.rec, runner.probe_state(g.rec.probe0), world.spell_data, world.time)
    return {"g": g, "ctx": ctx, "state": st}


def windstep_world(**setup) -> BenchWorld:
    w = BenchWorld(SPELLS, CATALOG)
    w.setup("unlock", spell="USD_Windstep")
    w.setup("grant_runes", runes={"Air": 20})
    for k, v in setup.items():
        w.setup(k, **v)
    return w


def ev(p, out):
    return P.evaluate(P.validate(p), out["state"], out["ctx"])


def test_spell_effect_passes_on_probe_evidence():
    out = cast_once(windstep_world())
    r = ev({"spell_effect": {"spell": "USD_Windstep"}}, out)
    assert r.passed is True and "tag_added" in r.detail and out["ctx"]["mismatches"] == []


@pytest.mark.parametrize("mode", ["claim_runes", "hide_runes", "claim_effect"])
def test_a_lying_body_is_a_sensor_mismatch_never_a_pass(mode):
    out = cast_once(windstep_world(lie={"mode": mode}))
    r = ev({"spell_effect": {"spell": "USD_Windstep"}}, out)
    assert r.passed is False and "sensor_mismatch" in r.detail and out["ctx"]["mismatches"]


def test_generic_evidence_is_rejected():
    good, bad = leaves.specific_effects("USD_Windstep", SPELLS)
    assert {e.get("class_contains") for e in bad} >= {"DominionStatusEffect"}
    assert all(e.get("class_contains") not in leaves.GENERIC_GE for e in good)
    # a spell whose only proof is a base GE class can't pass: unverifiable
    spells = copy.deepcopy(SPELLS)
    spells["USD_Windstep"]["proof"]["effect"] = [{"kind": "ge_added", "class_contains": "DominionStatusEffect"}]
    w = BenchWorld(spells, CATALOG)
    w.setup("unlock", spell="USD_Windstep")
    w.setup("grant_runes", runes={"Air": 20})
    out = cast_once(w)
    assert ev({"spell_effect": {"spell": "USD_Windstep"}}, out).passed is None


def test_runes_alone_never_pass():
    spells = copy.deepcopy(SPELLS)
    spells["USD_Windstep"]["proof"]["effect"] = []
    w = BenchWorld(spells, CATALOG)
    w.setup("unlock", spell="USD_Windstep")
    w.setup("grant_runes", runes={"Air": 20})
    out = cast_once(w)
    out["ctx"]["spells"] = spells
    assert ev({"spell_effect": {"spell": "USD_Windstep"}}, out).passed is not True


def test_not_cast_and_wrong_spell_fail():
    w = windstep_world()
    w.setup("unlock", spell="USD_TempestShield")
    w.setup("grant_runes", runes={"Air": 40})
    out = cast_once(w, "Tempest Shield")
    assert ev({"spell_effect": {"spell": "USD_Windstep"}}, out).passed is False


def test_travel_displacement_must_come_from_the_cast_call():
    w = BenchWorld(SPELLS, CATALOG)
    w.setup("unlock", spell="USD_PhaseDash")
    w.setup("grant_runes", runes={"Astral": 20, "Air": 40})
    g = ObservedGame(w, w.probe, clock=lambda: w.time)
    g.start()
    g.call("go_to", {"target": [15.0, 0.0, 0.0]})  # walking far first is not the dash
    g.finish()
    ctx = evidence_ctx(g.rec, runner.probe_state(g.rec.probe0), SPELLS, w.time)
    assert P.evaluate(P.validate({"spell_effect": {"spell": "USD_PhaseDash"}}), runner.probe_state(g.rec.probe1), ctx).passed is False


# ------------------------------------------------------------------ generation from data


def test_t0_one_case_per_manifest_spell_and_explicit_na():
    cases, na = generator.t0_cases(SPELLS, CATALOG)
    den, na2 = generator.manifest_spells(SPELLS)
    assert [c.tags["spell"] for c in cases] == den and na == na2
    assert len(cases) + len(na) == len(SPELLS)
    assert all(lint(c) == [] for c in cases)
    assert all(c.success == {"spell_effect": {"spell": c.tags["spell"]}} for c in cases)


def test_a_new_spell_in_the_data_gets_a_case_with_no_code_change(monkeypatch):
    spells = copy.deepcopy(SPELLS)
    spells["USD_TestNewSpell"] = {**copy.deepcopy(SPELLS["USD_Windstep"]), "name": "Test Nova", "status": "unlocked"}
    spells["USD_TestNewSpell"]["proof"]["effect"] = [{"kind": "tag_added", "tag": "Player.Spell.TestNova", "observable": "cast_reply"}]
    monkeypatch.setattr(leaves, "default_spells", lambda: spells)  # = the regenerated data file
    cases, _ = generator.t0_cases(spells, CATALOG)
    c = next(c for c in cases if c.tags["spell"] == "USD_TestNewSpell")
    w = BenchWorld(spells, CATALOG)
    for s in c.fixtures.setup:
        s = dict(s)
        w.setup(s.pop("verb"), **{k: v for k, v in s.items() if k != "as"})
    out = cast_once(w, "Test Nova")
    out["ctx"]["spells"] = spells
    assert ev(c.success, out).passed is True


def test_use_cases_never_name_the_spell():
    cases = generator.use_cases(SPELLS, generator.DEFAULT_PHRASINGS)
    assert cases
    for c in cases:
        name = SPELLS[c.tags["spell"]]["name"]
        assert name in c.forbid_terms and "cast" in c.forbid_terms
        assert lint(c) == [], (c.id, lint(c))


# ------------------------------------------------------------------ controls (lint on the mock)


@pytest.fixture(scope="module")
def suite():
    t0, _ = generator.t0_cases(SPELLS, CATALOG)
    use = [c for c in generator.use_cases(SPELLS, generator.DEFAULT_PHRASINGS) if c.status == "suite"]
    return t0 + use


def test_no_negative_control_ever_passes(suite, tmp_path):
    res = runner.lint_controls(suite, tmp_path / "lint", log=lambda *_: None)
    leaks = [(cid, k, v["result"]) for cid, rec in res.items() for k, v in rec["controls"].items()
             if k in NEGATIVE and v["result"] == "pass"]
    assert not leaks, leaks
    oracle_bad = [(cid, rec["controls"]["oracle"]) for cid, rec in res.items()
                  if rec["controls"]["oracle"]["result"] not in ("pass", "unverifiable")]
    assert not oracle_bad, oracle_bad
    assert sum(rec["valid_lint"] for rec in res.values()) >= 20  # the observable proofs
    assert any(rec["valid_lint"] for cid, rec in res.items() if cid.startswith("t1_use_"))


def test_a_weak_predicate_is_caught_by_a_control(tmp_path):
    """A gained-items predicate for a 'split the log' use case passes the alt_means control (hand-collected logs):
    the lint flags it, unlike the purpose leaf which demands the spell."""
    use = next(c for c in generator.use_cases(SPELLS, generator.DEFAULT_PHRASINGS) if c.tags.get("purpose") == "split_felled_log")
    weak = use.model_copy(update={"success": use.success["purpose"]["success"], "id": "weak"})
    res = runner.lint_controls([weak], tmp_path / "lint", log=lambda *_: None)
    assert res["weak"]["controls"]["alt_means"]["result"] == "pass" and not res["weak"]["valid_lint"]


# ------------------------------------------------------------------ the companion on the mock


def scripted(*turns):
    llm = FakeLLM(model="fake/controller")
    for t in turns:
        llm.push(t)
    llm.push(*[LLMResponse(content="") for _ in range(10)])
    return llm


def test_companion_casting_passes_with_latency_and_trace(tmp_path):
    c = mk()
    llm = scripted(LLMResponse(content="on it", tool_calls=[ToolCall(id="t1", name="cast", arguments={"spell": "Windstep"})]))
    r = runner.run_case_mock(c, "companion", tmp_path / "w", llm, FakeLLM(model="fake/planner"))
    assert r.result == "pass", (r.detail, r.failures)
    assert r.latency_s is not None and r.latency_s >= 0 and r.calls.get("haiku", 0) >= 1
    t = json.loads(Path(r.trace).read_text(encoding="utf-8"))
    assert t["observations"][0]["tool"] == "cast" and r.trace_sha256


def test_companion_that_only_talks_fails(tmp_path):
    llm = scripted(LLMResponse(content="Done, cast it!"))
    r = runner.run_case_mock(mk(), "companion", tmp_path / "w", llm, FakeLLM(model="fake/planner"))
    assert r.result == "fail"


def test_hint_ladder_after_idle_and_budget_cap(tmp_path):
    c = mk(limits={"idle_s": 10, "hints_max": 1, "sim_s": 120}, hints={"ladder": ["any luck? the wind one"]})
    llm = scripted(LLMResponse(content="hmm"), LLMResponse(content=""),  # the reply, then its no-promise check turn
                   LLMResponse(content="ah", tool_calls=[ToolCall(id="t", name="cast", arguments={"spell": "Windstep"})]))
    r = runner.run_case_mock(c, "companion", tmp_path / "w", llm, FakeLLM(model="fake/planner"))
    assert r.hints_used == 1 and r.result == "pass"
    capped = mk(limits={"model_calls": {"haiku": 1}, "idle_s": 10, "hints_max": 1}, hints={"ladder": ["nudge"]})
    r = runner.run_case_mock(capped, "companion", tmp_path / "w2", scripted(LLMResponse(content="hmm"), LLMResponse(content="x")),
                             FakeLLM(model="fake/planner"))
    assert r.result == "error" and r.reason == "budget"


def test_unmet_precondition_is_a_skip(tmp_path):
    c = mk(fixtures={"requires": [{"have": {"item": "ITEM_Rune_Law", "at_least": 5}}]})
    assert runner.run_case_mock(c, "companion", tmp_path / "w", scripted()).result == "skip"


def test_write_run_and_scoreboard_row_are_hash_bound(tmp_path):
    c = mk()
    rid, d = "r_test", tmp_path / "run"
    d.mkdir()
    res = runner.run_case_mock(c, "oracle", d / "w")
    out = runner.write_run(rid, d, "mock", "oracle", [res], [c], False, scoreboard=tmp_path / "sb.jsonl", extra={"llm": "fake"})
    row = json.loads((tmp_path / "sb.jsonl").read_text(encoding="utf-8"))
    assert row["cases_sha256"] == runner.hashes.sha256_file(d / "cases.jsonl") and row["target"] == "mock"
    assert "lint only" in (d / "report.md").read_text(encoding="utf-8")


# ------------------------------------------------------------------ reports


def test_wilson_and_mcnemar():
    lo, hi = report.wilson(20, 20)
    assert round(lo, 3) == 0.839 and hi == 1.0
    lo, _ = report.wilson(0, 0)
    assert lo == 0.0
    m = report.mcnemar({"a": False, "b": False, "c": True}, {"a": True, "b": True, "c": True})
    assert m["improved"] == 2 and m["regressed"] == 0 and m["diff_pct"] == 66.7


def test_report_counts_only_pass_and_keeps_heldout_aggregate():
    rows = [{"case_id": "a", "family": "spell_cast", "result": "pass"}, {"case_id": "b", "family": "spell_cast", "result": "unverifiable"},
            {"case_id": "h", "family": "spell_cast", "result": "pass", "heldout": True}]
    rep = report.summarize({"run_id": "x"}, rows)
    assert rep["families"]["spell_cast"]["passed"] == 1 and rep["families"]["spell_cast"]["n"] == 2
    assert "h" not in json.dumps(rep["matrix"]) and rep["heldout"]["aggregate"]["n"] == 1


# ------------------------------------------------------------------ the proposer and the split


def test_propose_validates_repairs_audits_and_lints():
    good = {"id": "g1", "tier": "T1", "family": "gather", "chat": "grab me a few ash logs would you",
            "success": {"all": [{"lost": {"item": "Ash Logs", "at_least": 3}},
                                {"on_ground": {"item": "Ash Logs", "at_least": 3, "player": "Tester"}}]}}
    bad = {"id": "b1", "tier": "T1", "family": "gather", "chat": "get some wood", "success": {"have": {"item": "Ash Logz", "at_least": 3}}}
    toolish = {"id": "t1", "tier": "T1", "family": "gather", "chat": "please go_to the trees",
               "success": {"have": {"item": "Ash Logs", "at_least": 1}}}
    weak = {"id": "w1", "tier": "T1", "family": "gather", "chat": "chop me a tree", "success": {"have": {"item": "Ash Logs", "at_least": 1}}}
    llm = FakeLLM([json.dumps({"cases": [good, bad, toolish, weak]}),
                   json.dumps({"cases": [{**bad, "success": {"have": {"item": "Ash Logs", "at_least": 3}}}]}),
                   json.dumps({"verdicts": [{"id": "w1", "ok": False, "problems": ["no delivery"]}]})])
    cases, rejects = generator.propose(llm, "T1", 4, "facts", ["seen_case_1"])
    ids = {c.id for c in cases}
    assert "g1" in ids and "b1" in ids and "w1" not in ids and "t1" not in ids
    assert {r["id"] for r in rejects} >= {"w1", "t1"} and len(llm.calls) == 3
    assert all(c.status == "candidate" for c in cases)


def test_heldout_split_is_stratified_and_deterministic():
    cs = [mk(id=f"c{i}", family=f) for i, f in enumerate(["spell_cast"] * 10 + ["gather"] * 10)]
    s1, h1 = generator.split_heldout([c.model_copy() for c in cs], "sha1")
    s2, h2 = generator.split_heldout([c.model_copy() for c in cs], "sha1")
    assert [c.id for c in h1] == [c.id for c in h2] and len(h1) == 6
    assert sum(c.family == "gather" for c in h1) == 3 and all(c.heldout for c in h1)
    assert generator.shingle_dupe("can you get me fifty coal please", "can you get me fifty coal now")


# ------------------------------------------------------------------ spend preflight (fail closed)


def test_spend_preflight_fails_closed(monkeypatch):
    import subprocess

    class P_:
        def __init__(self, out):
            self.stdout = out
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: P_("not json"))
    ok, why = runner.spend_preflight({"haiku": 10}, {"haiku": "anthropic/claude-haiku-5-5"})
    assert not ok and "cannot read" in why
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: P_(json.dumps({"state": "cap", "spent_usd": 10, "cap_usd": 10})))
    assert not runner.spend_preflight({"haiku": 10}, {"haiku": "anthropic/claude-haiku-5-5"})[0]
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: P_(json.dumps({"state": "ok", "spent_usd": 9.99, "cap_usd": 10})))
    ok, why = runner.spend_preflight({"haiku": 1000}, {"haiku": "anthropic/claude-haiku-5-5"})
    assert not ok and "worst case" in why
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: P_(json.dumps({"state": "ok", "spent_usd": 1.0, "cap_usd": 10})))
    assert runner.spend_preflight({"haiku": 10}, {"haiku": "anthropic/claude-haiku-5-5"})[0]


def test_kills_come_from_the_referee_not_the_body_claim():
    """Review C3: a referee death counts as HIS kill only when attributed (by == self); unattributed deaths are a
    perception gap; the body's own combat_end claim is ignored when the referee covers deaths."""
    from evals.bench.observer import Record
    p = P.validate({"killed": {"kind": "Goblin Runt", "kind_id": "BP_AI_RuntGoblin_Character_C", "at_least": 1}})
    body_claim = [{"kind": "combat_end", "outcome": "killed", "target": "Goblin Runt", "target_class": "BP_AI_RuntGoblin_Character_C"}]
    mine = Record(referee=[{"kind": "death", "who": "g1", "kind_id": "BP_AI_RuntGoblin_Character_C", "by": "self"}], episodes=body_claim)
    other = Record(referee=[{"kind": "death", "who": "g1", "kind_id": "BP_AI_RuntGoblin_Character_C", "by": "BP_AI_Wolf_C_3"}],
                   episodes=body_claim)
    unattributed = Record(referee=[{"kind": "death", "who": "g1", "kind_id": "BP_AI_RuntGoblin_Character_C"}], episodes=body_claim)
    ev = lambda rec: P.evaluate(p, {}, evidence_ctx(rec, {}, SPELLS, 0.0, referee_supports={"death"})).passed  # noqa: E731
    assert ev(mine) is True and ev(other) is False and ev(unattributed) is None


def test_goal_drafts_validate_lint_and_keep_method_words_out_of_scored_chat():
    from evals.bench import goal_drafts
    groups = [goal_drafts.long_tasks(), goal_drafts.combat_basics(), goal_drafts.tactics_and_knowledge(),
              goal_drafts.every_skill(), goal_drafts.capstone()]
    cases = [c for g in groups for c in g]
    assert len({c.id for c in cases}) == len(cases)
    for c in cases:
        assert lint(c) == [], (c.id, lint(c))
        for p in [c.success, *c.guards]:
            assert P.errors(p) == [], (c.id, P.errors(p))
        assert c.oracle.get("dev"), c.id  # a dev positive control is named for every GOAL case
    mining = next(c for c in cases if c.id == "goal_mining_run_home_chest")
    assert not any(w in mining.chat[0].text.lower() for w in ("copper", "tin", "iron", "lodestone", "wiki"))
    assert not any(c.fixtures.player_body for c in cases)  # Luis 2026-10-26: nothing is delivered to a player
    assert all(c.skill in goal_drafts.skill_names() for c in cases if c.family == "skill_train")


def test_main_variants_grant_no_items_and_quick_twins_are_tagged():
    """Luis 2026-10-26: combat basics, tactics and long tasks make him obtain prerequisites himself; grants only in
    `_quick` twins (variant quick, tag quick), which goal_check drops."""
    from evals.bench import goal_drafts
    grant_verbs = {"grant", "grant_runes", "grant_to_ground", "ground_item"}
    cases = goal_drafts.long_tasks() + goal_drafts.combat_basics() + goal_drafts.tactics_and_knowledge() + goal_drafts.capstone()
    for c in cases:
        verbs = {s.get("verb") for s in c.fixtures.setup}
        if c.variant == "quick":
            assert c.id.endswith("_quick") and (c.tags or {}).get("quick") is True, c.id
        elif c.family in ("combat_basic", "tactics_prep", "tactics_trend", "tactics_telegraph", "long_task", "capstone",
                          "capstone_stage"):
            assert not (verbs & grant_verbs), (c.id, verbs)
    ids = {c.id for c in cases}
    assert {"goal_basic_parry_quick", "goal_basic_disengage_heal_quick", "capstone_slay_velgar_solo_quick"} <= ids
    assert all(c.id[:-len("_quick")] in ids for c in cases if c.variant == "quick")

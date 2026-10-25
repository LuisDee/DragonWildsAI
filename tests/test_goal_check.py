"""tools/goal_check.py: MET / NOT MET / NO DATA per GOAL target, strictness rules, the exact verdict line."""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from tools import goal_check as gc

ROOT = Path(__file__).resolve().parents[1]
NOW = "2026-10-27T12:00:00Z"
FRESH = "2026-10-27T10:00:00Z"
OLD = "2026-10-25T10:00:00Z"
TARGETS = json.loads((ROOT / "docs" / "goal_targets.json").read_text(encoding="utf-8"))
FAMILIES = ("spell_cast", "spell_use", "craft", "combat", "adversarial", "tactics_prep")


def valid_controls(*hashes: str, positive_target: str = "dev") -> dict:
    return {h: {"positive": {"result": "pass", "target": positive_target}, "do_nothing": {"result": "fail"},
                "claims_only": {"result": "fail"}} for h in hashes}


def case(cid: str, family: str, result: str = "pass", **kw) -> dict:
    return {"id": cid, "case_hash": f"h_{cid}", "family": family, "tier": "T0", "heldout": False, "result": result,
            "hints": 0, **kw}


def all_met_cases() -> list[dict]:
    out = [case(f"{f}_{i}", f) for f in FAMILIES for i in range(3)]
    out += [case(f"{f}_held", f, heldout=True) for f in FAMILIES]
    out += [case(f"lt_{t}", "long_task", long_task=t) for t in TARGETS["long_tasks"]["required"]]
    out += [case(f"basic_{b}", "combat_basic", basic=b) for b in TARGETS["combat_basics_live_proven"]]
    return out


METRICS = {"ranged_hit_rate_15m_moving_pct": {"value": 65, "n": 40},
           "efficiency_vs_baseline_pct": {"value": 80, "n": 3},
           "telegraph_dodge_success_pct": {"value": 75, "n": 12},
           "damage_taken_trend": {"fights": 5, "slope": -12.5, "decreasing": True},
           "knowledge_lookup_when_needed_pct": {"value": 85, "n": 10},
           "knowledge_fact_correct_pct": {"value": 95, "n": 10},
           "knowledge_needless_lookup_pct": {"value": 10, "n": 10}}


def bench_row(run_id: str, target: str, at: str = FRESH, cases=None, metrics=None) -> dict:
    return {"schema": "dw_scoreboard/1", "kind": "bench", "run_id": run_id, "at": at, "target": target,
            "cases": all_met_cases() if cases is None else cases, "metrics": METRICS if metrics is None else metrics}


OBS = {"schema": "dw_obs_metrics/1", "generated_at": FRESH, "window": {"since": OLD, "until": FRESH}, "source": "live",
       "hours_observed": 3.0, "latency": {"chat_to_first_action_s": {"p50": 1.9, "p90": 3.2, "n": 40}},
       "anomalies_per_hour": {"stat_narration": 0, "talk_without_action": 0, "stall_over_30s": 0},
       "stability": {"longest_run_without_crash_h": 2.5, "crashes": 0, "stalls_over_30s": 0},
       "deaths": {"starvation": 0}, "voice": {"score": None, "n": 0, "source": None}}
VOICE = {"kind": "voice", "run_id": "voice_1", "at": FRESH, "score": 0.86, "n": 25}


def data(rows=None, validity=None, obs=OBS, targets=TARGETS) -> gc.Data:
    rows = [bench_row("dev_1", "dev"), bench_row("live_1", "live"), VOICE] if rows is None else rows
    if validity is None:
        validity = valid_controls(*{c["case_hash"] for r in rows for c in r.get("cases") or []})
    return gc.Data(targets, rows, validity, obs, gc.parse_ts(NOW))


def check_all(d: gc.Data) -> tuple[list[gc.Row], dict]:
    rows, vs = [], {}
    for m in gc.milestones(d.targets):
        r, vs = gc.check(d, m)
        rows += r
    return rows, vs


def by_name(rows: list[gc.Row]) -> dict[str, gc.Row]:
    return {r.target: r for r in rows}


def test_everything_measured_fresh_valid_and_live_confirmed_is_goal_met():
    rows, vs = check_all(data())
    bad = [r.line() for r in rows if r.status != gc.MET]
    assert not bad, "\n".join(bad)
    assert vs["valid"] == vs["cases"] > 0


def test_no_data_at_all_is_no_data_everywhere_and_not_met():
    rows, _ = check_all(data(rows=[], obs=None))
    assert {r.status for r in rows} == {gc.NO_DATA}


def test_stale_benchmark_rows_are_not_met():
    rows, _ = check_all(data(rows=[bench_row("dev_old", "dev", at=OLD), bench_row("live_old", "live", at=OLD), VOICE]))
    r = by_name(rows)["spells_effect_coverage_pct"]
    assert r.status == gc.NOT_MET and "stale" in r.note and r.source == "dev_old" and r.age_h == pytest.approx(50.0)


def test_mock_only_results_never_count():
    rows, _ = check_all(data(rows=[bench_row("mock_1", "mock"), VOICE]))
    r = by_name(rows)["spell_use_cases_pct"]
    assert r.status == gc.NOT_MET and "mock" in r.note


def test_family_target_needs_a_live_confirmation():
    rows, _ = check_all(data(rows=[bench_row("dev_1", "dev"), VOICE]))
    r = by_name(rows)["craft_from_scratch_pct"]
    assert r.status == gc.NOT_MET and r.note == "no live confirmation" and r.value.startswith("100.0%")


def test_below_threshold_is_not_met_with_the_measured_value():
    cases = [case(f"s{i}", "spell_cast", "pass" if i < 9 else "fail") for i in range(10)]
    rows, _ = check_all(data(rows=[bench_row("dev_1", "dev", cases=cases), bench_row("live_1", "live"), VOICE]))
    r = by_name(rows)["spells_effect_coverage_pct"]
    assert r.status == gc.NOT_MET and r.value == "90.0% (9/10)" and r.want == ">= 95%"


def test_unverifiable_counts_against_and_skip_is_not_counted():
    cases = [case("a", "spell_cast"), case("b", "spell_cast", "unverifiable"), case("c", "spell_cast", "skip")]
    rows, _ = check_all(data(rows=[bench_row("dev_1", "dev", cases=cases), bench_row("live_1", "live"), VOICE]))
    assert by_name(rows)["spells_effect_coverage_pct"].value == "50.0% (1/2)"


@pytest.mark.parametrize("controls,reason", [
    ({"positive": {"result": "pass", "target": "mock"}, "do_nothing": {"result": "fail"},
      "claims_only": {"result": "fail"}}, "positive control only on the mock"),
    ({"positive": {"result": "pass", "target": "dev"}, "do_nothing": {"result": "pass"},
      "claims_only": {"result": "fail"}}, "negative control do_nothing did not fail"),
    ({"positive": {"result": "pass", "target": "dev"}, "do_nothing": {"result": "fail"},
      "claims_only": {"result": "unverifiable"}}, "negative control claims_only did not fail"),
    ({"positive": {"result": "fail", "target": "dev"}, "do_nothing": {"result": "fail"},
      "claims_only": {"result": "fail"}}, "positive control did not pass"),
    (None, "no controls run"),
])
def test_invalid_cases_are_excluded_and_reported(controls, reason):
    rows_in = [bench_row("dev_1", "dev"), bench_row("live_1", "live"), VOICE]
    validity = valid_controls(*{c["case_hash"] for r in rows_in for c in r.get("cases") or []})
    for c in all_met_cases():
        if c["family"] == "spell_cast":
            if controls is None:
                validity.pop(c["case_hash"])
            else:
                validity[c["case_hash"]] = controls
    rows, vs = check_all(data(rows=rows_in, validity=validity))
    assert by_name(rows)["spells_effect_coverage_pct"].status != gc.MET
    assert vs["invalid_reasons"] == {reason: 4} and vs["valid"] == vs["cases"] - 4


def test_long_task_needs_dev_pass_within_hint_limit_and_live():
    lt = TARGETS["long_tasks"]["required"][0]
    name = f"long_tasks:{lt}"
    two_hints = [case("lt", "long_task", long_task=lt, hints=2)]
    rows, _ = check_all(data(rows=[bench_row("dev_1", "dev", cases=two_hints),
                                  bench_row("live_1", "live", cases=[case("lt", "long_task", long_task=lt)]), VOICE]))
    assert by_name(rows)[name].status == gc.NOT_MET and "hint" in by_name(rows)[name].note
    dev_only = [case("lt", "long_task", long_task=lt, hints=1)]
    rows, _ = check_all(data(rows=[bench_row("dev_1", "dev", cases=dev_only), VOICE]))
    assert by_name(rows)[name].status == gc.NOT_MET and by_name(rows)[name].note == "no live confirmation"
    rows, _ = check_all(data(rows=[bench_row("dev_1", "dev", cases=dev_only),
                                  bench_row("live_1", "live", cases=[case("lt2", "long_task", long_task=lt)]), VOICE]))
    assert by_name(rows)[name].status == gc.MET


def test_combat_basics_must_be_proven_live():
    rows, _ = check_all(data(rows=[bench_row("dev_1", "dev"), VOICE]))
    assert by_name(rows)["combat_basics_live_proven:parry"].status == gc.NO_DATA


def test_heldout_gap_measured_on_valid_cases():
    cases = [case(f"s{i}", "spell_cast") for i in range(10)] + \
            [case(f"h{i}", "spell_cast", "pass" if i < 2 else "fail", heldout=True) for i in range(4)]
    rows, _ = check_all(data(rows=[bench_row("dev_1", "dev", cases=cases), VOICE]))
    r = by_name(rows)["heldout_gap_max_points"]
    assert r.status == gc.NOT_MET and r.value.startswith("50.0 pts")


def test_obs_metrics_thresholds_staleness_and_no_data():
    slow = json.loads(json.dumps(OBS))
    slow["latency"]["chat_to_first_action_s"].update(p50=3.1)
    rows = by_name(check_all(data(obs=slow))[0])
    assert rows["latency_chat_to_action_p50_s"].status == gc.NOT_MET
    assert rows["latency_chat_to_action_p90_s"].status == gc.MET
    old = json.loads(json.dumps(OBS))
    old["window"]["until"] = old["generated_at"] = OLD
    rows = by_name(check_all(data(obs=old))[0])
    assert rows["stability_hours_without_crash"].status == gc.NOT_MET and "stale" in rows["stability_hours_without_crash"].note
    empty = json.loads(json.dumps(OBS))
    empty["latency"]["chat_to_first_action_s"] = {"p50": None, "p90": None, "n": 0}
    empty["hours_observed"] = 0
    rows = by_name(check_all(data(obs=empty))[0])
    assert rows["latency_chat_to_action_p50_s"].status == gc.NO_DATA
    assert rows["anomalies_per_hour_max:stat_narration"].status == gc.NO_DATA


def test_voice_score_from_scoreboard_voice_rows():
    rows = by_name(check_all(data(rows=[bench_row("dev_1", "dev"), bench_row("live_1", "live"),
                                       {**VOICE, "score": 0.7}]))[0])
    assert rows["voice_score_min"].status == gc.NOT_MET and rows["voice_score_min"].value.startswith("0.70")


def test_milestone_selects_its_targets():
    rows, _ = gc.check(data(), "M3")
    assert [r.target for r in rows] == TARGETS["milestones"]["M3"]
    m1 = [r.target for r in gc.check(data(), "M1")[0]]
    assert "spells_effect_coverage_pct" in m1 and "combat_basics_live_proven:parry" in m1 and "long_tasks" not in m1
    with pytest.raises(SystemExit):
        gc.check(data(), "M9")


def write_inputs(tmp_path, rows, obs=OBS) -> list[str]:
    sb = tmp_path / "scoreboard.jsonl"
    sb.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    val = tmp_path / "validity.json"
    val.write_text(json.dumps(valid_controls(*{c["case_hash"] for r in rows for c in r.get("cases") or []})),
                   encoding="utf-8")
    ob = tmp_path / "obs.json"
    ob.write_text(json.dumps(obs), encoding="utf-8")
    return ["--scoreboard", str(sb), "--validity", str(val), "--obs-json", str(ob), "--history",
            str(tmp_path / "goal_checks.jsonl")]


def run(capsys, args: list[str], now: str) -> tuple[int, list[str]]:
    code = gc.main(args + ["--now", now])
    return code, capsys.readouterr().out.strip().splitlines()


def full_rows(tag: str, at: str = FRESH) -> list[dict]:
    return [bench_row(f"dev_{tag}", "dev", at=at), bench_row(f"live_{tag}", "live", at=at),
            {**VOICE, "run_id": f"voice_{tag}", "at": at}]


def test_all_met_once_is_pending_confirmation_then_met_after_a_second_fresh_run(tmp_path, capsys):
    args = write_inputs(tmp_path, full_rows("a", at="2026-10-27T09:00:00Z"))
    code, out = run(capsys, args + ["--all"], "2026-10-27T10:00:00Z")
    sizes = {m: len(gc.check(data(), m)[0]) for m in gc.milestones(TARGETS)}
    assert code == 1 and out[-1] == "GOAL NOT MET (" + ", ".join(f"{m} {n}/{n}" for m, n in sizes.items()) + ", focus=M1)"
    assert any("confirmation: PENDING" in x for x in out) and out[-2].startswith("Predicate validity: ")
    code, out = run(capsys, args + ["--all"], "2026-10-27T10:30:00Z")   # the same data again: no confirmation
    assert code == 1 and out[-1].startswith("GOAL NOT MET (")
    args = write_inputs(tmp_path, full_rows("a", at="2026-10-27T09:00:00Z") + full_rows("b", at="2026-10-27T11:00:00Z"))
    code, out = run(capsys, args + ["--all"], "2026-10-27T12:00:00Z")   # a re-run with new data: confirmed
    assert code == 0 and out[-1] == "GOAL MET"


def test_milestone_lines_are_exact(tmp_path, capsys):
    args = write_inputs(tmp_path, full_rows("a", at="2026-10-27T09:00:00Z"))
    code, out = run(capsys, args + ["--milestone", "M3"], "2026-10-27T10:00:00Z")
    assert code == 1 and out[-1] == "MILESTONE M3 NOT MET (2/2)"   # all met, awaiting the confirmation re-run
    args = write_inputs(tmp_path, full_rows("a", at="2026-10-27T09:00:00Z") + full_rows("b", at="2026-10-27T11:00:00Z"))
    code, out = run(capsys, args + ["--milestone", "M3"], "2026-10-27T12:00:00Z")
    assert code == 0 and out[-1] == "MILESTONE M3 MET"
    args = write_inputs(tmp_path, [bench_row("dev_old", "dev", at=OLD)])
    code, out = run(capsys, args + ["--milestone", "M1"], NOW)
    assert code == 1 and re.fullmatch(rf"MILESTONE M1 NOT MET \(\d+/{len(gc.check(data(), 'M1')[0])}\)", out[-1])


def obs_at(until: str, p50: float = 1.9) -> dict:
    o = json.loads(json.dumps(OBS))
    o["generated_at"] = o["window"]["until"] = until
    o["latency"]["chat_to_first_action_s"]["p50"] = p50
    return o


def test_a_failed_check_in_between_breaks_the_confirmation(tmp_path, capsys):
    rows = full_rows("a", at="2026-10-27T08:00:00Z")
    code, out = run(capsys, write_inputs(tmp_path, rows, obs_at("2026-10-27T08:10:00Z")) + ["--milestone", "M1"],
                    "2026-10-27T08:30:00Z")
    assert code == 1 and "confirmation: PENDING" in " ".join(out)          # all met, pending
    code, out = run(capsys, write_inputs(tmp_path, rows, obs_at("2026-10-27T09:10:00Z", p50=3.1)) + ["--milestone", "M1"],
                    "2026-10-27T09:30:00Z")
    assert code == 1 and "confirmation" not in " ".join(out)              # new data, latency missed
    args = write_inputs(tmp_path, rows, obs_at("2026-10-27T10:10:00Z"))
    code, out = run(capsys, args + ["--milestone", "M1"], "2026-10-27T10:30:00Z")
    assert code == 1                                                        # previous check failed: not consecutive
    code, out = run(capsys, write_inputs(tmp_path, rows, obs_at("2026-10-27T11:10:00Z")) + ["--milestone", "M1"],
                    "2026-10-27T11:30:00Z")
    assert code == 0 and out[-1] == "MILESTONE M1 MET"                      # two consecutive passing checks
    hist = gc.read_jsonl(Path(args[args.index("--history") + 1]))
    assert [h["all_met"] for h in hist] == [True, False, True, True]


def test_stale_previous_check_does_not_confirm(tmp_path, capsys):
    args = write_inputs(tmp_path, full_rows("a", at="2026-10-25T09:00:00Z"))
    run(capsys, args + ["--milestone", "M3"], "2026-10-25T10:00:00Z")
    args = write_inputs(tmp_path, full_rows("b", at="2026-10-27T11:00:00Z"))
    code, out = run(capsys, args + ["--milestone", "M3"], "2026-10-27T12:00:00Z")
    assert code == 1 and out[-1] == "MILESTONE M3 NOT MET (2/2)"


def test_unknown_milestone_and_no_record(tmp_path, capsys):
    args = write_inputs(tmp_path, full_rows("a"))
    code, out = run(capsys, args + ["--milestone", "M9"], NOW)
    assert code == 1 and out[-1] == "MILESTONE M9 NOT MET (0/0)"
    run(capsys, args + ["--all", "--no-record"], NOW)
    assert not (tmp_path / "goal_checks.jsonl").exists()

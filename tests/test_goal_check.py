"""tools/goal_check.py v2: re-derivation from raw runs, hash freshness, validity on the scoring world, manifest
denominators with Wilson lower bounds, pass^k, gates, exact verdict lines, the confirmation re-run (design §9)."""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from evals.bench import hashes
from tools import goal_check as gc

ROOT = Path(__file__).resolve().parents[1]
NOW = "2026-10-27T12:00:00Z"
FRESH = "2026-10-27T10:00:00Z"
OLD = "2026-10-25T10:00:00Z"
TARGETS = json.loads((ROOT / "docs" / "goal_targets.json").read_text(encoding="utf-8"))
CUR = gc.Current(companion="comp1", judge="judge1", scorer="scorer1", body="body1", build="26161880", head="abc123", clean=True)
SKILLS = gc.skill_manifest(ROOT)


@pytest.fixture(autouse=True)
def _test_mode(monkeypatch):
    monkeypatch.setenv(gc.TEST_ENV, "1")  # the real "GOAL MET sha=" literal never appears in test output
    monkeypatch.setattr(gc, "skill_manifest", lambda root=ROOT, targets=None: SKILLS)


def case(cid: str, family: str, result: str = "pass", **kw) -> dict:
    return {"case_id": cid, "case_hash": f"h_{cid}", "family": family, "tier": "T0", "heldout": False, "result": result,
            "hints_used": 0, "repeat_i": 0, "entry_hash": "", **kw}


SIZES = {"spell_cast": 80, "craft": 40, "spell_use": 20, "combat": 20, "adversarial": 20, "tactics_prep": 20}  # LB needs n


def full_suite() -> list[dict]:
    out = [case(f"{f}_{i}", f) for f, n in SIZES.items() for i in range(n)]
    out += [case(f"lt_{t}_{k}", "long_task", long_task=t, repeat_i=k) for t in TARGETS["long_tasks"]["required"] for k in range(3)]
    out += [case(f"basic_{b}_{k}", "combat_basic", basic=b, repeat_i=k) for b in TARGETS["combat_basics_live_proven"] for k in range(3)]
    out += [case(f"skill_{s}_{m}", "skill_train", skill=s, mode=m) for s in SKILLS for m in ("asked", "initiative", "plus5")]
    out += [case(f"cap_velgar_{k}", "capstone", capstone="slay_velgar_solo", repeat_i=k) for k in range(3)]
    out += [case("capstone_stage_1", "capstone_stage")]
    out += [case(f"trend_{i}", "tactics_trend") for i in range(5)]
    for i, c in enumerate(out):
        c["process"] = {"shots": 10, "hits": 9, "telegraphs": 10, "dodged": 9, "efficiency_pct": 85.0,
                        "lookup_when_needed": True, "fact_correct": True, "needless_lookup": False,
                        }
    for k, c in enumerate(x for x in out if x["family"] == "tactics_trend"):
        c["process"]["fight_i"] = k
        c["process"]["damage_taken"] = 200.0 - 5 * k
    return out


def make_run(root: Path, rid: str, cases: list[dict], at: str = FRESH, target: str = "dev", full: bool = True,
             llm: str = "real", cur: gc.Current = CUR, heldout_draw: bool = False, manifest_cases: list[dict] | None = None) -> dict:
    d = root / "logs" / "evals" / rid
    d.mkdir(parents=True, exist_ok=True)
    man = {"version": 1, "families": {}}
    for c in manifest_cases if manifest_cases is not None else cases:
        man["families"].setdefault(c["family"], []).append({"id": c["case_id"], "hash": c["case_hash"]})
    mp = root / "evals" / "bench" / "manifests" / f"{rid}.json"
    mp.parent.mkdir(parents=True, exist_ok=True)
    mp.write_text(json.dumps(man), encoding="utf-8")
    run = {"run_id": rid, "at": at, "target": target, "llm": llm, "heldout_draw": heldout_draw,
           "suite_manifest": {"path": str(mp.relative_to(root)).replace("\\", "/"), "sha256": hashes.sha256_file(mp), "version": 1}}
    (d / "run.json").write_text(json.dumps(run), encoding="utf-8")
    (d / "cases.jsonl").write_text("".join(json.dumps(c) + "\n" for c in cases), encoding="utf-8")
    return {"schema": "dw_scoreboard/1", "kind": "bench", "run_id": rid, "at": at, "target": target, "full": full,
            "dir": str(d.relative_to(root)), "run_sha256": hashes.sha256_file(d / "run.json"),
            "cases_sha256": hashes.sha256_file(d / "cases.jsonl"), "companion_hash": cur.companion, "judge_hash": cur.judge,
            "build": cur.build}


def validity_for(cases: list[dict], cur: gc.Current = CUR, target: str = "dev", **override) -> dict:
    out = {}
    for c in cases:
        key = hashes.validity_key(c["case_hash"], cur.scorer, cur.body, cur.build, c.get("entry_hash", ""))
        ctl = {k: {"result": "fail"} for k in ("do_nothing", "claims_only", "wrong_action", "alt_means", "partial")}
        ctl["oracle"] = {"result": "pass"}
        ctl.update(override.get(c["family"], {}))
        out[key] = {"key": key, "case_hash": c["case_hash"], "target": target, "controls": ctl, "na": {}}
    return out


OBS = {"schema": "dw_obs_metrics/1", "generated_at": FRESH, "window": {"since": OLD, "until": FRESH}, "source": "dev",
       "hours_observed": 3.0, "exposure": {"active_hours": 2.5, "tool_calls_per_hour": 40, "player_chat_lines": 30},
       "latency": {"chat_to_first_action_s": {"p50": 1.9, "p90": 3.2, "n": 40}},
       "anomalies_per_hour": {"stat_narration": 0, "talk_without_action": 0, "stall_over_30s": 0},
       "stability": {"longest_run_without_crash_h": 2.5}, "deaths": {"starvation": 0}}
VOICE_SUMMARY = {"cases": 25, "checks_pass_rate": 0.96, "judge:human": 4.3, "judge:silence": 4.4, "judge:match": 4.5}


def voice_row(root: Path, summary: dict = VOICE_SUMMARY, **over) -> dict:
    """A voice row the way evals/voice_eval.py writes it: its log holds the voice_summary goal_check re-scores."""
    log = root / "logs" / "voice-eval-test.jsonl"
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(json.dumps({"kind": "voice_summary", "summary": {"new": summary}}) + "\n", encoding="utf-8")
    from evals.voice_eval import voice_score
    row = {"kind": "voice", "run_id": "voice_1", "at": FRESH, "score": voice_score(summary), "n": summary["cases"],
           "persona": "new", "persona_ref": "HEAD", "persona_sha256": "ab" * 32,
           "log": "logs/voice-eval-test.jsonl", "log_sha256": hashes.sha256_file(log),
           "companion_hash": CUR.companion}
    row.update(over)
    return row


def data(tmp_path, rows, validity, obs=OBS, cur=CUR, targets=TARGETS) -> gc.Data:
    return gc.Data(targets, rows, validity, obs, gc.parse_ts(NOW), cur, root=tmp_path)


def everything(tmp_path, at: str = FRESH, rid: str = "dev_1"):
    cases = full_suite()
    rows = [make_run(tmp_path, rid, cases, at=at), make_run(tmp_path, rid + "_held", [dict(c, heldout=True, case_id=c["case_id"] + "_h",
                                                                                         case_hash=c["case_hash"] + "_h") for c in cases[:40]],
                                                             at=at, heldout_draw=True), voice_row(tmp_path)]
    held = [dict(c, case_hash=c["case_hash"] + "_h") for c in cases[:40]]
    return rows, {**validity_for(cases), **validity_for(held)}


def all_rows(d: gc.Data) -> dict[str, gc.Row]:
    out = {}
    for m in gc.milestones(d.targets):
        for r in gc.check(d, m)[0]:
            out[r.target] = r
    return out


def test_everything_valid_fresh_and_full_meets_every_target(tmp_path):
    rows, val = everything(tmp_path)
    d = data(tmp_path, rows, val)
    bad = [r.line() for r in all_rows(d).values() if r.status != gc.MET]
    assert not bad, "\n".join(bad + d.rejected)


def test_no_data_and_rejections_are_reported(tmp_path):
    d = data(tmp_path, [], {}, obs=None)
    assert {r.status for r in all_rows(d).values()} == {gc.NO_DATA}


@pytest.mark.parametrize("change,why", [
    (dict(target="mock"), "scoring world"),
    (dict(full=False), "partial"),
    (dict(llm="fake"), "real-model"),
])
def test_runs_that_never_count(tmp_path, change, why):
    cases = full_suite()
    row = make_run(tmp_path, "r1", cases, target=change.get("target", "dev"), full=change.get("full", True), llm=change.get("llm", "real"))
    d = data(tmp_path, [row], validity_for(cases))
    r = all_rows(d)["spells_effect_coverage_pct"]
    assert r.status == gc.NOT_MET and why in r.note


def test_hash_freshness_and_mixed_hashes(tmp_path):
    cases = full_suite()
    old = gc.Current(**{**CUR.__dict__, "companion": "comp0"})
    d = data(tmp_path, [make_run(tmp_path, "r1", cases, cur=old)], validity_for(cases))
    r = all_rows(d)["spells_effect_coverage_pct"]
    assert r.status == gc.NOT_MET and "companion comp0 != current comp1" in r.note
    dirty = gc.Current(**{**CUR.__dict__, "companion": "comp1+dirty"})
    d = data(tmp_path, [make_run(tmp_path, "r2", cases, cur=dirty)], validity_for(cases), cur=dirty)
    assert all_rows(d)["spells_effect_coverage_pct"].status == gc.NOT_MET


def test_tampered_run_files_are_rejected(tmp_path):
    cases = full_suite()
    row = make_run(tmp_path, "r1", cases)
    f = tmp_path / row["dir"] / "cases.jsonl"
    f.write_text(f.read_text(encoding="utf-8").replace('"result": "fail"', '"result": "pass"') + "\n", encoding="utf-8")
    d = data(tmp_path, [row], validity_for(cases))
    r = all_rows(d)["spells_effect_coverage_pct"]
    assert r.status == gc.NOT_MET and "sha256 mismatch" in r.note


def test_precomputed_metrics_in_the_scoreboard_are_ignored(tmp_path):
    cases = [case(f"s{i}", "spell_cast", "fail") for i in range(25)]
    row = make_run(tmp_path, "r1", cases)
    row["metrics"] = {"spells_effect_coverage_pct": {"value": 100, "n": 25}}  # a forged summary
    d = data(tmp_path, [row], validity_for(cases))
    assert all_rows(d)["spells_effect_coverage_pct"].status == gc.NOT_MET


def test_denominator_is_the_manifest_and_only_pass_counts(tmp_path):
    cases = [case(f"s{i}", "spell_cast") for i in range(20)] + [case(f"u{i}", "spell_cast", "unverifiable") for i in range(5)]
    # 5 more manifest spells never even ran: they still count against
    extra = [case(f"x{i}", "spell_cast") for i in range(5)]
    row = make_run(tmp_path, "r1", cases, manifest_cases=cases + extra)
    d = data(tmp_path, [row], validity_for(cases))
    r = all_rows(d)["spells_effect_coverage_pct"]
    assert r.value.startswith("20/30") and r.status == gc.NOT_MET


def test_spells_count_k_trials_per_case(tmp_path):
    """39 manifest spells x k=2 trials = 78 (main's decision): 78/78 meets the 95% LB; one missing trial doesn't."""
    cases = [case(f"s{i}", "spell_cast", repeat_i=k) for i in range(39) for k in range(2)]
    row = make_run(tmp_path, "r1", cases, manifest_cases=[case(f"s{i}", "spell_cast") for i in range(39)])
    man_path = tmp_path / json.loads((tmp_path / row["dir"] / "run.json").read_text())["suite_manifest"]["path"]
    man = json.loads(man_path.read_text())
    man["trials_per_case"] = {"spell_cast": 2}
    man_path.write_text(json.dumps(man))
    run = json.loads((tmp_path / row["dir"] / "run.json").read_text())
    run["suite_manifest"]["sha256"] = hashes.sha256_file(man_path)
    (tmp_path / row["dir"] / "run.json").write_text(json.dumps(run))
    row["run_sha256"] = hashes.sha256_file(tmp_path / row["dir"] / "run.json")
    d = data(tmp_path, [row], validity_for(cases))
    r = all_rows(d)["spells_effect_coverage_pct"]
    assert r.status == gc.MET and r.value.startswith("78/78")
    cases2 = cases[:-1]
    row2 = make_run(tmp_path, "r2", cases2, manifest_cases=[case(f"s{i}", "spell_cast") for i in range(39)])
    man2 = tmp_path / json.loads((tmp_path / row2["dir"] / "run.json").read_text())["suite_manifest"]["path"]
    m2 = json.loads(man2.read_text())
    m2["trials_per_case"] = {"spell_cast": 2}
    man2.write_text(json.dumps(m2))
    run2 = json.loads((tmp_path / row2["dir"] / "run.json").read_text())
    run2["suite_manifest"]["sha256"] = hashes.sha256_file(man2)
    (tmp_path / row2["dir"] / "run.json").write_text(json.dumps(run2))
    row2["run_sha256"] = hashes.sha256_file(tmp_path / row2["dir"] / "run.json")
    d = data(tmp_path, [row2], validity_for(cases2))
    assert all_rows(d)["spells_effect_coverage_pct"].status == gc.NOT_MET


def test_wilson_lower_bound_and_min_n(tmp_path):
    few = [case(f"s{i}", "spell_cast") for i in range(10)]
    d = data(tmp_path, [make_run(tmp_path, "r1", few)], validity_for(few))
    r = all_rows(d)["spells_effect_coverage_pct"]
    assert r.status == gc.NOT_MET and "n 10 < 20" in r.note
    many = [case(f"s{i}", "spell_cast") for i in range(60)]  # 60/60: LB 94% < 95%
    d = data(tmp_path, [make_run(tmp_path, "r2", many)], validity_for(many))
    r = all_rows(d)["spells_effect_coverage_pct"]
    assert r.status == gc.NOT_MET and "LB 94%" in r.value
    lots = [case(f"s{i}", "spell_cast") for i in range(80)]  # 80/80: LB 95.4%
    d = data(tmp_path, [make_run(tmp_path, "r3", lots)], validity_for(lots))
    assert all_rows(d)["spells_effect_coverage_pct"].status == gc.MET


@pytest.mark.parametrize("override,reason", [
    ({"oracle": {"result": "fail"}}, "positive control did not pass"),
    ({"do_nothing": {"result": "pass"}}, "negative control do_nothing did not fail"),
    ({"alt_means": {"result": "unverifiable"}}, "negative control alt_means did not fail"),
    ({"wrong_action": {"result": "pass"}}, "negative control wrong_action did not fail"),
])
def test_invalid_cases_never_count(tmp_path, override, reason):
    cases = [case(f"s{i}", "spell_cast") for i in range(80)]
    d = data(tmp_path, [make_run(tmp_path, "r1", cases)], validity_for(cases, spell_cast=override))
    rows = all_rows(d)
    assert rows["spells_effect_coverage_pct"].value.startswith("0/80")
    assert d.validity_summary["invalid_reasons"] == {reason: 80}


def test_controls_on_another_world_or_old_scorer_do_not_count(tmp_path):
    cases = [case(f"s{i}", "spell_cast") for i in range(80)]
    d = data(tmp_path, [make_run(tmp_path, "r1", cases)], validity_for(cases, target="mock"))
    assert all_rows(d)["spells_effect_coverage_pct"].value.startswith("0/80")
    old = gc.Current(**{**CUR.__dict__, "scorer": "scorer0"})
    d = data(tmp_path, [make_run(tmp_path, "r2", cases)], validity_for(cases, cur=old))
    assert all_rows(d)["spells_effect_coverage_pct"].value.startswith("0/80")


def test_long_tasks_need_pass_k_within_hints_and_pins(tmp_path):
    lt = TARGETS["long_tasks"]["required"][0]
    name = f"long_tasks:{lt}"
    two = [case(f"lt{k}", "long_task", long_task=lt, repeat_i=k) for k in range(2)]
    d = data(tmp_path, [make_run(tmp_path, "r1", two)], validity_for(two))
    assert all_rows(d)[name].status == gc.NOT_MET
    three = [case(f"lt{k}", "long_task", long_task=lt, repeat_i=k, hints_used=2 if k == 1 else 0) for k in range(3)]
    d = data(tmp_path, [make_run(tmp_path, "r2", three)], validity_for(three))
    assert all_rows(d)[name].status == gc.NOT_MET
    good = [case(f"lt{k}", "long_task", long_task=lt, repeat_i=k) for k in range(3)]
    d = data(tmp_path, [make_run(tmp_path, "r3", good)], validity_for(good))
    assert all_rows(d)[name].status == gc.MET
    pinned = {**TARGETS, "goal_cases": {"pinned_by_hash": {"lt0": "some_other_hash"}}}
    d = data(tmp_path, [make_run(tmp_path, "r4", good)], validity_for(good), targets=pinned)
    assert all_rows(d)[name].status == gc.NOT_MET


def test_every_skill_needs_all_three_modes_for_every_skill(tmp_path):
    cases = [case(f"sk_{s}_{m}", "skill_train", skill=s, mode=m) for s in SKILLS for m in ("asked", "initiative", "plus5")
             if not (s == SKILLS[0] and m == "plus5")]
    d = data(tmp_path, [make_run(tmp_path, "r1", cases)], validity_for(cases))
    rows = all_rows(d)
    assert rows["every_skill:asked"].status == gc.MET
    assert rows["every_skill:plus5"].status == gc.NOT_MET and SKILLS[0] in rows["every_skill:plus5"].note
    assert len(SKILLS) >= 10  # the build's skill data (Attack ... Woodcutting)


def test_heldout_needs_a_fresh_draw_with_n_and_floor(tmp_path):
    seen = [case(f"s{i}", "spell_cast") for i in range(40)]
    held = [case(f"h{i}", "spell_cast", "pass" if i < 20 else "fail", heldout=True) for i in range(40)]
    d = data(tmp_path, [make_run(tmp_path, "seen", seen), make_run(tmp_path, "held", held, heldout_draw=True)],
             {**validity_for(seen), **validity_for(held)})
    r = all_rows(d)["heldout"]
    assert r.status == gc.NOT_MET and "held 20/40" in r.value


def test_obs_exposure_and_staleness(tmp_path):
    rows, val = everything(tmp_path)
    idle = json.loads(json.dumps(OBS))
    idle["exposure"]["active_hours"] = 0.4
    assert all_rows(data(tmp_path, rows, val, obs=idle))["obs_exposure"].status == gc.NOT_MET
    old = json.loads(json.dumps(OBS))
    old["generated_at"] = old["window"]["until"] = OLD
    r = all_rows(data(tmp_path, rows, val, obs=old))["stability_hours_without_crash"]
    assert r.status == gc.NOT_MET and "stale" in r.note


def test_gates_judge_tag_and_clean_tree(tmp_path, monkeypatch):
    rows, val = everything(tmp_path)
    d = data(tmp_path, rows, val)
    gc.collect_runs(d)
    g = {x.target: x for x in gc.gates(d)}
    assert g["gate:judge_tag"].status == gc.NOT_MET  # null until Luis tags it
    monkeypatch.setattr(gc.hashes, "judge_diff_since", lambda tag, root=None: ["tools/goal_check.py"])
    d2 = data(tmp_path, rows, val, targets={**TARGETS, "judge_tag": "goal-judge-20261027"})
    gc.collect_runs(d2)
    g = {x.target: x for x in gc.gates(d2)}
    assert g["gate:judge_tag"].status == gc.NOT_MET and "goal_check.py" in g["gate:judge_tag"].note
    dirty = gc.Current(**{**CUR.__dict__, "clean": False})
    d3 = data(tmp_path, rows, val, cur=dirty)
    assert {x.target: x for x in gc.gates(d3)}["gate:clean_tree"].status == gc.NOT_MET


# ------------------------------------------------------------------ the CLI: verdict lines and confirmation


def cli(tmp_path, capsys, monkeypatch, rows, val, now, extra=(), targets=None, judge_ok=True):
    sb = tmp_path / "scoreboard.jsonl"
    sb.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    vd = tmp_path / "validity"
    vd.mkdir(exist_ok=True)
    for k, v in val.items():
        (vd / f"{k}.json").write_text(json.dumps(v), encoding="utf-8")
    ob = tmp_path / "obs.json"
    ob.write_text(json.dumps(OBS), encoding="utf-8")
    tf = tmp_path / "targets.json"
    tf.write_text(json.dumps(targets or {**TARGETS, "judge_tag": "goal-judge-20261027"}), encoding="utf-8")
    monkeypatch.setattr(gc, "current", lambda root=None: CUR)
    monkeypatch.setattr(gc.hashes, "judge_diff_since", lambda tag, root=None: [] if judge_ok else ["docs/goal_targets.json"])
    code = gc.main(["--targets", str(tf), "--scoreboard", str(sb), "--validity", str(vd), "--obs-json", str(ob), "--history",
                    str(tmp_path / "goal_checks.jsonl"), "--root", str(tmp_path), "--now", now, *extra])
    return code, capsys.readouterr().out.strip().splitlines()


def test_goal_met_needs_two_consecutive_checks_on_new_data(tmp_path, capsys, monkeypatch):
    rows, val = everything(tmp_path, at="2026-10-27T09:00:00Z", rid="a")
    code, out = cli(tmp_path, capsys, monkeypatch, rows, val, "2026-10-27T09:30:00Z", ["--all"])
    assert code == 1 and re.fullmatch(r"GOAL NOT MET \((M\d \d+/\d+, )+focus=M1\)", out[-1])
    assert "confirmation: PENDING" in " ".join(out)
    code, out = cli(tmp_path, capsys, monkeypatch, rows, val, "2026-10-27T09:45:00Z", ["--all"])  # same data: no
    assert code == 1
    rows2, val2 = everything(tmp_path, at="2026-10-27T10:00:00Z", rid="b")
    code, out = cli(tmp_path, capsys, monkeypatch, rows + rows2, {**val, **val2}, "2026-10-27T10:30:00Z", ["--all"])
    assert code == 0 and out[-1] == "GOAL MET (TEST)"


def test_real_goal_met_line_is_sha_bound(tmp_path, capsys, monkeypatch):
    monkeypatch.delenv(gc.TEST_ENV)
    rows, val = everything(tmp_path, at="2026-10-27T09:00:00Z", rid="a")
    cli(tmp_path, capsys, monkeypatch, rows, val, "2026-10-27T09:30:00Z", ["--all"])
    rows2, val2 = everything(tmp_path, at="2026-10-27T10:00:00Z", rid="b")
    code, out = cli(tmp_path, capsys, monkeypatch, rows + rows2, {**val, **val2}, "2026-10-27T10:30:00Z", ["--all"])
    assert code == 0
    assert re.fullmatch(r"GOAL MET sha=abc123 judge=judge1 runs=\S+ at=2026-10-27T10:30:00Z", out[-1])


def test_gates_block_goal_met(tmp_path, capsys, monkeypatch):
    rows, val = everything(tmp_path, at="2026-10-27T09:00:00Z", rid="a")
    cli(tmp_path, capsys, monkeypatch, rows, val, "2026-10-27T09:30:00Z", ["--all"], judge_ok=False)
    rows2, val2 = everything(tmp_path, at="2026-10-27T10:00:00Z", rid="b")
    code, out = cli(tmp_path, capsys, monkeypatch, rows + rows2, {**val, **val2}, "2026-10-27T10:30:00Z", ["--all"], judge_ok=False)
    assert code == 1 and out[-1].endswith("focus=gates)")


def test_milestone_lines_never_say_goal_met(tmp_path, capsys, monkeypatch):
    rows, val = everything(tmp_path, at="2026-10-27T09:00:00Z", rid="a")
    code, out = cli(tmp_path, capsys, monkeypatch, rows, val, "2026-10-27T09:30:00Z", ["--milestone", "M4"])
    assert code == 1 and out[-1] == f"MILESTONE M4 NOT MET (2/2)" and not any("GOAL MET" in x for x in out)
    rows2, val2 = everything(tmp_path, at="2026-10-27T10:00:00Z", rid="b")
    code, out = cli(tmp_path, capsys, monkeypatch, rows + rows2, {**val, **val2}, "2026-10-27T10:30:00Z", ["--milestone", "M4"])
    assert code == 0 and out[-1] == "MILESTONE M4 MET"
    code, out = cli(tmp_path, capsys, monkeypatch, rows, val, NOW, ["--milestone", "M9"])
    assert code == 1 and out[-1] == "MILESTONE M9 NOT MET (0/0)"


def test_every_milestone_key_has_a_measurement():
    keys = {k for m in TARGETS["milestones"].values() for k in m}
    d = gc.Data(TARGETS, [], {}, None, gc.parse_ts(NOW), CUR)
    for k in keys:
        for r in gc.rows_for(d, k):
            assert "no measurement" not in r.note, k


def test_quick_variants_never_count_for_goal(tmp_path):
    """Luis 2026-10-26: a *_quick case (grants that isolate one skill) is a dev aid; only main variants are scored."""
    cases = full_suite()
    for c in cases:
        if c["family"] == "combat_basic":
            c["variant"] = "quick"
    rows = [make_run(tmp_path, "dev_q", cases)]
    d = data(tmp_path, rows, validity_for(cases))
    gc.collect_runs(d)
    kept = [c for r in d.runs for c in r["cases"]]
    assert kept and not any(c.get("family") == "combat_basic" for c in kept)
    assert len(kept) == len(cases) - sum(c["family"] == "combat_basic" for c in cases)


def test_voice_score_is_the_weakest_part_and_rows_must_rederive_from_their_log(tmp_path):
    """voice_score_min: min(checks pass rate, judge human/5, silence/5, match/5); a row counts only if its log
    re-scores to it (the 2026-10-26 11:13 run: checks 0.957, human 3.75 -> 0.75, under the 0.8 target)."""
    from evals.voice_eval import voice_score
    assert voice_score({"checks_pass_rate": 0.957, "judge:human": 3.75, "judge:silence": 4.12, "judge:match": 3.84}) == 0.75
    assert voice_score({"checks_pass_rate": 0.957, "judge:human": None, "judge:silence": 4, "judge:match": 4}) is None
    good = voice_row(tmp_path)
    d = data(tmp_path, [good], {})
    assert gc.voice(d, "voice_score_min").status == gc.MET
    for bad in (dict(good, score=0.99), dict(good, log_sha256="0" * 64), {k: v for k, v in good.items() if k != "log"},
                dict(good, persona_ref="worktree")):
        assert gc.voice(data(tmp_path, [bad], {}), "voice_score_min").status == gc.NO_DATA, bad

"""tools/breadth.py: the untuned pass rate beside the tuned one, offline, from files in a temp root."""
from __future__ import annotations

import json

from tools import breadth as b
from tools import quest_run as q


def irec(run, ok=True, job="L2", step="I3", held=False, **kw):
    """An interruption trial as job_run writes it (its verdict needs no brain rows)."""
    return {"run": run, "kind": "interrupt", "job": job, "step": step, "held_out": held, "until": "resumed",
            "interruption": {"step": step, "took": True}, "resume": {"resumed": ok, "after_s": 10.0 if ok else None},
            "resume_within_s": 180, **kw}


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")


def root(tmp_path, jobs=(), quests=(), ledger=(), ladder=(), lookup=None):
    src = b.Src(tmp_path)
    write_jsonl(src.jobs_runs, list(jobs))
    write_jsonl(src.quest_runs, list(quests))
    write_jsonl(src.ledger, list(ledger))
    write_jsonl(src.ladder, list(ladder))
    src.jobs_doc.parent.mkdir(parents=True, exist_ok=True)
    src.jobs_doc.write_text(json.dumps({"jobs": {"L2": {}, "H1": {"held_out": True}}}), encoding="utf-8")
    if lookup is not None:
        (tmp_path / "logs" / "evals" / "lookup_enemies_eval-20261117-main.json").write_text(json.dumps(lookup),
                                                                                           encoding="utf-8")
    return src


def test_split_first_three_untuned_rest_tuned_newest_n():
    trials = [({"run": f"r{i}"}, i % 2 == 0) for i in range(8)]   # T F T F T F T F
    s = b.split("x", trials, held_out=False, n=3)
    assert s["untuned"] == [True, False, True] and s["untuned_runs"] == ["r0", "r1", "r2"]
    assert s["tuned"] == [False, True, False] and s["tuned_runs"] == ["r5", "r6", "r7"]
    assert [t["blind"] for t in s["first"]] == ["blind unknown: record before the flag"] * 3
    h = b.split("h", trials[:4], held_out=True, n=3)
    assert h["tuned"] == [] and h["untuned"] == [True, False, True, False]      # every held-out run is untuned
    assert b.split("x", trials, False, n=0)["tuned"] == [False, True, False, True, False]


def test_blind_flag_read_from_the_record():
    assert b.blind_of({"first_three_blind": True}) == "scored before trace read"
    assert b.blind_of({"first_three_blind": False}) == "trace read before scoring"
    assert b.blind_of({}).startswith("blind unknown")


def test_jobs_leave_out_void_probes_and_uncounted_and_mark_held_out(tmp_path):
    recs = [irec("20261117-100000-L2-I3", first_three_blind=True), irec("20261117-110000-L2-I3", ok=False),
            irec("20261117-120000-L2-I3"), irec("20261117-130000-L2-I3"), irec("20261117-140000-L2-I3", ok=False),
            irec("20261117-150000-L2-I3"),                                        # void below
            dict(irec("20261117-160000-L2-I3"), until="first_step"),            # a probe
            irec("20261117-170000-L2-I3", not_counted="head start"),
            irec("20261117-180000-L2-I3", unread="chest out of reach"),
            irec("20261117-190000-H1-I3", job="H1", held=True)]
    src = root(tmp_path, jobs=recs, ledger=[{"run": "20261117-150000-L2-I3", "void": True}])
    d = b.collect(src, n=10)
    items = {i["item"]: i for i in d["jobs"]["items"]}
    l2 = items["L2 / I3"]
    assert l2["untuned"] == [True, False, True] and l2["tuned"] == [True, False]
    assert l2["first"][0]["blind"] == "scored before trace read" and l2["first"][1]["blind"].startswith("blind unknown")
    assert items["H1 / I3"]["held_out"] and items["H1 / I3"]["untuned"] == [True] and items["H1 / I3"]["tuned"] == []
    assert items["L2"]["n_scored"] == 0 and items["H1"]["held_out"]              # jobs with no run still listed
    assert d["jobs"]["left"] == {"void": 1, "probes (to the first step)": 1, "not counted": 1, "unread end state": 1}
    text = b.render(d)
    assert "H1 / I3  [held-out]" in text and "left out of 10 records: void 1" in text
    assert "goal 1, all items                  1 of 2 = 50 %          3 of 4 = 75 %" in text


def test_quests_starts_and_steps(tmp_path, monkeypatch):
    monkeypatch.setattr(q, "verdict", lambda r: {"pass": r["ok"]})
    monkeypatch.setattr(q, "not_counted", lambda r: r.get("nc"))
    qs = [{"run": f"20261101-1{i}0000", "quest": "Ratcatcher", "until": "complete", "ok": i > 1} for i in range(6)]
    qs += [{"run": "20261116-100000", "quest": "Ratcatcher", "checkpoint": "rc_start", "until": "complete", "ok": True},
           {"run": "20261116-110000", "quest": "Ratcatcher", "until": "change", "ok": True},
           {"run": "20261116-120000", "quest": "Ratcatcher", "until": "complete", "ok": True, "nc": "head start"}]
    d = b.collect(root(tmp_path, quests=qs), n=10)
    rc = d["quests"]["items"][0]
    assert rc["item"] == "Ratcatcher" and rc["untuned"] == [False, False, True] and rc["tuned"] == [True, True, True]
    assert [s["item"] for s in d["quests"]["steps"]] == ["Ratcatcher @ rc_start"]
    assert d["quests"]["left"] == {"void": 0, "probes (to a change of step)": 1, "not counted (head start)": 1}


def test_lookup_reads_the_held_out_half_as_one_number(tmp_path):
    src = root(tmp_path, lookup={"tuned": {"summary": {"hits": 10, "n": 15}}, "heldout": {"hits": 13, "n": 15}})
    lk = b.lookup(src)
    assert lk["tuned"] == (10, 15) and lk["heldout"] == (13, 15) and lk["heldout_blind"] and lk["when"] == "11-17"
    (tmp_path / "logs" / "evals" / "lookup_enemies_eval-20261117-main.json").write_text(
        json.dumps({"tuned": {"summary": {"hits": 1, "n": 2}}, "heldout": {"hits": 1, "n": 2, "cases": []}}))
    assert b.lookup(src)["heldout_blind"] is False                               # its cases were shown
    assert b.lookup(b.Src(tmp_path / "none")) == {"files": 0}


def test_jumps_course_rate_and_travel(tmp_path):
    ladder = [{"run": "c1", "label": "jumpcourse-a", "journey": "jump_hill_top", "ts": 1795000000.0, "s": 10, "ok": True},
              {"run": "c1", "label": "jumpcourse-a", "summary": True, "ts": 1795000500.0, "n": 1, "ok": 1,
               "jump_course": {"jump_paths": 10, "strike_paths": 3}},
              {"run": "20261101-100000", "label": "fix1", "summary": True, "ts": 1790000000.0, "n": 4, "ok": 3}]
    src = root(tmp_path, ladder=ladder)
    js = b.jumps(src)
    assert js["label"] == "jumpcourse-a" and js["tuned"].count(True) == 7 and len(js["tuned"]) == 10
    assert js["course_start"] == b._iso(1795000000.0)                            # the first leg, not the summary row
    assert [p["name"] for p in js["play"]] == ["brain play, same code", "brain play since 8adf80f"]
    assert all(p["untuned"] == [] for p in js["play"])                            # no client log here: 0 paths
    assert b.travel(src) == {"label": "fix1", "run": "20261101-100000", "ok": 3, "n": 4, "runs": 1}
    assert "0 paths" in b.render(b.collect(src))


def test_report_runs_on_an_empty_root(tmp_path, capsys):
    assert b.main(["report", "--root", str(tmp_path)]) == 0
    out = capsys.readouterr().out
    assert "4 capstone" in out and "no course run" in out and "no result file" in out

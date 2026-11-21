"""A day of play (goal stage D): tools/job_run.py `day` and tools/day_score.py, offline on the fake body of
tests/test_job_run.py. No server, client, brain or model."""
from __future__ import annotations

import json

import pytest

from tools import day_score as ds
from tools import job_run as j
from tests.test_job_run import CRATE, T0, FakeIO, call, model, result, state

TW = [182.4, 1839.9, 10.0]    # Temple Woods (power 1), his start
BV = [602.4, 1654.8, 10.0]    # Bramblemead Valley (power 2)
FP = [1037.0, 986.8, 10.0]    # Fractured Plains (power 3)
ASK = "get yourself ready for the next region"
STEAK = "ITEM_Consumable_Farm_Steak"


@pytest.fixture(autouse=True)
def _offline(monkeypatch, tmp_path):
    monkeypatch.setattr(j, "STOP_FILE", tmp_path / "job_run.stop")
    monkeypatch.setattr(ds, "DAY_OUT", tmp_path / "day_runs.jsonl")
    monkeypatch.setattr(ds, "RECORD_DIR", tmp_path / "day_runs")
    monkeypatch.setattr(ds, "LUIS_STANDARD", tmp_path / "no-standard-report.json")  # the VM's logs/ never in a test


def day_state(t):
    """He walks Temple Woods -> Bramblemead (t 300) -> Fractured Plains (t 900), trains Mining, his power level goes
    1 -> 2 at t 600, he eats down his steaks, and a read at t 450 has him dead."""
    rel = t - T0
    pos = TW if rel < 300 else BV if rel < 900 else FP
    s = state(food=max(0, 6 - int(rel // 200)), drink=3, pos=pos, mine=[CRATE], dead=450 <= rel < 465)
    s.update(power_level=2 if rel >= 600 else 1, total_level=20 + (1 if rel >= 700 else 0),
             skills=[{"skill": "Mining", "level": 5 + (1 if rel >= 700 else 0), "xp": 400 + rel},
                     {"skill": "Cooking", "level": 3, "xp": 120}])
    return s


def day_script():
    """One model turn and a gather at the start, a death mid-call at t 455 (companion_down), a fight that ended died
    at t 470 (one death with it: within 30 s), a failed build at t 800 (a miss), a second death at t 1000, and then
    nothing: he stands to the end."""
    rows = model(T0 + 1)
    rows += [call(T0 + 3, "g1", "gather", {"resource": "copper"}),
             result(T0 + 20, "g1", "gather", data={"detail": "Got 5 copper ore.", "count": 5}),
             call(T0 + 440, "g2", "gather", {"resource": "copper"}),
             result(T0 + 455, "g2", "gather", ok=False, reason="companion_down"),
             {"ts": T0 + 470, "kind": "event", "event": {"type": "activity", "kind": "combat_end", "outcome": "died",
                                                         "target": "Goblin Warrior", "by": "reflex", "ts": T0 + 470}},
             call(T0 + 790, "b1", "build", {"piece": "wall"}),
             result(T0 + 800, "b1", "build", ok=False, reason="blocked"),
             call(T0 + 990, "a1", "attack", {"target": "garou"}),
             result(T0 + 1000, "a1", "attack", ok=False, reason="companion_down")]
    return sorted(rows + model(T0 + 430) + model(T0 + 780) + model(T0 + 985), key=lambda r: r["ts"])


def crate(t, cid):
    return [{"item": STEAK, "name": "Steak", "count": 4}] if cid == CRATE else None


def run_day(doc_, budget=1200, monkeypatch=None):
    io = FakeIO(script=day_script(), states=day_state, chests=crate)
    job = j.day_job(ASK, None, budget, doc_)
    rec = j.run_job(io, job, {"deadline": budget, "job_deadline": budget, "character": "ClaudeJ211200a",
                              "checkpoint": "ClaudeDev"})
    return io, rec


@pytest.fixture(scope="module")
def doc():
    return j.load_jobs()


@pytest.fixture
def day(doc, monkeypatch):
    monkeypatch.setattr(j, "DAY_STOCK_S", 300.0)
    return run_day(doc)


# ------------------------------------------------------------------ the run: one ask, to the budget, never quiet
def test_day_line_is_addressed_like_every_jobs_line():
    assert j.day_line(ASK) == f"claude, {ASK}"
    assert j.day_line("  Claude,  go   mine ") == "Claude, go mine"


def test_day_job_has_no_end_and_the_work_tools_of_every_job(doc):
    job = j.day_job(ASK, None, 7200, doc)
    assert job["end"] == {} and job["day"] and job["deadline_s"] == 7200 and job["start"] == "ClaudeDev"
    assert {"gather", "craft", "attack", "build"} <= set(job["work_tools"])
    assert j.done(job, j.snapshot(state()), j.snapshot(state())) == (False, "")  # the game never reads a day done


def test_a_day_runs_to_its_budget_through_a_long_stand_and_says_nothing_more(day, doc):
    io, rec = day
    assert io.sent == [f"claude, {ASK}"]                     # one line, no re-ask
    assert rec["ended"] == "deadline" and rec["kind"] == "day" and rec["run"].endswith("-D")
    assert rec["wall_s"] >= 1200 and rec["active_s"] == rec["wall_s"]
    # a trial would have ended quiet 40 s after the last call (t 1000); the day stood to the end, and that is scored
    last = rec["idle_over_5s"][-1]
    assert last.get("to_end") and last["s"] >= 195
    assert rec["longest_stand_s"] == max(i["s"] for i in rec["idle_over_5s"]) >= 400  # 20 s to 430 s
    assert rec["day"]["quiet_ends_run"] is False and rec["day"]["lines_sent"] == 1
    assert not rec.get("not_counted") and rec["item"] == f"day: claude, {ASK}"


def test_the_day_keeps_a_trace_of_every_read_and_his_stock_every_interval(day):
    _, rec = day
    tr = rec["day"]["trace"]
    assert tr[0]["t"] == 0.0 and tr[-1]["t"] == rec["wall_s"]
    assert 70 <= len(tr) <= 90                                 # every 15 s over 1200 s, plus the start and the end
    assert tr[0]["skills"]["Mining"] == [5, 400] and tr[0]["pl"] == 1 and tr[0]["pos"][:2] == TW[:2]
    assert any(p["dead"] for p in tr)
    st = rec["day"]["stock"]
    assert [s["t"] for s in st][:2] == [0.0, 300.0] and len(st) == 6   # start, 300, 600, 900, 1200, and the end
    assert st[0]["chests"][CRATE]["food"] == 4 and st[0]["consumables"]["food"] == 6


def test_a_spend_cap_or_a_stop_ends_the_day_and_it_is_not_counted(doc, tmp_path):
    stop = tmp_path / "job_run.stop"
    stop.write_text("", encoding="utf-8")
    io = FakeIO(script=day_script(), states=day_state, chests=crate)
    rec = j.run_job(io, j.day_job(ASK, None, 1200, doc), {"deadline": 1200, "stop_file": str(stop)})
    assert rec["ended"] == "stopped" and "stopped by the stop file" in rec["not_counted"]
    stop.unlink()
    blocked = day_script() + [{"ts": T0 + 50, "kind": "budget_blocked"}]
    io = FakeIO(script=sorted(blocked, key=lambda r: r["ts"]), states=day_state, chests=crate)
    rec = j.run_job(io, j.day_job(ASK, None, 1200, doc), {"deadline": 1200})
    assert rec["ended"] == "budget" and "spend cap" in rec["not_counted"]


def test_end_class():
    rec = {"ended": "deadline", "wall_s": 7201.0, "day": {"budget_s": 7200.0}}
    assert ds.end_class(rec) == ("budget", "ran its budget (7201.0 s)") and ds.not_counted(rec) is None
    assert ds.end_class(rec, 7200.0)[0] == "budget"
    cut = {"ended": "deadline", "wall_s": 3000.0, "day": {"budget_s": 3000.0}}
    assert ds.end_class(cut, 7200.0)[0] == "harness" and "cut the budget" in ds.not_counted(cut, 7200.0)
    assert ds.end_class({"ended": "haiku cap"})[0] == "spend cap"
    assert ds.end_class({"ended": "quiet"})[0] == "harness"


# ------------------------------------------------------------------ the score
def test_the_score_from_the_record(day):
    _, rec = day
    sc = ds.score(rec)
    pl = sc["power_level"]
    assert (pl["start"], pl["end"], pl["max"], pl["gained"]) == (1, 2, 2, 1) and pl["series"][0] == [0.0, 1]
    assert pl["series"][1][1] == 2 and 600 <= pl["series"][1][0] < 616
    sk = sc["skills"]
    assert sk["skills"]["Mining"]["levels_gained"] == 1 and sk["skills"]["Mining"]["xp_gained"] >= 1200
    assert sk["skills"]["Cooking"]["xp_gained"] == 0 and sk["trained"] == ["Mining"]
    assert sk["total_level"] == [20, 21] and sk["total_levels_gained"] == 1
    rg = sc["regions"]
    assert rg["reached"] == ["Temple Woods", "Bramblemead Valley", "Fractured Plains"]
    assert rg["new"] == ["Bramblemead Valley", "Fractured Plains"] and rg["top_power"] == 3
    assert [e["power"] for e in rg["entries"]] == [1, 2, 3]
    # the death at 455 (call) and the read at 450 merge into one; the one at 1000 is the second
    dt = sc["deaths"]
    assert dt["n"] == 2 and 449 <= dt["t"][0] <= 456 and dt["t"][1] == 1000.0 and not dt["brain_log_read"]
    # misses and stands are job_run's own, unchanged
    # (job_run counts a call his death failed as a miss: companion_down is not an interruption by quest_run's rule)
    assert sc["misses"]["n"] == rec["misses"]["n"] == 3 and sc["misses"]["per_5min"] == rec["misses"]["per_5min"]
    assert sc["misses"]["kinds"] == {"companion_down": 2, "blocked": 1}
    assert sc["idle"]["total_s"] == rec["idle_total_s"] and sc["idle"]["longest_s"] == rec["longest_stand_s"]
    assert sc["idle"]["quiet_spells"] >= 1 and sc["idle"]["to_end_s"] >= 195
    st = sc["stock"]
    assert st["start"]["food"] == 6 and st["start"]["chest_food"] == 4 and st["low_food"] == 0
    assert st["end"]["chests"][CRATE]["food"] == 4
    assert sc["spend"]["haiku"] == rec["haiku"] == 4 and sc["end_class"] == "budget"
    assert sc["first_action_s"] == 3.0 and sc["first_step_s"] == 20.0  # the gather started at 3 s, ended ok at 20 s
    assert sc["bars"] == {"deaths": False, "stands": False, "counted": True} and not sc["pass_"]


def test_the_brain_log_adds_deaths_and_positions(day, tmp_path):
    _, rec = day
    t0 = rec["day"]["t0"]
    log = tmp_path / "brain-live-day.jsonl"
    rows = [{"ts": t0 + 1100, "kind": "event", "event": {"type": "activity", "kind": "combat_end", "outcome": "died",
                                                         "target": "Garou", "by": "reflex", "ts": t0 + 1100}},
            {"ts": t0 + 1150, "kind": "death_during_call", "tool": "go_to", "ago_s": 3, "cause": "a fall"},
            {"ts": t0 + 1160, "kind": "bridge_recv", "msg": {"ok": True, "data": {"hydration": 50, "position": BV,
                                                                                   "inventory": {"x": 1}}}},
            {"ts": t0 + 1170, "kind": "prompt", "component": "controller", "model": "claude-haiku-5-5",
             "messages": ["long"]},
            {"ts": t0 + 1171, "kind": "llm_response", "component": "controller", "usage": {"prompt": 1000}}]
    log.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    rec = {**rec, "brain_logs": [log.name]}
    got = ds.brain_rows(rec, tmp_path)
    assert [r["kind"] for r in got] == ["event", "death_during_call", "bridge_recv", "prompt", "llm_response"]
    assert got[2]["msg"] == {"data": {"position": BV}} and "messages" not in got[3]
    sc = ds.score(rec, got)
    assert sc["deaths"]["n"] == 4 and sc["deaths"]["brain_log_read"]
    # the brain's own read at 1160 s has him back in Bramblemead between two samples on the plains
    assert [e["region"] for e in sc["regions"]["entries"]][-3:] == ["Fractured Plains", "Bramblemead Valley",
                                                                     "Fractured Plains"]
    assert sc["regions"]["entries"][-2]["t"] == 1160.0
    assert sc["spend"]["from"] == "brain log" and sc["spend"]["haiku"] == 1


def test_luis_baselines_exist_where_he_has_them_and_the_missing_are_named(day):
    b = ds.luis()
    assert b["tasks"] == 41 and b["first_action_median_s"] == 1.2
    assert b["idle"]["share"] == pytest.approx(0.029, abs=0.001)
    assert b["press_misses"]["n"] == 33 and b["press_misses"]["per_5min"] == pytest.approx(6.61, abs=0.01)
    assert b["stands_over_5s"]["n"] == 48 and b["deaths"]["n"] is None and "180" in b["deaths"]["how"]
    assert "power level per hour" in b["missing"] and "regions per hour" in b["missing"]
    rows = {r["what"]: r for r in ds.compare(ds.score(day[1]), b)}
    assert rows["power level per hour"]["luis"] is None and rows["power level per hour"]["note"].startswith("no baseline")
    assert rows["misses per 5 min of work"]["luis"] == b["press_misses"]["per_5min"]
    assert "not the harness's miss" in rows["misses per 5 min of work"]["note"]


def test_luis_deaths_from_the_standard_report_when_the_vm_has_it(tmp_path):
    rep = tmp_path / "standard.json"
    rep.write_text(json.dumps({"windows": [{"deaths": 0, "idle_runs": [4.7, 2.6]}, {"deaths": 0, "idle_runs": []}]}))
    b = ds.luis(standard_path=rep)
    assert b["deaths"]["n"] == 0 and b["deaths"]["windows"] == 2 and b["idle"]["longest_s"] == 4.7


def test_the_report_says_each_figure_and_what_has_no_baseline(day, capsys):
    sc = ds.score(day[1])
    text = ds.report(sc)
    for want in ("power level 1 -> 2", "Mining 5->6", "Temple Woods (power 1, 0 s) > Bramblemead Valley",
                 "deaths 2", "misses 3", "longest stand", "stock: 0 s carried 6 food 3 drink, chests 4 food 0 drink",
                 "spend $", "bars: deaths NO, stands NO, counted ok -> FAIL", "no baseline of Luis's for: power level per hour"):
        assert want in text, want
    print(text)


# ------------------------------------------------------------------ the row, the record, the ledger
def test_finish_writes_one_row_and_the_record_and_the_ledger_sees_it(day, tmp_path, capsys, monkeypatch):
    from tools import failure_ledger as fl
    _, rec = day
    row = ds.finish(rec)
    assert row["day_row"] and row["deaths"] == 2 and row["pass"] is False and "power level 1 -> 2" in capsys.readouterr().out
    rows = ds.all_rows()
    assert len(rows) == 1 and rows[0]["run"] == rec["run"] and rows[0]["done"] is True
    assert json.loads(open(rows[0]["record"], encoding="utf-8").read())["run"] == rec["run"]
    ledger = tmp_path / "ledger.jsonl"
    new = fl.scan(ds.ledger_recs(), ds.ledger_verdict, ds.ledger_not_counted, path=ledger)
    assert len(new) == 1 and new[0]["item"] == f"day: claude, {ASK}"
    assert set(new[0]["bars"]) == {"deaths", "stands"}
    # the first thing that went wrong: the earliest stand over 5 s or death
    first = min([float(i["from"]) for i in rec["idle_over_5s"]] + rows[0]["deaths_t"])
    assert new[0]["at_s"] == round(first, 1)
    assert fl.scan(ds.ledger_recs(), ds.ledger_verdict, ds.ledger_not_counted, path=ledger) == []  # once
    from tools import quest_run as q
    (tmp_path / "quest_runs.jsonl").write_text("", encoding="utf-8")
    monkeypatch.setattr(q, "OUT", tmp_path / "quest_runs.jsonl")
    monkeypatch.setattr(j, "OUT", tmp_path / "job_runs.jsonl")
    monkeypatch.setattr(fl, "gate_runs", lambda: [])
    srcs = fl._all_recs()  # the ledger's own sources hold the day runs
    assert any(any(r.get("run") == rec["run"] for r in recs) for recs, _, _ in srcs)


def test_a_day_not_counted_is_left_out_of_the_ledger(tmp_path):
    from tools import failure_ledger as fl
    row = {"run": "20261122-100000-D", "item": "day: x", "not_counted": "stopped", "verdict": {"pass": False, "bars": {}}}
    assert fl.scan([row], ds.ledger_verdict, ds.ledger_not_counted, path=tmp_path / "l.jsonl") == []


def test_job_run_verdict_hands_a_day_to_day_score(day):
    _, rec = day
    assert j.verdict(rec)["bars"] == {"deaths": False, "stands": False, "counted": True}


# ------------------------------------------------------------------ the brain log read as it grows
def test_row_tail_reads_whole_lines_as_they_come_and_slims(tmp_path):
    from tools import chat_ladder as cl
    f = tmp_path / "brain-live-x.jsonl"
    big = {"hydration": 40, "position": [1, 2, 3], "inventory_items": [{"item": "x"}] * 50}
    rows = [{"ts": 10.0, "kind": "bridge_recv", "msg": {"id": "a", "ok": True, "data": big}},
            {"ts": 11.0, "kind": "prompt", "component": "controller", "model": "claude-haiku-5-5", "messages": ["x" * 999]},
            {"ts": 12.0, "kind": "tool_call", "call": "c1", "tool": "gather", "args": {"r": 1}}]
    f.write_bytes(("".join(json.dumps(r) + "\n" for r in rows[:2]) + json.dumps(rows[2])[:20]).encode())
    tail = j.RowTail()
    got = tail.read([f], 0, 100)
    assert [r["kind"] for r in got] == ["bridge_recv", "prompt"]  # the half-written line waits
    assert got[0]["msg"] == {"id": "a", "ok": True, "data": {"position": [1, 2, 3], "hydration": 40}}
    assert got[1] == {"ts": 11.0, "kind": "prompt", "component": "controller", "model": "claude-haiku-5-5"}
    f.write_bytes(("".join(json.dumps(r) + "\n" for r in rows)).encode())
    assert [r["kind"] for r in tail.read([f], 0, 100)] == ["bridge_recv", "prompt", "tool_call"]
    assert [r["kind"] for r in tail.read([f], 10.5, 100)] == ["prompt", "tool_call"]
    whole = j.RowTail(slim=None).read([f], 0, 100)
    assert whole == cl.brain_rows([f], 0, 100)  # unslimmed, the same rows the trial reads


def test_live_reads_the_log_as_it_grows_only_in_a_day():
    import argparse
    assert isinstance(j.Live(argparse.Namespace(ask=ASK), None, None).tail, j.RowTail)
    assert j.Live(argparse.Namespace(job="L2"), None, None).tail is None


# ------------------------------------------------------------------ the window: one trial, the world restored once
@pytest.fixture
def day_window(tmp_path, monkeypatch):
    from tests.test_checkpoint_pair import Rig, Window, keep_world, save_text
    rig = Rig(tmp_path)
    rig.at = []
    (rig.tmp / "checkpoints").mkdir(exist_ok=True)
    (rig.tmp / "checkpoints" / "ClaudeDev.json").write_text(save_text(name="ClaudeDev", guid="E71C"))
    keep_world(rig, "base")
    w = Window(rig, monkeypatch)
    w.started_on, w.jobs = [], []

    def run_job(io, job, opts):  # the trial meets the world as it is, then leaves pieces in it
        w.started_on.append(rig.world_bytes())
        rig.write_world(b"pieces-of-the-day")
        w.jobs.append((job, opts))
        return {"run": "20261122-100000-D", "kind": "day", "ended": "deadline", "wall_s": opts["deadline"],
                "active_s": opts["deadline"], "misses": {"n": 0, "list": [], "per_5min": 0.0},
                "idle_over_5s": [], "idle_total_s": 0.0, "longest_stand_s": 0, "lines": [{"t": 0.0}],
                "day": {"ask": job["line"], "budget_s": opts["deadline"], "trace": [], "stock": []}}
    monkeypatch.setattr(j, "run_job", run_job)
    monkeypatch.setattr(j, "day_spend_refusal", lambda usd: None)
    monkeypatch.setattr(ds, "brain_rows", lambda rec, log_dir=None: [])
    return rig, w


def _day_main(w, *argv):
    return w.j.main(["day", "--confirm", "--ask", ASK, *argv])


def test_a_day_restores_its_named_world_once_and_runs_one_trial(day_window, capsys):
    rig, w = day_window
    assert _day_main(w, "--world", "base", "--budget", "600") == 0
    assert w.resets == 1 and len(w.forked) == 1 and w.started_on == [b"world-at-start"]
    assert rig.calls == [("stop_client.ps1", "-Hold"), ("stop_server.ps1", "-Hold"), ("start_server.ps1",)]
    job, opts = w.jobs[0]
    assert job["line"] == f"claude, {ASK}" and job["day"] and opts["deadline"] == 600 and opts["job_deadline"] == 600
    out = capsys.readouterr().out
    assert "restored once at the start" in out and "quiet never ends it, no re-ask" in out
    row = json.loads((rig.tmp / "job_windows.jsonl").read_text().splitlines()[-1])
    assert row["job"] == "day" and row["day"]["budget_s"] == 600 and row["world"] == "base"
    assert row["trials"][0]["day_row"] and row["trials"][0]["end_class"] == "budget"
    (day_row,) = ds.all_rows()
    assert day_row["world"] == "base" and day_row["world_restore"]["label"] == "base" and day_row["end_class"] == "budget"


def test_a_day_needs_a_named_world_and_room_for_its_budget(day_window, capsys):
    rig, w = day_window
    assert _day_main(w, "--budget", "600") == 2
    assert "a day of play with no world to restore at its start" in capsys.readouterr().out
    assert _day_main(w, "--world", "base", "--window-s", "3600") == 2  # 7200 s of budget
    assert "does not fit the window" in capsys.readouterr().out
    assert w.ensured == [] and w.forked == [] and w.resets == 0


def test_a_day_over_the_daily_spend_guard_is_refused(day_window, monkeypatch, capsys):
    rig, w = day_window
    monkeypatch.setattr(j, "day_spend_refusal", lambda usd: f"today's $9.00 and this day's cap ${usd:.2f} pass")
    assert _day_main(w, "--world", "base", "--budget", "600", "--usd", "6") == 2
    assert "not running: today's $9.00 and this day's cap $6.00" in capsys.readouterr().out and w.forked == []


def test_day_spend_refusal_reads_the_guard(monkeypatch, capsys):
    from tools import spend
    monkeypatch.setattr(spend, "spend_today", lambda: {"spent_usd": 3.0})
    monkeypatch.setattr(spend, "day_cap_usd", lambda: 10.0)
    assert j.day_spend_refusal(6.0) is None and "today $3.00 of the day's $10.00" in capsys.readouterr().out
    assert "pass the daily $10.00" in j.day_spend_refusal(8.0)

    def broken():
        raise OSError("no logs")
    monkeypatch.setattr(spend, "spend_today", broken)
    assert "could not be read" in j.day_spend_refusal(1.0)


def test_cli_day_refuses_without_confirm_and_a_short_budget(capsys):
    assert j.main(["day", "--ask", ASK, "--world", "base"]) == 2
    assert "pass --confirm" in capsys.readouterr().out
    assert j.main(["day", "--confirm", "--ask", ASK, "--budget", "10"]) == 2
    with pytest.raises(SystemExit):
        j.main(["day", "--confirm"])  # --ask is required

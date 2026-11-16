"""The quest working loop (docs/GOAL-2026-11-01.md "How the work is run"): checkpoints and forks (tools/quest_clone.py),
K trials of one step in one window, pass rates with void runs left out and the chain guard (tools/quest_run.py), and
the failure ledger (tools/failure_ledger.py). All offline: the switch, the lock and the run itself are fakes."""
from __future__ import annotations

import argparse
import contextlib
import json
import os

import pytest

from tools import failure_ledger as fl
from tools import quest_clone as qc
from tools import quest_run as q

SAVE = ('{\r\n\t"Version": 86,\r\n\t"meta_data":\r\n\t{\r\n\t\t"char_guid": "AB12",\r\n\t\t"char_name": "ClaudeQ9",\r\n'
        '\t\t"char_type": 0\r\n\t},\r\n\t"Stats":\r\n\t{\r\n\t\t"Rate": 0.55555558204650879\r\n\t}\r\n}')


@pytest.fixture
def dirs(tmp_path, monkeypatch):
    for name in ("SAVE_DIR", "CHECKPOINT_DIR", "PARK_DIR"):
        d = tmp_path / name
        d.mkdir()
        monkeypatch.setattr(qc, name, d)
    (qc.SAVE_DIR / "ClaudeQ9.json").write_bytes(SAVE.encode("utf-8"))
    (qc.SAVE_DIR / "ClaudeDev.json").write_bytes(SAVE.replace("ClaudeQ9", "ClaudeDev").encode("utf-8"))
    return tmp_path


def rec(run, quest, ok=True, **kw):
    """A quest_runs record that passes every bar, or fails on one failed world call and a stand."""
    r = {"run": run, "quest": quest, "until": "complete", "character": "ClaudeQ1", "done": True, "ratio": 1.0,
         "ended": "quest complete", "wall_s": 60.0, "tool_calls": [], "idle_over_5s": [], "carried_at_start": {}}
    if not ok:
        r["tool_calls"] = [{"t": 12.0, "tool": "talk", "ok": False, "reason": "no_conversation"},
                           {"t": 30.0, "tool": "craft", "ok": False, "reason": "missing"}]
        r["idle_over_5s"] = [{"from": 20.0, "s": 7.0}]
    return {**r, **kw}


# --- checkpoints and forks -------------------------------------------------------------------------------------------

def test_a_fork_is_the_save_byte_for_byte_under_a_new_guid_and_name(dirs):
    target = qc.fork("ClaudeQ9", "ClaudeS1")
    text = target.read_bytes().decode("utf-8")
    meta = json.loads(text)["meta_data"]
    assert meta["char_name"] == "ClaudeS1" and len(meta["char_guid"]) == 32 and meta["char_guid"] != "AB12"
    assert text.replace(meta["char_guid"], "AB12").replace("ClaudeS1", "ClaudeQ9") == SAVE  # the float, tabs, CRLF: as written
    assert (qc.SAVE_DIR / "ClaudeQ9.json").read_bytes().decode("utf-8") == SAVE  # the source is only read


@pytest.mark.parametrize("name", ["ClaudeDev", "ClaudeQ9", "x", "has space", "ANameThatIsFarTooLongForTheGame"])
def test_a_fork_never_lands_on_an_existing_character_or_an_invalid_name(dirs, name):
    before = {p.name: p.read_bytes() for p in qc.SAVE_DIR.iterdir()}
    with pytest.raises(SystemExit):
        qc.fork("ClaudeQ9", name)
    assert {p.name: p.read_bytes() for p in qc.SAVE_DIR.iterdir()} == before


def test_a_checkpoint_label_is_found_before_a_character_of_the_same_name(dirs):
    assert qc.keep("ClaudeQ9", "rm_part2") == qc.CHECKPOINT_DIR / "rm_part2.json"
    (qc.SAVE_DIR / "rm_part2.json").write_text("{}")
    assert qc.source_of("rm_part2") == qc.CHECKPOINT_DIR / "rm_part2.json"
    with pytest.raises(SystemExit):
        qc.source_of("nope")
    for label in ("rm_part2", "../x"):  # a checkpoint is never overwritten, and a label is a plain name
        with pytest.raises(ValueError):
            qc.keep("ClaudeDev", label)
    assert "ClaudeQ9" in (qc.CHECKPOINT_DIR / "rm_part2.json").read_text(encoding="utf-8")
    (qc.SAVE_DIR / "Half.json").write_text('{"Version": 86, "meta')  # a save caught mid-write is not kept
    assert qc.keep("Half", "half", sleep=lambda s: None) is None and not (qc.CHECKPOINT_DIR / "half.json").exists()


def test_a_checkpoint_after_a_run_waits_for_a_save_the_game_wrote_after_it(dirs):
    src = qc.SAVE_DIR / "ClaudeQ9.json"
    os.utime(src, (1000.0, 1000.0))
    assert qc.keep("ClaudeQ9", "late", newer_than=2000.0, wait_s=0) is None  # the save on disk is from before the run ended
    assert not (qc.CHECKPOINT_DIR / "late.json").exists()

    def autosave(_s):  # the game's next save lands while we wait
        os.utime(src, (2500.0, 2500.0))
    assert qc.keep("ClaudeQ9", "late", newer_than=2000.0, wait_s=60, sleep=autosave) == qc.CHECKPOINT_DIR / "late.json"


def test_parking_moves_forks_and_their_backups_and_never_the_main_character(dirs):
    (qc.SAVE_DIR / "ClaudeQ9.json.backup").write_text("b")
    assert sorted(qc.park(["ClaudeQ9", "ClaudeDev", "Gone"])) == ["ClaudeQ9.json", "ClaudeQ9.json.backup"]
    assert sorted(p.name for p in qc.SAVE_DIR.iterdir()) == ["ClaudeDev.json"]
    assert sorted(p.name for p in qc.PARK_DIR.iterdir()) == ["ClaudeQ9.json", "ClaudeQ9.json.backup"]


# --- rates, void, the chain guard ------------------------------------------------------------------------------------

def test_rates_are_per_item_and_leave_out_void_probe_and_head_start_runs():
    recs = [rec("1", "First Steps"), rec("2", "First Steps"), rec("3", "First Steps", ok=False),  # 3: the harness's fault
            rec("4", "First Steps"),
            rec("5", "First Steps", until="change"),                                               # a probe
            rec("6", "Getting Started", carried_at_start={"ITEM_Club_Stone": 1}),                 # a head start
            rec("7", "Rune Mysteries", ok=False), rec("8", "Rune Mysteries", checkpoint="rm2"),
            rec("9", "Rune Mysteries", checkpoint="rm2", until_step="Speak to Zanik", carried_at_start={"ITEM_Rune_Air": 10})]
    r = q.rates(recs, void=set())
    assert r["First Steps"] == {"passes": 3, "of": 4, "streak": 1}
    assert q.rates(recs, void={"3"})["First Steps"] == {"passes": 3, "of": 3, "streak": 3}  # a void run resets nothing
    assert "Getting Started" not in r
    assert r["Rune Mysteries"] == {"passes": 0, "of": 1, "streak": 0}  # the gate's item: from the quest's start only
    assert r["Rune Mysteries @ rm2"]["passes"] == 1
    assert r["Rune Mysteries @ rm2 -> Speak to Zanik"] == {"passes": 1, "of": 1, "streak": 1}  # runes in the bag: by design


def test_the_chain_waits_until_every_quest_in_it_passes_four_of_its_last_five():
    recs = [rec(f"a{i}", "First Steps") for i in range(5)] + [rec("b1", "Rune Mysteries", ok=False), rec("b2", "Rune Mysteries")]
    why = q.chain_guard(recs, set(), ["First Steps", "Rune Mysteries", "Ratcatcher"])
    assert [w.split(":")[0] for w in why] == ["Rune Mysteries", "Ratcatcher"]  # 1 of 2, and none on record
    recs += [rec(f"c{i}", "Rune Mysteries", checkpoint="rm2") for i in range(3)]  # step trials count toward readiness
    assert q.chain_guard(recs, set(), ["First Steps", "Rune Mysteries"]) == []
    recs.append(rec("d1", "First Steps", ok=False))
    assert q.chain_guard(recs, set(), ["First Steps"]) == []          # 4 of 5
    recs.append(rec("d2", "First Steps", ok=False))
    assert len(q.chain_guard(recs, set(), ["First Steps"])) == 1      # 3 of 5
    assert q.chain_guard(recs, {"d1", "d2"}, ["First Steps"]) == []   # both were the harness's


def test_fresh_refuses_a_chain_that_is_not_ready_before_it_takes_the_lock(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(q, "OUT", tmp_path / "runs.jsonl")
    monkeypatch.setattr(fl, "LEDGER", tmp_path / "ledger.jsonl")
    monkeypatch.setattr(q, "clone_window", lambda *a, **k: pytest.fail("the window was opened"))
    a = argparse.Namespace(confirm=True, name="ClaudeQ1", start=None, chain_anyway=None, wait=0)
    assert q.cmd_fresh(a) == 6
    assert "First Steps: 0 of its last 0" in capsys.readouterr().out


# --- the step window -------------------------------------------------------------------------------------------------

class Switch:
    def __init__(self):
        self.on = []

    def ensure(self, name, create=False, wait_s=0):
        assert (qc.SAVE_DIR / f"{name}.json").is_file()  # the fork's save is there before the switch
        self.on.append(name)
        return {"character": name}


@pytest.fixture
def window(dirs, monkeypatch):
    """The window's outside world as fakes: the lock, the dev server, the switch, the body and the run."""
    import evals.bench.devchar as devchar
    import evals.bench.devrun as devrun
    import tools.live_lock as live_lock
    sw = Switch()
    monkeypatch.setattr(live_lock, "held", lambda owner, wait_s=0: contextlib.nullcontext())
    monkeypatch.setattr(devrun, "default_dev", lambda: argparse.Namespace())
    monkeypatch.setattr(devchar, "default_switch", lambda dev: sw)
    monkeypatch.setattr(q.cl, "_debug_client", lambda: object())
    monkeypatch.setattr(q, "_on_main", lambda s, c, tries=3: (s.on.append("ClaudeDev"), {"character": "ClaudeDev"})[1])
    monkeypatch.setattr(q, "OUT", dirs / "runs.jsonl")
    monkeypatch.setattr(q, "STEP_OUT", dirs / "steps.jsonl")
    return sw


def step_args(**kw):
    return argparse.Namespace(**{"confirm": True, "checkpoint": "ClaudeQ9", "quest": "Rune Mysteries", "line": None,
                                 "until_step": None, "k": 3, "deadline": 600.0, "save_as": None, "keep_forks": False,
                                 "wait": 0, "window_s": 3600.0, "reserve_s": 240.0, "max_haiku": 60, "usd": 0.4,
                                 "regrow_days": 0, **kw})


def test_k_trials_each_start_on_a_new_fork_and_the_window_ends_on_the_main_character(window, monkeypatch, capsys):
    seen = []

    def run(ns):
        seen.append(ns)
        ok = len(seen) != 2
        r = rec(f"r{len(seen)}", ns.quest, ok=ok, character=ns.character, checkpoint=ns.checkpoint)
        with q.OUT.open("a", encoding="utf-8") as f:
            f.write(json.dumps({**r, "verdict": q.verdict(r)}) + "\n")
        return 0
    monkeypatch.setattr(q, "cmd_run", run)
    assert q.cmd_step(step_args()) == 1  # one of three failed
    forks = [ns.character for ns in seen]
    assert len(set(forks)) == 3 and window.on == [*forks, "ClaudeDev"]
    assert all(ns.in_lock and ns.no_heal and ns.checkpoint == "ClaudeQ9" and ns.until == "complete" for ns in seen)
    assert seen[0].line == [q.FRESH_PLAN[3][1]]  # the quest's own line when none is given
    assert "2 of 3 passed" in capsys.readouterr().out
    assert sorted(p.name for p in qc.SAVE_DIR.iterdir()) == ["ClaudeDev.json", "ClaudeQ9.json"]  # the forks are parked
    assert len(list(qc.PARK_DIR.iterdir())) == 3
    row = json.loads(q.STEP_OUT.read_text(encoding="utf-8"))
    assert [t["pass"] for t in row["trials"]] == [True, False, True] and row["back"] == {"character": "ClaudeDev"}


def test_a_window_that_breaks_still_ends_on_the_main_character_and_records_why(window, monkeypatch):
    def run(ns):
        raise RuntimeError("the brain did not start")
    monkeypatch.setattr(q, "cmd_run", run)
    assert q.cmd_step(step_args(k=2)) == 1
    assert window.on[-1] == "ClaudeDev" and len(window.on) == 2  # one fork, then home: no second trial
    assert "the brain did not start" in json.loads(q.STEP_OUT.read_text(encoding="utf-8"))["error"]


def test_a_wrong_checkpoint_label_never_costs_a_window(window):
    with pytest.raises(SystemExit):
        q.cmd_step(step_args(checkpoint="nope"))
    assert window.on == []


def test_a_taken_save_as_label_is_refused_before_the_window(window):
    qc.keep("ClaudeQ9", "next")
    assert q.cmd_step(step_args(save_as="next")) == 2 and window.on == []


def test_the_first_done_trial_is_kept_as_the_next_checkpoint_once_the_game_has_saved_it(window, monkeypatch):
    def run(ns):
        r = rec("r1", ns.quest, character=ns.character, checkpoint=ns.checkpoint)
        with q.OUT.open("a", encoding="utf-8") as f:
            f.write(json.dumps({**r, "verdict": q.verdict(r)}) + "\n")
        os.utime(qc.SAVE_DIR / f"{ns.character}.json", (q.time.time() + 60, q.time.time() + 60))  # the autosave after it
        return 0
    monkeypatch.setattr(q, "cmd_run", run)
    assert q.cmd_step(step_args(k=1, save_as="rm_part3")) == 0
    kept = json.loads((qc.CHECKPOINT_DIR / "rm_part3.json").read_text(encoding="utf-8"))
    assert kept["meta_data"]["char_name"].startswith("ClaudeS")  # the fork's save, as the game wrote it after the run


def test_the_window_stops_forking_when_the_time_left_would_not_fit_a_trial(window, monkeypatch):
    monkeypatch.setattr(q, "cmd_run", lambda ns: pytest.fail("a trial ran"))
    assert q.cmd_step(step_args(window_s=300.0)) == 1  # 300 - 240 reserve - 70 switch: nothing left
    assert window.on == ["ClaudeDev"] and sorted(p.name for p in qc.SAVE_DIR.iterdir()) == ["ClaudeDev.json", "ClaudeQ9.json"]


PLACED = SAVE.replace('"Stats":', '"GameProgress":{"Character":{"LastAccessibleLocation":{"Position":'
                      '"V(X=26785.72, Y=182498.32, Z=-4204.14)"}}},"Stats":')


class Body:
    """go_to answers from a list (the last answer repeats); get_state says where he is."""

    def __init__(self, answers, position=None):
        self.answers, self.position, self.sent = list(answers), position, []

    def request(self, tool, args, timeout=0):
        self.sent.append((tool, args))
        if tool == "get_state":
            return {"ok": True, "data": {"position": self.position}}
        return self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]


def test_a_checkpoint_names_the_place_its_save_was_written_at_in_metres(dirs):
    assert qc.place_of("ClaudeQ9") is None  # a save without one
    (qc.CHECKPOINT_DIR / "at_zanik.json").write_bytes(PLACED.encode("utf-8"))
    assert qc.place_of("at_zanik") == [267.86, 1824.98, -42.04]


def test_a_trial_is_walked_to_the_checkpoints_place_before_its_clock(window, monkeypatch):
    (qc.CHECKPOINT_DIR / "at_zanik.json").write_bytes(PLACED.encode("utf-8"))
    body = Body([{"ok": False, "reason": "no_path"}, {"ok": True, "data": {"trip": "Walked 233 m in 37 s"}}])
    monkeypatch.setattr(q.cl, "_debug_client", lambda: body)
    order = []

    def run(ns):
        order.append(("run", len(body.sent)))
        r = rec("r1", ns.quest, character=ns.character, checkpoint=ns.checkpoint)
        with q.OUT.open("a", encoding="utf-8") as f:
            f.write(json.dumps({**r, "verdict": q.verdict(r)}) + chr(10))
        return 0
    monkeypatch.setattr(q, "cmd_run", run)
    assert q.cmd_step(step_args(k=1, checkpoint="at_zanik")) == 0
    assert body.sent == [("go_to", {"target": [267.86, 1824.98, -42.04]})] * 2 and order == [("run", 2)]
    row = json.loads(q.STEP_OUT.read_text(encoding="utf-8"))
    assert row["place"] == [267.86, 1824.98, -42.04]
    assert row["trials"][0]["start"]["ok"] and row["trials"][0]["start"]["tries"] == 2 and row["trials"][0]["pass"]


def test_a_fork_that_does_not_get_to_the_place_is_not_a_trial(window, monkeypatch):
    (qc.CHECKPOINT_DIR / "at_zanik.json").write_bytes(PLACED.encode("utf-8"))
    body = Body([{"ok": False, "reason": "no_path", "data": {"detail": "the walkable map ends 3 m short"}}],
                position=[52.9, 1890.2, -35.3])
    monkeypatch.setattr(q.cl, "_debug_client", lambda: body)
    monkeypatch.setattr(q, "cmd_run", lambda ns: pytest.fail("a trial ran from the wrong place"))
    assert q.cmd_step(step_args(k=1, checkpoint="at_zanik")) == 1
    t = json.loads(q.STEP_OUT.read_text(encoding="utf-8"))["trials"][0]
    assert t["skipped"] == "not at the checkpoint's place" and "3 m short" in t["start"]["why"] and "pass" not in t
    assert window.on[-1] == "ClaudeDev"


def test_a_walk_that_ends_within_reach_of_the_place_counts_as_there():
    body = Body([{"ok": False, "reason": "blocked"}], position=[266.0, 1824.0, -41.2])
    assert q.to_start(body, [267.86, 1824.98, -42.04], tries=2)["ok"]
    assert q.to_start(body, None) is None and len(body.sent) == 3  # two walks and one read; no place, no walk


# --- a run that ends at a step ---------------------------------------------------------------------------------------

def test_a_run_ends_done_when_the_quest_reaches_the_step_asked_for(tmp_path, monkeypatch):
    import tools.m1_session as m1
    log = [{"active": [{"quest": "Rune Mysteries", "step": "Mine Rune Essence, craft some Air and Astral Runes."}]},
           {"active": [{"quest": "Rune Mysteries", "step": "Mine Rune Essence, craft some Air and Astral Runes."}]},
           {"active": [{"quest": "Rune Mysteries", "step": "Speak to Zanik."}]}]

    class Cli:
        def request(self, tool, args, timeout=None):
            if tool == "quests":
                return {"ok": True, "data": log.pop(0) if len(log) > 1 else log[0]}
            return {"ok": True, "data": {}}
    monkeypatch.setattr(q, "preflight", lambda a: [])
    monkeypatch.setattr(q.cl, "ensure_sender", lambda: (True, ""))
    monkeypatch.setattr(q.spend, "spend_today", lambda: {"spent_usd": 0.0})
    monkeypatch.setattr(q.cl, "start_brain", lambda a, spent: (None, tmp_path / "brain-live-x.jsonl"))
    monkeypatch.setattr(q.cl, "stop_brain", lambda p: None)
    monkeypatch.setattr(q.cl, "_debug_client", lambda: Cli())
    monkeypatch.setattr(q.cl, "brain_rows", lambda files, a, b: [])
    monkeypatch.setattr(q.cl, "model_calls", lambda rows: {"haiku": 0, "sonnet": 0, "usd": 0.0, "calls": 0})
    monkeypatch.setattr(m1, "send_speech_direct", lambda line: (True, ""))
    monkeypatch.setattr(q.time, "sleep", lambda s: None)
    monkeypatch.setattr(q, "OUT", tmp_path / "runs.jsonl")
    a = argparse.Namespace(confirm=True, quest="Rune Mysteries", line=["claude, do her quest"], until="complete",
                           until_step="speak to zanik", deadline=600.0, max_haiku=60, usd=0.4, world="dev_x", wait=0,
                           grant=[], judge=False, in_lock=True, no_heal=True, character="ClaudeS1", checkpoint="rm2")
    assert q.cmd_run(a) == 0
    r = json.loads(q.OUT.read_text(encoding="utf-8"))
    assert r["ended"] == "quest step reached" and r["done"] is True
    assert r["checkpoint"] == "rm2" and r["until_step"] == "speak to zanik" and r["character"] == "ClaudeS1"
    assert q.item_key(r) == "Rune Mysteries @ rm2 -> speak to zanik"


# --- the ledger ------------------------------------------------------------------------------------------------------

def test_the_ledger_names_the_first_thing_that_went_wrong_once_per_failed_run(tmp_path):
    p = tmp_path / "ledger.jsonl"
    recs = [rec("1", "First Steps"), rec("2", "Rune Mysteries", ok=False),
            rec("3", "Rune Mysteries", done=False, ended="deadline", wall_s=900.0),
            rec("4", "Ratcatcher", ratio=1.8), rec("5", "Getting Started", ok=False, carried_at_start={"ITEM_Club_Stone": 1})]
    new = fl.scan(recs, q.verdict, q.not_counted, path=p)
    assert [(r["run"], r["at_s"], r["first_wrong"]) for r in new] == [
        ("2", 12.0, "miss: talk no_conversation"),   # the miss at 12 s, before the stand at 20 s and the miss at 30 s
        ("3", 900.0, "not done: deadline"), ("4", 60.0, "bar: time")]  # 1 passed; 5 had a head start: neither is a row
    assert new[0]["bars"] == ["misses", "stands"]
    assert fl.scan(recs, q.verdict, q.not_counted, path=p) == [] and len(fl.rows(p)) == 3  # a second scan adds nothing


def test_tags_count_by_cause_and_a_void_run_is_named_for_the_rates(tmp_path):
    p = tmp_path / "ledger.jsonl"
    fl.scan([rec(str(i), "Rune Mysteries", ok=False) for i in range(4)] + [rec("9", "First Steps", ok=False)],
            q.verdict, q.not_counted, path=p)
    assert fl.tag(["0", "1"], "game", "runes crafted but the quest flags never set", False, None, path=p) == 2
    assert fl.tag(["9"], "harness", "line sent before the brain's warm-up ended", True, "abc1234", path=p) == 1
    assert fl.voided(p) == {"9"}
    c = fl.counts(fl.rows(p))
    assert [(g["class"], g["n"], g["open"]) for g in c] == [("game", 2, 2), ("untagged", 2, 2), ("harness", 1, 0)]
    assert c[1]["cause"] == "miss: talk no_conversation" and c[0]["items"] == {"Rune Mysteries": 2}
    assert fl.tag(["0"], None, None, False, "def5678", path=p) == 1  # a fix alone keeps the class and cause
    assert fl.rows(p)[0]["class"] == "game" and fl.rows(p)[0]["fix"] == "def5678"


def test_a_passed_run_touched_by_a_harness_fault_can_be_voided(tmp_path):
    # 20261116-215441: an uncommitted combat.lua was hot-loaded into the client for 19 s of a trial that passed
    p = tmp_path / "ledger.jsonl"
    recs = [rec("1", "Ratcatcher"), rec("2", "Ratcatcher", ok=False)]
    fl.scan(recs, q.verdict, q.not_counted, path=p)
    assert fl.tag(["1"], "harness", "a module was swapped mid-trial", False, None, path=p, recs=recs) == 0  # not void: no row
    assert fl.tag(["1", "7"], "harness", "a module was swapped mid-trial", True, None, path=p, recs=recs) == 1  # 7 is no run
    row = fl.rows(p)[-1]
    assert (row["run"], row["item"], row["passed"], row["void"], row["first_wrong"]) == (
        "1", "quest: Ratcatcher", True, True, "passed, not counted")
    assert fl.voided(p) == {"1"}
    assert fl.tag(["1"], "harness", "a module was swapped mid-trial", True, None, path=p, recs=recs) == 1  # no second row
    assert len(fl.rows(p)) == 2
    assert fl.scan(recs, q.verdict, q.not_counted, path=p) == []


# --- the day's spend cap ---------------------------------------------------------------------------------------------

def test_a_cap_set_for_one_day_holds_for_that_day_only_and_a_runs_allowance_still_wins(tmp_path, monkeypatch):
    from datetime import date
    from tools import spend
    f = tmp_path / "caps.json"
    f.write_text(json.dumps({"days": {"2026-11-16": {"usd": 20.0}}}), encoding="utf-8")
    monkeypatch.setattr(spend, "DAY_CAPS_FILE", f)
    monkeypatch.delenv("DW_SPEND_CAP_USD", raising=False)
    monkeypatch.delenv("DW_DAILY_CAP_USD", raising=False)
    assert spend.day_cap_usd(date(2026, 11, 16)) == 20.0 and spend.day_cap_usd(date(2026, 11, 17)) == 10.0
    monkeypatch.setenv("DW_DAILY_CAP_USD", "12")
    assert spend.day_cap_usd(date(2026, 11, 17)) == 12.0 and spend.cap_usd(date(2026, 11, 16)) == 20.0
    monkeypatch.setenv("DW_SPEND_CAP_USD", "2.5")  # a harness run's allowance
    assert spend.cap_usd(date(2026, 11, 16)) == 2.5
    monkeypatch.setattr(spend, "DAY_CAPS_FILE", tmp_path / "none.json")
    assert spend.day_cap_usd(date(2026, 11, 16)) == 12.0

"""tools/job_run.py after the first N1 window (logs/window_n1_1118d.txt, 2026-11-18 01:40-02:10Z). Offline, fakes only.

1. The checkpoint `--until first_step --save-as job_n1_mid` was saved with all 20 ash and 10 stone carried (progress
   about 0.8 of the job, read at I2's start), so I2 deposited at 16 s and was done at 21 s, before the interruption
   took: `--until mid` ends a probe at a moment read from the game (progress between 0.2 and 0.6, nothing of the
   job stored yet), and the save is kept only when the end read says so.
2. I1: the sender's prove failed (the server's Lua could not call GetCharacterDisplayName) and the trial said only
   "brain did not start": the reason is kept, the prove is tried again, and the window says what it needs.
3. I4: the nav helper's heartbeat was stale at the preflight (the watchdog's restart cap): the window waits for it.
4. The I2 crate: the record said job_done true, done false, chests mine false and own_containers listed it. Whose
   a container is comes from the game's owner read when the body reports one; done is the job's end in every
   record (a step's own verdict is `resumed`); a probe carries `probe` and failure_ledger.scan skips it.
"""
from __future__ import annotations

import pytest

from tools import job_run as j
from tests.test_job_run import CRATE, T0, FakeIO, call, model, result, state

ASH, STONE = "ITEM_Resources_Wood_Ash", "ITEM_Resources_Stone"
DEV_GUID = "E71C5DC146F0A55B69FF52A881255DEF"   # ClaudeDev (the world 'base' crates' OwningCharacterGuid)
FORK_GUID = "11111111222222223333333344444444"
LUIS_GUID = "B0E56055497E9F8CA6003C955B47A47F"


@pytest.fixture(scope="module")
def doc():
    return j.load_jobs()


# ------------------------------------------------------------------ 1. a real mid-job checkpoint
def test_until_takes_mid_with_a_progress_window():
    assert j.until_ok("mid") and j.until_ok("mid:0.25-0.5") and j.until_ok("done") and j.until_ok("first_step")
    assert not j.until_ok("mid:0.7-0.2") and not j.until_ok("mid:x") and not j.until_ok("half")
    assert j.mid_range("mid") == (0.2, 0.6) and j.mid_range("mid:0.25-0.5") == (0.25, 0.5)
    assert j.mid_range("done") is None and j.mid_range("first_step") is None


def gathering(rate_s=1.0, start_at=5.0, top=20):
    """get_state while he picks up ash one log every rate_s from start_at: 1 ash and 5 stone at the start."""
    def st(t):
        n = 1 + max(0, min(top - 1, int((t - T0 - start_at) / rate_s)))
        return state(carried={ASH: n, STONE: 5}, mine=[CRATE])
    return st


def test_mid_probe_ends_inside_the_window_before_any_deposit(doc):
    script = model(T0 + 1) + [call(T0 + 3, "g1", "gather", {"resource": "ash", "count": 19}),
                              result(T0 + 60, "g1", "gather", data={"detail": "Got 19 ash."})]
    io = FakeIO(script=script, states=gathering())
    rec = j.run_job(io, j.job_of("N1", doc), {"until": "mid"})
    assert rec["ended"] == "mid-job" and rec["probe"] is True
    m = rec["mid"]
    assert 0.2 <= m["progress"] <= 0.6 and m["ok"] and not m["deposited"]
    assert j.save_ok(rec, "mid")[0]
    assert j.not_counted(rec).startswith("a checkpoint probe")


def test_mid_probe_that_overshot_is_not_saved(doc):
    # one gather call put all 19 logs on him at once (the window's probe: 19 ash at 38 s): past 0.6, no checkpoint
    script = model(T0 + 1) + [call(T0 + 3, "g1", "gather", {"resource": "ash", "count": 19}),
                              result(T0 + 20, "g1", "gather", data={"detail": "Got 19 ash."})]
    io = FakeIO(script=script, states=lambda t: state(carried={ASH: 1 if t < T0 + 20 else 20, STONE: 5}, mine=[CRATE]))
    rec = j.run_job(io, j.job_of("N1", doc), {"until": "mid", "deadline": 120})
    assert rec["mid"]["progress"] > 0.6 and not rec["mid"]["ok"]
    ok, why = j.save_ok(rec, "mid")
    assert not ok and "0.6" in why


def test_mid_probe_after_a_deposit_is_not_saved(doc):
    rows = model(T0 + 1) + [call(T0 + 3, "g1", "gather"), result(T0 + 8, "g1", "gather"),
                            call(T0 + 9, "s1", "store", {"item": "Ash Logs"}),
                            result(T0 + 10, "s1", "store", data={"container": CRATE, "item": ASH, "count": 4,
                                                                 "inside_now": 4, "contents": ["4 Ash Logs"]})]
    io = FakeIO(script=rows, states=lambda t: state(carried={ASH: 1 if t < T0 + 8 else 5, STONE: 5}, mine=[CRATE]),
                chests={CRATE: [{"item": ASH, "name": "Ash Logs", "count": 4}]})
    rec = j.run_job(io, j.job_of("N1", doc), {"until": "mid", "deadline": 60})
    assert rec["ended"] != "mid-job" and rec["mid"]["deposited"] and not j.save_ok(rec, "mid")[0]


def test_save_ok_for_the_other_untils():
    assert j.save_ok({"ended": "first step", "job_done": False}, "first_step")[0]
    assert j.save_ok({"ended": "job done", "job_done": True}, "done")[0]
    assert not j.save_ok({"ended": "quiet", "job_done": False}, "done")[0]


def test_the_progress_trigger_is_read_more_often_than_the_end_samples(doc):
    # the interruption at progress:0.5 goes in within a few seconds of him reaching it, not on the 15 s sample
    script = model(T0 + 1) + [call(T0 + 3, "g1", "gather", {"resource": "ash", "count": 19}),
                              result(T0 + 60, "g1", "gather", data={"detail": "Got 19 ash."})]
    io = FakeIO(script=script, states=gathering())
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I1", "interruptions": doc["interruptions"],
                                              "trigger": "progress:0.5", "deadline": 90})
    m = rec["interruption"]["moment"]
    assert 0.5 <= m["progress"] <= 0.6, m


def test_n1_points_at_a_new_mid_job_checkpoint(doc):
    job = j.job_of("N1", doc)
    assert job["interrupt_from"] != "job_n1_mid"  # saved with the whole job carried: never used again


# ------------------------------------------------------------------ probes are not trials
def test_a_probe_is_never_a_failed_trial(tmp_path):
    from tools import failure_ledger
    probe = {"run": "20261118-014312-N1", "item": "job: N1", "kind": "job", "until": "first_step",
             "ended": "first step", "done": False, "job_done": False, "wall_s": 40.7, "tool_calls": [],
             "idle_over_5s": [{"from": 9.7, "s": 7.6}], "verdict": {"pass": False}}
    assert j.not_counted(probe).startswith("a checkpoint probe")
    assert failure_ledger.scan([probe], j.verdict, j.not_counted, path=tmp_path / "ledger.jsonl") == []
    assert j.rates([probe], set()) == {}


# ------------------------------------------------------------------ 2. the sender and the brain start
class NoSender(FakeIO):
    start_why = "sender: speech_direct prove failed: attempt to call a nil value (method 'GetCharacterDisplayName')"

    def start_brain(self):
        return False


def test_a_failed_brain_start_says_why(doc):
    rec = j.run_job(NoSender(), j.job_of("N1", doc), {"step": "I1", "interruptions": doc["interruptions"]})
    assert rec["error"].startswith("brain did not start: sender:") and "GetCharacterDisplayName" in rec["error"]
    assert j.sender_fault(rec["error"])


def test_ensure_sender_tries_the_prove_again(monkeypatch):
    from tools import chat_ladder as cl
    from tools import m1_session
    replies = [{"ok": True, "data": {"result": {"proven": False}}},                     # status
               {"ok": True, "data": {"result": {"ok": True, "pass": False, "base": "err:nil method"}}},
               {"ok": True, "data": {"result": {"proven": False}}},
               {"ok": True, "data": {"result": {"ok": True, "pass": True}}}]

    class Cli:
        def request(self, *a, **k):
            return replies.pop(0)
    monkeypatch.setattr(cl, "_server_client", lambda: Cli())
    monkeypatch.setattr(m1_session, "register_sender", lambda: (True, "registered"))
    slept = []
    ok, how = cl.ensure_sender(tries=3, wait_s=7, sleep=slept.append)
    assert ok and slept == [7] and not replies


def test_ensure_sender_reports_what_it_needs_after_its_tries(monkeypatch):
    from tools import chat_ladder as cl
    bad = {"ok": True, "data": {"result": {"ok": True, "pass": False, "base": "err:nil method"}}}

    class Cli:
        def request(self, *a, **k):
            return bad
    monkeypatch.setattr(cl, "_server_client", lambda: Cli())
    ok, how = cl.ensure_sender(tries=2, wait_s=1, sleep=lambda s: None)
    assert not ok and "after 2 tries" in how and "restart the dev server" in how


# ------------------------------------------------------------------ 3. the nav helper
def test_wait_nav_waits_for_the_helper_then_says_why():
    seq = ["the nav helper's heartbeat is stale (90 s old)", "the nav helper is recovering", None]
    slept = []
    assert j.wait_nav(lambda: seq.pop(0), slept.append, max_s=60, step_s=5) is None and slept == [5, 5]
    slept = []
    why = j.wait_nav(lambda: "the nav helper's heartbeat is stale (90 s old)", slept.append, max_s=20, step_s=5)
    assert "stale" in why and sum(slept) == 20


# ------------------------------------------------------------------ 4. whose a container is
def test_container_reads_keep_the_games_owner():
    r = j.read_container({"ok": True, "data": {"kind": "storage", "class": "BP_BaseBuilding_Crate_C", "contents": [],
                                               "owner": "ClaudeDev", "owner_guid": DEV_GUID, "mine": False}})
    assert r["owner"] == "ClaudeDev" and r["owner_guid"] == DEV_GUID and r["mine"] is False
    c = j.chests_seen([result(1, "a", "store", data={"container": CRATE, "contents": ["2 Ash Logs"]})])
    assert c[CRATE]["mine"] is None  # the result did not say: not "false"


def _crate_end(owner_guid, owner, items, ledger_mine=True):
    start = j.snapshot(state(mine=[CRATE] if ledger_mine else []))
    start["own_guids"] = [FORK_GUID, DEV_GUID]
    start["chest_start"] = {CRATE: {"read": True, "items": {ASH: 2}, "kind": "storage"}}
    end = j.snapshot(state(mine=[CRATE] if ledger_mine else []))
    end["chests"] = {CRATE: {"items": items, "tool": "store", "mine": owner_guid == FORK_GUID, "owner": owner,
                             "owner_guid": owner_guid}}
    end["chest_end"] = {CRATE: {"read": True, "items": items, "kind": "storage", "owner": owner,
                                "owner_guid": owner_guid, "mine": owner_guid == FORK_GUID}}
    return start, end


def test_a_crate_of_the_character_he_was_forked_from_is_his(doc):
    job = j.job_of("N1", doc)
    s, e = _crate_end(DEV_GUID, "ClaudeDev", {ASH: 22, STONE: 10})
    ok, why = j.done(job, s, e)
    assert ok is True and "ClaudeDev" in why
    assert j.game_owner(CRATE, s, e)[0] is True


def test_a_crate_the_game_says_is_someone_elses_is_not_his(doc):
    job = j.job_of("N1", doc)
    s, e = _crate_end(LUIS_GUID, "luisdeburnaybast", {ASH: 22, STONE: 10})  # the ledger says mine; the game does not
    ok, why = j.done(job, s, e)
    assert ok is False and "luisdeburnaybast" in why
    s, e = _crate_end(LUIS_GUID, "luisdeburnaybast", {ASH: 22, STONE: 10}, ledger_mine=False)
    assert j.done(job, s, e)[0] is False


def test_one_truth_in_a_step_record(doc):
    # I2's shape: he finished the job before the interruption cleared: done is the job's end, resumed the step's
    rows = model(T0 + 1) + [call(T0 + 3, "s1", "store", {"item": "Ash Logs"}),
                            result(T0 + 10, "s1", "store", data={"container": CRATE, "item": ASH, "count": 20,
                                                                 "inside_now": 20, "contents": ["20 Ash Logs", "10 Stone"],
                                                                 "owner": "ClaudeDev", "owner_guid": DEV_GUID,
                                                                 "mine": False})]
    full = [{"item": ASH, "name": "Ash Logs", "count": 20}, {"item": STONE, "name": "Stone", "count": 10}]

    class IO(FakeIO):
        def inspect(self, cid):
            r = super().inspect(cid)
            if r.get("ok"):
                r["data"].update(owner="ClaudeDev", owner_guid=DEV_GUID, mine=False)
            return r
    io = IO(script=rows, states=lambda t: state(mine=[CRATE]), chests=lambda t, cid: full if t >= T0 + 10 else [])
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I2", "interruptions": doc["interruptions"],
                                              "own_guids": [FORK_GUID, DEV_GUID], "trigger": "at:30"})
    assert rec["job_done"] is True and rec["done"] is True and rec["resumed"] is False
    c = rec["chests"][CRATE]
    assert c["owner"] == "ClaudeDev" and c["his"] is True and c["mine"] is False

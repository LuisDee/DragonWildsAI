"""tools/checkpoint_pair.py: a checkpoint is his character save AND the world as it stood then, under ONE character
identity. Offline: a made-up Saved/ and SaveCharacters/, a fake server and client (the scripts are recorded, never run).

Why (2026-11-18): every trial's fork had a new guid, so the near-home job N1 met a restored world in which nothing
was his (runs 20261118-052749 and -053829-N1-I2: he refused ClaudeDev's crates or built his own and ran out of time).
"""
from __future__ import annotations

import json
import os

import pytest

from tools import checkpoint_pair as cp
from tools import world_snapshot as ws

T0 = 1795000000.0
GUID = "AAAA1111BBBB2222CCCC3333DDDD4444"
NAME = "ClaudeJ180600a"


def save_text(name=NAME, guid=GUID, logs=3):
    """A character save as the game writes it (only the fields the tool reads matter)."""
    return json.dumps({"meta_data": {"char_guid": guid, "char_name": name},
                       "GameProgress": {"Inventory": {"0": {"ItemData": "ash", "Count": logs}},
                                        "Character": {"LastAccessibleLocation": {"Position": "V(X=100.0, Y=200.0, Z=-30.0)"}}}},
                      indent="\t")


class Rig:
    """A fake dev box: the server's Saved/ (two world folders), the client's SaveCharacters/, the checkpoints, a
    death file, and processes that the recorded ps calls start and stop."""

    def __init__(self, tmp_path):
        self.tmp = tmp_path
        self.saved = tmp_path / "Saved"
        (self.saved / "SaveGames").mkdir(parents=True)
        (self.saved / "SpudCache").mkdir()
        self.write_world(b"world-at-start")
        self.saves = tmp_path / "SaveCharacters"
        self.saves.mkdir()
        self.hold = tmp_path / "server.stopped"
        self.server, self.client = True, True
        self.now = T0
        self.calls: list[tuple] = []
        self.lock = None
        self.joined: list = []
        self.store = ws.Store(saved=self.saved, root=tmp_path / "world_snapshots", hold_file=self.hold,
                              running=lambda: self.server, lock=lambda: self.lock, build=lambda: "26574459",
                              joins=lambda: (self.joined, "2026-11-01T00:00:00Z"), clock=lambda: self.now)
        self.deaths = tmp_path / "last_death.json"
        self.p = cp.Pairs(store=self.store, checkpoint_dir=tmp_path / "checkpoints", save_dir=self.saves,
                          park_dir=tmp_path / "forks", death_file=self.deaths, ps=self.ps,
                          client_running=lambda: self.client, sleep=self.sleep, clock=lambda: self.now, own_pid=4242)

    # the processes ---------------------------------------------------------------------------------------------
    def ps(self, script, *args):
        self.calls.append((script, *args))
        if script == "stop_server.ps1":
            self.server = False
            if "-Hold" in args:
                self.hold.write_text("")
        elif script == "start_server.ps1":
            self.server = True
            self.hold.unlink(missing_ok=True)
        elif script == "stop_client.ps1":
            self.client = False
        return 0

    def sleep(self, s):
        self.now += s
        for t, fn in list(self.at):
            if self.now >= t:
                fn()
                self.at.remove((t, fn))

    at: list = []

    # files -----------------------------------------------------------------------------------------------------
    def write_world(self, body: bytes, mtime: float | None = None):
        f = self.saved / "SaveGames" / "CompanionDev.sav"
        f.write_bytes(body)
        (self.saved / "SpudCache" / "L_World.lvl").write_bytes(body + b"-cell")
        if mtime is not None:
            os.utime(f, (mtime, mtime))

    def write_save(self, text: str, mtime: float, name=NAME):
        f = self.saves / f"{name}.json"
        f.write_text(text, encoding="utf-8")
        os.utime(f, (mtime, mtime))
        return f

    def world_bytes(self):
        return (self.saved / "SaveGames" / "CompanionDev.sav").read_bytes()


@pytest.fixture
def rig(tmp_path):
    r = Rig(tmp_path)
    r.at = []
    return r


def kept(rig, label="job_n1_mid", logs=7, world=b"world-with-his-chest"):
    """A pair kept the normal way: both saves come after the trial ended."""
    t_end = rig.now
    rig.write_save(save_text(logs=logs), mtime=t_end - 100)   # the save before the trial ended: not it
    rig.write_world(b"world-before-end", mtime=t_end - 50)
    rig.at = [(t_end + 30, lambda: rig.write_save(save_text(logs=logs), mtime=t_end + 30)),
              (t_end + 60, lambda: rig.write_world(world, mtime=t_end + 60))]
    return rig.p.keep(label, NAME, t_end=t_end, wait_s=330, window="w1")


# ------------------------------------------------------------------ keep: the pair is taken after the trial's end
def test_keep_waits_for_a_character_save_and_a_world_save_after_the_trial_and_keeps_both(rig):
    res = kept(rig)
    assert res["kept"] is True, res
    assert res["world"] == "ck-job_n1_mid"
    ck = rig.tmp / "checkpoints" / "job_n1_mid.json"
    assert json.loads(ck.read_text())["GameProgress"]["Inventory"]["0"]["Count"] == 7
    side = json.loads((rig.tmp / "checkpoints" / "job_n1_mid.world.json").read_text())
    assert side["schema"] == cp.SCHEMA and side["char_guid"] == GUID and side["char_name"] == NAME
    assert side["char_sha256"] == ws.sha256(ck) and side["world"] == "ck-job_n1_mid"
    assert side["char_saved_at"] > side["t_end"] and side["world_saved_at"] > side["t_end"]
    snap = rig.tmp / "world_snapshots" / "ck-job_n1_mid" / "SaveGames" / "CompanionDev.sav"
    assert snap.read_bytes() == b"world-with-his-chest"
    # the client first (no copy of his guid in play while the world is copied), then the server, then back up
    assert rig.calls == [("stop_client.ps1", "-Hold"), ("stop_server.ps1", "-Hold"), ("start_server.ps1",)]
    assert rig.server is True and not rig.hold.exists()


def test_keep_without_a_world_save_after_the_trial_keeps_nothing(rig):
    t_end = rig.now
    rig.write_world(b"old", mtime=t_end - 10)
    rig.at = [(t_end + 30, lambda: rig.write_save(save_text(), mtime=t_end + 30))]
    res = rig.p.keep("job_n1_mid", NAME, t_end=t_end, wait_s=120)
    assert res["kept"] is False and "world" in res["why"]
    assert not (rig.tmp / "checkpoints").exists() or not list((rig.tmp / "checkpoints").iterdir())
    assert rig.calls == []  # nothing was stopped


def test_keep_without_a_character_save_after_the_trial_keeps_nothing(rig):
    t_end = rig.now
    rig.write_save(save_text(), mtime=t_end - 5)
    rig.at = [(t_end + 20, lambda: rig.write_world(b"new", mtime=t_end + 20))]
    res = rig.p.keep("job_n1_mid", NAME, t_end=t_end, wait_s=120)
    assert res["kept"] is False and "character" in res["why"] and rig.calls == []


def test_keep_refuses_a_taken_label_before_waiting(rig):
    kept(rig)
    rig.calls.clear()
    with pytest.raises(ws.Refused, match="exists"):
        rig.p.keep("job_n1_mid", NAME, t_end=rig.now, wait_s=330)
    assert rig.calls == []


def test_keep_whose_world_copy_fails_writes_no_half_pair_and_starts_the_server(rig, monkeypatch):
    def boom(*a, **k):
        raise ws.Refused("something is writing the world")
    monkeypatch.setattr(rig.store, "keep", boom)
    res = kept(rig)
    assert res["kept"] is False and "writing the world" in res["why"]
    assert not (rig.tmp / "checkpoints" / "job_n1_mid.json").exists()
    assert not (rig.tmp / "checkpoints" / "job_n1_mid.world.json").exists()
    assert rig.calls[-1] == ("start_server.ps1",) and rig.server is True


def test_keep_refuses_a_save_of_another_character(rig):
    t_end = rig.now
    rig.write_save(save_text(name="SomeoneElse"), mtime=t_end + 1)
    rig.write_world(b"w", mtime=t_end + 1)
    res = rig.p.keep("job_n1_mid", NAME, t_end=t_end, wait_s=10)
    assert res["kept"] is False and "SomeoneElse" in res["why"] and rig.calls == []


# ------------------------------------------------------------------ read: a pair, no pair, or a broken pair
def test_read_is_none_for_a_plain_checkpoint_or_a_save_name(rig):
    (rig.tmp / "checkpoints").mkdir()
    (rig.tmp / "checkpoints" / "old_style.json").write_text(save_text())
    assert rig.p.read("old_style") is None
    assert rig.p.read("ClaudeDev") is None


def test_read_returns_the_pair(rig):
    kept(rig)
    pair = rig.p.read("job_n1_mid")
    assert pair["char_guid"] == GUID and pair["char_name"] == NAME and pair["world"] == "ck-job_n1_mid"


@pytest.mark.parametrize("damage, match", [
    ("checkpoint", "sha256"),
    ("world", "no snapshot"),
    ("sidecar", "JSON"),
])
def test_a_broken_pair_is_refused_never_taken_for_a_plain_fork(rig, damage, match):
    import shutil
    kept(rig)
    if damage == "checkpoint":
        (rig.tmp / "checkpoints" / "job_n1_mid.json").write_text(save_text(logs=99))
    elif damage == "world":
        shutil.rmtree(rig.tmp / "world_snapshots" / "ck-job_n1_mid")
    else:
        (rig.tmp / "checkpoints" / "job_n1_mid.world.json").write_text("{")
    with pytest.raises(ws.Refused, match=match):
        rig.p.read("job_n1_mid")


# ------------------------------------------------------------------ prepare: one trial from the pair
def played(rig):
    """The pair kept, then a trial played on: the world and his save moved on, and he died once in it."""
    kept(rig)
    pair = rig.p.read("job_n1_mid")
    rig.now += 600
    rig.write_world(b"world-after-trial-1", mtime=rig.now)
    rig.write_save(save_text(logs=20), mtime=rig.now)
    (rig.saves / f"{NAME}.json.backup").write_text(save_text(logs=15))
    rig.deaths.write_text(json.dumps({"deaths": [
        {"ts": T0 - 9999, "character": "ClaudeDev", "character_guid": "E71C5DC146F0A55B69FF52A881255DEF"},
        {"ts": pair["char_saved_at"] - 5, "character": NAME, "character_guid": GUID, "grave_id": "in the kept world"},
        {"ts": rig.now - 60, "character": NAME, "character_guid": GUID, "grave_id": "trial 1's grave"}]}))
    rig.client = True
    rig.calls.clear()
    return pair


def test_prepare_restores_the_world_and_his_save_under_the_same_guid_and_name(rig):
    pair = played(rig)
    res = rig.p.prepare(pair, stamp="20261118T070000Z")
    assert rig.world_bytes() == b"world-with-his-chest"                      # the world as the checkpoint saw it
    live = rig.saves / f"{NAME}.json"
    assert live.read_bytes() == (rig.tmp / "checkpoints" / "job_n1_mid.json").read_bytes()
    meta = json.loads(live.read_text())["meta_data"]
    assert meta == {"char_guid": GUID, "char_name": NAME}                    # ONE identity, never a new guid
    assert not (rig.saves / f"{NAME}.json.backup").exists()                  # no stale copy of his guid left
    parked = sorted(p.name for p in (rig.tmp / "forks").iterdir())
    assert parked == [f"{NAME}.20261118T070000Z.json", f"{NAME}.20261118T070000Z.json.backup"]
    assert res["name"] == NAME and res["guid"] == GUID and res["restored"]["restored"] == "ck-job_n1_mid"
    # client down before his file is written, the server down for the restore, the server up at the end
    assert rig.calls == [("stop_client.ps1", "-Hold"), ("stop_server.ps1", "-Hold"), ("start_server.ps1",)]
    assert rig.server is True and not rig.hold.exists()


def test_prepare_forgets_only_the_deaths_of_this_guid_after_the_checkpoint(rig):
    pair = played(rig)
    res = rig.p.prepare(pair, stamp="s1")
    left = json.loads(rig.deaths.read_text())["deaths"]
    assert [d.get("grave_id") for d in left] == [None, "in the kept world"]
    assert [d["grave_id"] for d in res["deaths_forgotten"]] == ["trial 1's grave"]


def test_prepare_twice_gives_the_same_start_both_times(rig):
    pair = played(rig)
    rig.p.prepare(pair, stamp="s1")
    first = (rig.world_bytes(), (rig.saves / f"{NAME}.json").read_bytes())
    rig.now += 900
    rig.write_world(b"world-after-trial-2", mtime=rig.now)
    rig.write_save(save_text(logs=30), mtime=rig.now)
    rig.client = True
    rig.p.prepare(pair, stamp="s2")
    assert (rig.world_bytes(), (rig.saves / f"{NAME}.json").read_bytes()) == first


def test_prepare_restores_inside_our_own_lock_window(rig):
    pair = played(rig)
    rig.lock = {"owner": "jobs", "text": "jobs pid=4242", "pid": 4242, "stale": False}
    rig.p.prepare(pair, stamp="s1")
    assert rig.world_bytes() == b"world-with-his-chest"


def test_prepare_refuses_while_someone_else_holds_the_lock_and_brings_the_server_back(rig):
    pair = played(rig)
    rig.lock = {"owner": "course", "text": "course pid=7", "pid": 7, "stale": False}
    with pytest.raises(ws.Refused, match="live lock"):
        rig.p.prepare(pair, stamp="s1")
    assert rig.world_bytes() == b"world-after-trial-1" and rig.server is True


def test_prepare_refuses_a_second_file_with_his_guid_before_stopping_anything(rig):
    pair = played(rig)
    (rig.saves / "ClaudeJ180601b.json").write_text(save_text(name="ClaudeJ180601b", guid=GUID))
    with pytest.raises(ws.Refused, match="ClaudeJ180601b"):
        rig.p.prepare(pair, stamp="s1")
    assert rig.calls == []


@pytest.mark.parametrize("name", ["ClaudeDev", "Claude"])
def test_prepare_never_writes_the_main_characters(rig, name):
    pair = played(rig)
    with pytest.raises(ws.Refused, match="never"):
        rig.p.prepare({**pair, "char_name": name}, stamp="s1")
    assert rig.calls == []


def test_prepare_refuses_when_the_client_did_not_stop(rig):
    pair = played(rig)
    rig.p.ps = lambda script, *a: rig.calls.append((script, *a)) or 0  # the stop does nothing
    with pytest.raises(ws.Refused, match="client"):
        rig.p.prepare(pair, stamp="s1")
    assert ("stop_server.ps1", "-Hold") not in rig.calls
    assert (rig.saves / f"{NAME}.json").read_text() == save_text(logs=20)


def test_prepare_whose_restore_stops_half_way_puts_the_undo_back(rig, monkeypatch):
    pair = played(rig)
    real = ws.Store.restore
    seen = []

    def flaky(self, label, others_ok="", own_pid=None, undo=True):
        seen.append((label, undo))
        if label.startswith("ck-"):
            out = real(self, label, others_ok, own_pid=own_pid, undo=undo)
            exc = ws.Refused("restore of ck-job_n1_mid stopped half way (disk): the world folders are NOT whole")
            exc.undo = out["undo"]
            (self.saved / "SaveGames" / "CompanionDev.sav").write_bytes(b"torn")
            raise exc
        return real(self, label, others_ok, own_pid=own_pid, undo=undo)
    monkeypatch.setattr(ws.Store, "restore", flaky)
    with pytest.raises(ws.Refused, match="half way"):
        rig.p.prepare(pair, stamp="s1")
    # the undo goes back without an undo of its own (the torn world is not worth keeping; its label would clash)
    assert seen[0] == ("ck-job_n1_mid", True) and seen[1][0].startswith("undo-") and seen[1][1] is False
    assert rig.world_bytes() == b"world-after-trial-1" and rig.server is True


def test_precheck_says_when_another_player_joined_since_the_pair(rig):
    pair = played(rig)
    rig.joined = [("2030-01-01T00:00:00Z", "Zezima")]
    assert any("Zezima" in w for w in rig.p.precheck(pair))
    assert rig.p.precheck(pair, others_ok="Luis 2026-11-17: reset the dev world at will") == []


# ------------------------------------------------------------------ the window's step: pair or fork
def test_file_check_sees_a_save_that_something_else_replaced(rig):
    pair = played(rig)
    res = rig.p.prepare(pair, stamp="s1")
    assert rig.p.file_check(pair, res["written_at"])["sha_ok"] is True
    rig.write_save(save_text(logs=20), mtime=rig.now + 5)  # e.g. a cloud copy of trial 1's end
    assert rig.p.file_check(pair, res["written_at"])["sha_ok"] is False


def test_start_character_from_a_pair_plays_the_pair_and_never_forks(rig):
    pair = played(rig)
    forked = []
    got = cp.start_character("job_n1_mid", "ClaudeJ181010a", pair, rig.p, fork=lambda ref, n: forked.append(n),
                             stamp="s1")
    assert got["name"] == NAME and got["paired"] is True and forked == []


def test_start_character_without_a_pair_forks_as_before(rig):
    forked = []
    got = cp.start_character("ClaudeDev", "ClaudeJ181010a", None, rig.p, fork=lambda ref, n: forked.append((ref, n)))
    assert got == {"name": "ClaudeJ181010a", "paired": False} and forked == [("ClaudeDev", "ClaudeJ181010a")]
    assert rig.calls == []


def test_identity_fault_when_the_server_lists_another_guid():
    pair = {"char_guid": GUID, "char_name": NAME}
    assert cp.identity_fault({"guid": GUID.lower()}, pair) is None
    assert cp.identity_fault({"guid": "FFFF"}, None) is None
    assert "FFFF" in cp.identity_fault({"guid": "FFFF"}, pair)


def test_the_world_label_fits_the_snapshot_rule():
    assert cp.world_label("job_n1_mid") == "ck-job_n1_mid"
    with pytest.raises(ws.Refused):
        cp.world_label("x" * 38)


def test_quest_run_step_wires_the_pair():
    """quest_run step goes through the same steps (the job_run window below is driven end to end)."""
    from tools import quest_run
    import inspect
    src = inspect.getsource(quest_run.cmd_step)
    assert "window_pair(" in src and "start_character(" in src and "identity_fault(" in src and "pairs.keep(" in src
    assert "--others-ok" in inspect.getsource(quest_run.main)


# ------------------------------------------------------------------ job_run's window, driven with fakes
class Window:
    """tools/job_run.cmd_window with every live part faked: the lock window, the switch, the brain and the trial."""

    def __init__(self, rig, monkeypatch, pair_ref=True, guid=GUID, trial_pass=True):
        import contextlib
        from tools import job_run as j
        from tools import quest_run as q
        from tools import quest_clone
        from tools import vitals_rescue, failure_ledger
        from evals.bench import devrun
        self.j, self.rig = j, rig
        self.forked, self.ensured, self.memories, self.kept, self.parked = [], [], [], [], []
        self.preps = 0
        real_prepare = rig.p.prepare

        def prepare(pair, others_ok="", stamp=None):
            self.preps += 1
            rig.now += 1  # each restore keeps its own undo label
            return real_prepare(pair, others_ok, stamp)
        monkeypatch.setattr(rig.p, "prepare", prepare)
        monkeypatch.setattr(rig.p, "keep", lambda label, name, **k: self.kept.append((label, name)) or
                            {"kept": True, "label": label})

        class Sw:
            def ensure(sw, name, create=False, wait_s=0):
                self.ensured.append(name)
                return {"name": name, "guid": guid if name == NAME else "F0F0", "relaunched": True}

        @contextlib.contextmanager
        def window(wait, out, out_file):
            import time
            yield Sw(), object(), time.time()
            out["back"] = {"name": "ClaudeDev"}
            with open(out_file, "a", encoding="utf-8") as f:  # as quest_run.clone_window writes it
                f.write(json.dumps(out) + "\n")
        monkeypatch.setattr(q, "clone_window", window)
        monkeypatch.setattr(q, "refuse_dirty", lambda a: False)
        monkeypatch.setattr(q, "to_start", lambda cli, place: None)
        monkeypatch.setattr(q, "preflight", lambda ns: [])
        monkeypatch.setattr(quest_clone, "source_of", lambda ref: rig.tmp / "checkpoints" / f"{ref}.json")
        monkeypatch.setattr(quest_clone, "place_of", lambda ref: None)
        monkeypatch.setattr(quest_clone, "fork", lambda ref, name: self.forked.append((ref, name)))
        monkeypatch.setattr(quest_clone, "park", lambda names: list(names))
        monkeypatch.setattr(vitals_rescue, "save_unfit", lambda src, pct=None: None)
        monkeypatch.setattr(failure_ledger, "voided", lambda: set())
        monkeypatch.setattr(devrun, "default_dev", lambda: type("Dev", (), {})())
        monkeypatch.setattr(cp, "default_pairs", lambda: rig.p)
        monkeypatch.setattr(j, "unfit", lambda cli, pct=None: None)
        monkeypatch.setattr(j, "wait_nav", lambda check, sleep: None)
        monkeypatch.setattr(j, "Live", lambda ns, cli, dev: self.memories.append(ns.world) or ns)
        monkeypatch.setattr(j, "blind_mark", lambda *a: {})
        monkeypatch.setattr(j, "all_runs", lambda: [])
        monkeypatch.setattr(j, "trace_reads", lambda: [])
        monkeypatch.setattr(j, "write", lambda rec: None)
        monkeypatch.setattr(j, "WINDOW_OUT", rig.tmp / "job_windows.jsonl")
        monkeypatch.setattr(j, "STOP_FILE", rig.tmp / "job_run.stop")
        monkeypatch.setattr(j.time, "sleep", lambda s: None)
        n = iter(range(100))

        def run_job(io, job, opts):
            self.j_opts = opts
            return {"run": f"r{next(n)}", "verdict": {"pass": trial_pass}, "ended": "job done", "job_done": trial_pass,
                    "misses": {"n": 0}}
        monkeypatch.setattr(j, "run_job", run_job)

    def run(self, *argv):
        return self.j.main(["trial", "--confirm", "--job", "N1", "--regrow-days", "0", *argv])


def test_job_run_window_from_a_pair_plays_the_pairs_character_every_trial(rig, monkeypatch):
    played(rig)
    w = Window(rig, monkeypatch)
    assert w.run("--from", "job_n1_mid", "-k", "2", "--interrupt", "I1") == 0
    assert w.forked == [] and w.preps == 2                           # never a fork: the pair, restored per trial
    assert w.ensured == [NAME, NAME]                                 # the checkpoint's own name and guid
    assert len(set(w.memories)) == 2 and all(m.startswith(f"dev_{NAME}_") for m in w.memories)
    assert w.j_opts["own_guids"][0] == GUID
    row = json.loads((rig.tmp / "job_windows.jsonl").read_text().splitlines()[-1])
    assert row["pair"]["char_guid"] == GUID and [t["character"] for t in row["trials"]] == [NAME, NAME]
    assert all(t["prep"]["file_after_join"]["sha_ok"] for t in row["trials"])  # still the checkpoint's bytes
    assert any(p.startswith(f"{NAME}.") for p in os.listdir(rig.tmp / "forks"))  # the last trial's end parked


def test_job_run_window_stops_when_the_server_lists_another_guid(rig, monkeypatch):
    played(rig)
    w = Window(rig, monkeypatch, guid="0BAD")
    assert w.run("--from", "job_n1_mid", "-k", "3", "--interrupt", "I1") == 1
    row = json.loads((rig.tmp / "job_windows.jsonl").read_text().splitlines()[-1])
    assert len(row["trials"]) == 1 and row["trials"][0]["void"] == "harness" and "0BAD" in row["trials"][0]["skipped"]


def test_job_run_window_from_the_jobs_start_forks_and_keeps_a_pair(rig, monkeypatch):
    (rig.tmp / "checkpoints").mkdir(exist_ok=True)
    (rig.tmp / "checkpoints" / "ClaudeDev.json").write_text(save_text(name="ClaudeDev", guid="E71C"))
    w = Window(rig, monkeypatch)
    assert w.run("--from", "ClaudeDev", "-k", "2", "--save-as", "job_n1_mid2") == 0
    assert [n for _, n in w.forked] == w.ensured and len(w.forked) == 2 and w.preps == 0
    assert w.kept == [("job_n1_mid2", w.forked[0][1])]               # the first good trial's fork, as a pair


def test_job_run_window_refuses_a_broken_pair_before_the_lock(rig, monkeypatch, capsys):
    played(rig)
    (rig.tmp / "checkpoints" / "job_n1_mid.json").write_text(save_text(logs=1))
    w = Window(rig, monkeypatch)
    assert w.run("--from", "job_n1_mid", "-k", "1") == 2
    assert "sha256" in capsys.readouterr().out and w.ensured == []

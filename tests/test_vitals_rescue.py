"""tools/vitals_rescue.py (offline): a vitals rescue on ClaudeDev only counts once his character SAVE carries it, since
a character switch reloads him from the save (live 2026-11-17 21:05Z: a job window forked the old save and both forks
were unfit). Fake save files and fake fixtures; nothing live."""
import contextlib
import json
import os

import pytest

from evals.bench.observer import Abort
from tools import quest_clone
from tools import vitals_rescue as vr


def write_save(path, food, water, health=100.0, mtime=None):
    path.write_text(json.dumps({"meta_data": {"char_name": path.stem}, "GameProgress": {"Character": {
        "Health": {"CurrentValue": health}, "Sustenance": {"SustenanceValue": food, "SustenanceDecayBuffer": 0},
        "Hydration": {"HydrationValue": water, "HydrationDecayBuffer": 0}}}}), encoding="utf-8")
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


@pytest.fixture
def saves(tmp_path, monkeypatch):
    monkeypatch.setattr(quest_clone, "SAVE_DIR", tmp_path)
    return tmp_path


# ------------------------------------------------------------------ the save's own bars
def test_a_fit_save_passes(saves):
    write_save(saves / "ClaudeDev.json", 75.7, 69.4)
    assert vr.save_unfit() is None


def test_a_starved_save_refuses_with_the_rescue_command(saves):
    write_save(saves / "ClaudeDev.json", 30.0, 12.0)
    why = vr.save_unfit()
    assert why.startswith("ClaudeDev's save unfit: food 30 of 100, water 12 of 100 (under 40 % is unfit;")
    assert "a fork copies the save" in why and "-m tools.vitals_rescue" in why


def test_a_dead_save_refuses(saves):
    write_save(saves / "ClaudeDev.json", 80.0, 80.0, health=0.0)
    assert "health 0 of 100" in vr.save_unfit()


def test_an_unreadable_or_missing_save_refuses(saves):
    assert vr.save_unfit().startswith("ClaudeDev's save unread")
    (saves / "ClaudeDev.json").write_text("{half a wri", encoding="utf-8")
    assert vr.save_unfit().startswith("ClaudeDev's save unread")


def test_a_checkpoint_save_names_its_own_remedy(tmp_path, saves):
    cp = write_save(tmp_path / "cp_x.json", 10.0, 90.0)
    why = vr.save_unfit(cp)
    assert why.startswith("save cp_x unfit: food 10 of 100") and "vitals_rescue" not in why


# ------------------------------------------------------------------ waiting for the save to carry the rescue
class Clock:
    def __init__(self, t=1000.0):
        self.t = t
        self.hooks = {}

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s
        hook = self.hooks.pop(round(self.t), None)
        if hook:
            hook()


def test_an_old_save_with_good_values_is_not_enough(saves):
    p = write_save(saves / "ClaudeDev.json", 90.0, 90.0, mtime=900.0)  # written before the rescue at 1000
    c = Clock()
    r = vr.wait_saved(p, after=1000.0, timeout_s=30, poll_s=5, now=c.now, sleep=c.sleep)
    assert r["ok"] is False and r["timeout"] and "not rewritten" in r["why"]


def test_a_new_save_over_the_bar_ends_the_wait(saves):
    p = write_save(saves / "ClaudeDev.json", 30.0, 20.0, mtime=900.0)
    c = Clock()
    c.hooks[1015] = lambda: write_save(p, 94.0, 93.0, mtime=1014.0)
    r = vr.wait_saved(p, after=1000.0, timeout_s=120, poll_s=5, now=c.now, sleep=c.sleep)
    assert r["ok"] is True and r["waited_s"] == 15 and r["save"]["food"] == 94.0


def test_a_new_save_still_under_the_bar_keeps_waiting(saves):
    p = write_save(saves / "ClaudeDev.json", 30.0, 20.0, mtime=900.0)
    c = Clock()
    c.hooks[1010] = lambda: write_save(p, 30.0, 20.0, mtime=1009.0)  # e.g. a reload from the old save, then a write
    r = vr.wait_saved(p, after=1000.0, timeout_s=40, poll_s=5, now=c.now, sleep=c.sleep)
    assert r["ok"] is False and r["timeout"] and "food 30 of 100" in r["why"]


# ------------------------------------------------------------------ the command: lock, fixtures, wait, exit codes
class Dev:
    def __init__(self, guard_err=None, setup_err=None):
        self.calls, self.guard_err, self.setup_err = [], guard_err, setup_err
        self.brain_running = lambda: True  # the live default: the tool must turn it off itself
        self.character_name = "ClaudeDev"

    def guard(self, *a):
        if self.brain_running():
            raise Abort("the live brain (run_live) is running: two brains on one pawn")
        if self.guard_err:
            raise Abort(self.guard_err)

    def setup(self, verb, purpose="", **a):
        self.guard()
        if self.setup_err:
            raise Abort(f"fixture {verb} failed: {self.setup_err}")
        self.calls.append((verb, purpose, a))
        if verb == "set_stat":
            return {"ok": True, "stat": a["stat"], "after": 95.0, "max": 100.0}
        return {"ok": True, "health": 100.0, "want": 100.0}


@pytest.fixture
def cmd(saves, monkeypatch, tmp_path):
    from evals.bench import devrun
    from tools import live_lock
    w = {"dev": Dev(), "lock": [], "clock": Clock()}

    @contextlib.contextmanager
    def held(owner, wait_s=0, **k):
        w["lock"].append(("claim", owner))
        try:
            yield
        finally:
            w["lock"].append(("release", owner))

    monkeypatch.setattr(live_lock, "held", held)
    monkeypatch.setattr(devrun, "default_dev", lambda: w["dev"])
    monkeypatch.setattr(vr, "_now", w["clock"].now)
    monkeypatch.setattr(vr, "_sleep", w["clock"].sleep)
    monkeypatch.setattr(vr, "LOG", tmp_path / "vitals_rescue.jsonl")
    w["save"] = write_save(saves / "ClaudeDev.json", 30.0, 12.0, mtime=900.0)
    return w


def test_a_rescue_sets_the_bars_as_a_logged_harness_rescue_and_waits_for_the_save(cmd):
    before = cmd["save"].read_bytes()
    cmd["clock"].hooks[1020] = lambda: write_save(cmd["save"], 94.0, 94.5, mtime=1019.0)
    assert vr.main(["--purpose", "before job window L2"]) == 0
    verbs = [(v, a.get("stat")) for v, _, a in cmd["dev"].calls]
    assert verbs == [("set_health", None), ("set_stat", "endurance"), ("set_stat", "sustenance"), ("set_stat", "hydration")]
    assert all(p.startswith("harness rescue") and "before job window L2" in p for _, p, _ in cmd["dev"].calls)
    assert cmd["lock"] == [("claim", "vitals"), ("release", "vitals")]  # the switch cannot come before the save
    (row,) = [json.loads(ln) for ln in vr.LOG.read_text(encoding="utf-8").splitlines()]
    assert row["ok"] and row["harness_rescue"] and row["purpose"] == "before job window L2"
    assert cmd["save"].read_bytes() != before  # only the fake game wrote it


def test_the_save_is_only_read(cmd, monkeypatch):
    before = cmd["save"].read_bytes()
    real_open = open

    def guarded_open(file, mode="r", *a, **k):
        if os.fspath(file) == os.fspath(cmd["save"]):
            assert set(mode) <= {"r", "b"}, f"opened the save with {mode!r}"
        return real_open(file, mode, *a, **k)
    monkeypatch.setattr("builtins.open", guarded_open)
    assert vr.main(["--purpose", "t", "--timeout", "20"]) == 2
    assert cmd["save"].read_bytes() == before


def test_no_new_save_in_time_is_exit_2(cmd, capsys):
    assert vr.main(["--purpose", "t", "--timeout", "60"]) == 2
    assert "not rewritten" in capsys.readouterr().out


@pytest.mark.parametrize("where,err", [
    ("guard", "client is on 1.2.3.4:7777, not the local dev server"),
    ("setup", "other_players_connected"),
    ("setup", "not_dev_server"),
    ("setup", "character_not_found"),
])
def test_the_fixtures_own_refusals_are_exit_3(cmd, capsys, where, err):
    cmd["dev"] = Dev(**{f"{where}_err": err})
    assert vr.main(["--purpose", "t"]) == 3
    assert err in capsys.readouterr().out and cmd["dev"].calls == []


def test_a_purpose_is_required(cmd):
    with pytest.raises(SystemExit):
        vr.main([])

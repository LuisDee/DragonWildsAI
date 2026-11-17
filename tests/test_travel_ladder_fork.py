"""travel_ladder --fork (docs/research/2026-11-17-idle-starvation.md option 1, offline): a body-only course plays a
throwaway fork of ClaudeDev topped up with tools.supply, and ALWAYS ends back on ClaudeDev before the live lock is
released (CLAUDE.md section 4: character switches)."""
import contextlib
import json
import sys

import pytest

import tools.travel_ladder as T

FIT = {"health": 100.0, "max_health": 100.0, "sustenance": 90.0, "sustenance_max": 100.0, "hydration": 90.0,
       "hydration_max": 100.0}


class Switch:
    def __init__(self):
        self.on = "ClaudeDev"
        self.seen = []

    def ensure(self, name, create=False, wait_s=0):
        self.on = name
        self.seen.append(name)
        return {"name": name, "guid": f"G-{name}", "created": False, "relaunched": True}


class Cli:
    def request(self, tool, args, timeout=None):
        assert tool == "get_state"
        return {"ok": True, "data": dict(FIT)}


@pytest.fixture
def world(tmp_path, monkeypatch):
    """The outside world as fakes: the lock (its own, released only on ClaudeDev), the dev server, the switch, the
    fork and park, supply and the legs."""
    from evals.bench import devchar, devrun
    from tools import live_lock, quest_clone, supply
    from tools import quest_run as q
    sw = Switch()
    w = {"sw": sw, "legs": [], "supplied": [], "forked": [], "parked": [], "lock": []}

    @contextlib.contextmanager
    def held(owner, wait_s=0, **k):
        w["lock"].append(("claim", sw.on))
        try:
            yield
        finally:
            w["lock"].append(("release", sw.on))

    class Dev:
        character_guid, character_name = "G-ClaudeDev", "ClaudeDev"

        def guard(self):
            assert sw.on == "ClaudeDev"

    def top_up(dev, food, water, heal=False, check=False, purpose="supply"):
        w["supplied"].append({"on": sw.on, "dev_name": dev.character_name, "dev_guid": dev.character_guid,
                              "food": food, "water": water, "purpose": purpose})
        return {"ok": True, "granted": {"food": food, "water": water}}

    def leg(dev, j):
        w["legs"].append((j["id"], sw.on))
        if w.get("leg_hook"):
            w["leg_hook"](len(w["legs"]))
        return {"journey": j["id"], "from": "a", "to": "b", "ok": True, "s": 1.0, "spl": 1.0, "end_dist_m": 0.5,
                "walked_m": 1.0, "straight_m": 1.0}

    monkeypatch.delenv("DW_LIVE_OWNER", raising=False)
    monkeypatch.setattr(live_lock, "read", lambda: None)
    monkeypatch.setattr(live_lock, "held", held)
    monkeypatch.setattr(devrun, "default_dev", lambda: Dev())
    monkeypatch.setattr(devchar, "default_switch", lambda dev: sw)
    monkeypatch.setattr(q.cl, "_debug_client", lambda: Cli())
    monkeypatch.setattr(q, "_on_main", lambda s, c, tries=3: (s.ensure("ClaudeDev"), {"character": "ClaudeDev"})[1])
    monkeypatch.setattr(quest_clone, "fork", lambda ref, name: (w["forked"].append((ref, name)), tmp_path / name)[1])
    monkeypatch.setattr(quest_clone, "park", lambda names: (w["parked"].extend(names), list(names))[1])
    monkeypatch.setattr(supply, "top_up", top_up)
    monkeypatch.setattr(T, "client", lambda: Cli())
    monkeypatch.setattr(T, "pick", lambda *a: [{"id": "leg1"}, {"id": "leg2"}])
    monkeypatch.setattr(T, "ghosts", lambda: {})
    monkeypatch.setattr(T, "run_journey", leg)
    monkeypatch.setattr(T, "head", lambda: "test")
    monkeypatch.setattr(T, "OUT", tmp_path / "travel_ladder.jsonl")
    monkeypatch.setattr(T, "STOP_FILE", tmp_path / "travel_ladder.stop", raising=False)
    return w


def run(monkeypatch, *argv):
    monkeypatch.setattr(sys, "argv", ["travel_ladder", *argv])
    T.main()


def released_on_main(w):
    assert w["lock"] and w["lock"][-1][0] == "release"
    assert all(on == "ClaudeDev" for ev, on in w["lock"] if ev == "release"), w["lock"]


def test_a_multi_pass_course_runs_on_a_supplied_fork_and_ends_on_claudedev(world, monkeypatch):
    run(monkeypatch, "--only", "leg1,leg2", "--repeat", "2")  # multi-pass: the fork is the default
    assert len(world["forked"]) == 1
    (ref, name), = world["forked"]
    assert ref == "ClaudeDev" and name.startswith("ClaudeT") and name != "ClaudeDev"
    assert [on for _, on in world["legs"]] == [name] * 4
    assert world["sw"].seen == [name, "ClaudeDev"] and world["sw"].on == "ClaudeDev"
    released_on_main(world)
    assert world["parked"] == [name]
    (s,) = world["supplied"]  # once, on the fork, the fixtures aimed at the fork's guid
    assert s["on"] == name and s["dev_name"] == name and s["dev_guid"] == f"G-{name}"
    assert "harness fixture" in s["purpose"]


def test_an_exception_mid_course_still_switches_back_before_the_lock_goes(world, monkeypatch):
    def boom(n):
        raise KeyboardInterrupt  # not an infra error the leg loop records: it leaves the run
    world["leg_hook"] = boom
    with pytest.raises(KeyboardInterrupt):
        run(monkeypatch, "--repeat", "2")
    assert len(world["forked"]) == 1 and len(world["legs"]) == 1 and world["legs"][0][1] != "ClaudeDev"
    assert world["sw"].on == "ClaudeDev"
    released_on_main(world)
    assert len(world["supplied"]) == 1


def test_the_stop_file_ends_the_course_on_claudedev(world, monkeypatch):
    world["leg_hook"] = lambda n: T.STOP_FILE.write_text("stop", encoding="utf-8")
    run(monkeypatch, "--repeat", "3")
    assert len(world["forked"]) == 1 and len(world["legs"]) == 1 and world["sw"].on == "ClaudeDev"
    released_on_main(world)
    summary = [json.loads(ln) for ln in T.OUT.read_text(encoding="utf-8").splitlines()][-1]
    assert summary["summary"] and summary["stopped"] == "travel_ladder.stop"
    assert summary["fork"]["character"] == world["forked"][0][1] and summary["fork"]["back"]


def test_a_stop_file_present_at_the_start_runs_no_leg_and_makes_no_fork(world, monkeypatch):
    T.STOP_FILE.write_text("stop", encoding="utf-8")
    run(monkeypatch, "--repeat", "2")
    assert world["legs"] == [] and world["forked"] == [] and world["supplied"] == []


def test_a_switch_that_fails_still_ends_on_claudedev_and_never_supplies_claudedev(world, monkeypatch):
    def bad_ensure(name, create=False, wait_s=0):
        if name != "ClaudeDev":
            raise RuntimeError("launch_timeout")
        world["sw"].on = name
        return {"name": name, "guid": "G-ClaudeDev"}
    world["sw"].ensure = bad_ensure
    with pytest.raises(RuntimeError):
        run(monkeypatch, "--repeat", "2")
    assert len(world["forked"]) == 1
    assert world["supplied"] == [] and world["legs"] == [] and world["sw"].on == "ClaudeDev"
    released_on_main(world)


def test_the_lock_is_kept_while_the_client_is_not_back(world, monkeypatch):
    from tools import quest_run as q
    tries = []

    def on_main(s, c, tries_=3, **k):
        tries.append(1)
        if len(tries) < 3:
            return None  # the return failed: the lock must not go
        s.ensure("ClaudeDev")
        return {"character": "ClaudeDev"}
    monkeypatch.setattr(q, "_on_main", lambda s, c, tries=3: on_main(s, c))
    monkeypatch.setattr(T, "STUCK_S", 0.0, raising=False)
    run(monkeypatch, "--repeat", "2")
    assert len(tries) == 3 and world["sw"].on == "ClaudeDev"
    released_on_main(world)


def test_one_pass_and_no_fork_stay_on_claudedev_without_supply(world, monkeypatch):
    run(monkeypatch, "--only", "leg1")
    run(monkeypatch, "--repeat", "2", "--no-fork")
    assert world["forked"] == [] and world["supplied"] == [] and world["sw"].seen == []
    assert {on for _, on in world["legs"]} == {"ClaudeDev"}
    run(monkeypatch, "--fork")  # one pass, asked for
    assert len(world["forked"]) == 1 and len(world["supplied"]) == 1 and world["sw"].on == "ClaudeDev"

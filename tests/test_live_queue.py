"""tools/live_queue.py: check files, templates, criteria, and the drain (slot, hold, recovery, retries, state) over a
fake environment. No game, bridge or client is touched."""
import json
from pathlib import Path

import pytest

import tools.client_slot as cs
import tools.live_queue as lq

ROOT = Path(__file__).resolve().parents[1]


# ------------------------------------------------------------------ fakes
class FakeEnv(lq.Env):
    def __init__(self, tmp: Path, replies=None, probes=None):
        super().__init__()
        self.t = 1_000_000.0
        self.tmp = tmp
        self.hold = None
        self.status = {"state": "in_world", "ts": lq.iso(self.t), "pid": 10}
        self.mono = 0.0
        self.replies = replies or {}          # tool -> list of replies (popped) or one reply
        self.probes = list(probes or [])      # successive probe dicts; the last one repeats
        self.calls: list = []
        self.fixtures: list = []
        self.guard_error = None
        self.slot_owner_seen: list = []
        self.on_bridge = None
        self.logs = {"client": ""}

    def now(self):
        return self.t

    def monotonic(self):
        return self.mono

    def sleep(self, s):
        self.t += max(s, 0.01)
        self.mono += max(s, 0.01)
        if getattr(self, "relaunch_at", None) and self.t >= self.relaunch_at:  # the watchdog's relaunch finished
            self.status, self.relaunch_at = {"state": "in_world", "ts": lq.iso(self.t), "pid": 11}, None
        self.status["ts"] = lq.iso(self.t) if self.status.get("state") == "in_world" else self.status.get("ts")

    def held(self):
        return self.hold

    def slot_status(self):
        return lq._slot_json(cs.main, ["status"])

    def slot_take(self, minutes, why):
        return bool(lq._slot_json(cs.main, ["take", lq.OWNER, f"{minutes:.0f}", "--why", why]).get("ok"))

    def slot_release(self):
        lq._slot_json(cs.main, ["release", lq.OWNER])

    def client_status(self):
        return dict(self.status)

    def guard(self):
        if self.guard_error:
            raise lq.InfraError(self.guard_error)

    def bridge(self, tool, args, timeout):
        self.calls.append(("bridge", tool, args))
        self.slot_owner_seen.append((lq._slot_json(cs.main, ["status"]).get("holder") or {}).get("owner"))
        if self.on_bridge:
            self.on_bridge(self, tool, args)
        if tool == "ping":
            return {"ok": self.status.get("state") == "in_world", "reason": None if self.status.get("state") == "in_world" else "timeout", "data": {}}
        r = self.replies.get(tool, {"ok": True, "data": {}})
        if isinstance(r, list):
            r = r.pop(0) if len(r) > 1 else r[0]
        return r

    def reset_bridge(self):
        self.calls.append(("reset_bridge",))

    def client_cmd(self, rel, args, timeout):
        self.calls.append(("cmd", Path(rel).name, args))
        if Path(rel).name == "input_gate_once.lua" and len(self.probes) > 1:
            self.probes.pop(0)
        return {"ok": True, "result": {"ok": True, "started": True}}

    def probe(self):
        self.calls.append(("probe",))
        p = self.probes[0] if self.probes else {"input_mode": "DIM_Gameplay", "position": [0, 0, 0], "inventory": {}}
        if len(self.probes) > 1 and not getattr(self, "sticky", False):
            self.probes.pop(0)
        return p

    def fixture(self, verb, purpose, args):
        self.fixtures.append((verb, args))
        return {"ok": True}

    def log_offsets(self):
        return {k: len(v) for k, v in self.logs.items()}

    def log_lines(self, source, since, regex):
        import re
        return [ln for ln in self.logs.get(source, "")[since:].splitlines() if re.search(regex, ln)]


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setattr(cs, "STATE", tmp_path / "slot.json")
    monkeypatch.setattr(lq, "STATE_FILE", tmp_path / "lq_state.json")
    monkeypatch.setattr(lq, "LOCK_FILE", tmp_path / "lq.lock")
    (tmp_path / "checks").mkdir()
    return tmp_path


def write_check(d: Path, spec: dict) -> Path:
    p = d / "checks" / f"{spec['id']}.json"
    p.write_text(json.dumps(spec), encoding="utf-8")
    return p


def basic(cid="c1", **kw):
    spec = {"id": cid, "owner": "t", "commit": "abc", "timeout_s": 60, "max_retries": 1,
            "preconditions": {"input_mode": "DIM_Gameplay"},
            "steps": [{"probe": True, "save": "before"}, {"bridge": "craft", "args": {"item": "X"}, "save": "craft"},
                      {"probe": True, "save": "after"}],
            "pass": [{"ref": "craft.ok", "eq": True}, {"ref": "after.input_mode", "eq": "DIM_Gameplay"}]}
    spec.update(kw)
    return spec


def runner(env, world):
    return lq.Runner(env, out=world / "out.jsonl", state_path=world / "lq_state.json", verbose=False)


def rows(world):
    return [json.loads(x) for x in (world / "out.jsonl").read_text(encoding="utf-8").splitlines()]


# ------------------------------------------------------------------ check files
def test_seed_checks_are_valid():
    checks = lq.load_checks()
    ids = {s["id"] for _, s in checks}
    assert {"recall_hold_walk", "craft_campfire_input_mode", "consume_food_input_mode", "collect_water_regression"} <= ids
    for p, s in checks:
        assert lq.validate(s, p) == [], p.name
        for st in s["steps"]:
            if "bridge" in st:
                assert lq.body_tool_known(st["bridge"]), st["bridge"]
    recall = next(s for _, s in checks if s["id"] == "recall_hold_walk")
    assert recall["observe_only"] is True


def test_validate_reports_problems(tmp_path):
    bad = {"id": "Bad-Id", "owner": "x", "steps": [{"bridge": "x", "probe": True}, {"client_cmd": "nope/x.lua"}],
           "pass": [{"ref": "a", "eq": 1, "gt": 2}, {"log": {"source": "nowhere", "regex": "("}, "gte": 1}],
           "timeout_s": 0, "preconditions": {"fixtures": [{"verb": "explode"}], "input_mode": "Gameplay"}}
    errs = " | ".join(lq.validate(bad, tmp_path / "other.json", root=tmp_path))
    for frag in ("id must be", "file name", "commit", "timeout_s", "exactly one of ('bridge'", "no command file",
                 "explode", "DIM_", "exactly one operator", "log takes"):
        assert frag in errs, frag
    assert lq.validate(basic(), None, item_ok=lambda i: False) == []
    g = basic(preconditions={"fixtures": [{"verb": "grant", "item": "ITEM_Nope"}]})
    assert "not in the catalog" in " ".join(lq.validate(g, None, item_ok=lambda i: False))


# ------------------------------------------------------------------ templates and criteria
def test_resolve_templates():
    ctx = {"start": {"position": [1.0, 2.0, 3.0]},
           "st": {"data": {"stations": [{"name": "Workbench", "id": "W1"}, {"name": "BP_Campfire_C", "id": "C7"}]}}}
    assert lq.resolve({"walk_to": {"$offset": ["start.position", [12, 0]]}}, ctx) == {"walk_to": [13.0, 2.0, 3.0]}
    assert lq.resolve({"$find": {"in": "st.data.stations", "match": {"name": "ampfire"}, "get": "id"}}, ctx) == "C7"
    assert lq.resolve([{"$ref": "start.position.2"}], ctx) == [3.0]
    for bad in ({"$ref": "nope"}, {"$offset": ["nope", [1]]},
                {"$find": {"in": "st.data.stations", "match": {"name": "furnace"}, "get": "id"}}):
        with pytest.raises(lq.Blocked):
            lq.resolve(bad, ctx)


def test_evaluate_ops_delta_dist_log():
    ctx = {"a": {"ok": True, "inv": {"W": 1}, "pos": [0, 0, 0], "mode": "DIM_Gameplay", "l": [1, 2]},
           "b": {"inv": {"W": 3}, "pos": [3, 4, 9]}}
    logs = lambda src, rx: ["crafting: closed [Processing]"] if rx == "closed" else []  # noqa: E731
    ok, r = lq.evaluate([{"ref": "a.ok", "eq": True}, {"delta": ["a.inv.W", "b.inv.W"], "gte": 2},
                         {"delta": ["a.inv.Missing", "b.inv.W"], "eq": 3}, {"dist": ["a.pos", "b.pos"], "eq": 5.0},
                         {"log": {"source": "client", "regex": "closed"}, "gte": 1}, {"ref": "a.mode", "regex": "^DIM_G"},
                         {"ref": "a.l", "contains": 2}, {"ref": "a.nope", "exists": False}], ctx, logs)
    assert ok, r
    ok, r = lq.evaluate([{"ref": "a.nope", "eq": None}, {"ref": "a.mode", "gt": 1}], ctx, logs)
    assert not ok and r[0]["missing"] and not r[1]["ok"]


def test_ts_reads_powershell_time():
    assert abs(lq._ts("2026-10-26T19:19:44.4604404Z") - lq._ts("2026-10-26T19:19:44Z") - 0.46) < 0.01
    assert lq._ts("garbage") == 0.0


# ------------------------------------------------------------------ the drain
def test_drain_passes_under_slot_and_releases(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    s = runner(env, world).drain([(p, basic())])
    assert s["checks"] == {"c1": "passed"}
    assert set(o for o in env.slot_owner_seen) == {lq.OWNER}               # every bridge call under our slot
    assert lq._slot_json(cs.main, ["status"])["free"]                       # released
    assert ("cmd", "bridge_start.lua", {"try_once": True}) in env.calls
    st = lq.load_state(world / "lq_state.json")["checks"]["c1"]
    assert st["status"] == "passed" and st["attempts"] == 1
    ev = [r for r in rows(world) if r["event"] == "check"][0]
    assert ev["verdict"] == "passed" and all(c["ok"] for c in ev["evidence"]["criteria"])
    # idempotent: a second drain runs nothing
    env2 = FakeEnv(world)
    assert runner(env2, world).drain([(p, basic())])["checks"] == {}
    assert not any(c[0] == "bridge" and c[1] == "craft" for c in env2.calls)
    # editing the file re-queues it
    p.write_text(json.dumps(basic(timeout_s=61)), encoding="utf-8")
    assert runner(FakeEnv(world), world).drain([(p, basic(timeout_s=61))])["checks"] == {"c1": "passed"}


def test_failed_retries_then_stays_failed(world):
    p = write_check(world, basic())
    env = FakeEnv(world, replies={"craft": {"ok": False, "reason": "missing_materials", "data": {}}})
    s = runner(env, world).drain([(p, basic())])
    assert s["checks"] == {"c1": "failed"}
    assert sum(1 for c in env.calls if c[:2] == ("bridge", "craft")) == 2   # 1 + max_retries
    assert not lq.is_pending(lq.load_state(world / "lq_state.json")["checks"]["c1"])


def test_hold_refuses_and_releases(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.hold = "logs/client.hold"
    s = runner(env, world).drain([(p, basic())])
    assert s["stopped"].startswith("hold") and s["checks"] == {}
    assert not any(c[0] == "bridge" for c in env.calls)
    assert lq._slot_json(cs.main, ["status"])["free"]


def test_unprobed_wait_is_status_only_and_same_pid_recovery_does_not_restart(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.status["state"] = "ok_unprobed"
    original_sleep = env.sleep
    def sleep(s):
        original_sleep(s)
        env.status.update(state="in_world", ts=lq.iso(env.t))
    env.sleep = sleep
    def transient(e, tool, args):
        if tool == "craft":
            e.status.update(state="ok_unprobed", ts=lq.iso(e.t))
    env.on_bridge = transient
    summary = runner(env, world).drain([(p, basic())])
    assert summary["checks"] == {"c1": "passed"}
    assert len([c for c in env.calls if c[0] == "cmd" and c[1] == "bridge_start.lua"]) == 1
    assert len([c for c in env.calls if c[0] == "reset_bridge"]) == 1
    assert len([r for r in rows(world) if r["event"] == "readiness_ready"]) == 2


@pytest.mark.parametrize("state,pid,age", [("paused", 10, 0), ("menu", 10, 0),
                                          ("in_world", None, 0), ("in_world", 10, 181),
                                          ("ok_unprobed", 10, -5)])
def test_unready_status_fails_without_actions(world, state, pid, age):
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.status = {"state": state, "pid": pid, "ts": lq.iso(env.t - age)}
    summary = runner(env, world).drain([(p, basic())])
    assert "precheck_failed" in summary and not env.calls and not env.fixtures
    assert lq._slot_json(cs.main, ["status"])["free"]


def test_unprobed_timeout_uses_monotonic_and_releases_slot(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.status["state"] = "ok_unprobed"
    def sleep(s):
        env.mono += s
        env.t += 1000 if int(env.mono) % 4 else -1000
        env.status["ts"] = lq.iso(env.t)
    env.sleep = sleep
    summary = runner(env, world).drain([(p, basic())])
    assert "timed out" in summary["precheck_failed"] and env.mono == lq.READINESS_WAIT_S
    assert not env.calls and lq._slot_json(cs.main, ["status"])["free"]


def test_hold_during_unprobed_wait_stops_without_actions(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.status["state"] = "ok_unprobed"
    old = env.sleep
    def sleep(s):
        old(s)
        env.hold = "hold"
    env.sleep = sleep
    summary = runner(env, world).drain([(p, basic())])
    assert summary["stopped"] == "hold hold" and not env.calls
    assert lq._slot_json(cs.main, ["status"])["free"]


def test_identity_change_during_admission_wait_fails_closed(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.status["state"] = "ok_unprobed"
    old = env.sleep
    def sleep(s):
        old(s)
        env.status.update(state="in_world", pid=11, ts=lq.iso(env.t))
    env.sleep = sleep
    summary = runner(env, world).drain([(p, basic())])
    assert "identity changed" in summary["precheck_failed"] and not env.calls and not env.fixtures


def test_guard_failure_after_unprobed_wait_does_not_rearm(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.status["state"] = "ok_unprobed"
    env.guard_error = "forbidden"
    old = env.sleep
    def sleep(s):
        old(s)
        env.status.update(state="in_world", ts=lq.iso(env.t))
    env.sleep = sleep
    summary = runner(env, world).drain([(p, basic())])
    assert "forbidden" in summary["precheck_failed"] and not env.calls and not env.fixtures


def test_changed_pid_recovery_refusal_never_resets_bridge(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    calls = 0
    original_cmd = env.client_cmd
    def cmd(rel, args, timeout):
        nonlocal calls
        if Path(rel).name == "bridge_start.lua":
            calls += 1
            if calls == 2:
                return {"ok": True, "result": {"ok": False, "refused": True, "why": "busy"}}
        return original_cmd(rel, args, timeout)
    env.client_cmd = cmd
    env.on_bridge = lambda e, tool, args: e.status.update(pid=11) if tool == "craft" else None
    summary = runner(env, world).drain([(p, basic())])
    assert summary["stopped"] == "client did not recover"
    assert len([c for c in env.calls if c[0] == "reset_bridge"]) == 1
    assert any(r["event"] == "recover_failed" and "busy" in r["problem"] for r in rows(world))


def test_changed_pid_wrong_server_never_rearms(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    def wrong_server(e, tool, args):
        if tool == "craft":
            e.status.update(pid=11)
            e.guard_error = "forbidden server"
    env.on_bridge = wrong_server
    summary = runner(env, world).drain([(p, basic())])
    assert summary["stopped"] == "client did not recover"
    assert len([c for c in env.calls if c[0] == "cmd" and c[1] == "bridge_start.lua"]) == 1
    assert any(r["event"] == "recover_failed" and "forbidden" in r["problem"] for r in rows(world))


def test_watchdog_down_then_new_pid_menu_and_pawn_waits_for_ready(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    def crash(e, tool, args):
        if tool == "craft" and not getattr(e, "crashed", False):
            e.crashed = True
            e.status = {"state": "down", "pid": None, "ts": lq.iso(e.t)}
    env.on_bridge = crash
    old = env.sleep
    def sleep(s):
        old(s)
        state = "menu" if env.mono < 20 else "no_pawn" if env.mono < 30 else "in_world"
        env.status = {"state": state, "pid": 11, "ts": lq.iso(env.t)}
    env.sleep = sleep
    summary = runner(env, world).drain([(p, basic())])
    assert summary["checks"] == {"c1": "passed"}
    assert len([c for c in env.calls if c[0] == "cmd" and c[1] == "bridge_start.lua"]) == 2
    assert any(r["event"] == "recover_bridge_start" for r in rows(world))


@pytest.mark.parametrize("state,pid", [("menu", 10), ("no_pawn", 10), ("unknown", None)])
def test_recovery_does_not_wait_on_unproven_identity(world, state, pid):
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.on_bridge = lambda e, tool, args: e.status.update(state=state, pid=pid) if tool == "craft" else None
    summary = runner(env, world).drain([(p, basic())])
    assert summary["stopped"] == "client did not recover"
    assert len([c for c in env.calls if c[0] == "cmd" and c[1] == "bridge_start.lua"]) == 1


def test_relaunch_deadline_bounds_unprobed_wait(world, monkeypatch):
    monkeypatch.setattr(lq, "RELAUNCH_WAIT_S", 12)
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.on_bridge = lambda e, tool, args: e.status.update(state="down", pid=None) if tool == "craft" else None
    old = env.sleep
    def sleep(s):
        old(s)
        env.status = {"state": "ok_unprobed", "pid": 11, "ts": lq.iso(env.t)}
    env.sleep = sleep
    summary = runner(env, world).drain([(p, basic())])
    assert summary["stopped"] == "client did not recover" and env.mono == 12
    assert len([c for c in env.calls if c[0] == "cmd" and c[1] == "bridge_start.lua"]) == 1


@pytest.mark.parametrize("reply", [None, {"ok": False}, {"ok": True, "result": {"ok": True, "deferred": True}},
                                   {"ok": True, "result": {"ok": False, "refused": True}},
                                   {"ok": True, "result": {"ok": True}}])
def test_unconfirmed_restart_stops_without_reset_or_check(world, reply):
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.client_cmd = lambda *args: reply
    summary = runner(env, world).drain([(p, basic())])
    assert "bridge start not completed" in summary["precheck_failed"]
    assert not env.fixtures and not any(c[0] == "reset_bridge" or (c[0] == "bridge" and c[1] != "ping") for c in env.calls)


def test_slot_busy_runs_nothing(world):
    p = write_check(world, basic())
    lq._slot_json(cs.main, ["take", "someone", "30"])
    env = FakeEnv(world)
    s = runner(env, world).drain([(p, basic())])
    assert s.get("slot_busy") and not env.calls
    assert lq._slot_json(cs.main, ["status"])["holder"]["owner"] == "someone"


def test_guard_failure_stops_before_any_check(world):
    p = write_check(world, basic())
    env = FakeEnv(world)
    env.guard_error = "client is on a forbidden server (1.2.3.4:7777)"
    s = runner(env, world).drain([(p, basic())])
    assert "forbidden" in s["precheck_failed"] and not any(c[1] == "craft" for c in env.calls if c[0] == "bridge")
    assert lq._slot_json(cs.main, ["status"])["free"]


def test_crash_waits_for_watchdog_relaunch_then_retries(world):
    p = write_check(world, basic())
    env = FakeEnv(world, replies={"craft": [{"ok": False, "reason": "body_restarted", "data": {}}, {"ok": True, "data": {}}]})

    def crash(e, tool, args):
        if tool == "craft" and not getattr(e, "crashed", False):
            e.crashed = True
            e.status = {"state": "booting", "ts": lq.iso(e.t), "pid": 10}
            e.relaunch_at = e.t + 95
    env.on_bridge = crash
    s = runner(env, world).drain([(p, basic())])
    assert s["checks"] == {"c1": "passed"}
    ev = [r["event"] for r in rows(world)]
    assert "recover_wait" in ev and "recover_bridge_start" in ev
    verdicts = [r["verdict"] for r in rows(world) if r["event"] == "check"]
    assert verdicts == ["error", "passed"]


def test_client_never_back_stops_run(world, monkeypatch):
    monkeypatch.setattr(lq, "RELAUNCH_WAIT_S", 60)
    a, b = write_check(world, basic("a1")), write_check(world, basic("b1"))
    env = FakeEnv(world, replies={"craft": {"ok": False, "reason": "timeout", "data": {}}})
    env.on_bridge = lambda e, t, a_: e.status.update(state="down", pid=None) if t == "craft" else None
    s = runner(env, world).drain([(a, basic("a1")), (b, basic("b1"))])
    assert s["checks"] == {"a1": "error"} and s["stopped"] == "client did not recover"
    e = lq.load_state(world / "lq_state.json")["checks"]["a1"]
    assert e["inconclusive_runs"] == 1 and lq.is_pending(e)                 # retried on a later drain
    assert lq._slot_json(cs.main, ["status"])["free"]


def test_stuck_input_mode_gets_one_gate_sweep(world):
    p = write_check(world, basic())
    stuck = {"input_mode": "DIM_FocussedInGameUI", "position": [0, 0, 0], "inventory": {}}
    ok = {"input_mode": "DIM_Gameplay", "position": [0, 0, 0], "inventory": {}}
    env = FakeEnv(world, probes=[ok, ok, stuck, stuck, ok])
    s = runner(env, world).drain([(p, basic())])
    assert s["checks"] == {"c1": "failed"} or s["checks"] == {"c1": "passed"}
    rec = [r for r in rows(world) if r["event"] == "recover_input_mode"]
    assert rec and rec[0]["before"] == "DIM_FocussedInGameUI"
    assert ("cmd", "input_gate_once.lua", None) in env.calls


def test_blocked_precondition_counts_and_gives_up(world):
    spec = basic(max_retries=2)
    p = write_check(world, spec)
    for i in range(lq.MAX_INCONCLUSIVE_RUNS):
        env = FakeEnv(world, probes=[{"input_mode": "DIM_SpellcastingMode"}])
        env.sticky = True
        s = runner(env, world).drain([(p, spec)])
        assert s["checks"] == {"c1": "blocked"}
        assert sum(1 for c in env.calls if c[:2] == ("bridge", "craft")) == 0   # blocked: no retry, no action
    e = lq.load_state(world / "lq_state.json")["checks"]["c1"]
    assert e["inconclusive_runs"] == lq.MAX_INCONCLUSIVE_RUNS and not lq.is_pending(e)


def test_observe_only_records_and_fixtures_run(world):
    spec = basic("obs", observe_only=True,
                 preconditions={"fixtures": [{"verb": "grant_runes", "runes": {"Air": 30}}], "set_health": {"pct": 100}},
                 steps=[{"probe": True, "save": "start"},
                        {"bridge": "cast", "args": {"spell": "Recall", "walk_to": {"$offset": ["start.position", [12, 0, 0]]}},
                         "save": "cast"}, {"probe": True, "save": "end"}])
    spec["pass"] = [{"ref": "cast.data.returned", "eq": True}]
    spec["observe"] = ["cast.data.walked_m", {"name": "moved", "dist": ["start.position", "end.position"]}]
    p = write_check(world, spec)
    env = FakeEnv(world, replies={"cast": {"ok": True, "data": {"walked_m": 11.8, "returned": False}}},
                  probes=[{"input_mode": "DIM_Gameplay", "position": [0, 0, 0]},
                          {"input_mode": "DIM_Gameplay", "position": [12, 0, 0]}])
    s = runner(env, world).drain([(p, spec)])
    assert s["checks"] == {"obs": "observed"}
    assert [f[0] for f in env.fixtures] == ["grant_runes", "set_health"]
    cast = next(c for c in env.calls if c[:2] == ("bridge", "cast"))
    assert cast[2]["walk_to"] == [12, 0, 0]
    ev = [r for r in rows(world) if r["event"] == "check"][0]["evidence"]
    assert ev["observed"]["cast.data.walked_m"] == 11.8 and ev["observed"]["moved"] == 12.0
    assert ev["criteria"][0]["ok"] is False                                 # recorded, not gating


def test_check_timeout_is_an_error(world):
    spec = basic(timeout_s=5, max_retries=0, steps=[{"sleep_s": 3}, {"sleep_s": 3}, {"bridge": "craft", "save": "craft"}])
    p = write_check(world, spec)
    s = runner(FakeEnv(world), world).drain([(p, spec)])
    assert s["checks"] == {"c1": "error"}


def test_single_instance_lock(tmp_path):
    with lq.single_instance(tmp_path / "l.lock") as a:
        assert a
        with lq.single_instance(tmp_path / "l.lock") as b:
            assert not b
    with lq.single_instance(tmp_path / "l.lock") as c:
        assert c


def test_main_if_free_is_quiet_when_slot_held(world, monkeypatch):
    lq._slot_json(cs.main, ["take", "someone", "30"])
    monkeypatch.setattr(lq, "CHECK_DIR", world / "checks")
    write_check(world, basic())
    ran = []
    monkeypatch.setattr(lq.Runner, "drain", lambda self, *a: ran.append(1) or {"checks": {}})
    assert lq.main(["run", "--if-free"]) == 0 and not ran
    lq._slot_json(cs.main, ["release", "someone"])
    monkeypatch.setattr(lq.Env, "held", lambda self: None)
    monkeypatch.setattr(lq.Env, "client_status", lambda self: {"state": "in_world", "ts": lq.iso()})
    monkeypatch.setattr(lq.Env, "guard", lambda self: (_ for _ in ()).throw(lq.InfraError("client is on 1.2.3.4:7777, not the local dev server")))
    assert lq.main(["run", "--if-free"]) == 0 and not ran                   # not on dev: quiet, slot untouched
    assert lq._slot_json(cs.main, ["status"])["free"]
    monkeypatch.setattr(lq.Env, "guard", lambda self: None)
    assert lq.main(["run", "--if-free"]) == 0 and ran == [1]


def test_main_dry_run_validates_only(world, monkeypatch, capsys):
    monkeypatch.setattr(lq, "CHECK_DIR", world / "checks")
    write_check(world, basic())
    write_check(world, {**basic("broken"), "steps": [{"bridge": "no_such_tool_xyz"}]})
    monkeypatch.setattr(lq.Env, "bridge", lambda *a: pytest.fail("dry run touched the bridge"))
    assert lq.main(["run", "--dry-run"]) == 1
    out = [json.loads(x) for x in capsys.readouterr().out.splitlines() if x.startswith("{")]
    by = {o.get("id"): o for o in out}
    assert by["c1"]["valid"] and not by["broken"]["valid"]
    assert not (world / "slot.json").exists() or lq._slot_json(cs.main, ["status"])["free"]


def test_server_step_and_cleanup_run_even_when_a_step_blocks(world):
    spec = basic("srv", max_retries=0, preconditions={},
                 steps=[{"fixture": "spawn", "class": "BP_AI_X_C", "save": "sp"},
                        {"server": "bench_creatures", "args": {"action": "read", "ids": [{"$ref": "sp.id"}]}, "save": "rd"},
                        {"bridge": "craft", "args": {"item": {"$ref": "nope.x"}}}],          # blocks
                 cleanup=[{"server": "bench_creatures", "args": {"action": "kill", "ids": [{"$ref": "sp.id"}]}, "save": "kill"},
                          {"server": "bench_creatures", "args": {"ids": [{"$ref": "never.made"}]}}])  # skipped
    spec["pass"] = [{"ref": "kill.ok", "eq": True}]
    assert lq.validate(spec) == []
    p = write_check(world, spec)
    env = FakeEnv(world)
    env.fixture = lambda verb, purpose, args: {"ok": True, "id": "X_1"}
    seen = []
    env.server = lambda module, args, timeout: seen.append((module, args)) or {"ok": True}
    s = runner(env, world).drain([(p, spec)])
    assert s["checks"] == {"srv": "blocked"}
    assert seen == [("bench_creatures", {"action": "read", "ids": ["X_1"]}), ("bench_creatures", {"action": "kill", "ids": ["X_1"]})]
    ev = [r for r in rows(world) if r["event"] == "check"][0]["evidence"]
    assert "skipped" in ev["cleanup"][1] and ev["cleanup"][0]["ok"] is True


def test_server_step_must_name_an_experiments_module():
    spec = basic("bad", steps=[{"server": "../bench/fixtures"}, {"server": "no_such_module_xyz"}])
    errs = lq.validate(spec)
    assert sum("mod/experiments" in e for e in errs) == 2

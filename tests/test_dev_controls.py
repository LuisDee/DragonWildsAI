import json
import hashlib
import time
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from evals.bench.spec import Case, load_cases
from tools import dev_controls as dc


def case(**changes):
    data = {"id": "example", "tier": "T0", "family": "spell_cast", "chat": [],
            "targets": ["dev"], "success": {"anything": {}}, "limits": {"wall_s": 1},
            "fixtures": {"setup": [{"verb": "unlock", "spell": "USD_Test", "as": "unlock"}]},
            "oracle": {"dev": [{"tool": "cast", "args": {"spell": "Test"}}]},
            "controls": {"wrong_action": [{"tool": "cast", "args": {"spell": "$unlock.name"}}]}}
    data.update(changes)
    return Case.model_validate(data)


def test_real_frozen_case_supports_list_script():
    cases = load_cases(Path("evals/bench/cases/t0_spells.json"))
    target = next(c for c in cases if c.id == "t0_cast_accesspersonalchest")
    assert dc.prepare(target, "oracle")[1] == target.oracle["dev"]
    assert dc.prepare(target, "wrong_action")[1] == target.controls.wrong_action


@pytest.mark.parametrize("script", [None, [], "scripted:absent", [{"note": "do something"}],
    [{"tool": "cast", "say": "also"}], [{"tool": "invented", "args": {}}],
    [{"pickup_all": "item"}], [{"wait_s": float("nan")}], [{"tool": "cast", "args": {"spell": "$missing.name"}}]])
def test_unknown_or_unbound_script_fails_before_effect(script):
    with pytest.raises(dc.Blocked):
        dc.prepare(case(oracle={"dev": script} if script is not None else {}), "oracle")


def test_snapshot_and_explicit_na_are_not_inferred():
    with pytest.raises(dc.Blocked, match="snapshot"):
        dc.prepare(case(fixtures={"state_snapshot": "fresh_dev_v1"}), "oracle")
    with pytest.raises(dc.Blocked, match="N/A"):
        dc.prepare(case(controls={"na": {"partial": "documented"}}), "partial")
    with pytest.raises(dc.Blocked, match="missing"):
        dc.prepare(case(controls={}), "partial")


class Game:
    def __init__(self): self.calls = []
    def call(self, tool, args):
        self.calls.append((tool, args))
        return {"ok": True, "data": {}}
    def say(self, text):
        self.calls.append(("say", text))
        return {"ok": True}


class Dev:
    def __init__(self): self.calls = []
    def guard(self, name, args): self.calls.append(("guard", name))
    def setup(self, verb, **args):
        self.calls.append(("setup", verb, args))
        return {"ok": True, "name": "Other"}
    def referee_start(self): self.calls.append(("referee_start",))
    def probe(self): return {"t": 1, "state": {}}
    def referee_events(self): return []


def judge_sequence(monkeypatch, outcomes):
    def judge(*args):
        result, reason = outcomes.pop(0)
        return result, reason, SimpleNamespace(detail="details", missing=[]), {"mismatches": []}
    monkeypatch.setattr(dc, "judge_dev", judge)


def run(tmp_path, monkeypatch, selected="wrong_action", outcomes=None, admission=lambda _: None, obj=None, now=None):
    judge_sequence(monkeypatch, outcomes or [("fail", "not_achieved"), ("fail", "not_achieved")])
    dev, game = Dev(), Game()
    journal = dc.Journal(tmp_path)
    clock = now or {"time": 0.0}
    def sleep(seconds): clock["time"] += seconds
    try:
        result = dc.execute(obj or case(), selected, dev=dev, game=game, admission=admission, journal=journal,
                            metadata={"actual_client_build": "26162923"}, clock=lambda: clock["time"], sleep=sleep)
    finally:
        journal.close()
    rows = [json.loads(x) for x in journal.path.read_text(encoding="utf-8").splitlines()]
    return result, rows, dev, game, clock


def test_native_step_binding_and_immutable_diagnostic_only(tmp_path, monkeypatch):
    result, rows, _, game, _ = run(tmp_path, monkeypatch)
    assert game.calls == [("cast", {"spell": "Other"})]
    assert result["status"] == "observed_expected" and result["promotion"] == "disabled"
    assert result["retain_slot"] is True and result["actual_client_build"] == "26162923"
    assert [x["kind"] for x in rows].index("step_intent") < [x["kind"] for x in rows].index("step_result")
    assert not list(tmp_path.rglob("validity/*.json"))


def test_ambient_waits_full_wall_window_and_claims_only_speaks(tmp_path, monkeypatch):
    result, rows, _, game, clock = run(tmp_path, monkeypatch, "do_nothing")
    assert clock["time"] == 1 and game.calls == [] and result["status"] == "observed_expected"
    assert any(x["kind"] == "wait_complete" for x in rows)
    result, _, _, game, _ = run(tmp_path, monkeypatch, "claims_only")
    assert game.calls == [("say", "Done, all sorted!")]
    assert result["status"] == "observed_expected"


@pytest.mark.parametrize("baseline", [("pass", None), ("unverifiable", "perception_gap"), ("fail", "guard")])
def test_invalid_baseline_prevents_action(tmp_path, monkeypatch, baseline):
    result, _, _, game, _ = run(tmp_path, monkeypatch, outcomes=[baseline])
    assert result["status"] == "blocked" and game.calls == []


@pytest.mark.parametrize("outcome", [("fail", "guard"), ("error", "sensor_mismatch"),
                                      ("unverifiable", "perception_gap"), ("pass", None)])
def test_negative_must_fail_not_achieved(tmp_path, monkeypatch, outcome):
    result, _, _, _, _ = run(tmp_path, monkeypatch, outcomes=[("fail", "not_achieved"), outcome])
    assert result["status"] == "blocked_negative"


def test_lost_admission_retains_partial_and_no_cleanup(tmp_path, monkeypatch):
    def admission(where):
        if where == "action:cast": raise dc.Blocked("slot lost")
    result, rows, dev, game, _ = run(tmp_path, monkeypatch, admission=admission)
    assert result["status"] == "blocked" and result["retain_slot"]
    assert game.calls == [] and any(row["kind"] == "step_intent" for row in rows)
    assert not any(call[0] == "referee_stop" for call in dev.calls)


def test_missing_concrete_binding_blocks_before_action(tmp_path, monkeypatch):
    obj = case(controls={"wrong_action": [{"tool": "cast", "args": {"spell": "$unlock.missing"}}]})
    result, _, _, game, _ = run(tmp_path, monkeypatch, obj=obj)
    assert result["status"] == "blocked" and game.calls == []


def test_import_and_describe_do_not_create_output(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    root = Path(__file__).resolve().parents[1]
    assert dc.main(["--describe", str(root / "evals/bench/cases/t0_spells.json"), "--case", "t0_cast_accesspersonalchest"]) == 0
    assert list(tmp_path.iterdir()) == []


def test_idle_rejects_foreign_or_unknown_work():
    def ok(data): return {"ok": True, "data": data}
    state = ok({"name": "ClaudeDev", "pawn": "pawn", "dead": False})
    ping = ok({"action": None, "waiters": [], "started": 100})
    arb = ok({"owner": None, "suspended": [], "counts": {}, "history": []})
    bridge = ok({"paused": False, "action": None})
    move = ok({"mode": "idle"})
    assert dc.idle(state, ping, arb, bridge, move, "ClaudeDev", "pawn")
    assert not dc.idle(state, ok({"action": {"id": "other"}, "waiters": [], "started": 100}), arb, bridge, move, "ClaudeDev", "pawn")
    assert not dc.idle(state, ping, ok({"owner": None}), bridge, move, "ClaudeDev", "pawn")
    assert not dc.idle(state, ping, arb, bridge, move, "ClaudeDev", "other")
    assert not dc.idle(state, ping, arb, ok({"paused": False}), move, "ClaudeDev", "pawn")


def test_live_cli_requires_operator_and_uses_deployed_root(tmp_path):
    with pytest.raises(SystemExit):
        dc.main(["--execute", "evals/bench/cases/t0_spells.json", "--case", "t0_cast_accesspersonalchest"])
    result = dc.main(["--execute", "evals/bench/cases/t0_spells.json", "--case", "t0_cast_accesspersonalchest",
                      "--slot-owner", "operator", "--expected-pawn", "pawn", "--expected-world", "dev",
                      "--expected-endpoint", "127.0.0.1:1", "--backup", str(tmp_path),
                      "--publication-manifest", str(tmp_path / "manifest.json"), "--operator-watchdog"])
    assert result == 1


def test_failed_action_is_not_a_negative_pass(tmp_path, monkeypatch):
    judge_sequence(monkeypatch, [("fail", "not_achieved")])
    class Failed(Game):
        def call(self, tool, args): return {"ok": False, "reason": "not_available"}
    journal = dc.Journal(tmp_path)
    try:
        result = dc.execute(case(), "wrong_action", dev=Dev(), game=Failed(), admission=lambda _: None,
                            journal=journal, metadata={}, clock=lambda: 0)
    finally:
        journal.close()
    assert result["status"] == "blocked" and result["retain_slot"]


def test_fresh_admission_rejects_foreign_work_and_lost_slot(tmp_path, monkeypatch):
    from brain import worlds
    state_dir = tmp_path / "logs/state"
    state_dir.mkdir(parents=True)
    slot = state_dir / "client_slot.json"
    slot.write_text(json.dumps({"holder": {"owner": "root", "until": time.time() + 300}}))
    status = {"ts": datetime.now(timezone.utc).isoformat(), "state": "in_world", "dev_server": True,
              "map": "L_World", "logged_in": True, "pawn": "p", "pid": 42, "build": "26162923"}
    (state_dir / "client_status.json").write_text(json.dumps(status))
    monkeypatch.setattr(dc, "process_start", lambda pid: "start")
    monkeypatch.setattr(worlds, "resolve_world_guid", lambda *args: ("dev", "world_info"))
    def ok(value): return {"ok": True, "data": value}
    class Body:
        action = None
        def get_state(self): return ok({"name": "ClaudeDev", "pawn": "p", "dead": False})
        def request(self, name, args, timeout):
            return ok({"ping": {"started": 3, "action": self.action, "waiters": []},
                       "arbiter_status": {"owner": None, "counts": {}, "history": [], "suspended": []},
                       "bridge_status": {"paused": False, "action": self.action},
                       "move_status": {"mode": "idle"}}[name])
    class GuardedDev:
        def joined(self): return "127.0.0.1:123"
        def forbidden(self): return ["forbidden:123"]
        def guard(self, *args): pass
    journal = dc.Journal(tmp_path)
    body = Body()
    guard = dc.LiveAdmission(tmp_path, GuardedDev(), body, "root", "p", "dev", "127.0.0.1:123",
                             time.monotonic() + 60, journal)
    try:
        guard("initial")
        body.action = {"id": "foreign"}
        with pytest.raises(dc.Blocked, match="busy"):
            guard("fixture")
        body.action = None
        slot.write_text(json.dumps({"holder": {"owner": "other", "until": time.time() + 300}}))
        with pytest.raises(dc.Blocked, match="slot"):
            guard("action")
    finally:
        journal.close()


def test_revocation_during_pre_action_probe_prevents_dispatch(tmp_path, monkeypatch):
    judge_sequence(monkeypatch, [("fail", "not_achieved")])
    active = {"value": True}
    class ProbeRevokes(Dev):
        probes = 0
        def probe(self):
            self.probes += 1
            if self.probes == 2: active["value"] = False
            return super().probe()
    def admission(where):
        if not active["value"]: raise dc.Blocked("lost slot")
    journal, game = dc.Journal(tmp_path), Game()
    try:
        result = dc.execute(case(), "wrong_action", dev=ProbeRevokes(), game=game, admission=admission,
                            journal=journal, metadata={}, clock=lambda: 0)
    finally:
        journal.close()
    assert result["status"] == "blocked" and game.calls == []


def test_revocation_before_say_prevents_dispatch(tmp_path, monkeypatch):
    judge_sequence(monkeypatch, [("fail", "not_achieved")])
    active = {"value": True}
    def admission(where):
        if where == "step": active["value"] = False
        elif not active["value"]: raise dc.Blocked("lost slot")
    journal, game = dc.Journal(tmp_path), Game()
    try:
        result = dc.execute(case(), "claims_only", dev=Dev(), game=game, admission=admission,
                            journal=journal, metadata={}, clock=lambda: 0)
    finally:
        journal.close()
    assert result["status"] == "blocked" and game.calls == []


def backup_manifest(tmp_path):
    directory = tmp_path / "logs/recovery/snapshot"
    directory.mkdir(parents=True)
    sources = {"world_state": "logs/state/worlds/dev/map.json", "skills": "data/skills/dev/nav.json",
               "envelopes": "data/envelopes/Claude.json", "client_state": "client_io/state/a.json",
               "world_save": "game/Saved/SaveGames/world.sav"}
    files = []
    for index, (category, source) in enumerate(sources.items()):
        copy = f"{index}.bak"
        content = category.encode()
        (directory / copy).write_bytes(content)
        files.append({"category": category, "source": source, "copy": copy,
                      "sha256": hashlib.sha256(content).hexdigest()})
    path = directory / "manifest.json"
    path.write_text(json.dumps({"world": "dev", "character": "ClaudeDev", "files": files}))
    return path


def test_backup_manifest_validates_identity_coverage_and_copy_hash(tmp_path):
    path = backup_manifest(tmp_path)
    result = dc.backup_attestation(path, tmp_path, "dev")
    assert result["files"] == 5 and result["world"] == "dev"
    with pytest.raises(dc.Blocked, match="identity"):
        dc.backup_attestation(path, tmp_path, "different")
    (path.parent / "0.bak").write_bytes(b"changed")
    with pytest.raises(dc.Blocked, match="digest"):
        dc.backup_attestation(path, tmp_path, "dev")


def test_backup_manifest_rejects_gaps_and_traversal(tmp_path):
    path = backup_manifest(tmp_path)
    obj = json.loads(path.read_text())
    obj["files"].pop()
    path.write_text(json.dumps(obj))
    with pytest.raises(dc.Blocked, match="coverage"):
        dc.backup_attestation(path, tmp_path, "dev")
    obj["files"][0]["copy"] = "../outside"
    path.write_text(json.dumps(obj))
    with pytest.raises(dc.Blocked, match="escapes"):
        dc.backup_attestation(path, tmp_path, "dev")

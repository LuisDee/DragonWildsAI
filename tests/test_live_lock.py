"""The live lock's queue order: rank first, less one rank per AGE_S waited (live 2026-11-02: rung3 starved 31 min)."""
import json
import os
import time

from tools import live_lock


def _ticket(qdir, owner, age_s):
    t = qdir / f"{time.time_ns() - int(age_s * 1e9)}_{owner}_{os.getpid()}"
    t.write_text(owner, encoding="utf-8")
    return t


def test_a_long_wait_outranks_a_fresh_higher_rank(tmp_path, monkeypatch):
    pri = tmp_path / "pri.json"
    pri.write_text(json.dumps({"rung1": 0, "rung3": 3}), encoding="utf-8")
    monkeypatch.setattr(live_lock, "PRIORITY", pri)
    _ticket(tmp_path, "rung1", 10)
    _ticket(tmp_path, "rung3", 60)
    assert [x["owner"] for x in live_lock.queue(tmp_path)] == ["rung1", "rung3"]
    _ticket(tmp_path, "rung3", 4 * live_lock.AGE_S)
    assert live_lock.queue(tmp_path)[0]["owner"] == "rung3"

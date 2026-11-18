"""tools/client_park.py and the live lock's unpark: a window that takes the lock while the watchdog has him logged off
(docs/research/2026-11-17-idle-starvation.md) gets him back into the world before anything is sent to the body.
No client, no PowerShell: client_boot is faked."""
import json

from tools import client_park, live_lock


def _mark(tmp_path, mode="menu"):
    p = tmp_path / "client_park.json"
    p.write_text(json.dumps({"mode": mode, "since": "2026-11-18T01:00:00Z"}), encoding="utf-8")
    return p


def test_not_parked_is_a_no_op(tmp_path):
    calls = []
    assert client_park.unpark(boot=lambda: calls.append(1) or 0, path=tmp_path / "none.json") == "not parked"
    assert calls == []


def test_unpark_boots_and_clears_the_marker(tmp_path):
    p = _mark(tmp_path)
    msg = client_park.unpark(boot=lambda: 0, path=p)
    assert msg.startswith("unparked") and "menu" in msg
    assert not p.exists()


def test_unpark_waits_out_a_boot_already_running(tmp_path):
    p, rcs, slept = _mark(tmp_path, "off"), [client_park.BOOT_LOCKED, client_park.BOOT_LOCKED, 0], []
    msg = client_park.unpark(boot=lambda: rcs.pop(0), path=p, sleep=slept.append)
    assert msg.startswith("unparked") and len(slept) == 2 and not p.exists()


def test_a_failed_unpark_says_so_and_keeps_the_marker(tmp_path):
    p = _mark(tmp_path)
    msg = client_park.unpark(boot=lambda: 3, path=p)  # 3: a hold file; never released from here
    assert msg.startswith("unpark failed") and "exit 3" in msg
    assert p.exists()


def test_an_unreadable_marker_still_counts_as_parked(tmp_path):
    p = tmp_path / "client_park.json"
    p.write_text("{half", encoding="utf-8")
    assert client_park.parked(p) == {"mode": "unknown"}


def _fake_lock(tmp_path, monkeypatch, calls):
    """try_claim/release bind the real lock path as a default argument: fake them, never touch logs/state."""
    monkeypatch.setattr(live_lock, "LOCK", tmp_path / "live_owner.txt")
    monkeypatch.setattr(live_lock, "QUEUE", tmp_path / "live_queue")
    monkeypatch.setattr(live_lock, "PRIORITY", tmp_path / "pri.json")
    monkeypatch.setattr(live_lock, "try_claim", lambda owner, pid=None: calls.append("claim") or True)
    monkeypatch.setattr(live_lock, "release", lambda owner, pid=None: calls.append("release"))


def test_taking_the_lock_unparks_him_first(tmp_path, monkeypatch):
    calls, logs = [], []
    _fake_lock(tmp_path, monkeypatch, calls)
    monkeypatch.setattr(client_park, "PARK", _mark(tmp_path))
    monkeypatch.setattr(live_lock, "unpark", lambda: calls.append("unpark") or "unparked: back in the world")
    with live_lock.held("quests", wait_s=5, log=logs.append, clean=False):
        # claimed before the unpark: the watchdog reads the lock after writing its marker, so it cannot park him now
        assert calls == ["claim", "unpark"]
    assert calls[-1] == "release" and "park: unparked" in logs[0]


def test_taking_the_lock_leaves_an_unparked_client_alone(tmp_path, monkeypatch):
    calls, logs = [], []
    _fake_lock(tmp_path, monkeypatch, calls)
    monkeypatch.setattr(client_park, "PARK", tmp_path / "none.json")
    monkeypatch.setattr(live_lock, "unpark", lambda: calls.append("unpark") or "x")
    with live_lock.held("quests", wait_s=5, log=logs.append, clean=False):
        pass
    assert calls == ["claim", "release"] and "park" not in logs[0]

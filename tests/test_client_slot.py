import json
import tools.client_slot as cs


def run(tmp_path, monkeypatch, *args, now=1000.0):
    monkeypatch.setattr(cs, "STATE", tmp_path / "slot.json")
    monkeypatch.setattr(cs.time, "time", lambda: now)
    return cs.main(list(args))


def state(tmp_path):
    return json.loads((tmp_path / "slot.json").read_text())


def test_release_hands_off_to_next_and_reservation_expires(tmp_path, monkeypatch):
    run(tmp_path, monkeypatch, "take", "a", "10")
    run(tmp_path, monkeypatch, "enqueue", "b")
    run(tmp_path, monkeypatch, "enqueue", "c")
    run(tmp_path, monkeypatch, "release", "a")
    assert state(tmp_path)["holder"]["owner"] == "b" and state(tmp_path)["holder"]["reserved"]
    assert run(tmp_path, monkeypatch, "take", "c", "5") == 1          # c can't jump b's reservation
    run(tmp_path, monkeypatch, "status", now=1000 + cs.RESERVE_S + 1)  # b never claimed -> moves on
    assert state(tmp_path)["holder"]["owner"] == "c"
    assert run(tmp_path, monkeypatch, "take", "c", "5", now=1000 + cs.RESERVE_S + 2) == 0


def test_enqueue_keeps_position(tmp_path, monkeypatch):
    run(tmp_path, monkeypatch, "take", "a", "10")
    run(tmp_path, monkeypatch, "enqueue", "b")
    run(tmp_path, monkeypatch, "enqueue", "c")
    run(tmp_path, monkeypatch, "enqueue", "b")
    assert [q["owner"] for q in state(tmp_path)["queue"]] == ["b", "c"]

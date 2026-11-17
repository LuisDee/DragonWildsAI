"""travel_ladder follow legs: the synthetic house-exit ghost and the human model's door pause (offline)."""
import tools.travel_ladder as T


def test_house_exit_ghost_and_door_pause(tmp_path, monkeypatch):
    monkeypatch.setattr(T, "GHOSTS", tmp_path / "ghosts.json")
    g = T.make_ghost("follow_house_exit", T.HOUSE_EXIT)
    assert g["door"] == T.HOUSE_EXIT["door"] and g["pauses"][0][1] == T.DOOR_S
    assert g["track"][0][1:3] == [9621, 185160] and g["duration_s"] > 3.0
    assert "follow_house_exit" in T.ghosts()
    plain = T.human_follower(g["track"], 2.0, 10.0, start=g["claude_start"])
    door = T.human_follower(g["track"], 2.0, 10.0, start=g["claude_start"], pauses=g["pauses"])
    # the follower stands at the door for DOOR_S: the gap to the leader grows by about the leader's speed x DOOR_S
    gap = lambda rows: max(T.d3(gp, fp) for _, gp, fp in rows)  # noqa: E731
    assert gap(door) > gap(plain) + 2.0
    s_plain = T.score_follow(plain, 2.0, g["duration_s"], 10.0)
    s_door = T.score_follow(door, 2.0, g["duration_s"], 10.0)
    assert s_door["within_6m"] <= s_plain["within_6m"] and s_door["end_gap_m"] <= 3.5


def test_a_starved_body_stops_the_ladder_before_any_leg(tmp_path, monkeypatch, capsys):
    import sys
    import pytest
    from evals.bench import devrun
    from tools import live_lock
    starved = {"health": 1.0, "max_health": 100.0, "sustenance": 0.0, "sustenance_max": 100.0, "hydration": 0.0,
               "hydration_max": 100.0}

    class Cli:
        def request(self, tool, args, timeout=None):
            assert tool == "get_state"
            return {"ok": True, "data": dict(starved)}

    legs = []
    monkeypatch.setattr(sys, "argv", ["travel_ladder", "--only", "leg"])
    monkeypatch.setenv("DW_LIVE_OWNER", "test")
    monkeypatch.setattr(live_lock, "read", lambda: {"stale": False, "owner": "test"})
    monkeypatch.setattr(devrun, "default_dev", lambda: type("Dev", (), {"guard": lambda self: None})())
    monkeypatch.setattr(T, "client", lambda: Cli())
    monkeypatch.setattr(T, "pick", lambda *a: [{"id": "leg"}])
    monkeypatch.setattr(T, "ghosts", lambda: {})
    monkeypatch.setattr(T, "run_journey", lambda dev, j: legs.append(j))
    monkeypatch.setattr(T, "OUT", tmp_path / "travel_ladder.jsonl")
    with pytest.raises(SystemExit) as e:
        T.main()
    assert e.value.code == 3 and legs == [] and not (tmp_path / "travel_ladder.jsonl").exists()
    assert "not running: body unfit: health 1 of 100, food 0 of 100, water 0 of 100" in capsys.readouterr().out

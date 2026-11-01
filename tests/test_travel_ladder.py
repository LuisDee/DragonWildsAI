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

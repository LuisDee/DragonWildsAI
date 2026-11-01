"""Retro 2026-11-01 root causes 3 and 4: players out of sight are listed from the game map's markers, and
what lies around the player who spoke reaches the model as one context line (information only)."""
from __future__ import annotations

import copy

from brain import situation as sit
from test_event_hygiene import STATES, Replay

FAR = {"name": "luisdeburnaybast", "position": [339.8, 1622.7, -30.0], "distance": 319.6, "direction": "NE",
       "bearing_deg": 45, "in_sight": False}
NEAR = {"player": "luisdeburnaybast", "radius_m": 15, "things": [
    {"id": "Item:7", "name": "Stone", "kind": "item", "count": 1, "distance": 1.2, "side": "in front", "from_me": 31.4},
    {"id": "Item:8", "name": "Stone", "kind": "item", "count": 1, "distance": 2.0, "side": "in front", "from_me": 32.0},
    {"id": "Res:3", "name": "Oak Tree", "kind": "resource", "distance": 9.5, "side": "behind", "from_me": 25.0}]}


def test_same_player_matches_a_name_cut_short_but_not_a_short_prefix():
    assert sit.same_player("luisdeburnaybast", "luisdeburnaybastos")
    assert sit.same_player("LuisDeBurnayBastos", "luisdeburnaybast")
    assert not sit.same_player("luis", "luisdeburnaybast")
    assert not sit.same_player("Zezima", "Zezimb")
    # the game's name filter masks the map registry's name (live 2026-11-01)
    assert sit.same_player("luisdeburnayb***t", "luisdeburnaybast")
    assert sit.same_player("luisdeburnaybastos", "luisdeburnayb***t")
    assert sit.same_player("luisdeburnayb***t", "luisdeburnay")
    assert not sit.same_player("luisdeburnayb***t", "luisdeburnaybasx")
    assert not sit.same_player("a.b**c", "axbyyc")


def test_players_line_lists_a_map_marker_out_of_sight():
    lines = sit.map_players({"map_players": [FAR]})
    assert lines == ["luisdeburnaybast 320 m NE (out of sight; go_to/follow go by his map marker)"]
    # a player the census already lists (in sight) is not repeated
    assert sit.map_players({"map_players": [FAR]}, ["luisdeburnaybastos"]) == []
    state = copy.deepcopy(STATES[1])
    state["players"], state["map_players"] = [], [FAR]
    players = next(line for line in sit.summary(state) if line.startswith("Players"))
    assert "luisdeburnaybast 320 m NE (out of sight" in players, players


def test_near_speaker_says_what_is_around_him_with_sides_and_ids():
    line = sit.near_speaker({"near_players": [NEAR]}, "luisdeburnaybastos")
    assert line.startswith("Within 15 m of luisdeburnaybast (who spoke): 2 Stone (item; nearest 1.2 m in front of him"), line
    assert "31 m from you" in line and "id Item:7" in line and "1 Oak Tree (resource; nearest 9.5 m behind him" in line
    assert sit.near_speaker({"near_players": [NEAR]}, "Zezima") is None
    empty = sit.near_speaker({"near_players": [{"player": "Zezima", "radius_m": 15, "things": []}]}, "Zezima")
    assert empty == "Within 15 m of Zezima (who spoke): nothing lying there to pick up or gather."


def test_controller_context_carries_near_speaker_only_for_the_one_who_spoke(tmp_path):
    state = copy.deepcopy(STATES[1])
    state["near_players"] = [dict(NEAR, player="Zezima")]
    r = Replay(tmp_path, state)
    ctx = r.controller.context("Zezima", "grab the 2 stone in front of me", state, None)
    assert ctx.get("near_speaker", "").startswith("Within 15 m of Zezima (who spoke): 2 Stone"), ctx.get("near_speaker")
    ctx = r.controller.context("Someone", "grab the stone", state, None)
    assert "near_speaker" not in ctx

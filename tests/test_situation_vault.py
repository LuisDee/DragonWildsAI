"""Vault reads in what the models are shown (client sense.lua vault section, commit 6d78811): in_vault / vault, door
rows (leads_to, destination, locked), lever rows (switch_position, switch_highest, drives), chest rows (chest_state)
and traps (hazards). Each field the body read is shown in words; a field it did not read shows nothing."""
from brain import director as D
from brain.controller import _look_row, look_view
from brain.planner import _trim_state
from brain.situation import (LINE_CHARS, summary, vault_fields, vault_here, vault_row_fields, vault_words)

DOOR = {"id": "BP_InteractablePlayerTeleporter_C_3", "name": "Interactable Player Teleporter", "prompt": "Enter",
        "kind": "interactable", "distance": 4.2, "class": "BP_InteractablePlayerTeleporter_C",
        "category": "interactables", "destination": "VertentisKara_Exit", "arrives_at": [-1653.1, 218.4, -31.2],
        "leads_to": "outside", "locked": False}
LEVER = {"id": "BP_BinaryLever_C_7", "name": "Binary Lever", "prompt": "Pull", "kind": "interactable", "distance": 9.8,
         "switch_position": 0, "switch_highest": 1, "drives": ["BP_FinalDoor_vault_Refactored_C_1"]}
CHEST = {"id": "BP_WorldChest_Vault_C_2", "name": "Vault Chest", "prompt": "Open", "kind": "chest", "distance": 14.0,
         "chest_state": "unopened"}
BENCH = {"id": "BP_Workbench_C_1", "name": "Workbench", "prompt": "Craft", "kind": "station", "distance": 6.0}
TRAP = {"id": "BP_FireTrap_C_4", "name": "Fire Trap", "kind": "trap", "class": "BP_FireTrap_C", "category": "hazards",
        "distance": 7.5, "position": [-1650, 220, -31], "parts": 2, "active_parts": 1}


def state(**kw):
    return {"position": [0, 0, 0], "health": 80, "max_health": 100, "interactables": [DOOR, LEVER, CHEST, BENCH], **kw}


def text(st):
    return "\n".join(summary(st))


# ---------------------------------------------------------------- in_vault / vault

def test_in_vault_true_with_its_name_on_the_you_line():
    you = summary(state(in_vault=True, vault="Vertentis Kara"))[0]
    assert you.startswith("You: ") and you.endswith(", in vault Vertentis Kara")
    assert vault_here({"in_vault": True}) == "in a vault"


def test_no_vault_box_and_the_flag_false_or_unread_shows_nothing():
    for st in (state(in_vault=False), state()):
        t = text(st)
        assert "vault Vertentis" not in t and "in a vault" not in t and "Vault:" not in t and "In vault" not in t
    assert vault_fields({"in_vault": False}) == {} and vault_fields({}) == {}


def test_the_vault_box_says_in_vault_whatever_the_flag():
    # the probe of 19 Nov (run 20261119-063427, build 26670300): inside Crasorak Kara get_state read in_vault false
    # and vault "Crasorak Kara" (the registry box that holds him); the model is told he is in it
    probe = {"position": [-1662.25, 1045.84, -428.21], "in_vault": False, "vault": "Crasorak Kara"}
    assert vault_here(probe) == "in vault Crasorak Kara"
    assert vault_fields(probe) == {"in_vault": True, "vault": "Crasorak Kara"}
    assert summary(state(in_vault=False, vault="Crasorak Kara"))[0].endswith(", in vault Crasorak Kara")
    assert vault_here({"vault": "Crasorak Kara"}) == "in vault Crasorak Kara"  # the flag unread
    assert vault_fields({"in_vault": True, "vault": " "}) == {"in_vault": True}
    # at the door outside (the probe's door row): in_vault false, no box: nothing
    assert vault_here({"position": [370.7, 1915.0, -1.2], "in_vault": False}) is None


# ---------------------------------------------------------------- door rows

def test_door_says_where_it_leads_and_whether_locked():
    t = text(state())
    assert "Interactable Player Teleporter (4 m, id BP_InteractablePlayerTeleporter_C_3, Enter, leads outside, unlocked)" in t
    assert vault_words({**DOOR, "leads_to": "Crasorak Kara", "locked": True}) == ["leads to Crasorak Kara", "locked"]


def test_door_without_a_vault_box_names_the_games_destination():
    row = {k: v for k, v in DOOR.items() if k not in ("leads_to", "locked")}
    assert vault_words(row) == ["teleports to VertentisKara_Exit"]
    assert vault_row_fields(row) == {"destination": "VertentisKara_Exit"}
    assert "destination" not in vault_row_fields(DOOR)  # leads_to says it in words; arrives_at is left to look
    assert "arrives_at" not in vault_row_fields(DOOR)


# ---------------------------------------------------------------- lever rows

def test_lever_says_its_switch_position_and_what_it_drives():
    t = text(state())
    assert ("Binary Lever (10 m, id BP_BinaryLever_C_7, Pull, switch position 0 of 0-1, "
            "drives BP_FinalDoor_vault_Refactored_C_1)") in t
    assert vault_words({"switch_position": 1}) == ["switch position 1"]
    many = vault_words({"switch_position": 0, "drives": ["a", "b", "c", "d", "e"]})
    assert many == ["switch position 0", "drives a, b, c +2 more"]


# ---------------------------------------------------------------- chest rows

def test_chest_says_unopened_opened_or_emptied():
    assert "Vault Chest (14 m, id BP_WorldChest_Vault_C_2, Open, chest unopened)" in text(state())
    for cs in ("opened", "emptied"):
        assert vault_words({"chest_state": cs}) == [f"chest {cs}"]
    assert vault_words({"chest_state": "bogus"}) == [] and vault_words({"chest_state": None}) == []


def test_rows_without_vault_fields_are_as_before():
    t = text({"position": [0, 0, 0], "interactables": [BENCH]})
    assert "Usable: Workbench (6 m, id BP_Workbench_C_1, Craft)" in t
    assert vault_words(BENCH) == [] and vault_row_fields(BENCH) == {}
    assert vault_words({"locked": None, "switch_position": True, "drives": []}) == []  # unread or not a number


def test_usable_line_has_room_for_vault_rows():
    usable = next(ln for ln in summary(state()) if ln.startswith("Usable:"))
    assert len(usable) > LINE_CHARS and usable.endswith("chest unopened)")


# ---------------------------------------------------------------- hazards

def test_traps_under_hazards():
    t = text(state(hazards=[TRAP, {"name": "Spike Trap", "distance": 3}]))
    assert "Hazards: Spike Trap (3 m); Fire Trap (8 m, id BP_FireTrap_C_4, 1 of 2 parts active)" in t
    assert "Hazards" not in text(state()) and "Hazards" not in text(state(hazards=[]))


# a standing poison cloud as the client census lists it (sense.ground_hazards_into; L3 deaths 2026-11-20)
CLOUD = {"id": "BP_DEDA_PoisonBreath_PoisonCloud_C_9", "kind": "ground_hazard", "hazard": "poison_cloud_box",
         "name": "poison cloud", "effect": "poisons you while you stand in it (damage over time, about 4 HP a second)",
         "position": [396.1, 1681.4, -41.8], "distance": 12.0, "center_m": 17.0, "direction": "NW", "across_m": 8,
         "owner_class": "BP_DEDA_PoisonBreath_PoisonCloud_C", "category": "hazards"}


def test_poison_cloud_under_hazards_with_distance_direction_and_effect():
    t = text(state(hazards=[CLOUD, TRAP]))
    assert ("Hazards: Fire Trap (8 m, id BP_FireTrap_C_4, 1 of 2 parts active); poison cloud (12 m NW, about 8 m across, "
            "poisons you while you stand in it (damage over time, about 4 HP a second), your walks route round it)") in t
    inside = text(state(hazards=[dict(CLOUD, distance=0, inside=True)]))
    assert "poison cloud (you are IN it, about 8 m across" in inside


def test_the_planner_sees_the_hazards_line_too():
    out = _trim_state(state(hazards=[CLOUD]))
    assert out["hazards"] and out["hazards"][0].startswith("poison cloud (12 m NW")
    assert "hazards" not in _trim_state(state())


# ---------------------------------------------------------------- look, Planner, Director

def test_look_keeps_vault_fields_and_drops_an_unread_or_false_flag():
    data = {"things": [DOOR, LEVER, CHEST, TRAP], "in_vault": True, "vault": "Vertentis Kara", "total": 4}
    v = look_view(data)
    assert v["in_vault"] is True and v["vault"] == "Vertentis Kara" and v["total"] == 4
    door, lever, chest, trap = v["things"]
    assert door["leads_to"] == "outside" and door["locked"] is False and door["destination"] == "VertentisKara_Exit"
    assert door["arrives_at"] == [-1653.1, 218.4, -31.2] and "class" not in door and "category" not in door
    assert lever["switch_position"] == 0 and lever["switch_highest"] == 1 and lever["drives"]
    assert chest["chest_state"] == "unopened"
    assert trap["category"] == "hazards" and trap["parts"] == 2 and trap["active_parts"] == 1 and "class" not in trap
    for flag in (False, None):
        out = look_view({"things": [], "in_vault": flag, "vault": None})
        assert "in_vault" not in out and "vault" not in out
    # the probe's look inside Crasorak Kara: in_vault false, vault named: he is in it
    out = look_view({"things": [], "in_vault": False, "vault": "Crasorak Kara"})
    assert out["in_vault"] is True and out["vault"] == "Crasorak Kara"
    assert _look_row(BENCH) == BENCH


def test_planner_state_carries_the_vault_only_when_in_one():
    assert _trim_state(state(in_vault=True, vault="Vertentis Kara"))["vault"] == "Vertentis Kara"
    assert _trim_state(state(in_vault=True))["in_vault"] is True
    out = _trim_state(state(in_vault=False))
    assert "in_vault" not in out and "vault" not in out
    assert _trim_state(state(in_vault=False, vault="Crasorak Kara"))["vault"] == "Crasorak Kara"  # the box holds him


def test_director_compact_state_rows_say_their_vault_state():
    me = D._compact_state(state(in_vault=True, vault="Vertentis Kara"))
    assert me["in_vault"] is True and me["vault"] == "Vertentis Kara"
    rows = {r["id"]: r for r in me["usable_near"]}
    assert rows[DOOR["id"]] == {"id": DOOR["id"], "name": DOOR["name"], "prompt": "Enter", "distance": 4.2,
                                "leads_to": "outside", "locked": False}
    assert rows[LEVER["id"]]["switch_position"] == 0 and rows[LEVER["id"]]["drives"] == LEVER["drives"]
    assert rows[CHEST["id"]]["chest_state"] == "unopened"
    assert rows[BENCH["id"]] == {"id": BENCH["id"], "name": "Workbench", "prompt": "Craft", "distance": 6.0}
    assert "in_vault" not in D._compact_state(state(in_vault=False))

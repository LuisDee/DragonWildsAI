"""tools/quest_clone.py: the FTUE chain cleared from a save, written in the game's own layout (offline)."""
import json

from tools import quest_clone as qc

FS1, GS, RM, FS2, DS, FISH = "fs1", "gs", "rm", "fs2", "ds", "fish"
IDS = {FS1: "Quest_FTUE_GS", GS: "Quest_FTUE_RtftJ", RM: "Quest_FTUE_RM", FS2: "Quest_FTUE_FS"}


def save() -> dict:
    q = lambda i, st, obj, bools=(): {"QuestId": i, "QuestState": st, "QuestObjective": obj, "QuestInts": [],
                                       "QuestBools": [{"QuestVariableName": b, "QuestVariableValue": True} for b in bools]}
    return {"Version": 86, "meta_data": {"char_guid": "E71C", "worlds_playtime": {"W": 1}, "char_name": "ClaudeDev", "char_type": 0},
            "Stats": {"WellRestedDecayRate": 0.55555558204650879},
            "GameProgress": {"Progress": {"SpellsUnlocked": ["a", "b"]}, "QuestProgress": {
                "QuestTrackedMain": FS2,
                "Quests": [q(FS1, 2, "Objective3", ("HasTriggeredEntryVolume", "SpokeToWOM")), q(DS, 0, "None", ("WOMTempleHidden",)),
                           q(RM, 2, "Objective3"), q(FISH, 1, "SpeakToWom", ("StartedFishFtue",)), q(GS, 2, "Objective4"), q(FS2, 1, "Objective1")],
                "QuestLocations": [{"QuestLocationId": n, "QuestLocationsState": s} for n, s in
                                   (("WOM_Objective_FTUE_GS", False), ("WOM_NPC_Fish_Target", True), ("Zanik_Objective_FTUE_RM", False),
                                    ("Zanik_Objective_NPC_RM", False), ("Doric_NPC_FTUE_RtftJ", False), ("WOM_Objective_FTUE_FS", True))]}},
            "Backup": 3439900877}


def test_the_chain_is_cleared_first_steps_reset_and_the_rest_kept_byte_for_byte():
    raw = "{\r\n" + qc.ue_json(save(), 0)[3:]  # the game's layout, as ue_json writes it
    raw = raw.replace("0.5555555820465088", "0.55555558204650879")  # a float as the game prints it: must survive as is
    src = json.loads(raw)
    names = {"WOM_Objective_FTUE_GS", "Zanik_Objective_FTUE_RM", "Doric_NPC_FTUE_RtftJ", "WOM_Objective_FTUE_FS"}
    out = qc.clear(src, IDS, names, {"_GS", "_RM", "_RtftJ", "_FS"}, "ClaudeQ1")
    qp = out["GameProgress"]["QuestProgress"]
    assert [q["QuestId"] for q in qp["Quests"]] == [FS1, DS, FISH]
    assert qp["Quests"][0] == {"QuestId": FS1, **qc.FIRST_RESET}
    assert qp["Quests"][1]["QuestBools"] == [] and qp["Quests"][2]["QuestBools"][0]["QuestVariableName"] == "StartedFishFtue"
    assert [l["QuestLocationId"] for l in qp["QuestLocations"]] == ["WOM_Objective_FTUE_GS", "Doric_Objective_FTUE_GS", "WOM_NPC_Fish_Target"]
    assert qp["QuestTrackedMain"] == FS1
    assert out["meta_data"]["char_name"] == "ClaudeQ1" and len(out["meta_data"]["char_guid"]) == 32
    assert src["meta_data"]["char_name"] == "ClaudeDev"  # the source is untouched
    text = qc.render(raw, out)
    assert json.loads(text) == out
    head, tail = raw[:raw.index('"QuestProgress"')], raw[raw.index('"Backup"'):]
    assert "0.55555558204650879" in text and text.endswith(tail)
    assert text[:text.index('"QuestProgress"')].replace(out["meta_data"]["char_guid"], "E71C").replace("ClaudeQ1", "ClaudeDev") == head


def test_the_cleared_quests_deliverables_leave_the_bag_and_every_other_slot_keeps_its_bytes():
    s = save()
    club, roast, axe = "IJILMByu-kCq_0feZkzKBw", "0aufkk55nHU1TlSAXZ0o3g", "0NWm0hwPokOAgp0ux3ambA"
    s["GameProgress"]["Inventory"] = {
        "0": {"GUID": "a", "ItemData": club, "AddedToInventoryTimestamp": 6.3929162140686e+17},
        "1": {"GUID": "b", "ItemData": axe, "Durability": 760, "AddedToInventoryTimestamp": 6.3928642787233e+17},
        "5": {"GUID": "c", "ItemData": roast, "Count": 4, "AddedToInventoryTimestamp": 6.3929156627561e+17},
        "MaxSlotIndex": 72}
    # a loadout slot holding a bag slot by index (live: his Air Runes, {"PlayerInventoryItemIndex": 40}) goes with it
    s["GameProgress"]["Loadout"] = {"2": {"GUID": "d", "ItemData": "x", "Durability": 0},
                                    "6": {"PlayerInventoryItemIndex": 5}, "7": {"PlayerInventoryItemIndex": 1},
                                    "MaxSlotIndex": 8}
    raw = "{\r\n" + qc.ue_json(s, 0)[3:]
    raw = raw.replace("6.3928642787233e+17", "6.3928642787232998e+17")  # as the game printed it (ClaudeDev.json)
    assert "6.3928642787232998e+17" in raw
    out = qc.clear(json.loads(raw), IDS, set(), set(), "ClaudeQ6", {club: "ITEM_Club_Stone", roast: "ITEM_Consumable_Meat_Rat_Roast"})
    assert list(out["GameProgress"]["Inventory"]) == ["1", "MaxSlotIndex"]  # the axe is a tool: it stays
    assert list(out["GameProgress"]["Loadout"]) == ["2", "7", "MaxSlotIndex"]  # nothing left pointing at no item
    text = qc.render(raw, out)
    assert json.loads(text) == out and "6.3928642787232998e+17" in text
    assert '"1":\r\n\t\t\t{' in text and '"0":' not in text.split('"Inventory"')[1].split('"MaxSlotIndex"')[0]


def test_the_deliverables_of_the_chain_have_persistence_ids():
    d = json.loads(qc.DELIVERABLES.read_text(encoding="utf-8"))
    assert all(i in d["persistence_ids"] for items in d["quests"].values() for i in items)

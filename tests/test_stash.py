"""brain/stash.py: containers he saw inside, from take/store/inspect results, per world."""
from brain import gear_plan, situation
from brain.stash import Stash

CRATE = "BP_BaseBuilding_Crate_C_2147461755"


def _seen(tmp_path):
    s = Stash(tmp_path / "containers.json", clock=lambda: 100.0)
    st = {"structures": [{"id": CRATE, "name": "Crate", "mine": True, "position": [103.8, 1857.8, -30.6]}]}
    s.observe_state(st)
    res = {"ok": True, "data": {"container": CRATE, "container_name": "Crate", "item": "ITEM_Resources_Wood_Ash",
                                "count": 2, "contents": ["2 Ash Logs", "1 Bronze Shield"]}}
    assert s.observe_result("store", {"item": "Ash Logs"}, res)
    return s


def test_store_result_records_contents_by_item_id_and_where(tmp_path):
    s = _seen(tmp_path)
    labels = s.labels()
    assert list(labels) == ["your Crate at (104,1858)"]
    assert set(labels["your Crate at (104,1858)"]) == {"ITEM_Resources_Wood_Ash", "ITEM_Shield_Bronze"}


def test_persisted_per_file_and_reloaded(tmp_path):
    _seen(tmp_path)
    again = Stash(tmp_path / "containers.json")
    assert "your Crate at (104,1858)" in again.labels()


def test_emptied_container_drops_out_and_graves_and_other_tools_are_ignored(tmp_path):
    s = _seen(tmp_path)
    assert s.observe_result("take", {}, {"ok": True, "data": {"container": CRATE, "contents": []}})
    assert s.labels() == {}
    assert not s.observe_result("take", {}, {"ok": True, "data": {"container": "BP_PlayerGravestone_C_1", "contents": ["1 Bronze Sword"]}})
    assert not s.observe_result("go_to", {}, {"ok": True, "data": {"container": CRATE, "contents": ["1 Bronze Sword"]}})


def test_inspect_structured_contents_and_a_failed_take_listing_count(tmp_path):
    s = Stash(tmp_path / "c.json")
    s.observe_result("inspect", {"target": "X_1"}, {"ok": True, "data": {"id": "BP_Chest_C_1", "name": "Chest", "position": [1, 2, 3],
                     "contents": [{"name": "Leather", "item": "ITEM_Resources_Leather", "count": 8}]}})
    s.observe_result("take", {}, {"ok": False, "reason": "not_in_container",
                     "data": {"container": "BP_BaseBuilding_Crate_C_9", "contents": ["3 Animal Bone"]}})
    labels = s.labels()
    assert labels["the Chest at (1,2)"] == ["ITEM_Resources_Leather"]
    assert labels["the Crate"] == ["ITEM_Resources_AnimalBone"]


def test_gear_line_counts_the_crate_shield(tmp_path):
    s = _seen(tmp_path)
    st = {"gear": {"Body": "ITEM_Armour_T1_Body_Adventurers", "Legs": "ITEM_Armour_T1_Legs_Adventurers"},
          "inventory": {}, "recipes_unlocked": [], "nearby_entities": [{"name": "Cow", "power_level": 2, "alive": True}]}
    s.observe_state(st)
    line = situation.gear_line(st)
    assert line and "Bronze Shield" in line and "your Crate at (104,1858)" in line
    assert gear_plan.plan(st, stash=st["containers_remembered"])["slots"]["left_hand"]["best"][0]["where"] == ["your Crate at (104,1858)"]

"""Per-world map / resource memory (BUGS L21) and remembered graves (BUGS L22).

Fixtures are real get_state answers: state_base_water_seen.json (20:31 UTC at the base, two Water Volumes
'Collect Water' in sight) and state_2140_thirsty.json (21:33 UTC at the start area, hydration 13.5, no water
within 40 m). Live, he died of thirst at 21:34 and 21:44 repeating "no water within 40 m".
"""
import json
from pathlib import Path

from brain import map_memory as mm
from brain import needs
from brain.item_stats import rank_graves
from brain.situation import summary

FIX = Path(__file__).parent / "fixtures"


def fx(name):
    return json.loads((FIX / name).read_text(encoding="utf-8"))


class Clock:
    def __init__(self, t=1792955476.0):
        self.t = t

    def __call__(self):
        return self.t


def memory(tmp_path, clock=None):
    clock = clock or Clock()
    m = mm.MapMemory(tmp_path / "w" / "map_memory.json", clock=clock, debounce_s=0)
    m.observe(fx("state_base_water_seen.json"))
    return m, clock


def test_census_feeds_sightings_with_game_names_prompts_and_positions(tmp_path):
    m, _ = memory(tmp_path)
    water = m.query(where=lambda r: "Water" in str(r.get("class")))
    assert len(water) >= 2 and water[0]["prompt"] == "Collect Water" and isinstance(water[0]["position"], list)
    assert all(r["count_seen"] == 1 for r in water)
    m.observe(fx("state_base_water_seen.json"))
    assert m.query(where=lambda r: "Water" in str(r.get("class")))[0]["count_seen"] == 2  # same thing, seen again


def test_drink_sources_are_found_from_game_data_not_names_in_code():
    tests = mm.need_matchers(needs.catalog())
    assert tests["drink"]({"kind": "interactable", "prompt": "Collect Water"})  # 'water' names drink items (Dirty Water ...)
    assert not tests["drink"]({"kind": "interactable", "prompt": "Open"})
    assert tests["food"]({"kind": "resource", "item": "ITEM_Consumable_Fruit_Redberry"})


def test_thirsty_at_the_start_area_the_digest_names_the_remembered_water_beyond_sight(tmp_path):
    m, clock = memory(tmp_path)
    clock.t += 62 * 60  # 21:33
    st = fx("state_2140_thirsty.json")
    m.observe(st)
    mm.annotate(st, m)
    rem = st["remembered"]["drink"][0]
    assert rem["prompt"] == "Collect Water" and rem["distance"] > 200 and rem["age_min"] == 62 and rem["direction"]
    line = next(l for l in needs.lines(st) if l.startswith("Need drink"))
    assert "remembered: Water Volume" in line and "('Collect Water') seen 62 min ago" in line, line


def test_replay_2130_to_2145_every_thirsty_turn_carries_the_remembered_water(tmp_path):
    m, clock = memory(tmp_path)
    for minute, water_pct in ((59, 22.0), (61, 15.4), (62, 13.5), (63, 10.8), (70, 7.1), (72, 0.8)):
        clock.t = 1792955476.0 + minute * 60
        st = fx("state_2140_thirsty.json")
        st["hydration"] = water_pct
        m.observe(st)
        mm.annotate(st, m)
        line = next(l for l in needs.lines(st) if l.startswith("Need drink"))
        assert "remembered: Water Volume" in line and "('Collect Water')" in line, (minute, line)


def test_store_is_atomic_debounced_and_readable_by_the_director(tmp_path):
    clock = Clock()
    m = mm.MapMemory(tmp_path / "w" / "map_memory.json", clock=clock, debounce_s=30)
    m.observe(fx("state_base_water_seen.json"))
    assert not m.path.exists(), "debounced: not written on the first observe"
    clock.t += 31
    m.observe(fx("state_base_water_seen.json"))
    d = mm.load(m.path)
    assert d["schema"] == mm.SCHEMA and d["sightings"] and not list(m.path.parent.glob("*.tmp"))
    near = mm.query(d, near=[368.0, 1756.0, -43.0], limit=1, where=lambda r: r.get("prompt") == "Collect Water")
    assert near and near[0]["distance"] < 2
    m.note_negative("ITEM_Resources_Coal", [10, 10, 0], "nothing_in_range")
    m.flush()
    assert mm.load(m.path)["negative"][0]["why"] == "nothing_in_range"
    assert mm.MapMemory(m.path, clock=clock).sightings, "reloads from disk"


def test_graves_are_ranked_most_valuable_first_and_all_listed():
    gear = {"iso": "2026-10-25T21:25:56Z", "distance": 300, "go_to": "my_grave:1792963556", "lost_items": 6,
            "lost": ["Steel Logging Axe x1", "Iron Pickaxe x1", "Wooden Training Sword x1"],
            "lost_ids": [{"item": "ITEM_Logging_Axe_Steel", "count": 1}, {"item": "ITEM_Pickaxe_Iron", "count": 1},
                         {"item": "ITEM_Sword_Training", "count": 1}]}
    junk = {"iso": "2026-10-25T21:44:50Z", "distance": 5, "go_to": "my_grave:1792964690", "lost_items": 12,
            "lost": ["Ash Logs x12"], "lost_ids": [{"item": "ITEM_Resources_Wood_Ash", "count": 12}]}
    assert rank_graves([junk, gear])[0] is gear
    st = fx("state_2140_thirsty.json")
    st["graves_remembered"] = [junk, gear]
    digest = "\n".join(summary(st))
    assert digest.index("my_grave:1792963556") < digest.index("my_grave:1792964690")  # the gear grave first
    assert "Steel Logging Axe x1" in digest and "300 m away" in digest

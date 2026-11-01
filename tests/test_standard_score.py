"""tools/standard_score.py (markers, levels, T_h) and tools/recorder_io.py (attribution, presses, idle)."""
from tools import recorder_io as rio
from tools import standard_score as ss

T = 1793536800.0
LUIS = "luisdeburnaybast"


def line(dt, text, who=LUIS):
    return {"ts": T + dt, "player": who, "text": text}


def test_markers_rename_scrap_unclosed_and_notes():
    lines = [line(0, "start sticks"), line(5, "Tester says hi", who="Tester"), line(10, "done"),
             line(12, "start get food"), line(40, "done"), line(41, "the above was start hunt"),
             line(45, "start cook"), line(50, "actually scrap that kebbits dont drop meat"),
             line(55, "start sleep"), line(70, "start mine rock"), line(80, "done make rock"), line(90, "start kill cow")]
    wins, notes = ss.marker_windows(lines, "luisdeburnaybastos")
    got = [(w["task"], w["family"], w["closed"]) for w in wins]
    assert got == [("sticks", "pickup", "done"), ("hunt", "kill", "done"), ("cook", "cook", "scrapped"),
                   ("sleep", "sleep", "unclosed"), ("mine rock", "mine", "done"), ("kill cow", "kill", "open")]
    assert wins[1]["renamed_from"] == "get food" and wins[3]["t1"] == T + 70
    assert any(n["kind"] == "knowledge" and n["text"] == "kebbits dont drop meat" for n in notes)
    assert [ss.usable(w | {"work_s": 1}) for w in wins] == [True, True, False, False, True, False]


def test_families():
    cases = {"gather water": "collect_water", "boil water": "cook", "craft axe": "craft", "club": "craft",
             "crafting table and firepit": "build", "make base": "build", "return back to foundation": "travel",
             "astral projection": "spell", "mine rock": "mine", "gather rocks": "pickup", "pickuip cabbage": "pickup",
             "hunt chicken": "kill", "pile": "drop", "use bow": "kill", "made thread": "craft", "MAKE tannery": "build"}
    assert {k: ss.family(k) for k in cases} == cases


def test_level_h_a_and_reasons():
    assert ss.level(True, 10, 10, 0, 0, 1, 0, True, 0) == ("H", [])
    lv, why = ss.level(True, 20, 10, 1, 0, 1, 0, True, 0)
    assert lv == "A" and "2.0x T_h" in why and "1 corrections" in why
    assert ss.level(True, 30, 10, 0, 0, 1, 0, True, 0)[0] is None            # 3x T_h (> 2.5x and > T_h + 10 s)
    assert ss.level(True, 13, 4, 0, 0, 1, 0, True, 0)[0] == "A"              # a 4 s task gets T_h + 10 s
    assert ss.level(True, 10, 10, 2, 0, 1, 0, True, 0)[0] is None            # 2 corrections
    assert ss.level(True, 10, 10, 0, 0, 1, 0, True, 1)[0] is None            # a false claim
    assert ss.level(True, 10, 10, 0, 0, 1, 1, True, 0)[0] is None            # a death
    assert ss.level(True, 99, 10, 0, 0, 1, 0, True, 0, timed=False)[0] == "H"
    assert ss.level(False, 1, 10, 0, 0, 1, 0, True, 0) == (None, ["not done"])


def test_t_human_uses_baselines_then_provisional():
    base = {"families": {"build": {"unit_s": 3.0}}}
    th, parts, prov = ss.t_human([["travel", 67], ["build", 2], ["eat_drink", 2]], base)
    assert th == round(ss.REACT_S + 10 + 6 + 2 * ss.PROVISIONAL["eat_drink"], 1) and prov
    assert ss.t_human([["build", 2]], base)[2] is False


def rows():
    """Two players; L presses three sticks (two 0.1 s apart), then a fumble; C stands still 6 s, then a water press."""
    out = [{"kind": "armed", "ts": T, "players": ["L", "C"]}]
    for i in range(60):
        t = T + i * 0.2
        out.append({"kind": "pos", "who": "L", "ts": t, "p": [100 + i * 0.1, 0, 0], "v": 0.5, "vz": 0, "yaw": 0, "hp": 100})
        out.append({"kind": "pos", "who": "C", "ts": t, "p": [200, 0, 0], "v": 0.0, "vz": 0, "yaw": 0, "hp": 100})
    comp = "BP_Components_InteractionManager"
    for dt, p in ((1.0, [101, 1, 0]), (1.1, [101, 2, 0]), (2.0, [102, 1, 0]), (4.0, [104, 2, 0])):
        out.append({"kind": "rpc", "rpc": "interact", "who": comp, "ts": T + dt, "target_p": p, "target_class": "BP_Stick"})
    for dt in (1.07, 1.3, 2.2):
        out.append({"kind": "inv", "who": "L", "ts": T + dt, "delta": {"ITEM_Wood_Ash": 1}})
    out.append({"kind": "rpc", "rpc": "interact", "who": comp, "ts": T + 7.0, "target_p": [230, 0, 0], "target_class": "BP_WaterVolume_C"})
    out.append({"kind": "inv", "who": "C", "ts": T + 7.1, "delta": {"ITEM_Water_Dirty": 2}})
    out.append({"kind": "rpc", "rpc": "drop", "who": "BP_Components_InventoryController", "ts": T + 9.0, "params": []})
    out.append({"kind": "inv", "who": "L", "ts": T + 9.2, "delta": {"ITEM_Stone": -1}})
    return out


def test_recorder_attribution_presses_idle():
    rec = rio.Recording(rows(), [])
    by = [(r["rpc"], r["player"], r["by"]) for r in rec.rpc]
    assert by == [("interact", "L", "near")] * 4 + [("interact", "C", "inv"), ("drop", "L", "inv")]
    ps = rec.presses("L", T, T + 6)
    assert [p.outcome for p in ps] == ["gain", "gain", "gain", "no_effect"]   # the quick second press keeps its own item
    assert rec.presses("C", T, T + 12)[0].outcome == "gain"
    still = rec.still_segments("C", T, T + 5)   # (to T + 6 it would be explained by the water press 1 s later)
    assert len(still) == 1 and not still[0]["explained"] and still[0]["s"] > 4
    assert rec.canon("Q") is None and rec.canon("Lxyz") == "L"            # a prefix either way
    m = ss.score_window(rec, "L", T, T + 6, "pickup")
    assert (m["presses"], m["misses"], m["units"], m["items_gained"]) == (4, 1, 3, 3)

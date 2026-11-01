"""tools/recorder_motion.py: rpc attribution, press outcomes, motion and standing runs over a synthetic recording."""
from tools import recorder_motion as rm

T = 1793536800.0
COMP = "BP_Components_InteractionManager"  # what `who` said before the recorder's class fix


def rows():
    out = []
    for i in range(100):  # 20 s at 5 Hz; C walks for 4 s, stands 8 s, walks; L stands far away throughout
        t = T + i * 0.2
        out.append({"kind": "pos", "who": "C", "ts": t, "p": [100 + (i if i < 20 or i >= 60 else 20) * 0.3, 0, 0],
                    "v": 0.0 if 20 <= i < 60 else 1.5, "hp": 100 - (5 if i >= 50 else 0)})
        out.append({"kind": "pos", "who": "L", "ts": t, "p": [300, 0, 0], "v": 0.0, "hp": 100})
    for dt in (5.0, 5.5, 9.0):  # two quick presses on one stick (one pick), then a press that does nothing
        out.append({"kind": "rpc", "rpc": "interact", "who": COMP, "ts": T + dt, "target_p": [106.5, 1, 0], "target_class": "BP_Stick"})
    out.append({"kind": "inv", "who": "C", "ts": T + 5.6, "delta": {"ITEM_Stick": 1}})
    out.append({"kind": "rpc", "rpc": "drop", "who": "BP_Components_InventoryController", "ts": T + 15.0, "params": []})
    out.append({"kind": "inv", "who": "L", "ts": T + 15.2, "delta": {"ITEM_Stone": -1}})
    out.append({"kind": "rpc", "rpc": "interact", "who": "L", "ts": T + 16.0, "target_p": [301, 0, 0], "target_class": "BP_Chest"})
    return out


def test_attribution_outcomes_motion_and_standing_runs():
    rec = rm.Recording(rows(), [])
    assert [(r["player"], r["who_src"]) for r in rec.rpcs] == [("C", "nearest_target")] * 3 + [("L", "inv_follow"), ("L", "recorded")]
    ps = rec.presses("C")
    assert [p.outcome for p in ps] == ["miss", "hit", "miss"]  # the pick is credited to the latest press before it
    assert ps[1].delta == {"ITEM_Stick": 1} and ps[1].delta_s == 0.1 and ps[0].dist_m < 1.5
    assert rec.presses("L")[0].outcome == "miss"
    mo = rec.motion("C", T, T + 20)
    assert abs(mo["moving_s"] - 12.0) < 0.3 and abs(mo["standing_s"] - 8.0) < 0.3 and mo["absent_s"] < 0.3
    (run,) = rec.idle_segments("C", T, T + 20)
    assert abs(run.start - (T + 4)) < 0.01 and abs(run.s - 8.0) < 0.3 and run.presses == 3 and (run.hp0, run.hp1) == (100, 95)
    assert rm.pick_player(rec, "c") == "C" and rm.pick_player(rec, "Claude") is None


def test_a_sampling_hole_splits_a_standing_run_and_counts_as_absent():
    rs = [r for r in rows() if not (r["kind"] == "pos" and r["who"] == "C" and T + 6 <= r["ts"] < T + 9)]
    rec = rm.Recording(rs, [])
    assert [round(x.s) for x in rec.idle_segments("C", T, T + 20, min_s=1.0)] == [2, 3]
    assert rec.motion("C", T, T + 20)["absent_s"] > 1.5

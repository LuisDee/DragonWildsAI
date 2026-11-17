"""tools/jump_stats.py: jump landings read from short real samples of logs/client/client.log and traversal.jsonl."""
from __future__ import annotations

from tools import jump_stats as J

# 2026-11-16 10:33Z: a jump from a standstill up 1.2 m on the windmill hill; he came down 1.6 m below the point
FELL_SHORT = """\
2026-11-16T10:33:01Z move: local plan #2 (wall_ahead) at (16385,174607,-866) toward (16399,174454,-801)
2026-11-16T10:33:01Z move: local path 2 pts [wj] traces=391 cache_hits=341 replans=1 stand=0.36s end=(16400,174500,-832) pts=164,1746,-9.5 164,1745,-8.3
2026-11-16T10:33:01Z move: sprint dropped src=local jump=true stuck=0 turn=-107 want=true air=true
2026-11-16T10:33:03Z move: landed 185 cm from the jump's point (allowed 130) and 166 cm off its height (allowed 65)
2026-11-16T10:33:03Z move: jump landing missed; re-planning from here
2026-11-16T10:33:03Z move: go_to d=1023cm src=nav lwp=2/nil trail=nil/0 spr=true spd=115 traces=1124
2026-11-16T10:33:04Z move: local plan #3 (wall_ahead) at (16354,174540,-905) toward (16399,174454,-801)
"""

# 2026-11-17 14:14Z (s31): a 50 cm hop judged with the 45 cm window; he stood 22 cm off the point's height
HOP_45 = """\
2026-11-17T14:14:40Z move: local plan #1 (hostile BP_AI_GiantRat_Character_C_2147464704) at (13666,172303,-736) toward (13807,172270,-681)
2026-11-17T14:14:41Z move: local path 2 pts [wj] traces=1059 cache_hits=1 replans=2 stand=0.69s end=(13800,172300,-769) pts=137,1723,-8.2 138,1723,-7.7
2026-11-17T14:14:43Z move: landed 50 cm from the jump's point (allowed 45) and 22 cm off its height (allowed 65)
2026-11-17T14:14:43Z move: jump landing missed; re-planning from here
2026-11-17T14:14:44Z move: stuck n=1 moved=9cm d=2080 src=nav me=(13766,172303,-689) aim=(13807,172270,-681) goal=(15610,171340,-350) lwp=2/nil trail=nil/0
"""

# 2026-11-17 14:15:33Z: a jump that landed (the body wrote its self_edge), then a walk on
LANDED = """\
2026-11-17T14:15:32Z move: local plan #3 (hostile BP_AI_GiantRat_Character_C_2147464427) at (14262,170641,-387) toward (14389,170609,-369)
2026-11-17T14:15:33Z move: local path 2 pts [wj] traces=1060 cache_hits=6 replans=1 stand=0.67s end=(14400,170600,-363) pts=143,1706,-4.8 144,1706,-3.6
2026-11-17T14:15:33Z move: local plan #4 (hostile BP_AI_GiantRat_Character_C_2147464427) at (14414,170602,-273) toward (15360,172160,-400)
2026-11-17T14:15:34Z move: local path 10 pts [wwwwwwwwww] traces=1068 cache_hits=5 replans=0 stand=0.75s end=(15300,171500,-410) pts=144,1706,-3.6 145,1707,-3.7 146,1708,-3.6 147,1709,-3.8 148,1710,-3.9 149,1711,-4.0 150,1712,-4.1 151,1713,-4.2 152,1714,-4.1 153,1715,-4.1
"""
LANDED_EDGE = {"type": "self_edge", "move": "jump", "from": [143.00, 1706.00, -4.81], "to": [144.00, 1706.00, -3.63],
               "heading_deg": 0.0, "dz_m": 1.17, "gap_m": 1.00, "ts": 1794924933.781, "iso": "2026-11-17T14:15:33Z"}

# 2026-11-17 13:59:50Z (s31): a path with two double jumps; the first landed 69 cm off height
TWO_DJUMPS = """\
2026-11-17T13:59:49Z move: local plan #1 (wall_ahead) at (15471,174831,-1133) toward (15873,174328,-567)
2026-11-17T13:59:50Z move: local path 6 pts [wdwwdw] traces=2083 cache_hits=3 replans=0 stand=1.34s end=(15800,174300,-643) pts=155,1748,-12.2 156,1747,-10.1 156,1746,-9.8 157,1745,-9.4 158,1744,-6.5 158,1743,-6.4
2026-11-17T13:59:51Z move: landed 121 cm from the jump's point (allowed 130) and 69 cm off its height (allowed 65)
2026-11-17T13:59:51Z move: jump landing missed; re-planning from here
"""


def parse(text, since=J.DEFAULT_SINCE):
    return J.parse_lines(text.splitlines(True), since)


def test_a_path_with_its_jump_and_the_miss_after_it():
    ps = parse(FELL_SHORT)
    assert len(ps) == 1
    p = ps[0]
    assert p.acts == "wj" and p.pts == [(164.0, 1746.0, -9.5), (164.0, 1745.0, -8.3)] and p.stand_s == 0.36
    assert p.at == (16385, 174607, -866) and p.why == "wall_ahead"
    (e,) = p.jump_ups()
    assert e.kind == "jump" and e.rise_cm == 120.0 and e.run_cm == 100.0 and not e.slope_range
    assert p.standing_start(e)
    assert p.miss["landed"] == (185, 130, 166, 65) and p.miss["third"] is False
    assert p.miss["after"] == (16354, 174540, -905)   # the next plan's own position, within 3 s


def test_the_miss_is_signed_from_the_position_after_it():
    (r,) = J.outcomes(parse(FELL_SHORT))
    assert r["outcome"] == "missed"
    assert r["signed_dz_cm"] == -905 - J.HALF_H_CM + 830          # feet -993 against the point's -830: 163 below
    assert r["after_vs_takeoff_dz_cm"] == -905 - J.HALF_H_CM + 950  # 43 cm below where he took off
    assert J.classify_miss(r) == "fell short (back at the takeoff level)"
    assert all(J.strike_under(r, i) for i in range(4))             # a real fall is a strike under every rule


def test_a_hop_over_the_step_is_judged_with_the_45_cm_window_and_rule_a_lets_it_land():
    (r,) = J.outcomes(parse(HOP_45))
    assert r["rise_cm"] == 50.0 and r["allowed_cm"] == 45 and r["off_cm"] == 50
    assert r["after_pos"] == (137.66, 1723.03, round((-689 - J.HALF_H_CM) / 100, 2))   # from the stuck line
    assert J.strike_under(r, 0) and not J.strike_under(r, 1)


def test_a_landing_the_body_confirmed_is_landed_not_missed():
    ps = parse(LANDED)
    J.attach_self_edges(ps, [LANDED_EDGE])
    rows = J.outcomes(ps)
    assert [(r["kind"], r["outcome"]) for r in rows] == [("jump", "landed")]
    assert not ps[0].miss and ps[1].jump_ups() == []


def test_the_miss_goes_on_the_first_jump_without_a_landing_and_djump_is_told_from_drop():
    (p,) = parse(TWO_DJUMPS)
    kinds = [(e.k, e.kind, e.rise_cm) for e in p.edges() if e.letter != "w"]
    assert kinds == [(1, "djump", 210.0), (4, "djump", 290.0)]
    rows = J.outcomes([p])
    assert [r["outcome"] for r in rows] == ["missed", "not_reached"]
    # with the first landing confirmed, the miss moves to the second
    p.landed_keys.add(J.key(p.pts[0], p.pts[1]))
    assert [r["outcome"] for r in J.outcomes([p])] == ["landed", "missed"]
    # 121 cm away and 69 cm off: no position sample, so rule B keeps it a strike only by the unsigned height
    assert J.classify_miss(J.outcomes([p])[1]) == "off height, within a walkable slope of the point"


def test_the_legacy_count_reads_d_that_rises_as_a_jump():
    ps = parse(FELL_SHORT + HOP_45 + TWO_DJUMPS)
    assert J.legacy_counts(ps) == (3, 3)


def test_lines_outside_the_window_and_other_lines_are_ignored():
    assert parse(FELL_SHORT, since="2026-11-17T00:00:00Z") == []
    assert parse("2026-11-16T10:33:01Z ran probe.lua ok=true\nnot a log line\n") == []


def test_places_cluster_within_5_m_and_sort_by_misses():
    rows = [{"b": (138.0, 1723.0, -7.7), "a": (137.0, 1723.0, -8.2), "outcome": "missed", "rise_cm": 50.0, "day": "2026-11-17"},
            {"b": (139.0, 1722.0, -7.0), "a": (138.0, 1723.0, -8.0), "outcome": "landed", "rise_cm": 100.0, "day": "2026-11-16"},
            {"b": (164.0, 1745.0, -8.3), "a": (164.0, 1746.0, -9.5), "outcome": "landed", "rise_cm": 120.0, "day": "2026-11-16"}]
    out = J.places(rows, top=5)
    assert [(c["planned"], c["missed"], c["landed"]) for c in out] == [(2, 1, 1), (1, 0, 1)]


def test_the_verdict_line_parses():
    line = ("move: jump verdict=missed why=far act=jump rise=120 run=141 k=3/6 from=(15800,174400,-950) "
            "to=(15900,174500,-830) takeoff=(15790,174380,-951) takeoff_off=22 v0=(310,290,0) v0h=424 toward=0.97 "
            "air=0.74 apex=+18 nearest=61@-40 at=(15700,174300,-993) feet_dz=-163 from_takeoff_dz=-43 off=185 "
            "floor=-994 floor_nz=0.91")
    d = J.parse_verdict(line)
    assert d["verdict"] == "missed" and d["why"] == "far" and d["rise"] == 120.0 and d["k"] == "3/6"
    assert d["takeoff"] == (15790.0, 174380.0, -951.0) and d["apex"] == 18.0 and d["nearest"] == "61@-40"
    assert d["feet_dz"] == -163.0 and d["floor_nz"] == 0.91
    assert J.parse_verdict("move: landed 185 cm from the jump's point (allowed 130)") is None
    rows = J.verdict_rows(["2026-11-18T10:00:00Z " + line + "\n", "2026-11-18T10:00:01Z move: arrived\n"])
    assert len(rows) == 1 and rows[0]["iso"] == "2026-11-18T10:00:00Z"


def test_attacks_scan_counts_path_blocked_after_a_landing(tmp_path):
    f = tmp_path / "brain-live-x.jsonl"
    f.write_text(
        '{"ts": 1794924002.845, "kind": "tool_result", "task_id": "51061646", "tool": "attack", "result": {"ok": false, '
        '"reason": "path_blocked", "data": {"move": {"lp_fail": "jump landing missed"}}}}\n'
        '{"ts": 1794924024.775, "kind": "tool_result", "task_id": "ba644bea", "tool": "attack", "result": {"ok": true, '
        '"reason": null, "data": {}}}\n'
        '{"ts": 1794924042.899, "kind": "tool_result", "tool": "gather", "result": {"ok": true}}\n', encoding="utf-8")
    r = J.scan_attacks([str(f)], 0)
    assert r["attacks"] == 2 and len(r["path_blocked"]) == 1 and r["after_missed_landing"] == ["2026-11-17T14:00:02Z"]

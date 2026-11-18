"""travel_ladder's jump course (docs/research/2026-11-17-jump-course.md): the legs, what counts as reached, the dev-only
and no-walk guards, one leg driven against fakes, and the jump_stats summary over the legs' time windows (offline)."""
from __future__ import annotations

import pytest

import tools.travel_ladder as T
from tools import jump_stats as J

COURSE = "jump_hill_rats,jump_hill_ledge3m,jump_hill_mid,jump_hill_east,jump_hill_top,jump_doric,jump_windmill_djump,jump_ford"
# the real-play legs (study jump_real_1118): the two causes the legs above never met
REAL = "jump_pond_bank,jump_pond_top,jump_rock_cell,jump_rock_step"
# cause (a) with its real approach (the pond legs above reproduced neither): starts are the real preceding plan or go_to
RUN = "jump_pond_bank_run,jump_pond_top_run,jump_pond_top_east"

# docs/research/2026-11-17-jump-landings.md, "The course (no model)": id -> (start, goal), capsule centre, m
STUDY = {
    "jump_hill_rats": ([134.94, 1718.0, -7.82], [140.0, 1721.0, -3.02]),
    "jump_hill_ledge3m": ([154.52, 1747.16, -10.91], [158.0, 1739.0, -5.32]),
    "jump_hill_mid": ([156.64, 1744.61, -8.52], [159.0, 1737.0, -3.22]),
    "jump_hill_east": ([154.38, 1748.35, -11.36], [164.0, 1745.0, -7.42]),
    "jump_hill_top": ([143.97, 1703.38, -4.87], [144.0, 1706.0, -2.72]),
    "jump_doric": ([106.46, 1849.46, -31.36], [109.02, 1846.57, -29.57]),
    # docs/research/2026-11-17-double-jumps.md section 5: the 3 m double jump after a walk, onto jump_hill_ledge3m's top
    "jump_windmill_djump": ([156.0, 1746.0, -8.82], [158.0, 1739.0, -5.32]),
    # the real-play jump study of 2026-11-18: the ford east of home, hops over one-cell bumps in water
    "jump_ford": ([122.5, 1888.5, -30.6], [129.0, 1895.0, -31.9]),
    # 2026-11-18 real play, from the client log's plan lines: (a) hops under the step slack at the pond bank by home
    "jump_pond_bank": ([162.79, 1914.44, -30.88], [157.0, 1911.0, -30.82]),  # 10:48:54Z plan #2, [wwwjwww]
    "jump_pond_top": ([159.21, 1911.83, -30.74], [157.0, 1915.0, -30.52]),   # 13:50:07Z plan #3, [wwwj]
    # (b) one-cell rocks climbed and dropped off
    "jump_rock_cell": ([163.20, 1913.95, -30.81], [157.0, 1912.0, -30.92]),  # 17 Nov 21:30:43Z plan #1, [wddwwww]
    "jump_rock_step": ([150.67, 1920.94, -31.85], [153.0, 1920.0, -30.12]),  # 13:35:11Z plan #5, [wdw]
    # home to the learned shore point, collect_water's go_to (10:48:51Z start, shore point logged 10:48:50Z), wading
    "jump_pond_bank_run": ([173.42, 1914.98, -30.28], [145.23, 1907.70, -31.85]),
    # 13:50:01Z plan #2 at, the chase target of its stuck line (follow d=58 m)
    "jump_pond_top_run": ([161.43, 1903.20, -30.49], [138.63, 1964.34, -29.71]),
    # 11:16:48Z plan #6 (water_ahead) at, the go_to's own point (15623,191688,-3254) + 0.88
    "jump_pond_top_east": ([168.21, 1907.82, -30.42], [156.23, 1916.88, -31.66]),
}


def test_the_legs_are_the_studys_and_only_only_picks_them():
    legs = T.pick(set(COURSE.split(",")))
    assert [j["id"] for j in legs] == COURSE.split(",")
    assert [j["id"] for j in T.pick(set(REAL.split(",")))] == REAL.split(",")
    assert [j["id"] for j in T.pick(set(RUN.split(",")))] == RUN.split(",")
    assert [j["id"] for j in T.JUMP_COURSE] == COURSE.split(",") + REAL.split(",") + RUN.split(",")
    legs = T.JUMP_COURSE
    for j in legs:
        assert (j["start"], j["goal"]) == STUDY[j["id"]] and j["course"] == "jump" and j["human_m"]
    # the old selections are unchanged: no flag = the journeys, --obstacles = the obstacle legs, neither has a jump leg
    assert T.pick(set()) == T.JOURNEYS and T.pick(set(), obstacles=True) == T.OBSTACLES and T.pick(set(), follow=True) == []
    assert not T.JUMP_IDS & {j["id"] for j in T.JOURNEYS + T.OBSTACLES}
    assert T.pick({"ramp_up", "jump_doric"})[0]["id"] == "ramp_up"


def test_reached_means_on_top_not_at_the_foot():
    for j in T.JUMP_COURSE:
        s, g = j["start"], j["goal"]
        assert T.arrived(g, g, j["tol_m"], j["tol_dz"])
        assert not T.arrived(s, g, j["tol_m"], j["tol_dz"]), j["id"]  # the start never counts
        if j.get("past"):  # a hump or rock crossed: the goal is past it at about the start's level or below, no top
            assert g[2] - s[2] < 1.0 and T.d2(s, g) > 5, j["id"]
            continue
        # beside the goal, at the low side's height (the start, or the dip below the top): fell back
        foot = [g[0] + 0.5, g[1], j.get("foot", s)[2]]
        assert not T.arrived(foot, g, j["tol_m"], j["tol_dz"]), j["id"]
        assert 0.5 <= j["tol_dz"] <= T.ARRIVE_DZ and j["tol_m"] == T.JUMP_TOL_M
    # the pond top: the start's shelf is 0.22 m under the top, so the dip (0.6 m under) is the foot, not the start
    top = T.pick({"jump_pond_top"})[0]
    assert top["foot"] == [157.0, 1914.0, -31.12] and top["tol_dz"] == 0.5 and top["go_tol"] == 0.5
    assert not T.arrived(top["start"], top["goal"], top["tol_m"], top["tol_dz"])
    # the rock step's goal is past a 2.3 m top 2.5 m away: the body's 1.5 m circle would stop at the rock's foot
    step = T.pick({"jump_rock_step"})[0]
    assert step["go_tol"] == 0.5 and not T.arrived(step["start"], step["goal"], step["tol_m"], step["tol_dz"])
    # the run legs start far enough back that he reaches the edge running, and the goal is over 10 m from the plan
    # point the real one was made at (move plans for water ahead only then; the 3.9 m pond-top go_to walked straight)
    for leg, plan_at in (("jump_pond_bank_run", [162.79, 1914.44]), ("jump_pond_top_run", [159.21, 1911.83]),
                         ("jump_pond_top_east", [159.36, 1912.71])):
        j = T.pick({leg})[0]
        assert T.d2(j["start"], plan_at) > 7 and T.d2(j["goal"], plan_at) > 4 and j["past"], leg
    assert T.d2(T.P["jpu_b"], T.P["jpt_a"]) > 10 and T.d2(T.P["jpe_a"], T.P["jpe_b"]) > 10
    # only collect_water's walk wades
    assert [j["id"] for j in T.JUMP_COURSE if j.get("wade")] == ["jump_pond_bank_run"]
    # the old legs keep the ladder's 3 m / 1.8 m
    assert T.JOURNEYS[0]["tol_m"] == T.ARRIVE_M and T.JOURNEYS[0]["tol_dz"] == T.ARRIVE_DZ


class FakeClient:
    def __init__(self, at):
        self.at, self.sent, self.args = list(at), [], {}

    def request(self, kind, args, timeout=None):
        self.sent.append(kind)
        self.args[kind] = dict(args)
        if kind == "me":
            return {"ok": True, "data": {"position": list(self.at)}}
        if kind == "go_to":
            self.at = list(args["target"])
            return {"ok": True, "data": {}}
        if kind == "arbiter_status":
            return {"ok": True, "data": {"owner": {}}}
        return {"ok": True, "data": {}}


class FakeDev:
    def __init__(self, client, players=False, dev_world=True):
        self.c, self.players, self.dev_world, self.setups = client, players, dev_world, []

    def guard(self):
        if not self.dev_world:
            raise RuntimeError("client is on 1.2.3.4:7777, not the local dev server")

    def brain_running(self):
        return False

    def setup(self, verb, purpose="", **a):
        self.setups.append((verb, a))
        if verb == "teleport":
            if self.players:
                raise RuntimeError("fixture refused: other_players_connected")
            self.c.at = list(a["at"])
        return {"ok": True}


@pytest.fixture
def fakes(monkeypatch, tmp_path):
    monkeypatch.setattr(T.time, "sleep", lambda s: None)
    monkeypatch.setattr(T, "TRIPS", tmp_path / "trips.jsonl")
    c = FakeClient([0.0, 0.0, 0.0])
    monkeypatch.setattr(T, "client", lambda: c)
    return c


@pytest.mark.parametrize("leg", ["jump_doric", "jump_pond_bank", "jump_pond_top", "jump_rock_cell", "jump_rock_step",
                                 "jump_pond_bank_run", "jump_pond_top_run", "jump_pond_top_east"])
def test_a_jump_leg_runs_against_fakes(fakes, leg):
    j = T.pick({leg})[0]
    dev = FakeDev(fakes)
    row = T.run_journey(dev, j)
    assert row["ok"] and row["start"] == j["start"] and row["end"] == j["goal"]
    assert dev.setups[0] == ("teleport", {"at": j["start"]}) and "go_to" in fakes.sent
    # the go_to as the brain or collect_water sent it: wade only on the shore walk, tolerance only where set
    sent = fakes.args["go_to"]
    assert sent.get("wade") is (True if leg == "jump_pond_bank_run" else None), sent
    assert sent.get("tolerance") == j.get("go_tol"), sent


def test_a_jump_leg_refuses_a_world_that_is_not_dev(fakes):
    dev = FakeDev(fakes, dev_world=False)
    with pytest.raises(RuntimeError, match="not the local dev server"):
        T.run_journey(dev, T.pick({"jump_hill_rats"})[0])
    assert dev.setups == [] and fakes.sent == []  # nothing reached the body
    with pytest.raises(RuntimeError, match="not the local dev server"):
        T.run_journey(dev, T.pick({"jump_pond_bank"})[0])
    assert dev.setups == [] and fakes.sent == []


def test_a_jump_leg_never_walks_past_another_player(fakes):
    dev = FakeDev(fakes, players=True)
    with pytest.raises(RuntimeError, match="another player is on the dev world"):
        T.run_journey(dev, T.pick({"jump_hill_top"})[0])
    with pytest.raises(RuntimeError, match="another player is on the dev world"):
        T.run_journey(dev, T.pick({"jump_rock_cell"})[0])
    assert "go_to" not in fakes.sent
    # the other legs keep the walk to the start
    p = T.place(dev, fakes, T.P["doric"])
    assert fakes.sent.count("go_to") == 1 and p == T.P["doric"]


# A leg 2026-11-18 10:00:00Z + 6 s: a jump up at the rats that fell back (a strike and a real fall), the re-plan's
# jump that landed (its self_edge), and the new verdict line. A miss at 10:00:30 is outside every leg.
LOG = """\
2026-11-18T10:00:01Z move: local plan #1 (wall_ahead) at (13700,172000,-782) toward (13800,172100,-592)
2026-11-18T10:00:01Z move: local path 2 pts [wj] traces=10 cache_hits=0 replans=0 stand=0.40s end=(13800,172100,-592) pts=137,1720,-8.7 138,1721,-6.8
2026-11-18T10:00:03Z move: landed 185 cm from the jump's point (allowed 130) and 166 cm off its height (allowed 65)
2026-11-18T10:00:03Z move: jump verdict=missed why=far_and_off_height act=jump rise=190 run=141 feet_dz=-188 off=185
2026-11-18T10:00:03Z move: jump landing missed; re-planning from here
2026-11-18T10:00:04Z move: local plan #2 (wall_ahead) at (13700,172000,-780) toward (13800,172100,-592)
2026-11-18T10:00:04Z move: local path 2 pts [wj] traces=10 cache_hits=0 replans=0 stand=0.40s end=(13800,172100,-592) pts=136,1720,-8.6 138,1721,-6.8
2026-11-18T10:00:06Z move: jump verdict=landed why=within act=jump rise=180 run=224 feet_dz=-3 off=20
2026-11-18T10:00:06Z move: arrived
2026-11-18T10:00:30Z move: local plan #3 (wall_ahead) at (13700,172000,-782) toward (13800,172100,-592)
2026-11-18T10:00:30Z move: local path 2 pts [wj] traces=10 cache_hits=0 replans=0 stand=0.40s end=(13800,172100,-592) pts=137,1720,-8.7 138,1721,-6.8
2026-11-18T10:00:32Z move: jump landing missed; re-planning from here
"""
T0 = J.epoch("2026-11-18T10:00:00Z")
EDGE = {"type": "self_edge", "move": "jump", "from": [136.0, 1720.0, -8.6], "to": [138.0, 1721.0, -6.8], "ts": T0 + 6.2}


def test_the_summary_counts_only_the_legs_windows():
    legs = [{"journey": "jump_hill_rats", "ts": T0, "s": 6.0, "ok": True},
            {"journey": "jump_doric", "ts": T0 + 100, "s": 5.0, "ok": False}]
    s = T.jump_course_summary(legs, LOG.splitlines(True), [EDGE])
    assert (s["legs"], s["legs_with_jump"], s["legs_with_strike"], s["legs_with_fall"]) == (2, 1, 1, 1)
    assert (s["paths"], s["jump_paths"], s["strike_paths"], s["fall_paths"]) == (2, 2, 1, 1)
    assert s["verdicts"] == {"missed": 1, "landed": 1}
    assert s["by_leg"]["jump_hill_rats"] == {"legs": 1, "reached": 1, "jump_paths": 2, "strike_paths": 1, "fall_paths": 1,
                                             "verdicts": 2}
    assert s["by_leg"]["jump_doric"]["jump_paths"] == 0
    text = "\n".join(T.jump_course_lines(s, "this run"))
    assert "paths with a jump up 2" in text and "with a strike 1 of 2 (50 %)" in text and "1 missed" in text
    assert T.jump_course_summary([])["legs"] == 0


def test_label_rows_gathers_every_run_of_the_label(tmp_path):
    f = tmp_path / "ladder.jsonl"
    f.write_text("\n".join([
        '{"journey": "jump_doric", "label": "jumpcourse", "run": "a", "ts": 1, "s": 2, "ok": true}',
        '{"journey": "jump_doric", "label": "other", "run": "b", "ts": 1, "s": 2, "ok": true}',
        '{"journey": "ramp_up", "label": "jumpcourse", "run": "a", "ts": 1, "s": 2, "ok": true}',
        '{"summary": true, "label": "jumpcourse", "journey": "jump_doric"}', "not json"]), encoding="utf-8")
    rows = T.label_rows("jumpcourse", T.JUMP_IDS, f)
    assert [r["run"] for r in rows] == ["a"]
    assert T.label_rows("jumpcourse", T.JUMP_IDS, tmp_path / "missing.jsonl") == []

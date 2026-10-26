"""Arrival is judged on the ground plane (live 22:19:34, episode 221904b): the body arrived 0.77 m from a
Water Volume's surface point that sits 3.1 m below the walkable ground. The 3D check said "still 3.2m from
target", a false failure the model retried 4 x, and the failure template read the metres out in chat
("Sorry, I couldn't walk somewhere: still 3.3m from target.", a stat_narration anomaly)."""
from __future__ import annotations

import copy

from brain.executor import ARRIVE_VERTICAL_M, VERIFIERS
from brain.interface import ok
from brain.state_store import Task

from test_event_hygiene import STATES, Replay

LIVE = {"position": [46.44, 1790.72, -31.82], "target_position": [46.77, 1791.41, -34.95], "arrive_tolerance": 3.0}


def _check(pos, target, tol=3.0):
    return VERIFIERS["go_to"]({"target": "x"}, {}, {"position": pos}, {"target_position": target, "arrive_tolerance": tol})


def test_the_live_arrival_above_a_water_point_passes():
    assert _check(LIVE["position"], LIVE["target_position"]) is None


def test_far_on_the_ground_still_fails_with_the_distance():
    assert _check([0, 0, 0], [10, 0, 0]) == "still 10.0m from target"


def test_a_target_on_another_level_fails_truthfully():
    why = _check([0, 0, 0], [0.5, 0, -(ARRIVE_VERTICAL_M + 6)])
    assert why == f"next to it but {ARRIVE_VERTICAL_M + 6:.1f}m above it"


def test_replay_2219_go_to_is_verified_ok(tmp_path):
    state = copy.deepcopy(STATES[5])
    after = {**copy.deepcopy(state), "position": LIVE["position"]}
    r = Replay(tmp_path, state)
    r.body.act("go_to", ok(position=LIVE["position"], target_position=LIVE["target_position"], arrive_tolerance=3.0,
                           dist_m=0.77), state_after=after)
    out = r.executor.run_task(Task(skill="go_to", args={"target": LIVE["target_position"]}))
    assert out.ok, out.reason
    assert r.records("verification_failed") == []


def test_a_verification_failure_template_says_no_metres(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.controller.report_failure("go_to", "verification_failed: still 3.3m from target", {})
    assert r.body.said == ["Sorry, I couldn't walk somewhere."]

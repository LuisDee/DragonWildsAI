"""evals/bench/snapshot.py (route B) against temp copies of SaveGames / SaveCharacters; no process is touched."""
from __future__ import annotations

import os
import time

import pytest

from evals.bench.observer import Abort
from evals.bench.snapshot import Snapshots, sha


def rig(tmp_path):
    sg, sc = tmp_path / "SaveGames", tmp_path / "SaveCharacters"
    sg.mkdir()
    sc.mkdir()
    (sg / "CompanionDev.sav").write_bytes(b"world-v1")
    (sg / "CompanionDev.sav.backup").write_bytes(b"world-v0")
    (sc / "CD_x.json").write_text('{"skills": 1}')
    calls = []
    s = Snapshots(save_games=sg, save_characters=sc, root=tmp_path / "snaps",
                  stop_client=lambda: calls.append("stop_client") or 0, stop_server=lambda: calls.append("stop_server") or 0,
                  start_server=lambda: calls.append("start_server") or 0, clock=lambda: 1793000000.0)
    return s, sg, sc, calls


def test_take_then_restore_round_trips_and_backs_up_the_live_files(tmp_path):
    s, sg, sc, calls = rig(tmp_path)
    man = s.take("cap_s1", "CD_x", case="capstone_stage_1_shelter", guid="G")
    assert calls == ["stop_client", "stop_server", "start_server"]
    assert set(man["files"]) == {"CompanionDev.sav", "CD_x.json"} and man["case"] == "capstone_stage_1_shelter"
    # the world moves on (and a stray NEWER save appears), the character too
    (sg / "CompanionDev.sav").write_bytes(b"world-v2")
    (sg / "Other.sav").write_bytes(b"stray")
    (sc / "CD_x.json").write_text('{"skills": 9}')
    calls.clear()
    res = s.restore("cap_s1")
    assert calls == ["stop_client", "stop_server", "start_server"]
    assert sorted(p.name for p in sg.iterdir()) == ["CompanionDev.sav"]  # emptied: the newest .sav wins at start
    assert (sg / "CompanionDev.sav").read_bytes() == b"world-v1" and (sc / "CD_x.json").read_text() == '{"skills": 1}'
    backup = tmp_path / "snaps" / res["backup"].split(os.sep)[-1]
    assert (backup / "Other.sav").read_bytes() == b"stray" and (backup / "CD_x.json").read_text() == '{"skills": 9}'
    assert s.verify("cap_s1")["ok"] is True


def test_verify_reports_a_cloud_overwrite_as_a_gap(tmp_path):
    s, sg, sc, _ = rig(tmp_path)
    s.take("cap_s1", "CD_x")
    s.restore("cap_s1")
    (sc / "CD_x.json").write_text('{"skills": "cloud"}')
    v = s.verify("cap_s1")
    assert v["ok"] is False and "fixture gap" in v["why"]


def test_a_corrupt_snapshot_is_refused_before_anything_live_is_touched(tmp_path):
    s, sg, sc, calls = rig(tmp_path)
    s.take("cap_s1", "CD_x")
    (tmp_path / "snaps" / "cap_s1" / "CompanionDev.sav").write_bytes(b"tampered")
    calls.clear()
    with pytest.raises(Abort, match="missing or changed"):
        s.restore("cap_s1")
    assert calls == [] and (sg / "CompanionDev.sav").read_bytes() == b"world-v1"


def test_names_are_immutable_and_failures_still_restart_the_server(tmp_path):
    s, sg, sc, calls = rig(tmp_path)
    s.take("cap_s1", "CD_x")
    with pytest.raises(Abort, match="exists"):
        s.take("cap_s1", "CD_x")
    calls.clear()
    with pytest.raises(Abort, match="no character file"):
        s.take("cap_s2", "CD_missing")
    assert calls[-1] == "start_server"
    assert [m["name"] for m in s.list()] == ["cap_s1"]

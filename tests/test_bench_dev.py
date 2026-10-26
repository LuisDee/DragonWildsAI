"""evals/bench/devtarget.py: dev guards (never Shockbyte, loopback only, no second brain), probe normalisation,
referee tailing, fixture argument resolution. All side effects faked."""
from __future__ import annotations

import json

import pytest

from evals.bench import devtarget as dt
from evals.bench.observer import Abort


@pytest.fixture(autouse=True)
def _setup_log(tmp_path, monkeypatch):
    monkeypatch.setattr(dt, "SETUP_LOG", tmp_path / "fixture_setup.jsonl")


def test_setup_is_logged_with_purpose(tmp_path):
    t, _ = make(tmp_path)
    t.setup("grant", item="ITEM_Resources_Stone", count=1, purpose="spell evidence: Divine Rock")
    row = json.loads((tmp_path / "fixture_setup.jsonl").read_text(encoding="utf-8").splitlines()[-1])
    assert row["verb"] == "grant" and row["purpose"] == "spell evidence: Divine Rock" and row["ok"]


def make(tmp_path, joined="127.0.0.1:7777", forbidden=("1.2.3.4:7777",), brain=False, replies=None):
    calls = []

    def server(args):
        calls.append(args)
        return {"ok": True, "data": {"result": (replies or {}).get(args.get("verb") or args.get("action"), {"ok": True})}}
    t = dt.DevTarget("GUID", client_cmd=lambda p, n, a, to: {"ok": True, "result": {"ok": True, "probe": {
        "t": 1.0, "inventory": [], "cooldowns": [], "skills": {"Mining": {"level": 1, "xp": 0}}}}},
        server_debug=server, joined=lambda: joined, forbidden=lambda: list(forbidden), brain_running=lambda: brain,
        referee_log=tmp_path / "referee.jsonl")
    return t, calls


@pytest.mark.parametrize("joined,forb,brain,why", [
    ("1.2.3.4:7777", ("1.2.3.4:7777",), False, "forbidden"),
    ("8.8.8.8:7777", (), False, "not the local dev server"),
    (None, (), False, "cannot tell"),
    ("127.0.0.1:7777", (), True, "two brains"),
])
def test_guards_refuse(tmp_path, joined, forb, brain, why):
    t, calls = make(tmp_path, joined, forb, brain)
    with pytest.raises(Abort, match=why):
        t.setup("grant", item="ITEM_Resources_Stone", count=1)
    assert calls == []  # nothing reached the server


def test_setup_resolves_catalog_paths_and_logs(tmp_path):
    t, calls = make(tmp_path)
    t.setup("grant", item="ITEM_Resources_Stone", count=2)
    t.setup("grant_runes", runes={"Air": 10})
    t.setup("unlock", spell="USD_Windstep")
    assert calls[0]["path"].endswith("ITEM_Resources_Stone.ITEM_Resources_Stone") and calls[0]["character_guid"] == "GUID"
    assert calls[1]["items"][0]["path"].endswith("ITEM_Rune_Air.ITEM_Rune_Air")
    assert calls[2]["paths"][0].endswith("USD_Windstep.USD_Windstep")
    assert [s["verb"] for s in t.setup_log] == ["grant", "grant_runes", "unlock"]


def test_failed_fixture_aborts_the_case(tmp_path):
    t, _ = make(tmp_path, replies={"grant": {"ok": False, "error": "no_live_empty_tag_container"}})
    with pytest.raises(Abort, match="no_live_empty_tag_container"):
        t.setup("grant", item="ITEM_Resources_Stone")


def test_probe_normalises_empty_lua_tables(tmp_path):
    t, _ = make(tmp_path)
    p = t.probe()
    assert p["cooldowns"] == {} and p["inventory"] == {} and p["skills"]["Mining"]["xp"] == 0


def test_referee_tail_keeps_only_verified_kinds(tmp_path):
    t, _ = make(tmp_path)
    log = tmp_path / "referee.jsonl"
    log.write_text(json.dumps({"kind": "referee_start"}) + "\n", encoding="utf-8")
    t.referee_start()
    with open(log, "a", encoding="utf-8") as f:
        for e in ({"kind": "damage", "amount": 8}, {"kind": "projectile", "hit": True}, {"kind": "death", "kind_id": "X"}):
            f.write(json.dumps(e) + "\n")
    assert [e["kind"] for e in t.referee_events()] == ["damage", "death"]
    assert t.referee_events() == []


def test_joined_from_game_log_reads_the_join_remote_addr(tmp_path):
    f = tmp_path / "game.log"
    f.write_text("x\n[..]LogNet: UPendingNetGame::SendInitialJoin: Sending hello. [UNetConnection] RemoteAddr: 127.0.0.1:7777, Name\n",
                 encoding="utf-8")
    assert dt.joined_from_game_log(f) == "127.0.0.1:7777"


def test_raise_skills_reply_that_names_the_target_skill_is_refused(tmp_path):
    """Main 2026-10-26: M3 initiative may raise the OTHER skills; the target skill itself is never touched."""
    t, _ = make(tmp_path, replies={"raise_skills": {"ok": True, "results": {"Mining": {"ok": True}, "Attack": {"ok": True}}}})
    with pytest.raises(Abort, match="touched the target skill Mining"):
        t.setup("raise_skills", **{"except": "Mining", "level": 10})
    t2, _ = make(tmp_path, replies={"raise_skills": {"ok": True, "results": {"Attack": {"ok": True}}}})
    assert t2.setup("raise_skills", **{"except": "Mining", "level": 10})["ok"]


def test_a_failed_fixture_reads_as_a_fixture_gap_not_a_fail(tmp_path):
    from evals.bench import devrun
    from evals.bench.goal_drafts import every_skill
    case = next(c for c in every_skill() if c.mode == "initiative")
    t, _ = make(tmp_path, replies={"raise_skills": {"ok": False, "error": "unverified"}})
    r = devrun.run_case_dev(case, t, tmp_path / "w", {"haiku": 1, "sonnet": 0}, log=lambda *_: None)
    assert (r.result, r.reason) == ("unverifiable", "fixture_gap"), (r.result, r.reason, r.detail)


def test_hold_uses_the_body_equip_and_scene_teleports_to_a_known_place(tmp_path, monkeypatch):
    t, calls = make(tmp_path)
    seen = []
    t.body_call = lambda tool, args: seen.append((tool, args)) or {"ok": True, "data": {"equipped": args["item"]}}
    assert t.setup("hold", item="ITEM_Sword_Bronze", category="melee_weapon")["ok"]
    assert seen == [("equip", {"item": "ITEM_Sword_Bronze"})]
    monkeypatch.setattr(dt, "dev_places", lambda: {"standing_trees": {"at": [1.0, 2.0, 3.0]}})
    t.setup("scene", needs="standing_trees")
    assert calls[-1]["verb"] == "teleport" and calls[-1]["at"] == [1.0, 2.0, 3.0]
    monkeypatch.setattr(dt, "dev_places", lambda: {})
    with pytest.raises(Abort, match="no dev place"):
        t.setup("scene", needs="standing_trees")


def test_claim_bed_uses_the_body_interact_and_proves_the_claim_on_the_server(tmp_path, monkeypatch):
    monkeypatch.setattr(dt.time, "sleep", lambda s: None)
    state = {"mine": False}

    def server(args):
        if args.get("action") == "beds":
            return {"ok": True, "data": {"result": {"ok": True, "beds": [
                {"id": "BP_Bed_C_1", "position": [10.0, 20.0, 0.0], "claimed": state["mine"], "mine": state["mine"]}]}}}
        return {"ok": True, "data": {"result": {"ok": True}}}
    t, _ = make(tmp_path)
    t.server_debug = server
    calls = []

    def body(tool, args):
        calls.append((tool, args))
        if tool == "look":
            return {"ok": True, "data": {"things": [{"id": "bed_client_1", "name": "Wooden Bed"}]}}
        if tool == "interact" and args.get("secondary"):
            state["mine"] = True  # the claim is the bed's secondary option
        return {"ok": True}
    t.body_call = body
    res = t.setup("claim_bed", away_m=40)
    assert res["ok"] and [c[0] for c in calls] == ["look", "interact", "interact"]
    state["mine"] = False
    t.body_call = lambda tool, args: {"ok": True, "data": {"things": [{"id": "b", "name": "Bed"}]}}  # never claims
    with pytest.raises(Abort, match="did not claim"):
        t.setup("claim_bed")


def test_after_cast_move_walks_him_away_right_after_the_armed_cast(tmp_path, monkeypatch):
    monkeypatch.setattr(dt.time, "sleep", lambda s: None)
    t, _ = make(tmp_path)
    walked = []
    t.body_call = lambda tool, args: walked.append((tool, args)) or {"ok": True}
    t.probe = lambda: {"position": [8.0, 0.0, 0.0]}
    t.setup("after_cast_move", spell="Recall", offset_m=[8, 0, 0], wait_s=0)
    assert t.harness_after("cast", {"spell": "Windstep"}, {}, {"position": [0, 0, 0]}) is None  # another spell
    h = t.harness_after("cast", {"spell": "Recall"}, {}, {"position": [0.0, 0.0, 0.0]})
    assert walked == [("go_to", {"target": [8.0, 0.0, 0.0]})] and h["after_cast_move"]["mid"] == [8.0, 0.0, 0.0]


def test_spawn_passes_verified_paths_and_unverified_candidates(tmp_path, monkeypatch):
    t, calls = make(tmp_path)
    monkeypatch.setattr(dt, "spawn_class_paths", lambda: {"BP_AI_RuntGoblin_Character_C": "/Game/R.R_C",
                                                          "BP_AI_Wolf_Character_C": ["/Game/A.W_C", "/Game/B.W_C"]})
    t.setup("spawn", **{"class": "BP_AI_RuntGoblin_Character_C"})
    assert calls[-1]["class_paths"] == ["/Game/R.R_C"]
    t.setup("spawn", **{"class": "BP_AI_Wolf_Character_C"})
    assert calls[-1]["class_paths"] == ["/Game/A.W_C", "/Game/B.W_C"]


def test_ground_item_is_granted_and_dropped_by_the_body_on_the_spot(tmp_path):
    t, calls = make(tmp_path)
    body = []
    t.body_call = lambda tool, args: body.append((tool, args)) or {"ok": True}
    t.probe = lambda: {"position": [10.0, 20.0, 1.0]}
    t.setup("ground_item", item="ITEM_Rune_Law", count=40, at=[6, 2, 0])
    verbs = [c.get("verb") for c in calls]
    assert verbs == ["teleport", "grant", "teleport"] and calls[0]["at"] == [16.0, 22.0, 1.5]
    assert body == [("drop", {"item": "ITEM_Rune_Law", "count": 40})] and calls[-1]["at"] == [10.0, 20.0, 1.5]


def test_full_run_sittings_resume_finished_runs_and_refuse_a_changed_companion(tmp_path, monkeypatch):
    from evals.bench import devrun, hashes
    from evals.bench.runner import CaseResult
    h = {"c": "aaa"}
    monkeypatch.setattr(hashes, "companion_hash", lambda: h["c"])
    monkeypatch.setattr(hashes, "judge_hash", lambda: "j")
    monkeypatch.setattr(hashes, "body_hash", lambda: "b")
    monkeypatch.setattr(hashes, "game_build", lambda: "26161880")
    done, why = devrun.sitting_check(tmp_path, True)
    assert done == {} and why is None
    r = CaseResult("t0_cast_windstep", "hh", "spell_cast", "T0", "companion", "dev", "pass", None, "", repeat_i=1)
    devrun.save_partial(tmp_path, r)
    done, why = devrun.sitting_check(tmp_path, True)
    assert why is None and done[("t0_cast_windstep", 1)].result == "pass"
    h["c"] = "bbb"  # someone committed brain code between sittings
    done, why = devrun.sitting_check(tmp_path, True)
    assert done == {} and "code changed" in why


def test_felled_log_is_felled_by_the_body_and_bound_as_the_target(tmp_path, monkeypatch):
    t, calls = make(tmp_path)
    monkeypatch.setattr(dt, "dev_places", lambda: {"standing_trees": {"at": [100.0, 1892.0, -31.0]}})
    seen = []

    def body(tool, args):
        seen.append(tool)
        if tool == "look":
            return {"ok": True, "data": {"things": [{"id": "BP_SplittableLog_Ash_C_77", "name": "Ash Log"}]}}
        return {"ok": True}
    t.body_call = body
    res = t.setup("felled_log", at=[4, 0, 0])
    assert res["id"] == "BP_SplittableLog_Ash_C_77" and seen == ["gather", "look"] and res["unverified"]
    assert [c.get("verb") for c in calls] == ["teleport", "grant"]


def test_built_is_a_supported_referee_kind_and_the_build_gap_is_gone():
    """Live 2026-10-26 14:59:39Z: the referee recorded {kind: built, by: self, piece_index: 26} (Campfire)."""
    from evals.bench import goal_drafts
    assert "built" in dt.REFEREE_SUPPORTS
    for c in goal_drafts.long_tasks():
        assert "build_tool" not in str((c.provenance or {}).get("gap") or ""), c.id

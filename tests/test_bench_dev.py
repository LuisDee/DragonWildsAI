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

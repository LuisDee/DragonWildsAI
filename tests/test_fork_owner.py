"""A harness fork is told the truth about itself (brain/fork_line.py). Offline, fakes only.

Test windows (tools/job_run.py, tools/quest_run.py) play a FORK of ClaudeDev: a new save, name and guid copied from
his. The world's base crates belong to ClaudeDev, and the body says so truthfully ("ClaudeDev (another character of
your account)"), so the fork refused its own base crates in about half the trials (2026-11-18 runs 091424, 092356,
101804, 102841-N1-I5: "the chests near here belong to ClaudeDev, not me"). With DW_FORKED_FROM set by the harness, a
container owned by the character he was copied from is shown as his, and the persona says once that he is a copy.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from conftest import Rig

from brain import fork_line
from brain.bridge_client import BridgeClient
from brain.jsonl_log import JsonlLogger

DEV_GUID = "E71C5DC146F0A55B69FF52A881255DEF"
FORK_GUID = "11111111222222223333333344444444"
LUIS_GUID = "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD"
LINE = f"ClaudeDev:{DEV_GUID}"


def dev_crate():  # as client_mod/scripts/sense.lua owner_row words it (run 101804, look result)
    return {"id": "BP_BaseBuilding_Chest_Small_C_2147472962", "name": "Ash Chest", "kind": "storage", "mine": False,
            "same_account": True, "owner": "ClaudeDev (another character of your account)", "owner_name": "ClaudeDev",
            "owner_guid": DEV_GUID}


def luis_crate():
    return {"id": "BP_BaseBuilding_Crate_C_7", "name": "Crate", "kind": "storage", "mine": False,
            "same_account": False, "owner": "Luis (another player)", "owner_name": "Luis", "owner_guid": LUIS_GUID}


def own_crate():
    return {"id": "BP_BaseBuilding_Crate_C_9", "name": "Crate", "owner": "yours", "owner_guid": FORK_GUID, "mine": True}


# ------------------------------------------------------------------ the line and the rewording
def test_line_parses_and_builds_without_the_played_character():
    assert fork_line.parse(LINE) == [("ClaudeDev", DEV_GUID)]
    assert fork_line.parse("ClaudeDev:e71c5dc1-46f0a55b-69ff52a8-81255def; ClaudeJ1a") == [
        ("ClaudeDev", DEV_GUID), ("ClaudeJ1a", None)]
    assert fork_line.parse("") == [] and fork_line.parse(None) == []
    # a checkpoint pair plays the checkpoint's own character: it is never "copied from" itself
    assert fork_line.value([("ClaudeDev", DEV_GUID), ("ClaudeJ1a", FORK_GUID)], played_guid=FORK_GUID) == LINE
    assert fork_line.value([("ClaudeDev", DEV_GUID), ("ClaudeDev", DEV_GUID)], played_guid=None) == LINE
    assert fork_line.value([("ClaudeDev", DEV_GUID)], played_guid=DEV_GUID) == ""  # ClaudeDev himself: no line


def test_a_crate_of_the_character_he_was_copied_from_is_his():
    data = {"things": [dev_crate(), luis_crate(), own_crate()]}
    assert fork_line.mark(data, fork_line.parse(LINE)) == 1
    dev, luis, own = data["things"]
    assert dev["owner"] == "ClaudeDev (the character you were copied from for this test: his things are yours)"
    assert dev["mine"] is True and dev["copied_from"] is True
    assert dev["owner_name"] == "ClaudeDev" and dev["owner_guid"] == DEV_GUID and dev["same_account"] is True
    assert luis == luis_crate()  # another player's stays another player's
    assert own == own_crate()


def test_a_store_result_carries_the_owner_at_the_top():
    data = {"container": "BP_BaseBuilding_Chest_Small_C_2147472962", "contents": ["4 Ash Logs"],
            **{k: v for k, v in dev_crate().items() if k.startswith(("owner", "mine", "same"))}}
    fork_line.mark(data, fork_line.parse(LINE))
    assert data["mine"] is True and "copied from" in data["owner"]


def test_off_without_the_line():
    data = {"things": [dev_crate()]}
    assert fork_line.mark(data, []) == 0 and data == {"things": [dev_crate()]}
    assert fork_line.from_env({}) == [] and fork_line.data_filter([]) is None
    assert fork_line.identity([]) == ""


def test_a_name_only_line_matches_by_name_and_a_guid_wins_over_a_name():
    data = {"things": [dev_crate()]}
    assert fork_line.mark(data, fork_line.parse("ClaudeDev")) == 1
    other = {**dev_crate(), "owner_guid": LUIS_GUID}  # same name, another character's guid: not his line
    assert fork_line.mark(other, fork_line.parse(LINE)) == 0


# ------------------------------------------------------------------ one place: the bridge's data filter
class ReplyTransport:
    def __init__(self, data):
        self.data, self.pending = data, []

    def send(self, msg):
        self.pending.append({"v": 1, "type": "result", "id": msg["id"], "ok": True, "reason": None,
                             "data": json.loads(json.dumps(self.data))})

    def receive(self, timeout=0.0):
        out, self.pending = self.pending, []
        return out


def test_the_bridge_shows_the_brain_his_line_and_logs_the_games_read(tmp_path):
    log = JsonlLogger(tmp_path / "b.jsonl")
    c = BridgeClient(ReplyTransport({"things": [dev_crate(), luis_crate()]}), log, default_timeout=2.0)
    c.data_filter = fork_line.data_filter(fork_line.parse(LINE))
    seen = []
    c.result_hooks.append(lambda tool, args, res: seen.append(res["data"]["things"][0]["mine"]))
    got = c.look()
    assert got["data"]["things"][0]["mine"] is True and "copied from" in got["data"]["things"][0]["owner"]
    assert got["data"]["things"][1]["owner"] == "Luis (another player)"
    assert seen == [True]  # every hook (stash) sees it as his
    raw = [json.loads(x) for x in (tmp_path / "b.jsonl").read_text(encoding="utf-8").splitlines()]
    recv = next(r for r in raw if r["kind"] == "bridge_recv")
    assert recv["msg"]["data"]["things"][0]["owner"] == "ClaudeDev (another character of your account)"


def test_the_bridge_without_a_filter_is_unchanged(tmp_path):
    c = BridgeClient(ReplyTransport({"things": [dev_crate()]}), JsonlLogger(tmp_path / "b.jsonl"), default_timeout=2.0)
    assert c.look()["data"]["things"][0] == dev_crate()


def test_run_live_sets_the_filter_from_the_environment():
    src = (Path(__file__).resolve().parents[1] / "brain" / "run_live.py").read_text(encoding="utf-8")
    assert "line = fork_line.from_env()" in src and "self.client.data_filter = fork_line.data_filter(line, self.log)" in src


# ------------------------------------------------------------------ the identity line
def test_the_persona_says_once_that_he_is_a_test_copy(tmp_path, monkeypatch):
    monkeypatch.setenv(fork_line.ENV, LINE)
    p = Rig(tmp_path).controller.persona()
    assert p.count("test copy of ClaudeDev") == 1
    monkeypatch.delenv(fork_line.ENV)
    assert "test copy" not in Rig(tmp_path / "b").controller.persona()


# ------------------------------------------------------------------ the harness says it when it starts the brain
def test_chat_ladder_brain_env_carries_the_line_only_when_given(monkeypatch):
    from tools import chat_ladder as cl
    monkeypatch.setenv(fork_line.ENV, "Stale:" + LUIS_GUID)  # never leaks from the harness's own environment
    a = argparse.Namespace(world="dev_ClaudeJ1a", usd=1.0, forked_from=LINE)
    assert cl.brain_env(a, 0.0)[fork_line.ENV] == LINE
    assert fork_line.ENV not in cl.brain_env(argparse.Namespace(world="dev_x", usd=1.0), 0.0)


def _save(path: Path, name: str, guid: str) -> Path:
    path.write_text(json.dumps({"meta_data": {"char_name": name, "char_guid": guid}}), encoding="utf-8")
    return path


def test_quest_run_names_the_line_from_the_saves(tmp_path, monkeypatch):
    from tools import quest_clone
    from tools import quest_run as q
    monkeypatch.setattr(quest_clone, "SAVE_DIR", tmp_path)
    _save(tmp_path / "ClaudeDev.json", "ClaudeDev", DEV_GUID)
    ck = _save(tmp_path / "ck.json", "ClaudeJ1a", FORK_GUID)
    assert q.forked_from(ck, "99999999999999999999999999999999") == f"ClaudeDev:{DEV_GUID};ClaudeJ1a:{FORK_GUID}"
    assert q.forked_from(ck, FORK_GUID) == LINE  # a pair plays the checkpoint's own character
    assert q.forked_from(tmp_path / "ClaudeDev.json", FORK_GUID) == LINE


# ------------------------------------------------------------------ the graders keep the game's read
def test_self_owned_still_wants_this_character_and_game_owner_his_line():
    from tools import job_run as j
    row = {"things": [dev_crate()]}
    fork_line.mark(row, fork_line.parse(LINE))
    shown = row["things"][0]
    assert "copied_from" in j.OWNER_KEYS
    assert j.self_owned(shown, FORK_GUID) is False  # the --until own_chest probe: HIM only
    start = {"own_guids": [FORK_GUID, DEV_GUID]}
    assert j.game_owner(shown["id"], start, {"chests": {shown["id"]: shown}})[0] is True

"""evals/bench/devchar.py: a fresh dev character per pristine-start case (main 2026-10-26, route A). All side
effects faked: the PowerShell scripts, the client command runner and the server's player list."""
from __future__ import annotations

import pytest

from evals.bench import devchar as dc
from evals.bench.observer import Abort


def test_fresh_names_are_short_valid_and_distinct():
    a = dc.fresh_name("m3_woodcutting_initiative", "0726a1")
    b = dc.fresh_name("m3_woodcutting_plus5", "0726a1")
    assert a != b and len(a) <= dc.MAX_NAME and len(b) <= dc.MAX_NAME
    assert all(dc.NAME_RE.match(n) for n in (a, b)) and a.startswith("CD_")


class Fake:
    def __init__(self, tmp_path, players=(), boot_rc=0, create_writes=True):
        self.calls, self.players, self.boot_rc, self.create_writes = [], list(players), boot_rc, create_writes
        self.save = tmp_path / "saves"
        self.save.mkdir()
        self.name_file = tmp_path / "character_name.txt"
        self.sw = dc.CharacterSwitch(server_players=lambda: list(self.players), client_cmd=self.cmd, ps=self.ps,
                                     name_file=self.name_file, save_dir=self.save, made_log=tmp_path / "made.jsonl",
                                     sleep=lambda s: None)

    def ps(self, script, *args, **kw):
        self.calls.append((script, args))
        if script == "client_boot.ps1" and "-Attempts" not in args and self.boot_rc == 0:
            self.players = [{"name": self.name_file.read_text().strip(), "character_guid": "G" * 32}]
        return self.boot_rc if "-Attempts" not in args else 1  # the first boot stops at the menu (new name)

    def cmd(self, file, name, args, timeout):
        self.calls.append(("cmd", (file.name,)))
        if self.create_writes:
            (self.save / (self.name_file.read_text().strip() + ".json")).write_text("{}")
        return {"ok": True, "result": {"create": True}}


def test_already_in_world_does_nothing(tmp_path):
    f = Fake(tmp_path, players=[{"name": "ClaudeDev", "character_guid": "E7"}])
    assert f.sw.ensure("ClaudeDev") == {"name": "ClaudeDev", "guid": "E7", "created": False, "relaunched": False}
    assert f.calls == []


def test_new_character_relaunches_creates_then_boots_and_resolves_the_guid(tmp_path):
    f = Fake(tmp_path, players=[{"name": "ClaudeDev", "character_guid": "E7"}])
    info = f.sw.ensure("CD_m3wood_x1", create=True)
    assert info == {"name": "CD_m3wood_x1", "guid": "G" * 32, "created": True, "relaunched": True}
    order = [c[0] for c in f.calls]
    assert order == ["stop_client.ps1", "client_boot.ps1", "cmd", "client_boot.ps1"]  # BUGS L24: never a menu return
    assert f.calls[2][1] == ("create_char.lua",)
    assert f.name_file.read_text().strip() == "CD_m3wood_x1" and f.sw.made == ["CD_m3wood_x1"]


def test_switch_back_to_an_existing_character_does_not_create(tmp_path):
    f = Fake(tmp_path, players=[{"name": "CD_m3wood_x1", "character_guid": "G1"}])
    (f.save / "ClaudeDev.json").write_text("{}")
    info = f.sw.ensure("ClaudeDev")
    assert info["created"] is False and [c[0] for c in f.calls] == ["stop_client.ps1", "client_boot.ps1"]


@pytest.mark.parametrize("kw,why", [({"create_writes": False}, "did not write"), ({"boot_rc": 1}, "client_boot did not")])
def test_failures_abort_with_a_reason(tmp_path, kw, why):
    f = Fake(tmp_path, **kw)
    with pytest.raises(Abort, match=why):
        f.sw.ensure("CD_m3wood_x1", create=True)


def test_missing_character_without_create_aborts(tmp_path):
    f = Fake(tmp_path)
    with pytest.raises(Abort, match="does not exist"):
        f.sw.ensure("CD_nope_x1")


def test_drafts_declare_the_character_policy():
    from evals.bench import goal_drafts
    from evals.bench.devrun import character_policy
    m3 = goal_drafts.every_skill()
    assert m3 and all(character_policy(c) == "fresh" for c in m3)
    cap = goal_drafts.capstone()
    stages = [c for c in cap if c.family == "capstone_stage"]
    assert character_policy(stages[0]) == "fresh" and all(character_policy(c).startswith("chain:") for c in stages[1:])
    assert all(character_policy(c) == "main" for c in goal_drafts.combat_basics())  # ClaudeDev

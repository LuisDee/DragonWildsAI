"""tools/vault_probe.py with fakes: the guards, the abort rules, the rows. No live call."""
from __future__ import annotations

import json

import pytest

from tools import vault_probe as vp

GUID = "E71C5DC146F0A55B69FF52A881255DEF"
DOOR_ROW = {"id": vp.DOOR_ID, "name": "Crasorak Kara", "prompt": "Enter", "category": "interactables",
            "kind": "interactable", "distance": 5.4, "position": [374.58, 1918.74, -0.33],
            "destination": "TP_Crasorak_In", "arrives_at": [-1650.0, 220.0, 10.0], "leads_to": "Crasorak Kara",
            "locked": False}
EXIT_ROW = {"id": "BP_InteractablePlayerTeleporter_C_UAID_18C04D97CB3D30D401_1545295722", "name": "Exit",
            "category": "interactables", "distance": 4.0, "destination": "TP_Crasorak_Out",
            "arrives_at": [374.0, 1916.0, -2.0], "leads_to": "outside"}
LEVER = {"id": "BP_BinaryLever_C_1", "category": "interactables", "distance": 30.0, "switch_position": 0,
         "switch_highest": 1, "drives": ["BP_FinalDoor_vault_Refactored_C_1"]}
CHEST = {"id": "Chest_1", "category": "interactables", "kind": "chest", "distance": 12.0, "chest_state": "unopened"}
TRAP = {"id": "Trap_1", "kind": "trap", "name": "Fire Trap", "distance": 40.0, "parts": 2, "active_parts": 1}
RAT_FAR = {"id": "Rat_1", "category": "creatures", "kind": "creature", "name": "Giant Rat", "hostile": True,
           "alive": True, "distance": 31.0, "power_level": 2}


class FakeDev:
    character_guid = GUID

    def __init__(self, world, guard_error=None, players=None):
        self.world, self.guard_error = world, guard_error
        self.players = players if players is not None else [{"name": "ClaudeDev", "character_guid": GUID}]
        self.calls = []

    def guard(self):
        if self.guard_error:
            raise RuntimeError(self.guard_error)

    def server_debug(self, args):
        return {"ok": True, "data": {"result": {"ok": True, "players": self.players}}}

    def setup(self, verb, purpose="", **a):
        self.guard()
        self.calls.append((verb, a))
        assert verb == "teleport"
        self.world.pos = list(a["at"])
        self.world.in_vault = False
        return {"ok": True}


class FakeWorld:
    """The client's debug channel: me, get_state, look, census, interact."""

    def __init__(self, name="ClaudeDev", pos=(100.0, 1892.0, -31.0)):
        self.name, self.pos, self.in_vault = name, list(pos), False
        self.health, self.max_health = 100.0, 100.0
        self.entities: list[dict] = []
        self.outside_things = [DOOR_ROW]
        self.inside_things = [EXIT_ROW, LEVER, CHEST, TRAP]
        self.inside_at = [-1650.0, 220.0, 10.0]
        self.door_works = True
        self.calls: list[tuple] = []
        self.on_inside = None  # callback when he arrives inside

    def request(self, tool, args=None, timeout=None):
        self.calls.append((tool, dict(args or {})))
        if tool == "me":
            return {"ok": True, "data": {"name": self.name, "position": list(self.pos), "health": self.health,
                                         "max_health": self.max_health}}
        if tool == "get_state":
            return {"ok": True, "data": {"position": list(self.pos), "health": self.health, "max_health": self.max_health,
                                         "nearby_entities": list(self.entities), "in_vault": self.in_vault,
                                         "vault": "Crasorak Kara" if self.in_vault else None}}
        if tool == "look":
            things = self.inside_things if self.in_vault else self.outside_things
            return {"ok": True, "data": {"things": list(things), "in_vault": self.in_vault}}
        if tool == "census":
            return {"ok": True, "data": {"creatures": [], "hazards": [TRAP] if self.in_vault else [],
                                         "prop_guard": {"stale": 0}}}
        if tool == "interact":
            if args["target"] == vp.DOOR_ID and self.door_works:
                self.pos, self.in_vault = list(self.inside_at), True
                if self.on_inside:
                    self.on_inside(self)
            elif args["target"] == EXIT_ROW["id"]:
                self.pos, self.in_vault = [374.0, 1916.0, -2.0], False
            return {"ok": True}
        return {"ok": False, "reason": f"unknown {tool}"}


def make(tmp_path, world=None, dev=None, **kw):
    world = world or FakeWorld()
    dev = dev or FakeDev(world)
    t = {"now": 0.0}

    def sleep(s):
        t["now"] += s
    probe = vp.Probe(cli=world, dev=dev, out=tmp_path / "vault_probe.jsonl", replies=tmp_path / "replies",
                     client_log=tmp_path / "client.log", sleep=sleep, clock=lambda: t["now"], print_fn=lambda s: None,
                     **kw)
    return probe, world, dev


def rows(probe):
    return [json.loads(x) for x in probe.out.read_text(encoding="utf-8").splitlines()]


class Args:
    spot, home, leave = "door", vp.HOME_DEFAULT, "door"


# ------------------------------------------------------------------ guards
def test_guard_refuses_off_dev(tmp_path):
    probe, world, dev = make(tmp_path)
    dev.guard_error = "client is on a forbidden server (1.2.3.4:7777)"
    assert vp.run_step(probe, "door", Args) == 2
    r = rows(probe)[-1]
    assert r["refused"].startswith("dev guard") and r["ok"] is False
    assert dev.calls == [] and not any(c[0] == "interact" for c in world.calls)


def test_guard_refuses_off_claudedev(tmp_path):
    probe, world, dev = make(tmp_path, world=FakeWorld(name="ClaudeV171900"))
    assert vp.run_step(probe, "enter", Args) == 2
    assert "not ClaudeDev" in rows(probe)[-1]["refused"]
    assert dev.calls == []


def test_guard_refuses_other_player_or_wrong_guid(tmp_path):
    probe, world, dev = make(tmp_path)
    dev.players = [{"name": "ClaudeDev", "character_guid": GUID}, {"name": "Zezima", "character_guid": "X"}]
    assert vp.run_step(probe, "home", Args) == 2
    assert "another player" in rows(probe)[-1]["refused"]
    dev.players = [{"name": "ClaudeDev", "character_guid": "OTHERGUID"}]
    assert vp.run_step(probe, "home", Args) == 2
    assert "does not list ClaudeDev" in rows(probe)[-1]["refused"]
    assert dev.calls == []


def test_no_confirm_touches_nothing(capsys, monkeypatch):
    monkeypatch.setattr(vp, "default_probe", lambda **kw: pytest.fail("built a live probe without --confirm"))
    assert vp.main(["door"]) == 0
    assert "--confirm" in capsys.readouterr().out


# ------------------------------------------------------------------ abort rules (pure)
def test_abort_reason_rules():
    ok = {"health": 100, "max_health": 100}
    assert vp.abort_reason(ok) is None
    assert "health" in vp.abort_reason({"health": 50, "max_health": 100})
    assert vp.abort_reason({"dead": True}) == "dead"
    near = dict(RAT_FAR, distance=12.0)
    assert "Giant Rat at 12.0 m" in vp.abort_reason({**ok, "nearby_entities": [near]})
    assert vp.abort_reason({**ok, "nearby_entities": [RAT_FAR]}) is None  # 31 m: outside 20 m
    assert vp.abort_reason({**ok, "nearby_entities": [RAT_FAR]}, hostile_m=35) is not None
    passive = {"category": "creatures", "name": "Deer", "attitude": "passive", "distance": 3.0}
    dead = dict(near, alive=False)
    summon = dict(near, follower=True, summon=True)
    assert vp.abort_reason(ok, [passive, dead, summon]) is None
    assert vp.abort_reason(ok, [DOOR_ROW, CHEST]) is None  # non-creature rows never count


# ------------------------------------------------------------------ steps
def test_door_records_the_door_row(tmp_path):
    probe, world, dev = make(tmp_path)
    assert vp.run_step(probe, "door", Args) == 0
    assert dev.calls[0] == ("teleport", {"at": vp.SPOTS["door"]["at"]})
    r = rows(probe)[-1]
    assert r["step"] == "door" and r["ok"] is True and r["in_vault"] is False
    assert r["door"]["leads_to"] == "Crasorak Kara" and r["door"]["destination"] == "TP_Crasorak_In"
    assert set(vp.TELEPORTER_FIELDS) <= set(r["door"])
    assert not any(c[0] == "interact" for c in world.calls)  # door never presses


def test_door_aborts_home_on_hostile(tmp_path):
    probe, world, dev = make(tmp_path)
    world.entities = [dict(RAT_FAR, distance=15.0)]
    assert vp.run_step(probe, "door", Args) == 1
    rs = rows(probe)
    assert rs[-2]["step"] == "door" and "hostile" in rs[-2]["aborted"]
    assert rs[-1]["step"] == "home" and rs[-1]["spot"] == vp.HOME_DEFAULT
    assert dev.calls[-1][1]["at"] == vp.spots()[vp.HOME_DEFAULT]["at"]


def test_door_aborts_home_on_low_health(tmp_path):
    probe, world, dev = make(tmp_path)
    world.health = 40.0
    assert vp.run_step(probe, "door", Args) == 1
    assert "health 40%" in rows(probe)[-2]["aborted"]
    assert rows(probe)[-1]["step"] == "home"


def test_enter_presses_once_reads_inside_and_leaves_by_the_exit(tmp_path):
    probe, world, dev = make(tmp_path)
    (tmp_path / "client.log").write_text("old line teleport_begin\n", encoding="utf-8")

    def arrive(w):  # the client's own log lines across the teleport
        with open(tmp_path / "client.log", "a", encoding="utf-8") as f:
            f.write("[DWClient] bridge: teleport_begin n=1\nnoise\n[DWClient] vault_read in_vault=true\n")
    world.on_inside = arrive
    assert vp.run_step(probe, "enter", Args) == 0
    presses = [c for c in world.calls if c[0] == "interact"]
    assert presses == [("interact", {"target": vp.DOOR_ID}), ("interact", {"target": EXIT_ROW["id"]})]
    assert ("look", {"radius": 80, "max": 40}) in world.calls
    rs = rows(probe)
    steps = [r["step"] for r in rs]
    assert steps == ["door", "enter", "leave"]
    e = rs[1]
    assert e["ok"] is True and e["in_vault"] is True and e["vault"] == "Crasorak Kara" and e["jump_m"] > 50
    assert len(e["inside"]["levers"]) == 1 and e["inside"]["levers"][0]["switch_highest"] == 1
    assert e["inside"]["chests"][0]["chest_state"] == "unopened"
    assert len(e["inside"]["hazards"]) == 1  # the trap from look and census counted once
    assert e["hooks_seen"] is True and len(e["client_log"]) == 2  # only lines since the press
    assert (tmp_path / "replies" / f"{probe.run}_enter.json").exists()
    assert rs[2]["ok"] is True and rs[2]["in_vault"] is False and rs[2]["door_m"] < 5


def test_enter_aborts_inside_on_a_guardian(tmp_path):
    probe, world, dev = make(tmp_path)
    world.on_inside = lambda w: setattr(w, "entities", [{"id": "Hulk", "name": "Vault Guardian Hulk", "hostile": True,
                                                         "alive": True, "distance": 8.0}])
    assert vp.run_step(probe, "enter", Args) == 1
    rs = rows(probe)
    assert rs[-2]["step"] == "enter" and "Vault Guardian Hulk" in rs[-2]["aborted"]
    assert rs[-1]["step"] == "home"
    assert [c[1]["target"] for c in world.calls if c[0] == "interact"] == [vp.DOOR_ID]  # no exit press, sent home


def test_enter_no_teleport_goes_home_without_second_press(tmp_path):
    probe, world, dev = make(tmp_path)
    world.door_works = False
    assert vp.run_step(probe, "enter", Args) == 1
    assert len([c for c in world.calls if c[0] == "interact"]) == 1
    rs = rows(probe)
    assert rs[-2]["step"] == "enter" and rs[-2]["ok"] is False and rs[-1]["step"] == "home"


def test_enter_locked_door_is_not_pressed(tmp_path):
    probe, world, dev = make(tmp_path)
    world.outside_things = [dict(DOOR_ROW, locked=True)]
    assert vp.run_step(probe, "enter", Args) == 1
    assert not any(c[0] == "interact" for c in world.calls)
    assert "locked" in rows(probe)[-1]["detail"]


def test_home_step(tmp_path):
    probe, world, dev = make(tmp_path, world=FakeWorld(pos=(370.7, 1915.0, -0.7)))
    assert vp.run_step(probe, "home", Args) == 0
    r = rows(probe)[-1]
    assert r["step"] == "home" and r["ok"] is True and r["position"] == vp.spots()["standing_trees"]["at"]


def test_fall_after_placement_aborts(tmp_path):
    probe, world, dev = make(tmp_path)
    real = world.request

    def falling(tool, args=None, timeout=None):
        if tool == "me" and world.pos[:2] == vp.SPOTS["door"]["at"][:2]:
            world.pos[2] -= 1.5  # sinks 1.5 m a poll: into cells not yet streamed
        return real(tool, args, timeout)
    world.request = falling
    assert vp.run_step(probe, "door", Args) == 1
    assert "fell" in rows(probe)[-2]["aborted"]


def test_spots():
    sp = vp.spots()
    assert vp.d2(sp["door"]["at"], vp.DOOR_AT) < 6
    assert sp["standing_trees"]["at"] == [100.0, 1892.0, -31.0]

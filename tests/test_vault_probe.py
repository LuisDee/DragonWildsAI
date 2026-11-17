"""tools/vault_probe.py with fakes: the guards, the abort rules, the rows, and enter's fork window (fork, switch,
back to ClaudeDev before the lock goes). No live call."""
from __future__ import annotations

import contextlib
import json

import pytest

from tools import vault_probe as vp

GUID = "E71C5DC146F0A55B69FF52A881255DEF"
FORK = "ClaudeV17220000"
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
    world = world or FakeWorld(name=kw.get("character", "ClaudeDev"))
    dev = dev or FakeDev(world, players=[{"name": world.name, "character_guid": GUID}])
    t = {"now": 0.0}

    def sleep(s):
        t["now"] += s
    probe = vp.Probe(cli=world, dev=dev, out=tmp_path / "vault_probe.jsonl", replies=tmp_path / "replies",
                     client_log=tmp_path / "client.log", sleep=sleep, clock=lambda: t["now"], print_fn=lambda s: None,
                     **kw)
    return probe, world, dev


def rows(probe):
    return [json.loads(x) for x in probe.out.read_text(encoding="utf-8").splitlines()]


def on_fork(tmp_path, **kw):
    """A probe on a fork (what enter's window hands run_step)."""
    return make(tmp_path, character=FORK, **kw)


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
    assert vp.run_step(probe, "door", Args) == 2
    assert "not ClaudeDev" in rows(probe)[-1]["refused"]
    assert dev.calls == []


def test_enter_is_refused_on_claudedev_himself(tmp_path):
    probe, world, dev = make(tmp_path)  # ClaudeDev, as the client and the server say
    assert vp.run_step(probe, "enter", Args) == 2
    r = rows(probe)[-1]
    assert "fork" in r["refused"] and r["character"] == "ClaudeDev"
    assert dev.calls == [] and not any(c[0] == "interact" for c in world.calls)


def test_guard_on_a_fork_wants_the_fork_by_its_guid(tmp_path):
    probe, world, dev = on_fork(tmp_path)
    dev.players = [{"name": FORK, "character_guid": "OTHER"}]
    assert vp.run_step(probe, "enter", Args) == 2
    assert f"does not list {FORK}" in rows(probe)[-1]["refused"]
    world.name = "ClaudeDev"  # the client still on ClaudeDev: never drive him as the fork
    dev.players = [{"name": FORK, "character_guid": GUID}]
    assert vp.run_step(probe, "enter", Args) == 2
    assert f"not {FORK}" in rows(probe)[-1]["refused"]
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
    probe, world, dev = on_fork(tmp_path)
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
    assert {r["character"] for r in rs} == {FORK}
    assert len(e["inside"]["levers"]) == 1 and e["inside"]["levers"][0]["switch_highest"] == 1
    assert e["inside"]["chests"][0]["chest_state"] == "unopened"
    assert len(e["inside"]["hazards"]) == 1  # the trap from look and census counted once
    assert e["hooks_seen"] is True and len(e["client_log"]) == 2  # only lines since the press
    assert (tmp_path / "replies" / f"{probe.run}_enter.json").exists()
    assert rs[2]["ok"] is True and rs[2]["in_vault"] is False and rs[2]["door_m"] < 5


def test_enter_aborts_inside_on_a_guardian(tmp_path):
    probe, world, dev = on_fork(tmp_path)
    world.on_inside = lambda w: setattr(w, "entities", [{"id": "Hulk", "name": "Vault Guardian Hulk", "hostile": True,
                                                         "alive": True, "distance": 8.0}])
    assert vp.run_step(probe, "enter", Args) == 1
    rs = rows(probe)
    assert rs[-2]["step"] == "enter" and "Vault Guardian Hulk" in rs[-2]["aborted"]
    assert rs[-1]["step"] == "home"
    assert [c[1]["target"] for c in world.calls if c[0] == "interact"] == [vp.DOOR_ID]  # no exit press, sent home


def test_enter_no_teleport_goes_home_without_second_press(tmp_path):
    probe, world, dev = on_fork(tmp_path)
    world.door_works = False
    assert vp.run_step(probe, "enter", Args) == 1
    assert len([c for c in world.calls if c[0] == "interact"]) == 1
    rs = rows(probe)
    assert rs[-2]["step"] == "enter" and rs[-2]["ok"] is False and rs[-1]["step"] == "home"


def test_enter_locked_door_is_not_pressed(tmp_path):
    probe, world, dev = on_fork(tmp_path)
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


# ------------------------------------------------------------------ enter's fork window (main, all side effects faked)
class Switch:
    """evals.bench.devchar.CharacterSwitch: which character the client is on; the fake world follows it."""

    def __init__(self, world):
        self.world, self.on, self.seen = world, "ClaudeDev", []

    def ensure(self, name, create=False, wait_s=0):
        self.on = self.world.name = name
        self.world.pos = [0.0, 0.0, 0.0]  # a new guid spawns at the world spawn
        self.seen.append(name)
        return {"name": name, "guid": f"G-{name}", "created": False, "relaunched": True}


@pytest.fixture
def window(tmp_path, monkeypatch):
    from evals.bench import devchar, devrun
    from tools import chat_ladder, live_lock, quest_clone, supply
    from tools import quest_run as q
    world = FakeWorld()
    sw = Switch(world)
    w = {"world": world, "sw": sw, "lock": [], "forked": [], "parked": [], "supplied": [], "presses": [], "fixtures_on": []}

    class Dev(FakeDev):
        character_guid, character_name = "G-ClaudeDev", "ClaudeDev"

        def server_debug(self, args):  # the server lists whoever the client is on, by that one's guid
            return {"ok": True, "data": {"result": {"ok": True, "players": [
                {"name": sw.on, "character_guid": f"G-{sw.on}"}]}}}

        def setup(self, verb, purpose="", **a):
            w["fixtures_on"].append((sw.on, self.character_guid))
            return super().setup(verb, purpose, **a)
    dev = the_dev = Dev(world)

    @contextlib.contextmanager
    def held(owner, wait_s=0, **k):
        w["lock"].append(("claim", sw.on))
        try:
            yield
        finally:
            w["lock"].append(("release", sw.on))

    real = world.request

    def request(tool, args=None, timeout=None):
        if tool == "interact":
            w["presses"].append((sw.on, args["target"]))
            if w.get("press_hook"):
                w["press_hook"]()
        return real(tool, args, timeout)
    world.request = request
    t = {"now": 0.0}

    def sleep(s):
        t["now"] += s
    monkeypatch.delenv("DW_LIVE_OWNER", raising=False)
    monkeypatch.setattr(live_lock, "read", lambda: None)
    monkeypatch.setattr(live_lock, "held", held)
    monkeypatch.setattr(devrun, "default_dev", lambda: dev)
    monkeypatch.setattr(devchar, "default_switch", lambda d: sw)
    monkeypatch.setattr(q.cl, "_debug_client", lambda: world)
    monkeypatch.setattr(q, "_on_main", lambda s, c, tries=3: (s.ensure("ClaudeDev"), {"character": "ClaudeDev"})[1])
    monkeypatch.setattr(quest_clone, "fork", lambda ref, name: (w["forked"].append((ref, name)), tmp_path / name)[1])
    monkeypatch.setattr(quest_clone, "park", lambda names: (w["parked"].extend(names), list(names))[1])
    monkeypatch.setattr(supply, "top_up", lambda d, food, water, heal=False, check=False, purpose="": (
        w["supplied"].append({"on": sw.on, "guid": d.character_guid, "purpose": purpose}), {"ok": True})[1])
    monkeypatch.setattr(chat_ladder, "body_unfit", lambda cli=None, pct=None: None)
    monkeypatch.setattr(vp, "STUCK_S", 0.0)

    def fake_probe(dev=None, **kw):
        return vp.Probe(cli=world, dev=dev if dev is not None else the_dev, out=tmp_path / "vault_probe.jsonl",
                        replies=tmp_path / "replies", client_log=tmp_path / "client.log", sleep=sleep,
                        clock=lambda: t["now"], print_fn=lambda s: None, **kw)
    monkeypatch.setattr(vp, "default_probe", fake_probe)
    w["out"] = tmp_path / "vault_probe.jsonl"
    w["dev"] = dev
    return w


def released_on_main(w):
    assert w["lock"] and w["lock"][-1][0] == "release"
    assert all(on == "ClaudeDev" for ev, on in w["lock"] if ev == "release"), w["lock"]


def window_rows(w):
    return [json.loads(x) for x in w["out"].read_text(encoding="utf-8").splitlines()]


def test_enter_runs_on_a_fork_and_ends_back_on_claudedev(window):
    assert vp.main(["enter", "--confirm"]) == 0
    (ref, name), = window["forked"]
    assert ref == "ClaudeDev" and name.startswith(vp.FORK_PREFIX) and name != "ClaudeDev"
    assert window["sw"].seen == [name, "ClaudeDev"] and window["sw"].on == "ClaudeDev"
    assert window["presses"] and {on for on, _ in window["presses"]} == {name}  # no press ever on ClaudeDev
    assert window["fixtures_on"] and set(window["fixtures_on"]) == {(name, f"G-{name}")}  # every teleport: the fork
    (s,) = window["supplied"]
    assert s["on"] == name and s["guid"] == f"G-{name}" and "harness fixture" in s["purpose"]
    released_on_main(window)
    assert window["parked"] == [name]
    rs = window_rows(window)
    assert [r["step"] for r in rs] == ["door", "enter", "leave", "fork"]
    assert {r["character"] for r in rs[:3]} == {name}
    f = rs[-1]
    assert f["ok"] is True and f["fork"]["character"] == name and f["fork"]["source"] == "ClaudeDev"
    assert f["fork"]["parked"] == [name] and f["step_rc"] == 0
    assert window["dev"].character_guid == "G-ClaudeDev"  # the fixtures aim at ClaudeDev again


def test_enter_from_a_named_checkpoint_forks_that(window):
    assert vp.main(["enter", "--confirm", "--from", "vault_ready"]) == 0
    assert window["forked"][0][0] == "vault_ready"


def test_an_interrupt_mid_enter_still_switches_back_before_the_lock_goes(window):
    def boom():
        raise KeyboardInterrupt
    window["press_hook"] = boom
    with pytest.raises(KeyboardInterrupt):
        vp.main(["enter", "--confirm"])
    assert window["sw"].on == "ClaudeDev" and len(window["presses"]) == 1
    released_on_main(window)
    assert len(window["parked"]) == 1
    assert window_rows(window)[-1]["step"] == "fork" and window_rows(window)[-1]["ok"] is True


def test_a_failed_switch_ends_on_claudedev_and_never_presses_or_supplies(window):
    sw = window["sw"]
    real = sw.ensure

    def bad(name, create=False, wait_s=0):
        if name != "ClaudeDev":
            raise RuntimeError("launch_timeout")
        return real(name)
    sw.ensure = bad
    with pytest.raises(RuntimeError):
        vp.main(["enter", "--confirm"])
    assert window["presses"] == [] and window["supplied"] == [] and sw.on == "ClaudeDev"
    released_on_main(window)
    assert len(window["parked"]) == 1  # the fork's save was written: parked


def test_the_lock_is_kept_while_the_client_is_not_back(window, monkeypatch):
    from tools import quest_run as q
    tries = []

    def on_main(s, c, tries_=3):
        tries.append(1)
        if len(tries) < 3:
            return None  # the return failed: the lock must not go
        s.ensure("ClaudeDev")
        return {"character": "ClaudeDev"}
    monkeypatch.setattr(q, "_on_main", lambda s, c, tries=3: on_main(s, c))
    assert vp.main(["enter", "--confirm"]) == 0
    assert len(tries) == 3 and window["sw"].on == "ClaudeDev"
    released_on_main(window)


def test_enter_off_the_dev_server_makes_no_fork(window):
    window["dev"].guard_error = "client is on a forbidden server"
    assert vp.main(["enter", "--confirm"]) == 2
    assert window["forked"] == [] and window["sw"].seen == [] and window["presses"] == []
    assert "dev guard" in window_rows(window)[-1]["refused"]


def test_an_unfit_fork_is_not_sent_in(window, monkeypatch):
    from tools import chat_ladder
    monkeypatch.setattr(chat_ladder, "body_unfit", lambda cli=None, pct=None: "food 10 % under 40 %")
    monkeypatch.setattr(vp, "FED_WAIT_S", 0.0)
    assert vp.main(["enter", "--confirm"]) == 2
    assert window["presses"] == [] and window["sw"].on == "ClaudeDev"
    rs = window_rows(window)
    assert "unfit" in rs[-2]["refused"] and rs[-1]["step"] == "fork"
    released_on_main(window)


def test_door_stays_on_claudedev_with_no_fork(window):
    assert vp.main(["door", "--confirm"]) == 0
    assert window["forked"] == [] and window["sw"].seen == [] and window["presses"] == []
    assert window_rows(window)[-1]["character"] == "ClaudeDev"


def test_dry_enter_says_it_forks(capsys, monkeypatch):
    monkeypatch.setattr(vp, "default_probe", lambda **kw: pytest.fail("built a live probe without --confirm"))
    assert vp.main(["enter"]) == 0
    assert "fork of ClaudeDev" in capsys.readouterr().out

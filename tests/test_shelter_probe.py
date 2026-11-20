"""tools/shelter_probe.py with the bridge mocked: the dry run, the guards, the read row (pass, crash, refusal, no
shelter station), --teleport-to and the way back. No live call."""
from __future__ import annotations

import json

import pytest

from tools import shelter_probe as sp
from tools import vault_probe as vp

GUID = "E71C5DC146F0A55B69FF52A881255DEF"
RAYS = [[1.0, 0.0, 0.0]] * 16
WHEEL = {"id": "BP_Station_Spinning_Wheel_C_7", "name": "Spinning Wheel", "class": "BP_Station_Spinning_Wheel_C",
         "distance": 4.2, "position": [173.0, 1915.0, -30.4], "yaw": 0.0, "source": "both", "component": True,
         "rule": "shelter_only", "requirement": 0,
         "raw": {"InteractionRequirements": 0, "RoofRays": [[0.0, 0.0, 1.0]], "ShelterRays": RAYS,
                 "SweepRayDistance": 2000.0, "SweepRayThickness": 200.0, "ValidityPercentage": 0.38,
                 "bIncludeNonBuildingPartActors": False, "RequiresRoofText": " needs a roof.",
                 "RequiresShelterText": " needs more surrounding shelter."},
         "shelter": {"roof": "yes", "roof_hits": 1, "roof_n": 1, "side_hits": 4, "side_n": 16, "side_pct": 25,
                     "need_pct": 38, "open": ["S", "SW"], "sides_ok": False, "covered": True, "sheltered": False,
                     "from": "game rays"},
         "facts": "roof: yes (1 of 1 roof rays meet a building piece); sides: 4 of 16 rays (25 %) meet a building "
                  "piece, it needs 38 %; open toward S, SW"}
BENCH = {"id": "BP_Station_Workbench_C_1", "name": "Workbench", "distance": 6.0, "source": "census", "component": False}


class FakeDev:
    character_guid = GUID

    def __init__(self, world, guard_error=None):
        self.world, self.guard_error = world, guard_error
        self.players = [{"name": "ClaudeDev", "character_guid": GUID}]
        self.calls = []

    def guard(self):
        if self.guard_error:
            raise RuntimeError(self.guard_error)

    def server_debug(self, args):
        return {"ok": True, "data": {"result": {"ok": True, "players": self.players}}}

    def setup(self, verb, purpose="", **a):
        self.calls.append((verb, a))
        assert verb == "teleport"
        self.world.pos = list(a["at"])
        return {"ok": True}


class FakeBridge:
    """The client's debug channel: me, get_state, shelter_read, ping."""

    def __init__(self, stations=None, pos=(100.0, 1892.0, -31.0)):
        self.name, self.pos = "ClaudeDev", list(pos)
        self.stations = [WHEEL, BENCH] if stations is None else stations
        self.calls: list[tuple] = []
        self.crash = False  # shelter_read takes the client down
        self.refuse = None  # shelter_read answers this reason
        self.entities: list[dict] = []
        self.on_read = None

    def request(self, tool, args=None, timeout=None):
        self.calls.append((tool, dict(args or {})))
        if self.crash and tool in ("ping", "me", "get_state"):
            raise ConnectionError("bridge gone")
        if tool == "me":
            return {"ok": True, "data": {"name": self.name, "position": list(self.pos), "health": 100, "max_health": 100}}
        if tool == "get_state":
            return {"ok": True, "data": {"position": list(self.pos), "health": 100, "max_health": 100,
                                         "nearby_entities": list(self.entities)}}
        if tool == "shelter_read":
            if self.on_read:
                self.on_read(self)
            if self.crash:
                raise TimeoutError("no reply")
            if self.refuse:
                return {"ok": False, "reason": self.refuse, "data": {"detail": "unknown tool"}}
            return {"ok": True, "data": {"radius": args["radius"], "here": list(self.pos), "stations": self.stations,
                                         "census_n": 2, "components_n": 1}}
        if tool == "ping":
            return {"ok": True, "data": {"pong": True}}
        if tool in ("look", "census", "interact", "build", "craft", "deconstruct"):
            pytest.fail(f"the probe called {tool}")
        return {"ok": False, "reason": f"unknown {tool}"}


def make(tmp_path, bridge=None, dumps=None, **kw):
    bridge = bridge or FakeBridge()
    dev = FakeDev(bridge)
    t = {"now": 0.0}
    dumps = dumps if dumps is not None else set()

    def sleep(s):
        t["now"] += s
    probe = sp.ShelterProbe(cli=bridge, dev=dev, out=tmp_path / "shelter_probe.jsonl", replies=tmp_path / "replies",
                            client_log=tmp_path / "client.log", sleep=sleep, clock=lambda: t["now"],
                            print_fn=lambda s: None, dumps_fn=lambda: set(dumps), **kw)
    return probe, bridge, dev, dumps


def rows(probe):
    return [json.loads(x) for x in probe.out.read_text(encoding="utf-8").splitlines()]


# ------------------------------------------------------------------ dry run and guards
def test_dry_run_says_what_it_would_do_and_touches_nothing(capsys, monkeypatch):
    monkeypatch.setattr(sp, "default_probe", lambda **kw: pytest.fail("built a live probe without --confirm"))
    monkeypatch.setattr(sp, "lock_window", lambda *a: pytest.fail("took the lock without --confirm"))
    assert sp.main(["read"]) == 0
    out = capsys.readouterr().out
    assert "dry: would" in out and "shelter_read radius 30 m" in out and "--confirm" in out and "API spend 0" in out
    assert sp.main(["read", "--teleport-to", "roofed_base", "--radius", "20"]) == 0
    out = capsys.readouterr().out
    assert "roofed_base" in out and "[174.6, 1919.4, -30.9]" in out and "back where he stood" in out


def test_unknown_spot_is_an_error(monkeypatch):
    monkeypatch.setattr(sp, "default_probe", lambda **kw: pytest.fail("built a live probe"))
    with pytest.raises(SystemExit):
        sp.main(["read", "--teleport-to", "nowhere"])


def test_refused_off_dev_touches_nothing(tmp_path):
    probe, bridge, dev, _ = make(tmp_path)
    dev.guard_error = "client is on a forbidden server"
    assert sp.run_read(probe, None, False) == 2
    r = rows(probe)[-1]
    assert r["refused"].startswith("dev guard") and r["ok"] is False and r["api_spend"] == 0
    assert not any(c[0] == "shelter_read" for c in bridge.calls) and dev.calls == []


def test_refused_with_another_player_or_off_claudedev(tmp_path):
    probe, bridge, dev, _ = make(tmp_path)
    dev.players.append({"name": "Zezima", "character_guid": "X"})
    assert sp.run_read(probe, "roofed_base", False) == 2
    assert "another player" in rows(probe)[-1]["refused"]
    dev.players.pop()
    bridge.name = "ClaudeJ17000000"
    assert sp.run_read(probe, "roofed_base", False) == 2
    assert "not ClaudeDev" in rows(probe)[-1]["refused"]
    assert dev.calls == [] and not any(c[0] == "shelter_read" for c in bridge.calls)


# ------------------------------------------------------------------ the read
def test_read_pass_row_has_the_facts_and_raw_values(tmp_path):
    probe, bridge, dev, _ = make(tmp_path, radius=25)
    (tmp_path / "client.log").write_text("old line crafting: shelter X\n", encoding="utf-8")

    def logs(b):
        with open(tmp_path / "client.log", "a", encoding="utf-8") as f:
            f.write("[t] crafting: shelter BP_Station_Spinning_Wheel_C_7 at (173.0, 1915.0, -30.4) yaw 0: roof yes 1/1\n"
                    "[t] unrelated line\n[t] crafting: shelter_read 25 m: 2 stations (2 census, 1 components), 1 with a shelter rule\n")
    bridge.on_read = logs
    assert sp.run_read(probe, None, False) == 0
    r = rows(probe)[-1]
    assert r["step"] == "read" and r["ok"] is True and r["reply_ok"] and r["ping_ok"] and r["new_dumps"] == 0
    assert r["crashed"] is None and r["radius"] == 25 and r["shelter_stations"] == 1 and r["detail"] is None
    assert ("shelter_read", {"radius": 25}) in bridge.calls
    assert [c[0] for c in bridge.calls].index("ping") > [c[0] for c in bridge.calls].index("shelter_read")
    w = next(s for s in r["stations"] if s["id"] == WHEEL["id"])
    assert w["roof"] == "yes" and w["side_pct"] == 25 and w["need_pct"] == 38 and w["open"] == ["S", "SW"]
    assert w["sides_ok"] is False and w["sheltered"] is False and w["rule"] == "shelter_only"
    raw = w["raw"]
    assert raw["ShelterRays_n"] == 16 and raw["RoofRays_n"] == 1 and "ShelterRays" not in raw
    assert raw["SweepRayDistance"] == 2000.0 and raw["SweepRayThickness"] == 200.0 and raw["ValidityPercentage"] == 0.38
    assert raw["bIncludeNonBuildingPartActors"] is False and raw["RequiresRoofText"] == " needs a roof."
    b = next(s for s in r["stations"] if s["id"] == BENCH["id"])
    assert b["component"] is False and b["rule"] is None
    assert len(r["client_log"]) == 2 and "old line" not in " ".join(r["client_log"])
    full = json.loads((tmp_path / "replies" / f"{probe.run}_read.json").read_text(encoding="utf-8"))
    assert len(full["shelter_read"]["data"]["stations"][0]["raw"]["ShelterRays"]) == 16  # every vector kept there
    assert dev.calls == []  # no --teleport-to: never moved


def test_read_crash_row(tmp_path):
    bridge = FakeBridge()
    probe, bridge, dev, dumps = make(tmp_path, bridge=bridge)

    def die(b):
        b.crash = True
        dumps.add("crash_2026_11_20_22_10_00.dmp")
    bridge.on_read = die
    assert sp.run_read(probe, None, False) == 1
    r = rows(probe)[-1]
    assert r["ok"] is False and r["reply_ok"] is False and r["ping_ok"] is False and r["crashed"] is True
    assert r["new_dumps"] == 1 and r["dumps"] == ["crash_2026_11_20_22_10_00.dmp"] and r["reason"] == "request_error"


def test_read_refused_by_an_old_client_is_no_crash(tmp_path):
    probe, bridge, dev, _ = make(tmp_path)
    bridge.refuse = "not_implemented"
    assert sp.run_read(probe, None, False) == 1
    r = rows(probe)[-1]
    assert r["ok"] is False and r["reply_ok"] is False and r["ping_ok"] is True and r["crashed"] is None
    assert r["reason"] == "not_implemented" and r["reply_detail"] == "unknown tool" and r["new_dumps"] == 0


def test_no_shelter_station_in_range_is_said(tmp_path):
    probe, bridge, dev, _ = make(tmp_path, bridge=FakeBridge(stations=[BENCH]))
    assert sp.run_read(probe, None, False) == 0
    r = rows(probe)[-1]
    assert r["ok"] is True and r["shelter_stations"] == 0
    assert "no shelter-requiring station within 30 m" in r["detail"] and "builds nothing" in r["detail"]


def test_a_station_error_is_in_its_row(tmp_path):
    bad = dict(WHEEL, error="shelter: boom", shelter=None)
    probe, bridge, dev, _ = make(tmp_path, bridge=FakeBridge(stations=[bad]))
    assert sp.run_read(probe, None, False) == 0
    r = rows(probe)[-1]
    assert r["station_errors"] == [WHEEL["id"]] and r["stations"][0]["error"] == "shelter: boom"


# ------------------------------------------------------------------ --teleport-to
def test_teleport_to_roofed_base_reads_there_and_goes_back(tmp_path):
    probe, bridge, dev, _ = make(tmp_path)
    start = list(bridge.pos)
    assert sp.run_read(probe, "roofed_base", False) == 0
    at = sp.spots()["roofed_base"]["at"]
    assert dev.calls == [("teleport", {"at": at}), ("teleport", {"at": start})]
    rs = rows(probe)
    read = next(x for x in rs if x["step"] == "read")
    assert read["placed"]["spot"] == "roofed_base" and read["position"] == at
    assert rs[-1]["step"] == "back" and rs[-1]["ok"] is True
    names = [c[0] for c in bridge.calls]
    assert names.index("shelter_read") < len(names)


def test_teleport_stay_keeps_him_there(tmp_path):
    probe, bridge, dev, _ = make(tmp_path)
    assert sp.run_read(probe, "roofed_base", True) == 0
    assert len(dev.calls) == 1 and rows(probe)[-1]["step"] == "read"


def test_hostile_after_placement_aborts_without_the_read(tmp_path):
    probe, bridge, dev, _ = make(tmp_path)
    bridge.entities = [{"category": "creatures", "name": "Giant Rat", "hostile": True, "alive": True, "distance": 8.0}]
    assert sp.run_read(probe, "roofed_base", False) == 1
    rs = rows(probe)
    ab = next(x for x in rs if x["step"] == "read")
    assert "Giant Rat" in ab["aborted"] and rs[-1]["step"] == "back"
    assert not any(c[0] == "shelter_read" for c in bridge.calls)


def test_no_teleport_back_after_a_crash(tmp_path):
    probe, bridge, dev, dumps = make(tmp_path)
    bridge.on_read = lambda b: (setattr(b, "crash", True), dumps.add("crash_x.dmp"))
    assert sp.run_read(probe, "roofed_base", False) == 1
    assert len(dev.calls) == 1 and rows(probe)[-1]["crashed"] is True


# ------------------------------------------------------------------ pure readers
def test_summarize_and_line():
    s = sp.summarize({"ok": True, "data": {"stations": [WHEEL, BENCH], "census_n": 2, "components_n": 1,
                                           "errors": ["find_all: x"]}})
    assert s["shelter_stations"] == 1 and s["read_errors"] == ["find_all: x"] and s["components_n"] == 1
    assert "roof yes 1/1, sides 25% (needs 38%), open [S,SW]" in sp.line(s["stations"][0])
    assert "no shelter component" in sp.line(s["stations"][1])
    assert sp.summarize({"ok": False, "reason": "x"})["stations"] == []
    assert "roofed_base" in sp.spots() and vp.spots()["roofed_base"]["at"] == [174.6, 1919.4, -30.9]

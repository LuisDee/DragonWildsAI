"""tools/scenario_run.py against a FAKE body + ops (no game, no PowerShell, no live client)."""
from __future__ import annotations

import json
import shutil
import subprocess
import types
from pathlib import Path

import pytest

from tools import scenario_run as sr

ROOT = Path(__file__).resolve().parents[1]
SHOCK, DEV = "1.2.3.4:20921", "127.0.0.1:7777"
SUITE = json.loads((ROOT / "tools" / "scenarios" / "dev_suite.json").read_text(encoding="utf-8"))


class FakeBody:
    def __init__(self):
        self.pos = [83.4, 1873.8, -34.6]
        self.inv = {"ITEM_Consumable_Sandwich_Veggie": 2, "ITEM_Rune_Air": 30, "ITEM_Rune_Mind": 12, "ITEM_Resources_Stone": 5,
                    "ITEM_Pickaxe_Mithril": 1}
        self.dur = {"ITEM_Pickaxe_Mithril": 2000}
        self.sust = 40.0
        self.calls: list[tuple[str, dict]] = []
        self.fail_goals: list[list[float]] = []
        self.crash_on: str | None = None
        self.things = [
            {"id": "fol:Pick_1:3", "name": "Cabbage", "item": "ITEM_Resources_Cabbage", "kind": "foliage", "foliage": "pickup",
             "category": "resources", "actions": ["interact", "gather"], "distance": 12.0, "position": [90, 1870, -34]},
            {"id": "WorldItem_7", "name": "Forager's Sandwich", "item": "ITEM_Consumable_Sandwich_Veggie", "category": "items",
             "actions": ["interact"], "distance": 8.0, "position": [88, 1871, -34]}]
        self.creatures = [
            {"id": "Kebbit_1", "name": "Kebbit", "archetype": "NeutralUntilAttacked", "health": 60, "alive": True,
             "distance": 20, "position": [100, 1880, -34]},
            {"id": "Goblin_1", "name": "Goblin Runt", "archetype": "Aggressive", "health": 156, "alive": True,
             "distance": 70, "position": [150, 1800, -30]}]

    def items_rows(self):
        rows = []
        for k, n in self.inv.items():
            rows.append({"item": k, "count": n, "where": "hotbar", "consumable": "food" if "Consumable" in k else None,
                         "kind": "HeldEquipmentItem" if k in self.dur else "Item", "durability": self.dur.get(k)})
        return rows

    def request(self, tool, args=None, timeout=15.0):
        args = args or {}
        self.calls.append((tool, args))
        if self.crash_on == tool:
            raise RuntimeError("boom")
        if tool == "capabilities":
            return {"ok": True, "data": {"tools": ["get_state", "go_to", "look", "interact", "attack", "stop", "inventory"]}}
        if tool == "get_state":
            return {"ok": True, "data": {"position": list(self.pos), "inventory": dict(self.inv), "inventory_items": self.items_rows(),
                                         "nearby_entities": [dict(c) for c in self.creatures], "health": 100, "max_health": 100,
                                         "sustenance": self.sust, "sustenance_max": 75, "hydration": 50, "hydration_max": 75,
                                         "skills": [{"skill": "Agility", "level": 5}], "gear": {"Body": "x"}, "dead": False}}
        if tool == "stop":
            return {"ok": True, "data": {}}
        if tool == "go_to":
            goal = args["target"]
            if goal in self.fail_goals:
                return {"ok": False, "reason": "path_blocked", "data": {"detail": "leader_above_jump_height"}}
            self.pos = list(goal)
            return {"ok": True, "data": {"position": goal}}
        if tool == "look":
            about = args.get("about") or ""
            if "grave" in about:
                return {"ok": True, "data": {"things": []}}
            return {"ok": True, "data": {"things": [dict(t) for t in self.things]}}
        if tool == "drop":
            self.inv[args["item"]] -= args["count"]
            n = len([t for t in self.things if t["id"].startswith("Drop_")])
            self.things.append({"id": f"Drop_{n}", "name": args["item"], "item": args["item"], "category": "items",
                                "actions": ["interact"], "distance": 1.0,
                                "position": [self.pos[0] + 0.5 * (n + 1) / 3, self.pos[1], self.pos[2]]})
            return {"ok": True, "data": {"dropped": args["count"]}}
        if tool == "interact":
            t = next(x for x in self.things if x["id"] == args["target"])
            self.things.remove(t)
            self.inv[t["item"]] = self.inv.get(t["item"], 0) + 1
            return {"ok": True, "data": {"item": t["item"], "count": 1}}
        if tool == "attack":
            for c in self.creatures:
                if c["id"] == args["target"]:
                    c["alive"] = False
            self.creatures = [c for c in self.creatures if c["alive"]]
            return {"ok": True, "data": {"outcome": "killed"}}
        return {"ok": False, "reason": "unknown_tool"}

    def cmd(self, file, args=None, timeout=20.0):
        self.calls.append(("cmd:" + file, args or {}))
        if file == "scn_find_ledge.lua":
            return {"ok": True, "result": {"ok": True, "traces": 90, "candidates": [
                {"rise_m": 1.0, "dist_m": 2.5, "base": [84.4, 1873.8, -34.6], "top": [86.6, 1873.8, -33.6]}]}}
        if file == "scn_consume.lua":
            self.sust += 18
            self.inv[args["item"]] -= 1
            return {"ok": True, "result": {"ok": True, "kind": "food"}}
        return None


class FakeOps:
    def __init__(self, joined=SHOCK, brain=False):
        self.j, self.brain, self.calls = joined, brain, []

    def brain_running(self):
        return self.brain

    def dev_server_running(self):
        return True

    def held(self):
        return None

    def nav_oracle_age_s(self):
        return 1.0

    def joined(self):
        return self.j

    def boot(self, target, timeout_s=900):
        self.calls.append(("boot", target, sr.LEASE.exists()))
        self.j = DEV if target == "dev" else SHOCK
        return {"ok": True, "joined": self.j, "state": "in_world"}

    def backup_character(self):
        self.calls.append(("backup",))
        return "backup.json"


@pytest.fixture(autouse=True)
def isolated(tmp_path, monkeypatch):
    sec = tmp_path / "secrets"
    sec.mkdir()
    (sec / "server.txt").write_text(f"{SHOCK}\npw1\n", encoding="utf-8")
    (sec / "server_dev.txt").write_text(f"{DEV}\npw2\n", encoding="utf-8")
    monkeypatch.setattr(sr, "SECRETS", sec)
    monkeypatch.setattr(sr, "STATE_DIR", tmp_path / "state")
    monkeypatch.setattr(sr, "LEASE", tmp_path / "state" / "client_target.json")
    monkeypatch.setattr(sr.time, "sleep", lambda s: None)
    return tmp_path


def args(tmp, **kw):
    a = dict(live=False, here=False, only=None, suite=None, allow_brain=False, allow_shockbyte=False, report_dir=str(tmp / "rep"),
             repeat=None)
    a.update(kw)
    return types.SimpleNamespace(**a)


def acting(body):
    return [c for c, _ in body.calls if c in ("go_to", "interact", "attack", "stop", "cmd:scn_consume.lua")]


def test_dry_run_is_read_only_and_reports(isolated):
    body, ops = FakeBody(), FakeOps()
    rep = sr.run(args(isolated), body=body, ops=ops, suite=SUITE, log=lambda m: None)
    assert rep["result"] == "dry_run" and acting(body) == [] and ops.calls == []
    res = {o["scenario"]: o["result"] for o in rep["scenarios"]}
    assert res["pit_escape"] == "dry" and res["ledge_jump"] == "dry" and res["combat_weak"] == "dry"
    assert res["grave_recovery"] == "skip"
    fc = next(o for o in rep["scenarios"] if o["scenario"] == "fetch_consume")
    assert fc["evidence"]["target"]["name"] == "Forager's Sandwich"   # dropped items before crop pickups
    cw = next(o for o in rep["scenarios"] if o["scenario"] == "combat_weak")
    assert cw["evidence"]["target"]["name"] == "Kebbit"               # never the aggressive goblin
    files = sorted(p.suffix for p in (isolated / "rep").iterdir())
    assert ".json" in files and ".md" in files


def test_live_switches_runs_and_switches_back(isolated):
    body, ops = FakeBody(), FakeOps()
    rep = sr.run(args(isolated, live=True), body=body, ops=ops, suite=SUITE, log=lambda m: None)
    assert [c[:2] for c in ops.calls] == [("backup",), ("boot", "dev"), ("boot", "shockbyte")]
    assert ops.calls[1][2] is True and ops.calls[2][2] is False          # leased while on dev, lease gone before return
    assert not sr.LEASE.exists()
    res = {o["scenario"]: o["result"] for o in rep["scenarios"]}
    assert res == {"pit_escape": "pass", "pit_to_grave_area": "pass", "alcove_escape": "pass", "waypoint_course": "pass",
                   "ledge_jump": "pass", "fetch_consume": "pass", "combat_weak": "pass", "cliff_to_grave_plateau": "pass",
                   "rune_pickup_cluster": "pass", "grave_recovery": "skip"}, rep["scenarios"]
    pit = next(o for o in rep["scenarios"] if o["scenario"] == "pit_escape")
    assert pit["detail"].startswith("5/5 runs passed") and len(pit["evidence"]["runs"]) == 5   # the suite's repeat: 5
    runes = next(o for o in rep["scenarios"] if o["scenario"] == "rune_pickup_cluster")
    dropped = [x["item"] for x in runes["evidence"]["dropped"]]
    assert dropped[:2] == ["ITEM_Rune_Air", "ITEM_Rune_Mind"] and "ITEM_Pickaxe_Mithril" not in dropped
    assert "ITEM_Consumable_Sandwich_Veggie" not in dropped and runes["evidence"]["not_recovered"] == []
    fc = next(o for o in rep["scenarios"] if o["scenario"] == "fetch_consume")
    assert "consumed" in fc["detail"] and fc["evidence"]["stat"]["rose_by"] >= 1
    assert rep["result"] == "pass"
    assert rep["baseline_diff"] == {}  # +1 fetched, -1 eaten: net zero; a real diff would be listed here


def test_failed_leg_and_crash_still_switch_back(isolated):
    body, ops = FakeBody(), FakeOps()
    body.fail_goals = [SUITE["places"]["pad_upper"]]
    body.crash_on = "attack"
    rep = sr.run(args(isolated, live=True, only="pit_escape,combat_weak", repeat=1), body=body, ops=ops, suite=SUITE,
                 log=lambda m: None)
    res = {o["scenario"]: o for o in rep["scenarios"]}
    assert res["pit_escape"]["result"] == "fail" and "leg 1" in res["pit_escape"]["detail"]
    assert res["combat_weak"]["result"] == "error" and "boom" in res["combat_weak"]["detail"]
    assert ops.calls[-1][:2] == ("boot", "shockbyte") and rep["result"] == "fail"


def test_preflight_aborts_without_touching_anything(isolated):
    body, ops = FakeBody(), FakeOps(brain=True)
    rep = sr.run(args(isolated, live=True), body=body, ops=ops, suite=SUITE, log=lambda m: None)
    assert rep["result"] == "aborted" and ops.calls == [] and acting(body) == []
    assert any("run_live" in p for p in rep["problems"])
    body, ops = FakeBody(), FakeOps(joined=SHOCK)
    rep = sr.run(args(isolated, here=True), body=body, ops=ops, suite=SUITE, log=lambda m: None)
    assert rep["result"] == "aborted" and any("Shockbyte" in p for p in rep["problems"]) and acting(body) == []


def test_lua_literal_and_prefixed_commands_compile(tmp_path):
    lit = sr.lua_literal({"item": 'a"b\\c', "n": 3, "f": 0.5, "xs": [1, "z"], "t": True})
    assert lit == '{item = "a\\"b\\\\c", n = 3, f = 0.5, xs = {1, "z"}, t = true}'
    lua = shutil.which("lua") or r"C:\Program Files\WinGet\Links\lua.exe"
    if not Path(lua).exists():
        pytest.skip("no lua.exe")
    for f, a in (("scn_find_ledge.lua", {"radius_m": 6}), ("scn_consume.lua", {"item": "ITEM_X"}), ("join_server.lua", None)):
        src = (ROOT / "client_mod" / "commands" / f).read_text(encoding="utf-8")
        if a:
            src = f"local ARGS = {sr.lua_literal(a)}\n" + src
        p = tmp_path / f
        p.write_text(src, encoding="utf-8")
        out = subprocess.run([lua, "-e", f"local f = assert(loadfile([[{p}]])); assert(type(f()) == 'function'); print('ok')"],
                             capture_output=True, text=True)
        assert out.stdout.strip() == "ok", (f, out.stderr)


def test_joined_server_reads_the_last_loadmap(tmp_path):
    g = tmp_path / "game.log"
    g.write_text("[2026.10.25-19.33.45:428][859]LogLoad: LoadMap: 203.16.163.204:20921/Game/Maps/World/L_World?p=xx?pf=PC\n"
                 "[2026.10.25-19.40.00:000][  1]LogLoad: LoadMap: 127.0.0.1:7777/Game/Maps/World/L_World?p=yy?pf=PC\n", encoding="utf-8")
    assert sr.joined_server(g) == "127.0.0.1:7777"
    g.write_text(g.read_text() + "[2026.10.25-19.41.00:000][  1]LogLoad: LoadMap: /Game/Maps/L_FrontEnd\n", encoding="utf-8")
    assert sr.joined_server(g) is None


def test_repeat_needs_every_run_to_pass(isolated):
    body, ops = FakeBody(), FakeOps()
    real = body.request
    n = {"go": 0}

    def flaky(tool, a=None, timeout=15.0):   # the 3rd trip to the doorway fails
        if tool == "go_to" and a["target"] == SUITE["places"]["pad_upper"]:
            n["go"] += 1
            if n["go"] == 3:
                return {"ok": False, "reason": "path_blocked", "data": {"detail": "no_route"}}
        return real(tool, a, timeout)
    body.request = flaky
    rep = sr.run(args(isolated, live=True, only="pit_escape"), body=body, ops=ops, suite=SUITE, log=lambda m: None)
    o = rep["scenarios"][0]
    assert o["result"] == "fail" and o["detail"].startswith("4/5 runs passed")
    assert [s["scenario"] for s in rep["steps"]][:5] == [f"pit_escape#{i}" for i in range(1, 6)]


def test_collect_cluster_skips_without_droppable_stacks(isolated):
    body, ops = FakeBody(), FakeOps()
    body.inv = {"ITEM_Consumable_Sandwich_Veggie": 2, "ITEM_Pickaxe_Mithril": 1}
    rep = sr.run(args(isolated), body=body, ops=ops, suite=SUITE, log=lambda m: None)
    o = next(x for x in rep["scenarios"] if x["scenario"] == "rune_pickup_cluster")
    assert o["result"] == "skip" and acting(body) == []


def test_expect_log_is_evidence(isolated, tmp_path):
    body, ops = FakeBody(), FakeOps()
    log = tmp_path / "client.log"
    log.write_text("old line\n", encoding="utf-8")
    body.log_offset = lambda: sr.log_offset(log)
    real = body.request

    def go(tool, a=None, timeout=15.0):
        if tool == "go_to" and a["target"] == SUITE["places"]["grave_plateau"]:
            with open(log, "a", encoding="utf-8") as f:
                f.write("2026-10-25T20:00:00Z move: memory: remembered route, 27 pts\n")
        return real(tool, a, timeout)
    body.request = go
    body.log_since = lambda off: sr.log_since(off, log)
    rep = sr.run(args(isolated, live=True, only="cliff_to_grave_plateau", repeat=1), body=body, ops=ops, suite=SUITE,
                 log=lambda m: None)
    o = rep["scenarios"][0]
    assert o["result"] == "pass" and "expected log seen on 1/1" in o["detail"]
    assert o["evidence"]["legs"][0]["expect_log"]["lines"] == ["2026-10-25T20:00:00Z move: memory: remembered route, 27 pts"]

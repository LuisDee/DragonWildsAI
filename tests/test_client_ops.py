"""tools/client_boot.ps1 + tools/client_watchdog.ps1 against a FAKE client (no game, never the live one).

The fake: a copied PING.EXE under a unique process name (a live, idle process), a Python thread that
plays the DWClient command runner (answers client_io/cmd/<name>.lua in client_io/out/<name>.json from a
scripted state), and temp dirs for logs/state/dumps. The DW_CLIENT_* overrides in tools/client_lib.ps1
point the scripts at all of it. The watchdog always runs with -DryRun here (decisions are logged, nothing
is killed or booted); boot runs for real but with -NoLaunch, so it never starts anything either.
Needs Windows PowerShell (and Steam running, as on the VM: boot checks it first).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Windows PowerShell tools")
PW = "hunter2-secret"


class FakeRunner(threading.Thread):
    """Answers runner commands from `state`; acting commands change it like the real client would."""

    def __init__(self, io: Path, state: dict):
        super().__init__(daemon=True)
        self.io, self.state, self.calls, self.stop_flag, self.answer = io, state, [], False, True
        self.texts = {}  # name -> the command file's text (as the runner saw it)

    def handle(self, name: str) -> dict:
        s = self.state
        if name == "boot_pick_char":
            s["logged_in"] = True
        elif name == "boot_join_server":
            s.update(map="L_World", intro_widgets=1, paused=True)
            return {"ok": True, "result": {"sent": True, "echo": f"open 1.2.3.4:7777?p=aHVudGVy?pf=PC {PW}"}}
        elif name == "boot_unpause":
            s["paused"] = False
        elif name == "boot_skip_intro":
            s.update(intro_widgets=0, pawn="BP_PlayerCharacter_C_1", pos_m=[1, 2, 3])
        elif name in ("boot_chat_start", "boot_sense_vitals_start", "boot_inv_reflex_start"):
            svc = {"boot_chat_start": "chat", "boot_sense_vitals_start": "vitals", "boot_inv_reflex_start": "fed_reflex"}[name]
            s["bridge"]["services"][svc] = {"state": "running", "starts": 1}
        elif name == "smk_smoke_walk":
            return {"ok": True, "result": {"ok": True, "start": [1, 2, 3], "goal": [3, 2, 3], "go_to": {"ok": True}}}
        elif name == "smk_smoke_move_status":
            return {"ok": True, "result": {"mode": "idle", "result": {"status": "arrived"}, "pos_m": [2.9, 2.1, 3]}}
        elif name == "smk_smoke_jump":
            return {"ok": True, "result": {"ok": True, "z0_cm": 300}}
        elif name == "smk_smoke_jump_read":
            return {"ok": True, "result": {"done": True, "max_dz_cm": 92.5, "samples": 20}}
        elif name == "smk_inv_list":
            return {"ok": True, "result": {"ok": True, "hotbar": [{"name": "Torch"}], "bag": [], "empty_slots": 170,
                                           "loadout": [{"loadout_slot": "Body", "name": "Adventurer's Tunic"}]}}
        return {"ok": True, "result": dict(s) if name == "wd_boot_probe" else {"ok": True}}

    def run(self):
        cmd, out = self.io / "cmd", self.io / "out"
        while not self.stop_flag:
            for f in list(cmd.glob("*.lua")) if self.answer else []:
                name = f.stem
                try:
                    self.texts[name] = f.read_text(encoding="utf-8-sig")
                    f.unlink()
                except OSError:
                    continue
                self.calls.append(name)
                (out / f"{name}.json").write_text(json.dumps(self.handle(name)), encoding="utf-8")
            time.sleep(0.1)


def in_world():
    svc = {n: {"state": "running", "starts": 0} for n in ("chat", "vitals", "fed_reflex")}
    return {"map": "L_World", "screen": 0, "logged_in": True, "pawn": "BP_PlayerCharacter_C_1", "pos_m": [1, 2, 3],
            "intro_widgets": 0, "bridge": {"running": True, "services": svc}}


def at_menu():
    s = in_world()
    s.update(map="L_FrontEnd", screen=2, logged_in=False, pawn=None, pos_m=None)
    return s


@pytest.fixture
def rig(tmp_path):
    io = tmp_path / "io"
    for d in ("cmd", "out", "secrets"):
        (io / d).mkdir(parents=True)
    (io / "secrets" / "server.txt").write_text(f"1.2.3.4:7777\n{PW}\n", encoding="utf-8")
    for d in ("state", "dumps", "logs"):
        (tmp_path / d).mkdir()
    game_log, mod_log = tmp_path / "logs" / "game.log", tmp_path / "logs" / "client.log"
    game_log.write_text("[2026.10.25-10.00.00:000][  0]LogInit: start\n", encoding="utf-8")
    mod_log.write_text("x\n", encoding="utf-8")
    exe = tmp_path / "FakeDWClient.exe"
    shutil.copy(r"C:\Windows\System32\PING.EXE", exe)
    proc = subprocess.Popen([str(exe), "-n", "600", "127.0.0.1"], stdout=subprocess.DEVNULL)
    env = dict(os.environ, DW_CLIENT_PROC="FakeDWClient", DW_CLIENT_IO=str(io), DW_CLIENT_STATE_DIR=str(tmp_path / "state"),
               DW_CLIENT_GAME_LOG=str(game_log), DW_CLIENT_MOD_LOG=str(mod_log), DW_CLIENT_DUMP_DIR=str(tmp_path / "dumps"),
               DW_CLIENT_HOLD=str(tmp_path / "client.stopped"), DW_CLIENT_WD_EVENTS=str(tmp_path / "wd.jsonl"),
               DW_CLIENT_BOOT_LOG=str(tmp_path / "boot.log"), DW_CLIENT_SMOKE_DIR=str(tmp_path))
    for k in ("DW_CLIENT_DEFAULT_TARGET", "DW_CLIENT_FORBID_TARGETS"):  # per-machine settings never leak in
        env.pop(k, None)
    r = type("Rig", (), {})()
    r.tmp, r.io, r.env, r.proc, r.game_log, r.mod_log = tmp_path, io, env, proc, game_log, mod_log
    r.runner = None

    def start(state):
        r.runner = FakeRunner(io, state)
        r.runner.start()
        return r.runner

    def ps(script, *args, timeout=180):
        cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(TOOLS / script), *args]
        return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)

    def events():
        p = tmp_path / "wd.jsonl"
        return [json.loads(x) for x in p.read_text(encoding="utf-8-sig").splitlines() if x.strip()] if p.exists() else []

    r.start, r.ps, r.events = start, ps, events
    yield r
    if r.runner:
        r.runner.stop_flag = True
    proc.kill()
    proc.wait(timeout=15)   # a fake client still dying would look like a hung one to the next test


def status(r):
    return json.loads((r.tmp / "state" / "client_status.json").read_text(encoding="utf-8-sig"))


# ------------------------------------------------------------------ boot_and_join
def test_boot_noop_when_in_world(rig):
    rig.start(in_world())
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet")
    assert p.returncode == 0, p.stdout + p.stderr
    assert rig.runner.calls == ["wd_boot_probe"]
    st = status(rig)
    assert st["state"] == "in_world" and st["last_boot"]["actions"] == []


def test_boot_full_sequence_from_menu(rig):
    rig.start(at_menu())
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet")
    assert p.returncode == 0, p.stdout + p.stderr
    acting = [c for c in rig.runner.calls if c != "wd_boot_probe"]
    assert acting == ["boot_pick_char", "boot_join_server", "boot_skip_intro", "boot_unpause"]
    assert status(rig)["last_boot"]["pawn"] == "BP_PlayerCharacter_C_1"
    log = (rig.tmp / "boot.log").read_text(encoding="utf-8-sig")
    assert PW not in log and "?p=aHVudGVy" not in log and "<redacted>" in log


def test_boot_starts_services_the_supervisor_did_not(rig):
    s = in_world()
    s["bridge"]["services"] = {n: {"state": "starting", "starts": 3} for n in ("chat", "vitals", "fed_reflex")}
    rig.start(s)
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet", "-ServiceWaitS", "1")
    assert p.returncode == 0, p.stdout + p.stderr
    assert [c for c in rig.runner.calls if c != "wd_boot_probe"] == [
        "boot_chat_start", "boot_sense_vitals_start", "boot_inv_reflex_start"]


def test_boot_reports_join_failure_from_game_log(rig):
    state = at_menu()
    state["logged_in"] = True
    runner = rig.start(state)
    orig = runner.handle

    def handle(name):  # the server rejects the join: the client stays at the menu, the log says why
        if name == "boot_join_server":
            with open(rig.game_log, "a", encoding="utf-8") as f:
                t = time.gmtime()
                f.write(time.strftime("[%Y.%m.%d-%H.%M.%S:000][  1]", t)
                        + "LogDominionPlayerControllerBase: Warning: Connection Failed for reason [DuplicateChar]\n")
            return {"ok": True, "result": {"sent": True}}
        return orig(name)
    runner.handle = handle
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet", "-Attempts", "1")
    assert p.returncode == 1
    assert "DuplicateChar" in status(rig)["last_boot"]["reason"]


def test_boot_refuses_while_held_unless_release(rig):
    rig.start(at_menu())
    (rig.tmp / "client.stopped").write_text("", encoding="utf-8")
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet")
    assert p.returncode == 3 and rig.runner.calls == []
    rig.runner.state.update(in_world())
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet", "-Release")
    assert p.returncode == 0 and not (rig.tmp / "client.stopped").exists()


def test_boot_dry_run_acts_on_nothing(rig):
    rig.start(at_menu())
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-DryRun")
    assert "DRY-RUN would: pick_char.lua" in p.stdout
    assert rig.runner.calls == ["wd_boot_probe"]


# ------------------------------------------------------------------ join targets (-Target, lease)
PW_DEV = "devpass-secret"


def loadmap(addr):
    t = time.gmtime()
    return time.strftime("[%Y.%m.%d-%H.%M.%S:000][  1]", t) + f"LogLoad: LoadMap: {addr}/Game/Maps/World/L_World?p=eHh4?pf=PC?cpx=1\n"


def dev_target(rig):
    (rig.io / "secrets" / "server_dev.txt").write_text(f"5.6.7.8:7777\n{PW_DEV}\n", encoding="utf-8")


def test_boot_target_switches_server(rig):
    dev_target(rig)
    with open(rig.game_log, "a", encoding="utf-8") as f:
        f.write(loadmap("1.2.3.4:7777"))
    runner = rig.start(in_world())
    orig = runner.handle

    def handle(name):
        if name == "boot_disconnect":
            runner.state.update(map="L_FrontEnd", screen=2, pawn=None, pos_m=None)
            return {"ok": True, "result": {"sent": True}}
        if name == "boot_join_server":
            with open(rig.game_log, "a", encoding="utf-8") as f:
                f.write(loadmap("5.6.7.8:7777"))
        return orig(name)
    runner.handle = handle
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet", "-Target", "dev")
    assert p.returncode == 0, p.stdout + p.stderr
    acting = [c for c in runner.calls if c != "wd_boot_probe"]
    assert acting[:2] == ["boot_disconnect", "boot_join_server"], acting
    assert runner.texts["boot_join_server"].startswith('local SECRETS_FILE = "server_dev.txt"')
    st = status(rig)["last_boot"]
    assert st["target"] == "dev" and st["joined"] == "5.6.7.8:7777"
    log = (rig.tmp / "boot.log").read_text(encoding="utf-8-sig")
    assert PW_DEV not in log and PW not in log


def test_boot_default_target_never_leaves_unknown_server(rig):
    rig.start(in_world())   # no LoadMap line: the joined server is unknown -> left alone
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet")
    assert p.returncode == 0 and rig.runner.calls == ["wd_boot_probe"]
    assert status(rig)["last_boot"]["target"] == "shockbyte"


def test_boot_lease_picks_target_until_it_expires(rig):
    dev_target(rig)
    with open(rig.game_log, "a", encoding="utf-8") as f:
        f.write(loadmap("1.2.3.4:7777"))
    rig.start(in_world())
    lease = rig.tmp / "state" / "client_target.json"
    future = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 600))
    lease.write_text(json.dumps({"target": "dev", "until": future, "by": "test"}), encoding="utf-8")
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-DryRun")
    assert "target=dev [lease" in p.stdout and "would: disconnect.lua" in p.stdout, p.stdout
    past = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 5))
    lease.write_text(json.dumps({"target": "dev", "until": past, "by": "test"}), encoding="utf-8")
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-DryRun")
    assert "target=shockbyte [default]" in p.stdout and "disconnect" not in p.stdout, p.stdout


def _switch_rig(rig, joined_after_join):
    runner = rig.start(in_world())
    orig = runner.handle

    def handle(name):
        if name == "boot_disconnect":
            runner.state.update(map="L_FrontEnd", screen=2, pawn=None, pos_m=None)
            return {"ok": True, "result": {"sent": True}}
        if name == "boot_join_server":
            with open(rig.game_log, "a", encoding="utf-8") as f:
                f.write(loadmap(joined_after_join))
            runner.state.update(map="L_World", screen=0, pawn="P", pos_m=[0, 0, 0])
        return orig(name)
    runner.handle = handle
    return runner


def test_default_target_dev_joins_with_the_dev_file_not_server_txt(rig):
    # live bug 2026-10-25 22:24: with default=dev the boot ran the static join_server.lua (server.txt =
    # Shockbyte) because it compared the target with the configurable default instead of 'shockbyte'
    dev_target(rig)
    with open(rig.game_log, "a", encoding="utf-8") as f:
        f.write(loadmap("1.2.3.4:7777"))
    (rig.tmp / "state" / "client_default_target.txt").write_text("dev" + "\n", encoding="utf-8")
    runner = _switch_rig(rig, "5.6.7.8:7777")
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet")
    assert p.returncode == 0, p.stdout + p.stderr
    assert runner.texts["boot_join_server"].startswith('local SECRETS_FILE = "server_dev.txt"'), runner.texts["boot_join_server"][:80]


def test_boot_leaves_a_forbidden_server_it_landed_on(rig):
    dev_target(rig)
    (rig.tmp / "state" / "client_forbid_targets.txt").write_text("shockbyte" + "\n", encoding="utf-8")
    runner = _switch_rig(rig, "1.2.3.4:7777")   # the join "lands" on server.txt's address (Shockbyte)
    with open(rig.game_log, "a", encoding="utf-8") as f:
        f.write(loadmap("9.9.9.9:7777"))
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet", "-Target", "dev", "-Attempts", "1")
    assert p.returncode != 0
    assert runner.calls.count("boot_disconnect") >= 2, runner.calls   # left the start server, then the forbidden one
    assert "JOINED A FORBIDDEN SERVER" in (rig.tmp / "boot.log").read_text(encoding="utf-8-sig")


def test_boot_refuses_a_forbidden_target_even_as_default(rig):
    # GOAL.md: during /goal shockbyte is forbidden; a boot (or a watchdog rejoin) must never join it
    rig.start(in_world())
    (rig.tmp / "state" / "client_forbid_targets.txt").write_text("# goal\nshockbyte\n", encoding="utf-8")
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet")
    assert p.returncode == 4, p.stdout + p.stderr
    assert "boot_join_server" not in rig.runner.calls
    assert "FORBIDDEN" in (rig.tmp / "boot.log").read_text(encoding="utf-8-sig")
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-Quiet", "-Target", "shockbyte")
    assert p.returncode == 4


def test_default_target_file_switches_default_and_dev_never_maps_to_server_txt(rig):
    dev_target(rig)
    with open(rig.game_log, "a", encoding="utf-8") as f:
        f.write(loadmap("1.2.3.4:7777"))
    rig.start(in_world())
    (rig.tmp / "state" / "client_default_target.txt").write_text("dev\n", encoding="utf-8")
    p = rig.ps("client_boot.ps1", "-NoLaunch", "-DryRun")
    assert "target=dev [default]" in p.stdout and "would: disconnect.lua" in p.stdout, p.stdout


# ------------------------------------------------------------------ watchdog (always -DryRun)
# memory thresholds 0: the real VM's free RAM must not leak memory_low events into these tests
WD = ("-DryRun", "-NoDevServer", "-NoNavOracle", "-PollS", "1", "-ProbeEveryS", "0", "-GraceS", "0", "-WarnFreeMB", "0", "-CritFreeMB", "0")


def names(evs):
    return [e["event"] for e in evs]


def test_watchdog_healthy_client_no_events(rig):
    rig.start(in_world())
    rig.ps("client_watchdog.ps1", *WD, "-Loops", "2")
    assert names(rig.events()) == ["watchdog_start"]
    assert status(rig)["state"] == "in_world"


def test_watchdog_client_gone(rig):
    rig.proc.kill()
    rig.proc.wait()
    rig.ps("client_watchdog.ps1", *WD, "-Loops", "1")
    assert names(rig.events())[1:3] == ["client_gone", "boot_start"]


def test_watchdog_hang_takes_stack_then_kills(rig):
    r = rig.start(in_world())
    r.answer = False  # game thread blocked: the runner never answers
    rig.ps("client_watchdog.ps1", *WD, "-Loops", "1", "-ProbeFails", "1")
    ev = names(rig.events())
    assert ev[1:] == ["client_hang", "hang_stack", "client_kill", "boot_start"], ev


def test_watchdog_disconnect_rejoins_without_kill(rig):
    rig.start(at_menu())
    rig.ps("client_watchdog.ps1", *WD, "-Loops", "4", "-DisconnectS", "1")
    evs = rig.events()
    assert "client_disconnected" in names(evs) and "client_kill" not in names(evs)
    boot = [e for e in evs if e["event"] == "boot_start"][0]
    assert boot["why"] == "disconnect" and boot["kill"] is False


def test_watchdog_crash_dump_and_rate_limit(rig):
    rig.start(in_world())
    p = subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(TOOLS / "client_watchdog.ps1"),
                          *WD, "-Loops", "8", "-MaxRestarts", "1"], env=rig.env)
    time.sleep(4)
    (rig.tmp / "dumps" / "crash_1.dmp").write_bytes(b"x")
    time.sleep(5)
    (rig.tmp / "dumps" / "crash_2.dmp").write_bytes(b"x")
    p.wait(timeout=120)
    ev = names(rig.events())
    assert ev.count("client_crash_dump") == 2, ev
    assert ev.count("boot_start") == 1 and "restart_rate_limited" in ev, ev


def test_watchdog_hold_pauses_recovery(rig):
    (rig.tmp / "client.stopped").write_text("", encoding="utf-8")
    rig.proc.kill()
    rig.proc.wait()
    rig.ps("client_watchdog.ps1", *WD, "-Loops", "2")
    ev = names(rig.events())
    assert "client_held" in ev and "boot_start" not in ev and "client_gone" not in ev


# ------------------------------------------------------------------ smoke test
def smoke_report(r):
    return json.loads(next(r.tmp.glob("client_smoke_*.json")).read_text(encoding="utf-8-sig"))


def test_smoke_read_only_by_default(rig):
    rig.start(in_world())
    p = rig.ps("client_smoke.ps1", "-NoBoot")
    assert p.returncode == 0, p.stdout + p.stderr
    res = {s["step"]: s["result"] for s in smoke_report(rig)["steps"]}
    assert res == {"boot": "pass", "services": "pass", "walk": "skip", "jump": "skip", "chat": "skip",
                   "inventory": "pass", "equip": "pass"}
    assert not any(c.startswith("smk_smoke_") for c in rig.runner.calls)  # nothing that moves or talks


def test_smoke_walk_and_jump_with_allow_move(rig):
    rig.start(in_world())
    p = rig.ps("client_smoke.ps1", "-NoBoot", "-AllowMove")
    assert p.returncode == 0, p.stdout + p.stderr
    res = {s["step"]: s["result"] for s in smoke_report(rig)["steps"]}
    assert res["walk"] == "pass" and res["jump"] == "pass"


def test_smoke_fails_when_not_in_world(rig):
    rig.start(at_menu())
    p = rig.ps("client_smoke.ps1", "-NoBoot")
    assert p.returncode == 1
    res = {s["step"]: s["result"] for s in smoke_report(rig)["steps"]}
    assert res["boot"] == "fail" and res["inventory"] == "skip"


def test_watchdog_treats_lingering_teardown_pause_as_degraded(rig):
    s = in_world()
    s["paused"] = True  # join/disconnect set _G.DW_PAUSE and nothing cleared it: every loop idles
    rig.start(s)
    rig.ps("client_watchdog.ps1", *WD, "-Loops", "4", "-DisconnectS", "1")
    assert "boot_start" in names(rig.events())


def test_watchdog_rejoins_target_when_on_wrong_server(rig):
    dev_target(rig)   # no lease: the target is shockbyte (1.2.3.4:7777), but the client sits on dev
    with open(rig.game_log, "a", encoding="utf-8") as f:
        f.write(loadmap("5.6.7.8:7777"))
    rig.start(in_world())
    p = rig.ps("client_watchdog.ps1", *WD, "-Loops", "2", "-WrongServerS", "0")
    assert p.returncode == 0, p.stdout + p.stderr
    evs = rig.events()
    wrong = [e for e in evs if e["event"] == "wrong_server"]
    assert wrong and wrong[0]["on"] == "5.6.7.8:7777" and wrong[0]["target"] == "shockbyte", names(evs)
    assert any(e["event"] == "boot_start" and e["why"] == "wrong_server" for e in evs)
    assert PW_DEV not in json.dumps(evs)


def test_watchdog_leaves_client_alone_on_target(rig):
    with open(rig.game_log, "a", encoding="utf-8") as f:
        f.write(loadmap("1.2.3.4:7777"))
    rig.start(in_world())
    p = rig.ps("client_watchdog.ps1", *WD, "-Loops", "2", "-WrongServerS", "0")
    assert p.returncode == 0, p.stdout + p.stderr
    assert "wrong_server" not in names(rig.events())

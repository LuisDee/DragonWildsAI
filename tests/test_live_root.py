"""One live body per VM, whichever working tree the code runs from (incident 2026-11-18 06:48Z).

A subagent's tests in a git worktree reached tools/job_run.cmd_window for real: the worktree's live lock was its own
logs/state, so it did not see the main tree's lock, launched the client (steam -applaunch) and moved the game's
UE4SS.log into the worktree while a window was starting in the main tree.

(1) Every piece of state that must be single per VM (the live lock and its queue, the park marker, the hold files,
    logs/state, client_io, the job_run stop file, the UE4SS archive dir) resolves to the MAIN working tree:
    brain/paths.LIVE_ROOT (git rev-parse --git-common-dir, or DW_LIVE_ROOT), and the same in tools/config.ps1.
(2) What launches or drives live things refuses under pytest unless the test passed a fake, and from a worktree
    unless DW_LIVE_OK=1 (tools/live_guard.py; Assert-LiveAllowed in tools/config.ps1).

Nothing here may reach a real launcher: the Python guard tests run with subprocess spawning replaced by a tripwire,
and the PowerShell ones point Steam at a fake that only writes a marker file, behind a hold file.
"""
from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path

import pytest

from brain import paths

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"


def _git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def _main_tree_by_listing() -> Path:
    """The main working tree, by another route than the code's: `git worktree list` lists it first."""
    first = _git("worktree", "list", "--porcelain", cwd=ROOT).splitlines()[0]
    return Path(first.split(" ", 1)[1]).resolve()


def same(a: Path, b: Path) -> bool:
    return os.path.normcase(str(Path(a).resolve())) == os.path.normcase(str(Path(b).resolve()))


def under(p: Path, root: Path) -> bool:
    return os.path.normcase(str(Path(p).resolve())).startswith(os.path.normcase(str(Path(root).resolve())) + os.sep)


# ------------------------------------------------------------------ (1) the live root
def test_main_tree_of_a_worktree_is_the_main_tree(tmp_path):
    main = tmp_path / "main"
    main.mkdir()
    _git("init", "-q", cwd=main)
    _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init", cwd=main)
    wt = tmp_path / "wt"
    _git("worktree", "add", "-q", "--detach", str(wt), cwd=main)
    assert same(paths.main_tree(main), main)
    assert same(paths.main_tree(wt), main)
    assert same(paths.main_tree(tmp_path / "not_a_repo"), tmp_path / "not_a_repo")  # no git: the tree itself


def test_live_root_is_the_main_tree_and_the_env_var_wins(monkeypatch, tmp_path):
    assert same(paths.LIVE_ROOT, _main_tree_by_listing())
    assert paths.IN_WORKTREE == (not same(paths.REPO_ROOT, paths.LIVE_ROOT))
    monkeypatch.setenv("DW_LIVE_ROOT", str(tmp_path))
    assert same(paths.live_root(), tmp_path)


def test_every_single_per_vm_path_is_under_the_live_root(monkeypatch):
    from evals.bench import devchar, devtarget
    from tools import (chat_ladder, client_park, client_slot, job_run, live_lock, live_queue, quest_clone,
                       scenario_run, world_snapshot)
    live = paths.LIVE_ROOT
    for p in (live_lock.LOCK, live_lock.QUEUE, live_lock.AUDIT, live_lock.PRIORITY, client_park.PARK, client_park.STAY,
              client_slot.STATE, job_run.STOP_FILE, live_queue.STATE_FILE, live_queue.LOCK_FILE, live_queue.CLIENT_STATUS,
              *live_queue.HOLD_FILES, *chat_ladder.HOLD_FILES, chat_ladder.CLIENT_BRIDGE, chat_ladder.NAV_ALIVE,
              world_snapshot.HOLD_FILE, devchar.NAME_FILE, quest_clone.CHECKPOINT_DIR, quest_clone.KEEP_DIR,
              quest_clone.PARK_DIR, quest_clone.IDS_PROBE, *scenario_run.HOLD_FILES):
        assert under(p, live), p
    assert devtarget.forbidden_addresses.__defaults__ and all(under(d, live) for d in devtarget.forbidden_addresses.__defaults__)
    for var in ("DW_STATE_DIR", "DW_BRIDGE_DIR"):
        monkeypatch.delenv(var, raising=False)
    assert same(paths.state_dir(), live / "logs" / "state")
    assert same(paths.bridge_dir("client"), live / "client_io" / "bridge")
    assert same(paths.bridge_dir("server"), live / "bridge_io")


# ------------------------------------------------------------------ (2) the guard, Python side
@pytest.fixture
def no_spawn(monkeypatch):
    """A tripwire: any process start fails the test instead of reaching Steam, the game or a server."""
    def trip(*a, **k):
        raise AssertionError(f"a live process start was reached: {a[:1]}")
    for name in ("run", "Popen", "call", "check_call", "check_output"):
        monkeypatch.setattr(subprocess, name, trip)
    monkeypatch.setattr(os, "system", trip)
    monkeypatch.setattr(os, "startfile", trip, raising=False)


def test_why_refused_rules():
    from tools import live_guard as g
    main, wt = Path("C:/m"), Path("C:/m/.claude/worktrees/x")
    assert "under pytest" in g.why_refused("x", env={"PYTEST_CURRENT_TEST": "t"}, repo=main, live=main)
    assert "under pytest" in g.why_refused("x", env={"PYTEST_CURRENT_TEST": "t", "DW_LIVE_OK": "1"}, repo=main, live=main)
    assert g.why_refused("x", fake=True, env={"PYTEST_CURRENT_TEST": "t"}, repo=wt, live=main) is None
    assert "DW_LIVE_OK" in g.why_refused("x", env={}, repo=wt, live=main)
    assert g.why_refused("x", env={"DW_LIVE_OK": "1"}, repo=wt, live=main) is None
    assert g.why_refused("x", env={}, repo=main, live=main) is None


def test_job_run_window_refuses_under_pytest_without_a_fake_window(no_spawn, capsys):
    """The incident: cmd_window reached with the real lock window behind it."""
    from tools import job_run, live_guard
    rc = job_run.cmd_window(argparse.Namespace(confirm=True, job="L2"), None)
    assert rc == live_guard.REFUSED_RC
    assert "under pytest" in capsys.readouterr().out


def test_job_run_window_runs_with_a_fake_window(monkeypatch):
    from tools import live_guard
    from tools import quest_run as q
    assert live_guard.is_live(q.clone_window)
    monkeypatch.setattr(q, "clone_window", lambda *a, **k: None)
    assert not live_guard.is_live(q.clone_window)


def test_the_real_lock_window_refuses_under_pytest(no_spawn, tmp_path):
    from tools import live_guard
    from tools import quest_run as q
    with pytest.raises(live_guard.LiveRefused):
        q.clone_window(1.0, {}, tmp_path / "w.jsonl")


def test_claiming_the_real_lock_refuses_under_pytest_and_a_temp_lock_does_not(no_spawn, monkeypatch, tmp_path):
    from tools import live_guard, live_lock

    def no_open(*a, **k):
        raise AssertionError("the real live lock file was about to be written")
    monkeypatch.setattr(live_lock, "_audit", lambda *a, **k: None)
    real_open = os.open
    monkeypatch.setattr(os, "open", no_open)
    with pytest.raises(live_guard.LiveRefused):
        live_lock.try_claim("test")
    monkeypatch.setattr(os, "open", real_open)
    assert live_lock.try_claim("test", path=tmp_path / "live_owner.txt")


def test_unpark_without_a_fake_boot_refuses(no_spawn, tmp_path):
    from tools import client_park
    mark = tmp_path / "client_park.json"
    mark.write_text('{"mode": "menu", "since": "x"}', encoding="utf-8")
    assert client_park.unpark(path=mark).startswith("unpark refused")
    assert client_park.unpark(boot=lambda: 0, path=mark).startswith("unparked")


def test_devchar_powershell_refuses(no_spawn):
    from evals.bench import devchar
    from tools import live_guard
    with pytest.raises(live_guard.LiveRefused):
        devchar.powershell("client_boot.ps1", "-Release", "-Target", "dev")


def test_world_restore_on_the_real_saves_refuses(no_spawn, tmp_path):
    from tools import world_snapshot as ws
    # running=True: even without the guard the restore has a blocker and cannot touch the real world
    st = ws.Store(root=tmp_path / "snaps", hold_file=tmp_path / "held", running=lambda: True, lock=lambda: None,
                  build=lambda: "1", joins=lambda: ([], None))
    with pytest.raises(ws.Refused, match="under pytest"):
        st.restore("base")


def test_brain_start_and_ps_launchers_refuse(no_spawn):
    from tools import chat_ladder, live_guard, m1_run
    with pytest.raises(live_guard.LiveRefused):
        chat_ladder.start_brain(argparse.Namespace(world="dev", usd=0.1), 0.0)
    with pytest.raises(live_guard.LiveRefused):
        m1_run.ps("start_server.ps1")


# ------------------------------------------------------------------ PowerShell side
def _ps(script: str, env: dict, timeout: float = 120) -> subprocess.CompletedProcess:
    return subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                          capture_output=True, text=True, env=env, timeout=timeout)


def _clean_env(**extra) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("DW_")}
    env.update(extra)
    return env


def test_ps_live_root_and_live_paths_are_the_main_tree():
    env = _clean_env(PYTEST_CURRENT_TEST="x")
    out = _ps(f". '{TOOLS / 'client_lib.ps1'}'; "
              "@($RepoRoot, $LiveRoot, $ClientStateDir, $ClientIo, $ClientModLog, $ClientArchiveDir, $ClientBridgeDir, "
              "$BridgeDir, $ModLogDir) + $ClientHoldFiles | ForEach-Object { $_ }", env)
    assert out.returncode == 0, out.stderr
    rows = [Path(r) for r in out.stdout.splitlines() if r.strip()]
    repo, live, *rest = rows
    assert same(repo, ROOT) and same(live, _main_tree_by_listing())
    assert all(under(p, live) for p in rest), rest


def test_ps_steam_launch_refuses_under_pytest(tmp_path):
    marker = tmp_path / "launched.txt"
    fake = tmp_path / "fake_steam.cmd"  # never the real steam.exe: even an unguarded launch only writes a marker
    fake.write_text(f'@echo off\r\necho %* > "{marker}"\r\n', encoding="utf-8")
    env = _clean_env(PYTEST_CURRENT_TEST="x", DW_STEAM_EXE=str(fake))
    out = _ps(f". '{TOOLS / 'client_lib.ps1'}'; Start-ClientProcess; 'after'", env)
    assert not marker.exists()
    assert out.returncode == 9 and "after" not in out.stdout, (out.stdout, out.stderr)


def test_ps_client_boot_refuses_under_pytest_without_a_fake_client(tmp_path):
    hold = tmp_path / "client.stopped"
    hold.write_text("", encoding="utf-8")  # even an unguarded boot leaves a held client alone (exit 3)
    marker = tmp_path / "launched.txt"
    fake = tmp_path / "fake_steam.cmd"
    fake.write_text(f'@echo off\r\necho %* > "{marker}"\r\n', encoding="utf-8")
    env = _clean_env(PYTEST_CURRENT_TEST="x", DW_STEAM_EXE=str(fake), DW_CLIENT_HOLD=str(hold),
                     DW_CLIENT_STATE_DIR=str(tmp_path / "state"), DW_CLIENT_IO=str(tmp_path / "io"),
                     DW_CLIENT_BOOT_LOG=str(tmp_path / "boot.log"), DW_CLIENT_STEAM="logged_in")
    p = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(TOOLS / "client_boot.ps1"),
                        "-NoLaunch", "-Quiet"], capture_output=True, text=True, env=env, timeout=120)
    assert p.returncode == 9 and "under pytest" in p.stdout, (p.returncode, p.stdout, p.stderr)
    assert not marker.exists()


GUARDED_PS = ("client_boot.ps1", "stop_client.ps1", "start_server.ps1", "stop_server.ps1", "client_watchdog.ps1",
              "start_client_watchdog.ps1", "start_brain.ps1", "watchdog.ps1", "start_watchdog.ps1")


@pytest.mark.parametrize("script", GUARDED_PS)
def test_ps_live_scripts_assert_before_acting(script):
    """Static (running these unguarded would start the real server or client): the guard is the first statement
    after the libraries are dot-sourced."""
    lines = [ln.strip() for ln in (TOOLS / script).read_text(encoding="utf-8").splitlines()]
    i = max(n for n, ln in enumerate(lines) if ln.startswith(". \"$PSScriptRoot\\"))
    nxt = next(ln for ln in lines[i + 1:] if ln and not ln.startswith("#"))
    assert nxt.startswith("Assert-LiveAllowed"), (script, nxt)

"""The guard on everything that launches or drives the ONE live client or dev server on this VM (Steam -applaunch,
client_boot, start_server, a job_run / quest_run lock window, a world restore, a brain start, the live lock's claim).

Refused, with the reason:
  * under pytest (PYTEST_CURRENT_TEST, which pytest sets while a test runs and its subprocesses inherit), unless the
    test passed a fake for the live part (fake=True at the call; for a decorated entry point, monkeypatching it is the
    fake). DW_LIVE_OK does not lift this: a test never drives the live body.
  * from a git worktree (brain/paths.IN_WORKTREE) unless DW_LIVE_OK=1: a worktree is a subagent's sandbox, and its
    code reaching the live client is the incident of 2026-11-18 06:48Z (a worktree's job_run tests launched the
    client while a window was starting in the main tree).

Default-deny with an explicit opt-in, as pytest-socket does for the network (--disable-socket, enable per test).
The PowerShell side is Assert-LiveAllowed in tools/config.ps1 (same rules, exit REFUSED_RC).
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Callable, Mapping

from brain import paths

REFUSED_RC = 9  # the exit code of a refused live action (tools/config.ps1 Assert-LiveAllowed exits the same)


class LiveRefused(RuntimeError):
    """A live action refused by this guard; nothing was started."""


def _same(a: Path, b: Path) -> bool:
    return os.path.normcase(os.path.abspath(str(a))) == os.path.normcase(os.path.abspath(str(b)))


def why_refused(what: str, fake: bool = False, env: Mapping[str, str] | None = None,
                repo: Path | None = None, live: Path | None = None) -> str | None:
    """None when `what` may run; else the reason it may not."""
    if fake:
        return None
    env = os.environ if env is None else env
    if env.get("PYTEST_CURRENT_TEST"):
        return (f"refused under pytest ({env['PYTEST_CURRENT_TEST']}): {what} drives the live game; a test passes a "
                f"fake for it (tools/live_guard.py)")
    repo = paths.REPO_ROOT if repo is None else repo
    live = paths.LIVE_ROOT if live is None else live
    if not _same(repo, live) and env.get("DW_LIVE_OK") != "1":
        return (f"refused: {what} from the worktree {repo} (the live tree is {live}, one client per VM); set "
                f"DW_LIVE_OK=1 to drive the live client from here")
    return None


def check(what: str, fake: bool = False) -> None:
    """Raise LiveRefused when `what` may not run."""
    why = why_refused(what, fake)
    if why:
        raise LiveRefused(why)


def mark_live(fn: Callable, what: str) -> Callable:
    """Mark the real `fn` as a live part, so a caller can tell it from a test's fake put in its place (is_live)."""
    fn.dw_live_entry = what
    return fn


def is_live(fn) -> bool:
    """Is `fn` a real live part (not a test's fake put in its place)?"""
    return getattr(fn, "dw_live_entry", None) is not None

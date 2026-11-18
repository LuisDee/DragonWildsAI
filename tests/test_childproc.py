"""brain/childproc.py: harness children get a console of their own (CREATE_NO_WINDOW) so they survive a lost console.

Incident 2026-11-18 08:20Z: the window's bash wrapper was reaped, job_run lived on, and every powershell it started
died with 0xC0000142 (no console to attach). Fakes only: a fake Popen records what CreateProcess would be given."""
from __future__ import annotations

import subprocess
import sys

import pytest

from brain import childproc


class FakePopen:
    seen: list[tuple[list, dict]] = []

    def __init__(self, cmd, **kw):
        FakePopen.seen.append((cmd, kw))
        self.args, self.returncode, self.pid = cmd, 0, 4242

    def communicate(self, input=None, timeout=None):
        return ("out", "err")

    def poll(self):
        return 0

    def wait(self, timeout=None):
        return 0

    def kill(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


@pytest.fixture
def fake(monkeypatch):
    FakePopen.seen = []
    monkeypatch.setattr(subprocess, "Popen", FakePopen)
    return FakePopen.seen


def test_run_passes_no_window_and_keeps_capture(fake, monkeypatch):
    monkeypatch.setattr(childproc.os, "name", "nt")
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools/client_boot.ps1", "-Quiet"]
    p = childproc.run(cmd, capture_output=True, text=True, timeout=5)
    assert (p.returncode, p.stdout, p.stderr) == (0, "out", "err")
    (got, kw), = fake
    assert got == cmd
    assert kw["creationflags"] & 0x08000000  # CREATE_NO_WINDOW
    assert kw["stdout"] == subprocess.PIPE and kw["stderr"] == subprocess.PIPE  # capture as the caller asked
    assert kw["stdin"] == subprocess.DEVNULL  # never the lost console's input
    assert kw["text"] is True


def test_popen_keeps_caller_flags_handles_and_env(fake, monkeypatch, tmp_path):
    monkeypatch.setattr(childproc.os, "name", "nt")
    log = open(tmp_path / "brain.log", "a", encoding="utf-8")
    try:
        childproc.popen(["python", "-m", "brain.run_live"], cwd=str(tmp_path), env={"A": "1"}, stdout=log,
                        stderr=subprocess.STDOUT, creationflags=0x200)  # CREATE_NEW_PROCESS_GROUP stays
    finally:
        log.close()
    (_, kw), = fake
    assert kw["creationflags"] == 0x200 | 0x08000000
    assert kw["stdout"] is log and kw["stderr"] == subprocess.STDOUT
    assert kw["env"] == {"A": "1"} and kw["cwd"] == str(tmp_path)


def test_caller_stdin_or_input_wins(fake, monkeypatch):
    monkeypatch.setattr(childproc.os, "name", "nt")
    childproc.run(["git", "apply"], input="patch", capture_output=True, text=True)
    childproc.popen(["cat"], stdin=subprocess.PIPE)
    (_, a), (_, b) = fake
    assert a["stdin"] == subprocess.PIPE  # run() turns input= into a pipe; no DEVNULL forced on it
    assert b["stdin"] == subprocess.PIPE


@pytest.mark.parametrize("own", [0x10, 0x8])  # CREATE_NEW_CONSOLE, DETACHED_PROCESS: the caller already chose
def test_explicit_console_choice_is_kept(own):
    kw = childproc.child_kwargs({"creationflags": own}, nt=True)
    assert kw["creationflags"] == own  # CREATE_NO_WINDOW is ignored with these (Microsoft Learn), so not added


def test_not_windows_no_creationflags():
    kw = childproc.child_kwargs({"capture_output": True}, nt=False)
    assert "creationflags" not in kw and kw["stdin"] == subprocess.DEVNULL


def test_routed_modules_use_the_helper():
    """Every harness launch of a console program in these modules goes through childproc (live_lock's `run --`
    pass-through and steam.exe, a GUI program, are the documented exceptions)."""
    import re
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    files = [*root.glob("tools/*.py"), *root.glob("evals/bench/*.py"), *root.glob("brain/*.py")]
    bad = []
    for f in files:
        if f.name in ("childproc.py", "live_lock.py"):
            continue
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if re.search(r"\bsubprocess\.(run|Popen|call|check_output|check_call)\(", line) and "[exe" not in line:
                bad.append(f"{f.relative_to(root)}:{n}")
    assert bad == []


@pytest.mark.skipif(sys.platform != "win32", reason="CREATE_NO_WINDOW is Windows only")
def test_real_child_output_still_captured():
    """A real (offline) console child under CREATE_NO_WINDOW: captured output comes back unchanged."""
    p = childproc.run([sys.executable, "-c", "import sys; print('hi'); print('err', file=sys.stderr)"],
                      capture_output=True, text=True, timeout=60)
    assert (p.returncode, p.stdout.strip(), p.stderr.strip()) == (0, "hi", "err")

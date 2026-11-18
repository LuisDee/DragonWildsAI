"""Child processes that survive a lost console: every harness launch of a console program goes through here.

Incident 2026-11-18 08:20Z: Claude Code's memory reaper killed a window's bash wrapper. Its python job_run kept
running, but every powershell it then started (client_boot.ps1) died at once with exit 3221225794 = 0xC0000142,
STATUS_DLL_INIT_FAILED. By default a console child inherits its parent's console (Microsoft Learn, "Process Creation
Flags": CREATE_NEW_CONSOLE "instead of inheriting its parent's console (the default)"); that console was the wrapper's
pseudoconsole, gone with it, and a console client that cannot attach to its console fails its DLL initialisation with
exactly 0xC0000142 (the ConPTY repro https://gist.github.com/asmichi/a37622e5cb7117e2870df68f750cb69b).

So on Windows each child gets CREATE_NO_WINDOW (0x08000000: "a console application that is being run without a console
window"): a fresh console of its own, no window, nothing inherited to lose. Flag ignored for GUI programs.
stdin defaults to DEVNULL (unless the caller passes stdin or input): with any std handle given, Python hands the child
all three explicitly (STARTF_USESTDHANDLES), so an uncaptured stdout/stderr still goes where the parent's goes instead
of into the hidden console, and no child reads a dead console's input. Capture (stdout/stderr) is the caller's, unchanged.

A child started this way does not share the parent's console, so Ctrl+C in that console no longer reaches it: stop
long-running children by pid (taskkill /T), as the harness already does.
"""
from __future__ import annotations

import os
import subprocess

CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
_OWN_CONSOLE = getattr(subprocess, "CREATE_NEW_CONSOLE", 0x10) | getattr(subprocess, "DETACHED_PROCESS", 0x8)


def child_kwargs(kw: dict, nt: bool | None = None) -> dict:
    """The caller's keyword arguments plus a console of the child's own (Windows) and stdin from NUL by default."""
    out = dict(kw)
    if "stdin" not in out and "input" not in out:
        out["stdin"] = subprocess.DEVNULL
    if os.name == "nt" if nt is None else nt:
        flags = int(out.get("creationflags") or 0)
        if not flags & _OWN_CONSOLE:  # the caller already chose a console (CREATE_NO_WINDOW is ignored with these)
            flags |= CREATE_NO_WINDOW
        out["creationflags"] = flags
    return out


def run(cmd, **kw) -> subprocess.CompletedProcess:
    """subprocess.run with a console of the child's own."""
    return subprocess.run(cmd, **child_kwargs(kw))


def popen(cmd, **kw) -> subprocess.Popen:
    """subprocess.Popen with a console of the child's own."""
    return subprocess.Popen(cmd, **child_kwargs(kw))

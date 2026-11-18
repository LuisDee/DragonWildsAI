"""Default runtime locations. All are overridable with environment variables so
nothing depends on a Windows path layout (the server may move to Linux)."""
from __future__ import annotations

import os
import subprocess
from . import childproc
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def main_tree(repo: Path = REPO_ROOT) -> Path:
    """The main working tree of the repository `repo` belongs to; `repo` itself when it is the main tree, or when git
    cannot say. A linked worktree (git worktree add, e.g. a subagent's .claude/worktrees/agent-*) has its own GIT_DIR,
    but `git rev-parse --git-common-dir` names the main tree's .git (git-worktree(1), "Details")."""
    try:
        out = childproc.run(["git", "-C", str(repo), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return Path(repo)
    common = Path(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else None
    if common is None or common.name.lower() != ".git":  # a bare repo or a submodule: no main tree to point at
        return Path(repo)
    return common.parent.resolve()


def live_root() -> Path:
    """Where the state lives that must be single per VM (ONE game client, ONE dev server): the live lock and its queue,
    logs/state, client_io (the client mod reads C:/gameserver/client_io), the hold files, the park marker, the job_run
    stop file, the client's log archive. DW_LIVE_ROOT wins; else the main working tree, so code run from a worktree
    sees the main tree's lock, not an empty one of its own (incident 2026-11-18 06:48Z). Code and data stay REPO_ROOT."""
    value = os.environ.get("DW_LIVE_ROOT")
    return Path(value) if value else main_tree(REPO_ROOT)


LIVE_ROOT = live_root()
IN_WORKTREE = os.path.normcase(str(REPO_ROOT.resolve())) != os.path.normcase(str(LIVE_ROOT.resolve()))


def _env_path(var: str, default: Path) -> Path:
    value = os.environ.get(var)
    return Path(value) if value else default


def log_dir() -> Path:
    return _env_path("DW_LOG_DIR", REPO_ROOT / "logs")


def state_dir() -> Path:
    # Task tree, progress log and notes.json. Lives under logs/ (gitignored) by default.
    return _env_path("DW_STATE_DIR", LIVE_ROOT / "logs" / "state")  # single per VM


def skills_dir() -> Path:
    # Learned skills, one readable JSON per skill under <dir>/<world_guid>/ (git-tracked, design 19).
    return _env_path("DW_SKILLS_DIR", REPO_ROOT / "data" / "skills")


# Which body the brain drives (BRIDGE_PROTOCOL.md "Client endpoint"):
#   server = the server-side puppet mod (mod/), files in bridge_io/
#   client = Claude's own game client (client_mod/, route R2), files in client_io/bridge/
BODY_ENV = "DW_BODY"
BODIES = ("server", "client")
_DEFAULT_BRIDGE_DIRS = {"server": LIVE_ROOT / "bridge_io", "client": LIVE_ROOT / "client_io" / "bridge"}


def body_kind(value: str | None = None) -> str:
    kind = (value or os.environ.get(BODY_ENV) or "server").strip().lower()
    if kind not in BODIES:
        raise ValueError(f"{BODY_ENV} must be one of {BODIES}, not {kind!r}")
    return kind


def bridge_dir(body: str | None = None) -> Path:
    """DW_BRIDGE_DIR wins; otherwise the default directory of the selected body."""
    return _env_path("DW_BRIDGE_DIR", _DEFAULT_BRIDGE_DIRS[body_kind(body)])

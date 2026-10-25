"""Default runtime locations. All are overridable with environment variables so
nothing depends on a Windows path layout (the server may move to Linux)."""
from __future__ import annotations

import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def _env_path(var: str, default: Path) -> Path:
    value = os.environ.get(var)
    return Path(value) if value else default


def log_dir() -> Path:
    return _env_path("DW_LOG_DIR", REPO_ROOT / "logs")


def state_dir() -> Path:
    # Task tree, progress log and notes.json. Lives under logs/ (gitignored) by default.
    return _env_path("DW_STATE_DIR", REPO_ROOT / "logs" / "state")


def skills_dir() -> Path:
    # Learned skills, one readable JSON per skill under <dir>/<world_guid>/ (git-tracked, design 19).
    return _env_path("DW_SKILLS_DIR", REPO_ROOT / "data" / "skills")


# Which body the brain drives (BRIDGE_PROTOCOL.md "Client endpoint"):
#   server = the server-side puppet mod (mod/), files in bridge_io/
#   client = Claude's own game client (client_mod/, route R2), files in client_io/bridge/
BODY_ENV = "DW_BODY"
BODIES = ("server", "client")
_DEFAULT_BRIDGE_DIRS = {"server": REPO_ROOT / "bridge_io", "client": REPO_ROOT / "client_io" / "bridge"}


def body_kind(value: str | None = None) -> str:
    kind = (value or os.environ.get(BODY_ENV) or "server").strip().lower()
    if kind not in BODIES:
        raise ValueError(f"{BODY_ENV} must be one of {BODIES}, not {kind!r}")
    return kind


def bridge_dir(body: str | None = None) -> Path:
    """DW_BRIDGE_DIR wins; otherwise the default directory of the selected body."""
    return _env_path("DW_BRIDGE_DIR", _DEFAULT_BRIDGE_DIRS[body_kind(body)])

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


def bridge_dir() -> Path:
    return _env_path("DW_BRIDGE_DIR", REPO_ROOT / "bridge_io")

"""Per-world memory (design section 15): facts never leak between worlds.

Everything the brain remembers about a world lives under ``<state>/worlds/<world_guid>/``:
notes.json, places.json, reflex_rules.json (a snapshot of the body's standing orders), task_tree.json
and progress.jsonl. Learned skills live under ``data/skills/<world_guid>/`` (git-tracked, design 19).

The world id is the save's ``WorldSaveGuid``. Sources, in order:
1. ``get_state`` data: ``world_guid`` or ``world.guid`` / ``world.world_guid`` (a body extender);
2. the body's ``world_info`` probe (``data.world_guid``);
3. the ``DW_WORLD_GUID`` environment variable (manual override);
4. ``"default"``.

Migration: files from before per-world memory (``<state>/notes.json`` etc.) move into the first
world resolved. A ``default`` folder made while the body could not name its world is adopted once
by the first real GUID (only when that world has no folder yet), so nothing learned is lost.
"""
from __future__ import annotations

import os
import re
import shutil
import time
from pathlib import Path

from .interface import GameInterface

DEFAULT = "default"
ENV = "DW_WORLD_GUID"
LEGACY_FILES = ("notes.json", "places.json", "reflex_rules.json", "task_tree.json", "progress.jsonl")


def sanitize(guid: object) -> str | None:
    """A safe folder name (hex GUIDs stay as they are), or None if nothing usable."""
    if not isinstance(guid, str):
        return None
    s = re.sub(r"[^A-Za-z0-9_-]", "", guid.strip())[:64]
    return s or None


def _from_state(state: dict | None) -> str | None:
    if not isinstance(state, dict):
        return None
    w = state.get("world")
    return sanitize(state.get("world_guid")) or (
        sanitize(w.get("guid") or w.get("world_guid")) if isinstance(w, dict) else None)


def resolve_world_guid(game: GameInterface | None = None, state: dict | None = None) -> tuple[str, str]:
    """(guid, source) where source is one of state, world_info, env, default."""
    if guid := _from_state(state):
        return guid, "state"
    if game is not None:
        if state is None:
            try:
                res = game.get_state()
                if res.get("ok") and (guid := _from_state(res.get("data"))):
                    return guid, "state"
            except Exception:  # the body may be half up; fall through
                pass
        try:
            res = game.world_info()
            if res.get("ok") and (guid := sanitize((res.get("data") or {}).get("world_guid"))):
                return guid, "world_info"
        except Exception:
            pass
    if guid := sanitize(os.environ.get(ENV)):
        return guid, "env"
    return DEFAULT, "default"


def _move_into(src: Path, dst: Path) -> list[str]:
    moved = []
    dst.mkdir(parents=True, exist_ok=True)
    for f in sorted(src.iterdir()):
        target = dst / f.name
        if target.exists():
            continue
        shutil.move(str(f), str(target))
        moved.append(f.name)
    return moved


def adopt_default(root: Path, guid: str) -> list[str]:
    """Move ``root/default`` into ``root/<guid>`` once, if that world has no folder yet."""
    src, dst = root / DEFAULT, root / guid
    if guid == DEFAULT or not src.is_dir() or dst.exists():
        return []
    moved = _move_into(src, dst)
    (dst / "ADOPTED_FROM_DEFAULT.txt").write_text(
        f"{time.strftime('%Y-%m-%d %H:%M:%S')}: adopted {moved} from {src}\n", encoding="utf-8")
    try:
        src.rmdir()
    except OSError:
        pass
    return moved


def prepare_state_dir(state_root: Path, guid: str) -> tuple[Path, list[str]]:
    """The world's state folder, with legacy root files migrated into it. Returns (dir, migrated)."""
    state_root = Path(state_root)
    worlds = state_root / "worlds"
    migrated = [f"default/{n}" for n in adopt_default(worlds, guid)]
    target = worlds / guid
    target.mkdir(parents=True, exist_ok=True)
    for name in LEGACY_FILES:
        old = state_root / name
        if old.is_file() and not (target / name).exists():
            shutil.move(str(old), str(target / name))
            migrated.append(name)
    if migrated:
        with (target / "MIGRATION.txt").open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}: moved {migrated} from {state_root}\n")
    return target, migrated


def prepare_skills_dir(skills_root: Path, guid: str) -> Path:
    skills_root = Path(skills_root)
    adopt_default(skills_root, guid)
    d = skills_root / guid
    d.mkdir(parents=True, exist_ok=True)
    return d

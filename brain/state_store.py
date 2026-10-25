"""Shared state store: task tree with done flags, progress log, notes.json, skill registry.

Everything that must survive a restart lives in files under one directory
(design principle 5). Files:
  task_tree.json   current goal and its tasks (rewritten atomically)
  progress.jsonl   append-only log of what happened
  notes.json       long-term facts written via remember()
"""
from __future__ import annotations

import json
import os
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field

from . import paths
from .interface import TOOLS

TaskStatus = Literal["pending", "running", "done", "failed", "skipped"]
GoalStatus = Literal["active", "done", "stuck", "interrupted"]


class Task(BaseModel):
    id: str = Field(default_factory=lambda: uuid.uuid4().hex[:8])
    skill: str
    args: dict[str, Any] = {}
    done: bool = False
    status: TaskStatus = "pending"
    attempts: int = 0
    last_reason: str | None = None


class TaskTree(BaseModel):
    goal: str
    status: GoalStatus = "active"
    tasks: list[Task] = []
    replans: int = 0

    def next_task(self) -> Task | None:
        return next((t for t in self.tasks if t.status in ("pending", "running")), None)


# --------------------------------------------------------------------------- skills


@dataclass(frozen=True)
class Skill:
    name: str
    description: str
    args_model: type[BaseModel]


class SkillRegistry:
    """Skills the Planner may use. Only verified skills should be registered."""

    def __init__(self) -> None:
        self._skills: dict[str, Skill] = {}

    def register(self, name: str, description: str | None = None, args_model: type[BaseModel] | None = None) -> None:
        model, default_desc = TOOLS.get(name, (args_model, ""))
        if args_model is None and model is None:
            raise ValueError(f"no args model for skill {name!r}")
        self._skills[name] = Skill(name, description or default_desc, args_model or model)

    def __contains__(self, name: str) -> bool:
        return name in self._skills

    def names(self) -> list[str]:
        return list(self._skills)

    def get(self, name: str) -> Skill:
        return self._skills[name]

    def validate(self, name: str, args: dict) -> dict:
        return self._skills[name].args_model.model_validate(args).model_dump()

    def describe(self) -> list[dict]:
        out = []
        for s in self._skills.values():
            schema = s.args_model.model_json_schema()
            out.append({"name": s.name, "description": s.description, "args": schema.get("properties", {}),
                        "required": schema.get("required", [])})
        return out

    @classmethod
    def default(cls) -> "SkillRegistry":
        """Skills the mock supports. On the real body, register each only once verified."""
        reg = cls()
        for name in ("go_to", "follow", "stop", "attack", "gather", "craft", "give", "place"):
            reg.register(name)
        return reg


# --------------------------------------------------------------------------- store


class StateStore:
    def __init__(self, directory: Path | None = None, skills: SkillRegistry | None = None):
        self.dir = Path(directory) if directory else paths.state_dir()
        self.dir.mkdir(parents=True, exist_ok=True)
        self.tree_path = self.dir / "task_tree.json"
        self.progress_path = self.dir / "progress.jsonl"
        self.notes_path = self.dir / "notes.json"
        self.skills = skills or SkillRegistry.default()
        self.tree: TaskTree | None = self._load_tree()

    # task tree
    def _load_tree(self) -> TaskTree | None:
        if self.tree_path.exists():
            return TaskTree.model_validate_json(self.tree_path.read_text(encoding="utf-8"))
        return None

    def set_goal(self, goal: str, tasks: list[Task]) -> TaskTree:
        self.tree = TaskTree(goal=goal, tasks=tasks)
        self.save_tree()
        return self.tree

    def save_tree(self) -> None:
        if self.tree is None:
            return
        _atomic_write(self.tree_path, self.tree.model_dump_json(indent=2))

    # progress log
    def progress(self, message: str, **data: Any) -> None:
        with self.progress_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": round(time.time(), 3), "msg": message, **data}, default=str) + "\n")

    def recent_progress(self, n: int = 10) -> list[dict]:
        if not self.progress_path.exists():
            return []
        lines = self.progress_path.read_text(encoding="utf-8").splitlines()
        return [json.loads(line) for line in lines[-n:] if line.strip()]

    # notes
    def notes(self) -> dict[str, str]:
        if self.notes_path.exists():
            return json.loads(self.notes_path.read_text(encoding="utf-8"))
        return {}

    def remember(self, key: str, value: str) -> dict:
        notes = self.notes()
        notes[key] = value
        _atomic_write(self.notes_path, json.dumps(notes, indent=2, ensure_ascii=False))
        return {"ok": True, "reason": None, "data": {"key": key}}


def _atomic_write(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)

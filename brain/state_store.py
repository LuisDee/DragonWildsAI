"""Shared state store: task tree with done flags, progress log, notes.json, skill registry.

Everything that must survive a restart lives in files under one directory
(design principle 5). Files:
  task_tree.json   current goal and its tasks (rewritten atomically)
  progress.jsonl   append-only log of what happened
  notes.json       long-term facts written via remember()
  places.json      named places {name: {position, note, saved}} (design section 15)
  reflex_rules.json  snapshot of the body's standing orders, for this world
With per-world memory the directory is <state>/worlds/<world_guid>/ (brain/worlds.py).
"""
from __future__ import annotations

import json
import os
import time
import uuid
from collections.abc import Iterable
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field, computed_field

from . import paths
from .interface import TOOLS, ActionResult, ok

TaskStatus = Literal["pending", "running", "done", "failed"]
GoalStatus = Literal["active", "done", "stuck", "interrupted"]


class Task(BaseModel):
    # Unknown keys are ignored on load, so an input "done" key is dropped and recomputed.
    id: str = Field(default_factory=lambda: uuid.uuid4().hex[:8])
    skill: str
    args: dict[str, Any] = {}
    status: TaskStatus = "pending"
    attempts: int = 0
    last_reason: str | None = None

    @computed_field  # still written to task_tree.json for readers of the file
    @property
    def done(self) -> bool:
        return self.status == "done"


class TaskTree(BaseModel):
    goal: str
    status: GoalStatus = "active"
    tasks: list[Task] = []
    replans: int = 0

    def next_task(self) -> Task | None:
        return next((t for t in self.tasks if t.status in ("pending", "running")), None)


# --------------------------------------------------------------------------- skills

# Skills the mock supports. On the real body, pass only the verified ones.
MOCK_SKILLS = ("go_to", "follow", "stop", "attack", "gather", "craft", "give", "place", "pickup", "drop",
               "cast", "sleep", "wake", "interact")


class SkillRegistry:
    """Skills the Planner may use (CLAUDE.md principle 3: only verified skills).

    Each name must be a tool in ``interface.TOOLS``; its args schema and
    description come from there.
    """

    def __init__(self, names: Iterable[str] = MOCK_SKILLS, specs: dict[str, dict] | None = None) -> None:
        # specs: capability-manifest entries for tools the brain has no typed model for (e.g. the client's
        # move_item, equip): validated against the body's JSON schema, described with its own words.
        self._names = list(dict.fromkeys(names))
        self._specs = dict(specs or {})
        unknown = [n for n in self._names if n not in TOOLS and n not in self._specs]
        if unknown:
            raise ValueError(f"not tools in interface.TOOLS or the body manifest: {unknown}")

    def __contains__(self, name: str) -> bool:
        return name in self._names

    def names(self) -> list[str]:
        return list(self._names)

    def validate(self, name: str, args: dict) -> dict:
        if name not in TOOLS and name in self._specs:
            import jsonschema  # only bodies with a manifest need it
            jsonschema.validate(args, self._specs[name].get("args") or {"type": "object"})
            return dict(args)
        return TOOLS[name][0].model_validate(args).model_dump()

    def describe(self) -> list[dict]:
        out = []
        for name in self._names:
            if name not in TOOLS:
                spec = self._specs[name]
                schema = spec.get("args") or {}
                out.append({"name": name, "description": spec.get("description", ""),
                            "args": schema.get("properties", {}), "required": schema.get("required", [])})
                continue
            model, description = TOOLS[name]
            schema = model.model_json_schema()
            out.append({"name": name, "description": description, "args": schema.get("properties", {}),
                        "required": schema.get("required", [])})
        return out


# --------------------------------------------------------------------------- store


class StateStore:
    def __init__(self, directory: Path | None = None, skills: SkillRegistry | None = None):
        self.dir = Path(directory) if directory else paths.state_dir()
        self.dir.mkdir(parents=True, exist_ok=True)
        self.tree_path = self.dir / "task_tree.json"
        self.progress_path = self.dir / "progress.jsonl"
        self.notes_path = self.dir / "notes.json"
        self.places_path = self.dir / "places.json"
        self.rules_path = self.dir / "reflex_rules.json"
        self.skills = skills or SkillRegistry()
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

    # notes
    def notes(self) -> dict[str, str]:
        if self.notes_path.exists():
            return json.loads(self.notes_path.read_text(encoding="utf-8"))
        return {}

    def remember(self, key: str, value: str) -> ActionResult:
        notes = self.notes()
        notes[key] = value
        _atomic_write(self.notes_path, json.dumps(notes, indent=2, ensure_ascii=False))
        return ok(key=key)

    # named places
    def places(self) -> dict[str, dict]:
        if self.places_path.exists():
            return json.loads(self.places_path.read_text(encoding="utf-8"))
        return {}

    def remember_place(self, name: str, position: list[float] | None, note: str | None = None) -> ActionResult:
        key = name.strip().lower()
        places = self.places()
        places[key] = {"position": position, "note": note, "saved": round(time.time())}
        _atomic_write(self.places_path, json.dumps(places, indent=2, ensure_ascii=False))
        return ok(place=key, position=position)

    def place_position(self, name: str) -> list[float] | None:
        rec = self.places().get(str(name).strip().lower())
        pos = rec.get("position") if isinstance(rec, dict) else None
        return pos if isinstance(pos, list) and len(pos) == 3 else None

    # standing orders: the body stores and runs them; this is the per-world record the brain keeps
    def save_rules(self, rules: list[dict]) -> None:
        _atomic_write(self.rules_path, json.dumps({"saved": round(time.time()), "rules": rules}, indent=2,
                                                  ensure_ascii=False, default=str))

    def saved_rules(self) -> list[dict]:
        if self.rules_path.exists():
            return json.loads(self.rules_path.read_text(encoding="utf-8")).get("rules") or []
        return []


def _atomic_write(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)

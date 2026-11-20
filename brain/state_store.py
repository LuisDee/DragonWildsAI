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
import time
import uuid
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field, computed_field

from . import paths
from .fileio import atomic_write as _atomic_write
from .interface import TOOLS, ActionResult, ok

# notes.json "state:<x>" keys are passing conditions, shown to a model only this long after they were written
STATE_PREFIX, STATE_NOTE_TTL_S = "state:", 1800.0

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
    detail: str | None = None  # what the body said happened (its result's detail), for the Planner's replan

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


class SkillArgsError(ValueError):
    """A step's args do not fit the skill's schema; the message names the arg and why (it goes back to the model)."""


class SkillRegistry:
    """Skills the Planner may use (CLAUDE.md principle 3: only verified skills).

    A skill's args schema and description come from the body's manifest entry when ``specs`` has one (the schema the
    Controller is offered; ``validator`` is the check the Controller's calls go through), else from ``interface.TOOLS``.
    """

    def __init__(self, names: Iterable[str] = MOCK_SKILLS, specs: dict[str, dict] | None = None,
                 validator: Callable[[str, dict], dict] | None = None) -> None:
        # specs: capability-manifest entries, for tools the brain has no typed model for (the client's move_item,
        # equip) and for those whose manifest replaces the brain's stub model (capabilities.MANIFEST_ARGS: craft).
        # Validated against the body's JSON schema, described with its own words.
        self._names = list(dict.fromkeys(names))
        self._specs = dict(specs or {})
        self._validator = validator
        unknown = [n for n in self._names if n not in TOOLS and n not in self._specs]
        if unknown:
            raise ValueError(f"not tools in interface.TOOLS or the body manifest: {unknown}")

    def __contains__(self, name: str) -> bool:
        return name in self._names

    def names(self) -> list[str]:
        return list(self._names)

    def validate(self, name: str, args: dict) -> dict:
        if name in self._specs:
            return self._validate_spec(name, args)
        return TOOLS[name][0].model_validate(args).model_dump()

    def _validate_spec(self, name: str, args: dict) -> dict:
        """The body's schema as is: every arg it declares is kept; an arg it does not declare is refused with the list
        it does take, never dropped in silence (study craft_hold_gap 2026-11-20: the brain's stub CraftArgs stripped
        the Planner's recipe and station, and it said it "can't pick a recipe through the craft skill")."""
        import jsonschema  # only bodies with a manifest need it
        schema = self._specs[name].get("args") or {"type": "object"}
        if not isinstance(args, dict):
            raise SkillArgsError(f"{name}: args must be an object, got {type(args).__name__}")
        props = schema.get("properties") if isinstance(schema, dict) else None
        if isinstance(props, dict) and props and schema.get("additionalProperties", False) is not True:
            extra = sorted(k for k in args if k not in props)
            if extra:
                raise SkillArgsError(f"{name}: unknown arg {', '.join(map(repr, extra))}; {name} takes: "
                                     f"{', '.join(props)}")
        try:
            if self._validator is not None:
                return self._validator(name, args)
            jsonschema.validate(args, schema)
        except jsonschema.ValidationError as exc:
            raise SkillArgsError(f"{name}: {exc.message}") from exc
        except ValueError as exc:  # capabilities.ManifestError: already "<tool>: <why>"
            raise SkillArgsError(str(exc)) from exc
        return dict(args)

    def describe(self) -> list[dict]:
        out = []
        for name in self._names:
            if name in self._specs:
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
        self.notes_at_path = self.dir / "notes_at.json"  # {key: unix time written} (state:* notes expire)
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

    def _notes_at(self) -> dict[str, float]:
        try:
            d = json.loads(self.notes_at_path.read_text(encoding="utf-8")) if self.notes_at_path.exists() else {}
        except ValueError:
            return {}
        return d if isinstance(d, dict) else {}

    def remember(self, key: str, value: str) -> ActionResult:
        notes = self.notes()
        notes[key] = value
        _atomic_write(self.notes_path, json.dumps(notes, indent=2, ensure_ascii=False))
        at = self._notes_at()
        at[key] = round(time.time())
        _atomic_write(self.notes_at_path, json.dumps(at, indent=2))
        return ok(key=key)

    def prompt_notes(self, now: float | None = None) -> dict[str, str]:
        """The notes a model sees. A ``state:*`` note is a passing condition ("at 0 water, 1% HP"): it is shown only
        within STATE_NOTE_TTL_S of being written, with its age, and never without a write time (forensics
        2026-10-31: a 4-day-old false "body link keeps restarting" note sat in 110/110 prompts). Other notes are
        long-term facts and always shown."""
        now = time.time() if now is None else now
        at = self._notes_at()
        out = {}
        for k, v in self.notes().items():
            if str(k).lower().startswith(STATE_PREFIX):
                t = at.get(k)
                if not isinstance(t, (int, float)) or now - t > STATE_NOTE_TTL_S:
                    continue
                v = f"{v} (noted {max(0, now - t) / 60:.0f} min ago)"
            out[k] = v
        return out

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

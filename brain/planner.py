"""Planner: goal -> JSON task list using ONLY registered skills.

On failure it follows DEPS (Describe, Explain, Plan; arXiv:2302.01560): the
prompt describes what was executed and how it failed, the model explains the
cause, then emits a new plan for the remaining work, or asks for help.
Plans are validated with pydantic against the skill registry; an invalid plan
gets one repair round with the validation errors, then raises PlanError.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

from pydantic import BaseModel, ValidationError

from .jsonl_log import JsonlLogger
from .llm import LLMClient
from .llm_json import DecisionError, extract_json, json_decision
from .situation import asked_line, bases_line
from .state_store import SkillRegistry, Task, TaskTree

SYSTEM = """You are the planner for an AI companion in RuneScape: Dragonwilds.
Turn the goal into a short ordered list of tasks. Use ONLY these skills, with
arguments matching their schemas:
{skills}

Rules:
- Preconditions matter: be within reach of a player before `give` (go_to the player first);
  gather materials before craft/place; go_to a place before gathering there if nothing is nearby.
- `inventory` is what the companion carries. Items lying on the ground (`nearby_items`) are
  collected with `pickup`; `drop` puts carried items on the ground.
- Use names from the state and notes (places, entity ids, player names). Never invent ids.
- If the goal is impossible with these skills, return no tasks and set "ask_help" to a short question.
Respond with JSON only, no prose:
{{"description": str|null, "explanation": str|null, "ask_help": str|null,
  "tasks": [{{"skill": str, "args": {{...}}}}]}}"""

REPLAN = """The plan failed. Follow these steps.
1. description: describe what was executed and what happened.
2. explanation: explain the most likely cause of the failure.
3. tasks: give a NEW plan for the remaining work only, which avoids that cause.
   If no registered skill can get around it, return no tasks and set ask_help."""


class TaskSpec(BaseModel):
    skill: str
    args: dict = {}


class PlanModel(BaseModel):
    description: str | None = None
    explanation: str | None = None
    ask_help: str | None = None
    tasks: list[TaskSpec] = []


@dataclass
class PlanResult:
    tasks: list[Task]
    ask_help: str | None = None
    explanation: str | None = None
    description: str | None = None


class PlanError(Exception):
    pass


def _trim_state(state: dict) -> dict:
    keep = ("position", "health", "inventory", "following", "players", "nearby_entities",
            "nearby_resources", "nearby_items", "structures", "places")
    return {k: state[k] for k in keep if k in state}


def _where(state: dict) -> dict:
    """What the Controller's situation says about places, in its own words: where he stood when asked ("here") and
    his own bases. Live 2026-11-16 (rung 2): the plan gathered 60 m away and built "near me" on a 3 m slope; the
    Planner saw neither line."""
    lines = {"asked": asked_line(state), "your_bases": bases_line(state)}
    return {k: v for k, v in lines.items() if v}


def _done_row(t: Task) -> dict:
    return t.model_dump(include={"skill", "args"}) | ({"result": t.detail} if t.detail else {})


class Planner:
    def __init__(self, llm: LLMClient, skills: SkillRegistry, logger: JsonlLogger, max_repairs: int = 1):
        self.llm = llm
        self.skills = skills
        self.log = logger
        self.max_repairs = max_repairs

    def _system(self) -> dict:
        return {"role": "system", "content": SYSTEM.format(skills=json.dumps(self.skills.describe(), indent=1))}

    def plan(self, goal: str, state: dict, notes: dict) -> PlanResult:
        user = {"goal": goal, **_where(state), "notes": notes, "state": _trim_state(state)}
        return self._ask([self._system(), {"role": "user", "content": json.dumps(user)}])

    def replan(self, tree: TaskTree, failed: Task, reason: str | None, state: dict, notes: dict) -> PlanResult:
        user = {
            "goal": tree.goal,
            **_where(state),
            # each step with what the body said happened (2026-11-16: the replan got "blocked" and nothing of "the
            # preview kept sliding ... 0.05 m from the flush spot", nor where the gather had left him)
            "completed": [_done_row(t) for t in tree.tasks if t.done],
            "failed_task": {"skill": failed.skill, "args": failed.args, "reason": reason, "attempts": failed.attempts}
            | ({"result": failed.detail} if failed.detail else {}),
            "remaining": [t.model_dump(include={"skill", "args"}) for t in tree.tasks if not t.done and t is not failed],
            "replans_so_far": tree.replans,
            "notes": notes,
            "state": _trim_state(state),
        }
        messages = [self._system(), {"role": "user", "content": json.dumps(user) + "\n\n" + REPLAN}]
        return self._ask(messages)

    def _ask(self, messages: list[dict]) -> PlanResult:
        """One plan through the shared validate-and-repair loop (brain/llm_json.py, simplify item 10)."""
        self.log.log("prompt", component="planner", model=self.llm.model, messages=messages)

        def validate(text: str, round_: int) -> PlanResult:
            try:
                return self._validate(text)
            except (ValueError, ValidationError) as exc:
                self.log.log("plan_invalid", error=str(exc), round=round_)
                raise

        try:
            plan, _ = json_decision(self.llm, messages, validate, max_repairs=self.max_repairs,
                                    on_response=lambda r: self.log.log("llm_response", component="planner",
                                                                       model=self.llm.model, content=r.content,
                                                                       usage=r.usage))
        except DecisionError as exc:
            raise PlanError("planner produced no valid plan") from exc
        return plan

    def _validate(self, text: str) -> PlanResult:
        plan = PlanModel.model_validate_json(extract_json(text))
        errors, tasks = [], []
        for i, spec in enumerate(plan.tasks):
            if spec.skill not in self.skills:
                errors.append(f"task {i}: unknown skill {spec.skill!r}; allowed: {self.skills.names()}")
                continue
            try:
                tasks.append(Task(skill=spec.skill, args=self.skills.validate(spec.skill, spec.args)))
            except ValidationError as exc:
                errors.append(f"task {i} ({spec.skill}): {exc.errors(include_url=False)}")
        if errors:
            raise ValueError("; ".join(errors))
        if not tasks and not plan.ask_help:
            raise ValueError("empty plan without ask_help")
        return PlanResult(tasks, plan.ask_help, plan.explanation, plan.description)

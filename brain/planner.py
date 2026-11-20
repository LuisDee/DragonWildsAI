"""Planner: goal -> JSON task list using ONLY registered skills.

On failure it follows DEPS (Describe, Explain, Plan; arXiv:2302.01560): the
prompt describes what was executed and how it failed, the model explains the
cause, then emits a new plan for the remaining work, or asks for help.
Plans are validated with pydantic against the skill registry; an invalid plan
gets one repair round with the validation errors, then raises PlanError.

Before it answers, the Planner may call read-only research tools (the registry's read view, brain/tool_registry.py
PLANNER_READS: the same lookup the Controller and the Director have). The loop runs inside plan()/replan(), so it
works unchanged when that call runs on a worker thread (DW_ASYNC_PLAN): the Research is built per call over a copy
of the state. At most MAX_RESEARCH_CALLS calls run per plan; then the plan is due.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Callable

from pydantic import BaseModel, ValidationError

from . import predicates as P
from .jsonl_log import JsonlLogger
from .llm import LLMClient
from .llm_json import DecisionError, extract_json, json_decision
from .situation import _creature_note as creature_note
from .situation import asked_line, bases_line, hazards, quest_rows, vault_fields
from .spells import state_lines as state_spell_lines
from .state_store import SkillRegistry, Task, TaskTree

SYSTEM = """You are the planner for an AI companion in RuneScape: Dragonwilds.
Turn the goal into a short ordered list of tasks. Use ONLY these skills, with
arguments matching their schemas:
{skills}

Rules:
- Preconditions matter: be within reach of a player before `give` (go_to the player first);
  gather materials before craft/place; go_to a place before gathering there if nothing is nearby.
- `inventory` is what the companion carries. Items lying on the ground (`nearby_items`) are
  collected with `pickup`; `drop` puts carried items on the ground. A row with `pile_n` is a pile of that many
  drops (its `count` summed): the game's item magnet takes the drops near him as he walks up, so one task on its id.
- Use names from the state and notes (places, entity ids, player names). Never invent ids.
- "ask_help" (a short question) is said to the player. With tasks, they run meanwhile and his answer comes later as a
  new line; with no tasks (the goal is impossible with these skills), the job stops until he answers.
Respond with JSON only, no prose:
{{"description": str|null, "explanation": str|null, "ask_help": str|null,
  "tasks": [{{"skill": str, "args": {{...}}}}]}}"""

# One plain sentence, only when tools are offered: what exists, not what to do with it (CLAUDE.md section 3).
RESEARCH_LINE = ("Read-only research tools are offered with this request ({names}); they change nothing in the game, "
                 "and at most {n} calls are answered before the plan is due.")
MAX_RESEARCH_CALLS = 4
RESULT_LOG_CHARS = 2000  # a research result as the planner_research row keeps it

# DW_ASK_OWNER=1 (agent._take_up_ask): a request the Controller left with no job is handed to the Planner in the
# player's own words, which may ask for no work at all (a question, a remark). Only then is a decline offered: one
# schema line saying what it is, no advice. An empty plan with an explanation and no question is that decline
# (PlanResult.declined).
DECLINE_LINE = ("- This goal is the player's own words. If they ask for no work these skills can do (a question, a "
                "remark), you may decline it: no tasks, no ask_help, and the reason in \"explanation\".")

# DW_PLAN_AT_ASK=1 (agent._submit_at_ask): the call made at the ask also writes the job's end condition, once, in the
# success-predicate format code checks on fresh game state (predicates.SCHEMA_DOC: the one source, as the Director gets
# it). One schema line saying what the key is, then the format; no advice (research 2026-11-17-long-jobs-planner-actor.md,
# decision 6: the end condition is written at the ask and checked by code). L3 2026-11-20: no plan carried what "geared
# up for the vault" meant, so nothing could read it as met or not.
DONE_WHEN_LINE = ("- Add \"done_when\" to the JSON: this job's end condition as ONE success predicate (format below), "
                  "checked by code on fresh game state from now on (\"since this step started\" there means since this "
                  "request); null when the words ask for no job.")

REPLAN = """The plan failed. Follow these steps.
1. description: describe what was executed and what happened.
2. explanation: explain the most likely cause of the failure.
3. tasks: give a NEW plan for the remaining work only, which avoids that cause.
   If no registered skill can get around it, return no tasks and set ask_help."""


class TaskSpec(BaseModel):
    skill: str
    args: dict = {}


def parse_steps(skills: SkillRegistry, specs: list) -> tuple[list[Task], list[str]]:
    """Steps {skill, args} to Tasks through the skill registry, with an error per step that is not one. The one step
    parser: the Planner's plan and the Controller's own first_steps of a start_goal (DW_ASYNC_PLAN) both go through it."""
    errors, tasks = [], []
    for i, raw in enumerate(specs):
        try:
            spec = raw if isinstance(raw, TaskSpec) else TaskSpec.model_validate(raw)
        except ValidationError as exc:
            errors.append(f"task {i}: {exc.errors(include_url=False)}")
            continue
        if spec.skill not in skills:
            errors.append(f"task {i}: unknown skill {spec.skill!r}; allowed: {skills.names()}")
            continue
        try:
            tasks.append(Task(skill=spec.skill, args=skills.validate(spec.skill, spec.args)))
        except ValidationError as exc:
            errors.append(f"task {i} ({spec.skill}): {exc.errors(include_url=False)}")
        except ValueError as exc:  # a body-schema skill (SkillArgsError): the arg and why
            errors.append(f"task {i} ({spec.skill}): {exc}")
    return tasks, errors


class PlanModel(BaseModel):
    description: str | None = None
    explanation: str | None = None
    ask_help: str | None = None
    tasks: list[TaskSpec] = []
    done_when: Any = None  # read only when asked for (Planner.plan(done_when=True)); checked by check_done_when


@dataclass
class PlanResult:
    tasks: list[Task]
    ask_help: str | None = None
    explanation: str | None = None
    description: str | None = None
    # DW_PLAN_AT_ASK=1: the job's end condition as written (raw), validated and normalised (None when null or refused),
    # and why it was refused. An invalid one never costs the plan: the steps land, done_when stays None
    done_when_raw: Any = None
    done_when: dict | None = None
    done_when_error: str | None = None

    @property
    def declined(self) -> bool:
        """No steps, no question, a reason: the Planner declined the goal (offered only with may_decline)."""
        return not self.tasks and not self.ask_help and bool((self.explanation or "").strip())


class PlanError(Exception):
    pass


def check_done_when(raw: Any, items: "P.Items | None" = None) -> tuple[dict | None, str | None]:
    """A written end condition through predicates.validate (item names to ids) and its net-delta lint: (the normalised
    predicate, None), or (None, why it is refused). None written: (None, None)."""
    if raw is None:
        return None, None
    try:
        pred = P.validate(raw, items if items is not None else P.Items())
    except P.PredicateError as exc:
        return None, str(exc) + (f" (candidates: {', '.join(exc.candidates)})" if exc.candidates else "")
    except Exception as exc:  # item data missing, a malformed argument: refused with what went wrong
        return None, f"{type(exc).__name__}: {exc}"[:300]
    if clash := P.net_conflicts(pred):
        return None, "gained and lost of the same item in one all can never both hold: " + ", ".join(clash)
    return pred, None


def creature_rows(state: dict) -> list[dict]:
    """The creatures in sight as the Controller sees them: id, name, where, hostile, and the body's own odds line
    ("PL 2, odds now: much stronger (PL +2; kills you ~6 s; you it ~15 s)"), with how many hostiles are in sight.
    Fight study 2026-11-18, run 20261118-010135 at 953.7 s: the Planner saw a Goblin Archer 18 m off only as a raw
    row (power_level 2) and planned an explore from there; he died to it. Facts only."""
    odds = state.get("fight_odds") if isinstance(state.get("fight_odds"), dict) else {}
    rows = [e for e in state.get("nearby_entities") or [] if isinstance(e, dict) and e.get("alive", True)]
    hostile = sum(1 for e in rows if e.get("hostile"))
    out = []
    for e in rows:
        row = {k: e[k] for k in ("id", "name", "distance", "up_m", "position", "hostile") if e.get(k) is not None}
        if note := creature_note(e, odds):
            row["note"] = note
        if e.get("hostile") and hostile > 1:
            row["hostiles_in_sight"] = hostile  # the body's odds count only those within aggro range of this one
        out.append(row)
    return out


def gear_fields(state: dict) -> dict:
    """What he wears (slot -> the item's name) and his power level: the game's reading, as his situation's "You:" line
    shows it, and beside it the level his worn armour gives (gear_plan's rule) when the two differ or the game gave
    none, each labelled by its source. L3 2026-11-19: the Planner had no gear and said "I have no armour" while he wore
    an Adventurer's Tunic, Adventurer's Leggings and a Leather Cowl."""
    from .situation import HELD_SLOTS, item_names, name_of_item
    gear = state.get("gear") if isinstance(state.get("gear"), dict) else {}
    if not gear:
        return {}
    names = item_names(state)
    worn: dict[str, str] = {}
    seen: set[str] = set()
    for slot, item in gear.items():
        key = str(slot).lower().replace("_", "")  # "held_right" and "HeldRight" are one slot
        if not item or key in seen:
            continue
        seen.add(key)
        label = {"heldright": "right hand", "heldleft": "left hand", "right": "right hand", "left": "left hand"}.get(
            key, str(slot)) if str(slot).lower() in HELD_SLOTS else str(slot)
        worn[label] = name_of_item(str(item).rsplit("/", 1)[-1].rsplit(".", 1)[-1], names)
    out: dict[str, Any] = {"gear": worn}
    game = state.get("power_level")
    game = game if isinstance(game, (int, float)) and not isinstance(game, bool) else None
    try:
        from .gear_plan import worn_armour
        mine = worn_armour(state)
    except Exception:  # item data missing: the game's reading alone
        mine = None
    pl: dict[str, Any] = {}
    if game is not None:
        pl["game_reads"] = int(game) if float(game).is_integer() else game
    if mine is not None and (game is None or mine["pl"] != game):
        pl["from_worn_armour"] = mine["pl"]
        pl["from_worn_armour_rule"] = ("mean of worn head, body, legs power level, rounded down; an empty slot is 0: "
                                       + (", ".join(mine["pieces"]) or "none worn"))
    if pl:
        out["power_level"] = pl
    return out


def _trim_state(state: dict) -> dict:
    keep = ("position", "health", "inventory", "following", "players", "nearby_entities",
            "nearby_resources", "nearby_items", "structures", "places",
            "further_off")  # kinds in sight that the nearby_* lists (the N nearest of a category) have no row of
    out = {k: state[k] for k in keep if k in state}
    if isinstance(state.get("nearby_entities"), list):
        out["nearby_entities"] = creature_rows(state)
    out.update(vault_fields(state))  # in a vault and which (its registry box, else the flag); nothing when not read in one
    # traps and standing poison clouds in the Controller's words (where, how big, what they do): a plan picks gather
    # spots and routes too (L3 2026-11-20: 4 of 8 deaths were poison clouds beside his flax spot)
    if hz := hazards(state):
        out["hazards"] = hz
    out.update(gear_fields(state))
    # his spells with their recharge: castable now and how long it recharges after each cast, or the seconds left.
    # L2-V1 2026-11-19: plans queued four 300 s Bark to Bones casts in a row and a replan put one back with 82 s left
    if spell_lines := state_spell_lines(state):
        out["spells"] = spell_lines
    # his quest log: each active step in the game's words with its map markers (the places a plan can name). Run
    # 20261116-222242: only the Controller had it, and the plan explored for a marker's name as a thing to see
    q = state.get("quests") if isinstance(state.get("quests"), dict) else {}
    log = {"active": quest_rows(state, 8), "complete": list(q.get("complete") or [])[:30]}
    if log["active"] or log["complete"]:
        out["quests"] = log
    return out


def _where(state: dict, goal: str = "", places: Any = None) -> dict:
    """What the Controller's situation says about places, in its own words: where he stood when asked ("here"), his
    own bases, and the map names in the goal (the Controller's map_names: places.mentioned). Live 2026-11-16 (rung 2):
    the plan gathered 60 m away and built "near me" on a 3 m slope; the Planner saw neither line. For each vault the
    goal names, or the nearest one when it says only "the vault" (places.named), the gear facts lookup gives it
    (gear_plan.vault_facts). L3 2026-11-20: the Controller had "nearest: Crasorak Kara (PL 2, 227 m)", the Planner
    had nothing; it asked the player "which vault?" and parked."""
    lines: dict[str, Any] = {"asked": asked_line(state), "your_bases": bases_line(state)}
    asked = state.get("asked_at") if isinstance(state.get("asked_at"), dict) else {}
    text = " ".join(dict.fromkeys(x for x in (goal, asked.get("request")) if isinstance(x, str) and x))
    if places is not None and text and not state.get("unavailable"):
        here = state.get("position")
        try:
            lines["map_names"] = places.mentioned(text, here)
            vaults = [p["name"] for p in places.named(text, here) if p.get("kind") == "vault"]
        except Exception as exc:  # map data missing: say so, never a lost plan
            lines["map_names"], vaults = f"unavailable ({type(exc).__name__})", []
        if vaults:
            from .gear_plan import vault_facts
            lines["gear_for_vault"] = [vault_facts(state, v) for v in vaults]
    return {k: v for k, v in lines.items() if v}


def _done_row(t: Task) -> dict:
    return t.model_dump(include={"skill", "args"}) | ({"result": t.detail} if t.detail else {})


class Planner:
    def __init__(self, llm: LLMClient, skills: SkillRegistry, logger: JsonlLogger, max_repairs: int = 1,
                 research: Callable[[dict], Any] | None = None, max_research: int = MAX_RESEARCH_CALLS,
                 places: Any = None):
        self.llm = llm
        self.places = places  # brain.places.Places: the Controller's map data (LiveSession sets it), None without
        self.skills = skills
        self.log = logger
        self.max_repairs = max_repairs
        # state -> an object with tools() and run(name, args) (brain.director.planner_research); None: no tools
        self.research = research
        self.max_research = max_research

    def _system(self, tools: list[dict] | None = None, may_decline: bool = False, done_when: bool = False) -> dict:
        text = SYSTEM.format(skills=json.dumps(self.skills.describe(), indent=1))
        if may_decline:
            text += "\n" + DECLINE_LINE
        if done_when:
            text += "\n" + DONE_WHEN_LINE + "\n" + P.SCHEMA_DOC
        if tools:
            names = ", ".join(t["function"]["name"] for t in tools)
            text += "\n\n" + RESEARCH_LINE.format(names=names, n=self.max_research)
        return {"role": "system", "content": text}

    def _research(self, state: dict) -> Any:
        if self.research is None:
            return None
        try:
            return self.research(state)
        except Exception as exc:  # no research is no reason to make no plan
            self.log.log("planner_research_unavailable", component="planner", error=repr(exc)[:300])
            return None

    def plan(self, goal: str, state: dict, notes: dict, may_decline: bool = False,
             done_when: bool = False) -> PlanResult:
        """``done_when`` (DW_PLAN_AT_ASK=1, the call at the ask): the plan also writes the job's end condition; it is
        validated here and logged (plan_done_when), and an invalid one is refused with its reason, never the plan."""
        user = {"goal": goal, **_where(state, goal, getattr(self, "places", None)), "notes": notes,
                "state": _trim_state(state)}
        research = self._research(state)
        tools = research.tools() if research is not None else None
        plan = self._ask([self._system(tools, may_decline, done_when), {"role": "user", "content": json.dumps(user)}],
                         "plan", research, tools, may_decline=may_decline)
        if done_when:
            plan.done_when, plan.done_when_error = check_done_when(plan.done_when_raw)
            self.log.log("plan_done_when", component="planner", request=goal, done_when=plan.done_when_raw,
                         valid=plan.done_when_error is None,
                         **({"reads_as": P.describe(plan.done_when)} if plan.done_when else {}),
                         **({"error": plan.done_when_error} if plan.done_when_error else {}))
        return plan

    def replan(self, tree: TaskTree, failed: Task, reason: str | None, state: dict, notes: dict,
               may_decline: bool = False) -> PlanResult:
        user = {
            "goal": tree.goal,
            **_where(state, tree.goal, getattr(self, "places", None)),
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
        research = self._research(state)
        tools = research.tools() if research is not None else None
        messages = [self._system(tools, may_decline),
                    {"role": "user", "content": json.dumps(user) + "\n\n" + REPLAN}]
        return self._ask(messages, "replan", research, tools, may_decline=may_decline)

    def _ask(self, messages: list[dict], mode: str = "plan", research: Any = None,
             tools: list[dict] | None = None, may_decline: bool = False) -> PlanResult:
        """One plan through the shared validate-and-repair loop (brain/llm_json.py, simplify item 10), with up to
        max_research read-only research calls before it."""
        self.log.log("prompt", component="planner", model=self.llm.model, messages=messages,
                     **({"tools": [t["function"]["name"] for t in tools]} if tools else {}))
        made: list[dict] = []

        def run_tool(name: str, args: dict) -> Any:
            try:
                result = research.run(name, args)
            except Exception as exc:  # a research tool failing is information for the model, never a lost plan
                result = {"ok": False, "error": repr(exc)[:300]}
            text = json.dumps(result, default=str, ensure_ascii=False)
            made.append({"tool": name, "args": args, "chars": len(text)})
            self.log.log("planner_research", component="planner", mode=mode, tool=name, args=args, chars=len(text),
                         result=text[:RESULT_LOG_CHARS])
            return result

        def validate(text: str, round_: int) -> PlanResult:
            try:
                return self._validate(text, may_decline)
            except (ValueError, ValidationError) as exc:
                self.log.log("plan_invalid", error=str(exc), round=round_)
                raise

        usage: list[dict] = []

        def on_response(r) -> None:
            usage.append(r.usage or {})
            self.log.log("llm_response", component="planner", model=self.llm.model, content=r.content, usage=r.usage,
                         **({"tool_calls": [c.name for c in r.tool_calls]} if r.tool_calls else {}))

        info: dict = {}
        try:
            plan, info = json_decision(self.llm, messages, validate, max_repairs=self.max_repairs,
                                       tools=tools or None, run_tool=run_tool if tools else None,
                                       max_tool_rounds=self.max_research, max_tool_calls=self.max_research,
                                       on_response=on_response)
        except DecisionError as exc:
            self._log_plan(mode, None, made, usage, info, error=str(exc)[:300])
            raise PlanError("planner produced no valid plan") from exc
        self._log_plan(mode, plan, made, usage, info)
        return plan

    def _log_plan(self, mode: str, plan: PlanResult | None, made: list[dict], usage: list[dict], info: dict,
                  error: str | None = None) -> None:
        """The plan row: its steps, the research calls made (and refused past the cap), the requests and their cost."""
        cost = [u.get("cost_usd") for u in usage if isinstance(u.get("cost_usd"), (int, float))]
        self.log.log("plan", component="planner", mode=mode, research_calls=len(made),
                     research_refused=sum(1 for c in info.get("tool_calls") or [] if c.get("refused")),
                     research=[c["tool"] for c in made], requests=len(usage),
                     tokens_in=sum(u.get("prompt") or 0 for u in usage),
                     tokens_out=sum(u.get("completion") or 0 for u in usage),
                     cost_usd=round(sum(cost), 6) if cost else None,
                     tasks=[t.skill for t in plan.tasks] if plan is not None else None,
                     ask_help=plan.ask_help if plan is not None else None, **({"error": error} if error else {}))

    def _validate(self, text: str, may_decline: bool = False) -> PlanResult:
        plan = PlanModel.model_validate_json(extract_json(text))
        tasks, errors = parse_steps(self.skills, plan.tasks)
        if errors:
            raise ValueError("; ".join(errors))
        if not tasks and not plan.ask_help and not (may_decline and (plan.explanation or "").strip()):
            raise ValueError("empty plan without ask_help" + (" or explanation" if may_decline else ""))
        return PlanResult(tasks, plan.ask_help, plan.explanation, plan.description, done_when_raw=plan.done_when)

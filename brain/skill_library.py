"""Skill library: verified goals generalised into named, parameterised skills, stored as data.

Prior art (research 2026-10-25 sections 2, 6.5): Voyager keeps a library of verified skills
indexed by their descriptions and puts the top-k into the prompt (top-5; 96.5% top-5 retrieval
accuracy); GITM stores successful action sequences per sub-goal; Agent Workflow Memory induces
reusable workflows from successful trajectories. We take the composability, not generated code
(L3): a skill is a declarative step list over registered primitives (or other skills), verified
step by step by the executor like any plan.

* **Learn** only after a goal completed with every task state-verified and a fresh get_state read
  (Voyager's self-verification gate, done deterministically). One Sonnet call names and
  parameterises the step list. The record is accepted only if expanding it with the example
  params reproduces exactly the task list that just succeeded (a deterministic faithfulness check),
  and its postcondition, when it has a checkable one, holds in the fresh state.
* **Store** one readable JSON file per skill in ``data/skills/<world_guid>/<name>.json`` (git-tracked
  so Luis can see what Claude learned; design section 19).
* **Retrieve** the top 3 by SQLite FTS5 BM25 (built into Python's sqlite3, porter stemming) over
  name, description, params and the goals it came from (decision D3). Skills that keep failing
  (>=4 runs, >50% failed) are flagged suspect and not offered.
* **Run** through ``run_skill(name, params)``: preconditions are checked against the situation, the
  steps are expanded (``$param`` substitution, ``repeat``) into ordinary Tasks for the executor.
* **Stats** per skill: runs, ok, failed, timings, last failure reason.
"""
from __future__ import annotations

# Verified-skill/workflow precedents; we retain declarative steps, not generated code:
# Voyager: https://arxiv.org/abs/2305.16291
# GITM: https://arxiv.org/abs/2305.17144
# Agent Workflow Memory: https://arxiv.org/abs/2409.07429

import json
import re
import sqlite3
import time
from pathlib import Path
from typing import Any, Callable, Literal

from pydantic import BaseModel, Field, ValidationError, field_validator

from .jsonl_log import JsonlLogger
from .llm import LLMClient, request_log_fields
from .llm_json import BudgetStop
from .situation import tokens
from .state_store import SkillRegistry, Task, _atomic_write

NAME_RE = re.compile(r"^[a-z][a-z0-9_]{2,47}$")
MAX_REPEAT = 20
MAX_DEPTH = 3
MAX_STEPS = 40


class ParamSpec(BaseModel):
    type: Literal["str", "int", "float"] = "str"
    description: str = ""
    default: Any = None


class SkillStep(BaseModel):
    skill: str  # a registered primitive, or another learned skill (composition)
    args: dict[str, Any] = {}
    repeat: int | str = 1  # an int or "$param"


class SkillStats(BaseModel):
    runs: int = 0
    ok: int = 0
    failed: int = 0
    total_s: float = 0.0
    last_s: float | None = None
    last_run: float | None = None
    last_reason: str | None = None

    @property
    def success_rate(self) -> float | None:
        return self.ok / self.runs if self.runs else None

    @property
    def avg_s(self) -> float | None:
        return self.total_s / self.ok if self.ok else None

    @property
    def suspect(self) -> bool:
        return self.runs >= 4 and self.failed / self.runs > 0.5


class SkillRecord(BaseModel):
    name: str
    description: str
    params: dict[str, ParamSpec] = {}
    preconditions: list[dict[str, Any]] = []
    steps: list[SkillStep] = Field(min_length=1)
    postcondition: dict[str, Any] | None = None
    stats: SkillStats = SkillStats()
    origin: dict[str, Any] = {}

    @field_validator("name")
    @classmethod
    def _name(cls, v: str) -> str:
        v = v.strip().lower().replace(" ", "_").replace("-", "_")
        if not NAME_RE.match(v):
            raise ValueError("name must be snake_case, 3-48 chars, start with a letter")
        return v

    def signature(self) -> tuple:
        """Same steps over the same params = the same skill (dedupe)."""
        return tuple(s.skill for s in self.steps), tuple(sorted(self.params))

    def brief(self) -> dict:
        """About 60-80 tokens for the Controller context."""
        st = self.stats
        out = {"name": self.name, "description": self.description,
               "params": {k: (f"{p.type}: {p.description}" if p.description else p.type) for k, p in self.params.items()},
               "record": f"{st.ok}/{st.runs} ok" if st.runs else "new"}
        if self.preconditions:
            out["needs"] = self.preconditions
        return out


class SkillError(ValueError):
    pass


# --------------------------------------------------------------------------- substitution


def _subst(value: Any, params: dict[str, Any]) -> Any:
    """'$count' -> params['count'] (typed); '$a*$b' / '$a*3' -> product; 'logs for $player' -> text."""
    if isinstance(value, dict):
        return {k: _subst(v, params) for k, v in value.items()}
    if isinstance(value, list):
        return [_subst(v, params) for v in value]
    if not isinstance(value, str) or "$" not in value:
        return value
    whole = re.fullmatch(r"\$(\w+)", value.strip())
    if whole:
        if whole.group(1) not in params:
            raise SkillError(f"missing param {whole.group(1)!r}")
        return params[whole.group(1)]
    if re.fullmatch(r"\s*(\$\w+|\d+)(\s*\*\s*(\$\w+|\d+))+\s*", value):
        prod = 1
        for part in value.split("*"):
            part = part.strip()
            v = params.get(part[1:]) if part.startswith("$") else int(part)
            if not isinstance(v, (int, float)) or isinstance(v, bool):
                raise SkillError(f"{part} is not a number")
            prod *= v
        return int(prod) if float(prod).is_integer() else prod

    def repl(m: re.Match) -> str:
        if m.group(1) not in params:
            raise SkillError(f"missing param {m.group(1)!r}")
        return str(params[m.group(1)])
    return re.sub(r"\$(\w+)", repl, value)


def _coerce(rec: SkillRecord, given: dict[str, Any]) -> dict[str, Any]:
    out = {}
    for name, spec in rec.params.items():
        v = given.get(name, spec.default)
        if v is None:
            raise SkillError(f"missing param {name!r} ({spec.description or spec.type})")
        try:
            out[name] = {"int": int, "float": float, "str": str}[spec.type](v)
        except (TypeError, ValueError):
            raise SkillError(f"param {name!r} must be {spec.type}, got {v!r}") from None
    return out


# --------------------------------------------------------------------------- preconditions

# Checkable kinds; anything else is shown to the model as advice and not enforced.
PRECONDITION_KINDS = {
    "has_item": "the companion carries at least count of item (e.g. {'has_item': '$item', 'count': '$count'})",
    "player_present": "that player is in the world near the companion (e.g. {'player_present': '$player'})",
    "holding": "the companion holds a tool whose name contains this word (e.g. {'holding': 'axe'})",
}


def _inv_match(state: dict, want: str) -> int:
    want_t = tokens(want)
    names = {r.get("item"): r.get("name") for r in state.get("inventory_items") or [] if isinstance(r, dict)}
    total = 0
    for item, n in (state.get("inventory") or {}).items():
        if item == want or (want_t and want_t & (tokens(item) | tokens(names.get(item)))):
            total += int(n or 0)
    return total


def check_preconditions(rec: SkillRecord, params: dict[str, Any], state: dict) -> list[str]:
    """Human-readable reasons the skill can't run now (empty = go)."""
    problems = []
    for pre in rec.preconditions:
        try:
            p = _subst(pre, params)
        except SkillError as exc:
            problems.append(str(exc))
            continue
        if "has_item" in p:
            need = int(p.get("count") or 1)
            have = _inv_match(state, str(p["has_item"]))
            if have < need:
                problems.append(f"I need {need} {p['has_item']} and have {have}")
        elif "player_present" in p:
            who = str(p["player_present"]).lower()
            if not any(str(x.get("name", "")).lower() == who for x in state.get("players") or []):
                problems.append(f"I can't see {p['player_present']}")
        elif "holding" in p:
            held = " ".join(str(v) for v in (state.get("gear") or {}).values()).lower()
            if held and str(p["holding"]).lower() not in held:
                problems.append(f"I'm not holding a {p['holding']}")
    return problems


def _postcondition_holds(post: dict | None, params: dict[str, Any], state: dict) -> bool | None:
    """True/False when checkable, None when not (unknown kind or no postcondition)."""
    if not post:
        return None
    try:
        p = _subst(post, params)
    except SkillError:
        return False
    if "inventory_at_least" in p and isinstance(p["inventory_at_least"], dict):
        return all(_inv_match(state, str(k)) >= int(v) for k, v in p["inventory_at_least"].items())
    if "near_player" in p:
        who = str(p["near_player"]).lower()
        d = next((x.get("distance") for x in state.get("players") or [] if str(x.get("name", "")).lower() == who), None)
        return isinstance(d, (int, float)) and d <= float(p.get("within_m") or 6)
    return None


# --------------------------------------------------------------------------- library

LEARN_PROMPT = """You turn a task list that just succeeded in RuneScape: Dragonwilds into a reusable skill.
The companion's primitives (the only step skills allowed, besides existing learned skills):
{skills}
Existing learned skills (reuse a name only if this is the same procedure): {existing}

Generalise the verified steps below into ONE skill:
- name: snake_case verb phrase, e.g. deliver_resource_stacks.
- description: one sentence saying what it does, mentioning the kinds of things it works for.
- params: the values a player would change next time (resource, count, player...), each
  {{"type": "str"|"int"|"float", "description": str}}. Keep params few.
- steps: the step list with literal values replaced by "$param" ("$count", or "$a*$b" for a product).
  Use "repeat": "$param" or an int for repeated steps.
- preconditions: list of checks, kinds: {kinds}. Only what must hold BEFORE the first step.
- postcondition: optional, {{"inventory_at_least": {{"$item": "$count"}}}} or {{"near_player": "$player"}}, or null.
- example_params: the param values that reproduce EXACTLY the steps below.
Respond with JSON only:
{{"name": str, "description": str, "params": {{}}, "steps": [{{"skill": str, "args": {{}}, "repeat": 1}}],
  "preconditions": [], "postcondition": null, "example_params": {{}}}}"""


def _fts_available() -> bool:
    try:
        c = sqlite3.connect(":memory:")
        c.execute("CREATE VIRTUAL TABLE t USING fts5(a)")
        c.close()
        return True
    except sqlite3.OperationalError:
        return False


class SkillLibrary:
    def __init__(self, directory: Path, log: JsonlLogger | None = None):
        self.dir = Path(directory)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.log = log
        self._skills: dict[str, SkillRecord] = {}
        self._db: sqlite3.Connection | None = None
        self._fts = _fts_available()
        self.load()

    # ---------------------------------------------------------------- storage

    def _log(self, kind: str, **data: Any) -> None:
        if self.log:
            self.log.log(kind, **data)

    def path_of(self, name: str) -> Path:
        return self.dir / f"{name}.json"

    def load(self) -> None:
        self._skills = {}
        for f in sorted(self.dir.glob("*.json")):
            try:
                rec = SkillRecord.model_validate_json(f.read_text(encoding="utf-8"))
                self._skills[rec.name] = rec
            except (OSError, ValueError, ValidationError) as exc:
                self._log("skill_load_error", file=str(f), error=str(exc)[:300])
        self._reindex()

    def save(self, rec: SkillRecord) -> None:
        self._skills[rec.name] = rec
        _atomic_write(self.path_of(rec.name), rec.model_dump_json(indent=2))
        self._reindex()

    def names(self) -> list[str]:
        return sorted(self._skills)

    def get(self, name: str) -> SkillRecord | None:
        return self._skills.get(str(name).strip().lower())

    def all(self) -> list[SkillRecord]:
        return [self._skills[n] for n in self.names()]

    def forget(self, name: str) -> bool:
        rec = self.get(name)
        if rec is None:
            return False
        del self._skills[rec.name]
        self.path_of(rec.name).unlink(missing_ok=True)
        self._reindex()
        self._log("skill_forgotten", name=rec.name)
        return True

    def find_name(self, text: str) -> SkillRecord | None:
        """The skill a player means by ``text`` ("deliver resource stacks", "the oak delivery one")."""
        key = re.sub(r"[\s-]+", "_", text.strip().lower())
        if key in self._skills:
            return self._skills[key]
        hits = self.retrieve(text, k=1, include_suspect=True)
        if hits and len(tokens(text) & tokens(hits[0].name.replace("_", " "))) >= 1:
            return hits[0]
        return None

    # ---------------------------------------------------------------- retrieval (FTS5 BM25)

    def _doc(self, rec: SkillRecord) -> str:
        goals = " ".join(rec.origin.get("goals") or [rec.origin.get("goal") or ""])
        return " ".join([rec.name.replace("_", " "), rec.description, " ".join(rec.params), goals])

    def _reindex(self) -> None:
        if not self._fts:
            return
        if self._db is not None:
            self._db.close()
        self._db = sqlite3.connect(":memory:")
        self._db.execute("CREATE VIRTUAL TABLE s USING fts5(name UNINDEXED, body, tokenize='porter unicode61')")
        self._db.executemany("INSERT INTO s(name, body) VALUES (?, ?)",
                             [(r.name, self._doc(r)) for r in self._skills.values()])

    def retrieve(self, text: str, k: int = 3, include_suspect: bool = False) -> list[SkillRecord]:
        words = [w for w in re.findall(r"[a-z0-9]+", (text or "").lower()) if len(w) > 1]
        if not words or not self._skills:
            return []
        if self._fts and self._db is not None:
            query = " OR ".join(f'"{w}"' for w in dict.fromkeys(words))
            rows = self._db.execute("SELECT name FROM s WHERE s MATCH ? ORDER BY bm25(s) LIMIT ?",
                                    (query, k + len(self._skills))).fetchall()
            ranked = [self._skills[n] for (n,) in rows if n in self._skills]
        else:  # plain token overlap if this sqlite has no FTS5
            want = tokens(text)
            scored = [(len(want & tokens(self._doc(r))), r) for r in self._skills.values()]
            ranked = [r for s, r in sorted(scored, key=lambda x: -x[0]) if s > 0]
        return [r for r in ranked if include_suspect or not r.stats.suspect][:k]

    # ---------------------------------------------------------------- expansion

    def expand(self, name: str, params: dict[str, Any], registry: SkillRegistry, _depth: int = 0) -> list[Task]:
        rec = self.get(name)
        if rec is None:
            raise SkillError(f"no skill called {name!r}")
        if _depth >= MAX_DEPTH:
            raise SkillError("skills nest too deeply")
        values = _coerce(rec, params)
        tasks: list[Task] = []
        for step in rec.steps:
            n = _subst(step.repeat, values)
            if not isinstance(n, int) or not 0 <= n <= MAX_REPEAT:
                raise SkillError(f"repeat must be 0-{MAX_REPEAT}, got {n!r}")
            args = _subst(step.args, values)
            for _ in range(n):
                if step.skill in registry:
                    try:
                        tasks.append(Task(skill=step.skill, args=registry.validate(step.skill, args)))
                    except ValidationError as exc:
                        raise SkillError(f"step {step.skill}: {exc.errors(include_url=False)}") from None
                elif self.get(step.skill):
                    tasks.extend(self.expand(step.skill, args, registry, _depth + 1))
                else:
                    raise SkillError(f"step {step.skill!r} is not a skill I have")
                if len(tasks) > MAX_STEPS:
                    raise SkillError("skill expands to too many steps")
        return tasks

    # ---------------------------------------------------------------- stats

    def record_run(self, name: str, ok: bool, seconds: float, reason: str | None = None) -> None:
        rec = self.get(name)
        if rec is None:
            return
        st = rec.stats
        st.runs += 1
        st.last_run = round(time.time())
        st.last_s = round(seconds, 1)
        if ok:
            st.ok += 1
            st.total_s += seconds
        else:
            st.failed += 1
            st.last_reason = reason
        self.save(rec)
        self._log("skill_stats", name=name, ok=ok, seconds=round(seconds, 1), runs=st.runs, success=st.ok,
                  suspect=st.suspect)

    # ---------------------------------------------------------------- learning

    def learn(self, goal: str, tasks: list[Task], state: dict, llm: LLMClient, registry: SkillRegistry,
              seconds: float | None = None, build: str | None = None, max_repairs: int = 1) -> SkillRecord | None:
        """Generalise a verified task list into a skill and save it. None when it can't be done
        faithfully (the record is never stored unverified). Same as ``propose`` then ``accept``."""
        proposal = self.propose(goal, tasks, state, llm, registry, max_repairs=max_repairs)
        if proposal is None:
            return None
        return self.accept(proposal, goal, tasks, state, registry, seconds=seconds, build=build)

    @staticmethod
    def _verified(tasks: list[Task], registry: SkillRegistry) -> list[tuple[str, dict]]:
        # the verified sequence (failed, replanned-away steps are dropped)
        return [(t.skill, registry.validate(t.skill, t.args)) for t in tasks if t.done]

    def _check(self, rec: SkillRecord, example: dict, actual: list[tuple[str, dict]], state: dict,
               registry: SkillRegistry) -> None:
        """The faithfulness gate (expanding with example_params reproduces the verified steps exactly) and the
        postcondition on the given state. Raises SkillError."""
        got = [(t.skill, t.args) for t in self.expand_record(rec, example, registry)]
        if got != actual:
            raise SkillError(f"expanding with example_params gives {got}, expected {actual}")
        if _postcondition_holds(rec.postcondition, _coerce(rec, example), state) is False:
            raise SkillError("the postcondition does not hold in the current game state")

    def propose(self, goal: str, tasks: list[Task], state: dict, llm: LLMClient, registry: SkillRegistry,
                max_repairs: int = 1, before_request: Callable[[], bool] | None = None) -> tuple[SkillRecord, dict] | None:
        """The model part of learning: one call (plus repair rounds) that names and parameterises the verified
        steps, checked on ``state``. Writes no skill records, so it can run on a worker thread over its OWN
        library instance (docs/design/director.md section 12 item 4); the agent loop then calls ``accept``.
        An optional admission callback runs before every request; returned usage is logged before validation.
        """
        actual = self._verified(tasks, registry)
        if len(actual) < 2:
            return None
        prompt = LEARN_PROMPT.format(skills=json.dumps(registry.describe()), existing=self.names() or "none",
                                     kinds=json.dumps(PRECONDITION_KINDS))
        user = {"goal": goal, "verified_steps": [{"skill": s, "args": a} for s, a in actual]}
        messages = [{"role": "system", "content": prompt}, {"role": "user", "content": json.dumps(user)}]
        for round_ in range(max_repairs + 1):
            if before_request is not None and not before_request():
                raise BudgetStop("skill learning daily budget unavailable or exhausted")
            # Reuse the adapter input contract, including cache blocks/settings and truthful boundary.
            # https://docs.litellm.ai/docs/completion/input
            self._log("prompt", component="skill_learner", model=llm.model, round=round_,
                      **request_log_fields(llm, messages))
            resp = llm.complete(messages)
            # Account for each paid response before validation or another admission decision.
            # https://docs.litellm.ai/docs/observability/custom_callback
            self._log("llm_response", component="skill_learner", model=llm.model, round=round_,
                      content=resp.content, usage=resp.usage, finish_reason=resp.finish_reason,
                      tool_calls=[vars(c) for c in resp.tool_calls])
            try:
                rec, example = self._parse(resp.content or "")
                self._check(rec, example, actual, state, registry)
            except (ValueError, ValidationError, SkillError) as exc:
                self._log("skill_invalid", error=str(exc)[:500], round=round_)
                messages = messages + [{"role": "assistant", "content": resp.content or ""},
                                       {"role": "user", "content": f"Invalid: {exc}\nReturn corrected JSON only."}]
                continue
            return rec, example
        return None

    def accept(self, proposal: tuple[SkillRecord, dict], goal: str, tasks: list[Task], state: dict,
               registry: SkillRegistry, seconds: float | None = None, build: str | None = None) -> SkillRecord | None:
        """The deterministic part, on the library that owns the files: re-check the proposal against THIS
        library and fresh ``state``, then save it (or note it as a variant). None when it no longer holds."""
        rec, example = proposal
        try:
            self._check(rec, example, self._verified(tasks, registry), state, registry)
        except (ValueError, ValidationError, SkillError) as exc:
            self._log("skill_invalid", error=str(exc)[:500], round="accept")
            return None
        return self._store_learned(rec, goal, seconds, build)

    def expand_record(self, rec: SkillRecord, params: dict, registry: SkillRegistry) -> list[Task]:
        """Expand a record that is not (yet) in the library."""
        saved = self._skills.get(rec.name)
        self._skills[rec.name] = rec
        try:
            return self.expand(rec.name, params, registry)
        finally:
            if saved is None:
                del self._skills[rec.name]
            else:
                self._skills[rec.name] = saved

    @staticmethod
    def _parse(text: str) -> tuple[SkillRecord, dict]:
        start, end = text.find("{"), text.rfind("}")
        if start == -1 or end < start:
            raise ValueError("no JSON object in response")
        raw = json.loads(text[start: end + 1])
        example = raw.pop("example_params", None) or {}
        raw.pop("stats", None)
        return SkillRecord.model_validate(raw), example

    def _store_learned(self, rec: SkillRecord, goal: str, seconds: float | None, build: str | None) -> SkillRecord:
        same = self.get(rec.name) or next((r for r in self._skills.values() if r.signature() == rec.signature()), None)
        if same is not None:  # a variant of something known: keep the verified original, note the goal
            goals = list(dict.fromkeys([*(same.origin.get("goals") or []), goal]))[-5:]
            same.origin = {**same.origin, "goals": goals, "variants": int(same.origin.get("variants") or 1) + 1}
            self.save(same)
            self._log("skill_variant", name=same.name, goal=goal)
            return same
        rec.origin = {"goal": goal, "goals": [goal], "created": time.strftime("%Y-%m-%d %H:%M:%S"),
                      "build": build, "variants": 1}
        rec.stats = SkillStats(runs=1, ok=1, total_s=round(seconds or 0.0, 1), last_s=seconds,
                               last_run=round(time.time()))
        self.save(rec)
        self._log("skill_learned", name=rec.name, description=rec.description, file=str(self.path_of(rec.name)))
        return rec

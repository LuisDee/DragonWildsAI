"""Agent: wires Controller, Planner, Executor, the state store and the skill library to a GameInterface.

Event-driven: ``step()`` handles whatever events the body emitted and only calls a model when
there is something to interpret or plan. ``run_goal`` executes a plan task by task, replans on
failure (bounded) and asks for help when it runs out of options (design principle 8).

Speech (design section 19, Luis): every command gets a one-line reply; what can't be done is said
with the reason; a stuck job asks for help; long jobs get a short progress line at most every
~20 s (body progress events, delivered live while the action runs, plus task milestones).

Skills (brain/skill_library.py): a goal that completes with every task verified is generalised
into a learned skill (one Sonnet call); ``run_skill`` runs one through the executor with no
planner call; "what have you learned?" and "forget <skill>" are answered without a model.
"""
from __future__ import annotations

import re
import time
from typing import Literal

from .controller import Controller, describe_rule
from .executor import Executor, StateUnavailable
from .interface import RULE_TOOLS, Attacked, CommandReceived, Event, GameInterface, Reason
from .jsonl_log import JsonlLogger
from .planner import Planner, PlanError
from .skill_library import SkillError, SkillLibrary, check_preconditions
from .state_store import StateStore, Task

GoalResult = Literal["done", "stuck", "interrupted"]

LEARNED_RE = re.compile(r"^\s*(what (have|did) you (learn|learned|learnt)|what do you know how to do|"
                        r"(list|show) (me )?(your )?(skills|what you('ve| have)? learn(ed|t)?))\b", re.I)
FORGET_RE = re.compile(r"^\s*forget (?:about )?(?:the |your )?(?:skill |how to )?(.+?)[.!?]*\s*$", re.I)
HERE_WORDS = {"here", "there", "this spot", "where i am standing", "where you are"}


def _task_label(t: Task) -> str:
    bits = [str(v) for k, v in t.args.items() if k in ("resource", "item", "target", "player", "count") and v is not None]
    return f"{t.skill} {' '.join(bits)}".strip()


class Agent:
    def __init__(self, game: GameInterface, controller: Controller, planner: Planner, executor: Executor,
                 store: StateStore, logger: JsonlLogger, max_replans: int = 2, max_interrupts: int = 5,
                 skills: SkillLibrary | None = None, learn_skills: bool = True, build: str | None = None):
        self.game = game
        self.controller = controller
        self.planner = planner
        self.executor = executor
        self.store = store
        self.log = logger
        self.max_replans = max_replans
        self.max_interrupts = max_interrupts
        self.skills = skills
        self.learn_skills = learn_skills
        self.build = build
        self.active_goal: str | None = None
        self.pending_goal: str | None = None
        self.pending_tasks: list[Task] | None = None
        self.pending_skill: str | None = None
        self._cancelled = False
        self._last_reason: str | None = None
        game.set_progress_listener(self._on_progress)

    # ---------------------------------------------------------------- events

    def step(self) -> GoalResult | None:
        """Handle pending events, then start any goal the controller queued."""
        self.pump()
        if self.pending_goal:
            goal, tasks, skill = self.pending_goal, self.pending_tasks, self.pending_skill
            self.pending_goal, self.pending_tasks, self.pending_skill = None, None, None
            return self.run_goal(goal, tasks=tasks, skill=skill)
        return None

    def run_forever(self, poll_interval: float = 0.25) -> None:
        while True:
            self.step()
            time.sleep(poll_interval)

    def pump(self) -> None:
        for event in self.game.poll_events():
            self.handle_event(event)

    def handle_event(self, event: Event) -> None:
        self.log.log("event", event=event.model_dump())
        self.controller.note_event(event)
        if isinstance(event, Attacked):
            # Self-defence is a reflex: no model call needed.
            self.executor.run_task(Task(skill="attack", args={"target": event.by}))
        elif isinstance(event, CommandReceived):
            self._command(event)
        # Progress events are narrated live through the progress listener (_on_progress).

    def _on_progress(self, event: Event) -> None:
        if self.active_goal:
            self.controller.progress_event(event)

    # ---------------------------------------------------------------- commands

    def _command(self, event: CommandReceived) -> None:
        if self._skill_command(event.text):
            return
        try:
            state = self.executor.state()
        except StateUnavailable as exc:  # still let the Controller answer; actions will refuse
            state = {"unavailable": str(exc)}
        d = self.controller.decide(event.player, event.text, state, self.active_goal)
        if d.interrupts and self.active_goal:
            self._cancelled = True
        failure = d.refusals[0] if d.refusals else None
        extra: list[str] = []  # facts the body reported that the speech must carry (single voice)
        for call in d.actions:
            if call.name == "remember":
                self._remember(call.arguments, state, event.player)
                continue
            if call.name in RULE_TOOLS:
                res = self._rule_tool(call.name, call.arguments, extra)
                if not res["ok"] and failure is None:
                    failure = (call.name, res["reason"], res["data"])
                continue
            outcome = self.executor.run_task(Task(skill=call.name, args=call.arguments))
            if not outcome.ok and failure is None:
                failure = (call.name, outcome.reason, outcome.data)
        if d.skill and failure is None:
            failure = self._queue_skill(*d.skill, state)
        if failure:
            self.controller.report_failure(*failure)
        elif d.speech or extra:
            self.controller.say(" ".join(s for s in [d.speech, *extra] if s))
        else:  # reply to every command, even when the model said nothing
            self.controller.say(self._default_reply(d))
        if d.goal and not d.skill:
            self.pending_goal = d.goal

    def _default_reply(self, d) -> str:
        if d.skill:
            return f"On it, I know how to do that ({d.skill[0]})."
        if d.goal:
            return f"On it: {d.goal}."
        for call in d.actions:
            if ack := self.controller.ack(call.name):
                return ack
        return "Sorry, I didn't catch that." if not d.actions else "Okay."

    def _remember(self, args: dict, state: dict, player: str) -> None:
        """remember(); a "place:<name>" whose value is "here" or a player's name is stored with its
        position (per-world places), so go_to(<name>) works later."""
        self.log.log("tool_call", tool="remember", args=args)
        key, value = str(args.get("key", "")), str(args.get("value", ""))
        res = self.store.remember(key, value)
        if key.lower().startswith("place:"):
            name = key.split(":", 1)[1].strip()
            pos = None
            low = value.strip().lower()
            if low in HERE_WORDS:
                pos = state.get("position")
            else:
                pos = next((p.get("position") for p in state.get("players") or []
                            if str(p.get("name", "")).lower() == low or (low in ("me", "you") and p.get("name") == player)),
                           None)
            if name:
                res = self.store.remember_place(name, pos if isinstance(pos, list) else None, note=value)
        self.log.log("tool_result", tool="remember", result=res)

    def _rule_tool(self, name: str, args: dict, extra: list[str]) -> dict:
        """Standing orders go straight to the body (no task, nothing to retry). A new rule counts
        only once the body's rule list shows it (verified state, principle 2)."""
        self.log.log("tool_call", tool=name, args=args)
        res = self.game.call(name, args)
        self.log.log("tool_result", tool=name, result=res)
        self.controller.rules_changed()
        if not res["ok"]:
            return res
        data = res["data"]
        if name == "set_reflex_rule":
            rid = (data.get("rule") or {}).get("id")
            listed = self.game.list_rules()
            ids = {r.get("id") for r in listed["data"].get("rules", [])} if listed["ok"] else set()
            if not rid or rid not in ids:
                self.log.log("verification_failed", tool=name, problem="rule not in list_rules", rule=rid)
                return {"ok": False, "reason": Reason.VERIFICATION_FAILED, "data": data}
            if listed["ok"]:
                self.store.save_rules(listed["data"].get("rules") or [])
            if note := self.controller.warning_note(data.get("warnings") or []):
                extra.append(note)
        elif name == "list_rules":
            rules = data.get("rules") or []
            extra.append("My standing orders: " + "; ".join(describe_rule(r) for r in rules) + "."
                         if rules else "I have no standing orders.")
        elif name == "clear_rule":
            n = len(data.get("removed") or [])
            extra.append(f"Forgot {n} order{'s' if n != 1 else ''}.")
        return res

    # ---------------------------------------------------------------- skills

    def _skill_command(self, text: str) -> bool:
        """'what have you learned?' / 'forget <skill>': answered from the library, no model call."""
        if not self.skills:
            return False
        if LEARNED_RE.match(text):
            recs = self.skills.all()
            self.log.log("skill_command", command="list", skills=[r.name for r in recs])
            if not recs:
                self.controller.say("I haven't learned any skills yet. When I finish a job, I'll remember how I did it.")
            else:
                parts = [f"{r.name} ({r.stats.ok}/{r.stats.runs} ok)" if r.stats.runs else r.name for r in recs]
                self.controller.say(f"I've learned {len(recs)} skill{'s' if len(recs) != 1 else ''}: " + ", ".join(parts) + ".")
            return True
        m = FORGET_RE.match(text)
        if m:
            rec = self.skills.find_name(m.group(1))
            if rec is None:
                return False  # "forget that" etc. is a standing order for the Controller
            self.skills.forget(rec.name)
            self.log.log("skill_command", command="forget", name=rec.name)
            self.controller.say(f"Okay, I've forgotten how to {rec.name.replace('_', ' ')}.")
            return True
        return False

    def _queue_skill(self, name: str, params: dict, state: dict) -> tuple[str, str, dict] | None:
        """Expand and check a learned skill now; queue it as a goal. A refusal tuple on failure."""
        rec = self.skills.get(name) if self.skills else None
        if rec is None:
            return "run_skill", Reason.UNKNOWN_SKILL, {"skill": name}
        try:
            tasks = self.skills.expand(name, params, self.store.skills)
        except SkillError as exc:
            self.log.log("skill_expand_failed", name=name, params=params, error=str(exc))
            return "run_skill", f"can't use it like that ({exc})", {"skill": name}
        if not state.get("unavailable"):
            problems = check_preconditions(rec, params, state)
            if problems:
                self.log.log("skill_preconditions_failed", name=name, problems=problems)
                return "run_skill", "; ".join(problems), {"skill": name}
        bits = ", ".join(f"{k}={v}" for k, v in params.items())
        self.pending_goal = f"{name}({bits})" if bits else name
        self.pending_tasks, self.pending_skill = tasks, rec.name
        self.log.log("skill_queued", name=name, params=params, tasks=[t.model_dump() for t in tasks])
        return None

    def _learn(self, goal: str, seconds: float) -> None:
        tree = self.store.tree
        if not (self.skills and self.learn_skills and tree):
            return
        if sum(1 for t in tree.tasks if t.done) < 2:
            return
        try:
            fresh = self.executor.state()  # the verification gate needs fresh game state
            rec = self.skills.learn(goal, tree.tasks, fresh, self.planner.llm, self.store.skills,
                                    seconds=seconds, build=self.build)
        except Exception as exc:  # learning is a bonus; never break the session over it
            self.log.log("skill_learn_error", goal=goal, error=repr(exc))
            return
        if rec is not None and rec.origin.get("variants", 1) == 1:
            self.controller.say(f"I'll remember how to do that next time ({rec.name}).")

    # ---------------------------------------------------------------- goals

    def _stuck(self, goal: str, task: Task | None, reason: str | None, question: str | None = None) -> GoalResult:
        if self.store.tree:
            self.store.tree.status = "stuck"
            self.store.save_tree()
        self._last_reason = reason
        self.store.progress("stuck", goal=goal, reason=reason)
        self.controller.ask_for_help(goal, task.skill if task else None, reason, question)
        return "stuck"

    def _planner_notes(self) -> dict:
        notes = dict(self.store.notes())
        for name, rec in self.store.places().items():
            if isinstance(rec, dict) and rec.get("position"):
                notes[f"place:{name}"] = f"go_to target [x, y, z] = {rec['position']}" + (
                    f" ({rec['note']})" if rec.get("note") else "")
        return notes

    def run_goal(self, goal: str, tasks: list[Task] | None = None, skill: str | None = None) -> GoalResult:
        self.active_goal, self._cancelled, self._last_reason = goal, False, None
        self.controller.job_started()
        start = time.monotonic()
        result: GoalResult = "stuck"
        try:
            result = self._run_goal(goal, tasks)
        except StateUnavailable:  # the planner needs fresh state too
            result = self._stuck(goal, None, Reason.STATE_UNAVAILABLE)
        finally:
            self.active_goal = None
        elapsed = time.monotonic() - start
        if skill and self.skills and result != "interrupted":
            self.skills.record_run(skill, result == "done", elapsed, self._last_reason)
        elif result == "done" and not skill:
            self._learn(goal, elapsed)
        return result

    def _run_goal(self, goal: str, given: list[Task] | None = None) -> GoalResult:
        self.store.progress("goal started", goal=goal, from_skill=given is not None)
        if given is None:
            try:
                plan = self.planner.plan(goal, self.executor.state(), self._planner_notes())
            except PlanError as exc:
                return self._stuck(goal, None, str(exc))
            if not plan.tasks:
                return self._stuck(goal, None, "no plan", plan.ask_help)
            given = plan.tasks
        tree = self.store.set_goal(goal, given)
        interrupts = 0

        while (task := tree.next_task()) is not None:
            outcome = self.executor.run_task(task)
            if outcome.interrupt:
                interrupts += 1
                self.pump()
                if self._cancelled:
                    break
                if interrupts > self.max_interrupts:
                    return self._stuck(goal, task, "interrupted too often")
                continue  # resume the same task
            if outcome.ok:
                done = sum(1 for t in tree.tasks if t.done)
                self.controller.milestone(done, len(tree.tasks), _task_label(task))
                self.pump()  # Luis may have said something between steps
                if self._cancelled:
                    break
                continue
            # Retries exhausted (or not retryable): DEPS replan, bounded.
            self._last_reason = outcome.reason
            if tree.replans >= self.max_replans:
                return self._stuck(goal, task, outcome.reason)
            tree.replans += 1
            try:
                new = self.planner.replan(tree, task, outcome.reason, self.executor.state(), self._planner_notes())
            except PlanError as exc:
                return self._stuck(goal, task, str(exc))
            self.store.progress("replanned", goal=goal, explanation=new.explanation, ask_help=new.ask_help)
            if new.ask_help or not new.tasks:
                return self._stuck(goal, task, outcome.reason, new.ask_help)
            tree.tasks = [t for t in tree.tasks if t.done or t is task] + new.tasks
            self.store.save_tree()

        if self._cancelled:
            tree.status = "interrupted"
            self.store.save_tree()
            self.store.progress("goal interrupted", goal=goal)
            return "interrupted"
        tree.status = "done"
        self.store.save_tree()
        self.store.progress("goal done", goal=goal)
        self.controller.goal_done(goal)
        return "done"

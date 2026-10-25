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

import time
from typing import Literal

from . import situation as sit
from .broker import BODY_SITUATIONS, EventBroker, facts, fallback_line
from .controller import LONG_ACTIONS, Controller, describe_rule
from .executor import Executor, Outcome, StateUnavailable
from .interface import (RULE_TOOLS, Activity, Attacked, CommandReceived, Event, GameInterface, Reason, TaskDone,
                        TaskFailed)
from .jsonl_log import JsonlLogger
from .planner import Planner, PlanError
from .skill_library import SkillError, SkillLibrary, check_preconditions
from .state_store import StateStore, Task

GoalResult = Literal["done", "stuck", "interrupted"]

# Help lines the companion says by itself (no model call) when it can't handle something alone.
# At most one per key per HELP_REPEAT_S seconds, so a fight doesn't spam chat.
HELP_REPEAT_S = 60.0
# Body situations (unreachable, resumed, vitals_low) are triaged by broker.EventBroker and phrased by
# the Controller model; broker.fallback_line is the template safety net (streamline step 3).



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
        self._help_said: dict[str, float] = {}  # help key -> monotonic time last said
        # Event hygiene (streamline step 3): triage, movement episodes, digest, episodic memory.
        self.broker = EventBroker(logger, tool_of=getattr(game, "sent_tool", None))
        controller.status_provider = self.broker.digest
        controller.activity_provider = self.broker.activity_lines
        self._situations: list[dict] = []  # body situations waiting for one Controller run
        self._in_pump = False
        # True when the body runs its own self-defence reflex (client combat.lua guard): an attacked
        # event then needs no brain-side attack (it would fight the body's reflex for the pawn).
        self.body_self_defends = False
        self.clock = time.monotonic
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
        """Poll the body, triage the batch (broker), handle what is left, then voice the batch's body
        situations in ONE Controller run (unless a chat run will take them along)."""
        self._in_pump = True
        try:
            for event in self.broker.triage(self.game.poll_events()):
                self.handle_event(event)
        finally:
            self._in_pump = False
        self.flush_situations()

    def handle_event(self, event: Event) -> None:
        self.log.log("event", event=event.model_dump())
        if isinstance(event, BODY_SITUATIONS):
            self._body_situation(event)
            if not self._in_pump:
                self.flush_situations()
            return
        if isinstance(event, TaskFailed) and self.broker.held(event.task_id):
            self._body_situation(event)  # a follow ended by itself (review H1): the model says why
            if not self._in_pump:
                self.flush_situations()
            return
        if isinstance(event, (TaskDone, TaskFailed)):
            return  # the executor already has the result (synchronous reply); see broker.triage
        if isinstance(event, Activity):
            return self._activity(event)
        self.controller.note_event(event)
        if isinstance(event, Attacked):
            if self.body_self_defends:
                self.log.log("attacked_body_reflex", by=event.by)  # the body's own guard fights back
            elif "attack" in self.store.skills:
                # Self-defence is a reflex: no model call needed.
                self._run_task(Task(skill="attack", args={"target": event.by}))
            else:  # a body that can't fight yet (the client body today): say so and ask for help
                who = event.name or sit.pretty_id(event.by)
                self._help("attacked", f"Help! {who} is attacking me and I can't fight back yet.")
        elif isinstance(event, CommandReceived):
            self._command(event)
        # Progress events are narrated live through the progress listener (_on_progress).

    def _help(self, key: str, line: str) -> None:
        now = self.clock()
        last = self._help_said.get(key)
        if last is not None and now - last < HELP_REPEAT_S:
            self.log.log("help_suppressed", key=key)
            return
        self._help_said[key] = now
        self.log.log("help", key=key, text=line)
        self.controller.say(line)

    # ---------------------------------------------------------------- body situations (broker)

    def _fresh_state(self) -> dict:
        try:
            return self.executor.state()
        except StateUnavailable as exc:
            return {"unavailable": str(exc)}

    def _body_situation(self, event: Event) -> None:
        v = self.broker.assess(event, self._fresh_state())
        if v.action == "decide":
            self._situations.append(v.event)

    def _chat_waiting(self) -> bool:
        """True while chat lines wait for a Controller run that will take the situations along."""
        return False

    def take_situations(self, state: dict | None = None) -> list[dict]:
        """The pending situations still true now (a chat run takes them along: one line for both)."""
        events, self._situations = self._situations, []
        if not events:
            return []
        still = self.broker.still_valid(events, state if state is not None else self._fresh_state())
        for e in events:
            if e not in still:
                self.log.log("situation_stale", event=e, why="fixed before it was voiced")
        return still

    def flush_situations(self) -> None:
        if not self._situations or self._chat_waiting():
            return
        state = self._fresh_state()
        events = self.take_situations(state)
        if not events:
            return
        player = next((e["target"] for e in events if e.get("about") == "player" and e.get("target")), None)
        if not player:
            near = sorted((p for p in state.get("players") or [] if isinstance(p, dict) and p.get("name")),
                          key=lambda p: p.get("distance") if isinstance(p.get("distance"), (int, float)) else 1e9)
            player = str(near[0]["name"]) if near else self.controller.player
        try:
            self._command(CommandReceived(player=player, text=""), addressed=True, body_events=events)
        except Exception as exc:  # the model call failed: the template line still tells him
            self.log.log("situation_error", error=repr(exc), events=events)
            if line := fallback_line(events):
                if self.controller.say(line, kind="notice") is not None:
                    self.broker.voiced(events)

    def _activity(self, event: Activity) -> None:
        """Episodic memory: every completed body episode, whoever started it."""
        self.broker.remember_activity(event)
        line = self.broker.describe_activity(event)
        self.store.progress("activity", kind=event.kind, by=event.by, ts=event.ts, **event.fields())
        if self.broker.notable(event):
            when = time.strftime("%H:%M UTC", time.gmtime(event.ts)) if event.ts else "earlier"
            self.store.remember(f"last_{event.kind}", f"{when}: {line}")
            where = event.fields().get("where")
            if event.kind == "death" and isinstance(where, list) and len(where) >= 3:
                self.store.remember_place("grave", [float(c) for c in where[:3]],
                                          note=f"my gravestone (died {when}: {event.fields().get('cause') or '?'})")

    def _run_task(self, task: Task) -> Outcome:
        """Every body action the brain runs goes through here, so the broker knows the brain's own moves."""
        self.broker.action_started(task.skill, task.args)
        outcome = self.executor.run_task(task)
        self.broker.action_finished(task.skill, task.args, outcome.ok, outcome.reason, outcome.data)
        return outcome

    def _on_progress(self, event: Event) -> None:
        # Progress events only come while a long body action runs (a goal's task or a direct gather).
        self.controller.progress_event(event)

    # ---------------------------------------------------------------- commands

    def _command(self, event: CommandReceived, addressed: bool = True, body_events: list[dict] | None = None) -> None:
        """``addressed=False``: a chat line nobody addressed to the companion (LiveAgent's chat
        reading); the model may decide it is not for him, and then nothing is said or done.
        ``body_events``: body situations (broker) this run must also decide on; with an empty text it
        is a body-initiated run: the model phrases the line (or fixes it with a tool)."""
        state = self._fresh_state()  # unavailable: still let the Controller answer; actions will refuse
        body_ctx = (body_events[0] if len(body_events) == 1 else {"events": body_events}) if body_events else None
        d = self.controller.decide(event.player, event.text, state, self.active_goal, addressed=addressed,
                                   body_event=body_ctx)
        if body_events:  # speak-time check of the situation itself, on fresh state
            state = self._fresh_state()
            still = self.broker.still_valid(body_events, state)
            if not still and not (d.actions or d.goal or d.skill):
                self.log.log("situation_stale", events=body_events, why="fixed while the model was thinking",
                             speech=d.speech)
                if not event.text:
                    return
            body_events = still
        d, state = self._fresh_reply(event, d, state, addressed, body_ctx)
        if not addressed and not (d.actions or d.goal or d.skill or d.refusals or d.speech):
            self.log.log("chat_decision", player=event.player, text=event.text, decision="ignored",
                         reason="model: not meant for me")
            return
        if not addressed:
            self.log.log("chat_decision", player=event.player, text=event.text, decision="addressed",
                         reason="model: meant for me", actions=[c.name for c in d.actions], speech=d.speech)
        if d.interrupts and self.active_goal:
            self._cancelled = True
        failure = d.refusals[0] if d.refusals else None
        # the call that failed (a body action, or one refused for bad args): its result goes back to the model
        failed_call = d.invalid[0] if d.invalid and failure and failure[0] == d.invalid[0].name else None
        results: dict[str, dict] = {}  # call id -> result of the steps that ran (multi-step turns)
        extra: list[str] = []  # facts the body reported that the speech must carry (single voice)
        spoken = False  # a long action's reply is said when it starts
        for call in d.actions:
            if call.name in ("remember", "forget_skill"):
                res = self._remember(call.arguments, state, event.player) if call.name == "remember" \
                    else self._forget_skill(call.arguments)
                results[call.id or call.name] = res
                if not res.get("ok", True) and failure is None:
                    failure, failed_call = (call.name, res["reason"], res["data"]), call
                    break
                continue
            if call.name in RULE_TOOLS:
                res = self._rule_tool(call.name, call.arguments, extra)
                if not res["ok"] and failure is None:
                    failure = (call.name, res["reason"], res["data"])
                continue
            if call.name in LONG_ACTIONS and failure is None and not spoken:
                self.controller.say(d.speech or self.controller.ack(call.name) or "On it.")
                self.controller.job_started()
                spoken = True
            outcome = self._run_task(Task(skill=call.name, args=call.arguments))
            results[call.id or call.name] = {"ok": outcome.ok, "reason": outcome.reason, "data": outcome.data}
            if not outcome.ok and failure is None:
                failure, failed_call = (call.name, outcome.reason, outcome.data), call
                break  # steps run in order and stop at the first that fails (the model hears why)
            elif outcome.ok and call.name in LONG_ACTIONS:
                extra.append(self._long_done(call.name, call.arguments, outcome.data))
        if d.skill and failure is None:
            failure = self._queue_skill(*d.skill, state)
        kind = "notice" if body_events and not event.text else "reply"
        res = None
        if failure and failed_call is not None and failure[1] not in Reason.INTERRUPTS:  # model hears why
            self._explain_failure(d, failed_call, failure, state, results)
        elif failure:
            self.controller.report_failure(*failure)
        elif spoken:
            if extra:
                self.controller.say(" ".join(extra))
        elif d.speech or extra:
            res = self.controller.say(" ".join(s for s in [d.speech, *extra] if s), kind=kind)
        elif body_events and not event.text:  # the model said nothing about a body situation: the template
            res = self.controller.say(fallback_line(body_events) or self._default_reply(d), kind=kind)
        elif addressed:  # reply to every command, even when the model said nothing
            res = self.controller.say(self._default_reply(d))
        if body_events and (res is not None or failure or spoken):
            self.broker.voiced(body_events)
        if d.goal and not d.skill:
            self.pending_goal = d.goal

    def _explain_failure(self, d, call, failure: tuple, state: dict, results: dict | None = None) -> None:
        """PRINCIPLES.md #2: the body's truthful result goes back to the model, which says what happened
        and may try ONE fix or ask. The reason templates (report_failure) are only the safety net when
        the model call fails or says nothing."""
        tool, reason, data = failure
        try:
            d2 = self.controller.follow_up(d, call, {"ok": False, "reason": reason, "data": data}, state, results)
        except Exception as exc:  # model/provider error: the template still says why
            self.log.log("follow_up_error", tool=tool, error=repr(exc))
            return self.controller.report_failure(*failure)
        if d2.refusals:
            return self.controller.report_failure(*d2.refusals[0])
        fix = next((c for c in d2.actions if c.name not in ("remember", *RULE_TOOLS)), None)
        if fix is not None:
            outcome = self._run_task(Task(skill=fix.name, args=fix.arguments))
            if not outcome.ok:  # no second follow-up: say why, from the body's result
                return self.controller.report_failure(fix.name, outcome.reason, outcome.data)
            return self.controller.say(d2.speech or self.controller.ack(fix.name) or "Done.")
        if d2.speech:
            return self.controller.say(d2.speech)
        self.controller.report_failure(*failure)

    def _fresh_reply(self, event: CommandReceived, d, state: dict, addressed: bool, body_ctx: dict | None):
        """Single voice, speak-time check: a pure-talk reply decided on facts that changed while the
        model was thinking (he arrived, ate, drank, got something) is decided once more on fresh state."""
        if not d.speech or d.actions or d.goal or d.skill or d.refusals:
            return d, state
        before = facts(state)
        if not before:
            return d, state
        fresh = self._fresh_state()
        after = facts(fresh)
        changed = {k: (before.get(k), after.get(k)) for k in before.keys() | after.keys() if before.get(k) != after.get(k)}
        if not after or not changed:
            return d, state
        self.log.log("speech_redecided", changed=changed, first=d.speech)
        return self.controller.decide(event.player, event.text, fresh, self.active_goal, addressed=addressed,
                                      body_event=body_ctx), fresh

    @staticmethod
    def _long_done(tool: str, args: dict, data: dict) -> str:
        if tool == "gather":
            n = data.get("gathered") or args.get("count")
            what = sit.name_of_item(str(data["item"]), {}) if data.get("item") else args.get("resource")
            return f"Done, gathered {n} {what}."
        return "Done."

    def _default_reply(self, d) -> str:
        if d.skill:
            return f"On it, I know how to do that ({d.skill[0]})."
        if d.goal:
            return f"On it: {d.goal}."
        for call in d.actions:
            if ack := self.controller.ack(call.name):
                return ack
        return "Sorry, I didn't catch that." if not d.actions else "Okay."

    def _remember(self, args: dict, state: dict, player: str) -> dict:
        """remember(); a "place:<name>" with at=self | player is stored with that position (per-world
        places), so go_to(<name>) works later. The model says where (review M6: no word list); a place
        with no position it could resolve is a failure the model hears."""
        self.log.log("tool_call", tool="remember", args=args)
        key, value = str(args.get("key", "")), str(args.get("value", ""))
        res = self.store.remember(key, value)
        if key.lower().startswith("place:") and (name := key.split(":", 1)[1].strip()):
            pos = None
            if args.get("at") == "self":
                pos = state.get("position")
            elif args.get("at") == "player":
                who = str(args.get("player") or player)
                pos = next((p.get("position") for p in state.get("players") or []
                            if isinstance(p, dict) and str(p.get("name", "")).lower() == who.lower()), None)
            res = self.store.remember_place(name, pos if isinstance(pos, list) else None, note=value)
            if args.get("at") and not isinstance(pos, list):
                res = {"ok": False, "reason": "no_position",
                       "data": {"place": name, "at": args.get("at"), "detail": "couldn't read that position now"}}
        self.log.log("tool_result", tool="remember", result=res)
        return res

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

    def _forget_skill(self, args: dict) -> dict:
        """forget_skill(name): the model chose to; an exact name only (no fuzzy deletes, review H3)."""
        name = str(args.get("name") or "")
        rec = self.skills.get(name) if self.skills else None
        if rec is None:
            names = [r.name for r in self.skills.all()] if self.skills else []
            return {"ok": False, "reason": Reason.UNKNOWN_SKILL, "data": {"skill": name, "learned": names}}
        self.skills.forget(rec.name)
        self.log.log("skill_command", command="forget", name=rec.name)
        return {"ok": True, "reason": None, "data": {"forgot": rec.name}}

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
            outcome = self._run_task(task)
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

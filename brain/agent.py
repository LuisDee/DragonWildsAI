"""Agent: wires Controller, Planner, Executor and the state store to a GameInterface.

Event-driven: ``step()`` handles whatever events the body emitted and only
calls a model when there is something to interpret or plan. ``run_goal``
executes a plan task by task, replans on failure (bounded) and asks for help
when it runs out of options (design principle 8).
"""
from __future__ import annotations

import time
from typing import Literal

from .controller import Controller
from .executor import Executor, StateUnavailable
from .interface import Attacked, CommandReceived, Event, GameInterface, Reason
from .jsonl_log import JsonlLogger
from .planner import Planner, PlanError
from .state_store import StateStore, Task

GoalResult = Literal["done", "stuck", "interrupted"]


class Agent:
    def __init__(self, game: GameInterface, controller: Controller, planner: Planner, executor: Executor,
                 store: StateStore, logger: JsonlLogger, max_replans: int = 2, max_interrupts: int = 5):
        self.game = game
        self.controller = controller
        self.planner = planner
        self.executor = executor
        self.store = store
        self.log = logger
        self.max_replans = max_replans
        self.max_interrupts = max_interrupts
        self.active_goal: str | None = None
        self.pending_goal: str | None = None
        self._cancelled = False

    # ---------------------------------------------------------------- events

    def step(self) -> GoalResult | None:
        """Handle pending events, then start any goal the controller queued."""
        self.pump()
        if self.pending_goal:
            goal, self.pending_goal = self.pending_goal, None
            return self.run_goal(goal)
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

    def _command(self, event: CommandReceived) -> None:
        try:
            state = self.executor.state()
        except StateUnavailable as exc:  # still let the Controller answer; actions will refuse
            state = {"unavailable": str(exc)}
        d = self.controller.decide(event.player, event.text, state, self.active_goal)
        if d.interrupts and self.active_goal:
            self._cancelled = True
        failure = None
        for call in d.actions:
            if call.name == "remember":
                self.log.log("tool_call", tool="remember", args=call.arguments)
                self.log.log("tool_result", tool="remember", result=self.store.remember(**call.arguments))
                continue
            outcome = self.executor.run_task(Task(skill=call.name, args=call.arguments))
            if not outcome.ok and failure is None:
                failure = (call.name, outcome.reason)
        if failure:
            self.controller.report_failure(*failure)
        elif d.speech:
            self.controller.say(d.speech)
        if d.goal:
            self.pending_goal = d.goal

    # ---------------------------------------------------------------- goals

    def _stuck(self, goal: str, task: Task | None, reason: str | None, question: str | None = None) -> GoalResult:
        if self.store.tree:
            self.store.tree.status = "stuck"
            self.store.save_tree()
        self.store.progress("stuck", goal=goal, reason=reason)
        self.controller.ask_for_help(goal, task.skill if task else None, reason, question)
        return "stuck"

    def run_goal(self, goal: str) -> GoalResult:
        self.active_goal, self._cancelled = goal, False
        try:
            return self._run_goal(goal)
        except StateUnavailable:  # the planner needs fresh state too
            return self._stuck(goal, None, Reason.STATE_UNAVAILABLE)
        finally:
            self.active_goal = None

    def _run_goal(self, goal: str) -> GoalResult:
        self.store.progress("goal started", goal=goal)
        try:
            plan = self.planner.plan(goal, self.executor.state(), self.store.notes())
        except PlanError as exc:
            return self._stuck(goal, None, str(exc))
        if not plan.tasks:
            return self._stuck(goal, None, "no plan", plan.ask_help)
        tree = self.store.set_goal(goal, plan.tasks)
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
                self.pump()  # Luis may have said something between steps
                if self._cancelled:
                    break
                continue
            # Retries exhausted (or not retryable): DEPS replan, bounded.
            if tree.replans >= self.max_replans:
                return self._stuck(goal, task, outcome.reason)
            tree.replans += 1
            try:
                new = self.planner.replan(tree, task, outcome.reason, self.executor.state(), self.store.notes())
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

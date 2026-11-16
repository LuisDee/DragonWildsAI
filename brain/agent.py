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
from .consume_order import interleave
from .broker import BODY_SITUATIONS, REVIEW_SAMPLE_S, EventBroker, facts, fallback_line
from .controller import LONG_ACTIONS, Controller, describe_rule
from .executor import Executor, Outcome, StateUnavailable
from .interface import (PROGRESS_EVENTS, RULE_TOOLS, Activity, Attacked, ChatHeard, CommandReceived, Event,
                        GameInterface, Reason, TaskDone, TaskFailed)
from .jsonl_log import JsonlLogger
from .planner import Planner, PlanError
from .progress import RepeatWatch, change
from .skill_library import SkillError, SkillLibrary, check_preconditions
from .state_store import StateStore, Task

GoalResult = Literal["done", "stuck", "interrupted"]

# Help lines the companion says by itself (no model call) when it can't handle something alone.
# At most one per key per HELP_REPEAT_S seconds, so a fight doesn't spam chat.
HELP_REPEAT_S = 60.0
# The agent loop: model turns after the first, per request (every turn's results go back to the model),
# bounded by a turn cap and a wall deadline (a long chain such as "make an axe then cut a tree" fits).
MAX_TURNS = 8
# The turn budget ended a request with work open: it is handed on as a body situation this many times at most
# (agent._hand_on), each a fresh run in which the model sees how its last calls went.
CHAIN_BUDGET = "chain_budget"
MAX_HAND_ONS = 2
WORK_DETAIL_CHARS = 220  # a call's own result words kept in a hand-on's done_so_far
WORK_ROWS = 40
# The no-progress breaker parked a step (brain/progress.py): the model's last turn of this request.
PARKED_NOTE = ("A step is parked (results above): the same call failed the same way with no progress. If the player "
               "hasn't heard why, tell him in one short plain line; this request ends after this reply.")
# Wall time for one request's chain: a go_to alone may take 295 s (the body's timeout), and the steps after it fit.
REQUEST_SECONDS = 600.0
# The deadline passed during a body action: the model still hears how it went, and this turn is the chain's last.
LAST_TURN_NOTE = ("Time is up for this request (results above). If the player hasn't heard how it went, tell him in "
                  "one short plain line; this request ends after this reply.")
# Tools that take a while: the turn's line is said as they start, so it is true when said.
# gather is not here: its line is held and said once the body has the job under way (bridge_client ACCEPTED_AFTER_S),
# as a player talks while he walks to the rock. Said first, the chat box cost 0.57 s of standing before every gather
# (rung 3 mine 2026-11-16), and a gather refused at once had "on it" in chat before its reason
ANNOUNCE_FIRST = {"go_to", "come_to", *LONG_ACTIONS} - {"gather"}
# A turn of only these is a standing behaviour, not a step of a plan: no continuation turn.
STANDING = {"follow", "stop"}
# Voice eval v2 (2026-10-26): the old note offered only "call it" or "say nothing", so a line the model
# could not back up (no tool or target for it, e.g. a walk to a spot it can't name) was left standing
# with no reason. It now also covers "I'm doing X" claims and has an honest third option (Anthropic,
# reduce-hallucinations: give the model an explicit out), per Luis's "say what you can't do and why".
PROMISE_NOTE = ("You replied without calling any tool. That line has been said. If it says you will do "
                "something, or that you are doing it, call the tool(s) for it now, in order. If you can't do it "
                "now (no tool or target for it, or something is missing), say in a few words what's stopping you. "
                "Otherwise (you only answered or asked something) reply with no text at all.")
# Co-play 2026-11-01 11:50:11: the player asked "so why couldn't you validate ...", and the model wrote its answer as
# plain text (a private note, never spoken) with no say call: he got silence. The model is told the truth once and
# decides; code never speaks the note itself (it can be reasoning, controller.py SAY_SCHEMA).
UNHEARD_NOTE = ("Nobody heard that: you wrote plain text and called no tool, and only say(text) is heard in chat. If "
                "it was meant for the player, say it now with say; otherwise reply with no text at all.")
# Build run 2026-11-01 20:29:57Z: his line "roof only covers part, second piece won't seat. I'll keep at it" came with
# a store call; the next turn returned no call and the request ended there. A later turn that stops with nothing,
# right after a line of his was said, is told once what he last said; the model decides (never a veto, code never
# speaks for him). Decided on the turn's shape only, never the line's words.
# Rung4 gear_up run 2026-11-01 23:36:46Z: interact on a grave failed path_blocked twice with the guard's true reason ("I
# can't get to the Player Gravestone safely ... a drop that killed me 4 times"); he drank, ate, went to another grave and
# said "got my gear back from the grave": the can't-do never reached the player. A request that is about to end with a
# failure no later line of his followed gets ONE more turn, told which (the result's own detail). The model decides
# (code never speaks for it, never a phrase rule); decided on the turn's shape only.
UNREPORTED_NOTE = ("Before you stop: these steps failed and {player} hasn't heard about it from you: {items}. He should "
                   "know what you couldn't do and why: say it in one short plain line with the real reason from the "
                   "result, unless a later step already sorted it out. If it's sorted, reply with no text at all.")
STOP_NOTE = ("You stopped: no tool call and nothing said. Your last line to the player was: {line!r}. If it says you "
             "will keep going or do more, call the tool(s) for that now. If you can't, say in a few words what's "
             "stopping you. If it's done, reply with no text at all.")
# Live 2026-11-02 gear_up (logs/brain-live-20261102-013020-15324.jsonl): "gear up properly" met a failed craft (no
# thread: the wheels need a roof) and he ended the request with "short on bones and leather, any spare?", the job
# dropped although his situation listed the no-thread set and a task board was offered. A player's request that is
# about to end after a body failure, with no long-job tool called in it, gets ONE turn reminding him of the request and
# the long-job tool. The model decides (replay of that turn: 5/5 hand the rest on; "truly blocked" stays a choice).
OPEN_JOB_NOTE = ("He asked {request!r}. This request ends here unless you act: if that job isn't finished and another "
                 "route exists (your situation lists them), take it now or hand the rest to {tool}; if you are truly "
                 "blocked, reply with no text at all.")
LONG_JOB_TOOLS = ("add_task", "start_goal")
TASK_DETAIL_CHARS = 900  # a step's own result words kept on its task for the Planner
# Body situations (unreachable, resumed, vitals_low) are triaged by broker.EventBroker and phrased by
# the Controller model; broker.fallback_line is the template safety net (streamline step 3).

FRESH_REUSE_S = 0.75  # get_state reuse window between body reads with no action in between (see _fresh_state)
POST_ACTION_REUSE_S = 1.0  # the executor's own verification read is this fresh: the next prompt reads it



def _task_label(t: Task) -> str:
    bits = [str(v) for k, v in t.args.items() if k in ("resource", "item", "target", "player", "count") and v is not None]
    return f"{t.skill} {' '.join(bits)}".strip()


def _work_rows(d, t: dict, chars: int, unrun: bool = False) -> list[dict]:
    """One model turn's calls as short rows {tool, args, ok, reason, detail}: what a hand-on tells the fresh run.
    unrun: a call with no result (after a failure) is listed too."""
    rows = []
    for c in d.actions:
        r = t["results"].get(c.id) or t["results"].get(c.name)
        if r is None and not unrun:
            continue
        r = r or {}
        data = r.get("data") if isinstance(r.get("data"), dict) else {}
        rows.append({"tool": c.name, "args": c.arguments, "ok": r.get("ok"), "reason": r.get("reason"),
                     "detail": str(data.get("detail") or data.get("built") or data.get("why") or "")[:chars] or None})
    return rows


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
        self.broker = EventBroker(logger, tool_of=getattr(game, "sent_tool", None),
                                  abandoned=getattr(game, "abandoned", None),
                                  late_result=getattr(game, "late_result", None))
        controller.status_provider = self.broker.digest
        controller.activity_provider = self.broker.activity_lines
        controller.on_progress = self.broker.note_progress  # progress notes -> body_status, never said
        self._situations: list[dict] = []  # body situations waiting for one Controller run
        self._stash: list[Event] = []  # events peeked during a chain (handled by the next pump)
        self.budget = None  # brain.budget.Budget (LiveSession): the daily model-spend cap
        self.check_promises = True  # L5: a talk-only first turn gets one turn to call what it promised
        self.repeats = RepeatWatch()  # the no-progress breaker (brain/progress.py)
        self.request_calls = 0  # model calls of the last _command_run (a board step's call budget)
        self._asked: dict | None = None  # where he stood when the open request was asked (situation "Asked:")
        self._goal_asked: dict | None = None  # the same for the goal now running (_goal_request)
        self.request_parked: str | None = None  # the last _command_run ended on a parked step: why
        self._sampled_at: float | None = None  # last get_state the broker observed (situation_review)
        self._in_pump = False
        # The model's line held back during a quick action (said after it, unless a failure replaces it): said
        # as soon as the bridge reports the action accepted and still running (bridge_client.ACCEPTED_AFTER_S).
        self._held: dict | None = None
        if hasattr(game, "on_long_action"):
            game.on_long_action = self._long_action
        # True when the body runs its own self-defence reflex (client combat.lua guard): an attacked
        # event then needs no brain-side attack (it would fight the body's reflex for the pawn).
        self.body_self_defends = False
        self.clock = time.monotonic
        # Task board (brain/director.py, docs/design/director.md): attached by LiveSession when DW_DIRECTOR=1.
        self.director = None
        self._directed: list[dict] | None = None  # action records of the board run in progress (run_directed)
        self._directed_end = "normal"
        self._directed_origin = "board"  # "chat" while a chat command runs nested inside a board run (re-check 2)
        self._quiet_goal = False  # run_goal(quiet=True) inside board runs: no goal situations, no Planner replans
        game.set_progress_listener(self._on_progress)

    # ---------------------------------------------------------------- events

    def step(self) -> GoalResult | None:
        """Handle pending events, then start any goal the controller queued."""
        self.pump()
        if self.pending_goal:
            goal, tasks, skill = self.pending_goal, self.pending_tasks, self.pending_skill
            self.pending_goal, self.pending_tasks, self.pending_skill = None, None, None
            if self.budget is not None and not self.budget.allows("planner"):
                self.log.log("goal_dropped", goal=goal, why="out of model budget")
                if self.budget.out_line_due():
                    self.controller.say(self.budget.out_line())
                return "stuck"
            eid, self._goal_episode = getattr(self, "_goal_episode", None), None
            with self.log.episode(eid or self.log.new_episode_id("goal")):
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
            batch, self._stash = self._stash + self.game.poll_events(), []
            if self.broker.running is not None:  # a job left running when the player spoke: its progress, for
                for ev in batch:                 # body_status ("how's it going?"); nobody waits on its listener now
                    if isinstance(ev, PROGRESS_EVENTS):
                        self.controller.progress_event(ev)
            for event in self.broker.triage(batch):
                self.handle_event(event)
        finally:
            self._in_pump = False
        self.flush_situations()
        self._review_tick()
        if self.director is not None:
            self.director.tick()  # the board: decisions (worker) applied, the next step run started

    def _review_tick(self) -> None:
        """Proactive behaviour: read the state now and then (a bridge read, never a model call) and,
        when the broker sees a meaningful change at a good moment, give the model a situation_review.
        The model decides to speak, act or stay silent."""
        now = self.broker.clock()
        if self.budget is not None and not self.budget.allows("review"):
            return  # out of budget: no proactive reviews (reflexes keep running in the body)
        if self._sampled_at is None or now - self._sampled_at >= REVIEW_SAMPLE_S:
            self._fresh_state()
        ep = self.broker.episode
        busy = bool(self.active_goal or self.pending_goal or self._situations or self._chat_waiting()
                    or self._chat_stashed()
                    or (ep is not None and ep.ended is None and ep.tool != "follow")
                    or self.broker.running is not None  # a job left running when the player spoke
                    or (self.director is not None and
                        getattr(self.director, "owns_transition", self.director.running)))
        ev = self.broker.review_due(busy=busy)
        if ev:
            self._situations.append(ev)
            self.flush_situations()

    def handle_event(self, event: Event) -> None:
        self.log.log("event", event=event.model_dump())
        if isinstance(event, BODY_SITUATIONS):
            self._body_situation(event)
            if not self._in_pump:
                self.flush_situations()
            return
        if (isinstance(event, TaskFailed) and self.broker.held(event.task_id)) or \
                (isinstance(event, (TaskDone, TaskFailed)) and self.broker.running_result(event.task_id)):
            # a follow ended by itself (review H1), or an action left running when the player spoke has ended
            # (nobody re-attached to or replaced it): the model hears how it went and decides what's next
            self._body_situation(event)
            if not self._in_pump:
                self.flush_situations()
            return
        if isinstance(event, (TaskDone, TaskFailed)):
            return  # the executor already has the result (synchronous reply); see broker.triage
        if isinstance(event, Activity):
            return self._activity(event)
        self.controller.note_event(event)
        if isinstance(event, Attacked):
            self.broker.note_attacked()
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

    def _fresh_state(self, reuse: bool = False, after_action: bool = False) -> dict:
        try:
            # reuse = a read before a model call on the wake path (each event's triage, still_valid, flush, the
            # controller's first read: back to back, 0.3-0.5 s each; live r1-20261102T065157Z: 1.9 s of get_state
            # before the first prompt): the last read if it is FRESH_REUSE_S old on the broker clock and no action ran
            # since (executor.run_task clears its cache). Reads after a model call stay fresh (facts changed while thinking).
            now, c = self.broker.clock(), getattr(self, "_wake_state", None)
            ex_cache = getattr(self.executor, "_cache", None)
            if reuse and c is not None and now - c[0] <= FRESH_REUSE_S and c[1] is ex_cache and ex_cache is not None:
                return c[2]
            # after_action = the read between a turn's tools and the next model call: the executor read the state a
            # moment ago to verify the last action, and nothing ran since (live r1-20261115T223115Z: two get_state back
            # to back, 0.6 s + 0.8 s, between arriving at his grave and the prompt that pressed Take All)
            state = self.executor.state(max_age=POST_ACTION_REUSE_S if after_action else None)
            self._wake_state = (now, getattr(self.executor, "_cache", None), state)
        except StateUnavailable as exc:
            return {"unavailable": str(exc)}
        self.broker.observe(state)  # where am I, am I moving, who is in sight (body_status "Where:")
        self._sampled_at = self.broker.clock()
        return state

    def _body_situation(self, event: Event) -> None:
        v = self.broker.assess(event, self._fresh_state(reuse=True))
        if v.action == "decide":
            self._situations.append(v.event)

    def _chat_waiting(self) -> bool:
        """True while chat lines wait for a Controller run that will take the situations along."""
        return False

    def _chat_stashed(self) -> bool:
        """A chat line peeked mid-request (``_player_spoke``) and not handled yet: it goes first."""
        return any(isinstance(e, (ChatHeard, CommandReceived)) for e in self._stash)

    def take_situations(self, state: dict | None = None) -> list[dict]:
        """The pending situations still true now (a chat run takes them along: one line for both)."""
        events, self._situations = self._situations, []
        if not events:
            return []
        # Ordinary external reviews wait for the owned transition to settle. Urgent body
        # situations and human commands keep their existing paths, including mixed queues.
        # https://www.w3.org/TR/scxml/#run-to-completion (scheduling precedent only)
        if self.director is not None and getattr(self.director, "owns_transition", self.director.running):
            self._situations = [e for e in events if e.get("type") == "situation_review"]
            events = [e for e in events if e.get("type") != "situation_review"]
        if not events:
            return []
        still = self.broker.still_valid(events, state if state is not None else self._fresh_state(reuse=True))
        for e in events:
            if e not in still:
                self.log.log("situation_stale", event=e, why="fixed before it was voiced")
        return still

    def flush_situations(self) -> None:
        if not self._situations or self._chat_waiting() or self._chat_stashed():
            return  # the chat run takes the situations along (M1 17:53:42: a review ran first, the line waited 140 s)
        state = self._fresh_state(reuse=True)
        events = self.take_situations(state)
        if not events:
            return
        if self.budget is not None and not self.budget.allows("situation"):
            # out of budget: the template line still tells him (communication paramount), no model call
            line = fallback_line(events)
            if line and self.controller.say(line, kind="notice") is not None:
                self.broker.voiced(events)
            return
        player = next((e["target"] for e in events if e.get("about") == "player" and e.get("target")), None)
        if not player:
            near = sorted((p for p in state.get("players") or [] if isinstance(p, dict) and p.get("name")),
                          key=lambda p: p.get("distance") if isinstance(p.get("distance"), (int, float)) else 1e9)
            player = str(near[0]["name"]) if near else self.controller.player
        try:
            with self.log.episode(self.log.new_episode_id("review" if any(e.get("type") == "situation_review"
                                                                           for e in events) else "situation")):
                self._command(CommandReceived(player=player, text=""), addressed=True, body_events=events)
        except Exception as exc:  # the model call failed: the template line still tells him
            self.log.log("situation_error", error=repr(exc), events=events)
            if line := fallback_line(events):
                if self.controller.say(line, kind="notice") is not None:
                    self.broker.voiced(events)

    def _activity(self, event: Activity) -> None:
        """Episodic memory: every completed body episode, whoever started it."""
        self.broker.remember_activity(event)
        if self.director is not None:
            self.director.observe_activity(event)  # kills, pickups, drops for the board's counters
        line = self.broker.describe_activity(event)
        self.store.progress("activity", kind=event.kind, by=event.by, ts=event.ts, **event.fields())
        if self.broker.notable(event):
            when = time.strftime("%H:%M UTC", time.gmtime(event.ts)) if event.ts else "earlier"
            self.store.remember(f"last_{event.kind}", f"{when}: {line}")
            where = event.fields().get("where")
            if event.kind == "death" and isinstance(where, list) and len(where) >= 3:
                self.store.remember_place("grave", [float(c) for c in where[:3]],
                                          note=f"my gravestone (died {when}: {event.fields().get('cause') or '?'})")
        if event.kind == "combat_end" and event.by == "reflex":
            # A fight nobody asked for (the body's guard fought back when hit) is news to the player: the model hears
            # how it ended and says it, or not (rung 1 "fight back when hit": he fought and told no one, 2026-11-01).
            self._situations.append({**event.model_dump(), "about": "a fight you fought by reflex when attacked"})
            if not self._in_pump:
                self.flush_situations()

    def _killed_note(self, task: Task, outcome: Outcome, wait_s: float = 1.0) -> None:
        """A target that is gone because a fight killed it: the result says so (live 20:09Z ClaudeQ4: go_to <rat id>
        -> unknown_target "target_not_visible"; his combat reflex had killed that rat during the walk, and the kill
        event reached the brain 0.5 s after the result). Peeks at the body's events (kept for the chain's news), waits
        up to wait_s when the target is a creature id or the result names a fight. Informs only: reason unchanged."""
        target = (task.args or {}).get("target")
        if outcome.ok or outcome.reason != Reason.UNKNOWN_TARGET or not isinstance(target, str) or not target:
            return
        data = outcome.data if isinstance(outcome.data, dict) else None
        fight = "_Character_C_" in target or "combat" in str((data or {}).get("detail") or "")
        deadline = time.monotonic() + (wait_s if fight else 0.0)
        while True:
            self._stash.extend(self.game.poll_events())
            note = self.broker.killed(target, extra=[e for e in self._stash if isinstance(e, Activity)])
            if note or time.monotonic() >= deadline:
                break
            time.sleep(0.2)
        if note and data is not None:
            data["detail"] = f"{note} {data.get('detail') or ''}".strip()
            self.log.log("target_was_killed", tool=task.skill, target=target, note=note)

    def _run_task(self, task: Task) -> Outcome:
        """Every body action the brain runs goes through here, so the broker knows the brain's own moves."""
        # the same call as the action the body is still doing since the player spoke: the executor re-attaches to it
        continues = getattr(self.executor, "continues", None)
        self.broker.action_started(task.skill, task.args, continuing=bool(continues and continues(task)))
        self.broker.note_busy()
        outcome = self.executor.run_task(task)
        detail = (outcome.data or {}).get("detail") if isinstance(outcome.data, dict) else None
        task.detail = str(detail)[:TASK_DETAIL_CHARS] if detail else None
        self._killed_note(task, outcome)
        self.broker.action_finished(task.skill, task.args, outcome.ok, outcome.reason, outcome.data)
        if self._directed is not None:
            rec = {"tool": task.skill, "args": dict(task.args), "ok": outcome.ok, "reason": outcome.reason,
                   "data": outcome.data, "interrupt": outcome.interrupt, "origin": self._directed_origin}
            effects = (outcome.data or {}).get("effects") if isinstance(outcome.data, dict) else None
            if isinstance(effects, dict):  # the body's own uniform effects block (director.effects_of uses it)
                rec["effects"] = effects
            self._directed.append(rec)
        return outcome

    def _on_progress(self, event: Event) -> None:
        # Progress events only come while a long body action runs (a goal's task or a direct gather).
        self.controller.progress_event(event)

    # ---------------------------------------------------------------- commands

    def _command(self, event: CommandReceived, addressed: bool = True, body_events: list[dict] | None = None) -> None:
        if self._directed is None or not event.text:
            return self._command_run(event, addressed, body_events)
        prev, self._directed_origin = self._directed_origin, "chat"  # a chat command nested in a board run
        try:
            return self._command_run(event, addressed, body_events)
        finally:
            self._directed_origin = prev

    def _command_run(self, event: CommandReceived, addressed: bool = True, body_events: list[dict] | None = None) -> None:
        """``addressed=False``: a chat line nobody addressed to the companion (LiveAgent's chat
        reading); the model may decide it is not for him, and then nothing is said or done.
        ``body_events``: body situations (broker) this run must also decide on; with an empty text it
        is a body-initiated run: the model phrases the line (or fixes it with a tool).

        The agent loop (live 21:43, the shelter plan died after its first step): every turn's tool
        results go back to the model for the next turn (``Controller.next_turn``), up to MAX_TURNS more
        and REQUEST_SECONDS of wall time, until it stops calling tools; a new chat line ends the chain
        (the player has the floor)."""
        if event.text:
            self.broker.note_busy()  # he is talking with the player: no proactive review on top
        deadline = self.clock() + REQUEST_SECONDS
        # a body-only run (no chat line) reuses the wake's read; a chat line reads fresh (his words may follow a change)
        state = self._fresh_state(reuse=not event.text)  # unavailable: still let the Controller answer; actions will refuse
        body_ctx = (body_events[0] if len(body_events) == 1 else {"events": body_events}) if body_events else None
        # where he stood when asked: "here" / "by me" keep that place while the request runs (live 21:13Z: he gathered
        # 31 m away and built there). Perception only (the situation's "Asked" line); a hand-on carries it on.
        self._asked = sit.asked_at(state, event.player, event.text) if event.text else \
            (body_ctx or {}).get("asked_at") if isinstance(body_ctx, dict) else None
        state = sit.with_asked(state, self._asked)
        # the model's command.addressed: only a player's line is addressed to him; a body-initiated run (no text) is
        # not (live 2026-11-01: body events came as addressed=true and he opened with "hey" when nobody spoke)
        heard = addressed and bool(event.text)
        d = self.controller.decide(event.player, event.text, state, self.active_goal, addressed=heard,
                                   body_event=body_ctx)
        if body_events:  # speak-time check of the situation itself, on fresh state
            state = sit.with_asked(self._fresh_state(), self._asked)
            still = self.broker.still_valid(body_events, state)
            if not still and not (d.actions or d.goal or d.skill):
                self.log.log("situation_stale", events=body_events, why="fixed while the model was thinking",
                             speech=d.speech)
                if not event.text:
                    return
            body_events = still
        self.request_calls, self.request_parked = d.model_calls, None
        d2, state = self._fresh_reply(event, d, state, heard, body_ctx)
        if d2 is not d:
            self.request_calls += d2.model_calls
        d = d2
        if not addressed and not (d.actions or d.goal or d.skill or d.refusals or d.speech):
            self.log.log("chat_decision", player=event.player, text=event.text, decision="ignored",
                         reason="model: not meant for me")
            return
        if not addressed:
            self.log.log("chat_decision", player=event.player, text=event.text, decision="addressed",
                         reason="model: meant for me", actions=[c.name for c in d.actions], speech=d.speech)
        kind = "notice" if body_events and not event.text else "reply"
        ran_all: list[str] = []  # every tool this request ran (the board hears about player commands)
        said = False  # anything said for this request (single voice: at most one line per turn)
        lines: list[str] = []  # what the model's turns actually said (for previous_review.you_said)
        acted = False
        turn = 0
        parked = None  # the no-progress breaker parked a step: this turn is the chain's last
        prev_line, stop_checked = None, False  # the line said with the previous turn; the one-time STOP_NOTE check
        unreported: list[dict] = []  # body failures no later line of his followed (UNREPORTED_NOTE)
        fail_checked = False
        failed_any, handed, open_checked = False, False, False  # OPEN_JOB_NOTE: an open failure, a long-job tool, the check
        last_turn = False  # the deadline passed during a body action: the model's report turn is the chain's last
        # every call this request ran and how it went, for a hand-on's fresh run (a handed-on request carries its own on)
        work: list[dict] = [*(body_ctx.get("done_so_far") or []), *(body_ctx.get("last_results") or [])]             if isinstance(body_ctx, dict) and body_ctx.get("type") == CHAIN_BUDGET else []
        while True:
            if d.interrupts and self.active_goal:
                self._cancelled = True
            t = self._run_turn(d, state, event)
            work.extend(_work_rows(d, t, WORK_DETAIL_CHARS))
            nonbody_success = not t["ran"] and any(r.get("ok", True) for r in t["results"].values())
            acted = acted or bool(t["ran"]) or nonbody_success
            ran_all.extend(t["ran"])
            if t["failure"] and t["failed_call"] is None:  # refused before the body (safety, no such tool)
                self.controller.report_failure(*t["failure"])
                said = True
                break
            line_said = bool(t["spoken"])  # was this turn's own line heard (the say call's result, next turn)
            if not t["failure"]:
                text = " ".join(s for s in [None if t["spoken"] else d.speech, *t["extra"]] if s)
                if text:
                    if self.controller.say(text, kind=kind) is not None:
                        said = True
                        lines.append(text)
                        line_said = line_said or bool(d.speech)
                said = said or t["spoken"]
            elif t["failure"][1] in Reason.INTERRUPTS:  # a newer command took over: it speaks
                break
            if line_said:  # a line heard in a turn after the model saw them: it had its say on those
                unreported = [f for f in unreported if f["turn"] == turn]
            if t["failure"]:
                fd = t["failure"][2] if isinstance(t["failure"][2], dict) else {}
                unreported.append({"turn": turn, "tool": t["failure"][0], "reason": t["failure"][1],
                                   "detail": str(fd.get("detail") or "")[:200] or None})
            fail_check = False
            if parked or last_turn:  # caps spend: the model heard why and had its one turn to say it
                self.log.log("chain_stopped", turns=turn, why="parked" if parked else "deadline", parked=parked)
                break
            more = bool(t["failure"]) or bool(set(t["ran"]) - STANDING)
            more = more or (bool(event.text) and nonbody_success and not said)
            # L5 (live 21:02:56 "I'll walk closer and cast it on the tree", no tool call): a first turn that
            # only talked gets ONE more turn to call what it said it would do (or reply empty). Its line
            # is already said, so this costs no reply latency.
            # Only for a player's request: on a situation_review, speaking IS the response (run 1: all 4 reviews
            # paid a 2nd call that answered "I said my line already").
            # ...and once on a later turn whose line came after reads in that same turn (farming 2026-11-02 23:05Z: lookup
            # flax, then "I'll go look" and no call, 483 s idle): a line after fresh research is a plan, not a report
            # (a talk-only report after a verified go_to has no reads before it: no extra call for those)
            # ...and for the run that hears a goal ended, when that goal came from a player's words (_goal_request):
            # those words may ask for more than the goal did. Fresh chain 20261116-073129: Rune Mysteries part 1 handed
            # in, he read quests, said "next step is rune essence, mining near here" with no call, and stood 160 s
            # (replayed 10 times each: 1/10 went on as logged, 10/10 called gather with this one more turn)
            asked = bool(event.text) or any(e.get("type") == "goal_done" and e.get("request") for e in body_events or [])
            promise_check = (self.check_promises and asked and not t["ran"] and not t["failure"]
                             and bool(d.speech) and not (d.actions or d.goal or d.skill)
                             and (turn == 0 or (not stop_checked and getattr(d, "read_rounds", 0) > 0
                                                and not getattr(d, "talk_checked", False))))
            more = more or promise_check
            unheard = (turn == 0 and addressed and bool(event.text) and not body_events and not t["ran"]
                       and not t["failure"] and not d.speech and not (d.actions or d.goal or d.skill or d.refusals)
                       and getattr(self.controller, "say_channel", False) and self._wrote_text(d))
            more = more or unheard
            # a line said beside work in a LATER turn (a first reply's "on it" + its call, then an empty report turn, is
            # the normal end of a request: no check for that)
            this_line = d.speech if line_said and d.speech and t["ran"] and turn > 0 else None
            stop_check = (turn > 0 and not stop_checked and self.check_promises and bool(event.text) and not t["ran"]
                          and not t["failure"] and bool(prev_line) and not d.speech
                          and not (d.actions or d.goal or d.skill or d.refusals))
            stop_checked = stop_checked or stop_check or promise_check or unheard  # never doubled with those
            more = more or stop_check
            stop_line, prev_line = prev_line, this_line
            # not in a board run: the board reports its own step failures (test_recovery_decision_dispatch)
            if not more and unreported and not fail_checked and not t["failure"] and self._directed is None                     and not self._player_spoke():
                fail_check = fail_checked = more = True
                stop_checked = True  # never doubled with the STOP_NOTE check
                self.log.log("failure_unreported", failures=unreported)
            # the request's latest body failure still stands: no body action of a later turn worked
            failed_any = bool(t["failure"]) or (failed_any and not t["ran"])
            handed = handed or bool(d.goal) or any(c.name in LONG_JOB_TOOLS for c in d.actions)
            open_check = False
            job_tool = None
            if not more and failed_any and not (handed or open_checked):
                job_tool = next((n for n in LONG_JOB_TOOLS if n in getattr(self.controller, "offered", set)()), None)
            if (job_tool and self.check_promises and bool(event.text) and not body_events and self._directed is None
                    and not self._player_spoke()):
                open_check = open_checked = stop_checked = more = True  # never doubled with the STOP_NOTE check
                self.log.log("open_job_check", request=event.text, tool=job_tool)
            if not more:
                break
            spoke = self._player_spoke()
            late = self.clock() >= deadline
            if late and t["ran"] and not spoke and turn < MAX_TURNS:
                last_turn = True  # a long action (a 295 s go_to) used the time up: never cut off its report
            elif turn >= MAX_TURNS or spoke or late:
                self.log.log("chain_stopped", turns=turn,
                             why="the player spoke" if spoke else "deadline" if late else "budget")
                if self._directed is not None and spoke:
                    self._directed_end = "chat"
                if not spoke and not late and self._hand_on(event, d, t, body_events, work):
                    break  # the model hears the last results in a fresh run (live 17:2xZ: he stood 194 s here)
                if t["failure"] and not spoke:  # the model never saw this failure; when he spoke, he has the
                    self.controller.report_failure(*t["failure"])  # floor (the next run's body_status has it)
                    said = True
                elif not spoke and not said and self._directed is None:  # hand-ons used up, nothing said: he must
                    line = fallback_line([{"type": CHAIN_BUDGET, "request": event.text or next(  # not stop silently
                        (e.get("request") for e in body_events or [] if e.get("type") == CHAIN_BUDGET), None)}])
                    said = bool(line) and self.controller.say(line, kind=kind) is not None
                break
            turn += 1
            before, state = state, sit.with_asked(self._fresh_state(after_action=True), self._asked)
            parked = self._note_progress(t, before, state, event.player)
            self.request_parked = parked or self.request_parked
            news = self._news()
            try:
                say_res = {"ok": True, "note": "said"} if line_said else \
                    {"ok": None, "note": "not said: a step failed first; say what's true now" if t["failure"]
                     else "not said (too close to a line you just said)"}
                d = self.controller.next_turn(d, {**t["results"], "say": say_res}, state, failed=bool(t["failure"]),
                                              note=PARKED_NOTE if parked else LAST_TURN_NOTE if last_turn else
                                              UNREPORTED_NOTE.format(player=self.controller.player, items="; ".join(
                                                  f"{f['tool']} {f['reason']}" + (f" ({f['detail']})" if f["detail"] else "")
                                                  for f in unreported)) if fail_check else
                                              OPEN_JOB_NOTE.format(request=event.text, tool=job_tool) if open_check else
                                              PROMISE_NOTE if promise_check else UNHEARD_NOTE if unheard else
                                              STOP_NOTE.format(line=stop_line) if stop_check else None,
                                              news=news)
            except Exception as exc:  # model/provider error: the template still says why
                self.log.log("next_turn_error", turn=turn, error=repr(exc))
                if t["failure"]:
                    self.controller.report_failure(*t["failure"])
                    said = True
                break
            self.request_calls += d.model_calls
            self.log.log("chain_turn", turn=turn, actions=[c.name for c in d.actions], speech=d.speech)
            # A model-selected goal/skill is recovery work even without primitive actions.
            # https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls
            if t["failure"] and not (d.actions or d.goal or d.skill or d.speech or d.refusals):
                if getattr(self.controller.llm, "template_voice", False):  # the dry run: no model to phrase it
                    self.controller.report_failure(*t["failure"])
                    said = True
                else:  # the model saw the failure and chose silence: code doesn't talk over it (2026-10-31)
                    self.log.log("failure_unspoken", tool=t["failure"][0], reason=t["failure"][1],
                                 why="model chose silence")
                break
        if not said and body_events and not event.text:  # the model said nothing about a body situation
            # Live 20:21:53: the model fixed it silently (picked up 4 sandwiches) and the template "I'm really
            # hungry and have nothing left" was said anyway. Re-check on fresh state at speak time: only
            # what is still true is said, and nothing at all when the model's own action fixed it.
            still = self.broker.still_valid(body_events, self._fresh_state())
            if still and not acted:
                # None for a situation_review or a handed-on request (CHAIN_BUDGET): the model chose silence
                line = fallback_line([e for e in still if e.get("type") != CHAIN_BUDGET])
                said = bool(line) and self.controller.say(line, kind=kind) is not None
            else:
                self.log.log("situation_unspoken", events=body_events, still=still,
                             why="fixed by the model's own action" if acted else "fixed before speaking")
        elif not said and addressed and not body_events and not (acted or d.goal or d.skill or d.refusals):
            self.log.log("reply_silent", player=event.player, text=event.text)  # the model chose silence: no stock line
        if body_events and said:
            self.broker.voiced(body_events, text=" ".join(lines) or d.speech)
        if self.director is not None and event.text and (ran_all or d.goal or d.skill):
            self.director.on_player_command(event.player, ran_all + (["run_skill"] if d.skill else []), event.text)
        if d.goal and not d.skill:
            self.pending_goal = d.goal
        if self.pending_goal:
            self._goal_episode = self.log.episode_id  # the goal's rows stay in the episode that asked for it

    def _hand_on(self, event: CommandReceived, d, t: dict, body_events: list[dict] | None,
                 work: list[dict] | None = None) -> bool:
        """The turn budget ended a request with work still open (its last turn ran tools whose results the model
        never saw). Live 17:2xZ: the 8th turn cast Summon Shelter "to rest", the chain stopped, and he stood 194 s,
        silent, to the run's end. The request is handed on as a body situation: a fresh run (fresh context) in which
        the model hears what it asked for and how its last calls went, and decides: carry on, change course, tell
        the player, or stop. At most MAX_HAND_ONS per request; a board run's step budget is the board's."""
        if self._directed is not None:
            return False
        prev = next((e for e in body_events or [] if e.get("type") == CHAIN_BUDGET), None)
        n = int(prev.get("hand_on") or 0) + 1 if prev else 1
        if n > MAX_HAND_ONS:
            return False
        last = _work_rows(d, t, 300, unrun=True)
        # live 2026-11-16 (rung 2): the fresh run knew only its last call; with his house torn down and four of his
        # own pieces up it asked the player "which one's yours?"
        done = (work or [])[:max(0, len(work or []) - len(_work_rows(d, t, 1)))][-WORK_ROWS:]
        request = (prev or {}).get("request") or event.text or None
        self._situations.append({
            "type": CHAIN_BUDGET, "hand_on": n, "of": MAX_HAND_ONS, "request": request, "asked_at": self._asked,
            "from": (prev or {}).get("from") or (event.player if event.text else None),
            "about": (f"your work on this request stopped at the turn limit ({MAX_TURNS + 1} turns) before you had "
                      "seen how your last calls went; their results are in last_results, and every call the request "
                      "ran before them is in done_so_far, in order"
                      + ("; this is the last hand-on, the request ends after this run" if n == MAX_HAND_ONS else "")),
            "done_so_far": done, "last_results": last})
        self.log.log("chain_handed_on", hand_on=n, request=request, last=[x["tool"] for x in last])
        return True  # the next pump's flush_situations runs it (never nested inside this run's own wrap-up)

    def _run_turn(self, d, state: dict, event: CommandReceived) -> dict:
        """Run one model turn's calls in order; stop at the first failure. Every result is kept for the
        model's next turn (a failure also carries the tool's own argument descriptions)."""
        failure = d.refusals[0] if d.refusals else None
        # the call that failed (a body action, or one refused for bad args): its result goes back to the model
        failed_call = d.invalid[0] if d.invalid and failure and failure[0] == d.invalid[0].name else None
        results: dict[str, dict] = {}
        if failed_call is not None:
            results[failed_call.id or failed_call.name] = {"ok": False, "reason": failure[1], "data": failure[2],
                                                           "args_help": self.controller.arg_help(failed_call.name)}
        extra: list[str] = []  # facts the body reported that the speech must carry (single voice)
        spoken, ran = False, []
        body: list[tuple[str, str, dict]] = []  # (result key, tool, args) of the body actions run
        self.broker.learn_names(looks=d.looks)  # body_status then names the things this turn's looks found
        acts = interleave(d.actions, state)  # food and drink locks are separate: a drink never waits behind food
        if [id(c) for c in acts] != [id(c) for c in d.actions]:
            self.log.log("consume_interleaved", order=[(c.arguments or {}).get("item") for c in acts if c.name == "consume"])
        for call in ([] if failure else acts):
            if call.name in ("remember", "forget_skill"):
                res = self._remember(call.arguments, state, event.player) if call.name == "remember" \
                    else self._forget_skill(call.arguments)
                results[call.id or call.name] = res
                if not res.get("ok", True):
                    failure, failed_call = (call.name, res["reason"], res["data"]), call
                    break
                continue
            if self.director is not None and call.name in self.director.tool_names:
                res = self.director.handle_tool(call.name, call.arguments, event.player)  # board tools
                results[call.id or call.name] = res
                if not res.get("ok", True):
                    failure, failed_call = (call.name, res.get("reason"), res.get("data") or {}), call
                    break
                continue
            if call.name in RULE_TOOLS:
                res = self._rule_tool(call.name, call.arguments, extra)
                results[call.id or call.name] = res
                if not res["ok"]:
                    failure = (call.name, res["reason"], res["data"])
                    break
                continue
            if call.name in LONG_ACTIONS:
                self.controller.job_started()
            if call.name in ANNOUNCE_FIRST and not spoken and d.speech:
                # a move or a job that takes a while: the model's line is said as it starts (true then)
                self.controller.say(d.speech)
                spoken = True
            self._held = {"tool": call.name, "line": d.speech, "said": False} if d.speech and not spoken else None
            try:
                with self.log.scope(call=call.id):  # the model's tool_use id on every row + bridge cmd (item 1)
                    outcome = self._run_task(Task(skill=call.name, args=call.arguments))
            finally:
                held, self._held = self._held, None
            spoken = spoken or bool(held and held["said"])
            ran.append(call.name)
            if outcome.reason == Reason.BUSY and isinstance(outcome.data, dict) and not outcome.data.get("owner"):
                hint = self.broker.busy_with()  # name who had the body (the stay-fed reflex), never a token
                if hint:
                    outcome.data.update(busy_with=hint["what"], busy_by=hint["by"], busy_item=hint["name"])
            res = {"ok": outcome.ok, "reason": outcome.reason, "data": outcome.data}
            body.append((call.id or call.name, call.name, call.arguments))
            if not outcome.ok and outcome.reason in (Reason.UNKNOWN_TARGET, Reason.INVALID_ARGS, Reason.NOT_PERCEIVED,
                                                     Reason.AMBIGUOUS_TARGET):
                res["args_help"] = self.controller.arg_help(call.name)  # how to name a target for this tool
            results[call.id or call.name] = res
            if not outcome.ok:
                failure, failed_call = (call.name, outcome.reason, outcome.data), call
                break  # steps run in order and stop at the first that fails (the model hears why)
        if d.skill and failure is None:
            failure = self._queue_skill(*d.skill, state)
        return {"failure": failure, "failed_call": failed_call, "results": results, "extra": extra,
                "spoken": spoken, "ran": ran, "body": body}

    def _note_progress(self, t: dict, before: dict, after: dict, player: str) -> str | None:
        """The no-progress breaker (brain/progress.py), on the turn's body results before the model reads them:
        what the turn changed, and a plain note on a failure repeated with no progress. Returns the parked note
        when a step was parked (the chain then ends after the model's next turn)."""
        body = t.get("body") or []
        delta = change(before, after) if body else None
        parked = None
        for i, (key, tool, args) in enumerate(body):
            res = t["results"].get(key)
            if not isinstance(res, dict):
                continue
            if delta and i == len(body) - 1:
                res["change"] = "this turn: " + delta
            if res.get("ok"):
                self.repeats.progressed(tool, args)
                continue
            n = self.repeats.note(tool, args, res.get("reason"), after)
            words = self.repeats.verdict(tool, args, res.get("reason"), n, player)
            if words:
                res.update(words)
                self.log.log("no_progress", tool=tool, args=args, reason=res.get("reason"), count=n)
                parked = words.get("parked") or parked
        return parked

    def run_directed(self, event: dict, player: str) -> dict:
        """One body-initiated Controller run for the board's current step (docs/design/director.md §2.4).

        The event (type board_step) reaches the model as body_event. A run_skill the model queued runs here,
        before returning, so the board checks the step's predicate after the run's actions really ran
        (review H7b); start_goal is not offered while the board is on and is dropped if it comes anyway.
        Returns {actions: [{tool, args, ok, reason, data, interrupt, origin: board|chat}],
        ended: normal | chat | interrupted | error}. Activity events that arrived during the run are handled
        before it returns, so the board's counters are current when it checks the step."""
        self._directed, self._directed_end = [], "normal"
        self.request_calls, self.request_parked = 0, None
        try:
            self._command(CommandReceived(player=player, text=""), addressed=True, body_events=[event])
            if self.pending_goal and self.pending_skill:
                goal, tasks, skill = self.pending_goal, self.pending_tasks, self.pending_skill
                self.pending_goal, self.pending_tasks, self.pending_skill = None, None, None
                self.run_goal(goal, tasks=tasks, skill=skill, quiet=True)
            elif self.pending_goal:
                self.log.log("goal_dropped", goal=self.pending_goal, why="start_goal inside a board run")
                self._directed.append({"tool": "start_goal", "args": {"goal": self.pending_goal}, "ok": False,
                                       "reason": "not_offered", "data": {}, "interrupt": False})
                self.pending_goal = None
            if any(r.get("interrupt") for r in self._directed) and self._directed_end == "normal":
                self._directed_end = "interrupted"
            # re-check 6: activity that arrived during the run (kills, pickups) reaches the board before it
            # checks the step; everything else stays stashed for the next pump, in order
            batch, self._stash = self._stash + self.game.poll_events(), []
            for ev in batch:
                if isinstance(ev, Activity):
                    self.handle_event(ev)
                else:
                    self._stash.append(ev)
        except Exception as exc:  # the board records the error; the agent loop keeps running
            self.log.log("directed_run_error", error=repr(exc))
            self._directed_end = "error"
        finally:
            actions, ended = self._directed, self._directed_end
            self._directed = None
        return {"actions": actions, "ended": ended, "model_calls": self.request_calls,
                "parked": self.request_parked}

    def run_first_call(self, call: dict, player: str) -> dict:
        """A board step's first call, chosen by the Director's plan (a model decision), run before the Controller's
        turn so a step starts without a model round trip. It passes the Controller's own gates (offered tools,
        aliases, the argument schema, Luis's safety rules) and the executor, and is recorded like any board-run
        action: {tool, args, ok, reason, data, interrupt, origin: board}. Nothing here decides what comes next."""
        from .controller import Decision
        from .llm import ToolCall
        d = Decision()
        state = self._fresh_state()
        self.controller._collect([ToolCall(str(call.get("tool") or ""), dict(call.get("args") or {}), "first")], d, state)
        if d.refusals:
            tool, reason, data = d.refusals[0]
            return {"tool": tool, "args": dict(call.get("args") or {}), "ok": False, "reason": reason,
                    "data": data or {}, "interrupt": False, "origin": "board", "refused": True}
        if not d.actions:  # a read tool (or nothing to act on): the Controller's turn does it
            return {"tool": call.get("tool"), "args": dict(call.get("args") or {}), "skipped": True}
        c = d.actions[0]
        self._directed, self._directed_origin = [], "board"
        try:
            if c.name in LONG_ACTIONS:
                self.controller.job_started()
            self._run_task(Task(skill=c.name, args=c.arguments))
            rec = self._directed[-1]
        except Exception as exc:
            self.log.log("first_call_error", tool=c.name, error=repr(exc))
            rec = {"tool": c.name, "args": c.arguments, "ok": False, "reason": Reason.BODY_ERROR,
                   "data": {"error": repr(exc)[:200]}, "interrupt": False, "origin": "board"}
        finally:
            self._directed = None
        batch, self._stash = self._stash + self.game.poll_events(), []  # kills/pickups reach the board first
        for ev in batch:
            if isinstance(ev, Activity):
                self.handle_event(ev)
            else:
                self._stash.append(ev)
        return rec

    def _long_action(self, tool: str, request_id: str) -> None:
        """The bridge says a watched action is under way: say the turn's held line now, not when it ends.
        A failure that comes back before this still replaces the line (it was never said)."""
        held = self._held
        if held and not held["said"] and tool == held["tool"]:
            held["said"] = True
            self.log.log("held_line_said", tool=tool, id=request_id)
            self.controller.say(held["line"])

    def _news(self) -> list[str]:
        """Body activity that arrived during this chain (the stay-fed reflex drinking, a kill, a pickup): handled now
        and told to the model's next turn, not only after the chain ends. Other events stay stashed, in order."""
        self._stash.extend(self.game.poll_events())
        acts = [e for e in self._stash if isinstance(e, Activity)]
        if not acts:
            return []
        self._stash = [e for e in self._stash if not isinstance(e, Activity)]
        for ev in acts:
            self.handle_event(ev)
        return [self.broker.describe_activity(ev) for ev in acts]

    @staticmethod
    def _wrote_text(d) -> bool:
        """Did the model's last reply carry free text (a private note on the say channel)?"""
        last = (getattr(d, "messages", None) or [{}])[-1]
        content = last.get("content") if isinstance(last, dict) and last.get("role") == "assistant" else None
        return isinstance(content, str) and bool(content.strip())

    def _player_spoke(self) -> bool:
        """Has a chat line arrived since this request started? (peeked, kept for the next pump)"""
        self._stash.extend(self.game.poll_events())
        return self._chat_waiting() or any(isinstance(e, (ChatHeard, CommandReceived)) for e in self._stash)

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
        if rec is not None:
            self.log.log("skill_learned", name=rec.name, variants=rec.origin.get("variants", 1))  # not said

    # ---------------------------------------------------------------- goals

    def _stuck(self, goal: str, task: Task | None, reason: str | None, question: str | None = None) -> GoalResult:
        if self.store.tree:
            self.store.tree.status = "stuck"
            self.store.save_tree()
        self._last_reason = reason
        self.store.progress("stuck", goal=goal, reason=reason)
        if self._quiet_goal:
            return "stuck"  # the board hears it from run_directed's records and decides
        self._situations.append({"type": "stuck", "goal": goal, "failed": task.skill if task else None,
                                 "reason": reason, "question": question, **self._goal_request()})
        self.flush_situations()
        return "stuck"

    def _goal_request(self) -> dict:
        """The player's own words the running goal came from, for the run that hears how the goal ended. The goal is
        the model's wording of them and may cover less: fresh chain 20261116-065203, "go and see Zanik and do her
        quest" became the goal "chop 50 Ash Logs ... bring them to Zanik"; that goal ended 290 s after the line (the
        rolling chat keeps 240 s), so the run that heard goal_done knew only the goal, and he stopped with the
        quest's next part open (583 s standing)."""
        a = self._goal_asked
        if not (isinstance(a, dict) and a.get("request")):
            return {}
        # the words alone: replayed on that turn 10 times each, he stopped or went looking for a bed 9/10 without
        # them, went on with the quest 10/10 with them, and stopped 6/10 with a note beside them saying what a
        # goal's end means
        return {"request": a["request"], "from": a.get("player"), "asked_at": a}

    def _planner_notes(self) -> dict:
        notes = dict(self.store.prompt_notes())
        for name, rec in self.store.places().items():
            if isinstance(rec, dict) and rec.get("position"):
                notes[f"place:{name}"] = f"go_to target [x, y, z] = {rec['position']}" + (
                    f" ({rec['note']})" if rec.get("note") else "")
        return notes

    def run_goal(self, goal: str, tasks: list[Task] | None = None, skill: str | None = None,
                 quiet: bool = False) -> GoalResult:
        """quiet=True (a run_skill inside a board run): no goal_done / stuck situations and no Planner replans;
        the result goes back to the board (docs/design/director.md section 12 item 7)."""
        self._quiet_goal = quiet
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
            self._quiet_goal = False
        elapsed = time.monotonic() - start
        if skill and self.skills and result != "interrupted":
            self.skills.record_run(skill, result == "done", elapsed, self._last_reason)
        elif result == "done" and not skill:
            self._learn(goal, elapsed)
        return result

    def _run_goal(self, goal: str, given: list[Task] | None = None) -> GoalResult:
        self.store.progress("goal started", goal=goal, from_skill=given is not None)
        asked = self._asked  # the request this goal came from (a body-only run in between clears self._asked)
        self._goal_asked = asked
        if given is None:
            try:
                plan = self.planner.plan(goal, sit.with_asked(self.executor.state(), asked), self._planner_notes())
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
                self.broker.note_progress(f"step {done}/{len(tree.tasks)} done ({_task_label(task)})")
                self.pump()  # Luis may have said something between steps
                if self._cancelled:
                    break
                continue
            # Retries exhausted (or not retryable): DEPS replan, bounded.
            self._last_reason = outcome.reason
            if tree.replans >= (0 if self._quiet_goal else self.max_replans):
                return self._stuck(goal, task, outcome.reason)
            tree.replans += 1
            try:
                new = self.planner.replan(tree, task, outcome.reason, sit.with_asked(self.executor.state(), asked),
                                          self._planner_notes())
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
        if self._quiet_goal:
            return "done"
        self._situations.append({"type": "goal_done", "goal": goal, "steps": len(tree.tasks), **self._goal_request()})
        self.flush_situations()
        return "done"

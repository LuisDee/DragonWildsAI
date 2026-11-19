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

import concurrent.futures as cf
import copy
import json
import os
import time
from pathlib import Path
from typing import Literal

from . import ask_store, fight_news, item_stats, job_tree, needs
from . import plan_async
from . import open_ask as oa
from . import result_knowledge
from . import situation as sit
from .consume_order import interleave
from .broker import BODY_SITUATIONS, REVIEW_SAMPLE_S, RUNNING_RESULT, EventBroker, facts, fallback_line
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
# The same turn for the run that hears a goal ended, when the goal came from a player's words that may ask for more
# than the goal did. Chain 20261116-103757 (Rune Mysteries): part 1 handed in, "Next up is mining rune essence ..."
# with no call, and PROMISE_NOTE got an empty reply (as in chain 073129): he stood 622 s to the deadline. Replayed in
# live order (the prompt cache as live; a single cold call of that turn acts 36/36 and shows nothing): PROMISE_NOTE
# 4 of 18 no call, this note 0 of 24; with the quest shown finished both stay silent (7/7, 8/8).
PROMISE_FOR_NOTE = ("You replied without calling any tool. That line has been said. {player} asked {request!r}: if that "
                    "is not finished, call the tool(s) for its next step now, in order. If you can't do it now (no tool "
                    "or target for it, or something is missing), say in a few words what's stopping you. If it is "
                    "finished, reply with no text at all.")
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
# The same one turn for a run that stops with nothing while a request a goal came from is still open (the run that
# hears that goal end, or a later body run): the request closes on a reply with no call, so he is asked once whether
# it is finished. Window s17 (2026-11-17), runs 044508 and 045210: the goal "50 ash logs to Zanik" came from "go and
# see Zanik and do her quest"; the run that heard it end ate, drank, replied with nothing, and he stood with the
# quest's next step open until the trial ran out. 16 and 17 Nov: 5 of the 26 runs that heard such a goal end stopped
# so, all 5 with the quest open. Rolled forward from their first call 10 times each (with each step's report in
# goal_done): went on 3 and 9 of 10 without this turn, 10 and 10 with it (it was needed 4 times and once).
STOP_FOR_NOTE = ("You stopped: no tool call and nothing said. {player} asked {request!r}: if that is not finished, call "
                 "the tool(s) for its next step now, in order. If you can't do it now (no tool or target for it, or "
                 "something is missing), say in a few words what's stopping you. If it is finished, reply with no text "
                 "at all.")
# Live 2026-11-02 gear_up (logs/brain-live-20261102-013020-15324.jsonl): "gear up properly" met a failed craft (no
# thread: the wheels need a roof) and he ended the request with "short on bones and leather, any spare?", the job
# dropped although his situation listed the no-thread set and a task board was offered. A player's request that is
# about to end after a body failure, with no long-job tool called in it, gets ONE turn reminding him of the request and
# the long-job tool. The model decides (replay of that turn: 5/5 hand the rest on; "truly blocked" stays a choice).
OPEN_JOB_NOTE = ("He asked {request!r}. This request ends here unless you act: if that job isn't finished and another "
                 "route exists (your situation lists them), take it now or hand the rest to {tool}; if you are truly "
                 "blocked, reply with no text at all.")
LONG_JOB_TOOLS = ("add_task", "start_goal")
# An ask still open when a turn calls nothing is not closed by that silence: ONE more turn shows it as data (his
# words, how long ago, what changed in the game since) and offers request_done(evidence) and park_request(reason)
# (brain/open_ask.py; replay docs/research/2026-11-17-open-ask-replay.md, variant C: went on 12 of 38 against 0 of 38,
# and 24 of the 26 that did not ended in a logged park with a reason or a done claim with evidence). At most one such
# turn per chain; it may go one past MAX_TURNS / REQUEST_SECONDS (a stop at the limit is still a stop). A run that
# handed the ask to a job (start_goal, run_skill, add_task) gets none: the job carries it, its end reopens it.
ASKS_SEEN = 8  # baselines kept for asks (where the game stood when each was asked)
# The ask stays open until request_done, park_request or a new line from the player: no stop closes it by silence
# (2026-11-18; until then a second silent turn, or a stop with no turn left, closed it as request_closed). Such a stop is
# logged as request_left_open with why, and the next run with no goal running carries the ask again (its own one turn).
# A goal's end, either way, hands the player's words back to the run that hears it (as the open request):
GOAL_ENDS = {"goal_done": "goal_done", "stuck": "goal_stuck"}
# DW_ASK_OWNER=1 (off by default, and off while the Director is attached): the goal machinery owns the ask. A run that
# leaves the open ask with no job (request_left_open) no longer ends the matter: unless the player's newest line, his own
# stop / park / done, a goal or a waiting chat line stands in the way, the ask's words go to his Planner verbatim as a
# goal (agent._take_up_ask). Study scratchpad unanswered_1119.md: 19 of 19 questions he asked the silent player were
# followed by nothing, because nothing schedules the next run. Steps come only from his Planner, which may ask (the
# ask is parked, by=planner) or decline (parked with its explanation).
ASK_OWNER_ENV = "DW_ASK_OWNER"
ASK_PLAN_CAP = 6  # Planner calls on one ask (plans and replans of its hand-over goals), then no more hand-overs
ASK_PARKED = "ask_parked"  # the situation that tells him an ask was parked for him (by his planner or the stall rule)
HANDOVER_IF_YOU_STOP = "your planner takes this request as a job, in his words"
TASK_DETAIL_CHARS = 900  # a step's own result words kept on its task for the Planner
ASK_STEP_DETAIL_CHARS = 240  # a step's result words kept with the open ask on disk (brain/ask_store.py)
GOAL_RESULT_CHARS = 400  # of them, per step, for the run that hears the job end (goal_done "results")
# Body situations (unreachable, resumed, vitals_low) are triaged by broker.EventBroker and phrased by
# the Controller model; broker.fallback_line is the template safety net (streamline step 3).

FRESH_REUSE_S = 0.75  # get_state reuse window between body reads with no action in between (see _fresh_state)
POST_ACTION_REUSE_S = 1.0  # the executor's own verification read is this fresh: the next prompt reads it
# DW_ASYNC_PLAN=1 (brain/plan_async.py): the Planner call runs in the background and the Controller keeps his turns.
# These are what he is told; they state facts and leave the choice to him.
PLAN_POLL_S = 0.1
# While the plan is made his one plan_pending turn may end with no call (live 2026-11-19, run 20261119-013245-L2-V1:
# all 5 plan/replan turns did, "I'm letting the planner finish the copper job", and nothing else gave him a turn: chat
# and body situations wake one, reviews wait while a job is active, and an idle body sends no events, so he stood the
# 18-26 s of every composition as with the in-line planner). Mindcraft's self-prompter: an idle actor is prompted again,
# and three replies with no command stop it. Here: with the plan still pending and the body idle (no action of his or
# left running, no move, nothing queued for a turn) this long after his last turn ended, he gets another plan_pending
# turn with how long the body has stood; up to PLAN_QUIET_TURNS turns in a row with no body act, reset by any act.
PLAN_IDLE_TURN_S = 3.0
PLAN_QUIET_TURNS = 3
PLAN_PENDING_NOTE = ("Your planner is making the plan for this job now (it takes a few seconds); it is not here yet. "
                     "Nothing waits on you meanwhile: act on what is plainly next for the job, look something up, "
                     "tell the player, or wait. When the plan arrives you are told; it starts by itself once your "
                     "turn has ended, unless the game has moved past it.")
REPLAN_PENDING_NOTE = ("A step of this job failed (failed_step) and your planner is revising the plan now; the new one "
                       "is not here yet. Nothing waits on you meanwhile: act, look something up, tell the player, or "
                       "wait. When it arrives you are told; it starts by itself once your turn has ended, unless the "
                       "game has moved past it.")
PLAN_STALE_NOTE = ("Your planner's plan for this job arrived, but the game moved past the state it was made on (why). "
                   "It was not started. Its steps are in steps: do them yourself, hand the job to the planner again "
                   "with start_goal (it plans on the game as it is now), or tell the player.")



_ITEM_NAMES: list[str] | None = None


def _item_names() -> list[str]:
    """Every game item's display name (the recipe dump's items and the gear catalog), read once."""
    global _ITEM_NAMES
    if _ITEM_NAMES is None:
        names = {str(e.get("name")) for e in (needs.catalog().get("items") or {}).values()
                 if isinstance(e, dict) and e.get("name")}
        names |= {str(e.get("name")) for e in item_stats.catalog().values() if isinstance(e, dict) and e.get("name")}
        _ITEM_NAMES = sorted(n for n in names if len(n) >= 3)
    return _ITEM_NAMES


def _task_label(t: Task) -> str:
    bits = [str(v) for k, v in t.args.items() if k in ("resource", "item", "target", "player", "count") and v is not None]
    return f"{t.skill} {' '.join(bits)}".strip()


def _step_results(tasks: list[Task]) -> list[str]:
    """What each step of a finished job reported, in the words a call of his own would have been answered with, for
    the run that hears the job end. Window s17 (2026-11-17), runs 044508 and 045210: the hand-in talk was a plan step,
    so "... moved on to its next step, Mine Rune Essence ... Given to you: 1 Stone Pickaxe" stayed on the task. The
    run that heard goal_done saw the goal, "steps": 3 and the statuses, ate, drank and stopped with the quest's next
    step open. 15 to 17 Nov: the hand-in made by the model itself ended in a finished quest 7 times of 11, as a plan
    step 2 of 12. Run 045210 rolled forward from its first call, 10 times each: he went on 0 times as logged, 4 with
    these rows, 9 with the talk report worded as one quest moving on (talk.lua outcome_words). (The plan-and-execute
    idiom: the executor hands the planner's caller each step with its result.)"""
    rows = []
    for t in tasks:
        if t.status not in ("done", "failed"):
            continue
        row = f"{_task_label(t)}: " + ("ok" if t.done else f"FAILED: {t.last_reason}")
        rows.append(row + (f". {t.detail[:GOAL_RESULT_CHARS]}" if t.detail else ""))
    return rows


def _ask_outcome(d) -> str:
    """How the open-ask turn ended, by its calls only (tools.unseen and the window's count read it)."""
    names = {c.name for c in d.actions}
    if oa.DONE in names:
        return "done_claim"
    if oa.PARK in names:
        return "park"
    if names or d.goal or d.skill:
        return "world"
    if d.refusals:
        return "refused"
    return "say" if d.speech else "silent"


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
        self.pending_first: list[Task] | None = None  # start_goal's first_steps (DW_ASYNC_PLAN=1), run while it is planned
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
        self._pending_asked: dict | None = None  # the same for a goal that waits to start (pending_goal)
        # (player, his words): the last thing a player asked, until request_done, park_request or his next line (no
        # silent stop closes it since 2026-11-18). Body runs in between (a review that eats and drinks) carry it in
        # their notes. Chain 20261116-114101: runes made, a failed boil ended the goal's run, the review after it
        # ate, drank and stopped with the quest open (in live order: 0 of 4 went on; with the request named, 6 of 6)
        self._open_request: tuple | None = None
        self.keep_asks_open = True  # an open ask survives one silent turn (oa, the open-ask turn)
        self._ask_seen: dict[tuple, tuple[float, dict]] = {}  # (player, words) -> (when, the state read then)
        self._last_line: dict[str, tuple[str, float]] = {}  # player -> (his last chat line, when): _told_back
        # what the game and his knowledge told him while working on the open ask (oa.keep_fact): kept with that ask,
        # shown with it while it is open, dropped when it ends (live 20261118-010135, 389 s: the tier fact was gone)
        self._ask_facts: list[dict] = []
        self._ask_facts_for: tuple | None = None
        self._serving_ask: tuple | None = None  # the ask the run or goal now acting is for (facts kept only then)
        # the ask he parked last, {ask, facts, names}: a later call of his on one of its items opens it again
        # (oa.serves; live 20261118-034204: parked at 48 s, taken up at 64 s, 12 min standing from 210 s)
        self._parked: dict | None = None
        # the open ask on disk (brain/ask_store.py, goal item 1 of docs/GOAL-2026-11-17-long-jobs.md): written to the
        # world store whenever it changes, read back at startup (attach_ask_store); None: memory only (tests, tools).
        # Run 20261118-021010-N1-I5: killed 4 s into a gather for the chest job, the new brain knew no ask
        self.ask_dir: Path | None = None
        self._ask_steps: list[dict] = []  # the last body calls made for the open ask, with their outcomes
        self._ask_steps_for: tuple | None = None
        self._ask_in_flight: dict | None = None  # the body call running now while an ask is kept
        self._ask_written: dict | None = None  # the record last written (unchanged: no write)
        self._ask_on_disk = False
        self.wall = time.time
        # the job tree of the open ask (brain/job_tree.py), behind DW_JOB_TREE=1: its target from his words, each node
        # checked against the game state each turn, the last failures per node; shown in place of the kept facts
        self.jobs: job_tree.Keeper | None = None
        if job_tree.enabled():
            self.jobs = job_tree.Keeper(lambda: job_tree.GameData.default(
                knowledge=getattr(self.controller, "knowledge", None), places=getattr(self.controller, "places", None)),
                log=self.log, wall=lambda: self.wall())
            self.controller.job_view = self._job_view
        self.request_parked: str | None = None  # the last _command_run ended on a parked step: why
        self._sampled_at: float | None = None  # last get_state the broker observed (situation_review)
        self._in_pump = False
        # The model's line held back during a quick action (said after it, unless a failure replaces it): said
        # as soon as the bridge reports the action accepted and still running (bridge_client.ACCEPTED_AFTER_S).
        self._held: dict | None = None
        if hasattr(game, "on_long_action"):
            game.on_long_action = self._long_action
        # a fight on him (or strong hostiles in sight) during a body call gives the model the floor at once, the way a
        # player's line does (LiveAgent adds the line); the body keeps going (grave study 2026-11-18)
        if hasattr(game, "interrupt_check") and getattr(game, "interrupt_check", None) is None:
            game.interrupt_check = self._interrupt_for
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
        self._plan_asked: set[str] = set()  # the plan questions said beside the running goal (_plan_question)
        # DW_ASYNC_PLAN=1: the Planner call in flight (plan_async.PendingPlan), and a landed plan the next Controller
        # turn has not been told about yet (the "planner" fact in its context)
        self.async_plan = plan_async.enabled()
        self._planning: plan_async.PendingPlan | None = None
        self._steps_plan: plan_async.PendingPlan | None = None  # composed beside his first steps (start_goal first_steps)
        self._plan_landed: dict | None = None
        self._turn_ended_at: float | None = None  # when his last Controller run ended (every run goes through _command)
        # DW_ASK_OWNER=1 (_take_up_ask): the ask a run left with no job, (ask, run_for, why, when); his own stop on the
        # open ask; the hand-over goal queued and the one running ({ask, goal, n, continue, his_calls}); the last stuck
        # goal on an ask ({ask, goal, tree, failed_i, failed, reason, state, prev}); Planner calls and hand-overs per ask
        self.ask_owner = os.environ.get(ASK_OWNER_ENV, "0") == "1"
        self._unowned: tuple | None = None
        self._stopped_ask: tuple | None = None
        self._handover_next: dict | None = None
        self._handover: dict | None = None
        self._last_stuck: dict | None = None
        self._last_done: dict | None = None  # the last hand-over goal on an ask whose plan ran to its end (_done_by_plan)
        self._ask_plan_calls: dict[tuple, int] = {}
        self._handovers: dict[tuple, int] = {}
        controller.plan_provider = self._plan_fact
        game.set_progress_listener(self._on_progress)

    # ---------------------------------------------------------------- events

    def step(self) -> GoalResult | None:
        """Handle pending events, then start any goal the controller queued."""
        self.pump()
        if self._unowned is not None:  # (only ever set with DW_ASK_OWNER=1)
            self._take_up_ask()
        if self.pending_goal:
            goal, tasks, skill, first = self.pending_goal, self.pending_tasks, self.pending_skill, self.pending_first
            self.pending_goal, self.pending_tasks, self.pending_skill, self.pending_first = None, None, None, None
            ho, self._handover_next = self._handover_next, None
            if self.budget is not None and not self.budget.allows("planner"):
                self.log.log("goal_dropped", goal=goal, why="out of model budget")
                if self.budget.out_line_due():
                    self.controller.say(self.budget.out_line())
                return "stuck"
            self._handover = ho if ho is not None and ho["goal"] == goal and not skill else None
            eid, self._goal_episode = getattr(self, "_goal_episode", None), None
            with self.log.episode(eid or self.log.new_episode_id("goal")):
                return self.run_goal(goal, tasks=tasks, skill=skill, first=first)
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
        if (proxy := getattr(self, "planner_proxy", None)) is not None:
            proxy.serve()  # body reads a background Planner call asked for (DW_ASYNC_PLAN); empty in line
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
            self.broker.note_unavailable(str(exc))
            return {"unavailable": str(exc)}
        self.broker.observe(state)  # where am I, am I moving, who is in sight (body_status "Where:")
        self._sampled_at = self.broker.clock()
        return state

    def _body_situation(self, event: Event) -> None:
        state = self._fresh_state(reuse=True)
        v = self.broker.assess(event, state)
        if v.action == "decide":
            e = v.event
            if isinstance(e, dict) and e.get("type") == RUNNING_RESULT and e.get("ok") is False and \
                    e.get("reason") not in fight_news.NOT_RUN:  # it ran on and then failed: did he die meanwhile?
                died = fight_news.died_during(self._fresh_state(), float(e.get("ran_s") or 0) + 2.0)  # fresh: a death
                if died is not None:
                    e = {**e, "reason": Reason.COMPANION_DOWN, "body_reason": e.get("reason"), "died": died,
                         "detail": fight_news.death_detail(str(e.get("tool")), died, e.get("reason"), e.get("detail"))}
                    self.log.log("death_during_call", tool=e.get("tool"), body_reason=e["body_reason"],
                                 cause=died["cause"], ago_s=died["ago_s"], late=True)
            self._situations.append(e)

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
        if self._planning is not None and event.kind == "death":
            self._planning.died = True
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

    def _craft_sources(self, task: Task, outcome: Outcome) -> None:
        """A craft that failed short: each missing row gets the sources craft_plan would give it, and the step's result
        words end with them (brain/plan_sources.py enrich_craft_failure; live 2026-11-18 00:08Z, 389 s: "the bone pickaxe
        needs stuff we don't have" though Bark to Bones was his and a Tannery is a build-menu piece). Facts only."""
        from . import plan_sources
        ctl = self.controller
        try:
            state = self.executor.state(max_age=POST_ACTION_REUSE_S)
        except Exception:  # an unreadable state leaves the facts that don't need it
            state = {}
        state = state if isinstance(state, dict) and not state.get("unavailable") else {}
        try:
            spells = ctl.castable_spells() if (ctl.has("spells") or ctl.has("cast")) else None
        except Exception:
            spells = None
        try:
            line = plan_sources.enrich_craft_failure(
                outcome.data if isinstance(outcome.data, dict) else None, state=state, spells=spells,
                knowledge=getattr(ctl, "knowledge", None), places=getattr(ctl, "places", None), log=self.log)
        except Exception as exc:  # facts are a bonus; the failure stands without them
            self.log.log("craft_sources_error", error=repr(exc))
            line = None
        if line:
            task.detail = (f"{task.detail} " if task.detail else "") + line
        data = outcome.data if isinstance(outcome.data, dict) else {}
        short = str(data.get("detail") or "").split(". ", 1)[0].rstrip(".")  # "I need 8 Animal Bone ... and I have 0"
        if short or line:
            item = (task.args or {}).get("item") or data.get("item")
            self._keep_ask_fact(f"craft:{item}", f"craft {item} {outcome.reason}",
                                ". ".join(x for x in (short, line) if x), raw=line or short)

    def _plan_bag(self, state: dict | None) -> None:
        """His bag when the plan that runs now was made: a queued craft held short says what it gained since."""
        from .plan_sources import counts
        try:
            self.executor.plan_bag = counts(state) if isinstance(state, dict) else None
        except AttributeError:  # an executor stand-in without the field
            pass

    @staticmethod
    def _interrupt_for(event: Event) -> str | None:
        """The bridge's interrupt check for body events: "fight" / "threat" take the floor during a body call."""
        return fight_news.interrupt_reason(event)

    def _death_truth(self, task: Task, outcome: Outcome, started: float) -> None:
        """A call that failed while he died says so, with what killed him (grave study 2026-11-18: explore answered
        nothing_in_range 0.6 s after his death, run 20261116-062404; go_to "interrupted (stopped)", run
        20261118-010135 at 668.5 s). The game's own death row (get_state.last_death) is the evidence; the call's own
        reason and words are kept beside it."""
        if outcome.ok or outcome.reason in fight_news.NOT_RUN:
            return
        try:
            state = self.executor.state(max_age=POST_ACTION_REUSE_S)
        except Exception:  # unreadable: the call's own reason stands
            return
        died = fight_news.died_during(state, time.monotonic() - started)
        if died is None:
            return
        data = outcome.data if isinstance(outcome.data, dict) else {}
        own_reason, own = outcome.reason, data.get("detail") or data.get("why")
        data.update(detail=fight_news.death_detail(task.skill, died, own_reason, own), died=died,
                    body_reason=own_reason)
        outcome.data, outcome.reason = data, Reason.COMPANION_DOWN
        task.last_reason = Reason.COMPANION_DOWN
        self.log.log("death_during_call", tool=task.skill, args=task.args, body_reason=own_reason, cause=died["cause"],
                     ago_s=died["ago_s"])

    def _fight_turn(self, task: Task, outcome: Outcome, started: float) -> None:
        """The wait was detached for a fight (or strong hostiles in sight): queue the situation that gives the model a
        turn now, with the fight shown. The model decides; nothing here fights, flees or stops anything."""
        data = outcome.data if isinstance(outcome.data, dict) else {}
        self._stash.extend(self.game.poll_events())  # the events that took the floor (handled by the next pump too)
        events = [e for e in self._stash if isinstance(e, Activity) and e.kind in fight_news.SHOWN_KINDS]
        try:
            state = self.executor.state(max_age=POST_ACTION_REUSE_S)
        except Exception:
            state = {}
        ran = data.get("running_s") if isinstance(data.get("running_s"), (int, float)) else time.monotonic() - started
        sit_ = fight_news.fight_situation(events, state, {"tool": task.skill, "args": task.args, "ran_s": ran},
                                          str(data.get("by")))
        if self.active_goal and not self._quiet_goal:
            sit_["job"] = self.active_goal
        self._situations = [e for e in self._situations if e.get("type") != "fight"] + [sit_]  # the newest only
        self.log.log("fight_turn", by=data.get("by"), tool=task.skill, who=sit_.get("who"), odds=sit_.get("odds"),
                     your_hp=sit_.get("your_hp"), events=[e.kind for e in events])

    def _run_task(self, task: Task) -> Outcome:
        """Every body action the brain runs goes through here, so the broker knows the brain's own moves."""
        # the same call as the action the body is still doing since the player spoke: the executor re-attaches to it
        continues = getattr(self.executor, "continues", None)
        self.broker.action_started(task.skill, task.args, continuing=bool(continues and continues(task)))
        self.broker.note_busy()
        started = time.monotonic()
        self._ask_call_started(task)
        try:
            outcome = self.executor.run_task(task)
        except Exception:  # an error the brain lives through: no call is lost (a killed brain runs nothing here)
            self._ask_in_flight = None
            self._save_ask()
            raise
        self._ask_call_ended(task, outcome)
        self._death_truth(task, outcome, started)
        detail = (outcome.data or {}).get("detail") if isinstance(outcome.data, dict) else None
        task.detail = str(detail)[:TASK_DETAIL_CHARS] if detail else None
        if not outcome.ok:  # not found, or gather's wrong_tool: what his own knowledge says about where it is and the
            # tool it takes against his best (facts, with source), on every
            # path: a Planner step's result is what the replan and the stuck message show (live 2026-11-17 22:24Z, run
            # 20261117-212448-L2: explore and gather ran as plan steps and only the turn's own calls carried it)
            got = result_knowledge.note(getattr(self.controller, "knowledge", None), task.skill, task.args,
                                        {"ok": False, "reason": outcome.reason, "data": outcome.data},
                                        lambda: self.executor.state(max_age=POST_ACTION_REUSE_S))  # where he is, his tools
            if got is not None:
                self.log.log("result_knowledge", tool=task.skill, query=got[0], added=got[1])
                if isinstance(outcome.data, dict):
                    outcome.data["knowledge"] = got[1]
                task.detail = (f"{task.detail} " if task.detail else "") + f"({got[1]})"
                self._keep_ask_fact("node:" + got[1].split(":", 1)[0], f"{task.skill} {got[0]!r} {outcome.reason}",
                                    got[1])  # (one per node: "wiki, Copper Ore Node")
            if outcome.reason == Reason.WRONG_TOOL and task.detail:  # the body's own words: what tool it lacks
                what = (task.args or {}).get("resource") or (task.args or {}).get("target") or ""
                self._keep_ask_fact(f"wrong_tool:{task.skill}:{what}",
                                    f"{task.skill} {what!r} wrong_tool" if what else f"{task.skill} wrong_tool",
                                    str(detail), raw=str(detail)[:TASK_DETAIL_CHARS])
        if not outcome.ok and task.skill == "craft" and outcome.reason == Reason.MISSING_MATERIALS:
            self._craft_sources(task, outcome)
        self._killed_note(task, outcome)
        self.broker.action_finished(task.skill, task.args, outcome.ok, outcome.reason, outcome.data)
        if outcome.reason == Reason.STILL_RUNNING and isinstance(outcome.data, dict) and \
                outcome.data.get("by") in ("fight", "threat"):
            self._fight_turn(task, outcome, started)
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
        # a run nested in a goal's step (a need, a fight) sets its own ask; the goal's is back when it ends
        serving, shown = self._serving_ask, getattr(self.controller, "open_request", None)
        if event.text:  # every chat line reaches here (addressed or not): the player's last line, for _told_back
            self._last_line[event.player] = (event.text, self.clock())
        try:
            if self._directed is None or not event.text:
                return self._command_run(event, addressed, body_events)
            prev, self._directed_origin = self._directed_origin, "chat"  # a chat command nested in a board run
            try:
                return self._command_run(event, addressed, body_events)
            finally:
                self._directed_origin = prev
        finally:
            self._serving_ask = serving
            self.controller.open_request = shown
            self._save_ask()
            self._turn_ended_at = self.clock()

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
        if heard:
            self._open_request = (event.player, event.text)
            if self.jobs is not None:
                self.jobs.open(self._open_request)
            self._note_ask(self._open_request, state, new=True)  # a line heard now is a new ask
            self._drop_ask_facts("a new line")
            self._parked = None  # his new line is the ask now
            if self.ask_owner:  # a new ask, even in the same words: its own stop, Planner count and stuck record
                self._stopped_ask = None
                self._ask_plan_calls.pop(self._open_request, None)
                self._handovers.pop(self._open_request, None)
                if self._last_stuck and oa.same_ask(self._last_stuck["ask"], self._open_request):
                    self._last_stuck = None
                if self._last_done and oa.same_ask(self._last_done["ask"], self._open_request):
                    self._last_done = None
            self._ask_steps, self._ask_steps_for = [], self._open_request
            self._save_ask()  # on disk before the first model call: a brain killed while thinking keeps it
        # the request this run is for: his line, the one a goal came from at its end, or the one still open. A goal's
        # end is goal_done or stuck: live 2026-11-18 00:24Z (brain-live-20261118-012330-23088), the goal for "thirty
        # copper ore in the chest" got stuck on its craft step; the stuck run ran inside run_goal with active_goal still
        # set, so it carried no request, made a stone pickaxe, found no copper in range, said why and stopped: no
        # open-ask turn, no row, 25 min standing with the ask open
        ended = next((e for e in body_events or [] if e.get("type") in GOAL_ENDS and e.get("request")), None)
        goal_for = (ended.get("from"), ended["request"]) if ended else None
        if goal_for:  # a goal's end is the next step of what he asked: open again, whatever the run before said
            if not oa.same_ask(goal_for, self._open_request):
                self._drop_ask_facts("another ask reopened")
            if self._parked and oa.same_ask(self._parked["ask"], goal_for):  # parked, and its goal ended: its facts
                self._ask_facts, self._ask_facts_for = list(self._parked["facts"]), self._parked["ask"]
                self._parked = None
            self._open_request = goal_for
            self._note_ask(goal_for, state)  # (kept when it was heard in this session: the baseline is the ask's)
            self._save_ask()
        # ...a goal still running is doing the open one: a body run beside it (a need, an attack) is not for it
        run_asked = (event.player, event.text) if event.text else goal_for or (
            None if self.active_goal or self.pending_goal else self._open_request)
        run_for = "line" if event.text else GOAL_ENDS[ended["type"]] if ended else "carried" if run_asked else None
        # DW_ASYNC_PLAN=1: his turn while the Planner makes the goal's plan (agent._plan_turn) acts on the goal's ask,
        # though the goal is running (so run_asked stays None: not an open-ask run, no left-open row). He is shown
        # what a run on it is shown, the job tree too (DW_JOB_TREE=1), built here on the loop thread: the 19-21 s
        # opening stand of the job-tree trials of 2026-11-19 is the time this turn has to act on it
        pending = next((e for e in body_events or [] if e.get("type") == "plan_pending" and e.get("request")), None)
        view_ask = run_asked or ((pending.get("from"), pending["request"]) if pending else None)
        # what the game told him about the ask, kept with it (oa.keep_fact), shown on every turn of a run for it
        self._serving_ask = view_ask if oa.same_ask(view_ask, self._open_request) else None
        self.controller.open_request = self._open_view(view_ask, body_ctx, where="turn", state=state)
        # a goal he queued that has not begun (step() starts it after this run): the run is told of it. Run
        # 20261117-041914: "chopping them now" + start_goal, a hunger event came in before the goal began, and the
        # run for it knew nothing of the waiting goal: it chopped the 48 logs and handed them in itself (260 s),
        # then the goal began and the Planner had the done work done again.
        self.controller.queued_goal = self.pending_goal if not self.pending_skill else None
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
        open_ask, open_asked, open_prev = False, False, False  # the open-ask turn: now, once in this chain, the last one
        # every call this request ran and how it went, for a hand-on's fresh run (a handed-on request carries its own on)
        work: list[dict] = [*(body_ctx.get("done_so_far") or []), *(body_ctx.get("last_results") or [])]             if isinstance(body_ctx, dict) and body_ctx.get("type") == CHAIN_BUDGET else []
        while True:
            if d.interrupts and self.active_goal and self._replaces_job(d, event):
                self._cancelled = True
            if run_asked is None and (reopened := self._reopen_parked(d)) is not None:
                # he took the parked ask up himself: this run is on it now (its stop gets the one open-ask turn)
                run_asked, run_for, self._serving_ask = reopened, "reopened", reopened
                self.controller.open_request = self._open_view(reopened, None, where=None)
            t = self._run_turn(d, state, event)
            work.extend(_work_rows(d, t, WORK_DETAIL_CHARS))
            nonbody_success = not t["ran"] and any(r.get("ok", True) for r in t["results"].values())
            acted = acted or bool(t["ran"]) or nonbody_success
            ran_all.extend(t["ran"])
            if t["failure"] and t["failed_call"] is None:  # refused before the body (safety, no such tool)
                self.controller.report_failure(*t["failure"])
                said = True
                self._left_open(run_asked, run_for, "a call was refused", open_prev)
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
            if t.get("closed") and not t["ran"] and not t["failure"]:
                break  # he closed the open ask (request_done / park_request) and ran nothing else: his stop
            open_prev, open_ask = open_ask, False
            fail_check = False
            if parked or last_turn:  # caps spend: the model heard why and had its one turn to say it
                self.log.log("chain_stopped", turns=turn, why="parked" if parked else "deadline", parked=parked)
                if not (t["ran"] or t["failure"] or d.goal or d.skill):  # he stopped there with the ask open
                    self._left_open(run_asked, run_for, "parked step" if parked else "deadline", open_prev)
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
            # ...and for a later body run while that request is still open (run_asked): a line with no call there
            # gets the same one turn (the request stays open after it: _left_open)
            goal_asked = None if event.text else run_asked
            asked = bool(event.text) or bool(goal_asked)
            # ...and a chat run whose own ask is still open names it too: PROMISE_NOTE's "(you only answered or asked
            # something) reply with no text at all" made a question on the ask terminal (window l2_v1_1118l, 4 of 4
            # copper runs ended on "where's a copper vein?"; replayed the turn after it: 0/18 act; with this note and
            # the say result told back, 12/18). No ask open (a line not addressed to him): PROMISE_NOTE as before.
            promise_ask = goal_asked or (run_asked if event.text and run_asked and run_asked == self._open_request
                                         else None)
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
            stop_for = (not stop_checked and self.check_promises and bool(goal_asked)
                        and goal_asked == self._open_request and not t["ran"] and not t["failure"] and not d.speech
                        and not (d.actions or d.goal or d.skill or d.refusals))  # STOP_FOR_NOTE
            if stop_for:
                self.log.log("stop_for_check", request=goal_asked[1])
            stop_checked = stop_checked or stop_check or promise_check or unheard or stop_for  # never doubled
            more = more or stop_check or stop_for
            stop_line, prev_line = prev_line, this_line
            # not in a board run: the board reports its own step failures (test_recovery_decision_dispatch)
            if not more and unreported and not fail_checked and not t["failure"] and self._directed is None                     and not self._player_spoke():
                fail_check = fail_checked = more = True
                stop_checked = True  # never doubled with the STOP_NOTE check
                self.log.log("failure_unreported", failures=unreported)
            # the request's latest body failure still stands: no body action of a later turn worked
            failed_any = bool(t["failure"]) or (failed_any and not t["ran"])
            # (a learned skill he queued is a job handed on as much as a goal is)
            handed = handed or bool(d.goal) or bool(d.skill) or any(c.name in LONG_JOB_TOOLS for c in d.actions)
            open_check = False
            job_tool = None
            if not more and failed_any and not (handed or open_checked):
                job_tool = next((n for n in LONG_JOB_TOOLS if n in getattr(self.controller, "offered", set)()), None)
            if (job_tool and self.check_promises and bool(event.text) and not body_events and self._directed is None
                    and not self._player_spoke()):
                open_check = open_checked = stop_checked = more = True  # never doubled with the STOP_NOTE check
                self.log.log("open_job_check", request=event.text, tool=job_tool)
            if not more:
                if (run_asked and run_asked == self._open_request and not t["ran"] and not t["failure"]
                        and not (d.actions or d.goal or d.skill)):
                    # a stop on the open ask: one more turn shows it as data, with request_done / park_request (oa).
                    # Any stop: also one after a failure's line, or in a body run whose notes never named the ask (the
                    # block names it). Live 20261118-012330: the stuck run's last turn said why copper was out of
                    # reach after a failed gather; that note did not name the ask, so no turn ran and nothing was logged
                    why_not = "had one this run" if open_asked else (
                        "handed to a job" if handed else self._no_open_ask_turn())
                    if why_not is None:
                        open_ask = open_asked = more = stop_checked = True  # never doubled with a check
                    else:  # not closed by silence: open until request_done, park_request or his next line
                        self._left_open(run_asked, run_for, why_not, open_prev)
                        break
                if not more:
                    break
            spoke = self._player_spoke()
            late = self.clock() >= deadline
            if late and t["ran"] and not spoke and turn < MAX_TURNS:
                last_turn = True  # a long action (a 295 s go_to) used the time up: never cut off its report
            elif spoke or ((turn >= MAX_TURNS or late) and not open_ask):  # (the open-ask turn: _no_open_ask_turn)
                self.log.log("chain_stopped", turns=turn,
                             why="the player spoke" if spoke else "deadline" if late else "budget")
                if self._directed is not None and spoke:
                    self._directed_end = "chat"
                if not spoke and not late and self._hand_on(event, d, t, body_events, work, run_asked):
                    break  # the model hears the last results in a fresh run (live 17:2xZ: he stood 194 s here)
                if t["failure"] and not spoke:  # the model never saw this failure; when he spoke, he has the
                    self.controller.report_failure(*t["failure"])  # floor (the next run's body_status has it)
                    said = True
                elif not spoke and not said and self._directed is None:  # hand-ons used up, nothing said: he must
                    line = fallback_line([{"type": CHAIN_BUDGET, "request": event.text or next(  # not stop silently
                        (e.get("request") for e in body_events or [] if e.get("type") == CHAIN_BUDGET),
                        run_asked[1] if run_asked else None)}])
                    said = bool(line) and self.controller.say(line, kind=kind) is not None
                break
            turn += 1
            before, state = state, sit.with_asked(self._fresh_state(after_action=True), self._asked)
            parked = self._note_progress(t, before, state, event.player)
            self.request_parked = parked or self.request_parked
            news = self._news()
            try:
                promise_for = promise_check and promise_ask
                # (a fact this run's own steps added shows on the next turn: next_turn shows them when they changed)
                self.controller.open_request = self._open_view(run_asked, None, where=None)
                shown = self._open_ask_block(run_asked, state) if open_ask else None
                say_res = {"ok": True, "note": "said"} if line_said else \
                    {"ok": None, "note": "not said: a step failed first; say what's true now" if t["failure"]
                     else "not said (too close to a line you just said)"}
                if line_said and run_asked and run_asked == self._open_request:  # a line on his open ask: told back
                    told = self._told_back(run_asked, state, t, d, handed)
                    say_res = {**say_res, **told}
                    self.log.log("say_told_back", request=run_asked[1], player=run_asked[0], turn=turn,
                                 heard_by=told["heard_by"], working_on_it=told["his_request"]["working_on_it"],
                                 note="open_ask" if open_ask else "promise_for" if promise_for else
                                 "promise" if promise_check else "other" if (parked or last_turn or fail_check
                                                                            or open_check or stop_check or stop_for
                                                                            or unheard) else None)
                d = self.controller.next_turn(d, {**t["results"], "say": say_res}, state, failed=bool(t["failure"]),
                                              note=oa.NOTE_PREFIX + json.dumps(shown, ensure_ascii=False, default=str)
                                              if open_ask else PARKED_NOTE if parked else LAST_TURN_NOTE if last_turn else
                                              UNREPORTED_NOTE.format(player=self.controller.player, items="; ".join(
                                                  f"{f['tool']} {f['reason']}" + (f" ({f['detail']})" if f["detail"] else "")
                                                  for f in unreported)) if fail_check else
                                              OPEN_JOB_NOTE.format(request=event.text, tool=job_tool) if open_check else
                                              PROMISE_FOR_NOTE.format(
                                                  player=promise_ask[0] or self.controller.player,
                                                  request=promise_ask[1])
                                              if promise_for else
                                              PROMISE_NOTE if promise_check else UNHEARD_NOTE if unheard else
                                              STOP_NOTE.format(line=stop_line) if stop_check else
                                              STOP_FOR_NOTE.format(player=goal_asked[0] or self.controller.player,
                                                                   request=goal_asked[1]) if stop_for else None,
                                              news=news, request=run_asked,
                                              extra_tools=list(oa.ASK_TOOL_SCHEMAS) if open_ask else None)
            except Exception as exc:  # model/provider error: the template still says why
                if open_ask:
                    self.log.log("open_ask_turn", request=run_asked[1], player=run_asked[0], shown=shown,
                                 turn=turn, outcome="error")
                self.log.log("next_turn_error", turn=turn, error=repr(exc))
                if t["failure"]:
                    self.controller.report_failure(*t["failure"])
                    said = True
                break
            self.request_calls += d.model_calls
            if open_ask:
                self.log.log("open_ask_turn", request=run_asked[1], player=run_asked[0], shown=shown, turn=turn,
                             outcome=_ask_outcome(d), actions=[c.name for c in d.actions], speech=d.speech,
                             run_for=run_for)
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
                    if (run_asked and run_asked == self._open_request and not open_asked and not handed
                            and self._no_open_ask_turn() is None):
                        # ...but with the ask still open that silence is a stop on it: his empty turn goes on to the
                        # open-ask turn, and no other check comes before it
                        stop_checked = fail_checked = open_checked = True
                        continue
                    self._left_open(run_asked, run_for, "had one this run" if open_asked else "handed to a job"
                                    if handed else self._no_open_ask_turn() or "silent after a failure", open_prev)
                break
        if self._ask_owner_on():
            self._note_his_stop(run_asked, ran_all)
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
            self.pending_goal, self.pending_first = d.goal, d.first_steps
            # a body-only run before the goal starts clears self._asked. A body run on the open ask (no line, no
            # asked_at in its event) queues it for that ask: live 20261118-010135 row 567, a run after a fight queued
            # "Mine 30 copper ore", and its stuck event (row 692) reached the model with no request
            self._pending_asked = self._asked if (self._asked or {}).get("request") else self._asked_of(run_asked)
        if self.pending_goal:
            self._goal_episode = self.log.episode_id  # the goal's rows stay in the episode that asked for it

    def _hand_on(self, event: CommandReceived, d, t: dict, body_events: list[dict] | None,
                 work: list[dict] | None = None, asked: tuple | None = None) -> bool:
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
        # (a body run on the open ask hands his words on too: live 20261118-010135 row 588, "request": null)
        request = (prev or {}).get("request") or event.text or (asked[1] if asked else None)
        self._situations.append({
            "type": CHAIN_BUDGET, "hand_on": n, "of": MAX_HAND_ONS, "request": request, "asked_at": self._asked,
            "from": (prev or {}).get("from") or (event.player if event.text else asked[0] if asked else None),
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
        closed = None  # request_done / park_request closed the open ask this turn
        for call in ([] if failure else acts):
            if call.name in oa.ASK_TOOLS:
                results[call.id or call.name] = self._close_ask(call, extra)
                closed = call.name
                continue
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
            if self._planning is not None:  # a body act while the Planner composes (acted_while_planning)
                self._planning.acted(call.name)
                self._serve_planner_reads("turn")  # its research's body reads, between his calls
            if outcome.reason == Reason.BUSY and isinstance(outcome.data, dict) and not outcome.data.get("owner"):
                hint = self.broker.busy_with()  # name who had the body (the stay-fed reflex), never a token
                if hint:
                    outcome.data.update(busy_with=hint["what"], busy_by=hint["by"], busy_item=hint["name"])
            res = {"ok": outcome.ok, "reason": outcome.reason, "data": outcome.data}
            body.append((call.id or call.name, call.name, call.arguments))
            if not outcome.ok and outcome.reason in (Reason.UNKNOWN_TARGET, Reason.INVALID_ARGS, Reason.NOT_PERCEIVED,
                                                     Reason.AMBIGUOUS_TARGET):
                res["args_help"] = self.controller.arg_help(call.name)  # how to name a target for this tool
            if isinstance(outcome.data, dict) and outcome.data.get("knowledge"):  # added in _run_task, shown beside the reason
                res["knowledge"] = outcome.data.pop("knowledge")
            results[call.id or call.name] = res
            if not outcome.ok:
                failure, failed_call = (call.name, outcome.reason, outcome.data), call
                break  # steps run in order and stop at the first that fails (the model hears why)
        if d.skill and failure is None:
            failure = self._queue_skill(*d.skill, state)
            if failure and d.skill_call is not None:  # it could not start (params, preconditions): the model hears why
                failed_call = d.skill_call
                results[failed_call.id or failed_call.name] = {"ok": False, "reason": failure[1], "data": failure[2],
                                                               "args_help": self.controller.arg_help("run_skill")}
        if ran and self._handover is not None and self.active_goal:
            self._handover["his_calls"] += len(ran)  # his own body calls while his planner's job runs (double work)
        return {"failure": failure, "failed_call": failed_call, "results": results, "extra": extra,
                "spoken": spoken, "ran": ran, "body": body, "closed": closed}

    # ---------------------------------------------------------------- the open ask (brain/open_ask.py)

    def _note_ask(self, ask: tuple, state: dict, new: bool = False) -> None:
        """Where the game stood when this ask opened: the baseline its open-ask turn's changes are read against.
        new: a line heard now (a new ask, even in the same words); an ask reopened by a goal's end keeps its own."""
        if (ask in self._ask_seen and not new) or not oa.readable(state):
            return
        self._ask_seen.pop(ask, None)  # re-inserted last: the oldest baseline is the one dropped
        self._ask_seen[ask] = (self.clock(), state)
        while len(self._ask_seen) > ASKS_SEEN:
            self._ask_seen.pop(next(iter(self._ask_seen)))

    def _asked_of(self, ask: tuple | None) -> dict | None:
        """The goal's asked_at for an ask with no line in this run (a body run on the open ask): the ask's words, and
        where he stood when it was asked when that read is kept."""
        if not ask or not oa.same_ask(ask, self._open_request):
            return self._asked
        seen = self._ask_seen.get(self._open_request) or self._ask_seen.get(ask)
        pos = (seen[1] or {}).get("position") if seen else None
        ok = isinstance(pos, (list, tuple)) and len(pos) >= 3
        return {"position": [round(float(v), 1) for v in pos[:3]] if ok else None, "request": ask[1],
                "player": ask[0], "player_at": None}

    # what the game told him about the open ask (oa.keep_fact): kept while a run or goal acts on it, shown with it

    def _keep_ask_fact(self, key: str, source: str, text: str, raw: str | None = None) -> None:
        ask = self._open_request
        if not (ask and oa.same_ask(self._serving_ask, ask)):
            return  # a run beside the ask (a need, a fight) or no ask: not about it
        if not oa.same_ask(self._ask_facts_for, ask):
            self._ask_facts = []
        self._ask_facts_for = ask
        self._ask_facts = oa.keep_fact(self._ask_facts, key, source, text, raw=raw, t=self.clock())
        self.log.log("ask_fact_kept", request=ask[1], key=key, source=source, chars=len(text or ""),
                     kept=len(self._ask_facts))
        self._save_ask()

    def _request_facts(self, exclude: str | None = None, where: str | None = None) -> list[str]:
        """The open ask's kept facts as shown (newest first, bounded), [] when none or no ask is open. ``where``: a
        row says they were shown there (tools.unseen signature request_facts_shown)."""
        ask = self._open_request
        if not (ask and self._ask_facts and oa.same_ask(self._ask_facts_for, ask)):
            return []
        view = oa.facts_view(self._ask_facts, exclude=exclude, now=self.clock())
        if view and where:
            self.log.log("request_facts_shown", where=where, request=ask[1], n=len(view),
                         chars=sum(len(s) for s in view))
        return view

    def _drop_ask_facts(self, why: str) -> None:
        if self._ask_facts:
            self.log.log("ask_facts_dropped", request=(self._ask_facts_for or (None, None))[1], why=why,
                         n=len(self._ask_facts))
        self._ask_facts, self._ask_facts_for = [], None

    def _job_view(self, state: dict | None = None, where: str | None = None) -> dict | None:
        """The compact job tree of the open ask (DW_JOB_TREE=1) from this state (a fresh read when None); None when
        there is no tree for it."""
        if self.jobs is None or not self.jobs.active(self._open_request):
            return None
        if state is None:
            try:
                state = self._fresh_state(reuse=True)
            except Exception:  # a state that can't be read: no tree this turn
                return None
        return self.jobs.compact_view(state, where=where)

    def _open_view(self, ask: tuple | None, body_ctx: dict | None, where: str | None,
                   state: dict | None = None) -> dict | None:
        """The Controller's open_request block for a run on the open ask: his words and the kept facts; None when the
        run is not for it or nothing is kept. A goal's end event carries them itself (request_facts). With the job
        tree on (DW_JOB_TREE=1) the tree takes the facts' place."""
        if not (ask and oa.same_ask(ask, self._open_request)):
            return None
        if self.jobs is not None and self.jobs.active(ask):
            view = self._job_view(state, where=where)
            if view:
                return {"player": ask[0], "words": ask[1], "job_tree": view}
        carried = isinstance(body_ctx, dict) and body_ctx.get("request_facts")
        facts = self._request_facts(where=None if carried else where)
        return {"player": ask[0], "words": ask[1], "known_facts": facts} if facts else None

    def _park(self, ask: tuple | None, reason: str | None) -> None:
        """park_request: the ask, its facts and the game item names it names are kept, so a later step of his on one
        of those items opens it again (``_reopen_parked``)."""
        if not ask:
            self._parked = None
            return
        facts = self._ask_facts if oa.same_ask(self._ask_facts_for, ask) else []
        text = " ".join([str(ask[1] or ""), str(reason or ""), *(f.get("text") or "" for f in facts)])
        try:
            names = oa.names_in(text, _item_names())
        except Exception:  # item data is best effort: the park stands without it
            names = set()
        self._parked = {"ask": ask, "facts": list(facts), "names": sorted(names), "reason": reason}

    def _reopen_parked(self, d) -> tuple | None:
        """With no ask open and none being worked on, a call of this turn (a body action, an inline read, or the goal
        it queues) on an item the parked ask names opens that ask again with its facts; returns it, else None."""
        p = self._parked
        if not p or self._open_request is not None or self.active_goal or not p.get("names"):
            return None
        calls = [{"tool": c.name, "args": c.arguments} for c in d.actions] + list(getattr(d, "reads", None) or [])
        hit = oa.serves(calls, set(p["names"]))
        if hit is None and d.goal:
            named = oa.names_in(d.goal, p["names"])
            hit = ("start_goal", d.goal[:80], sorted(named)[0]) if named else None
        if hit is None:
            return None
        ask = p["ask"]
        self._open_request, self._parked = ask, None
        self._ask_facts, self._ask_facts_for = list(p["facts"]), ask if p["facts"] else None
        self.log.log("request_reopened", request=ask[1], player=ask[0], tool=hit[0], arg=hit[1], item=hit[2],
                     facts=len(p["facts"]))
        self._save_ask()
        return ask

    def _no_open_ask_turn(self) -> str | None:
        """Why the chain cannot run the open-ask turn now, or None. The turn budget and the deadline do not bar it: it
        is one call, at most one per chain, and a stop at the limit is still a stop with the ask open (the chain stops
        after it if it acts: the hand-on or the report takes over)."""
        if not self.keep_asks_open:
            return "off"
        if self._player_spoke():
            return "the player spoke"  # his line has the floor; it is the new open ask
        return None

    def _left_open(self, ask: tuple | None, run_for: str | None, why: str, after_open_ask_turn: bool) -> None:
        """A run ended on the open ask with no turn left for it, or silent after its open-ask turn: the ask is NOT
        closed (only request_done, park_request or the player's next line end it); the next run with no goal running
        carries it and gets its own one turn. One row says so, with why (tools.unseen signature)."""
        if not ask or ask != self._open_request:
            return
        self.log.log("request_left_open", request=ask[1], player=ask[0], run_for=run_for,
                     after_open_ask_turn=after_open_ask_turn,
                     **({} if after_open_ask_turn else {"no_open_ask_turn": why}))
        if self._ask_owner_on() and why not in ("the player spoke", "off"):
            self._unowned = (ask, run_for, why, self.clock())  # step() decides whether his Planner takes it up

    def _told_back(self, ask: tuple, state: dict | None, t: dict, d, handed: bool) -> dict:
        """What is true about a line he just said on the open ask, for its say result (study ask_vs_act 2026-11-18,
        variant V2): who could hear it (players in perception), the asking player's last line and how long ago, and
        what works on his request now. Facts read by code, no advice: he may still ask and wait."""
        state = state or {}
        me = getattr(self.controller, "name", None)
        names = [str(p["name"]) for p in state.get("players") or []
                 if isinstance(p, dict) and p.get("name") and not (me and sit.same_player(p["name"], me))]
        who = ask[0] or self.controller.player
        asker: dict = {"in_sight": any(sit.same_player(n, who) for n in names)}
        if not asker["in_sight"]:
            mark = next((r for r in state.get("map_players") or []
                         if isinstance(r, dict) and sit.same_player(r.get("name"), who)), None)
            dist = sit.num(mark.get("distance")) if mark else None
            if dist is not None:
                asker["map_marker"] = f"{dist:.0f} m {mark.get('direction') or ''}".strip()
        last = next((v for k, v in self._last_line.items() if sit.same_player(k, who)), None)
        asker["last_line"] = last[0] if last else None
        asker["last_line_s_ago"] = round(self.clock() - last[1]) if last else None
        work = []
        if d.goal or d.skill:
            work.append(f"a goal queued: {d.goal or d.skill}")
        elif self.active_goal or self.pending_goal:
            ho = (self._handover if self.active_goal else self._handover_next) if self._ask_owner_on() else None
            if ho is not None and oa.same_ask(ho["ask"], ask):  # DW_ASK_OWNER=1: his planner's job on this request
                step = self.store.tree.next_task() if self.active_goal and self.store.tree else None
                work.append(f"your planner's job on this request, in his words, "
                            f"{'running' if self.active_goal else 'queued'}: {ho['goal']}"
                            + (f"; step now: {_task_label(step)}" if step else ""))
            else:
                work.append(f"a goal {'running' if self.active_goal else 'queued'}: "
                            f"{self.active_goal or self.pending_goal}")
        elif handed:
            work.append("a long job handed on in this run")
        if t.get("ran"):
            work.append("this turn's calls: " + ", ".join(t["ran"]))
        return {"heard_by": "in sight: " + ", ".join(names) if names else "nobody in sight", who: asker,
                "his_request": {"words": ask[1], "open": True,
                                "working_on_it": "; ".join(work) or "nothing: no job and no step under way"}}

    def _open_ask_block(self, ask: tuple, state: dict) -> dict:
        """The open ask as data, from fresh state against the state read when it was asked (facts, no advice)."""
        seen = self._ask_seen.get(ask)
        if seen is None or not oa.readable(state):
            changed = "unknown: no state read from when it was asked" if seen is None else "unknown: no state read now"
        else:
            try:
                cat = item_stats.catalog()
            except Exception:  # names fall back to the body's own and the id
                cat = {}
            changed = oa.changes(seen[1], state, cat)
        tree = self._job_view(state, where="open_ask") if oa.same_ask(ask, self._open_request) else None
        if tree:  # DW_JOB_TREE=1: the tree in the facts' place
            blk = oa.block(ask[0], ask[1], round(self.clock() - seen[0]) if seen else None, changed)
            blk["open_request"]["job_tree"] = tree
        else:
            blk = oa.block(ask[0], ask[1], round(self.clock() - seen[0]) if seen else None, changed,
                           known=self._request_facts(where="open_ask") if oa.same_ask(ask, self._open_request)
                           else None)
        if self._ask_owner_on():
            done = self._done_by_plan(ask, state)
            if done is not None and not self._last_done.get("told"):  # told once: his planner's job for it finished
                self._last_done["told"] = True
                blk["open_request"]["your_planners_job"] = {
                    "goal": self._last_done["goal"], "ended": "done: its plan ran to its end",
                    "steps": self._last_done["steps"]}
            if self._handover_bar(ask, standing=True) is None and not (done and done["blocked"]):
                blk["open_request"]["if_you_stop"] = HANDOVER_IF_YOU_STOP  # what a stop now leads to (DW_ASK_OWNER=1)
        return blk

    def _close_ask(self, call, extra: list[str]) -> dict:
        """request_done / park_request: the open ask ends here. The claim or the reason is recorded, never judged; a
        park reason is said (the player hears it, as the tool says)."""
        ask, self._open_request = self._open_request, None
        if call.name == oa.PARK:
            self._park(ask, (call.arguments or {}).get(oa.ARG[oa.PARK]))
        else:
            self._parked = None
            if self.jobs is not None:
                self.jobs.close()
        self._drop_ask_facts(call.name)
        self._save_ask()  # done: the file goes; parked: kept as parked, with the reason
        words = str((call.arguments or {}).get(oa.ARG[call.name]) or "").strip() or None
        who, what = ask or (None, None)
        if call.name == oa.PARK:
            self.log.log("request_parked", request=what, player=who, reason=words)
            if words:
                extra.append(words)
        else:
            self.log.log("request_done_claimed", request=what, player=who, evidence=words)
        return {"ok": True, "note": "request parked" if call.name == oa.PARK else "request closed as finished"}

    # ------------------------------------------------ the goal machinery owns the ask (DW_ASK_OWNER=1, _take_up_ask)

    def _ask_owner_on(self) -> bool:
        """DW_ASK_OWNER=1 and no Director attached (the board owns its own steps)."""
        return self.ask_owner and self.director is None

    @staticmethod
    def _per_ask(table: dict, ask: tuple | None) -> int:
        return sum(n for k, n in table.items() if oa.same_ask(k, ask))

    def _note_his_stop(self, run_asked: tuple | None, ran_all: list[str]) -> None:
        """His own stop while the ask is open stands: no hand-over of it until a later call of his on it (or a new
        line, which is a new ask)."""
        ask = self._open_request
        if not ask:
            return
        if "stop" in ran_all:
            self._stopped_ask = ask
            self.log.log("ask_stopped_by_him", request=ask[1], player=ask[0])
        elif self._stopped_ask and oa.same_ask(run_asked, ask) and set(ran_all) - STANDING:
            self._stopped_ask = None  # he took it up again himself

    def _newer_line(self, ask: tuple, since: float | None) -> bool:
        """A player line newer than the ask: the asker's last line is other words, or anyone spoke after ``since``."""
        last = next((v for k, v in self._last_line.items() if sit.same_player(k, ask[0])), None) if ask[0] else None
        if last is not None and last[0] != ask[1]:
            return True
        return since is not None and any(t > since for _, t in self._last_line.values())

    def _handover_bar(self, ask: tuple, since: float | None = None, standing: bool = False) -> str | None:
        """Why the ask can not go to his Planner now, or None. ``standing``: only what holds whatever runs next (his
        stop, the budget, the cap, the stall rule): the open-ask block's if_you_stop is shown only when none does."""
        if not standing:
            if not oa.same_ask(self._open_request, ask):
                if self._newer_line(ask, since):
                    return "a newer player line"
                if self._parked and oa.same_ask(self._parked["ask"], ask):
                    return "parked by him"
                return "closed"
            if self._newer_line(ask, since):
                return "a newer player line"
        if self._stopped_ask and oa.same_ask(self._stopped_ask, ask):
            return "stopped by him"
        if not standing:
            if self.active_goal or self._planning is not None:
                return "a goal is running"
            if self.pending_goal:
                return "a goal is queued"
            if self._chat_waiting() or self._chat_stashed():
                return "a chat line waits"
        if self.budget is not None and not self.budget.allows("planner"):
            return "out of model budget"
        if (n := self._per_ask(self._ask_plan_calls, ask)) >= ASK_PLAN_CAP:
            return f"cap: {n} Planner calls on this request"
        if standing and self._stalled(ask):
            return "stall"
        return None

    def _stalled(self, ask: tuple) -> str | None:
        """THE ONE CODE-MADE BOUND of the hand-over (CLAUDE.md section 3 leaves stopping to him; this is flagged as the
        exception): the last two goals on this ask stuck at the same step for the same reason, and the bag, the gear
        and the quest log show nothing changed between the two. Another hand-over would only repeat it. Returns the
        reason (code's words), or None. Unknown state on either side is no stall."""
        last = self._last_stuck
        if not last or not oa.same_ask(last["ask"], ask) or not last.get("prev"):
            return None
        prev = last["prev"]
        if (prev["failed"], prev["reason"]) != (last["failed"], last["reason"]):
            return None
        if not (oa.readable(prev["state"]) and oa.readable(last["state"])):
            return None
        try:
            cat = item_stats.catalog()
        except Exception:  # names fall back to the body's own and the id
            cat = {}
        ch = oa.changes(prev["state"], last["state"], cat)
        if any(v != "no change" for v in ch.values()):
            return None
        step = (f"{last['failed']['skill']} {json.dumps(last['failed']['args'], ensure_ascii=False)}"
                if last["failed"] else "planning")
        return (f"stopped by code after the same failure twice: {step} failed again ({last['reason']}), and nothing in "
                "the bag, the gear or the quest log changed since the try before")

    def _take_up_ask(self) -> None:
        """A run left the open ask with no job (request_left_open): unless something stands in the way, the ask's words
        go to his Planner verbatim as a goal, started by step() right after this. What stands in the way: the ask is
        no longer the open one or the player's newest line; he parked, closed or stopped it; a goal is queued or
        running; a chat line waits; the budget; ASK_PLAN_CAP Planner calls on it; the stall rule (_stalled, which
        parks it). One decision per left-open run, logged either way."""
        u, self._unowned = self._unowned, None
        if u is None or not self._ask_owner_on():
            return
        ask, run_for, why_unowned, since = u
        why = self._handover_bar(ask, since)
        if why is None and (stall := self._stalled(ask)):
            why = "stall"
            self.log.log("ask_handover_skipped", request=ask[1], player=ask[0], why=why, reason=stall)
            self._park_for(ask, stall, by="code")
            return
        if why is not None:
            self.log.log("ask_handover_skipped", request=ask[1], player=ask[0], why=why)
            return
        done = self._done_by_plan(ask, self._fresh_state()) if self._last_done else None
        if done is not None and done["blocked"]:
            self.log.log("ask_handover_skipped", request=ask[1], player=ask[0], why="done_by_plan",
                         goal=self._last_done["goal"], root_not_done=done["root_not_done"], changed=done["changed"])
            return
        last = self._last_stuck
        cont = last if (last and oa.same_ask(last["ask"], ask) and last.get("failed_i") is not None) else None
        if done is not None:  # its plan ran to its end, the game says the job is not: the next plan goes on from it
            cont, self._last_done = (self._last_done if self._last_done.get("failed_i") is not None else None), None
        self._handovers[ask] = self._handovers.get(ask, 0) + 1
        self.pending_goal, self.pending_tasks, self.pending_skill, self.pending_first = ask[1], None, None, None
        self._pending_asked = self._asked_of(ask)
        self._handover_next = {"ask": ask, "goal": ask[1], "n": self._per_ask(self._handovers, ask),
                               "continue": cont, "his_calls": 0}
        said = next((s.text for s in reversed(getattr(getattr(self.controller, "voice", None), "history", None) or [])
                     if s.kind != "system"), None)
        self.log.log("ask_handover", request=ask[1], player=ask[0], run_for=run_for, why_unowned=why_unowned,
                     n=self._handover_next["n"], plan_calls=self._per_ask(self._ask_plan_calls, ask),
                     mode="replan" if cont else "plan",
                     prior={"goal": cont["goal"], "failed": cont["failed"], "reason": cont["reason"]} if cont else None,
                     question_pending=bool(said and said.rstrip().endswith("?")))  # (logged only, never decides)

    def _park_for(self, ask: tuple, reason: str, by: str, **extra) -> None:
        """The ask parked for him (by his planner, or by the stall rule): kept as parked with its facts, so his own
        later call on one of its items or the player's next line opens it again, and told to him as a situation (he
        decides what to say; code never speaks for him unless the model call fails: broker.fallback_line)."""
        if oa.same_ask(self._open_request, ask):
            self._open_request = None
        self._park(ask, reason)
        self._drop_ask_facts(f"parked by {by}")
        self._save_ask()
        self.log.log("request_parked", request=ask[1], player=ask[0], reason=reason, by=by)
        what = {"planner": "your planner took this request as a job and did not plan steps for it",
                "code": "your planner's jobs on this request stopped twice the same way with nothing changed"}[by]
        self._situations.append({"type": ASK_PARKED, "by": by, "request": ask[1], "from": ask[0], "reason": reason,
                                 **{k: v for k, v in extra.items() if v}, "about": f"{what}; the request is parked"})
        self.flush_situations()

    def _handover_park(self, goal: str, ho: dict, plan, task: Task | None) -> GoalResult:
        """A hand-over goal's plan with no steps: only a question for the player (parked, waiting on him), or a decline
        with its explanation (parked with it). The job ends; nothing here re-plans."""
        tree = self.store.tree
        if tree is not None:
            tree.status = "stuck"
            self.store.save_tree()
        ask = ho["ask"]
        if plan.ask_help:
            reason = f"planner waits on the player: {plan.ask_help.strip()}"
        else:
            reason = f"planner: {(plan.explanation or '').strip()}"
            self.log.log("planner_declined", request=ask[1], player=ask[0], goal=goal,
                         explanation=plan.explanation, failed=task.skill if task else None)
        self.store.progress("goal parked", goal=goal, by="planner", reason=reason)
        self._park_for(ask, reason, by="planner", question=plan.ask_help,
                       explanation=None if plan.ask_help else plan.explanation)
        return "stuck"

    def _count_plan(self, ho: dict | None, kind: str, goal: str, log_start: bool) -> None:
        """A Planner call of a hand-over goal counts against its ask (ASK_PLAN_CAP). log_start: the in-line call has
        no plan_started row of its own (the background one logs it, from_ask=true, in _submit_plan)."""
        if ho is None:
            return
        self._ask_plan_calls[ho["ask"]] = self._ask_plan_calls.get(ho["ask"], 0) + 1
        if log_start:
            self.log.log("plan_started", composer="planner", plan_kind=kind, goal=goal, request=ho["ask"][1],
                         from_ask=True)

    def _note_done(self, goal: str, tree) -> None:
        """A hand-over goal's plan ran to its end: kept, so the same ask is not handed over again unless the game says
        its job is not done and something changed since (_done_by_plan); a later hand-over replans from this tree."""
        ho = self._handover
        if ho is None or not oa.same_ask(ho["ask"], self._open_request) or tree is None:
            return
        idx = max((i for i, t in enumerate(tree.tasks) if t.done), default=None)
        try:
            state = ask_store.baseline(self.executor.state(max_age=POST_ACTION_REUSE_S))
        except Exception:  # unknown state: nothing reads as changed later
            state = None
        last = tree.tasks[idx] if idx is not None else None
        self._last_done = {"ask": self._open_request, "goal": goal, "tree": copy.deepcopy(tree), "failed_i": idx,
                           "failed": {"skill": last.skill, "args": dict(last.args or {})} if last else None,
                           "reason": "the plan ran to its end, and the game does not read the request as done",
                           "state": state, "steps": len(tree.tasks), "told": False}

    def _done_by_plan(self, ask: tuple, state: dict | None) -> dict | None:
        """After a hand-over goal on this ask ended done: {blocked, root_not_done, changed}; None when there was none.
        Not blocked only when (a) the job tree's root reads not done from the game state (DW_JOB_TREE keeper, when
        it has a tree for the ask) and (b) the bag, gear or quest log changed since that goal ended."""
        d = self._last_done
        if not d or not oa.same_ask(d["ask"], ask):
            return None
        root_not_done = None
        if self.jobs is not None and self.jobs.active(ask) and oa.readable(state):
            try:
                tree = self.jobs.tree(state)
            except Exception:  # no tree: the job tree says nothing
                tree = None
            roots = (tree or {}).get("roots") or []
            if roots:
                root_not_done = any(r.get("status") != "done" for r in roots)
        changed = False
        if oa.readable(d["state"]) and oa.readable(state):
            try:
                cat = item_stats.catalog()
            except Exception:
                cat = {}
            changed = any(v != "no change" for v in oa.changes(d["state"], state, cat).values())
        return {"blocked": not (changed and root_not_done is not False), "root_not_done": root_not_done,
                "changed": changed}

    def _note_stuck(self, goal: str, task: Task | None, reason: str | None) -> None:
        """The goal on the open ask got stuck: kept for a hand-over that goes on from it (its tree, the failed step and
        the reason go to planner.replan) and for the stall rule (the state read beside it)."""
        a = self._goal_asked
        ask = (a.get("player"), a["request"]) if isinstance(a, dict) and a.get("request") else None
        if not (ask and oa.same_ask(ask, self._open_request)):
            return
        tree = self.store.tree
        idx = next((i for i, t in enumerate(tree.tasks) if t is task), None) if tree is not None and task else None
        try:
            state = ask_store.baseline(self.executor.state(max_age=POST_ACTION_REUSE_S))
        except Exception:  # unknown state: never a stall
            state = None
        if self._last_done and oa.same_ask(self._last_done["ask"], ask):
            self._last_done = None  # a stuck goal on it since: the newer end is the one gone on from
        prev = self._last_stuck if self._last_stuck and oa.same_ask(self._last_stuck["ask"], ask) else None
        failed = {"skill": task.skill, "args": dict(task.args or {})} if task else None
        self._last_stuck = {"ask": self._open_request, "goal": goal,
                            "tree": copy.deepcopy(tree) if tree is not None and idx is not None else None,
                            "failed_i": idx, "failed": failed, "reason": reason, "state": state,
                            "prev": {"failed": prev["failed"], "reason": prev["reason"], "state": prev["state"]}
                            if prev else None}

    # ---------------------------------------------------------------- the open ask on disk (brain/ask_store.py)

    def _ask_record(self) -> dict | None:
        """The kept ask as written: his words, who, when, open or parked (and why), its facts, the last calls for it
        and the call running now; None when no ask is kept. Times as unix seconds (monotonic does not survive)."""
        if self._open_request:
            ask, state, reason, names = self._open_request, "open", None, []
            facts = self._ask_facts if oa.same_ask(self._ask_facts_for, ask) else []
        elif self._parked:
            p = self._parked
            ask, state, reason = p["ask"], "parked", p.get("reason")
            names, facts = p.get("names") or [], p.get("facts") or []
        else:
            return None
        now_m, now_w = self.clock(), self.wall()

        def wall(t):
            return None if not isinstance(t, (int, float)) else round(now_w - (now_m - t))
        seen = self._ask_seen.get(ask)
        steps = self._ask_steps if oa.same_ask(self._ask_steps_for, ask) else []
        return {"player": ask[0], "words": ask[1], "state": state, "park_reason": reason, "names": list(names),
                "asked_unix": wall(seen[0]) if seen else None,
                "baseline": ask_store.baseline(seen[1]) if seen else None,
                "goal": self.active_goal if self.active_goal and oa.same_ask(self._serving_ask, ask) else None,
                "facts": [{"key": f.get("key"), "source": f.get("source"), "text": f.get("text"), "raw": f.get("raw"),
                           "t_unix": wall(f.get("t"))} for f in facts],
                "steps": list(steps)[-ask_store.STEPS_KEPT:], "in_flight": self._ask_in_flight}

    def _save_ask(self) -> None:
        """Write the kept ask to the world store when it changed; remove it when none is kept (done, or never one)."""
        if self.ask_dir is None:
            return
        try:
            rec = self._ask_record()
            if rec is None:
                if self._ask_on_disk and ask_store.clear(self.ask_dir):
                    self.log.log("ask_cleared", path=str(ask_store.path(self.ask_dir)))
                self._ask_on_disk, self._ask_written = False, None
                return
            if rec == self._ask_written:
                return
            ask_store.save(self.ask_dir, {**rec, "saved_unix": round(self.wall(), 1)})
            self._ask_written, self._ask_on_disk = rec, True
        except (OSError, TypeError, ValueError) as exc:  # memory is best effort: the ask stays in memory
            self.log.log("ask_save_error", error=repr(exc)[:200])

    def _ask_call_started(self, task: Task) -> None:
        if self.ask_dir is None or not (self._open_request or self._parked):
            return
        self._ask_in_flight = {"tool": task.skill, "args": dict(task.args or {}), "t_unix": round(self.wall(), 1),
                               "for_request": oa.same_ask(self._serving_ask, self._open_request)}
        self._save_ask()

    def _ask_call_ended(self, task: Task, outcome: Outcome) -> None:
        if self.jobs is not None and not outcome.ok and self.jobs.active(self._open_request):
            data = outcome.data if isinstance(outcome.data, dict) else {}
            try:  # a failure kept on the job tree's nodes it is about (job_tree.nodes_for)
                self.jobs.record(task.skill, dict(task.args or {}), outcome.ok, outcome.reason,
                                 str(data.get("detail") or data.get("why") or "") or None)
            except Exception as exc:  # bookkeeping is best effort
                self.log.log("job_tree_error", where="record", error=repr(exc)[:200])
        fl, self._ask_in_flight = self._ask_in_flight, None
        if fl is None:
            return
        if fl.get("for_request") and self._open_request:
            if not oa.same_ask(self._ask_steps_for, self._open_request):
                self._ask_steps = []
            self._ask_steps_for = self._open_request
            data = outcome.data if isinstance(outcome.data, dict) else {}
            detail = data.get("detail") or data.get("why")
            self._ask_steps = [*self._ask_steps, {
                "tool": task.skill, "args": dict(task.args or {}), "ok": outcome.ok, "reason": outcome.reason,
                "detail": str(detail)[:ASK_STEP_DETAIL_CHARS] if detail else None,
                "t_unix": round(self.wall(), 1)}][-ask_store.STEPS_KEPT:]
        self._save_ask()

    def attach_ask_store(self, directory: Path, state: dict | None = None,
                         containers: dict | None = None) -> dict | None:
        """Keep the open ask in ``directory`` (the world's state folder) from now on, and bring back the one a brain
        before this one kept there: open or parked as it was, with its facts, steps and the baseline its open-ask turn
        compares against. The first run then decides on a ``brain_restarted`` situation (ask_store.where_you_were): the
        ask, how long ago, what the game shows now, and a call that was running when the old brain stopped, said as
        unknown. Returns that situation, or None when nothing was kept."""
        self.ask_dir = Path(directory)
        if self.jobs is not None:
            self.jobs.dir = self.ask_dir
        rec = ask_store.load(self.ask_dir)
        if rec is None:
            self._ask_on_disk = ask_store.path(self.ask_dir).exists()  # unreadable: the next save replaces it
            return None
        now_m, now_w = self.clock(), self.wall()

        def mono(tu):
            return None if not isinstance(tu, (int, float)) else now_m - max(0.0, now_w - tu)
        ask = (rec.get("player"), str(rec["words"]))
        facts = [{"key": f.get("key"), "source": f.get("source"), "text": f["text"], "raw": f.get("raw"),
                  "t": mono(f.get("t_unix"))} for f in rec.get("facts") or [] if isinstance(f, dict) and f.get("text")]
        if self.jobs is not None and not self.jobs.attach(self.ask_dir, ask):
            self.jobs.open(ask)  # no tree kept for it: its target again from his words
        if rec["state"] == "open":
            self._open_request, self._parked = ask, None
            self._ask_facts, self._ask_facts_for = facts, ask if facts else None
        else:
            self._parked = {"ask": ask, "facts": facts, "names": list(rec.get("names") or []),
                            "reason": rec.get("park_reason")}
        base = rec.get("baseline")
        if isinstance(base, dict) and "inventory" in base:
            t = mono(rec.get("asked_unix"))
            self._ask_seen[ask] = (now_m if t is None else t, base)
        self._ask_steps = [s for s in rec.get("steps") or [] if isinstance(s, dict)][-ask_store.STEPS_KEPT:]
        self._ask_steps_for = ask
        self._ask_on_disk, self._ask_written = True, None  # the next save writes it afresh (the lost call said once)
        if state is None:
            state = self._fresh_state()
        try:
            cat = item_stats.catalog()
        except Exception:  # names fall back to the body's own and the id
            cat = {}
        event = ask_store.where_you_were(rec, now_w, state, containers, cat)
        self._situations.append(event)
        w = event["where_you_were"]
        self.log.log("ask_restored", request=ask[1], player=ask[0], state=rec["state"],
                     asked_s_ago=w["open_request"].get("asked_s_ago"), saved_s_ago=w.get("record_saved_s_ago"),
                     lost_call=(rec.get("in_flight") or {}).get("tool"), facts=len(facts),
                     steps=len(self._ask_steps), containers=len(w["game_now"].get("containers_seen") or []),
                     carried_read=not str(w["game_now"].get("carried")).startswith("unknown"))
        return event

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
        plan = self._plan_news()
        if not acts:
            return plan
        self._stash = [e for e in self._stash if not isinstance(e, Activity)]
        for ev in acts:
            self.handle_event(ev)
        return [self.broker.describe_activity(ev) for ev in acts] + plan

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
        self._pending_asked = self._asked
        self.pending_tasks, self.pending_skill, self.pending_first = tasks, rec.name, None
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
        if self._ask_owner_on():
            self._note_stuck(goal, task, reason)
        self._situations.append({"type": "stuck", "goal": goal, "failed": task.skill if task else None,
                                 "reason": reason, "question": question,
                                 **({"result": task.detail} if task and task.detail else {}),  # what the step said
                                 **self._goal_request(exclude=task.detail if task else None, where="stuck")})
        self.flush_situations()
        return "stuck"

    def _plan_question(self, goal: str, question: str, tasks: list[Task]) -> None:
        """A plan that comes with steps AND a question for the player: the steps run, and the question is said once
        beside them; his answer, when it comes, is a line like any other (it takes over the job if he acts on it).
        Park study 2026-11-18 (window l2_facts_1118i, runs 051943, 053839, 054931): every ask_help ended the job, even
        one that came with steps; the stuck event handed the Controller the question to relay, he asked and parked,
        and with the player away the copper job was dead 3 of 3 (0 of 25 replayed samples went on). A plan with no
        steps and only a question still stops (_stuck). Body run beside the job: no request of its own (run_asked)."""
        q = (question or "").strip()
        if not q or self._quiet_goal or q.lower() in self._plan_asked:
            return
        self._plan_asked.add(q.lower())
        self.log.log("plan_question", goal=goal, question=q, tasks=[t.skill for t in tasks])
        self._situations.append({"type": "plan_question", "goal": goal, "question": q,
                                 "steps": [_task_label(t) for t in tasks][:8],
                                 "about": "your job's plan has this question for the player; its steps are running "
                                          "now and go on meanwhile; his answer, when it comes, is his next line"})
        self.flush_situations()

    @staticmethod
    def _replaces_job(d, event) -> bool:
        """Does this decision end the job now running? A player's words do (what he asks for now takes over), and so
        does a stop, a follow or a new job of his own. What he does about a body event beside the job (a drink, a
        fight) only holds it up: _run_goal goes on from its next step when that run is over. Live 20261116-182213:
        thirsty after step 3 of 6 he fetched and boiled water and ate, the job ended as "interrupted" with craft,
        craft and talk left, nothing said it had, and he stood with the quest open until the trial ran out."""
        return bool(event.text) or bool(d.goal or d.skill) or any(a.name in STANDING for a in d.actions)

    def _goal_request(self, exclude: str | None = None, where: str | None = None) -> dict:
        """The player's own words the running goal came from, for the run that hears how the goal ended. The goal is
        the model's wording of them and may cover less: fresh chain 20261116-065203, "go and see Zanik and do her
        quest" became the goal "chop 50 Ash Logs ... bring them to Zanik"; that goal ended 290 s after the line (the
        rolling chat keeps 240 s), so the run that heard goal_done knew only the goal, and he stopped with the
        quest's next part open (583 s standing).
        With them, what the game told him about that ask while he worked on it (request_facts; ``exclude``: the
        step result shown beside them, not repeated)."""
        a = self._goal_asked
        if not (isinstance(a, dict) and a.get("request")):
            return {}
        # the words alone: replayed on that turn 10 times each, he stopped or went looking for a bed 9/10 without
        # them, went on with the quest 10/10 with them, and stopped 6/10 with a note beside them saying what a
        # goal's end means
        out = {"request": a["request"], "from": a.get("player"), "asked_at": a}
        if oa.same_ask((a.get("player"), a["request"]), self._open_request) and (
                facts := self._request_facts(exclude=exclude, where=where)):
            out["request_facts"] = facts
        return out

    def _planner_notes(self, goal: str | None = None, state: dict | None = None, exclude: str | None = None,
                       where: str | None = None) -> dict:
        notes = dict(self.store.prompt_notes())
        # the ask this goal serves and what the game told him about it (a replan sees the failed step's own words)
        a = self._goal_asked
        if isinstance(a, dict) and a.get("request") and oa.same_ask((a.get("player"), a["request"]),
                                                                   self._open_request):
            tree = None
            if self.jobs is not None and self.jobs.active(self._open_request):
                tree = self.jobs.full_view(state, where=where)  # DW_JOB_TREE=1: the whole tree, in the facts' place
            if tree:
                notes["open_request"] = {"player": a.get("player"), "words": a["request"], "job_tree": tree}
            elif facts := self._request_facts(exclude=exclude, where=where):
                notes["open_request"] = {"player": a.get("player"), "words": a["request"], "known_facts": facts}
        # the Planner cannot look a recipe up: what the recipe of a thing the goal or a quest step names takes
        if isinstance(state, dict) and (rows := needs.named_recipes(state, [goal, *sit.quest_texts(state)])):
            notes["recipes"] = rows
        for name, rec in self.store.places().items():
            if isinstance(rec, dict) and rec.get("position"):
                notes[f"place:{name}"] = f"go_to target [x, y, z] = {rec['position']}" + (
                    f" ({rec['note']})" if rec.get("note") else "")
        return notes

    # ------------------------------------------------ the Planner in the background (DW_ASYNC_PLAN=1, plan_async.py)

    def _plan_async_now(self) -> bool:
        return self.async_plan and not self._quiet_goal

    def _serve_planner_reads(self, where: str) -> None:
        """Body reads the background Planner's research queued (tool_registry.BodyProxy), answered on this thread,
        the bridge's one owner. Pump serves them too; under DW_ASYNC_PLAN so do his turn and every body wait."""
        proxy = getattr(self, "planner_proxy", None)
        if proxy is not None:
            proxy.serve(where)

    def loop_holder(self) -> str:
        """What this (the loop) thread is doing, for a background read it has not reached (BodyProxy.holder). Read
        from the worker: plain attribute reads, a description and never a decision."""
        since = getattr(self.controller, "model_since", None)
        if since is not None:
            return f"your Controller's model call, {max(0.0, time.monotonic() - since):.1f} s so far"
        inflight = getattr(self.game, "_inflight", None)  # BridgeClient: request ids awaiting their result
        if inflight:
            return f"waiting on {len(inflight)} body call(s)"
        return "the brain's own work between turns, no model or body call in flight"

    @staticmethod
    def _snapshot(*objs):
        """A private copy of the Planner's inputs for the worker (DW_ASYNC_PLAN): the loop keeps the originals and
        may change them (the executor's cached state, the task tree) while the plan is made. One deepcopy for all,
        so a task in the tree stays that same task (the replan's ``t is not failed``)."""
        return copy.deepcopy(objs)

    def _plan_fact(self) -> dict | None:
        """The Controller's context "planner" entry: a plan being made now, or one that landed since his last turn
        (told once). None when there is neither (the key is then left out)."""
        p = self._planning
        if p is not None and not p.done():
            return {"state": "making the plan" if p.kind == "plan" else "revising the plan after a failed step",
                    "job": p.goal, "for_s": round(self.clock() - p.started, 1)}
        landed, self._plan_landed = self._plan_landed, None
        return landed

    def _plan_news(self) -> list[str]:
        """A plan that landed while his chain runs: told on his next turn (steering at a model boundary, never by
        stopping a tool). It starts when the chain ends, unless the game has moved past it by then."""
        p = self._planning
        if p is None or p.shown or not p.done() or p.future.exception() is not None:
            return []
        plan = p.future.result()
        # beside his own first steps a plan step their effect made true is marked done at the splice, not stale
        why = plan_async.stale_reasons(p.basis, self._fresh_state(reuse=True),
                                       [] if p is self._steps_plan else plan.tasks, p.died)
        p.shown = "stale" if why else "fresh"
        steps = "; ".join(plan_async.step_label(t) for t in plan.tasks[:8]) or "none"
        head = f"Your planner's {'revised ' if p.kind == 'replan' else ''}plan for {p.goal!r} has arrived"
        if why:
            return [f"{head}, but the game moved past the state it was made on ({'; '.join(why)}). It will not start "
                    f"by itself. Its steps: {steps}."]
        return [f"{head} ({len(plan.tasks)} steps: {steps}). It starts by itself when you end this turn."]

    def _plan_in_background(self, kind: str, goal: str, state: dict, ask, failed: dict | None = None):
        """The Planner call on the worker; the loop keeps pumping, so the Controller hears body events and chat and
        gets one turn told that the plan is being made. Returns the plan to run, None when the job was replaced
        meanwhile or the plan arrived stale (then shown to him as a situation), or raises PlanError as ask() does."""
        p = self._submit_plan(kind, goal, state, ask, failed)
        return self._land_plan(p, self._await_plan(p, failed))

    def _submit_plan(self, kind: str, goal: str, state: dict, ask, failed: dict | None = None):
        """The Planner call submitted to the worker and held as the one in flight (self._planning)."""
        # the basis is a copy: the executor's cached state object may be read again (and changed) while this runs
        p = plan_async.PendingPlan(kind=kind, goal=goal, basis=copy.deepcopy(state), started=self.clock())
        plan_async.submit(p, ask, self.log, self.log.episode_id)
        self._planning = p
        p.req = self._goal_request()
        self.log.log("plan_started", composer="planner", plan_kind=kind, goal=goal, request=p.req.get("request"),
                     basis=plan_async.digest(state), failed_step=failed,
                     **({"from_ask": True} if self._handover is not None else {}))
        return p

    def _await_plan(self, p, failed: dict | None = None, extra: dict | None = None) -> int:
        """Wait for the plan with his turns: one plan_pending turn, then a turn while the body stands idle. Returns
        the idle turns he was given."""
        kind, goal, req = p.kind, p.goal, p.req
        idle_turns = 0  # the turns he was given because the body stood idle while it was made (plan_idle_turn)
        try:
            ev = {"type": "plan_pending", "goal": goal, "about": REPLAN_PENDING_NOTE if failed else PLAN_PENDING_NOTE,
                  **({"failed_step": failed} if failed else {}), **(extra or {}), **req}
            self._plan_turn(ev)
            seen, offered = len(p.acts), self.clock()
            quiet = 0 if seen else 1  # his turns in a row with no body act while it is made
            while not p.done() and not self._cancelled:
                self.pump()
                flush = getattr(self, "flush_chat", None)
                if callable(flush):  # LiveAgent: a burst of unnamed lines
                    flush()
                if len(p.acts) != seen:  # a run pump woke (chat, a body situation) acted
                    seen, quiet = len(p.acts), 0
                idle = self._idle_while_planning(p, offered)
                if idle is not None and quiet < PLAN_QUIET_TURNS:
                    self.log.log("plan_idle_turn", plan_kind=kind, goal=goal, idle_s=idle, quiet=quiet,
                                 for_s=round(self.clock() - p.started, 1))
                    self._plan_turn({**ev, "idle_s": idle})
                    offered, idle_turns = self.clock(), idle_turns + 1
                    if len(p.acts) != seen:
                        seen, quiet = len(p.acts), 0
                    else:
                        quiet += 1
                    continue
                if not self._cancelled:
                    try:
                        p.future.exception(timeout=PLAN_POLL_S)
                    except cf.TimeoutError:
                        pass
        finally:
            self._planning = None
        return idle_turns

    def _land_plan(self, p, idle_turns: int = 0, his_steps: bool = False):
        """The plan as it lands: the plan to run, None when the job was replaced or the plan is stale (shown to him
        as a situation), or raises PlanError. his_steps: his own first steps ran meanwhile (start_goal first_steps),
        so a plan step their effect made true is no reason to call the plan stale (the splice marks it done)."""
        self._planning = None
        kind, goal, req = p.kind, p.goal, p.req
        acts = p.acts_while_composed()
        self.log.log("acted_while_planning", n=len(acts), tools=acts, n_before_start=len(p.acts), plan_kind=kind,
                     goal=goal, idle_turns=idle_turns, **({"first_steps": True} if his_steps else {}))
        age = round(self.clock() - p.started, 2)
        composed = round(p.composed_wall - p.started_wall, 2) if p.composed_wall is not None else None
        if self._cancelled and not p.done():
            self.log.log("plan_abandoned", plan_kind=kind, goal=goal, age_s=age, why="the job was replaced")
            return None
        exc = p.future.exception()
        if exc is not None:
            self.log.log("plan_arrived", plan_kind=kind, goal=goal, age_s=age, composed_s=composed, stale=None,
                         ok=False, error=repr(exc), applied=False)
            raise exc
        plan = p.future.result()
        if self._cancelled:
            self.log.log("plan_arrived", plan_kind=kind, goal=goal, age_s=age, composed_s=composed, stale=None,
                         ok=True, steps=len(plan.tasks), applied=False, why=["the job was replaced"])
            return None
        now = self.executor.state()
        why = plan_async.stale_reasons(p.basis, now, [] if his_steps else plan.tasks, p.died)
        if p.shown == "stale" and not why:  # he was told it will not start by itself: it does not
            why = ["it was shown to you as stale"]
        moved = plan_async.drift(p.basis, now)
        steps = [plan_async.step_label(t) for t in plan.tasks]
        self.log.log("plan_arrived", plan_kind=kind, goal=goal, age_s=age, composed_s=composed, stale=bool(why),
                     why=why, drift=moved, ok=True, steps=len(plan.tasks), first_step=steps[0] if steps else None,
                     applied=not why, shown=p.shown)
        if why:
            self._situations.append({"type": "plan_arrived", "stale": True, "goal": goal, "why": why, "steps": steps,
                                     "since_it_was_asked_for": moved, "about": PLAN_STALE_NOTE, **req})
            return None
        if his_steps:  # the plan steps his own steps' effects made true, read from the game (never his claim)
            p.marked = plan_async.already_done(plan.tasks, p.basis, now)
        if p.shown is None:  # he has not heard it landed: his next turn is told (context "planner")
            self._plan_landed = {"state": "plan arrived and running" if plan.tasks else "plan arrived",
                                 "job": goal, "after_s": composed, "steps": steps[:8],
                                 **({"since_it_was_asked_for": moved} if moved else {})}
        return plan

    def _splice_plan(self, p, tree, started: set, idle_turns: int = 0) -> tuple:
        """A plan landed while his own first steps ran (start_goal first_steps): at this step boundary it replaces
        only the steps not yet started; a step already started is kept, and a plan step the game shows done is
        marked done. Returns ("spliced" | "stale" (shown to him; his steps run on) | "none" (no steps), plan)."""
        plan = self._land_plan(p, idle_turns, his_steps=True)
        if plan is None:
            return "stale", None
        if not plan.tasks:
            return "none", plan
        marked = dict(p.marked)
        for i, t in enumerate(plan.tasks):
            if i in marked:
                t.status, t.detail = "done", f"already true in the game when the plan landed: {marked[i]}"
        # started: a step sent to the body (an interrupted one is pending again, and is resumed, not replaced)
        kept = [t for t in tree.tasks if t.status != "pending" or t.id in started]
        replaced = [t for t in tree.tasks if t not in kept]
        tree.tasks = kept + plan.tasks
        self.store.save_tree()
        self.log.log("plan_spliced", goal=p.goal, kept=[plan_async.step_label(t) for t in kept],
                     replaced=[plan_async.step_label(t) for t in replaced],
                     marked_done=[plan_async.step_label(plan.tasks[i]) for i in sorted(marked)],
                     running=[plan_async.step_label(t) for t in kept if t.status in ("pending", "running")],
                     steps=len(plan.tasks))
        self.store.progress("plan spliced", goal=p.goal, kept=len(kept), replaced=len(replaced),
                            marked_done=len(marked))
        if plan.ask_help:
            self._plan_question(p.goal, plan.ask_help, plan.tasks)
        return "spliced", plan

    def _idle_while_planning(self, p, offered: float) -> float | None:
        """Seconds the body has stood idle since his last turn ended (or the last offer), once that is
        PLAN_IDLE_TURN_S, with the plan still pending; None while anything else holds or will take a turn. Facts
        only: what he does with the turn is his."""
        if p.done() or self._cancelled or self._situations or self._chat_waiting() or self._chat_stashed():
            return None
        ep = self.broker.episode
        if self.broker.running is not None or (ep is not None and ep.ended is None):
            return None  # an action of his left running, or a move (a follow) still going
        since = max(t for t in (self._turn_ended_at, offered, p.started) if t is not None)
        idle = self.clock() - since
        return round(idle, 1) if idle >= PLAN_IDLE_TURN_S else None

    def _plan_turn(self, ev: dict) -> None:
        """His turn while the plan is made, in the goal's own episode (its acts are the ask's). A player's line that
        waits takes the fact along instead (one run for both)."""
        if self._chat_waiting() or self._chat_stashed():
            self._situations.append(ev)
            return
        if self.budget is not None and not self.budget.allows("situation"):
            return
        player = (self._goal_asked or {}).get("player") if isinstance(self._goal_asked, dict) else None
        try:
            self._command(CommandReceived(player=player or self.controller.player, text=""), addressed=True,
                          body_events=[ev, *self.take_situations()])
        except Exception as exc:  # the model call failed: the plan is still on its way
            self.log.log("situation_error", error=repr(exc), events=[ev])

    def _drop_steps_plan(self) -> None:
        """The job ended (replaced, stuck) with the plan composed beside his first steps not applied: logged, let go."""
        p, self._steps_plan = self._steps_plan, None
        if p is None:
            return
        self._planning = None
        acts = p.acts_while_composed()
        self.log.log("acted_while_planning", n=len(acts), tools=acts, n_before_start=len(p.acts), plan_kind=p.kind,
                     goal=p.goal, idle_turns=0, first_steps=True)
        self.log.log("plan_abandoned", plan_kind=p.kind, goal=p.goal, age_s=round(self.clock() - p.started, 2),
                     why="the job was replaced" if self._cancelled else "the job ended before it was applied")

    def _plan_not_run(self, goal: str, tree) -> GoalResult:
        """The plan was not started: the job was replaced while it was made, or it arrived stale (shown to him)."""
        if tree is not None:
            tree.status = "interrupted"
            self.store.save_tree()
        self.store.progress("goal interrupted", goal=goal, why="plan not started")
        self.flush_situations()
        return "interrupted"

    def run_goal(self, goal: str, tasks: list[Task] | None = None, skill: str | None = None,
                 quiet: bool = False, first: list[Task] | None = None) -> GoalResult:
        """quiet=True (a run_skill inside a board run): no goal_done / stuck situations and no Planner replans;
        the result goes back to the board (docs/design/director.md section 12 item 7)."""
        self._quiet_goal = quiet
        self.active_goal, self._cancelled, self._last_reason = goal, False, None
        self.controller.job_started()
        start = time.monotonic()
        result: GoalResult = "stuck"
        serving = self._serving_ask
        try:
            result = self._run_goal(goal, tasks, first)
        except StateUnavailable:  # the planner needs fresh state too
            result = self._stuck(goal, None, Reason.STATE_UNAVAILABLE)
        finally:
            self._drop_steps_plan()
            self.active_goal = None
            self._quiet_goal = False
            self._serving_ask = serving
            ho, self._handover = self._handover, None
            if ho is not None:
                self.log.log("ask_handover_ended", request=ho["ask"][1], player=ho["ask"][0], n=ho["n"],
                             result=result, his_calls=ho["his_calls"],
                             plan_calls=self._per_ask(self._ask_plan_calls, ho["ask"]))
        elapsed = time.monotonic() - start
        if skill and self.skills and result != "interrupted":
            self.skills.record_run(skill, result == "done", elapsed, self._last_reason)
        elif result == "done" and not skill:
            self._learn(goal, elapsed)
        return result

    def _run_goal(self, goal: str, given: list[Task] | None = None, first: list[Task] | None = None) -> GoalResult:
        self.store.progress("goal started", goal=goal, from_skill=given is not None)
        # the request this goal came from, kept from the run that queued it. Window s18 (2026-11-17), run 054545: a
        # hunger run came between start_goal and the goal's start and, as a body-only run, cleared self._asked; the
        # goal's end came with no request, his line "next quest step is rune essence" with no call was not asked
        # about, and he stood 9.3 s (5 of the 32 goal ends of 15 to 17 Nov that followed a chat run's start_goal)
        asked, self._pending_asked = self._pending_asked or self._asked, None
        self._goal_asked = asked
        # its steps act on that ask while it is the open one: what the game tells them is kept with it (oa.keep_fact)
        mine = (asked.get("player"), asked["request"]) if isinstance(asked, dict) and asked.get("request") else None
        self._serving_ask = mine if oa.same_ask(mine, self._open_request) else None
        plan_q = None  # the plan's question beside its steps (_plan_question)
        plan_state = None  # the state the plan is made from (a held craft says what the bag gained since)
        # DW_ASK_OWNER=1: a hand-over goal (the ask's words, _take_up_ask) may be declined, counts its Planner calls
        # against the ask, and goes on from the last stuck goal on that ask (its tree, failed step and reason: a replan)
        ho = self._handover
        kw = {"may_decline": True} if ho is not None else {}
        cont = ho.get("continue") if ho is not None else None
        if given is None:
            try:
                state = plan_state = self.executor.state()
                notes = self._planner_notes(goal, state, where="plan")
                ask = lambda: self.planner.plan(goal, sit.with_asked(state, asked), notes, **kw)  # noqa: E731
                if cont is not None:  # the prior job's tree in the ask's words, its replan count reset
                    prior = copy.deepcopy(cont["tree"])
                    prior.goal, prior.replans, prior.status = goal, 0, "active"
                    reason = cont["reason"]
                    ask = lambda: self.planner.replan(prior, prior.tasks[cont["failed_i"]], reason,  # noqa: E731
                                                      sit.with_asked(state, asked), notes, **kw)
                self._count_plan(ho, "replan" if cont is not None else "plan", goal,
                                 log_start=not self._plan_async_now())
                if self._plan_async_now():
                    s_c, n_c = self._snapshot(sit.with_asked(state, asked), notes)
                    if first:  # his own first steps (start_goal first_steps) run now; the plan lands at a boundary
                        self._steps_plan = self._submit_plan("plan", goal, state,
                                                             lambda: self.planner.plan(goal, s_c, n_c))
                        self.log.log("first_steps_started", goal=goal, steps=[plan_async.step_label(t) for t in first])
                        plan = None
                    elif cont is not None:
                        self.store.tree = None
                        p_c, s_c, n_c = self._snapshot(prior, sit.with_asked(state, asked), notes)
                        f = p_c.tasks[cont["failed_i"]]
                        plan = self._plan_in_background(
                            "replan", goal, state, lambda: self.planner.replan(p_c, f, reason, s_c, n_c, **kw),
                            failed={"skill": f.skill, "args": f.args, "reason": reason})
                        if plan is None:
                            return self._plan_not_run(goal, None)
                    else:
                        self.store.tree = None  # in memory only: no earlier job's steps beside it while it is planned
                        plan = self._plan_in_background("plan", goal, state,
                                                        lambda: self.planner.plan(goal, s_c, n_c, **kw))
                        if plan is None:  # the job was replaced meanwhile, or the plan arrived stale (shown to him)
                            return self._plan_not_run(goal, None)
                else:
                    plan = ask()
            except PlanError as exc:
                return self._stuck(goal, None, str(exc))
            if plan is None:
                given = list(first)
            elif not plan.tasks:
                if ho is not None and (plan.ask_help or plan.declined):  # only a question, or a decline: parked
                    return self._handover_park(goal, ho, plan, None)
                return self._stuck(goal, None, "no plan", plan.ask_help)
            else:
                given, plan_q = plan.tasks, plan.ask_help
        tree = self.store.set_goal(goal, given)
        self._plan_bag(plan_state)
        self._plan_asked = set()
        if plan_q:
            self._plan_question(goal, plan_q, given)
        interrupts = 0
        failed_mine = None  # (task, reason): a first step of his that failed while the plan was made
        not_run = False  # the plan landed stale while his first steps ran: they run on, the job ends without it
        started: set[str] = set()  # ids of the steps sent to the body (the splice keeps them)

        while True:
            p = self._steps_plan  # at this step boundary: the plan composed beside his first steps, landed or awaited
            if p is not None and not self._cancelled and (p.done() or failed_mine or tree.next_task() is None):
                try:
                    extra = {"failed_step": {"skill": failed_mine[0].skill, "args": failed_mine[0].args,
                                             "reason": failed_mine[1]}} if failed_mine else None
                    idle = 0 if p.done() else self._await_plan(p, extra=extra)
                    if self._cancelled:
                        break
                    self._steps_plan = None
                    got, plan = self._splice_plan(p, tree, started, idle)
                except PlanError as exc:
                    self._steps_plan = None
                    return self._stuck(goal, failed_mine[0] if failed_mine else None, str(exc))
                if got == "none":
                    return self._stuck(goal, failed_mine[0] if failed_mine else None, "no plan", plan.ask_help)
                if got == "stale" and failed_mine:
                    return self._stuck(goal, failed_mine[0], failed_mine[1])
                not_run, failed_mine = got == "stale", None
            if (task := tree.next_task()) is None:
                break
            started.add(task.id)
            if self._steps_plan is not None:  # a first step of his sent while the Planner composes
                self._steps_plan.acted(task.skill)
            self.executor.queued = task.id  # a queued step: a craft is checked against the fresh bag first
            try:
                outcome = self._run_task(task)
            finally:
                self.executor.queued = None
            if outcome.interrupt:
                # a fight on him is bounded by the game, not by chat: it never makes the job "interrupted too often"
                interrupts += 0 if isinstance(outcome.data, dict) and outcome.data.get("by") in ("fight", "threat") else 1
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
            if self._steps_plan is not None:  # a first step of his failed while the plan is made: it lands next
                failed_mine = (task, outcome.reason)
                continue
            if tree.replans >= (0 if self._quiet_goal else self.max_replans):
                return self._stuck(goal, task, outcome.reason)
            tree.replans += 1
            try:
                state = self.executor.state()
                notes = self._planner_notes(goal, state, exclude=task.detail, where="replan")
                ask = lambda: self.planner.replan(tree, task, outcome.reason,  # noqa: E731
                                                  sit.with_asked(state, asked), notes, **kw)
                self._count_plan(ho, "replan", goal, log_start=not self._plan_async_now())
                if self._plan_async_now():
                    failed = {"skill": task.skill, "args": task.args, "reason": outcome.reason,
                              **({"result": task.detail[:GOAL_RESULT_CHARS]} if task.detail else {})}
                    tree_c, task_c, s_c, n_c = self._snapshot(tree, task, sit.with_asked(state, asked), notes)
                    reason = outcome.reason
                    new = self._plan_in_background(
                        "replan", goal, state, lambda: self.planner.replan(tree_c, task_c, reason, s_c, n_c, **kw),
                        failed=failed)
                    if new is None:
                        return self._plan_not_run(goal, tree)
                else:
                    new = ask()
            except PlanError as exc:
                return self._stuck(goal, task, str(exc))
            self._plan_bag(state)
            self.store.progress("replanned", goal=goal, explanation=new.explanation, ask_help=new.ask_help)
            if not new.tasks:  # only a question (or nothing): the job stops honestly with its reason and the question
                if ho is not None and (new.ask_help or new.declined):  # a hand-over goal: the ask is parked instead
                    return self._handover_park(goal, ho, new, task)
                return self._stuck(goal, task, outcome.reason, new.ask_help)
            tree.tasks = [t for t in tree.tasks if t.done or t is task] + new.tasks
            self.store.save_tree()
            if new.ask_help:  # steps AND a question: the steps run, the question is said beside them (_plan_question)
                self._plan_question(goal, new.ask_help, new.tasks)

        if self._cancelled:
            tree.status = "interrupted"
            self.store.save_tree()
            self.store.progress("goal interrupted", goal=goal)
            return "interrupted"
        if not_run:  # his first steps ended; the plan beside them arrived stale and was shown to him, not started
            return self._plan_not_run(goal, tree)
        tree.status = "done"
        self.store.save_tree()
        self.store.progress("goal done", goal=goal)
        if self._quiet_goal:
            return "done"
        if ho is not None:
            self._note_done(goal, tree)
        self._situations.append({"type": "goal_done", "goal": goal, "steps": len(tree.tasks),
                                 "results": _step_results(tree.tasks), **self._goal_request(where="goal_done")})
        self.flush_situations()
        return "done"

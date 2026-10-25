"""Run the brain live against the real body over the JSONL bridge, driven by in-game chat.

  .venv\\Scripts\\python.exe -m brain.run_live              # real models: API spend per addressed chat line
  .venv\\Scripts\\python.exe -m brain.run_live --dry-run    # rule-based fake models, no API calls

Event-driven: the loop only polls the bridge file for new events. A model is
called only when a chat line addressed to the companion arrives (or a goal
needs planning). Never on a timer.

Chat routing (every line is logged; only these reach the brain):
  "!ping"            -> say("pong") at once, no model call (Phase 5 gate).
  "<prefix> <text>"  -> the Controller gets <text>. Prefixes are case-insensitive and
                        configurable (--prefix, or DW_CHAT_PREFIXES separated by "|").
  anything else      -> ignored (players talking to each other).

Body: --body server (the server puppet mod, bridge_io/) or --body client (Claude's own game
client, client_mod/, client_io/bridge/; BRIDGE_PROTOCOL.md "Client endpoint"); default DW_BODY or server.

Env vars: DW_CONTROLLER_MODEL, DW_PLANNER_MODEL (LiteLLM model strings) plus the
provider key LiteLLM wants (ANTHROPIC_API_KEY, XAI_API_KEY, ...); DW_BODY, DW_BRIDGE_DIR,
DW_LOG_DIR, DW_STATE_DIR (see paths.py); DW_CHAT_PREFIXES, DW_COMPANION_NAME,
DW_PLAYER_NAME.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import re
import sys
import threading
import time
import traceback
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import paths, worlds
from .agent import Agent, GoalResult
from .bridge_client import BridgeClient
from .budget import Budget, default_cap_usd, default_spend_fn
from .capabilities import Capabilities, discover
from .map_memory import MapMemory, annotate
from .controller import Controller
from .dry_run_llm import DryRunController, DryRunPlanner
from .executor import Executor
from .interface import ChatHeard, CommandReceived, Event
from .jsonl_log import JsonlLogger
from .knowledge import open_knowledge
from .llm import CONTROLLER_MODEL_ENV, PLANNER_MODEL_ENV, LLMClient, LiteLLMClient, missing_keys
from .planner import Planner
from .skill_library import SkillLibrary
from .state_store import StateStore
from .transport import JsonlFileTransport, endpoint_files

# Matched case-insensitively. "claude," before "claude " so the comma is stripped too.
DEFAULT_PREFIXES = ["!c ", "claude,", "claude:", "@claude ", "claude ", "companion,", "companion:", "@companion "]
PREFIX_ENV = "DW_CHAT_PREFIXES"
PING = "!ping"
PARTNER_S = 180.0  # a player he answered this recently is the one he is talking with
PONG = "pong"


def chat_route(text: str, prefixes: list[str], name: str | None = "Claude") -> tuple[str, str | None]:
    """("ping", None), ("command", the text for the Controller) or ("ignore", None).
    Addressed = a prefix at the start, or the companion's name as a whole word anywhere
    ("hello claude ...", "thanks Claude", "@claude ..."; not "claudette"). The text goes to the
    model VERBATIM (review L12: no greeting stripping); only a command prefix like "!c " is cut."""
    t = text.strip()
    low = t.lower()
    if low == PING or low.startswith(PING + " "):
        return "ping", None
    for p in prefixes:
        if low.startswith(p.lower()):
            rest = t[len(p):].strip()
            if not rest:
                return "ignore", None
            return "command", (t if re.match(rf"@?{re.escape(name)}\b", t, flags=re.I) else rest) if name else rest
    if name and re.search(rf"\b{re.escape(name)}\b", t, flags=re.I):
        return "command", t
    return "ignore", None


class ChatMemory:
    """The rolling chat the Controller sees (Luis, 2026-10-25: Claude reads all chat and works out
    what is meant for him): the last ``max_lines`` lines of the last ``max_age_s`` seconds, his own
    lines included (``you``)."""

    def __init__(self, name: str, max_lines: int = 12, max_age_s: float = 240.0,
                 clock: Callable[[], float] = time.monotonic):
        self.name = name
        self.max_lines, self.max_age_s, self.clock = max_lines, max_age_s, clock
        self._lines: deque[tuple[float, str, str, bool]] = deque(maxlen=max_lines)

    def add(self, who: str, text: str, you: bool = False) -> None:
        self._lines.append((self.clock(), who, text, you))

    def lines(self) -> list[dict]:
        now = self.clock()
        return [{"who": who, "text": text, "you": you, "ago_s": round(now - t)}
                for t, who, text, you in self._lines if now - t <= self.max_age_s]


class LiveAgent(Agent):
    """Agent for live chat. With a client body every chat line arrives (``chat_heard``):
    - "!ping" -> "pong" at once, no model;
    - a line that names the companion (or starts with a prefix) -> the Controller, addressed;
    - any other line -> after a short quiet time, the Controller with addressed=false decides whether
      it is meant for him and stays silent if not. Capped at ``calls_per_min`` model calls per minute.
    A burst is ONE run with all of the player's lines (streamline step 3): his pending lines are
    joined with " / " into the command text, so "drink the pumkin spice infusuion / thats drink / smh"
    is grounded as a whole, and an addressed line takes his pending lines along. Body situations
    waiting meanwhile ride along in that run (one line for both).
    Every line gets a ``chat_decision`` log record with the reason. A body that pre-filters chat
    (``command_received``) is still handled the old way."""

    def __init__(self, *args, prefixes: list[str], calls_per_min: int = 20, debounce_s: float = 1.5,
                 clock: Callable[[], float] = time.monotonic, **kwargs):
        super().__init__(*args, **kwargs)
        self.prefixes = prefixes
        self.calls_per_min, self.debounce_s, self.clock = calls_per_min, debounce_s, clock
        self.chat = ChatMemory(self.controller.name, clock=clock)
        self.controller.chat_provider = self.chat.lines
        self._pending: list[tuple[float, ChatHeard, bool, str, str]] = []  # (heard at, event, addressed, text, episode)
        self._calls: deque[float] = deque()
        self._partner: tuple[str, float] | None = None  # the player he last answered, and when
        self._talking_to: str | None = None
        self.controller.on_say = self._said
        if hasattr(self.game, "interrupt_check"):  # L2(a): the player's addressed line gets the floor at once
            self.game.interrupt_check = self._addressed_line

    def _addressed_line(self, event: Event) -> bool:
        if isinstance(event, CommandReceived):
            return True
        return isinstance(event, ChatHeard) and \
            chat_route(event.text, self.prefixes, self.controller.name)[0] in ("command", "ping")

    # ---------------------------------------------------------------- chat
    def _said(self, text: str) -> None:
        self.chat.add(self.controller.name, text, you=True)
        if self._talking_to:
            self._partner = (self._talking_to, self.clock())

    def _with(self, player: str) -> str | None:
        """Why a line from ``player`` counts as addressed without his name (speed plan §2.1: Luis rarely
        says "claude"): he is the one Claude is talking with, or the only player around."""
        if self._partner and self._partner[0] == player and self.clock() - self._partner[1] <= PARTNER_S:
            return "his conversation partner"
        seen = self.broker._seen or {}
        names = [str(p.get("name")) for p in seen.get("players") or [] if isinstance(p, dict) and p.get("name")]
        if names == [player]:
            return "the only player around"
        return None

    def _decision(self, player: str, text: str, decision: str, reason: str, **extra) -> None:
        self.log.log("chat_decision", player=player, text=text, decision=decision, reason=reason, **extra)

    def _ping(self, player: str) -> None:
        start = time.perf_counter()
        res = self.controller.say(PONG, kind="system")
        self.log.log("ping_reply", player=player, ok=bool(res and res.get("ok")), reason=res.get("reason") if res else None,
                     say_round_trip_ms=round((time.perf_counter() - start) * 1000, 1))

    def _run(self, player: str, text: str, addressed: bool) -> None:
        if self.budget is not None and not self.budget.allows("chat"):
            # $ cap (Luis): one honest line, then reflex-only (the body keeps itself fed, defends, follows)
            self._decision(player, text, "budget", "model calls refused by the budget guard")
            if addressed and self.budget.out_line_due():
                self.controller.say(self.budget.out_line())
            return
        self._calls.append(self.clock())
        command = CommandReceived(player=player, text=text)
        self._talking_to = player
        try:
            self._command(command, addressed=addressed, body_events=self.take_situations() or None)
        except Exception as exc:  # a model/provider error must not kill the session
            self.log.log("command_error", error=repr(exc), traceback=traceback.format_exc())
            if addressed:
                self.controller.say("Sorry, my head glitched on that one. Try again?")
        finally:
            self._talking_to = None

    def _rate_capped(self) -> bool:
        now = self.clock()
        while self._calls and now - self._calls[0] > 60.0:
            self._calls.popleft()
        return len(self._calls) >= self.calls_per_min

    def heard(self, event: ChatHeard) -> None:
        # one episode per chat burst: the lines a run will take together share an id (observability)
        eid = next((x[4] for x in self._pending if x[1].player == event.player), None) or \
            self.log.new_episode_id("chat")
        with self.log.episode(eid):
            self._heard(event, eid)

    def _heard(self, event: ChatHeard, eid: str) -> None:
        self.log.log("event", event=event.model_dump())
        self.chat.add(event.player, event.text)
        route, text = chat_route(event.text, self.prefixes, self.controller.name)
        if route == "ping":
            self._decision(event.player, event.text, "ping", "!ping (no model)")
            return self._ping(event.player)
        if route == "command":  # named: at once, taking his pending lines along
            mine = [(ev, t) for _, ev, _, t, _ in self._pending if ev.player == event.player]
            self._pending = [x for x in self._pending if x[1].player != event.player]
            for ev, _ in mine:
                self._decision(ev.player, ev.text, "merged", "burst: decided together with his addressed line")
            text = " / ".join([t.strip() for _, t in mine] + [text])
            self._decision(event.player, event.text, "addressed", "named or prefixed", command=text)
            return self._run(event.player, text, addressed=True)
        if why := self._with(event.player):
            self._pending.append((self.clock(), event, True, event.text, eid))
            self._decision(event.player, event.text, "addressed", why)
        else:
            self._pending.append((self.clock(), event, False, event.text, eid))
            self._decision(event.player, event.text, "pending", "not named: the model decides after the burst")
        if self.debounce_s <= 0:
            self.flush_chat()

    def flush_chat(self) -> None:
        """Run the burst once the chat has been quiet for ``debounce_s`` (0.8 s): ONE run with all of the
        last speaker's lines; it is addressed when any of them was (named, or from the player he is with)."""
        if not self._pending:
            return
        if self.clock() - self._pending[-1][0] < self.debounce_s and len(self._pending) < 4:
            return
        batch, self._pending = self._pending, []
        last = batch[-1][1]
        eid = next(x[4] for x in batch if x[1].player == last.player)
        with self.log.episode(eid):
            mine = [(ev, addr, text) for _, ev, addr, text, _ in batch if ev.player == last.player]
            for _, ev, _, _, _ in batch[:-1]:
                self._decision(ev.player, ev.text, "merged", "burst: decided together with the last line")
            addressed = any(addr for _, addr, _ in mine)
            text = " / ".join(t.strip() for _, _, t in mine)
            if not addressed and self._rate_capped():
                self._decision(last.player, text, "ignored", f"rate cap ({self.calls_per_min} model calls/min)")
                return
            self._run(last.player, text, addressed=addressed)

    def _chat_waiting(self) -> bool:
        return bool(self._pending)

    def step(self) -> GoalResult | None:
        self.pump()
        self.flush_chat()
        return super().step()

    def handle_event(self, event: Event) -> None:
        if isinstance(event, ChatHeard):
            return self.heard(event)
        if not isinstance(event, CommandReceived):
            return super().handle_event(event)
        with self.log.episode(self.log.new_episode_id("chat")):
            return self._command_line(event)

    def _command_line(self, event: CommandReceived) -> None:
        route, text = chat_route(event.text, self.prefixes, self.controller.name)
        self.log.log("event", event=event.model_dump(), route=route)
        if route == "ping":
            return self._ping(event.player)
        if route == "ignore":
            return
        self._run(event.player, text, addressed=True)

    def run_goal(self, goal: str, **kwargs) -> GoalResult:
        try:
            return super().run_goal(goal, **kwargs)
        except Exception as exc:
            self.log.log("goal_error", goal=goal, error=repr(exc), traceback=traceback.format_exc())
            self.controller.say(f"Sorry, I lost track of '{goal}' (internal error).")
            return "stuck"


BODY_LABELS = {"server": "server puppet mod, mod/", "client": "Claude's own game client, client_mod/"}


@dataclass
class LiveOptions:
    body: str = field(default_factory=paths.body_kind)  # "server" | "client" (file names; see transport)
    bridge_dir: Path | None = None  # default: DW_BRIDGE_DIR, else the body's default directory
    state_dir: Path = field(default_factory=paths.state_dir)
    skills_dir: Path | None = None  # default: data/skills (or <state_dir>/skills for a non-default state dir)
    log_dir: Path = field(default_factory=paths.log_dir)
    prefixes: list[str] = field(default_factory=lambda: list(DEFAULT_PREFIXES))
    dry_run: bool = False
    name: str = "Claude"
    player: str = "Luis"
    poll_interval: float = 0.25  # bridge-file poll only; no model is ever called on this timer
    wait: float = 0.0  # seconds to wait for the body at startup; 0 = forever
    probe_timeout: float = 3.0
    # chat reading (client body): model calls per minute for lines nobody addressed to him, and the
    # quiet time that ends a burst of lines (DW_CHAT_CALLS_PER_MIN, DW_CHAT_DEBOUNCE_S)
    chat_calls_per_min: int = field(default_factory=lambda: int(os.environ.get("DW_CHAT_CALLS_PER_MIN", "20")))
    chat_debounce_s: float = field(default_factory=lambda: float(os.environ.get("DW_CHAT_DEBOUNCE_S", "0.8")))
    # game knowledge (brain/knowledge.py: game data + local wiki mirror) behind the lookup tool; DW_KNOWLEDGE=0 off
    knowledge: bool = field(default_factory=lambda: os.environ.get("DW_KNOWLEDGE", "1") != "0")
    # the task board + Sonnet Director (brain/director.py); DW_DIRECTOR=1 on, DW_DIRECTOR_CALLS_PER_HOUR its window
    director: bool = field(default_factory=lambda: os.environ.get("DW_DIRECTOR", "0") == "1")


def code_version() -> dict:
    """{companion_sha, dirty} of the repo this brain runs from, so obs/goal_check can tie a session to the
    exact code. None values when git isn't available (never fails a start)."""
    root = Path(__file__).resolve().parents[1]

    def git(*args: str) -> str | None:
        try:
            out = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return None
        return out.stdout if out.returncode == 0 else None
    sha = git("rev-parse", "HEAD")
    status = git("status", "--porcelain")
    return {"companion_sha": sha.strip() if sha else None, "dirty": None if status is None else bool(status.strip())}


class BodyUnavailable(RuntimeError):
    pass


class LiveSession:
    def __init__(self, opts: LiveOptions, controller_llm: LLMClient, planner_llm: LLMClient,
                 out: Callable[[str], None] = lambda s: print(s, flush=True)):
        self.opts = opts
        self.out = out
        self.log = JsonlLogger.session(directory=opts.log_dir)
        opts.body = paths.body_kind(opts.body)
        if opts.bridge_dir is None:
            opts.bridge_dir = paths.bridge_dir(opts.body)
        d = Path(opts.bridge_dir)
        to_body, to_brain = endpoint_files(opts.body)
        self.client = BridgeClient(JsonlFileTransport(d / to_body, d / to_brain), self.log)
        self.rtt = self._connect()
        self.caps: Capabilities = discover(self.client, self.log, opts.probe_timeout)
        # Per-world memory (design 15): notes, places, rule snapshot, task tree and learned skills
        # are keyed by the save's WorldSaveGuid ("default" until the body can tell us).
        self.world, self.world_source = worlds.resolve_world_guid(self.client)
        state_dir, migrated = worlds.prepare_state_dir(opts.state_dir, self.world)
        skills_root = opts.skills_dir or (paths.skills_dir() if Path(opts.state_dir) == paths.state_dir()
                                          else Path(opts.state_dir) / "skills")
        self.skills = SkillLibrary(worlds.prepare_skills_dir(skills_root, self.world), self.log)
        self.store = StateStore(state_dir, self.caps.registry())
        # per-world map / resource memory (BUGS L21): every census feeds it; get_state carries the nearest
        # remembered options beyond sight (state["remembered"]); the Director reads the same file
        self.map = MapMemory(Path(state_dir) / "map_memory.json")
        self.client.state_hooks.append(lambda data: (self.map.observe(data), annotate(data, self.map)))
        self.executor = Executor(self.client, self.store, self.log)
        self.planner = Planner(planner_llm, self.store.skills, self.log)
        self.knowledge = open_knowledge(self.log) if opts.knowledge else None
        self.controller = Controller(controller_llm, self.client, self.store, self.log,
                                     name=opts.name, player=opts.player, available_tools=self.caps.tools,
                                     skills=self.skills, caps=self.caps, knowledge=self.knowledge)
        self.executor.max_attempts = 1  # speed plan §2.3: no executor retries live; results go to the model
        self.agent = LiveAgent(self.client, self.controller, self.planner, self.executor, self.store,
                               self.log, prefixes=opts.prefixes, skills=self.skills,
                               calls_per_min=opts.chat_calls_per_min, debounce_s=opts.chat_debounce_s)
        self.agent.body_self_defends = "combat_status" in self.caps.extras
        self.agent.budget = Budget(None if opts.dry_run else default_spend_fn(), cap_usd=default_cap_usd(),
                                   log=self.log)  # Luis's daily $ cap (shared with tools/spend.py)
        self.director = None
        if opts.director:
            from .director import Director  # docs/design/director.md
            self.director = Director.for_session(self.agent, planner_llm, store=self.store, skills=self.skills,
                                                 knowledge=self.knowledge, caps=self.caps, budget=self.agent.budget,
                                                 log=self.log, player=opts.player)
            self.agent.director = self.director
            self.controller.attach_director(self.director)
        self.log.log("session_start", dry_run=opts.dry_run, controller_model=controller_llm.model,
                     planner_model=planner_llm.model, body=opts.body, bridge_dir=str(d), prefixes=opts.prefixes,
                     ping_ms=round(self.rtt * 1000, 1), skills=self.store.skills.names(),
                     capabilities_source=self.caps.source, missing=self.caps.missing,
                     world=self.world, world_source=self.world_source, state_dir=str(state_dir),
                     migrated=migrated, learned_skills=self.skills.names(), skills_dir=str(self.skills.dir),
                     knowledge=self.knowledge.stats() if self.knowledge else None,
                     director=self.director is not None, **code_version())
        self.out(self.banner(controller_llm.model, planner_llm.model))

    def _connect(self) -> float:
        deadline = time.monotonic() + self.opts.wait if self.opts.wait > 0 else None
        announced = 0.0
        while True:
            rtt = self.client.ping(timeout=2.0)
            if rtt is not None:
                return rtt
            if deadline is not None and time.monotonic() >= deadline:
                raise BodyUnavailable(f"no answer to ping on {self.opts.bridge_dir} after {self.opts.wait:.0f}s")
            if time.monotonic() - announced > 15:
                self.out(f"waiting for the body to answer ping on {self.opts.bridge_dir} ...")
                announced = time.monotonic()

    def banner(self, controller_model: str, planner_model: str) -> str:
        mode = ("DRY RUN (rule-based fake models, no API calls)" if self.opts.dry_run
                else "LIVE MODELS (API calls on every addressed chat line)")
        missing = ", ".join(f"{t} ({r})" for t, r in self.caps.missing.items()) or "none"
        lines = [
            "=" * 72,
            " Dragonwilds companion brain",
            f" mode         : {mode}",
            f" controller   : {controller_model}",
            f" planner      : {planner_model}",
            f" body         : {self.opts.body}  ({BODY_LABELS[self.opts.body]})",
            f" bridge       : {self.opts.bridge_dir}  (ping {self.rtt * 1000:.0f} ms)",
            f" skills       : {', '.join(self.store.skills.names()) or 'none'}  (from {self.caps.source})",
            f" world        : {self.world}  (from {self.world_source}; memory {self.store.dir})",
            f" learned      : {', '.join(self.skills.names()) or 'none yet'}  ({self.skills.dir})",
            f" perception   : {'look/inspect' if self.caps.has('look') else 'situation digest only (no look)'}"
            f"{', interact' if self.caps.has('interact') else ''}",
            f" unavailable  : {missing}",
            f" chat         : {PING!r} -> {PONG!r} (no model); prefixes {', '.join(map(repr, self.opts.prefixes))}",
            f" log          : {self.log.path}",
            "                (pretty-print: .venv\\Scripts\\python.exe -m brain.tail_logs)",
            "=" * 72,
        ]
        warn = []
        if not self.caps.has("say"):
            warn.append(" WARNING: body has no 'say'; the companion cannot reply in chat (pong included).")
        if not self.caps.has("get_state"):
            warn.append(" WARNING: body has no 'get_state'; actions cannot be verified and will be refused.")
        return "\n".join(lines[:-1] + warn + lines[-1:])

    def step(self) -> GoalResult | None:
        try:
            return self.agent.step()
        except Exception as exc:
            self.log.log("loop_error", error=repr(exc), traceback=traceback.format_exc())
            self.out(f"loop error (see log): {exc!r}")
            return None

    def run(self, stop: threading.Event | None = None) -> None:
        stop = stop or threading.Event()
        try:
            while not stop.is_set():
                self.step()
                stop.wait(self.opts.poll_interval)
        finally:
            self.log.log("session_end")


# --------------------------------------------------------------------------- CLI


def _env_prefixes() -> list[str] | None:
    raw = os.environ.get(PREFIX_ENV)
    return [p for p in raw.split("|") if p.strip()] if raw else None


def make_llms(dry_run: bool) -> tuple[LLMClient, LLMClient]:
    if dry_run:
        return DryRunController(), DryRunPlanner()
    # Controller: up to 3 short calls per command; room for default-on adaptive thinking + one tool call.
    # Speed plan §2 (live p50: ~170 of ~266 completion tokens per Controller call were thinking): effort
    # "low" for the fast Controller (Claude API docs: low suits latency-sensitive, chat-like routes; keep
    # adaptive thinking ON rather than disabling it, which can put tool calls into the visible text).
    # DW_CONTROLLER_EFFORT= (empty) uses the model's default (Haiku 5.5: medium). A constant effort keeps
    # the prompt cache. LiteLLM 1.106 passes output_config through to the Messages API unchanged.
    controller = os.environ[CONTROLLER_MODEL_ENV]
    effort = os.environ.get("DW_CONTROLLER_EFFORT", "low").strip()
    extra = {"output_config": {"effort": effort}} if effort and controller.startswith("anthropic/") else {}
    return (LiteLLMClient(controller, max_tokens=1024, **extra),
            LiteLLMClient(os.environ[PLANNER_MODEL_ENV], max_tokens=2048))


def check_credentials() -> list[str]:
    """Problems that stop a live (non dry-run) start; empty when good to go."""
    problems = []
    models = {}
    for var in (CONTROLLER_MODEL_ENV, PLANNER_MODEL_ENV):
        if os.environ.get(var):
            models[var] = os.environ[var]
        else:
            problems.append(f"{var} is not set (a LiteLLM model string, e.g. 'anthropic/<model-id>')")
    for var, model in models.items():
        try:
            keys = missing_keys(model)
        except Exception as exc:  # litellm missing or broken
            problems.append(f"cannot check the API key for {model}: {exc!r}")
            continue
        if keys:
            problems.append(f"{var}={model} needs {' or '.join(keys)} in the environment")
    return problems


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(prog="python -m brain.run_live", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="rule-based fake models; no API key, no spend")
    ap.add_argument("--body", choices=paths.BODIES, default=None,
                    help="which body to drive: server (puppet mod) or client (Claude's game client). "
                         "Default DW_BODY or server")
    ap.add_argument("--bridge-dir", type=Path, default=None,
                    help="default: DW_BRIDGE_DIR, else <repo>/bridge_io (server) or <repo>/client_io/bridge (client)")
    ap.add_argument("--prefix", action="append", default=None,
                    help=f"chat prefix addressing the companion (repeatable). Default {DEFAULT_PREFIXES}")
    ap.add_argument("--name", default=os.environ.get("DW_COMPANION_NAME", "Claude"))
    ap.add_argument("--player", default=os.environ.get("DW_PLAYER_NAME", "Luis"),
                    help="name the persona uses for the human player")
    ap.add_argument("--wait", type=float, default=0.0, help="seconds to wait for the body; 0 = forever")
    return ap.parse_args(argv)


def main(argv: list[str] | None = None, stop: threading.Event | None = None) -> int:
    a = parse_args(argv)
    if not a.dry_run and (problems := check_credentials()):
        print("refusing to start live models (use --dry-run to test without a key):", file=sys.stderr)
        for p in problems:
            print("  - " + p, file=sys.stderr)
        return 2
    opts = LiveOptions(dry_run=a.dry_run, name=a.name, player=a.player, wait=a.wait,
                       body=paths.body_kind(a.body),
                       prefixes=a.prefix or _env_prefixes() or list(DEFAULT_PREFIXES))
    if a.bridge_dir:
        opts.bridge_dir = a.bridge_dir
    controller_llm, planner_llm = make_llms(a.dry_run)
    try:
        session = LiveSession(opts, controller_llm, planner_llm)
    except BodyUnavailable as exc:
        print(f"body unavailable: {exc}", file=sys.stderr)
        return 3
    try:
        session.run(stop)
    except KeyboardInterrupt:
        print("stopped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

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

Env vars: DW_CONTROLLER_MODEL, DW_PLANNER_MODEL (LiteLLM model strings) plus the
provider key LiteLLM wants (ANTHROPIC_API_KEY, XAI_API_KEY, ...); DW_BRIDGE_DIR,
DW_LOG_DIR, DW_STATE_DIR (see paths.py); DW_CHAT_PREFIXES, DW_COMPANION_NAME,
DW_PLAYER_NAME.
"""
from __future__ import annotations

import argparse
import os
import sys
import threading
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import paths
from .agent import Agent, GoalResult
from .bridge_client import BridgeClient
from .capabilities import Capabilities, discover
from .controller import Controller
from .dry_run_llm import DryRunController, DryRunPlanner
from .executor import Executor
from .interface import CommandReceived, Event
from .jsonl_log import JsonlLogger
from .llm import CONTROLLER_MODEL_ENV, PLANNER_MODEL_ENV, LLMClient, LiteLLMClient, missing_keys
from .planner import Planner
from .state_store import StateStore
from .transport import BODY_TO_BRAIN, BRAIN_TO_BODY, JsonlFileTransport

# Matched case-insensitively. "claude," before "claude " so the comma is stripped too.
DEFAULT_PREFIXES = ["!c ", "claude,", "claude:", "@claude ", "claude ", "companion,", "companion:", "@companion "]
PREFIX_ENV = "DW_CHAT_PREFIXES"
PING = "!ping"
PONG = "pong"


def chat_route(text: str, prefixes: list[str]) -> tuple[str, str | None]:
    """("ping", None), ("command", text without the prefix) or ("ignore", None)."""
    t = text.strip()
    low = t.lower()
    if low == PING or low.startswith(PING + " "):
        return "ping", None
    for p in prefixes:
        if low.startswith(p.lower()):
            rest = t[len(p):].strip()
            return ("command", rest) if rest else ("ignore", None)
    return "ignore", None


class LiveAgent(Agent):
    """Agent that only answers chat addressed to it, and answers !ping without a model."""

    def __init__(self, *args, prefixes: list[str], **kwargs):
        super().__init__(*args, **kwargs)
        self.prefixes = prefixes

    def handle_event(self, event: Event) -> None:
        if not isinstance(event, CommandReceived):
            return super().handle_event(event)
        route, text = chat_route(event.text, self.prefixes)
        self.log.log("event", event=event.model_dump(), route=route)
        if route == "ping":
            start = time.perf_counter()
            res = self.controller.say(PONG)
            self.log.log("ping_reply", player=event.player, ok=bool(res and res.get("ok")),
                         reason=res.get("reason") if res else None,
                         say_round_trip_ms=round((time.perf_counter() - start) * 1000, 1))
            return
        if route == "ignore":
            return
        command = CommandReceived(player=event.player, text=text)
        self.controller.note_event(command)
        try:
            self._command(command)
        except Exception as exc:  # a model/provider error must not kill the session
            self.log.log("command_error", error=repr(exc), traceback=traceback.format_exc())
            self.controller.say("Sorry, my head glitched on that one. Try again?")

    def run_goal(self, goal: str) -> GoalResult:
        try:
            return super().run_goal(goal)
        except Exception as exc:
            self.log.log("goal_error", goal=goal, error=repr(exc), traceback=traceback.format_exc())
            self.controller.say(f"Sorry, I lost track of '{goal}' (internal error).")
            return "stuck"


@dataclass
class LiveOptions:
    bridge_dir: Path = field(default_factory=paths.bridge_dir)
    state_dir: Path = field(default_factory=paths.state_dir)
    log_dir: Path = field(default_factory=paths.log_dir)
    prefixes: list[str] = field(default_factory=lambda: list(DEFAULT_PREFIXES))
    dry_run: bool = False
    name: str = "Claude"
    player: str = "Luis"
    poll_interval: float = 0.25  # bridge-file poll only; no model is ever called on this timer
    wait: float = 0.0  # seconds to wait for the body at startup; 0 = forever
    probe_timeout: float = 3.0


class BodyUnavailable(RuntimeError):
    pass


class LiveSession:
    def __init__(self, opts: LiveOptions, controller_llm: LLMClient, planner_llm: LLMClient,
                 out: Callable[[str], None] = lambda s: print(s, flush=True)):
        self.opts = opts
        self.out = out
        self.log = JsonlLogger.session(directory=opts.log_dir)
        d = Path(opts.bridge_dir)
        self.client = BridgeClient(JsonlFileTransport(d / BRAIN_TO_BODY, d / BODY_TO_BRAIN), self.log)
        self.rtt = self._connect()
        self.caps: Capabilities = discover(self.client, self.log, opts.probe_timeout)
        self.store = StateStore(opts.state_dir, self.caps.registry())
        self.executor = Executor(self.client, self.store, self.log)
        self.planner = Planner(planner_llm, self.store.skills, self.log)
        self.controller = Controller(controller_llm, self.client, self.store, self.log,
                                     name=opts.name, player=opts.player)
        self.agent = LiveAgent(self.client, self.controller, self.planner, self.executor, self.store,
                               self.log, prefixes=opts.prefixes)
        self.log.log("session_start", dry_run=opts.dry_run, controller_model=controller_llm.model,
                     planner_model=planner_llm.model, bridge_dir=str(d), prefixes=opts.prefixes,
                     ping_ms=round(self.rtt * 1000, 1), skills=self.store.skills.names(),
                     capabilities_source=self.caps.source, missing=self.caps.missing)
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
            f" bridge       : {self.opts.bridge_dir}  (ping {self.rtt * 1000:.0f} ms)",
            f" skills       : {', '.join(self.store.skills.names()) or 'none'}  (from {self.caps.source})",
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
    return (LiteLLMClient(os.environ[CONTROLLER_MODEL_ENV], max_tokens=512),
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
    ap.add_argument("--bridge-dir", type=Path, default=None, help="default: DW_BRIDGE_DIR or <repo>/bridge_io")
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

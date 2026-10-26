"""Who plays a case (design §2, §6): the companion (the real brain stack) or a control agent.

Controls are scripted and harness-owned. `oracle` is the positive control; `do_nothing` (= the review's `ambient`:
no actions, reflexes on, the full wall time), `claims_only`, `wrong_action`, `alt_means` and `partial` are the
negative controls. Every control acts through the same ObservedGame, so its evidence is judged exactly like the
companion's.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from brain.controller import Controller
from brain.executor import Executor
from brain.interface import ChatHeard
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM, LLMClient, LLMResponse
from brain.planner import Planner
from brain.state_store import StateStore

CONTROLS = ("oracle", "do_nothing", "claims_only", "wrong_action", "alt_means", "partial")
NEGATIVE = ("do_nothing", "claims_only", "wrong_action", "alt_means", "partial")
PLAYER = "Tester"


class BudgetExceeded(RuntimeError):
    pass


@dataclass
class CountingLLM:
    """Counts calls and tokens per model, logs usage rows (tools.obs spend reads them), enforces a call cap."""
    inner: LLMClient
    family: str  # "haiku" | "sonnet" (the cap key)
    cap: int
    log: JsonlLogger | None = None
    calls: int = 0
    usage: list[dict] = field(default_factory=list)
    exceeded: bool = False  # the agent loop swallows exceptions: the runner reads this flag

    @property
    def model(self) -> str:
        return getattr(self.inner, "model", "unknown")

    def __getattr__(self, name: str):
        # warm (L27 cache warm-up) and other optional client features pass through; only complete() is capped
        if name == "warm" and hasattr(self.inner, "warm"):
            return self.inner.warm
        raise AttributeError(name)

    def complete(self, messages: list[dict], tools: list[dict] | None = None) -> LLMResponse:
        if self.calls >= self.cap:
            self.exceeded = True
            raise BudgetExceeded(f"{self.family} call cap {self.cap} reached")
        self.calls += 1
        resp = self.inner.complete(messages, tools)
        if resp.usage:
            self.usage.append(dict(resp.usage))
        return resp


def model_family(model: str) -> str:
    return "sonnet" if re.search(r"sonnet|opus|planner", model or "", re.I) else "haiku"


# ------------------------------------------------------------------ the companion


@dataclass
class Companion:
    agent: Any
    controller_llm: CountingLLM
    planner_llm: CountingLLM
    log: JsonlLogger

    def hear(self, text: str, player: str = PLAYER) -> None:
        self.agent.heard(ChatHeard(player=player, text=text))

    def step(self) -> None:
        self.agent.step()

    def calls(self) -> dict[str, int]:
        return {self.controller_llm.family: self.controller_llm.calls,
                self.planner_llm.family: self.planner_llm.calls + (self.controller_llm.calls if
                                                                    self.planner_llm.family == self.controller_llm.family else 0)}


def build_companion(game, workdir: Path, controller_llm: LLMClient | None, planner_llm: LLMClient | None,
                    caps: dict[str, int], player: str = PLAYER, knowledge=None, tools: set[str] | None = None) -> Companion:
    """The real LiveAgent stack (Controller, Planner, Executor, broker) over the observed game. Its state store
    and skill library live in this case's own fresh directory (design §7.3: no memory leaks between cases)."""
    from brain.run_live import LiveAgent  # late: heavy import

    log = JsonlLogger(workdir / "brain.jsonl")
    c_llm = controller_llm or FakeLLM(model="fake/controller")
    p_llm = planner_llm or FakeLLM(model="fake/planner")
    cf, pf = model_family(getattr(c_llm, "model", "")), "sonnet"
    ctl = CountingLLM(c_llm, cf, int(caps.get(cf, 10)), log)
    pln = CountingLLM(p_llm, pf, int(caps.get(pf, 0)) or 1, log)
    store = StateStore(workdir / "state")
    executor = Executor(game, store, log, max_attempts=1)
    controller = Controller(ctl, game, store, log, name="Claude", player=player, available_tools=tools,
                            knowledge=knowledge)
    agent = LiveAgent(game, controller, Planner(pln, store.skills, log), executor, store, log,
                      prefixes=["claude ", "claude,", "@claude "], calls_per_min=1000, debounce_s=0.0)
    return Companion(agent, ctl, pln, log)


# ------------------------------------------------------------------ scripted controls


def bind(obj: Any, bindings: dict) -> Any:
    """Replace "$name" / "$name.key" strings with scene-builder outputs (ids, positions)."""
    if isinstance(obj, str) and obj.startswith("$"):
        cur: Any = bindings
        for part in obj[1:].split("."):
            if not isinstance(cur, dict) or part not in cur:
                raise KeyError(f"unbound placeholder {obj}")
            cur = cur[part]
        return cur
    if isinstance(obj, list):
        return [bind(x, bindings) for x in obj]
    if isinstance(obj, dict):
        return {k: bind(v, bindings) for k, v in obj.items()}
    return obj


def run_script(steps: list[dict], game, world, bindings: dict, say: Callable[[str], Any] | None = None) -> list[dict]:
    """Steps: {"tool": name, "args": {...}} (through the observed game, judged like the companion's actions),
    {"setup": verb, ...} (a harness fixture, e.g. an alt_means proxy: items appear on the ground),
    {"say": text}, {"wait_s": n} (the mock clock)."""
    out = []
    for s in steps:
        s = bind(s, bindings)
        if "tool" in s:
            r = game.call(s["tool"], s.get("args") or {})
            out.append({"tool": s["tool"], "ok": r.get("ok"), "reason": r.get("reason")})
        elif "setup" in s:
            a = {k: v for k, v in s.items() if k != "setup"}
            out.append({"setup": s["setup"], **(world.setup(s["setup"], **a) or {})})
        elif "say" in s:
            (say or game.say)(s["say"])
            out.append({"say": s["say"]})
        elif "pickup_all" in s:
            for gid, g in list(world.ground.items()):
                if g.item == s["pickup_all"]:
                    r = game.call("pickup", {"target": gid})
                    out.append({"tool": "pickup", "ok": r.get("ok"), "reason": r.get("reason")})
        elif "wait_s" in s:
            world.tick(float(s["wait_s"]))
    return out


def control_steps(case, control: str) -> list[dict] | None:
    """The scripted steps for a control on the mock, or None when it doesn't apply (case.controls.na)."""
    if control in (case.controls.na or {}):
        return None
    oracle = case.oracle.get("mock")
    if control == "oracle":
        return oracle if isinstance(oracle, list) else None
    if control == "do_nothing":
        return [{"wait_s": float(case.limits.sim_s or case.limits.wall_s)}]
    if control == "claims_only":
        return [{"say": "Done, all sorted!"}, {"tool": "remember", "args": {"key": "task", "value": "done"}}]
    if control == "partial":
        if case.controls.partial is not None:
            return case.controls.partial
        return oracle[:-1] if isinstance(oracle, list) and len(oracle) > 1 else None
    if control == "wrong_action":
        return case.controls.wrong_action
    if control == "alt_means":
        return case.controls.alt_means
    raise ValueError(control)

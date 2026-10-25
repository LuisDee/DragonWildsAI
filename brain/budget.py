"""Daily model-spend cap (Luis, 2026-10-25: $10/day).

The spend comes from a callable (the observability agent's ``tools.obs.spend_today``: USD this UTC
day, read from the brain logs' usage records; tools.spend.spent_today_usd). It is checked at most every ``check_s`` seconds.
- At ``warn_at`` (80 %) of the cap: one ``budget_warning`` log line per day.
- At 100 %: ``allows()`` is False. The Agent stops situation reviews and model runs, and the next
  player request gets one honest line (at most every ``out_repeat_s``). Body situations use their
  template lines (no model call). The body's reflexes (stay fed, self-defence, an active follow) run
  in the client and are unaffected.
Without a spend function the guard is off (``allows()`` is always True), and the log says so once.
"""
from __future__ import annotations

import os
import time
from typing import Callable

OUT_LINE = "I'm out of thinking budget for today, so I'll just keep myself fed, defend myself and follow you."
OUT_REPEAT_S = 600.0


class Budget:
    def __init__(self, spend_fn: Callable[[], float] | None, cap_usd: float | None = None, log=None,
                 clock: Callable[[], float] = time.monotonic, warn_at: float = 0.8, check_s: float = 30.0):
        self.spend_fn = spend_fn
        self.cap = float(cap_usd if cap_usd is not None else os.environ.get("DW_DAILY_CAP_USD", "10"))
        self.log, self.clock, self.warn_at, self.check_s = log, clock, warn_at, check_s
        self._at: float | None = None
        self._spent = 0.0
        self._warned_day: str | None = None
        self._out_said: float | None = None
        self._blocked = False
        if spend_fn is None and log is not None:
            log.log("budget_off", why="no spend function (tools.obs.spend_today not importable)")

    def spent(self) -> float:
        now = self.clock()
        if self.spend_fn is not None and (self._at is None or now - self._at >= self.check_s):
            self._at = now
            try:
                self._spent = float(self.spend_fn() or 0.0)
            except Exception as exc:  # a broken spend reader must never stop the brain
                if self.log is not None:
                    self.log.log("budget_read_error", error=repr(exc))
            day = time.strftime("%Y-%m-%d", time.gmtime())
            if self.cap > 0 and self._spent >= self.warn_at * self.cap and self._warned_day != day:
                self._warned_day = day
                if self.log is not None:
                    self.log.log("budget_warning", spent_usd=round(self._spent, 3), cap_usd=self.cap)
        return self._spent

    def allows(self, kind: str = "model") -> bool:
        """May the brain make a model call of this kind (chat, situation, review, director, planner)?"""
        if self.spend_fn is None or self.cap <= 0:
            return True
        ok = self.spent() < self.cap
        if ok == self._blocked and self.log is not None:  # log the change only (this is asked every pump)
            self.log.log("budget_blocked" if not ok else "budget_ok_again", call=kind,
                         spent_usd=round(self._spent, 3), cap_usd=self.cap)
        self._blocked = not ok
        return ok

    def out_line_due(self) -> bool:
        """Say the out-of-budget line now? (once, then at most every OUT_REPEAT_S)"""
        now = self.clock()
        if self._out_said is None or now - self._out_said >= OUT_REPEAT_S:
            self._out_said = now
            return True
        return False


def default_spend_fn():
    """The observability agent's ``tools.spend.spent_today_usd`` (USD this UTC day across every source:
    live brain, director, evals, generators; never raises, 0.0 on error, so the guard fails open), or
    None when it is not importable (guard off)."""
    try:
        from tools.spend import spent_today_usd
    except Exception:
        return None
    return spent_today_usd


def default_cap_usd() -> float | None:
    """The shared cap (tools.spend.cap_usd: DW_SPEND_CAP_USD, then DW_DAILY_CAP_USD, then 10)."""
    try:
        from tools.spend import cap_usd
        return float(cap_usd())
    except Exception:
        return None

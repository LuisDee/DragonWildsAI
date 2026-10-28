"""Daily model-spend cap (Luis, 2026-10-25: $10/day).

The spend comes from a callable that RAISES when it can't read the spend (default: the observability
agent's ``tools.spend.spend_today()["spent_usd"]``; USD this UTC day across every source: live brain,
director, evals, generators). It is checked at most every ``check_s`` seconds.
- At ``warn_at`` (80 %) of the cap: one ``budget_warning`` log line per day.
- At 100 %: ``allows()`` is False. The Agent stops situation reviews and model runs, and the next
  player request gets one honest line (at most every ``out_repeat_s``). Body situations use their
  template lines (no model call). The body's reflexes (stay fed, self-defence, an active follow) run
  in the client and are unaffected.
- The reader fails CLOSED (main, 2026-10-25). While the spend can't be read, autonomous calls (the
  Director, situation reviews, body situations, the planner) are refused at once and a
  ``budget_reader_error`` anomaly is logged. Live player chat stays allowed for up to
  ``chat_grace_s`` (30 min) of reader errors, then it is refused too, with one honest line.
Without a spend function the guard is off (``allows()`` is always True), and the log says so once.
"""
from __future__ import annotations

import threading
import time
from typing import Callable

OUT_LINE = "I'm out of thinking budget for today, so I'll just keep myself fed, defend myself and follow you."
BLIND_LINE = ("I can't check my thinking budget right now, so I'll stick to reflexes: staying fed, "
              "defending myself and following you.")
OUT_REPEAT_S = 600.0
CHAT_GRACE_S = 1800.0  # player chat keeps working this long while the spend reader fails
CHAT_KINDS = {"chat", "warmup"}  # everything else (review, situation, director, planner, ...) is autonomous


class Budget:
    def __init__(self, spend_fn: Callable[[], float] | None, cap_usd: float | None = None, log=None,
                 clock: Callable[[], float] = time.monotonic, warn_at: float = 0.8, check_s: float = 30.0,
                 chat_grace_s: float = CHAT_GRACE_S, background: bool = False):
        """``background``: a daemon thread reads the spend every ``check_s`` (call ``start()``) and
        ``allows()`` only reads the cached result, so the chat and pump paths never wait for the reader.
        Without it the read happens inline (tests, simple tools). The cap's single source is
        ``tools.spend.cap_usd`` (DW_SPEND_CAP_USD, then DW_DAILY_CAP_USD, then 10)."""
        self.spend_fn = spend_fn
        self.cap = float(cap_usd if cap_usd is not None else (default_cap_usd() or 10.0))
        self.background = background
        self._thread: threading.Thread | None = None
        self.log, self.clock, self.warn_at, self.check_s = log, clock, warn_at, check_s
        self.chat_grace_s = chat_grace_s
        self._at: float | None = None
        self._spent = 0.0
        self._successful_read = False  # set only after the first spend read has actually completed
        self._warned_day: str | None = None
        self._out_said: float | None = None
        self._blocked = False
        self._error_since: float | None = None  # the spend reader has failed since then
        self._why = "out"  # what the honest line is about: "out" (cap reached) | "blind" (can't read)
        if spend_fn is None and log is not None:
            log.log("budget_off", why="no spend function (tools.spend not importable)")

    def _log(self, kind: str, **f) -> None:
        if self.log is not None:
            self.log.log(kind, **f)

    def start(self) -> "Budget":
        """Start the background reader (background mode only); the first read starts at once."""
        if self.background and self.spend_fn is not None and self._thread is None:
            self._thread = threading.Thread(target=self._read_loop, name="budget-reader", daemon=True)
            self._thread.start()
        return self

    def _read_loop(self) -> None:
        while True:
            self._read()
            time.sleep(max(1.0, self.check_s))

    def spent(self) -> float:
        if not self.background:
            now = self.clock()
            if self.spend_fn is not None and (self._at is None or now - self._at >= self.check_s):
                self._read()
        return self._spent

    def _read(self) -> None:
        """One read of the spend reader; updates the cached spend and the error streak."""
        now = self.clock()
        if self.spend_fn is not None:
            self._at = now
            try:
                self._spent = float(self.spend_fn() or 0.0)
                self._successful_read = True
            except Exception as exc:  # fail CLOSED: see allows()
                if self._error_since is None:
                    self._error_since = now
                    self._log("budget_reader_error", anomaly=True, error=repr(exc),
                              effect="autonomous model calls refused; chat allowed for "
                                     f"{self.chat_grace_s / 60:.0f} min")
            else:
                if self._error_since is not None:
                    self._log("budget_reader_ok", after_s=round(now - self._error_since))
                self._error_since = None
            day = time.strftime("%Y-%m-%d", time.gmtime())
            if self.cap > 0 and self._spent >= self.warn_at * self.cap and self._warned_day != day:
                self._warned_day = day
                self._log("budget_warning", spent_usd=round(self._spent, 3), cap_usd=self.cap)

    def allows(self, kind: str = "model") -> bool:
        """May the brain make a model call of this kind (chat, situation, review, director, planner)?"""
        if self.spend_fn is None or self.cap <= 0:
            return True
        spent = self.spent()
        if self.background and self._at is None and kind not in CHAT_KINDS:
            return False  # the first background read hasn't finished: autonomous calls wait (fail closed)
        if self._error_since is not None:  # can't read the spend
            blind_for = self.clock() - self._error_since
            ok = kind in CHAT_KINDS and blind_for < self.chat_grace_s
            why = "blind"
        else:
            ok, why = spent < self.cap, "out"
        if not ok:
            self._why = why
        if ok == self._blocked:  # log the change only (this is asked every pump)
            self._log("budget_blocked" if not ok else "budget_ok_again", call=kind, why=why,
                      spent_usd=round(spent, 3), cap_usd=self.cap)
        self._blocked = not ok
        return ok

    def has_successful_read(self) -> bool:
        """Whether this reader has completed a successful read (not whether its cache is fresh)."""
        return self._successful_read

    def out_line(self) -> str:
        return BLIND_LINE if self._why == "blind" else OUT_LINE

    def out_line_due(self) -> bool:
        """Say the honest line now? (once, then at most every OUT_REPEAT_S)"""
        now = self.clock()
        if self._out_said is None or now - self._out_said >= OUT_REPEAT_S:
            self._out_said = now
            return True
        return False


def default_spend_fn():
    """USD spent today, RAISING when it can't be read (fail closed): ``tools.spend.spend_today()``
    (the observability agent's reader; its ``spent_today_usd`` would hide errors as 0.0). None when
    tools.spend is not importable (guard off)."""
    try:
        from tools.spend import spend_today
    except Exception:
        return None
    return lambda: float(spend_today()["spent_usd"])


def default_cap_usd() -> float | None:
    """The shared cap (tools.spend.cap_usd: DW_SPEND_CAP_USD, then DW_DAILY_CAP_USD, then 10)."""
    try:
        from tools.spend import cap_usd
        return float(cap_usd())
    except Exception:
        return None

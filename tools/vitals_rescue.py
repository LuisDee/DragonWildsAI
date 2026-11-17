"""A vitals rescue on ClaudeDev that holds: the dev fixtures set his bars, then the tool waits for his character SAVE.

    .venv\\Scripts\\python.exe -m tools.vitals_rescue --purpose "before job window L2"
    .venv\\Scripts\\python.exe -m tools.vitals_rescue --purpose "..." --pct 95 --timeout 420
    .venv\\Scripts\\python.exe -m tools.vitals_rescue --check            # the save's bars only, no rescue

Why (live 2026-11-17): a rescue sets his LIVE bars, but a character switch reloads him from his save
(SaveCharacters/ClaudeDev.json: GameProgress.Character Sustenance.SustenanceValue, Hydration.HydrationValue,
Health.CurrentValue), which the game rewrites only every few minutes (about 5). A switch before that rewrite loses the
rescue, and a fork (tools.quest_clone.fork) copies the old save: at 21:05Z a job window forked him that way and both
forks started unfit.

What it does, inside the live lock (tools.live_lock.held("vitals"), so no window switches the client meanwhile):
  1. the rescue, a dev-only harness fixture logged as one with its purpose (logs/bench/fixture_setup.jsonl and one
     row in logs/vitals_rescue.jsonl): set_health to full, set_stat sustenance and hydration to --pct of their max
     (evals.bench.devrun.default_dev, brain_running off: a rescue between runs, as tools.supply does);
  2. waits until the save's mtime is after the rescue AND its food, water and health are over the fit bar
     (chat_ladder.FIT_PCT, 40 %), up to --timeout. The save is only read, never written.
Exit: 0 done; 2 timeout (no save carrying the rescue in time); 3 refused by the fixtures' own guards (not the local
dev server, another player connected, the client not on ClaudeDev, the live brain running); 1 anything else.

It sets the bars, not the bag: he still carries what he carried (docs/research/2026-11-17-idle-starvation.md).
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG = ROOT / "logs" / "vitals_rescue.jsonl"
PY = r".venv\Scripts\python.exe"
COMMAND = PY + ' -m tools.vitals_rescue --purpose "<why>"'
HEALTH_MAX = 100.0  # the save holds no maxima: food and water are out of 100 (quest_clone.VITALS_START); health
SUSTENANCE_MAX = HYDRATION_MAX = 100.0  # is taken out of 100 too (a lower bar when his max is higher; the live gate
# chat_ladder.body_unfit still reads the real max once he is on)
# the fixtures' own refusals (DevTarget.guard, mod/bench/fixtures.lua guard): the rescue is not allowed here and now
REFUSALS = ("not_dev_server", "other_players_connected", "character_not_found", "no_character_guid",
            "forbidden server", "not the local dev server", "cannot tell which server", "live brain")
_now, _sleep = time.time, time.sleep


def _fit_pct() -> float:
    from tools.chat_ladder import FIT_PCT
    return FIT_PCT


def save_path(name: str | None = None) -> Path:
    from tools import quest_clone
    return quest_clone.SAVE_DIR / f"{name or quest_clone.SOURCE}.json"


def read_save(path: Path) -> dict:
    """{food, water, health, mtime} from a character save (read only). Raises OSError / ValueError / KeyError."""
    st = path.stat()
    ch = json.loads(path.read_bytes().decode("utf-8-sig"))["GameProgress"]["Character"]
    out = {"food": float(ch["Sustenance"]["SustenanceValue"]), "water": float(ch["Hydration"]["HydrationValue"]),
           "mtime": st.st_mtime}
    hp = (ch.get("Health") or {}).get("CurrentValue")
    if isinstance(hp, (int, float)):
        out["health"] = float(hp)
    return out


def _low(v: dict, pct: float) -> list[str]:
    from tools.chat_ladder import _vitals_low
    return _vitals_low({"health": v.get("health"), "max_health": HEALTH_MAX, "sustenance": v["food"],
                        "sustenance_max": SUSTENANCE_MAX, "hydration": v["water"], "hydration_max": HYDRATION_MAX}, pct)


def save_unfit(path: Path | None = None, pct: float | None = None) -> str | None:
    """Why a save is not fit to fork or to be reloaded into (a harness fault, never his), or None. Default: ClaudeDev's
    save. An unreadable save refuses too: what a fork would copy cannot be judged."""
    pct = _fit_pct() if pct is None else pct
    main = save_path()
    path = Path(path) if path is not None else main
    try:
        is_main = path.resolve() == main.resolve()
    except OSError:
        is_main = False
    who = f"{main.stem}'s save" if is_main else f"save {path.stem}"
    remedy = (f"run {COMMAND} (it rescues him and waits until his save carries it)" if is_main else
              "every fork of it starts so: take the checkpoint again from a fit run, or start from a fit save")
    try:
        v = read_save(path)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return f"{who} unread ({type(exc).__name__}: {exc})"[:200] + f"; {remedy}"
    low = _low(v, pct)
    if not low:
        return None
    return f"{who} unfit: {', '.join(low)} (under {pct:.0f} % is unfit; a fork copies the save); {remedy}"


def wait_saved(path: Path, after: float, pct: float | None = None, timeout_s: float = 420.0, poll_s: float = 5.0,
               now=None, sleep=None) -> dict:
    """Wait until `path` was written after `after` and its bars are over the bar. {ok, waited_s, save, why, timeout}."""
    pct = _fit_pct() if pct is None else pct
    now, sleep = now or _now, sleep or _sleep
    t0 = now()
    why, v = "save not read yet", None
    while True:
        try:
            v = read_save(path)
        except (OSError, ValueError, KeyError, TypeError) as exc:  # e.g. caught mid-write: read again next poll
            why = f"save unread ({type(exc).__name__})"
        else:
            if v["mtime"] <= after:
                why = f"save not rewritten since the rescue (last written {after - v['mtime']:.0f} s before it)"
            elif low := _low(v, pct):
                why = f"save rewritten but under the bar: {', '.join(low)}"
            else:
                return {"ok": True, "waited_s": round(now() - t0, 1), "save": v}
        if now() - t0 >= timeout_s:
            return {"ok": False, "timeout": True, "waited_s": round(now() - t0, 1), "save": v, "why": why}
        sleep(poll_s)


def rescue(dev, pct: float, purpose: str) -> dict:
    """The rescue itself: full health, food and water to pct % of their max, each a logged dev fixture."""
    p = f"harness rescue (vitals, {getattr(dev, 'character_name', 'ClaudeDev')}): {purpose}"
    out = {"health": dev.setup("set_health", purpose=p, pct=100).get("health")}
    for stat in ("sustenance", "hydration"):
        out[stat] = dev.setup("set_stat", purpose=p, stat=stat, pct=float(pct)).get("after")
    return out


def _log(row: dict) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, default=str) + "\n")
    except OSError:
        pass


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--purpose", help="why the rescue (logged with each fixture call); required unless --check")
    ap.add_argument("--pct", type=float, default=95.0, help="food and water set to this %% of their max")
    ap.add_argument("--timeout", type=float, default=420.0, help="seconds to wait for a save carrying the rescue")
    ap.add_argument("--poll", type=float, default=5.0)
    ap.add_argument("--lock-wait", type=float, default=1800.0)
    ap.add_argument("--check", action="store_true", help="only say whether his save is fit; no rescue")
    a = ap.parse_args(argv)
    path = save_path()
    if a.check:
        why = save_unfit(path)
        print(why or f"{path.stem}'s save fit: {read_save(path)}")
        return 0 if why is None else 1
    if not a.purpose:
        ap.error("--purpose is required: a harness rescue is logged with its purpose")
    from evals.bench.devrun import default_dev
    from tools import live_lock
    row: dict = {"t": round(_now(), 1), "harness_rescue": True, "purpose": a.purpose, "pct": a.pct, "save": str(path)}
    code = 1
    try:
        with live_lock.held("vitals", wait_s=a.lock_wait):  # no switch until the save carries the rescue
            dev = default_dev()
            dev.brain_running = lambda: False  # a rescue between runs; the fixtures' guards still apply
            try:
                dev.guard()
                row["set"] = rescue(dev, a.pct, a.purpose)
            except Exception as exc:  # noqa: BLE001  (evals.bench Abort: the guards and fixture failures)
                msg = str(exc)
                code = 3 if any(r in msg for r in REFUSALS) else 1
                row.update(ok=False, refused=code == 3, why=msg[:300])
                print(("refused: " if code == 3 else "rescue failed: ") + msg, flush=True)
            else:
                t_done = _now()
                row["rescued_at"] = round(t_done, 1)
                print(f"rescued (harness fixture, dev only): {row['set']}; waiting up to {a.timeout:.0f} s for "
                      f"{path.name} to carry it", flush=True)
                w = wait_saved(path, after=t_done, timeout_s=a.timeout, poll_s=a.poll)
                row.update(ok=w["ok"], waited_s=w["waited_s"], save_read=w.get("save"))
                if w["ok"]:
                    code = 0
                    print(f"done: {path.name} written {w['save']['mtime'] - t_done:.0f} s after the rescue, food "
                          f"{w['save']['food']:.0f}, water {w['save']['water']:.0f}", flush=True)
                else:
                    code = 2
                    row["why"] = w["why"]
                    print(f"timeout after {w['waited_s']:.0f} s: {w['why']}; a switch now would reload the old "
                          "bars", flush=True)
    except TimeoutError as exc:  # the live lock stayed busy
        row.update(ok=False, why=str(exc)[:300])
        print(f"not run: {exc}", flush=True)
    row["exit"] = code
    _log(row)
    return code


if __name__ == "__main__":
    sys.exit(main())

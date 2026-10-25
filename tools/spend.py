"""Model API spend from logged token usage x Anthropic list prices (GOAL.md section 3: $10/day hard cap).

    .venv\\Scripts\\python.exe -m tools.obs spend [--today | --day YYYY-MM-DD] [--json]
    from tools.obs import spend_today, spent_today_usd
    spend_today()        -> dict (schema dw_obs_spend/1): spent_usd, pct_of_cap, state ok|warn|cap, by_source, by_model
    spent_today_usd()    -> float, never raises (the brain's budget guard; incremental, cheap to call every 30 s)

Prices: data/model_prices.json (one shared table, filled from the official pricing page; its source and as_of travel
with every result). Day = UTC calendar day (all logs are UTC). Cap: DW_SPEND_CAP_USD, else DW_DAILY_CAP_USD, else 10.

Sources: every JSONL under the log dir whose rows carry a usage block {prompt, completion, cached, cache_write}:
  live_controller   brain-*.jsonl (brain-live-*, brain-<day>)  component controller
  director_planner  brain-live-*.jsonl                component planner / director
  generators        brain-live-*.jsonl skill_learner; evals/**/gen_*.jsonl; spend/generators*.jsonl
  evals             evals-*.jsonl, voice-eval-*.jsonl, evals/**/*.jsonl (other than gen_*), spend/evals*.jsonl
  <source>          spend/<source>*.jsonl rows {"ts", "model", "usage", "source"?}: a ledger for callers that log elsewhere
A row's model is its own "model", else the model of the last prompt record of the same component in that file, else
session_start's controller_model / planner_model. Dry-run sessions (fake models) cost nothing.

Usage semantics (brain/llm.py _usage over LiteLLM): prompt = uncached input + cache reads + cache writes (LiteLLM's
Anthropic transform adds both into prompt_tokens), cached = cache reads, cache_write = cache writes (5-minute TTL),
completion = output including thinking. A usage row with no known model is an *unpriced call*: it is still added to
spent_usd at the dearest listed rate (never under-counts against the cap) and counted in unpriced_calls.
"""
from __future__ import annotations

import json
import os
import re
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from tools.timeline import ROOT

PRICES_FILE = ROOT / "data" / "model_prices.json"
WARN_AT, CAP_AT = 0.8, 1.0
SOURCES = ("live_controller", "director_planner", "evals", "generators", "other")
COMPONENT_SOURCE = {"controller": "live_controller", "planner": "director_planner", "director": "director_planner",
                    "skill_learner": "generators", "generator": "generators"}
_HEAD = re.compile(r'^\{"ts": ([\d.]+), "kind": "([\w-]+)"(?:, "component": "([\w-]+)")?(?:, "model": "([^"]+)")?')


def load_prices(path: Path = PRICES_FILE) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def cap_usd() -> float:
    for k in ("DW_SPEND_CAP_USD", "DW_DAILY_CAP_USD"):
        try:
            if os.environ.get(k):
                return float(os.environ[k])
        except ValueError:
            pass
    return 10.0


def _model_id(model: str | None) -> str | None:
    return str(model).split("/")[-1] if model else None


def price(model: str | None, usage: dict, prices: dict) -> tuple[float, str | None]:
    """(usd, model id it was priced as or None when unknown -> priced at the dearest listed tier)."""
    models = prices["models"]
    key = _model_id(model)
    prompt = int(usage.get("prompt") or 0)
    read = int(usage.get("cached") or 0)
    write = int(usage.get("cache_write") or 0)
    out = int(usage.get("completion") or 0)
    uncached = max(0, prompt - read - write)

    def cost(r):
        return (uncached * r["input"] + write * r["cache_write_5m"] + read * r["cache_read"] + out * r["output"]) / 1e6
    if key in models:
        tier = next(t for t in models[key] if t["max_prompt"] is None or prompt <= t["max_prompt"])
        return cost(tier), key
    return max(cost(t) for tiers in models.values() for t in tiers), None


class _FileState:
    """Incremental reader of one JSONL: rows with usage (raw), plus the model context needed to price them."""

    def __init__(self, path: Path, source: str | None):
        self.path, self.source = path, source
        self.offset, self.rows = 0, []
        self.model_of: dict[str, str] = {}
        self.session: dict[str, str | None] = {}
        self.dry = False
        self.mtime = -1.0

    def update(self) -> None:
        try:
            st = self.path.stat()
        except OSError:
            return
        if st.st_size < self.offset:  # rewritten: start again
            self.__init__(self.path, self.source)
        if st.st_size == self.offset:
            return
        with self.path.open("rb") as f:
            f.seek(self.offset)
            data = f.read()
        end = data.rfind(b"\n") + 1  # only complete lines; a line being written is read next time
        self.offset += end
        for raw in data[:end].splitlines():
            line = raw.decode("utf-8", errors="replace").lstrip("﻿")
            m = _HEAD.match(line)
            if m and m.group(2) == "prompt":  # huge: only its component and model matter
                if m.group(4):
                    self.model_of[m.group(3) or "?"] = m.group(4)
                continue
            if '"usage"' not in line and '"session_start"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            if d.get("kind") == "session_start":
                self.dry = bool(d.get("dry_run"))
                self.session = {"controller": d.get("controller_model"), "planner": d.get("planner_model")}
                continue
            u = d.get("usage")
            if self.dry or not isinstance(u, dict) or not isinstance(d.get("ts"), (int, float)):
                continue
            comp = d.get("component") or "?"
            model = d.get("model") or self.model_of.get(comp) or self.session.get(comp)
            src = d.get("source") if d.get("source") in SOURCES else self.source or COMPONENT_SOURCE.get(comp, "other")
            self.rows.append({"ts": float(d["ts"]), "source": src, "model": model, "usage": u, "file": self.path.name})


_states: dict[str, _FileState] = {}


def _source_for(path: Path, logs: Path) -> str | None:
    rel = path.relative_to(logs).parts
    if rel[0] == "spend":
        stem = path.stem.split("-")[0].split("_")[0]
        return {"director": "director_planner", "live": "live_controller"}.get(stem, stem if stem in SOURCES else "other")
    if rel[0] == "evals" or path.name.startswith(("evals-", "voice-eval-")):
        return "generators" if path.name.startswith("gen_") else "evals"
    return None  # brain-live: by component


def _files(logs: Path) -> list[Path]:
    return [*logs.glob("brain-*.jsonl"), *logs.glob("evals-*.jsonl"), *logs.glob("voice-eval-*.jsonl"),
            *(logs / "evals").rglob("*.jsonl"), *(logs / "spend").glob("*.jsonl")]


def calls(logs: Path, since: float, until: float, prices: dict) -> list[dict]:
    out = []
    for p in _files(logs):
        try:
            if p.stat().st_mtime < since:  # nothing written after the window started
                continue
        except OSError:
            continue
        st = _states.get(str(p))
        if st is None:
            st = _states[str(p)] = _FileState(p, _source_for(p, logs))
        st.update()
        for r in st.rows:
            if since <= r["ts"] < until:
                usd, priced = price(r["model"], r["usage"], prices)
                out.append({**r, "usd": usd, "priced_as": priced})
    out.sort(key=lambda r: r["ts"])
    return out


def _iso(t: float | None) -> str | None:
    return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z") if t else None


def summarize(rows: list[dict], cap: float, prices: dict, label: dict) -> dict:
    def agg(rs):
        u = [r["usage"] for r in rs]
        return {"usd": round(sum(r["usd"] for r in rs), 4), "calls": len(rs),
                "prompt": sum(int(x.get("prompt") or 0) for x in u), "completion": sum(int(x.get("completion") or 0) for x in u),
                "cached": sum(int(x.get("cached") or 0) for x in u), "cache_write": sum(int(x.get("cache_write") or 0) for x in u)}
    total = sum(r["usd"] for r in rows)
    run, warn_at, cap_at = 0.0, None, None
    for r in rows:
        run += r["usd"]
        if warn_at is None and cap and run >= WARN_AT * cap:
            warn_at = r["ts"]
        if cap_at is None and cap and run >= CAP_AT * cap:
            cap_at = r["ts"]
    models = sorted({str(r["model"]) for r in rows if r["priced_as"]})
    return {"schema": "dw_obs_spend/1", **label, "generated_at": _iso(time.time()), "cap_usd": cap,
            "spent_usd": round(total, 4), "calls": len(rows), "pct_of_cap": round(100 * total / cap, 1) if cap else None,
            "state": "cap" if cap and total >= CAP_AT * cap else "warn" if cap and total >= WARN_AT * cap else "ok",
            "warn_crossed_at": _iso(warn_at), "cap_crossed_at": _iso(cap_at),
            "by_source": {s: agg([r for r in rows if r["source"] == s]) for s in SOURCES},
            "by_model": {m: agg([r for r in rows if str(r["model"]) == m]) for m in models},
            "unpriced_calls": sum(1 for r in rows if not r["priced_as"]),
            "unpriced_files": sorted({r["file"] for r in rows if not r["priced_as"]}),
            "prices": {"source": prices.get("source"), "as_of": prices.get("as_of"), "file": "data/model_prices.json"}}


def spend_day(day: date, log_dir: Path | None = None, cap: float | None = None) -> dict:
    start = datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc).timestamp()
    prices = load_prices()
    cap = cap_usd() if cap is None else cap
    return summarize(calls(Path(log_dir) if log_dir else ROOT / "logs", start, start + 86400, prices), cap, prices,
                     {"day": day.isoformat(), "tz": "UTC"})


def spend_today(log_dir: Path | None = None, cap: float | None = None, now: float | None = None) -> dict:
    """Today's (UTC) spend across every source; JSON-ready (schema dw_obs_spend/1)."""
    day = datetime.fromtimestamp(time.time() if now is None else now, timezone.utc).date()
    return spend_day(day, log_dir, cap)


def spent_today_usd(log_dir: Path | None = None) -> float:
    """USD spent so far this UTC day by every model call we log (the cap is global). Never raises: 0.0 on any error."""
    try:
        return float(spend_today(log_dir)["spent_usd"])
    except Exception:
        return 0.0


def spend_window(log_dir: Path, since: float, until: float, cap: float | None = None) -> dict:
    prices = load_prices()
    cap = cap_usd() if cap is None else cap
    return summarize(calls(log_dir, since, until, prices), cap, prices, {"since": _iso(since), "until": _iso(until), "tz": "UTC"})


def days_between(since: float, until: float) -> list[date]:
    d0 = datetime.fromtimestamp(since, timezone.utc).date()
    d1 = datetime.fromtimestamp(until, timezone.utc).date()
    return [d0 + timedelta(days=i) for i in range((d1 - d0).days + 1)]


def render(s: dict) -> str:
    head = s.get("day") or f"{s.get('since')} .. {s.get('until')}"
    out = [f"spend {head} (UTC): ${s['spent_usd']:.4f} of ${s['cap_usd']:.2f} cap ({s['pct_of_cap']}%), {s['calls']} calls"
           f" -> {s['state'].upper()}"]
    for k, v in s["by_source"].items():
        if v["calls"]:
            out.append(f"  {k:<17} ${v['usd']:.4f}  {v['calls']} calls  prompt {v['prompt']} (cache read {v['cached']},"
                       f" write {v['cache_write']})  out {v['completion']}")
    for k, v in s["by_model"].items():
        out.append(f"  model {k:<28} ${v['usd']:.4f}  {v['calls']} calls")
    if s["unpriced_calls"]:
        out.append(f"  {s['unpriced_calls']} calls logged no model ({', '.join(s['unpriced_files'][:4])}): "
                   "counted at the dearest listed rate")
    if s.get("warn_crossed_at"):
        out.append(f"  80% crossed at {s['warn_crossed_at']}" + (f"; cap crossed at {s['cap_crossed_at']}" if s.get("cap_crossed_at") else ""))
    out.append(f"  prices: {s['prices']['source']} (as of {s['prices']['as_of']})")
    return "\n".join(out)

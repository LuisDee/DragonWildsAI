"""Model API spend from logged token usage x Anthropic list prices (GOAL.md section 3: $10/day hard cap).

    .venv\\Scripts\\python.exe -m tools.obs spend [--today | --day YYYY-MM-DD] [--json]
    from tools.spend import spend_today
    spend_today()   -> dict (schema dw_obs_spend/1): spent_usd, pct_of_cap, state ok|warn|cap, by_source, by_model
                       (brain/budget.py calls it every 30 s and fails closed on an error)

Prices: data/model_prices.json (one shared table, filled from the official pricing page; its source and as_of travel
with every result). Day = UTC calendar day (all logs are UTC). Cap: DW_SPEND_CAP_USD, else DW_DAILY_CAP_USD, else 10.

Sources: every JSONL under the log dir (brain/paths.py log_dir) whose rows carry a usage block
{prompt, completion, cached, cache_write}:
  live_controller   brain-*.jsonl (brain-live-*, brain-<day>)  component controller
  director_planner  brain-*.jsonl                     component planner / director
  generators        brain-*.jsonl skill_learner; evals/**/gen_*.jsonl; spend/generators*.jsonl
  evals             evals-*.jsonl, voice-eval-*.jsonl, evals/**/*.jsonl (other than gen_*), spend/evals*.jsonl
  <source>          spend/<source>*.jsonl rows {"ts", "model", "usage", "source"?}: a ledger for callers that log elsewhere
A row's model is its own "model", else the model of the last prompt record of the same component in that file, else
session_start's controller_model / planner_model. Dry-run sessions (fake models) cost nothing.

Usage semantics (brain/llm.py _usage over LiteLLM): prompt = uncached input + cache reads + cache writes (LiteLLM's
Anthropic transform adds both into prompt_tokens), cached = cache reads, cache_write = cache writes (5-minute TTL),
completion = output including thinking. A usage row with no known model is an *unpriced call*: it is still added to
spent_usd at the dearest listed rate (never under-counts against the cap) and counted in unpriced_calls.

Cost of a call: files are read incrementally (byte offsets; prompt lines are matched on bytes and skipped); the
logs/evals tree (thousands of bench work dirs) is indexed once and a directory is re-listed only when its own mtime
changes, with a full mtime sweep at most every RESCAN_S. Rows older than yesterday 00:00 UTC are dropped from memory
(a request for an older day re-reads that file).
"""
from __future__ import annotations

import json
import os
import re
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from brain import paths

PRICES_FILE = paths.REPO_ROOT / "data" / "model_prices.json"
WARN_AT, CAP_AT = 0.8, 1.0
RESCAN_S = 60.0
SOURCES = ("live_controller", "director_planner", "evals", "generators", "other")
COMPONENT_SOURCE = {"controller": "live_controller", "planner": "director_planner", "director": "director_planner",
                    "skill_learner": "generators", "generator": "generators"}
_HEAD = re.compile(rb'^\{"ts": ([\d.]+), "kind": "([\w-]+)"(?:, "component": "([\w-]+)")?(?:, "model": "([^"]+)")?')


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


def _iso(t: float | None) -> str | None:
    return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z") if t else None


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
        self.floor = 0.0  # rows before this were evicted

    def update(self, keep_from: float) -> None:
        try:
            size = self.path.stat().st_size
        except OSError:
            return
        if size < self.offset or keep_from < self.floor:  # rewritten, or an older day is asked for: read again
            self.__init__(self.path, self.source)
        if size > self.offset:
            with self.path.open("rb") as f:
                f.seek(self.offset)
                data = f.read(size - self.offset)
            end = data.rfind(b"\n") + 1  # only complete lines; a line being written is read next time
            self.offset += end
            for raw in data[:end].splitlines():
                self._line(raw.lstrip(b"\xef\xbb\xbf"))
        if keep_from > self.floor:
            self.rows = [r for r in self.rows if r["ts"] >= keep_from]
            self.floor = keep_from

    def _line(self, raw: bytes) -> None:
        m = _HEAD.match(raw)
        if m and m.group(2) == b"prompt":  # huge: only its component and model matter
            if m.group(4):
                self.model_of[(m.group(3) or b"?").decode()] = m.group(4).decode()
            return
        if b'"usage"' not in raw and b'"session_start"' not in raw:
            return
        try:
            d = json.loads(raw.decode("utf-8", errors="replace"))
        except ValueError:
            return
        if not isinstance(d, dict):
            return
        if d.get("kind") == "session_start":
            self.dry = bool(d.get("dry_run"))
            self.session = {"controller": d.get("controller_model"), "planner": d.get("planner_model")}
            return
        u = d.get("usage")
        if self.dry or not isinstance(u, dict) or not isinstance(d.get("ts"), (int, float)):
            return
        comp = d.get("component") or "?"
        model = d.get("model") or self.model_of.get(comp) or self.session.get(comp)
        src = d.get("source") if d.get("source") in SOURCES else self.source or COMPONENT_SOURCE.get(comp, "other")
        self.rows.append({"ts": float(d["ts"]), "source": src, "model": model, "usage": u, "file": self.path.name})


class _DirIndex:
    """The .jsonl files under one directory tree. A directory is re-listed only when its own mtime changed (a file or
    folder was added or removed in it); the mtime sweep over the tree runs at most every RESCAN_S."""

    def __init__(self, root: Path):
        self.root = root
        self.dirs: dict[str, tuple[int, list[str], list[str]]] = {}  # dir -> (mtime_ns, jsonl files, subdirs)
        self.swept = -1e18

    def files(self, now: float | None = None) -> list[Path]:
        now = time.time() if now is None else now
        if now - self.swept >= RESCAN_S:
            self.swept = now
            self._sweep(str(self.root))
        return [Path(d, f) for d, (_, fs, _) in self.dirs.items() for f in fs]

    def _sweep(self, top: str) -> None:
        seen, stack = set(), [top]
        while stack:
            d = stack.pop()
            try:
                mt = os.stat(d).st_mtime_ns
            except OSError:
                continue
            seen.add(d)
            cached = self.dirs.get(d)
            if cached is None or cached[0] != mt:
                fs, subs = [], []
                try:
                    with os.scandir(d) as it:
                        for e in it:
                            if e.is_dir(follow_symlinks=False):
                                subs.append(e.path)
                            elif e.name.endswith(".jsonl"):
                                fs.append(e.name)
                except OSError:
                    continue
                cached = self.dirs[d] = (mt, fs, subs)
            stack.extend(cached[2])
        for gone in set(self.dirs) - seen:
            del self.dirs[gone]


_states: dict[str, _FileState] = {}
_indexes: dict[str, _DirIndex] = {}


def _source_for(path: Path, logs: Path) -> str | None:
    rel = path.relative_to(logs).parts
    if rel[0] == "spend":
        stem = path.stem.split("-")[0].split("_")[0]
        return {"director": "director_planner", "live": "live_controller"}.get(stem, stem if stem in SOURCES else "other")
    if rel[0] == "evals" or path.name.startswith(("evals-", "voice-eval-")):
        return "generators" if path.name.startswith("gen_") else "evals"
    return None  # brain logs: by component


def _files(logs: Path) -> list[Path]:
    idx = _indexes.get(str(logs / "evals"))
    if idx is None:
        idx = _indexes[str(logs / "evals")] = _DirIndex(logs / "evals")
    return [*logs.glob("brain-*.jsonl"), *logs.glob("evals-*.jsonl"), *logs.glob("voice-eval-*.jsonl"),
            *idx.files(), *(logs / "spend").glob("*.jsonl")]


def _keep_from(since: float) -> float:
    yesterday = datetime.combine(datetime.now(timezone.utc).date() - timedelta(days=1), datetime.min.time(),
                                 tzinfo=timezone.utc).timestamp()
    return min(since, yesterday)


def calls(logs: Path, since: float, until: float, prices: dict, files: list[Path] | None = None) -> list[dict]:
    """Priced usage rows in [since, until). ``files``: a list from ``_files`` the caller already has."""
    out = []
    keep = _keep_from(since)
    for p in files if files is not None else _files(logs):
        try:
            if p.stat().st_mtime < since:  # nothing written after the window started
                continue
        except OSError:
            continue
        st = _states.get(str(p))
        if st is None:
            st = _states[str(p)] = _FileState(p, _source_for(p, logs))
        st.update(keep)
        for r in st.rows:
            if since <= r["ts"] < until:
                usd, priced = price(r["model"], r["usage"], prices)
                out.append({**r, "usd": usd, "priced_as": priced})
    out.sort(key=lambda r: r["ts"])
    return out


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


def spend_day(day: date, log_dir: Path | None = None, cap: float | None = None, files: list[Path] | None = None) -> dict:
    start = datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc).timestamp()
    prices = load_prices()
    cap = cap_usd() if cap is None else cap
    logs = Path(log_dir) if log_dir else paths.log_dir()
    return summarize(calls(logs, start, start + 86400, prices, files), cap, prices, {"day": day.isoformat(), "tz": "UTC"})


def spend_today(log_dir: Path | None = None, cap: float | None = None, now: float | None = None) -> dict:
    """Today's (UTC) spend across every source; JSON-ready (schema dw_obs_spend/1)."""
    day = datetime.fromtimestamp(time.time() if now is None else now, timezone.utc).date()
    return spend_day(day, log_dir, cap)


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

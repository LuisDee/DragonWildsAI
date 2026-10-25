"""Is the long-running goal met? (docs/GOAL.md §1/§1b, docs/goal_targets.json). Built for Claude Code's /goal, whose
evaluator only reads the transcript: completion has to be provable from this command's output.

  .venv\\Scripts\\python.exe -m tools.goal_check --all           # a table per milestone M1-M4 (also the default)
  .venv\\Scripts\\python.exe -m tools.goal_check --milestone M1  # one milestone
  .venv\\Scripts\\python.exe -m tools.goal_check --json          # results as JSON (the last line stays the verdict)

One row per target: MET | NOT MET | NO DATA, the measured value, the run id and its age. The LAST line is exactly:
- --milestone Mn: "MILESTONE Mn MET" or "MILESTONE Mn NOT MET (x/y)" (x targets met of y);
- --all:          "GOAL MET" (all four milestones met) or "GOAL NOT MET (M1 x/y, M2 x/y, M3 x/y, M4 x/y, focus=Mn)",
                  focus = the first milestone not met.
Exit 0 only for MET.

Confirmation re-run: a milestone counts as MET only when every target is met now AND the previous check of that
milestone on DIFFERENT data (new benchmark runs or a new obs window: the fingerprint) was fresh and also all met, i.e.
two consecutive fresh runs pass. Every check is appended to logs/evals/goal_checks.jsonl for this (--no-record: don't).

Sources (all optional; missing = NO DATA = not met):
- logs/evals/scoreboard.jsonl   one row per benchmark run (evals.bench runner; schema dw_scoreboard/1, below) and
                                 per voice-eval ingest (kind "voice")
- logs/evals/validity.json      the eval of the eval: per case hash, the positive control (oracle) and the two
                                 negative controls (do_nothing, claims_only)
- tools/obs.py metrics --json   latency, anomalies, stability, deaths (observability agent; dw_obs_metrics/1)

Strictness (GOAL.md §3, §4.3), every one of these makes a target NOT MET:
- data older than --max-age-h (24 h);
- benchmark results measured only on the mock (a target counts dev or live runs only);
- no live confirmation: a benchmark-family target also needs >= 1 valid passing case of that family in a LIVE run
  inside the window; long tasks need a live pass (live_confirmed_required) and a dev pass within the hint limit;
- a case whose predicate is not valid: it counts only if its positive control passed on the dev world or live and
  BOTH negative controls failed (a negative control that passes, or evaluates null, invalidates the case).

Scoreboard row (dw_scoreboard/1, kind "bench"):
  {schema, kind, run_id, at (UTC ISO), target: mock|dev|live, agent, git_sha, models, report,
   cases: [{id, case_hash, family, tier, heldout, result: pass|fail|unverifiable|skip|error, hints,
            long_task?: <goal_targets long_tasks id>, basic?: <combat_basics_live_proven id>}],
   metrics: {<metric>: {value, n}, damage_taken_trend: {fights, slope, decreasing}, ...}, calls, cost_usd}
Families: spell_cast, spell_use, craft, combat, combat_basic, tactics_prep, adversarial, knowledge, long_task, ...
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ROOT / "docs" / "goal_targets.json"
SCOREBOARD = ROOT / "logs" / "evals" / "scoreboard.jsonl"
VALIDITY = ROOT / "logs" / "evals" / "validity.json"
HISTORY = ROOT / "logs" / "evals" / "goal_checks.jsonl"
MAX_AGE_H = 24.0
MET, NOT_MET, NO_DATA = "MET", "NOT MET", "NO DATA"
COUNTED = ("pass", "fail", "unverifiable", "error")  # skip (precondition not met) is not counted
BENCH_TARGETS = ("dev", "live")

# target key in goal_targets.json -> the benchmark case family it is measured on
FAMILY_TARGETS = {
    "spells_effect_coverage_pct": "spell_cast",
    "spell_use_cases_pct": "spell_use",
    "craft_from_scratch_pct": "craft",
    "combat_cases_pct": "combat",
    "adversarial_cases_pct": "adversarial",
}
# scoreboard metrics (value, n) with a minimum
METRIC_TARGETS = {
    "ranged_hit_rate_15m_moving_pct": "ranged_hit_rate_15m_moving_pct",
    "efficiency_vs_baseline_pct": "efficiency_vs_baseline_pct",
}


@dataclass
class Row:
    target: str
    status: str
    value: str = "-"
    want: str = ""
    source: str = "-"
    age_h: float | None = None
    note: str = ""

    def line(self) -> str:
        age = f"{self.age_h:.1f}h" if self.age_h is not None else "-"
        note = f"  ({self.note})" if self.note else ""
        return f"[{self.status:<7}] {self.target:<44} {self.value:<28} want {self.want:<14} {self.source}  age {age}{note}"


@dataclass
class Data:
    targets: dict
    rows: list[dict]
    validity: dict
    obs: dict | None
    now: datetime
    max_age_h: float = MAX_AGE_H
    validity_summary: dict = field(default_factory=dict)


# ------------------------------------------------------------------ loading


def parse_ts(s: Any) -> datetime | None:
    if not isinstance(s, str) or not s:
        return None
    try:
        t = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def read_jsonl(path: Path) -> list[dict]:
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    out.append(r)
    except OSError:
        pass
    return out


def read_json(path: Path) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def run_obs(since_h: float) -> dict | None:
    if not (ROOT / "tools" / "obs.py").exists():
        return None
    try:
        p = subprocess.run([sys.executable, "-m", "tools.obs", "metrics", "--json", "--since", f"{since_h:g}h"],
                           cwd=ROOT, capture_output=True, text=True, timeout=180, encoding="utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    try:
        return json.loads(p.stdout.strip().splitlines()[-1] if "\n" in p.stdout.strip() else p.stdout)
    except (ValueError, IndexError):
        try:
            return json.loads(p.stdout)
        except ValueError:
            return None


def age_h(d: Data, ts: Any) -> float | None:
    t = parse_ts(ts)
    return None if t is None else max(0.0, (d.now - t).total_seconds() / 3600.0)


def fresh(d: Data, ts: Any) -> bool:
    a = age_h(d, ts)
    return a is not None and a <= d.max_age_h


# ------------------------------------------------------------------ validity (the eval of the eval)


def case_valid(d: Data, case: dict) -> tuple[bool, str]:
    v = d.validity.get(str(case.get("case_hash"))) if isinstance(d.validity, dict) else None
    if not isinstance(v, dict):
        return False, "no controls run"
    pos = v.get("positive") or {}
    if pos.get("result") != "pass":
        return False, "positive control did not pass"
    if pos.get("target") not in BENCH_TARGETS:
        return False, "positive control only on the mock"
    for neg in d.targets.get("eval_validity", {}).get("negative_controls", ["do_nothing", "claims_only"]):
        if (v.get(neg) or {}).get("result") != "fail":
            return False, f"negative control {neg} did not fail"
    return True, ""


def validity_summary(d: Data) -> dict:
    seen: dict[str, dict] = {}
    for r in d.rows:
        if r.get("kind", "bench") == "bench":
            for c in r.get("cases") or []:
                if isinstance(c, dict) and c.get("case_hash"):
                    seen[str(c["case_hash"])] = c
    why: dict[str, int] = {}
    valid = 0
    for c in seen.values():
        ok, reason = case_valid(d, c)
        valid += ok
        if not ok:
            why[reason] = why.get(reason, 0) + 1
    n = len(seen)
    return {"cases": n, "valid": valid, "pct": round(100.0 * valid / n, 1) if n else None, "invalid_reasons": why}


# ------------------------------------------------------------------ benchmark rows


def bench_rows(d: Data, targets: tuple[str, ...] = BENCH_TARGETS) -> list[dict]:
    """Benchmark runs on the given targets inside the window, newest first."""
    rows = [r for r in d.rows if r.get("kind", "bench") == "bench" and r.get("target") in targets and fresh(d, r.get("at"))]
    return sorted(rows, key=lambda r: parse_ts(r.get("at")) or d.now, reverse=True)


def family_cases(d: Data, row: dict, family: str) -> list[dict]:
    return [c for c in row.get("cases") or [] if isinstance(c, dict) and c.get("family") == family
            and c.get("result") in COUNTED and case_valid(d, c)[0]]


def pct(cases: list[dict]) -> float | None:
    return 100.0 * sum(c.get("result") == "pass" for c in cases) / len(cases) if cases else None


def live_confirmed(d: Data, pred: Callable[[dict], bool]) -> dict | None:
    for r in bench_rows(d, ("live",)):
        if any(isinstance(c, dict) and pred(c) and c.get("result") == "pass" and case_valid(d, c)[0]
               for c in r.get("cases") or []):
            return r
    return None


def stale_or_missing(d: Data, name: str, want: str, kind_targets=BENCH_TARGETS, has=lambda r: True) -> Row:
    """The NO DATA / stale row for a benchmark target: says which (an old row exists, or only mock rows)."""
    older = [r for r in d.rows if r.get("kind", "bench") == "bench" and has(r)]
    if any(r.get("target") in kind_targets for r in older):
        newest = max((r for r in older if r.get("target") in kind_targets), key=lambda r: parse_ts(r.get("at")) or d.now)
        return Row(name, NOT_MET, "-", want, str(newest.get("run_id")), age_h(d, newest.get("at")),
                   f"stale: older than {d.max_age_h:g} h")
    if any(r.get("target") == "mock" for r in older):
        return Row(name, NOT_MET, "-", want, "mock only", None, "measured only on the mock (needs dev or live)")
    return Row(name, NO_DATA, "-", want, "-", None, "no valid case measured")


def family_target(d: Data, name: str, family: str, want_v: float | None = None) -> Row:
    want_v = float(d.targets[name] if want_v is None else want_v)
    want = f">= {want_v:g}%"
    for r in bench_rows(d):
        cases = family_cases(d, r, family)
        if not cases:
            continue
        v = pct(cases)
        n_pass = sum(c["result"] == "pass" for c in cases)
        value = f"{v:.1f}% ({n_pass}/{len(cases)})"
        live = live_confirmed(d, lambda c: c.get("family") == family)
        if live is None:
            return Row(name, NOT_MET, value, want, str(r.get("run_id")), age_h(d, r.get("at")), "no live confirmation")
        return Row(name, MET if v >= want_v else NOT_MET, value, want, str(r.get("run_id")), age_h(d, r.get("at")),
                   f"live-confirmed by {live.get('run_id')}")
    return stale_or_missing(d, name, want, has=lambda r: any(isinstance(c, dict) and c.get("family") == family
                                                             for c in r.get("cases") or []))


def metric_value(d: Data, metric: str) -> tuple[dict, dict] | None:
    """(row, {value, n}) of the newest fresh dev/live run that measured the metric (n > 0)."""
    for r in bench_rows(d):
        m = (r.get("metrics") or {}).get(metric)
        if isinstance(m, dict) and isinstance(m.get("value"), (int, float)) and (m.get("n") or 0) > 0:
            return r, m
    return None


def metric_target(d: Data, name: str, metric: str, want_v: float, at_most: bool = False, unit: str = "%") -> Row:
    want = f"{'<=' if at_most else '>='} {want_v:g}{unit}"
    got = metric_value(d, metric)
    if got is None:
        return stale_or_missing(d, name, want, has=lambda r: metric in (r.get("metrics") or {}))
    r, m = got
    v = float(m["value"])
    ok = v <= want_v if at_most else v >= want_v
    return Row(name, MET if ok else NOT_MET, f"{v:.1f}{unit} (n={m['n']})", want, str(r.get("run_id")),
               age_h(d, r.get("at")))


def long_task(d: Data, tid: str) -> Row:
    cfg = d.targets.get("long_tasks") or {}
    max_hints = int(cfg.get("dev_world_max_hints", 1))
    name = f"long_tasks:{tid}"
    want = f"dev pass <= {max_hints} hint" + ("; live" if cfg.get("live_confirmed_required", True) else "")

    def mine(c):
        return isinstance(c, dict) and c.get("long_task") == tid and case_valid(d, c)[0]
    dev = next(((r, c) for r in bench_rows(d, ("dev",)) for c in r.get("cases") or []
                if mine(c) and c.get("result") == "pass" and int(c.get("hints") or 0) <= max_hints), None)
    live = next(((r, c) for r in bench_rows(d, ("live",)) for c in r.get("cases") or []
                 if mine(c) and c.get("result") == "pass"), None)
    if dev is None and live is None:
        last = next(((r, c) for r in bench_rows(d) for c in r.get("cases") or [] if mine(c)), None)
        if last:
            r, c = last
            return Row(name, NOT_MET, f"{c.get('result')} ({c.get('hints', 0)} hints)", want, str(r.get("run_id")),
                       age_h(d, r.get("at")))
        return stale_or_missing(d, name, want, has=lambda r: any(isinstance(c, dict) and c.get("long_task") == tid
                                                                 for c in r.get("cases") or []))
    if dev is None:
        r, c = live
        return Row(name, NOT_MET, "live pass", want, str(r.get("run_id")), age_h(d, r.get("at")),
                   f"no dev-world pass with <= {max_hints} hint")
    r, c = dev
    if cfg.get("live_confirmed_required", True) and live is None:
        return Row(name, NOT_MET, f"dev pass ({c.get('hints', 0)} hints)", want, str(r.get("run_id")),
                   age_h(d, r.get("at")), "no live confirmation")
    note = f"live {live[0].get('run_id')}" if live else ""
    return Row(name, MET, f"dev pass ({c.get('hints', 0)} hints)", want, str(r.get("run_id")), age_h(d, r.get("at")), note)


def combat_basic(d: Data, basic: str) -> Row:
    name = f"combat_basics_live_proven:{basic}"
    r = live_confirmed(d, lambda c: c.get("basic") == basic)
    if r is None:
        return stale_or_missing(d, name, "live pass", ("live",),
                                has=lambda r: any(isinstance(c, dict) and c.get("basic") == basic for c in r.get("cases") or []))
    return Row(name, MET, "live pass", "live pass", str(r.get("run_id")), age_h(d, r.get("at")))


def heldout_gap(d: Data, name: str) -> Row:
    want_v = float(d.targets[name])
    want = f"<= {want_v:g} pts"
    for r in bench_rows(d):
        cases = [c for c in r.get("cases") or [] if isinstance(c, dict) and c.get("result") in COUNTED
                 and case_valid(d, c)[0]]
        seen = [c for c in cases if not c.get("heldout")]
        held = [c for c in cases if c.get("heldout")]
        if seen and held:
            gap = abs(pct(seen) - pct(held))
            return Row(name, MET if gap <= want_v else NOT_MET,
                       f"{gap:.1f} pts (seen {pct(seen):.0f}% n={len(seen)}, held {pct(held):.0f}% n={len(held)})",
                       want, str(r.get("run_id")), age_h(d, r.get("at")))
    return stale_or_missing(d, name, want, has=lambda r: any(isinstance(c, dict) and c.get("heldout")
                                                             for c in r.get("cases") or []))


def tactics(d: Data) -> list[Row]:
    cfg = d.targets.get("combat_tactics") or {}
    out = []
    if "prep_before_hard_fight_pct" in cfg:
        out.append(family_target(d, "combat_tactics:prep_before_hard_fight_pct", "tactics_prep",
                                 float(cfg["prep_before_hard_fight_pct"])))
    if "telegraph_dodge_success_pct" in cfg:
        out.append(metric_target(d, "combat_tactics:telegraph_dodge_success_pct", "telegraph_dodge_success_pct",
                                 float(cfg["telegraph_dodge_success_pct"])))
    if "damage_taken_trend" in cfg:
        name, want = "combat_tactics:damage_taken_trend", str(cfg["damage_taken_trend"])
        need = next((int(w) for w in want.split() if w.isdigit()), 5)
        got = next(((r, (r.get("metrics") or {}).get("damage_taken_trend")) for r in bench_rows(d)
                    if isinstance((r.get("metrics") or {}).get("damage_taken_trend"), dict)), None)
        if got is None:
            out.append(stale_or_missing(d, name, f"falling over {need}",
                                        has=lambda r: "damage_taken_trend" in (r.get("metrics") or {})))
        else:
            r, m = got
            fights, dec = int(m.get("fights") or 0), bool(m.get("decreasing"))
            ok = fights >= need and dec
            out.append(Row(name, MET if ok else NOT_MET, f"{fights} fights, slope {m.get('slope')}", f"falling over {need}",
                           str(r.get("run_id")), age_h(d, r.get("at")), "" if fights >= need else f"needs {need} fights"))
    return out


def knowledge(d: Data) -> list[Row]:
    cfg = d.targets.get("knowledge_use") or {}
    out = []
    for key, v in cfg.items():
        at_most = key.endswith("_max")
        metric = key[:-4] if at_most else key
        out.append(metric_target(d, f"knowledge_use:{key}", f"knowledge_{metric}", float(v), at_most=at_most))
    return out


# ------------------------------------------------------------------ observability (tools/obs.py)


def obs_row(d: Data, name: str, value_of: Callable[[dict], Any], want_v: float, at_most: bool, unit: str,
            n_of: Callable[[dict], Any] | None = None) -> Row:
    want = f"{'<=' if at_most else '>='} {want_v:g}{unit}"
    o = d.obs
    if not isinstance(o, dict):
        return Row(name, NO_DATA, "-", want, "obs", None, "tools/obs.py metrics gave nothing")
    ts = (o.get("window") or {}).get("until") or o.get("generated_at")
    a = age_h(d, ts)
    src = f"obs {o.get('source') or '?'}"
    try:
        v = value_of(o)
    except (AttributeError, KeyError, TypeError):
        v = None
    n = n_of(o) if n_of else o.get("hours_observed")
    if v is None or not isinstance(v, (int, float)) or not n:
        return Row(name, NO_DATA, "-", want, src, a, "no data in the window")
    if a is None or a > d.max_age_h:
        return Row(name, NOT_MET, f"{v:g}{unit}", want, src, a, f"stale: older than {d.max_age_h:g} h")
    ok = v <= want_v if at_most else v >= want_v
    return Row(name, MET if ok else NOT_MET, f"{v:g}{unit}", want, src, a)


def voice(d: Data, name: str) -> Row:
    want_v = float(d.targets[name])
    want = f">= {want_v:g}"
    rows = sorted([r for r in d.rows if r.get("kind") == "voice" and isinstance(r.get("score"), (int, float))
                   and (r.get("n") or 0) > 0], key=lambda r: parse_ts(r.get("at")) or d.now, reverse=True)
    if not rows:
        o = d.obs if isinstance(d.obs, dict) else {}
        vs = (o.get("voice") or {}) if isinstance(o.get("voice"), dict) else {}
        if isinstance(vs.get("score"), (int, float)) and (vs.get("n") or 0) > 0:
            return obs_row(d, name, lambda o: o["voice"]["score"], want_v, False, "", lambda o: o["voice"]["n"])
        return Row(name, NO_DATA, "-", want, "-", None, "no voice-eval score")
    r = rows[0]
    if not fresh(d, r.get("at")):
        return Row(name, NOT_MET, f"{r['score']:.2f}", want, str(r.get("run_id")), age_h(d, r.get("at")),
                   f"stale: older than {d.max_age_h:g} h")
    return Row(name, MET if r["score"] >= want_v else NOT_MET, f"{r['score']:.2f} (n={r['n']})", want,
               str(r.get("run_id")), age_h(d, r.get("at")))


# ------------------------------------------------------------------ the target registry


def rows_for(d: Data, key: str) -> list[Row]:
    t = d.targets
    if key.startswith("long_tasks:"):
        return [long_task(d, key.split(":", 1)[1])]
    if key in FAMILY_TARGETS:
        return [family_target(d, key, FAMILY_TARGETS[key])]
    if key in METRIC_TARGETS:
        return [metric_target(d, key, METRIC_TARGETS[key], float(t[key]))]
    if key == "long_tasks":
        return [long_task(d, x) for x in (t.get("long_tasks") or {}).get("required", [])]
    if key == "combat_basics_live_proven":
        return [combat_basic(d, b) for b in t.get(key) or []]
    if key == "combat_tactics":
        return tactics(d)
    if key == "knowledge_use":
        return knowledge(d)
    if key == "heldout_gap_max_points":
        return [heldout_gap(d, key)]
    if key == "latency_chat_to_action_p50_s":
        return [obs_row(d, key, lambda o: o["latency"]["chat_to_first_action_s"]["p50"], float(t[key]), True, " s",
                        lambda o: o["latency"]["chat_to_first_action_s"]["n"])]
    if key == "latency_chat_to_action_p90_s":
        return [obs_row(d, key, lambda o: o["latency"]["chat_to_first_action_s"]["p90"], float(t[key]), True, " s",
                        lambda o: o["latency"]["chat_to_first_action_s"]["n"])]
    if key == "voice_score_min":
        return [voice(d, key)]
    if key == "anomalies_per_hour_max":
        return [obs_row(d, f"{key}:{a}", lambda o, a=a: o["anomalies_per_hour"][a], float(v), True, "/h")
                for a, v in (t.get(key) or {}).items()]
    if key == "stability_hours_without_crash":
        return [obs_row(d, key, lambda o: o["stability"]["longest_run_without_crash_h"], float(t[key]), False, " h")]
    if key == "no_starvation_deaths":
        return [obs_row(d, key, lambda o: (o.get("deaths") or {}).get("starvation"), float(t[key]), True, "")]
    return [Row(key, NO_DATA, "-", str(t.get(key)), "-", None, "goal_check has no measurement for this target yet")]


def milestones(targets: dict) -> dict[str, list[str]]:
    return {k: list(v) for k, v in (targets.get("milestones") or {}).items()}


def check(d: Data, milestone: str) -> tuple[list[Row], dict]:
    """The rows of one milestone's targets (each target key may give several rows)."""
    ms = milestones(d.targets)
    if milestone not in ms:
        raise SystemExit(f"unknown milestone {milestone!r}; have {', '.join(ms) or 'none'}")
    d.validity_summary = validity_summary(d)
    rows: list[Row] = []
    for k in ms[milestone]:
        rows += rows_for(d, k)
    return rows, d.validity_summary


def score(rows: list[Row]) -> tuple[int, int]:
    return sum(r.status == MET for r in rows), len(rows)


# ------------------------------------------------------------------ confirmation re-run (two consecutive fresh runs)


def fingerprint(d: Data) -> str:
    """What data this check saw: the fresh run ids plus the obs window end. A confirmation needs NEW data, not the
    same results checked twice."""
    ids = sorted(str(r.get("run_id")) for r in d.rows if fresh(d, r.get("at")))
    o = d.obs if isinstance(d.obs, dict) else {}
    return json.dumps([ids, (o.get("window") or {}).get("until") or o.get("generated_at")])


def confirmed(d: Data, history: list[dict], milestone: str, fp: str) -> dict | None:
    """The previous check of this milestone on different data, if it was fresh and all-met; else None.
    Consecutive: the most recent earlier record with a different fingerprint decides."""
    prev = [h for h in history if h.get("milestone") == milestone and h.get("fingerprint") != fp
            and (parse_ts(h.get("at")) or d.now) < d.now]
    if not prev:
        return None
    last = max(prev, key=lambda h: parse_ts(h.get("at")) or d.now)
    return last if last.get("all_met") and fresh(d, last.get("at")) else None


def evaluate_milestones(d: Data, names: list[str], history: list[dict]) -> list[dict]:
    fp = fingerprint(d)
    out = []
    for m in names:
        rows, _ = check(d, m)
        n, total = score(rows)
        all_met = total > 0 and n == total
        conf = confirmed(d, history, m, fp) if all_met else None
        out.append({"milestone": m, "rows": rows, "met": n, "total": total, "all_met": all_met,
                    "confirmed_by": conf.get("at") if conf else None, "milestone_met": bool(all_met and conf),
                    "fingerprint": fp})
    return out


def milestone_line(res: dict) -> str:
    m = res["milestone"]
    return f"MILESTONE {m} MET" if res["milestone_met"] else f"MILESTONE {m} NOT MET ({res['met']}/{res['total']})"


def goal_line(results: list[dict]) -> str:
    if results and all(r["milestone_met"] for r in results):
        return "GOAL MET"
    parts = ", ".join(f"{r['milestone']} {r['met']}/{r['total']}" for r in results)
    focus = next((r["milestone"] for r in results if not r["milestone_met"]), "-")
    return f"GOAL NOT MET ({parts}, focus={focus})"


def print_milestone(res: dict) -> None:
    print(f"== {res['milestone']}: {res['met']}/{res['total']} targets met")
    for r in res["rows"]:
        print(r.line())
    if res["all_met"]:
        print(f"   confirmation: {'by the fresh run at ' + res['confirmed_by'] if res['confirmed_by'] else 'PENDING - every target is met, but a milestone counts only after two consecutive fresh runs on new data pass; re-run the benchmark and check again'}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--all", action="store_true", help="every milestone M1-M4 (the default)")
    g.add_argument("--milestone", help="one milestone (goal_targets.json milestones: M1..M4)")
    ap.add_argument("--targets", default=str(TARGETS))
    ap.add_argument("--scoreboard", default=str(SCOREBOARD))
    ap.add_argument("--validity", default=str(VALIDITY))
    ap.add_argument("--history", default=str(HISTORY), help="goal_check's own record of its checks (confirmations)")
    ap.add_argument("--no-record", action="store_true", help="do not append this check to the history")
    ap.add_argument("--obs-json", help="read the obs metrics from this file instead of running tools/obs.py")
    ap.add_argument("--max-age-h", type=float, default=MAX_AGE_H)
    ap.add_argument("--now", help=argparse.SUPPRESS)  # tests: a fixed clock (ISO)
    ap.add_argument("--json", action="store_true", help="print the results as JSON before the verdict line")
    a = ap.parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:  # captured stdout in tests
        pass
    targets = read_json(Path(a.targets))
    ms = milestones(targets) if isinstance(targets, dict) else {}
    names = [a.milestone] if a.milestone else list(ms)
    if not ms or any(m not in ms for m in names):
        print(f"cannot read milestone(s) {names} from {a.targets} (have: {', '.join(ms) or 'none'})")
        print(f"MILESTONE {a.milestone} NOT MET (0/0)" if a.milestone else "GOAL NOT MET (no milestones, focus=-)")
        return 1
    now = parse_ts(a.now) if a.now else datetime.now(timezone.utc)
    obs = read_json(Path(a.obs_json)) if a.obs_json else run_obs(a.max_age_h)
    d = Data(targets, read_jsonl(Path(a.scoreboard)), read_json(Path(a.validity)) or {}, obs, now, a.max_age_h)
    history = read_jsonl(Path(a.history))
    results = evaluate_milestones(d, names, history)
    print(f"GOAL CHECK {a.milestone or 'all milestones'}  at {now.isoformat(timespec='seconds')}  "
          f"max age {a.max_age_h:g} h  scoreboard rows {len(d.rows)}")
    if a.json:
        print(json.dumps([{**r, "rows": [asdict(x) for x in r["rows"]]} for r in results], default=str))
    else:
        for res in results:
            print_milestone(res)
    vs = d.validity_summary
    reasons = ", ".join(f"{k}: {v}" for k, v in sorted(vs.get("invalid_reasons", {}).items())) or "none"
    share = f" ({vs['pct']:.0f}%)" if vs.get("pct") is not None else ""
    print(f"Predicate validity: {vs['valid']}/{vs['cases']} cases valid{share}; invalid: {reasons}")
    if not a.no_record:
        try:
            Path(a.history).parent.mkdir(parents=True, exist_ok=True)
            with open(a.history, "a", encoding="utf-8") as f:
                for r in results:
                    f.write(json.dumps({"at": now.isoformat(timespec="seconds"), "milestone": r["milestone"],
                                        "met": r["met"], "total": r["total"], "all_met": r["all_met"],
                                        "milestone_met": r["milestone_met"], "fingerprint": r["fingerprint"]}) + "\n")
        except OSError as exc:
            print(f"(could not record this check: {exc})")
    final = milestone_line(results[0]) if a.milestone else goal_line(results)
    print(final)
    return 0 if final in ("GOAL MET", f"MILESTONE {a.milestone} MET") else 1


if __name__ == "__main__":
    raise SystemExit(main())

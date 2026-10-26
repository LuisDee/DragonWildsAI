"""Is the long-running goal met? (docs/GOAL.md §1, §1b, §1c; docs/goal_targets.json; design eval-benchmark.md §9).
Built for Claude Code's /goal, whose evaluator only reads the transcript: completion is proven by this command's output.

  .venv\\Scripts\\python.exe -m tools.goal_check --all            # a table per milestone M1-M6 (the default)
  .venv\\Scripts\\python.exe -m tools.goal_check --milestone M3   # one milestone
  .venv\\Scripts\\python.exe -m tools.goal_check --json           # results as JSON (the last line stays the verdict)

The LAST line is exactly one of:
  GOAL MET sha=<HEAD> judge=<judge hash> runs=<run ids> at=<UTC>   (--all; only when everything below holds)
  GOAL MET (TEST)                                                  (the same, with DW_GOAL_CHECK_TEST=1: tests only)
  GOAL NOT MET (M1 x/y, M2 x/y, ..., focus=<first milestone not met, or "gates">)
  MILESTONE Mn MET | MILESTONE Mn NOT MET (x/y)                    (--milestone; never prints the words GOAL MET)
Exit 0 only for MET. After GOAL MET, Luis's sign-off is the final gate (goal_targets.json final_gate).

What counts (review findings 2, 3, 5, 6, 7, 15; Luis's decision rules, GOAL.md §1c):
- Benchmark evidence is RE-DERIVED from raw run directories (cases.jsonl, run.json), whose sha256 must match the
  scoreboard row. Precomputed metrics are never trusted.
- Only full runs of a frozen suite manifest, on the scoring world (goal_targets scoring_world: dev), with real models,
  at the CURRENT companion hash + judge hash + game build count. Mixed or dirty hashes = NOT MET.
- A case counts only if its validity record (logs/evals/validity/<key>.json, key = case + scorer + body + build) shows
  the positive control passed and every negative control failed, on the scoring world.
- Percentage targets: the manifest denominator (only `pass` counts; unverifiable/skip/error count against),
  n >= min_n and the Wilson 95% lower bound >= the target.
- Long tasks: k repeats, all pass (pass^k), hints <= the limit. Pinned goal cases must match their pinned hashes.
- Obs targets (tools/obs.py, filtered to the commits at the current companion hash): <= 24 h old and the exposure
  minimum (active hours, tool calls per hour).
- Gates for GOAL MET: a Luis-approved judge tag with no judge diff since; a clean tree; two consecutive checks on
  different data per milestone (logs/evals/goal_checks.jsonl).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from evals.bench import hashes  # noqa: E402
from evals.bench.report import wilson  # noqa: E402

TARGETS = ROOT / "docs" / "goal_targets.json"
SCOREBOARD = ROOT / "logs" / "evals" / "scoreboard.jsonl"
VALIDITY_DIR = ROOT / "logs" / "evals" / "validity"
HISTORY = ROOT / "logs" / "evals" / "goal_checks.jsonl"
MAX_AGE_H = 24.0
MET, NOT_MET, NO_DATA = "MET", "NOT MET", "NO DATA"
TEST_ENV = "DW_GOAL_CHECK_TEST"
EXTRA_NEGATIVES = ("wrong_action", "alt_means", "partial")  # review finding 4 (unless the record says n/a)

FAMILY_TARGETS = {
    "spells_effect_coverage_pct": "spell_cast",
    "spell_use_cases_pct": "spell_use",
    "craft_from_scratch_pct": "craft",
    "combat_cases_pct": "combat",
    "adversarial_cases_pct": "adversarial",
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
        return f"[{self.status:<7}] {self.target:<46} {self.value:<30} want {self.want:<16} {self.source}  age {age}{note}"


@dataclass
class Current:
    companion: str
    judge: str
    scorer: str
    body: str
    build: str | None
    head: str | None
    clean: bool


@dataclass
class Data:
    targets: dict
    rows: list[dict]  # scoreboard rows
    validity: dict  # key -> record
    obs: dict | None
    now: datetime
    cur: Current
    max_age_h: float = MAX_AGE_H
    root: Path = ROOT
    runs: list[dict] = field(default_factory=list)  # counted runs: {row, run, cases}
    rejected: list[str] = field(default_factory=list)  # why rows did not count
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


def load_validity(d: Path) -> dict:
    out = {}
    for f in sorted(Path(d).glob("*.json")) if Path(d).exists() else []:
        r = read_json(f)
        if isinstance(r, dict) and r.get("key"):
            out[r["key"]] = r
    return out


def current(root: Path = ROOT) -> Current:
    return Current(hashes.companion_hash(root), hashes.judge_hash(root), hashes.scorer_hash(root), hashes.body_hash(root),
                   hashes.game_build(root), hashes.head_sha(root), hashes.tree_clean(root))


def companion_commits(root: Path = ROOT) -> list[str]:
    """Commits whose companion tree equals HEAD's (since the last commit that touched the companion paths)."""
    last = hashes.git("log", "-1", "--format=%H", "--", *hashes.COMPANION_PATHS, root=root)
    if not last or not last.strip():
        return []
    out = hashes.git("rev-list", f"{last.strip()}^..HEAD", root=root) or hashes.git("rev-list", "HEAD", root=root) or ""
    return [x.strip() for x in out.splitlines() if x.strip()]


def run_obs(root: Path, since_h: float, shas: list[str]) -> dict | None:
    if not (root / "tools" / "obs.py").exists():
        return None
    cmd = [sys.executable, "-m", "tools.obs", "metrics", "--json", "--since", f"{since_h:g}h"]
    if shas:
        cmd += ["--companion-sha", ",".join(s[:12] for s in shas)]
    try:
        p = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=300, encoding="utf-8", errors="replace")
        return json.loads(p.stdout) if p.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


def age_h(d: Data, ts: Any) -> float | None:
    t = parse_ts(ts)
    return None if t is None else max(0.0, (d.now - t).total_seconds() / 3600.0)


# ------------------------------------------------------------------ counted runs (re-derived, finding 5)


def collect_runs(d: Data) -> None:
    world = (d.targets.get("scoring_world") or {}).get("world", "dev")
    for row in d.rows:
        if row.get("kind", "bench") != "bench":
            continue
        rid = row.get("run_id")
        why = None
        if row.get("target") != world:
            why = f"target {row.get('target')} (scoring world is {world})"
        elif not row.get("full"):
            why = "partial run (--only)"
        elif row.get("companion_hash") != d.cur.companion or "+dirty" in str(row.get("companion_hash")):
            why = f"companion {row.get('companion_hash')} != current {d.cur.companion}"
        elif row.get("judge_hash") != d.cur.judge:
            why = f"judge {row.get('judge_hash')} != current {d.cur.judge}"
        elif row.get("build") != d.cur.build:
            why = f"build {row.get('build')} != {d.cur.build}"
        if why is None:
            rd = d.root / str(row.get("dir"))
            if hashes.sha256_file(rd / "run.json") != row.get("run_sha256") or \
                    hashes.sha256_file(rd / "cases.jsonl") != row.get("cases_sha256"):
                why = "run files missing or changed since the scoreboard row (sha256 mismatch)"
            else:
                run = read_json(rd / "run.json") or {}
                if run.get("llm") != "real":
                    why = f"not a real-model run (llm={run.get('llm')})"
                else:
                    d.runs.append({"row": row, "run": run, "cases": read_jsonl(rd / "cases.jsonl"), "dir": rd})
        if why:
            d.rejected.append(f"{rid}: {why}")
    d.runs.sort(key=lambda r: parse_ts(r["row"].get("at")) or d.now, reverse=True)


def case_valid(d: Data, c: dict) -> tuple[bool, str]:
    key = hashes.validity_key(str(c.get("case_hash")), d.cur.scorer, d.cur.body, d.cur.build, str(c.get("entry_hash") or ""))
    v = d.validity.get(key)
    world = (d.targets.get("scoring_world") or {}).get("world", "dev")
    if not isinstance(v, dict):
        return False, "no controls at the current scorer/body/build"
    if v.get("target") != world:
        return False, f"controls ran on {v.get('target')}, not the scoring world"
    cs = v.get("controls") or {}
    if (cs.get("oracle") or {}).get("result") != "pass":
        return False, "positive control did not pass"
    na = v.get("na") or {}
    for neg in list((d.targets.get("eval_validity") or {}).get("negative_controls") or []) + list(EXTRA_NEGATIVES):
        if neg in na:
            continue
        if (cs.get(neg) or {}).get("result") != "fail":
            return False, f"negative control {neg} did not fail"
    return True, ""


def validity_summary(d: Data) -> dict:
    seen = {}
    for r in d.runs:
        for c in r["cases"]:
            seen[str(c.get("case_hash"))] = c
    why: dict[str, int] = {}
    valid = 0
    for c in seen.values():
        ok, reason = case_valid(d, c)
        valid += ok
        if not ok:
            why[reason] = why.get(reason, 0) + 1
    n = len(seen)
    return {"cases": n, "valid": valid, "pct": round(100.0 * valid / n, 1) if n else None, "invalid_reasons": why}


def manifest_of(d: Data, run: dict) -> dict | None:
    m = run["run"].get("suite_manifest") or {}
    path = d.root / str(m.get("path") or "")
    if not m.get("path") or hashes.sha256_file(path) != m.get("sha256"):
        return None
    return read_json(path)


def latest_with(d: Data, pred: Callable[[dict], bool]) -> dict | None:
    return next((r for r in d.runs if pred(r)), None)


def _no_runs_row(d: Data, name: str, want: str) -> Row:
    if d.rejected:
        return Row(name, NOT_MET, "-", want, "-", None, "no counted run: " + "; ".join(d.rejected[-2:]))
    return Row(name, NO_DATA, "-", want, "-", None, "no benchmark run")


def wilson_row(name: str, passed: int, n: int, target_pct: float, min_n: int, src: str, age: float | None, extra: str = "") -> Row:
    lo, hi = wilson(passed, n)
    value = f"{passed}/{n} ({100 * passed / n:.0f}%, LB {100 * lo:.0f}%)" if n else "0/0"
    want = f"LB >= {target_pct:g}%, n >= {min_n}"
    if n < min_n:
        return Row(name, NOT_MET, value, want, src, age, f"n {n} < {min_n}{'; ' + extra if extra else ''}")
    return Row(name, MET if 100 * lo >= target_pct else NOT_MET, value, want, src, age, extra)


def family_target(d: Data, name: str, family: str, target_pct: float) -> Row:
    min_n = int((d.targets.get("decision_rule") or {}).get("min_n_percent_targets", 20))
    for r in d.runs:
        man = manifest_of(d, r)
        if man is None or family not in (man.get("families") or {}):
            continue
        ids = {x["id"]: x["hash"] for x in man["families"][family]}
        k = max(1, int((man.get("trials_per_case") or {}).get(family, 1)))  # repeated trials per case (spells: 2)
        trials = {(c.get("case_id"), int(c.get("repeat_i") or 0)): c for c in r["cases"]}
        passed = sum(1 for cid, h in ids.items() for i in range(k) if (c := trials.get((cid, i)))
                     and c.get("case_hash") == h and c.get("result") == "pass" and case_valid(d, c)[0])
        return wilson_row(name, passed, len(ids) * k, target_pct, min_n, str(r["row"].get("run_id")), age_h(d, r["row"].get("at")),
                          f"manifest v{man.get('version')}" + (f", {k} trials/case" if k > 1 else ""))
    return _no_runs_row(d, name, f"LB >= {target_pct:g}%")


def _cases(d: Data, pred: Callable[[dict], bool]) -> list[tuple[dict, dict]]:
    return [(r, c) for r in d.runs for c in r["cases"] if pred(c)]


def pinned_ok(d: Data, c: dict) -> bool:
    pins = ((d.targets.get("goal_cases") or {}).get("pinned_by_hash") or {})
    return c.get("case_id") not in pins or pins[c["case_id"]] == c.get("case_hash")


def k_target(d: Data, name: str, pred: Callable[[dict], bool], k: int, max_hints: int | None = None) -> Row:
    """k repeats, all pass (pass^k), valid, pinned, hints within the limit."""
    want = f"pass^{k}" + (f", <= {max_hints} hint" if max_hints is not None else "")
    rows = _cases(d, pred)
    if not rows:
        return _no_runs_row(d, name, want)
    good = [(r, c) for r, c in rows if c.get("result") == "pass" and case_valid(d, c)[0] and pinned_ok(d, c)
            and (max_hints is None or int(c.get("hints_used") or 0) <= max_hints)]
    recent = rows[:k]
    allpass = len(rows) >= k and all(c.get("result") == "pass" and case_valid(d, c)[0] and pinned_ok(d, c)
                                     and (max_hints is None or int(c.get("hints_used") or 0) <= max_hints) for _, c in recent)
    r0 = rows[0][0]
    gaps = sorted({m for _, c in recent for m in (c.get("missing") or []) if c.get("result") == "unverifiable"})
    note = "" if allpass else (f"blocked on: {', '.join(gaps)}" if gaps else f"the last {k} must all pass (valid, pinned)")
    return Row(name, MET if allpass else NOT_MET, f"{len(good)}/{len(rows)} good runs", want, str(r0["row"].get("run_id")),
               age_h(d, r0["row"].get("at")), note)


def metric_from_cases(d: Data, name: str, key: str, want_v: float, at_most: bool = False, ratio: tuple[str, str] | None = None,
                      flag: str | None = None, unit: str = "%") -> Row:
    """A process metric re-derived from cases.jsonl `process` fields of the newest counted run that has it."""
    want = f"{'<=' if at_most else '>='} {want_v:g}{unit}"
    for r in d.runs:
        procs = [c.get("process") or {} for c in r["cases"] if case_valid(d, c)[0]]
        if ratio:
            num = sum(float(p.get(ratio[0], 0)) for p in procs)
            den = sum(float(p.get(ratio[1], 0)) for p in procs)
            if den <= 0:
                continue
            lo, _ = wilson(int(num), int(den))
            v = 100 * lo
            value = f"{int(num)}/{int(den)} (LB {v:.0f}%)"
        elif flag:
            xs = [bool(p[flag]) for p in procs if flag in p]
            if not xs:
                continue
            lo, hi = wilson(sum(xs), len(xs))
            v = 100 * (hi if at_most else lo)
            value = f"{sum(xs)}/{len(xs)} ({'UB' if at_most else 'LB'} {v:.0f}%)"
        else:
            xs = sorted(float(p[key]) for p in procs if key in p)
            if not xs:
                continue
            v = xs[len(xs) // 2]
            value = f"median {v:.1f} (n={len(xs)})"
        ok = v <= want_v if at_most else v >= want_v
        return Row(name, MET if ok else NOT_MET, value, want, str(r["row"].get("run_id")), age_h(d, r["row"].get("at")))
    return _no_runs_row(d, name, want)


def damage_trend(d: Data, name: str, spec: str) -> Row:
    need = next((int(w) for w in str(spec).split() if w.isdigit()), 5)
    series = [((c.get("process") or {}).get("fight_i", c.get("repeat_i", 0)), float((c.get("process") or {})["damage_taken"])) for _, c in
              _cases(d, lambda c: c.get("family") == "tactics_trend" and "damage_taken" in (c.get("process") or {}))]
    if len(series) < need:
        return _no_runs_row(d, name, f"falling over {need}") if not series else \
            Row(name, NOT_MET, f"{len(series)} fights", f"falling over {need}", "-", None, f"needs {need} fights")
    xs, ys = [i for i, _ in series], [y for _, y in series]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    sxx = sum((x - mx) ** 2 for x in xs) or 1.0
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    return Row(name, MET if slope < 0 else NOT_MET, f"slope {slope:.2f}/fight over {len(series)}", f"falling over {need}")


def every_skill(d: Data, cfg: dict) -> list[Row]:
    """M3: per skill in the build's skill manifest, three modes (asked, initiative, plus5), each pass^1, valid."""
    skills = skill_manifest(d.root, d.targets)
    modes = ("asked", "initiative", "plus5")
    out = []
    for m in modes:
        good = [s for s in skills if any(c.get("result") == "pass" and case_valid(d, c)[0] and pinned_ok(d, c)
                                         for _, c in _cases(d, lambda c, s=s, m=m: c.get("family") == "skill_train"
                                                            and c.get("skill") == s and c.get("mode") == m))]
        name = f"every_skill:{m}"
        if not d.runs:
            out.append(_no_runs_row(d, name, f"{len(skills)}/{len(skills)} skills"))
            continue
        missing = [s for s in skills if s not in good]
        out.append(Row(name, MET if skills and not missing else NOT_MET, f"{len(good)}/{len(skills)} skills",
                       f"{len(skills)}/{len(skills)}", str(d.runs[0]["row"].get("run_id")), age_h(d, d.runs[0]["row"].get("at")),
                       ("missing: " + ", ".join(missing[:6]) + ("..." if len(missing) > 6 else "")) if missing else ""))
    return out


def skill_manifest(root: Path = ROOT, targets: dict | None = None) -> list[str]:
    """The frozen M3 skill list (goal_targets every_skill.skills_frozen, Luis 2026-10-26); the data scan only when
    no frozen list exists."""
    frozen = ((targets or read_json(root / "docs" / "goal_targets.json") or {}).get("every_skill") or {}).get("skills_frozen")
    if frozen:
        return sorted(frozen)
    import re
    names: set[str] = set()
    for f in sorted((root / "data").glob("*_*.json")):
        if not re.fullmatch(r"(spells|recipes)_\d+\.json", f.name):
            continue
        names.update(re.findall(r"SKILL_([A-Za-z]+)", f.read_text(encoding="utf-8", errors="replace")))
    return sorted(names)


# ------------------------------------------------------------------ observability (tools/obs.py)


def obs_row(d: Data, name: str, value_of: Callable[[dict], Any], want_v: float, at_most: bool, unit: str,
            n_of: Callable[[dict], Any] | None = None) -> Row:
    want = f"{'<=' if at_most else '>='} {want_v:g}{unit}"
    o = d.obs
    if not isinstance(o, dict):
        return Row(name, NO_DATA, "-", want, "obs", None, "tools/obs.py metrics gave nothing")
    ts = (o.get("window") or {}).get("until") or o.get("generated_at")
    a = age_h(d, ts)
    exp = o.get("exposure") or {}
    src = f"obs {o.get('source') or '?'} {exp.get('active_hours', 0) or 0:.1f}h active"
    try:
        v = value_of(o)
    except (AttributeError, KeyError, TypeError):
        v = None
    n = n_of(o) if n_of else exp.get("active_hours")
    if v is None or not isinstance(v, (int, float)) or not n:
        return Row(name, NO_DATA, "-", want, src, a, "no data at the current companion hash")
    if a is None or a > d.max_age_h:
        return Row(name, NOT_MET, f"{v:g}{unit}", want, src, a, f"stale: older than {d.max_age_h:g} h")
    ok = v <= want_v if at_most else v >= want_v
    return Row(name, MET if ok else NOT_MET, f"{v:g}{unit}", want, src, a)


def exposure_row(d: Data, cfg: dict) -> Row:
    hours, cph = float(cfg.get("min_active_hours_at_current_hash", 2)), float(cfg.get("min_tool_calls_per_hour", 20))
    want = f">= {hours:g} h, >= {cph:g} calls/h"
    o = d.obs if isinstance(d.obs, dict) else None
    if o is None:
        return Row("obs_exposure", NO_DATA, "-", want, "obs", None, "tools/obs.py metrics gave nothing")
    exp = o.get("exposure") or {}
    ah, rate = float(exp.get("active_hours") or 0), float(exp.get("tool_calls_per_hour") or 0)
    ok = ah >= hours and rate >= cph
    return Row("obs_exposure", MET if ok else NOT_MET, f"{ah:.1f} h, {rate:.0f} calls/h", want, "obs",
               age_h(d, (o.get("window") or {}).get("until") or o.get("generated_at")))


def voice(d: Data, name: str) -> Row:
    want_v = float(d.targets[name])
    rows = sorted([r for r in d.rows if r.get("kind") == "voice" and isinstance(r.get("score"), (int, float))
                   and (r.get("n") or 0) > 0 and r.get("companion_hash") == d.cur.companion],
                  key=lambda r: parse_ts(r.get("at")) or d.now, reverse=True)
    if not rows:
        return Row(name, NO_DATA, "-", f">= {want_v:g}", "-", None, "no voice-eval score at the current companion hash")
    r = rows[0]
    return Row(name, MET if r["score"] >= want_v else NOT_MET, f"{r['score']:.2f} (n={r['n']})", f">= {want_v:g}",
               str(r.get("run_id")), age_h(d, r.get("at")))


# ------------------------------------------------------------------ registry


def rows_for(d: Data, key: str) -> list[Row]:
    t = d.targets
    rule = t.get("decision_rule") or {}
    k = int(rule.get("long_tasks_repeats_k", 3))
    if key.startswith("long_tasks:"):
        tid = key.split(":", 1)[1]
        mh = (t.get("long_tasks") or {}).get("dev_world_max_hints", 1)
        return [k_target(d, key, lambda c: c.get("long_task") == tid, k, int(mh))]
    if key.startswith("capstone:"):
        cid = key.split(":", 1)[1]
        if cid == "brynmoor_progression":
            stages = [c for _, c in _cases(d, lambda c: c.get("family") == "capstone_stage")]
            ids = sorted({c.get("case_id") for c in stages})
            if not ids:
                return [_no_runs_row(d, key, "every stage passes")]
            bad = [i for i in ids if not any(c.get("case_id") == i and c.get("result") == "pass" and case_valid(d, c)[0]
                                            and pinned_ok(d, c) for c in stages)]
            return [Row(key, MET if not bad and pinned_stage_count(t) <= len(ids) else NOT_MET,
                        f"{len(ids) - len(bad)}/{max(len(ids), pinned_stage_count(t))} stages", "all stages",
                        note=("open: " + ", ".join(bad[:5])) if bad else "")]
        return [k_target(d, key, lambda c: c.get("capstone") == cid, int(rule.get("capstone_repeats_k", 1)), None)]
    if key in FAMILY_TARGETS:
        return [family_target(d, key, FAMILY_TARGETS[key], float(t[key]))]
    if key == "every_skill":
        return every_skill(d, t.get("every_skill") or {})
    if key == "combat_basics_live_proven":
        kb = int(rule.get("combat_basics_repeats_k", 1))
        return [k_target(d, f"{key}:{b}", lambda c, b=b: c.get("basic") == b, kb, None) for b in t.get(key) or []]
    if key == "combat_tactics":
        cfg = t.get(key) or {}
        out = []
        if "prep_before_hard_fight_pct" in cfg:
            out.append(family_target(d, f"{key}:prep_before_hard_fight_pct", "tactics_prep", float(cfg["prep_before_hard_fight_pct"])))
        if "telegraph_dodge_success_pct" in cfg:
            out.append(metric_from_cases(d, f"{key}:telegraph_dodge_success_pct", "", float(cfg["telegraph_dodge_success_pct"]),
                                         ratio=("dodged", "telegraphs")))
        if "damage_taken_trend" in cfg:
            out.append(damage_trend(d, f"{key}:damage_taken_trend", cfg["damage_taken_trend"]))
        return out
    if key == "knowledge_use":
        cfg = t.get(key) or {}
        out = []
        for name, v in cfg.items():
            at_most = name.endswith("_max")
            flag = (name[:-4] if at_most else name).removesuffix("_pct")
            out.append(metric_from_cases(d, f"{key}:{name}", "", float(v), at_most=at_most, flag=flag))
        return out
    if key == "ranged_hit_rate_15m_moving_pct":
        return [metric_from_cases(d, key, "", float(t[key]), ratio=("hits", "shots"))]
    if key == "efficiency_vs_baseline_pct":
        return [metric_from_cases(d, key, "efficiency_pct", float(t[key]))]
    if key == "heldout":
        return [heldout(d, t.get("heldout") or {})]
    if key == "obs_exposure":
        return [exposure_row(d, t.get(key) or {})]
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


def pinned_stage_count(t: dict) -> int:
    pins = ((t.get("goal_cases") or {}).get("pinned_by_hash") or {})
    return sum(1 for k in pins if k.startswith("capstone_stage"))


def heldout(d: Data, cfg: dict) -> Row:
    min_n = int(cfg.get("min_n", 30))
    want = f"held LB >= seen - 10, n >= {min_n}"
    r = latest_with(d, lambda r: bool(r["run"].get("heldout_draw")))
    if r is None:
        return _no_runs_row(d, "heldout", want) if not d.runs else Row("heldout", NOT_MET, "-", want, "-", None,
                                                                      "no fresh post-freeze held-out draw at this hash")
    valid = [c for c in r["cases"] if case_valid(d, c)[0] and c.get("result") != "skip"]
    held = [c for c in valid if c.get("heldout")]
    seen_run = latest_with(d, lambda x: not x["run"].get("heldout_draw"))
    seen = [c for c in (seen_run or {}).get("cases", []) if case_valid(d, c)[0] and c.get("result") != "skip"]
    if not seen:
        return Row("heldout", NOT_MET, "-", want, str(r["row"].get("run_id")), None, "no seen-suite run to compare with")
    sp = sum(c.get("result") == "pass" for c in seen) / len(seen)
    hp = sum(c.get("result") == "pass" for c in held)
    lo, _ = wilson(hp, len(held))
    ok = len(held) >= min_n and 100 * lo >= 100 * sp - 10
    return Row("heldout", MET if ok else NOT_MET, f"held {hp}/{len(held)} LB {100 * lo:.0f}% vs seen {100 * sp:.0f}%", want,
               str(r["row"].get("run_id")), age_h(d, r["row"].get("at")), "" if len(held) >= min_n else f"n {len(held)} < {min_n}")


# ------------------------------------------------------------------ milestones, gates, confirmation


def milestones(targets: dict) -> dict[str, list[str]]:
    return {k: list(v) for k, v in (targets.get("milestones") or {}).items()}


def check(d: Data, milestone: str) -> tuple[list[Row], dict]:
    ms = milestones(d.targets)
    if milestone not in ms:
        raise SystemExit(f"unknown milestone {milestone!r}; have {', '.join(ms) or 'none'}")
    if not d.runs and not d.rejected:
        collect_runs(d)
    d.validity_summary = validity_summary(d)
    rows: list[Row] = []
    for k in ms[milestone]:
        rows += rows_for(d, k)
    return rows, d.validity_summary


def score(rows: list[Row]) -> tuple[int, int]:
    return sum(r.status == MET for r in rows), len(rows)


def declared_gaps(root: Path = ROOT) -> list[str]:
    """Capability gaps the GOAL case drafts declare (provenance.gap), shown so a blocked target isn't mistaken for
    a capability failure (main, 2026-10-26: build-dependent cases read as a capability gap until the build tool lands)."""
    out = []
    for f in sorted((root / "evals" / "bench" / "goal_cases").glob("*.json")):
        data = read_json(f) or {}
        for c in data.get("cases") or []:
            gap = (c.get("provenance") or {}).get("gap")
            if gap:
                out.append(f"{c.get('id')}: {gap}")
    return out


def gates(d: Data) -> list[Row]:
    out = []
    tag = d.targets.get("judge_tag")
    if not tag:
        out.append(Row("gate:judge_tag", NOT_MET, "none", "Luis's tag", note="Luis has not tagged the judge files yet"))
    else:
        diff = hashes.judge_diff_since(tag, d.root)
        if diff is None:
            out.append(Row("gate:judge_tag", NOT_MET, str(tag), "exists", note="the judge tag is unknown to git"))
        else:
            out.append(Row("gate:judge_tag", MET if not diff else NOT_MET, f"{len(diff)} judge files changed", "0",
                           str(tag), note=("changed since Luis's approval: " + ", ".join(diff[:6])) if diff else ""))
    out.append(Row("gate:clean_tree", MET if d.cur.clean else NOT_MET, "clean" if d.cur.clean else "dirty", "clean",
                   str(d.cur.head)[:12] if d.cur.head else "-"))
    world = (d.targets.get("scoring_world") or {}).get("world")
    out.append(Row("gate:scoring_world", MET if world else NOT_MET, str(world), "set"))
    return out


def fingerprint(d: Data) -> str:
    ids = sorted(str(r["row"].get("run_id")) for r in d.runs)
    o = d.obs if isinstance(d.obs, dict) else {}
    return json.dumps([ids, (o.get("window") or {}).get("until") or o.get("generated_at"), d.cur.companion])


def confirmed(d: Data, history: list[dict], milestone: str, fp: str) -> dict | None:
    prev = [h for h in history if h.get("milestone") == milestone and h.get("fingerprint") != fp
            and (parse_ts(h.get("at")) or d.now) < d.now]
    if not prev:
        return None
    last = max(prev, key=lambda h: parse_ts(h.get("at")) or d.now)
    a = age_h(d, last.get("at"))
    return last if last.get("all_met") and a is not None and a <= d.max_age_h else None


def evaluate_milestones(d: Data, names: list[str], history: list[dict]) -> list[dict]:
    collect_runs(d)
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


def goal_line(d: Data, results: list[dict], gate_rows: list[Row]) -> str:
    parts = ", ".join(f"{r['milestone']} {r['met']}/{r['total']}" for r in results)
    focus = next((r["milestone"] for r in results if not r["milestone_met"]), None)
    if focus is None and any(g.status != MET for g in gate_rows):
        focus = "gates"
    if focus is None and results:
        if os.environ.get(TEST_ENV) == "1":
            return "GOAL MET (TEST)"
        runs = ",".join(sorted({str(r["row"].get("run_id")) for r in d.runs}))
        return (f"GOAL MET sha={d.cur.head} judge={d.cur.judge} runs={runs} "
                f"at={d.now.isoformat(timespec='seconds').replace('+00:00', 'Z')}")
    return f"GOAL NOT MET ({parts}, focus={focus or '-'})"


def print_milestone(res: dict) -> None:
    print(f"== {res['milestone']}: {res['met']}/{res['total']} targets met")
    for r in res["rows"]:
        print(r.line())
    if res["all_met"]:
        print("   confirmation: " + (f"by the fresh check at {res['confirmed_by']}" if res["confirmed_by"] else
                                     "PENDING - every target is met; a milestone counts after two consecutive checks on "
                                     "new data pass: re-run the benchmark, then check again"))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--all", action="store_true", help="every milestone (the default)")
    g.add_argument("--milestone", help="one milestone (goal_targets.json milestones)")
    ap.add_argument("--targets", default=str(TARGETS))
    ap.add_argument("--scoreboard", default=str(SCOREBOARD))
    ap.add_argument("--validity", default=str(VALIDITY_DIR))
    ap.add_argument("--history", default=str(HISTORY))
    ap.add_argument("--no-record", action="store_true", help="do not append this check to the history")
    ap.add_argument("--obs-json", help="read the obs metrics from this file instead of running tools/obs.py")
    ap.add_argument("--max-age-h", type=float, default=MAX_AGE_H)
    ap.add_argument("--root", default=str(ROOT), help=argparse.SUPPRESS)  # tests: a temp repo
    ap.add_argument("--now", help=argparse.SUPPRESS)  # tests: a fixed clock (ISO)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    root = Path(a.root)
    targets = read_json(Path(a.targets))
    ms = milestones(targets) if isinstance(targets, dict) else {}
    names = [a.milestone] if a.milestone else list(ms)
    if not ms or any(m not in ms for m in names):
        print(f"cannot read milestone(s) {names} from {a.targets} (have: {', '.join(ms) or 'none'})")
        print(f"MILESTONE {a.milestone} NOT MET (0/0)" if a.milestone else "GOAL NOT MET (no milestones, focus=-)")
        return 1
    now = parse_ts(a.now) if a.now else datetime.now(timezone.utc)
    cur = current(root)
    obs = read_json(Path(a.obs_json)) if a.obs_json else run_obs(root, a.max_age_h, companion_commits(root))
    d = Data(targets, read_jsonl(Path(a.scoreboard)), load_validity(Path(a.validity)), obs, now, cur, a.max_age_h, root)
    results = evaluate_milestones(d, names, read_jsonl(Path(a.history)))
    gate_rows = gates(d) if not a.milestone else []
    print(f"GOAL CHECK {a.milestone or 'all milestones'}  at {now.isoformat(timespec='seconds')}  head {str(cur.head)[:12]}  "
          f"companion {cur.companion}  judge {cur.judge}  build {cur.build}  counted runs {len(d.runs)}")
    if a.json:
        print(json.dumps({"milestones": [{**r, "rows": [asdict(x) for x in r["rows"]]} for r in results],
                          "gates": [asdict(g) for g in gate_rows], "rejected_runs": d.rejected}, default=str))
    else:
        for res in results:
            print_milestone(res)
        if gate_rows:
            print("== gates")
            for gr in gate_rows:
                print(gr.line())
        for why in d.rejected[-8:]:
            print(f"   (not counted) {why}")
        for gap in declared_gaps(root):
            print(f"   (capability gap) {gap}")
    vs = d.validity_summary
    reasons = ", ".join(f"{k}: {v}" for k, v in sorted(vs.get("invalid_reasons", {}).items())) or "none"
    share = f" ({vs['pct']:.0f}%)" if vs.get("pct") is not None else ""
    print(f"Predicate validity: {vs.get('valid', 0)}/{vs.get('cases', 0)} counted cases valid{share}; invalid: {reasons}")
    if not a.no_record:
        try:
            Path(a.history).parent.mkdir(parents=True, exist_ok=True)
            with open(a.history, "a", encoding="utf-8") as f:
                for r in results:
                    f.write(json.dumps({"at": now.isoformat(timespec="seconds"), "milestone": r["milestone"], "met": r["met"],
                                        "total": r["total"], "all_met": r["all_met"], "milestone_met": r["milestone_met"],
                                        "fingerprint": r["fingerprint"]}) + "\n")
        except OSError as exc:
            print(f"(could not record this check: {exc})")
    final = milestone_line(results[0]) if a.milestone else goal_line(d, results, gate_rows)
    print(final)
    return 0 if final == f"MILESTONE {a.milestone} MET" or final.startswith("GOAL MET") else 1


if __name__ == "__main__":
    raise SystemExit(main())

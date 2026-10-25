"""Run reports (design §8): counts, per-family pass rates with Wilson 95% intervals, the coverage matrix, failure
clusters, perception gaps, latency, calls; paired comparisons between runs (Miller 2024: McNemar on the same cases).

Only `pass` counts as a pass; unverifiable, skip, error and invalid are reported in their own columns but count
against the denominator (review finding 2). Held-out cases are reported as aggregates only (finding 8)."""
from __future__ import annotations

import math
from collections import Counter, defaultdict
from typing import Any, Iterable

Z95 = 1.959963984540054


def wilson(passed: int, n: int, z: float = Z95) -> tuple[float, float]:
    """Wilson score interval (as fractions). n = 0 -> (0, 1)."""
    if n <= 0:
        return 0.0, 1.0
    p = passed / n
    den = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return max(0.0, centre - half), min(1.0, centre + half)


def pct_row(passed: int, n: int) -> dict:
    lo, hi = wilson(passed, n)
    return {"passed": passed, "n": n, "pct": round(100.0 * passed / n, 1) if n else None,
            "wilson_lo": round(100 * lo, 1), "wilson_hi": round(100 * hi, 1)}


def percentile(xs: list[float], q: float) -> float | None:
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    f, c = math.floor(k), math.ceil(k)
    return round(xs[f] + (xs[c] - xs[f]) * (k - f), 3)


def _get(r: Any, k: str, default=None):
    return r.get(k, default) if isinstance(r, dict) else getattr(r, k, default)


def summarize(run: dict, results: Iterable[Any]) -> dict:
    rows = list(results)
    counts = Counter(_get(r, "result") for r in rows)
    fam: dict[str, Counter] = defaultdict(Counter)
    matrix: dict[str, dict[str, str]] = defaultdict(dict)
    clusters: Counter = Counter()
    gaps: Counter = Counter()
    seen = [r for r in rows if not _get(r, "heldout")]
    held = [r for r in rows if _get(r, "heldout")]
    for r in seen:
        fam[_get(r, "family")][_get(r, "result")] += 1
        matrix[_get(r, "family")][_get(r, "case_id")] = _get(r, "result")
        for f in _get(r, "failures") or []:
            if f.get("tool"):
                clusters[f"{f.get('tool')}:{f.get('reason')}"] += 1
        for m in _get(r, "missing") or []:
            gaps[m] += 1
    calls: Counter = Counter()
    for r in rows:
        calls.update(_get(r, "calls") or {})
    fams = {f: {**pct_row(c["pass"], sum(c.values())), "results": dict(c)} for f, c in sorted(fam.items())}
    per_spell: dict[str, dict] = {}
    for r in seen:
        sp = _get(r, "spell")
        if not sp:
            continue
        e = per_spell.setdefault(sp, {"runs": 0, "passed": 0, "latency": [], "reasons": Counter(), "families": Counter()})
        e["runs"] += 1
        e["passed"] += _get(r, "result") == "pass"
        e["families"][_get(r, "family")] += 1
        if _get(r, "latency_s") is not None:
            e["latency"].append(_get(r, "latency_s"))
        if _get(r, "result") != "pass":
            e["reasons"][_get(r, "reason") or _get(r, "result")] += 1
    spells = {sp: {"reliability": round(e["passed"] / e["runs"], 3), "runs": e["runs"], "passed": e["passed"],
                   "latency_p50": percentile(e["latency"], 0.5), "failures": dict(e["reasons"]), "families": dict(e["families"])}
              for sp, e in sorted(per_spell.items())}
    lat = [_get(r, "latency_s") for r in rows if _get(r, "latency_s") is not None]
    return {"run": run, "counts": dict(counts), "families": fams, "matrix": {k: dict(v) for k, v in matrix.items()},
            "heldout": {"aggregate": pct_row(sum(1 for r in held if _get(r, "result") == "pass"), len(held))} if held else None,
            "seen": pct_row(sum(1 for r in seen if _get(r, "result") == "pass"), len(seen)),
            "failure_clusters": clusters.most_common(20), "perception_gaps": gaps.most_common(30),
            "mismatches": [m for r in seen for m in (_get(r, "mismatches") or [])][:50],
            "latency_s": {"p50": percentile(lat, 0.5), "p90": percentile(lat, 0.9), "n": len(lat)},
            "calls": dict(calls), "per_spell": spells}


def render_md(rep: dict) -> str:
    run = rep.get("run") or {}
    L = [f"# Benchmark run {run.get('run_id')} ({run.get('target')}, agent {run.get('agent')})", "",
         f"Counts: {rep.get('counts')}. Calls: {rep.get('calls')}. Companion `{run.get('companion_hash')}`, judge "
         f"`{run.get('judge_hash')}`, build {run.get('build')}, full suite: {run.get('full')}."]
    if run.get("target") == "mock":
        L += ["", "> Mock run: lint only, never counts for GOAL (review finding 3)."]
    L += ["", "## Families (only pass counts; Wilson 95%)", "", "| family | pass/n | % | Wilson | results |", "|---|---|---|---|---|"]
    for f, r in (rep.get("families") or {}).items():
        L.append(f"| {f} | {r['passed']}/{r['n']} | {r['pct']} | {r['wilson_lo']}–{r['wilson_hi']} | {r['results']} |")
    if rep.get("heldout"):
        h = rep["heldout"]["aggregate"]
        L += ["", f"Held-out (aggregate only): {h['passed']}/{h['n']} ({h['pct']}%, Wilson {h['wilson_lo']}–{h['wilson_hi']})"]
    L += ["", "## Coverage matrix", ""]
    for f, cells in (rep.get("matrix") or {}).items():
        L.append(f"**{f}**: " + ", ".join(f"{k}={v}" for k, v in sorted(cells.items())))
    if rep.get("per_spell"):
        L += ["", "## Per spell (cast, use and stress runs)", "", "| spell | reliability | runs | latency p50 (s) | failures |",
              "|---|---|---|---|---|"]
        for sp, e in rep["per_spell"].items():
            L.append(f"| {sp} | {e['reliability']} | {e['runs']} | {e['latency_p50']} | {e['failures']} |")
    if rep.get("failure_clusters"):
        L += ["", "## Failure clusters (tool:reason)", ""] + [f"- {k}: {n}" for k, n in rep["failure_clusters"]]
    if rep.get("perception_gaps"):
        L += ["", "## Perception gaps (unverifiable)", ""] + [f"- {k}: {n}" for k, n in rep["perception_gaps"]]
    if rep.get("mismatches"):
        L += ["", "## Sensor mismatches (probe vs skill reply)", ""] + [f"- {m}" for m in rep["mismatches"]]
    lat = rep.get("latency_s") or {}
    L += ["", f"Latency chat→first action: p50 {lat.get('p50')} s, p90 {lat.get('p90')} s (n={lat.get('n')})"]
    return "\n".join(L) + "\n"


def mcnemar(a: dict[str, bool], b: dict[str, bool]) -> dict:
    """Paired comparison of two runs over the same case ids: exact McNemar p-value and the pass-rate difference."""
    ids = sorted(set(a) & set(b))
    b01 = sum(1 for i in ids if not a[i] and b[i])  # fixed by B
    b10 = sum(1 for i in ids if a[i] and not b[i])  # broken by B
    n = b01 + b10
    k = min(b01, b10)
    p = min(1.0, 2 * sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n) if n else 1.0
    diff = (sum(b[i] for i in ids) - sum(a[i] for i in ids)) / len(ids) if ids else 0.0
    return {"n_paired": len(ids), "improved": b01, "regressed": b10, "p_value": round(p, 4), "diff_pct": round(100 * diff, 1)}

"""Lookup eval for enemies and vaults: does the ``lookup`` tool, as it is today, return the facts a player
reads before a fight or a vault (level, attacks, weak to, where it lives, what is in a vault, drops)?

Offline: it calls ``brain.knowledge.Knowledge.lookup`` directly, as the brain does
(``brain/controller.py`` ``_brain_read``). No model, no game, no network.

Cases (docs/GOAL-2026-11-17-long-jobs.md section 3, step 1):
* ``evals/lookup_enemies_cases.jsonl``   the tuned half (15): misses are shown and may guide a fix.
* ``evals/lookup_enemies_heldout.jsonl`` the held-out half (15): scored, never fixed against. Only
  its overall score is printed, unless ``--show-heldout`` is passed (CLAUDE.md, Breadth).

A case is a hit when every answer group has at least one alternative in the returned text (title,
section and text of every result, plus a walkthrough if any). Matching is case-insensitive on
normalised text: every run of non-alphanumeric characters is one space, and an alternative must sit
on word boundaries ("stab" does not match "stable").

    .venv\\Scripts\\python.exe evals\\lookup_enemies_eval.py
    .venv\\Scripts\\python.exe evals\\lookup_enemies_eval.py --json out.json   # tuned per case, held-out total
    .venv\\Scripts\\python.exe evals\\lookup_enemies_eval.py --show-heldout     # only when a fix is final

The index is the live brain's (data/wiki/knowledge.sqlite). If its cached signature is stale, the eval
builds a private copy in a temp directory instead of rewriting the shared cache.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

TUNED = ROOT / "evals" / "lookup_enemies_cases.jsonl"
HELDOUT = ROOT / "evals" / "lookup_enemies_heldout.jsonl"
KINDS = ("level", "attacks", "weakness", "location", "vault", "drops")
PREVIEW = 300  # characters of what came back, for a tuned miss


# ------------------------------------------------------------------------------ scoring


def norm(text: str) -> str:
    """Lower case, every run of non-alphanumerics one space, padded so a phrase matches on word boundaries."""
    return " " + " ".join(re.findall(r"[a-z0-9]+", (text or "").lower())) + " "


def returned_text(data: dict) -> str:
    """Everything the model reads in a lookup result: each result's title, section and text, and the walkthrough."""
    parts: list[str] = []
    for r in (data or {}).get("results") or []:
        parts += [str(r.get("title") or ""), str(r.get("section") or ""), str(r.get("text") or "")]
    walk = (data or {}).get("walkthrough")
    if isinstance(walk, dict):
        parts += [str(walk.get("title") or ""), str(walk.get("text") or "")]
    return "\n".join(parts)


def score(answers: list[list[str]], text: str) -> tuple[bool, list[list[str]]]:
    """(hit, the groups with no alternative found). An empty answer list never hits."""
    hay = norm(text)
    missing = [g for g in answers if not any(norm(a) in hay for a in g if norm(a).strip())]
    return (bool(answers) and not missing), missing


# ------------------------------------------------------------------------------ cases


def load_cases(path: Path) -> list[dict]:
    rows = []
    for i, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        case = json.loads(line)
        for key in ("id", "kind", "query", "answers", "source"):
            if key not in case:
                raise ValueError(f"{path.name}:{i}: missing {key}")
        if case["kind"] not in KINDS:
            raise ValueError(f"{path.name}:{i}: unknown kind {case['kind']}")
        if not case["answers"] or not all(isinstance(g, list) and g for g in case["answers"]):
            raise ValueError(f"{path.name}:{i}: answers must be non-empty lists of alternatives")
        rows.append(case)
    return rows


# ------------------------------------------------------------------------------ running


def open_index(db: str | None = None):
    """The live brain's index (brain.knowledge.Knowledge). A stale cache is rebuilt into a temp file, never
    over the shared data/wiki/knowledge.sqlite."""
    import sqlite3

    from brain.knowledge import Knowledge, data_dir, wiki_dir
    if db:
        return Knowledge(db_path=Path(db))
    live = wiki_dir() / "knowledge.sqlite"
    sig = Knowledge._signature(SimpleNamespace(data=data_dir(), wiki=wiki_dir()))
    cached = None
    if live.exists():
        try:
            con = sqlite3.connect(f"file:{live}?mode=ro", uri=True)
            try:
                row = con.execute("SELECT v FROM meta WHERE k='signature'").fetchone()
                cached = row[0] if row else None
            finally:
                con.close()
        except sqlite3.Error:
            cached = None
    if cached == sig:
        return Knowledge()
    tmp = Path(tempfile.mkdtemp(prefix="lookup-eval-")) / "knowledge.sqlite"
    print(f"note: the shared index is stale; building a private copy at {tmp}", file=sys.stderr)
    return Knowledge(db_path=tmp)


def run_case(knowledge, case: dict) -> dict:
    t0 = time.perf_counter()
    try:
        res = knowledge.lookup(case["query"], case.get("lookup_kind"))
        err = None
    except Exception as exc:  # a crash is a miss with its reason, never a crashed eval
        res, err = {"ok": False, "data": {}}, repr(exc)[:200]
    ms = (time.perf_counter() - t0) * 1000
    data = res.get("data") or {}
    text = returned_text(data)
    hit, missing = score(case["answers"], text)
    return {"id": case["id"], "kind": case["kind"], "query": case["query"], "hit": hit, "missing": missing,
            "answer_in_mirror": case.get("answer_in_mirror", True), "chars": len(json.dumps(data, ensure_ascii=False)),
            "ms": round(ms, 1), "titles": [r.get("title") for r in data.get("results") or []],
            "preview": text[:PREVIEW], "error": err}


def run_all(knowledge, cases: list[dict]) -> list[dict]:
    return [run_case(knowledge, c) for c in cases]


def summarise(rows: list[dict]) -> dict:
    by_kind: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for r in rows:
        by_kind[r["kind"]][0] += int(r["hit"])
        by_kind[r["kind"]][1] += 1
    mirror = [r for r in rows if r["answer_in_mirror"]]
    return {"hits": sum(r["hit"] for r in rows), "n": len(rows),
            "hits_in_mirror": sum(r["hit"] for r in mirror), "n_in_mirror": len(mirror),
            "by_kind": {k: tuple(v) for k, v in sorted(by_kind.items(), key=lambda kv: KINDS.index(kv[0]))},
            "mean_chars": round(sum(r["chars"] for r in rows) / max(1, len(rows))),
            "max_chars": max((r["chars"] for r in rows), default=0),
            "mean_ms": round(sum(r["ms"] for r in rows) / max(1, len(rows)), 1)}


def report(tuned: list[dict], held: list[dict], show_heldout: bool = False) -> str:
    """The printed report. The held-out half is ONE line (its score) unless show_heldout."""
    out: list[str] = []
    s = summarise(tuned)
    out.append(f"TUNED {s['hits']}/{s['n']}  (in mirror {s['hits_in_mirror']}/{s['n_in_mirror']})  "
               f"mean {s['mean_chars']} chars, max {s['max_chars']}, mean {s['mean_ms']} ms")
    out.append("  by kind: " + ", ".join(f"{k} {h}/{n}" for k, (h, n) in s["by_kind"].items()))
    for r in tuned:
        mark = "hit " if r["hit"] else "MISS"
        gap = "" if r["answer_in_mirror"] else "  [answer not in mirror]"
        out.append(f"  {mark} {r['id']:<26} q={r['query']!r} {r['chars']} chars {r['ms']} ms{gap}")
        if not r["hit"]:
            out.append(f"       missing: {r['missing']}")
            out.append(f"       titles:  {r['titles']}")
            if r["error"]:
                out.append(f"       error:   {r['error']}")
    h = summarise(held)
    out.append(f"HELD-OUT {h['hits']}/{h['n']}")
    if show_heldout:
        out.append(f"  (shown on request) in mirror {h['hits_in_mirror']}/{h['n_in_mirror']}; by kind: "
                   + ", ".join(f"{k} {a}/{n}" for k, (a, n) in h["by_kind"].items()))
        for r in held:
            out.append(f"  {'hit ' if r['hit'] else 'MISS'} {r['id']:<26} q={r['query']!r} missing={r['missing']}")
    return "\n".join(out)


def json_report(tuned: list[dict], held: list[dict], show_heldout: bool = False) -> dict:
    h = summarise(held)
    doc = {"tuned": {"summary": summarise(tuned), "cases": tuned},
           "heldout": {"hits": h["hits"], "n": h["n"]}}
    if show_heldout:
        doc["heldout"]["cases"] = held
    return doc


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--show-heldout", action="store_true", help="print the held-out half per case")
    ap.add_argument("--json", help="write the report as JSON (held-out as one number unless --show-heldout)")
    ap.add_argument("--db", help="a knowledge.sqlite to use instead of the live index")
    a = ap.parse_args(argv)
    knowledge = open_index(a.db)
    tuned = run_all(knowledge, load_cases(TUNED))
    held = run_all(knowledge, load_cases(HELDOUT))
    print(f"index build {knowledge.build}, {knowledge.stats()['db']}")
    print(report(tuned, held, a.show_heldout))
    if a.json:
        Path(a.json).write_text(json.dumps(json_report(tuned, held, a.show_heldout), ensure_ascii=False, indent=1),
                                encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())

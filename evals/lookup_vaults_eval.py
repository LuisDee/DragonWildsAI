"""Lookup eval for vaults: does a lookup of a vault ("Crasorak Kara"), its boss ("Vault Overlord") or "what vault drops X"
return where the vault is (region, province, door), its power level, who lives inside, the boss and what it gives (goal item 3,
docs/GOAL-2026-11-17-long-jobs.md)?

Offline: no model, no game, no network. The lookup is the brain's ``Knowledge.lookup`` with the bestiary entries the
query names put first (tools/build_bestiary.py ``BestiaryLookup``, the same path its ``score`` measures; the regions
sections come from tools/build_regions.py, the vault fields from tools/build_vaults.py). The "before" column is ``Knowledge.lookup`` alone.

Cases:
* ``evals/lookup_vaults_cases.jsonl``   the tuned half (5): misses are shown and may guide a fix.
* ``evals/lookup_vaults_heldout.jsonl`` the held-out half (5), written before any result was seen: scored, never
  fixed against. Only its score is printed, unless ``--show-heldout`` (CLAUDE.md, Breadth).

Scoring is the enemies eval's own (evals/lookup_enemies_eval.py ``score``): a case is a hit when every answer group
has one alternative in the returned text, case-insensitive, on word boundaries.

    .venv\\Scripts\\python.exe evals\\lookup_vaults_eval.py            # set DW_WIKI_DIR to the mirror for the wiki tier
    .venv\\Scripts\\python.exe evals\\lookup_vaults_eval.py --show-heldout
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

TUNED = ROOT / "evals" / "lookup_vaults_cases.jsonl"
HELDOUT = ROOT / "evals" / "lookup_vaults_heldout.jsonl"
KINDS = ("vault", "creature", "item")


def _enemies_eval():
    spec = importlib.util.spec_from_file_location("lookup_enemies_eval", ROOT / "evals" / "lookup_enemies_eval.py")
    ev = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ev)
    return ev


EV = _enemies_eval()
score, returned_text, run_case = EV.score, EV.returned_text, EV.run_case


def load_cases(path: Path) -> list[dict]:
    rows = []
    for i, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        case = json.loads(line)
        for k in ("id", "kind", "query", "answers", "source"):
            if k not in case:
                raise ValueError(f"{path.name}:{i}: missing {k}")
        if case["kind"] not in KINDS:
            raise ValueError(f"{path.name}:{i}: unknown kind {case['kind']}")
        if not case["answers"] or not all(isinstance(g, list) and g for g in case["answers"]):
            raise ValueError(f"{path.name}:{i}: answers must be non-empty lists of alternatives")
        rows.append(case)
    return rows


def run_all(knowledge, cases: list[dict]) -> list[dict]:
    return [run_case(knowledge, c) for c in cases]


def hits(rows: list[dict]) -> tuple[int, int]:
    return sum(r["hit"] for r in rows), len(rows)


def report(before: list[dict], tuned: list[dict], held_before: list[dict], held: list[dict],
           show_heldout: bool = False) -> str:
    out = [f"TUNED    before {'%d/%d' % hits(before)}  after {'%d/%d' % hits(tuned)}"]
    for r0, r in zip(before, tuned):
        out.append(f"  {'hit ' if r['hit'] else 'MISS'} (before {'hit' if r0['hit'] else 'miss'}) {r['id']:<18} "
                   f"q={r['query']!r} first={(r['titles'] or [None])[0]!r} {r['chars']} chars")
        if not r["hit"]:
            out.append(f"       missing: {r['missing']}")
    out.append(f"HELD-OUT before {'%d/%d' % hits(held_before)}  after {'%d/%d' % hits(held)}")
    if show_heldout:
        for r in held:
            out.append(f"  {'hit ' if r['hit'] else 'MISS'} {r['id']:<18} q={r['query']!r} missing={r['missing']}")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--show-heldout", action="store_true", help="print the held-out half per case")
    ap.add_argument("--db", help="a knowledge.sqlite to use instead of the live index")
    a = ap.parse_args(argv)
    from tools.build_bestiary import Bestiary, BestiaryLookup
    knowledge = EV.open_index(a.db)
    if hasattr(knowledge, "bestiary"):
        knowledge.bestiary = None  # once lookup merges the bestiary itself (d894103), "before" stays the plain lookup
    look = BestiaryLookup(knowledge, Bestiary())
    tc, hc = load_cases(TUNED), load_cases(HELDOUT)
    print(f"index build {knowledge.build}, {knowledge.stats()['db']}")
    print(report(run_all(knowledge, tc), run_all(look, tc), run_all(knowledge, hc), run_all(look, hc), a.show_heldout))
    return 0


if __name__ == "__main__":
    sys.exit(main())

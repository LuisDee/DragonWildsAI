"""Overfit detector (GOAL.md §3 "No spoon-feeding / overfitting"): fail when a diff adds benchmark task text to the
companion's code (brain/ or client_mod/scripts/).

Benchmark task texts are the player lines of every benchmark case: `chat[].text`, `hints[].text` and `goal` in
evals/bench/tasks/**/*.json (seen) and logs/evals/heldout/**/*.json (held out, gitignored). A text "appears" in code
when an added line contains one of its 4-word shingles (normalised words), ignoring shingles of mostly function words.

"The diff" = everything added to brain/ and client_mod/scripts/ since BASELINE (the commit before the detector):
`git diff BASELINE` (committed since then + uncommitted, tracked files) plus untracked files there. Being diff-based,
existing code is never flagged; the moment a change copies a task's wording into the companion, this goes red.
Fix the companion's tools/perception/context instead (PRINCIPLES #2), never the case text.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path
from typing import Iterable, Iterator

import pytest

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "fc6fe31"  # 2026-10-25T22:22:24+01:00, before the detector and before any benchmark case existed
CODE_DIRS = ("brain", "client_mod/scripts")
# Test infrastructure inside brain/ (mock worlds and their scenario data): PRINCIPLES exempts data files and tests, and
# a mock legitimately mirrors benchmark wording. Every other brain/ and client_mod/scripts/ path stays strict.
EXEMPT = ("brain/mock/",)
TASK_DIRS = (ROOT / "evals" / "bench" / "cases", ROOT / "evals" / "bench" / "goal_cases", ROOT / "evals" / "bench" / "tasks",
             ROOT / "logs" / "evals" / "heldout")
N = 4
# Function words (English grammar, not game facts): a shingle made mostly of these carries no task identity.
COMMON = frozenset("""a an and are as at be but by can could do does did for from get got go have has how i if in into
is it its just me my of off on or our out please so some that the their them then there these they this to up us was
we what when where which who why will with would you your yeah ok okay hey can't don't it's i'm you're let's""".split())
WORD = re.compile(r"[a-z0-9']+")


def words(text: str) -> list[str]:
    return WORD.findall((text or "").lower())


def shingles(text: str, n: int = N) -> set[tuple[str, ...]]:
    w = words(text)
    out = set()
    for i in range(len(w) - n + 1):
        sh = tuple(w[i:i + n])
        if sum(x in COMMON for x in sh) <= n // 2:  # at least half of the words are content words
            out.add(sh)
    return out


def _texts_in(obj) -> Iterator[str]:
    """Player-facing texts of one case (or a list / {"cases": [...]} file)."""
    if isinstance(obj, list):
        for x in obj:
            yield from _texts_in(x)
    elif isinstance(obj, dict):
        if "cases" in obj and isinstance(obj["cases"], list):
            yield from _texts_in(obj["cases"])
            return
        if isinstance(obj.get("goal"), str):
            yield obj["goal"]
        for key in ("chat", "hints"):
            for line in obj.get(key) or []:
                if isinstance(line, dict) and isinstance(line.get("text"), str):
                    yield line["text"]
        adv = obj.get("adversarial")
        if isinstance(adv, dict):
            yield from _texts_in({"chat": adv.get("chat") or []})


def task_texts(dirs: Iterable[Path] = TASK_DIRS) -> list[str]:
    out = []
    for d in dirs:
        for p in sorted(d.rglob("*.json")) if d.exists() else []:
            try:  # "<phrase the need: ...>" placeholders of draft cases are not player text
                out.extend(t for t in _texts_in(json.loads(p.read_text(encoding="utf-8"))) if not t.lstrip().startswith("<"))
            except (OSError, ValueError):
                continue
    return out


def _h(x: str) -> str:
    import hashlib
    return hashlib.sha256(x.encode("utf-8")).hexdigest()[:10]


def find_overlaps(added: Iterable[tuple[str, int, str]], texts: Iterable[str]) -> list[str]:
    """added: (file, line_no, line). Returns 'file:line: shingle #<hash> of a benchmark case text' per hit. Only
    hashes are printed, never the text: a failure message must not leak held-out cases (review finding 8c)."""
    index: dict[tuple[str, ...], str] = {}
    for t in texts:
        for sh in shingles(t):
            index.setdefault(sh, t)
    hits = []
    for f, n, line in added:
        for sh in shingles(line):
            if sh in index:
                hits.append(f"{f}:{n}: shingle #{_h(' '.join(sh))} of benchmark case text #{_h(index[sh])}")
                break
    return hits


def _git(*args: str) -> str | None:
    if not shutil.which("git"):
        return None
    try:
        p = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=60,
                           encoding="utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout if p.returncode == 0 else None


def added_lines() -> list[tuple[str, int, str]] | None:
    diff = _git("diff", "--unified=0", "--no-color", "--no-ext-diff", BASELINE, "--", *CODE_DIRS)
    untracked = _git("ls-files", "--others", "--exclude-standard", "--", *CODE_DIRS)
    if diff is None or untracked is None:
        return None
    out, cur, n = [], None, 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            cur = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)
            n = int(m.group(1)) if m else 0
        elif line.startswith("+") and cur:
            out.append((cur, n, line[1:]))
            n += 1
    for rel in untracked.splitlines():
        p = ROOT / rel.strip()
        if p.suffix in (".py", ".lua", ".md", ".json", ".txt") and p.is_file():
            for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                out.append((rel.strip(), i, line))
    return out


def test_no_benchmark_task_text_added_to_companion_code():
    texts = task_texts()
    if not texts:
        pytest.skip("no benchmark cases yet (evals/bench/tasks, logs/evals/heldout)")
    added = added_lines()
    if added is None:
        pytest.skip(f"git unavailable or baseline {BASELINE} missing")
    hits = find_overlaps([a for a in added if not a[0].replace("\\", "/").startswith(EXEMPT)], texts)
    assert not hits, ("benchmark task text copied into the companion (GOAL.md §3 overfit detector); fix tools, "
                      "perception or context instead:\n" + "\n".join(hits[:40]))


def test_no_benchmark_canary_in_companion_code_or_data():
    """Every case file carries the canary (evals/bench CANARY): it must never appear in what the companion reads."""
    from evals.bench import CANARY
    hits = []
    for base in ("brain", "client_mod/scripts", "data"):
        for p in (ROOT / base).rglob("*"):
            if p.is_file() and p.suffix in (".py", ".lua", ".json", ".md", ".txt") and p.stat().st_size < 5_000_000:
                if CANARY in p.read_text(encoding="utf-8", errors="ignore"):
                    hits.append(str(p.relative_to(ROOT)))
    assert not hits, "benchmark canary found in companion files: " + ", ".join(hits)


# ------------------------------------------------------------------ the detector itself


def test_detects_a_copied_phrase_in_code_or_comment():
    texts = ["can you get me 50 coal? the wiki says where, use the lodestones if it's far"]
    added = [("brain/controller.py", 10, 'HINT = "use the lodestones if it\'s far"'),
             ("brain/x.py", 3, "# when he says get me 50 coal, mine it"),
             ("brain/y.py", 7, "x = compute(state)")]
    hits = find_overlaps(added, texts)
    assert [h.split(":")[0] for h in hits] == ["brain/controller.py", "brain/x.py"]
    assert not any("lodestone" in h or "coal" in h for h in hits)  # hashes only, no case text


def test_function_word_shingles_and_short_overlaps_are_ignored():
    texts = ["can you do it for me", "farm desert weed at our farm"]
    added = [("brain/a.py", 1, "# can you do it for me later"),     # all function words
             ("brain/b.py", 2, "desert weed is a plant")]           # only 2 shared words
    assert find_overlaps(added, texts) == []


def test_case_texts_are_read_from_chat_hints_goal_and_adversarial(tmp_path):
    (tmp_path / "a.json").write_text(json.dumps({"cases": [
        {"id": "x", "chat": [{"at_s": 0, "text": "line one here now"}], "hints": [{"text": "hint text goes here"}],
         "adversarial": {"chat": [{"text": "hold on come here quick"}]}}, {"goal": "a goal text"}]}), encoding="utf-8")
    assert sorted(task_texts([tmp_path])) == sorted(["line one here now", "hint text goes here",
                                                     "hold on come here quick", "a goal text"])

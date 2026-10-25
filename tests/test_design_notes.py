"""Strict search enforcement (Luis, GOAL.md §2 step 4; PRINCIPLES #6): every design note that is new or modified after
the enforcement baseline must carry a "Search record" section with at least 3 distinct source URLs.

Which notes are "new or modified" is decided from git, never from file mtimes:
- a note not in ALLOWLIST (the notes that existed at BASELINE) is new: it needs a search record;
- an allowlisted note is exempt only while it is unchanged since BASELINE: a later commit touching it
  (git log BASELINE..HEAD) or an uncommitted change (git status) makes it modified, so it needs one too.
The baseline is the last commit before enforcement (2026-10-25 22:22 +01:00). Extend nothing here to silence a
failure: add the Search record to the note (the search-before-building skill's template).
"""
from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DESIGN = ROOT / "docs" / "design"
BASELINE = "fc6fe31"  # Checkpoint 2026-10-25T22:22:24+01:00: the last commit before enforcement
# Notes that existed at BASELINE (git ls-tree fc6fe31 docs/design). Exempt only while unchanged since then.
ALLOWLIST = frozenset({
    "PRINCIPLES.md",
    "autonomy-plan.md",
    "client-spells.md",
    "companion-quality.md",
    "knowledge-lookup.md",
    "r2-crafting.md",
    "real-player-remediation.md",
    "robustness-and-item-catalog.md",
    "streamline-plan.md",
})
MIN_URLS = 3
HEADING = re.compile(r"^(#{1,6})\s+(.*\S)\s*$")
URL = re.compile(r"https?://[^\s<>()\[\]`'\"]+")


def git(*args: str) -> str | None:
    if not shutil.which("git"):
        return None
    try:
        p = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout if p.returncode == 0 else None


def search_record_urls(text: str) -> set[str] | None:
    """URLs inside the first heading that names "Search record" (any level), up to the next heading of the same or a
    higher level. None when there is no such section."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = HEADING.match(line)
        if not m or "search record" not in m.group(2).lower():
            continue
        level = len(m.group(1))
        body = []
        for nxt in lines[i + 1:]:
            h = HEADING.match(nxt)
            if h and len(h.group(1)) <= level:
                break
            body.append(nxt)
        return {u.rstrip(".,;:") for u in URL.findall("\n".join(body))}
    return None


def changed_since_baseline() -> set[str] | None:
    """Note file names touched by a commit after BASELINE, or with uncommitted / untracked changes."""
    committed = git("log", "--format=", "--name-only", f"{BASELINE}..HEAD", "--", "docs/design")
    status = git("status", "--porcelain", "--untracked-files=all", "--", "docs/design")
    if committed is None or status is None:
        return None
    names = {Path(x.strip()).name for x in committed.splitlines() if x.strip()}
    for line in status.splitlines():
        path = line[3:].split(" -> ")[-1].strip().strip('"')
        if path:
            names.add(Path(path).name)
    return names


def notes_requiring_record() -> list[Path]:
    changed = changed_since_baseline()
    if changed is None:
        pytest.skip("git unavailable: cannot tell new/modified design notes (the check needs git history)")
    return sorted(p for p in DESIGN.glob("*.md") if p.name not in ALLOWLIST or p.name in changed)


def test_baseline_commit_exists():
    if git("rev-parse", "--verify", "--quiet", f"{BASELINE}^{{commit}}") is None:
        pytest.skip("git unavailable or shallow clone without the baseline commit")


def test_allowlist_is_exactly_the_baseline_notes():
    """The allowlist may not grow: it is the set of notes at BASELINE, nothing added later."""
    out = git("ls-tree", "--name-only", BASELINE, "docs/design/")
    if out is None:
        pytest.skip("git unavailable")
    at_baseline = {Path(x).name for x in out.splitlines() if x.endswith(".md")}
    assert ALLOWLIST == at_baseline


def test_new_or_modified_design_notes_have_a_search_record():
    problems = []
    for p in notes_requiring_record():
        urls = search_record_urls(p.read_text(encoding="utf-8", errors="replace"))
        if urls is None:
            problems.append(f"{p.relative_to(ROOT)}: no 'Search record' section")
        elif len(urls) < MIN_URLS:
            problems.append(f"{p.relative_to(ROOT)}: Search record has {len(urls)} distinct URL(s), needs >= {MIN_URLS}")
    assert not problems, ("design notes created or modified after 2026-10-25 need a '## Search record' with >= 3 "
                          "source URLs (.claude/skills/search-before-building):\n" + "\n".join(problems))


# ------------------------------------------------------------------ the parser itself


def test_parser_reads_only_the_search_record_section():
    text = ("# Note\n\nSee https://a.example/x.\n\n## Search record\n- one https://b.example/1\n"
            "- two https://c.example/2, three (https://d.example/3).\n### sub\n- https://e.example/4\n"
            "## Next\n- https://f.example/5\n")
    assert search_record_urls(text) == {"https://b.example/1", "https://c.example/2", "https://d.example/3",
                                        "https://e.example/4"}


def test_parser_none_without_section_and_dedupes():
    assert search_record_urls("# A\n## Precedent\nhttps://x.example\n") is None
    assert search_record_urls("## Step 6: search record (2026)\nhttps://x.example/a\nhttps://x.example/a\n") == {
        "https://x.example/a"}

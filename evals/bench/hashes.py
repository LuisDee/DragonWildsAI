"""Hashes that bind measurements to code (design §9): the companion hash (what is being judged), the judge hash
(what judges it), the body hash (client Lua: part of the validity key) and the game build.

Both runner and goal_check use these, so a run and the check agree on what "current" means. Git trees are used
(blob ids at HEAD) plus a dirty flag, so hashing is cheap and independent of untracked noise."""
from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Judge files (design §9.3): everything that decides a score. A change since Luis's judge tag = NOT MET.
JUDGE_PATHS = (
    "docs/goal_targets.json", "docs/GOAL.md",
    "tools/goal_check.py", "tools/goal_confirm.py",
    "evals/bench",
    "brain/predicates.py",
    "data/spell_effects.json", "data/spell_purposes.json",
    "client_mod/commands/bench_probe.lua", "mod/bench", "mod/scripts/bench.lua", "tools/hooks/judge_guard.py",
    # Luis 2026-10-26: the obs metrics and the voice eval score GOAL targets too
    "tools/obs.py", "tools/obs_tasks.py", "evals/voice_eval.py", "evals/voice_fixtures.py", "evals/voice_cases.jsonl",
    "evals/fixtures",
)
# What is being judged: the brain, the client body and the data profiles (judge files excluded).
COMPANION_PATHS = ("brain", "client_mod/scripts", "data")
COMPANION_EXCLUDE = ("brain/predicates.py", "data/spell_effects.json", "data/spell_purposes.json", "data/wiki/",
                     "data/skills/", "data/envelopes/")
BODY_PATHS = ("client_mod/scripts",)


def git(*args: str, root: Path = ROOT) -> str | None:
    if not shutil.which("git"):
        return None
    try:
        p = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=60,
                           encoding="utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout if p.returncode == 0 else None


def _excluded(path: str, exclude: tuple[str, ...]) -> bool:
    return any(path == e or (e.endswith("/") and path.startswith(e)) for e in exclude)


def tree_hash(paths: tuple[str, ...], exclude: tuple[str, ...] = (), root: Path = ROOT) -> str:
    """sha256 over the HEAD blob ids of the paths (minus exclusions), suffixed "+dirty" when any of them has
    uncommitted changes (tracked or untracked). "nogit" when git is unavailable."""
    out = git("ls-tree", "-r", "HEAD", "--", *paths, root=root)
    if out is None:
        return "nogit"
    rows = sorted(line for line in out.splitlines() if line and not _excluded(line.split("\t", 1)[-1], exclude))
    h = hashlib.sha256("\n".join(rows).encode("utf-8")).hexdigest()[:16]
    return h + ("+dirty" if dirty(paths, exclude, root) else "")


def dirty(paths: tuple[str, ...], exclude: tuple[str, ...] = (), root: Path = ROOT) -> bool:
    out = git("status", "--porcelain", "--untracked-files=all", "--", *paths, root=root)
    if out is None:
        return True
    for line in out.splitlines():
        p = line[3:].split(" -> ")[-1].strip().strip('"')
        if p and not _excluded(p, exclude):
            return True
    return False


def companion_hash(root: Path = ROOT) -> str:
    return tree_hash(COMPANION_PATHS, COMPANION_EXCLUDE, root)


def judge_hash(root: Path = ROOT) -> str:
    return tree_hash(JUDGE_PATHS, (), root)


SCORER_PATHS = ("brain/predicates.py", "evals/bench/leaves.py", "evals/bench/observer.py")


def scorer_hash(root: Path = ROOT) -> str:
    """The code that turns evidence into pass/fail: part of the validity key (finding 3)."""
    return tree_hash(SCORER_PATHS, (), root)


def body_hash(root: Path = ROOT) -> str:
    return tree_hash(BODY_PATHS, (), root)


def head_sha(root: Path = ROOT) -> str | None:
    out = git("rev-parse", "HEAD", root=root)
    return out.strip() if out else None


def tree_clean(root: Path = ROOT) -> bool:
    out = git("status", "--porcelain", "--untracked-files=no", root=root)
    return out is not None and not out.strip()


def game_build(root: Path = ROOT) -> str | None:
    """The build the catalogs were generated from (newest data/spells_<build>.json)."""
    builds = sorted(int(m.group(1)) for f in (root / "data").glob("spells_*.json")
                    if (m := re.fullmatch(r"spells_(\d+)\.json", f.name)))
    return str(builds[-1]) if builds else None


def judge_diff_since(tag: str, root: Path = ROOT) -> list[str] | None:
    """Judge files changed since the tag (committed or in the working tree); None if the tag is unknown."""
    if git("rev-parse", "--verify", "--quiet", f"{tag}^{{commit}}", root=root) is None:
        return None
    out = git("diff", "--name-only", tag, "--", *JUDGE_PATHS, root=root)
    untracked = git("ls-files", "--others", "--exclude-standard", "--", *JUDGE_PATHS, root=root)
    if out is None or untracked is None:
        return None
    return sorted({x.strip() for x in (out + "\n" + untracked).splitlines() if x.strip()})


def sha256_file(path: Path) -> str | None:
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()
    except OSError:
        return None


def validity_key(case_hash: str, scorer: str, body: str, build: str | None, entry_hash: str = "") -> str:
    """Validity is re-opened by any change to the case, the judge, the client body, the build, or the case's own
    spell_effects entry (review finding 3)."""
    return hashlib.sha256("|".join([case_hash, scorer, body, build or "", entry_hash]).encode()).hexdigest()[:20]

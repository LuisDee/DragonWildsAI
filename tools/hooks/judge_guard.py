"""Claude Code PreToolUse hook: while a /goal run is active, nobody edits the judge or reads the held-out set
(review findings 5e, 8b; design eval-benchmark.md §9.3). Drafted by the Eval agent; main/Luis install it.

Install (Luis's OK; .claude/settings.json):
  {"hooks": {"PreToolUse": [{"matcher": "Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell|Read|Grep|Glob",
                             "hooks": [{"type": "command", "command": ".venv\\\\Scripts\\\\python.exe tools/hooks/judge_guard.py"}]}]}}
  plus deny rules for the same paths (defence in depth), e.g. "Edit(docs/goal_targets.json)", "Read(logs/evals/heldout/**)".

Active when the environment has DW_GOAL_ACTIVE=1 or the marker file logs/goal_active exists (the marker itself is a
protected path, so an agent can't switch the guard off by deleting it). Inactive: every call is allowed.

Decision (stdin: the hook JSON {tool_name, tool_input, ...}; stdout: the hook decision JSON; exit 0):
- Edit / Write / MultiEdit / NotebookEdit on a judge file  -> deny
- Read / Grep / Glob on the held-out paths                 -> deny
- Bash / PowerShell that writes to a judge file (redirect, sed -i, tee, rm, mv, cp, git checkout/restore/apply/reset,
  Set-Content, Out-File, Remove-Item, Move-Item, Copy-Item, python/node -c ... open(...,'w')), creates or moves a
  git tag, or touches a held-out path at all                -> deny
Reasons name the rule; changing a judge file during /goal is a "stop and ask Luis" item (GOAL.md §5).
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
MARKER = "logs/goal_active"
JUDGE = (
    "docs/goal_targets.json", "docs/GOAL.md", "tools/goal_check.py", "tools/goal_confirm.py", "tools/hooks/judge_guard.py",
    "evals/bench/", "brain/predicates.py", "data/spell_effects.json", "data/spell_purposes.json",
    "client_mod/commands/bench_probe.lua", "mod/bench/", "logs/evals/scoreboard.jsonl", "logs/evals/validity/",
    "logs/evals/goal_checks.jsonl", "logs/evals/confirmations/", ".claude/settings.json", ".claude/settings.local.json",
    # Luis 2026-10-26: the obs metrics and the voice eval score GOAL targets too
    "tools/obs.py", "tools/obs_tasks.py", "evals/voice_eval.py", "evals/voice_fixtures.py", "evals/voice_cases.jsonl",
    "evals/fixtures/",
    MARKER,
)
HELDOUT = ("logs/evals/heldout/", "logs/evals/heldout_runs/")
FILE_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
READ_TOOLS = ("Read", "Grep", "Glob")
SHELL_TOOLS = ("Bash", "PowerShell")
WRITE_HINT = re.compile(
    r"(>>?|\btee\b|\bsed\s+-i|\brm\b|\bmv\b|\bcp\b|\btruncate\b|\bdd\b|\bgit\s+(checkout|restore|apply|reset|mv|rm|stash|revert|cherry-pick)\b"
    r"|Set-Content|Add-Content|Out-File|Remove-Item|Move-Item|Copy-Item|Rename-Item|New-Item|Clear-Content"
    r"|open\([^)]*['\"][wa]|write_text|write_bytes|unlink\(|shutil\.)", re.I)
GIT_TAG = re.compile(r"\bgit\s+(tag|push\s+.*--tags|update-ref)\b", re.I)


def active(root: Path = ROOT) -> bool:
    return os.environ.get("DW_GOAL_ACTIVE") == "1" or (root / MARKER).exists()


def norm(p: str, root: Path = ROOT) -> str:
    """A repo-relative POSIX path (lower-case on Windows paths) for prefix matching."""
    s = str(p or "").replace("\\", "/").strip().strip('"').strip("'")
    r = str(root).replace("\\", "/").rstrip("/")
    if s.lower().startswith(r.lower() + "/"):
        s = s[len(r) + 1:]
    while s.startswith("./"):
        s = s[2:]
    return str(PurePosixPath(s)).lower() if s else ""


def _hit(path: str, prefixes: tuple[str, ...]) -> str | None:
    for pre in prefixes:
        pl = pre.lower()
        if path == pl.rstrip("/") or (pl.endswith("/") and path.startswith(pl)) or path == pl:
            return pre
    return None


def _mentions(cmd: str, prefixes: tuple[str, ...], root: Path) -> str | None:
    c = cmd.replace("\\", "/").lower()
    r = str(root).replace("\\", "/").lower().rstrip("/") + "/"
    c = c.replace(r, "")
    for pre in prefixes:
        if pre.lower().rstrip("/") in c:
            return pre
    return None


def decide(payload: dict, root: Path = ROOT) -> tuple[str, str]:
    """("allow" | "deny", reason)."""
    if not active(root):
        return "allow", "no /goal run active"
    tool = str(payload.get("tool_name") or "")
    ti = payload.get("tool_input") or {}
    if tool in FILE_TOOLS:
        p = norm(ti.get("file_path") or ti.get("notebook_path") or "", root)
        if (j := _hit(p, JUDGE)) is not None:
            return "deny", f"judge file {j} is frozen during /goal (GOAL.md §5: stop and ask Luis)"
        if _hit(p, HELDOUT) is not None:
            return "deny", "the held-out set is sealed during /goal"
    if tool in READ_TOOLS:
        for k in ("file_path", "path", "pattern", "glob"):
            v = ti.get(k)
            if v and (_hit(norm(v, root), HELDOUT) is not None or _mentions(str(v), HELDOUT, root)):
                return "deny", "the held-out set is sealed during /goal"
    if tool in SHELL_TOOLS:
        cmd = str(ti.get("command") or "")
        if _mentions(cmd, HELDOUT, root):
            return "deny", "the held-out set is sealed during /goal"
        if GIT_TAG.search(cmd):
            return "deny", "git tags (the Luis-approved judge tag) can't be created or moved during /goal"
        if (j := _mentions(cmd, JUDGE, root)) and WRITE_HINT.search(cmd):
            return "deny", f"this command would change judge file {j}, frozen during /goal (stop and ask Luis)"
    return "allow", ""


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        payload = {}
    decision, reason = decide(payload)
    if decision == "deny":
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": reason}}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

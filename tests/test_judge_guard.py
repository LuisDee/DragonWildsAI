"""tools/hooks/judge_guard.py: during /goal the judge is frozen and the held-out set sealed (review findings 5e, 8b)."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from tools.hooks import judge_guard as jg

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def on(monkeypatch):
    monkeypatch.setenv("DW_GOAL_ACTIVE", "1")


def d(tool, **ti):
    return jg.decide({"tool_name": tool, "tool_input": ti}, ROOT)[0]


def test_inactive_allows_everything(monkeypatch, tmp_path):
    monkeypatch.delenv("DW_GOAL_ACTIVE", raising=False)
    assert jg.decide({"tool_name": "Edit", "tool_input": {"file_path": "docs/goal_targets.json"}}, tmp_path)[0] == "allow"


@pytest.mark.parametrize("path", ["docs/goal_targets.json", str(ROOT / "evals" / "bench" / "leaves.py"),
                                  str(ROOT / "brain" / "predicates.py"), "./data/spell_effects.json", "mod/bench/fixtures.lua",
                                  "logs/evals/scoreboard.jsonl", "logs/evals/validity/abc.json", ".claude/settings.json",
                                  "logs/goal_active"])
def test_file_edits_to_judge_files_are_denied(on, path):
    assert d("Edit", file_path=path) == "deny"
    assert d("Write", file_path=path) == "deny"


def test_companion_files_stay_editable(on):
    assert d("Edit", file_path="brain/controller.py") == "allow"
    assert d("Write", file_path="client_mod/scripts/spells.lua") == "allow"
    assert d("Read", file_path="evals/bench/leaves.py") == "allow"  # reading the judge is fine


def test_heldout_reads_and_shell_access_are_denied(on):
    assert d("Read", file_path="logs/evals/heldout/batch1.json") == "deny"
    assert d("Grep", pattern="coal", path="logs/evals/heldout_runs") == "deny"
    assert d("Glob", pattern="logs/evals/heldout/**") == "deny"
    assert d("Bash", command="cat logs/evals/heldout/batch1.json") == "deny"


@pytest.mark.parametrize("cmd", [
    "echo 99 > docs/goal_targets.json",
    "sed -i 's/95/5/' docs/goal_targets.json",
    "git checkout HEAD~3 -- tools/goal_check.py",
    "python -c \"open('evals/bench/leaves.py','w').write('')\"",
    "Set-Content -Path brain/predicates.py -Value x",
    "rm logs/goal_active",
    "git tag -f goal-judge-20261026",
])
def test_shell_writes_to_the_judge_and_tags_are_denied(on, cmd):
    assert d("Bash", command=cmd) == "deny"


def test_shell_reads_of_the_judge_are_allowed(on):
    assert d("Bash", command="python -m tools.goal_check --all") == "allow"
    assert d("Bash", command="cat docs/goal_targets.json") == "allow"
    assert d("Bash", command="python -m pytest tests/test_goal_check.py") == "allow"


def test_hook_protocol_output(monkeypatch, tmp_path):
    env = {**__import__("os").environ, "DW_GOAL_ACTIVE": "1"}
    p = subprocess.run([sys.executable, str(ROOT / "tools" / "hooks" / "judge_guard.py")], input=json.dumps(
        {"tool_name": "Edit", "tool_input": {"file_path": "docs/goal_targets.json"}}), capture_output=True, text=True, env=env)
    out = json.loads(p.stdout)
    assert p.returncode == 0 and out["hookSpecificOutput"]["permissionDecision"] == "deny"
    p = subprocess.run([sys.executable, str(ROOT / "tools" / "hooks" / "judge_guard.py")], input=json.dumps(
        {"tool_name": "Edit", "tool_input": {"file_path": "brain/agent.py"}}), capture_output=True, text=True, env=env)
    assert p.returncode == 0 and p.stdout.strip() == ""


def test_obs_and_the_voice_eval_are_judge_files():
    """Luis 2026-10-26: tools/obs.py (and the voice eval) score GOAL targets, so they are frozen with the judge."""
    from evals.bench import hashes
    from tools.hooks import judge_guard as jg
    for f in ("tools/obs.py", "tools/obs_tasks.py", "evals/voice_eval.py", "evals/voice_cases.jsonl"):
        assert any(f.startswith(j) for j in jg.JUDGE), f
        assert any(f == j or f.startswith(j + "/") or f.startswith(j) for j in hashes.JUDGE_PATHS), f

"""Every benchmark module compiles and imports (main 2026-10-26: a SyntaxError in devtarget.py reached the spells
agent; this catches that class of break before anyone runs a fixture)."""
from __future__ import annotations

import importlib
import py_compile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
FILES = sorted((ROOT / "evals" / "bench").glob("*.py")) + [ROOT / "tools" / "goal_check.py",
                                                         ROOT / "tools" / "hooks" / "judge_guard.py"]


@pytest.mark.parametrize("path", FILES, ids=lambda p: p.name)
def test_compiles(path):
    py_compile.compile(str(path), doraise=True)


@pytest.mark.parametrize("mod", [f"evals.bench.{p.stem}" for p in sorted((ROOT / "evals" / "bench").glob("*.py"))
                                 if p.stem != "__main__"])
def test_imports(mod):
    importlib.import_module(mod)

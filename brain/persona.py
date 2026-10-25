"""The Controller's persona template, kept in brain/persona.md (voice workstream V, companion-quality.md §3).

The text lives in a Markdown file so the voice can be edited without touching code; it is re-read
when the file changes (like house_rules.md). Placeholders, filled by ``render``: {name} {player}
{triggers} {look_rule} {lookup_rule}. Any other brace in the file is a mistake and fails the tests.
DW_PERSONA overrides the path (evals and A/B tests).
"""
from __future__ import annotations

import os
from pathlib import Path

PLACEHOLDERS = ("name", "player", "triggers", "look_rule", "lookup_rule")
DEFAULT_PATH = Path(__file__).with_name("persona.md")

_cache: dict[str, tuple[float, str]] = {}


def persona_path() -> Path:
    return Path(os.environ.get("DW_PERSONA") or DEFAULT_PATH)


def template(path: Path | None = None, fallback: str | None = None) -> str:
    """The persona template text (re-read when the file's mtime changes). ``fallback`` when the file is
    missing or unreadable (the brain must keep a voice even if the file is deleted)."""
    p = Path(path) if path is not None else persona_path()
    try:
        mtime = p.stat().st_mtime
        hit = _cache.get(str(p))
        if hit is None or hit[0] != mtime:
            hit = (mtime, p.read_text(encoding="utf-8").strip())
            _cache[str(p)] = hit
        return hit[1]
    except OSError:
        if fallback is None:
            raise
        return fallback


def render(text: str, **values: str) -> str:
    """Fill the placeholders (all of them are required, so a missing one fails loudly in tests)."""
    missing = [k for k in PLACEHOLDERS if k not in values]
    if missing:
        raise KeyError(f"persona placeholders not given: {missing}")
    return text.format(**{k: values[k] for k in PLACEHOLDERS})

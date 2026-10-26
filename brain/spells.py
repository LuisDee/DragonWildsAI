"""The Controller's view of spells: a compact list of what the companion can cast.

Built from the body's ``spells`` answer (body/spells.lua ``list({compact=true})``: the catalog
filtered by Luis's unlocks, verified routes, cooldowns and runes), cached for ``ttl`` seconds so a
chat line costs at most one extra bridge round trip a minute. A body without the ``spells`` handler
falls back to the catalog file (data/spells_<build>.json): spells Luis had unlocked in the catalog's
player snapshot whose route is verified in game. Rows are trimmed to what a prompt needs:
``{name, role, use_when}`` plus ``note`` when something blocks it for now, and ``for`` / ``needs``
(what the spell is for, what the game requires) from data/spell_effects.json.
"""
from __future__ import annotations

import json
import time
from functools import lru_cache
from pathlib import Path
from typing import Callable

from .interface import GameInterface, Reason

REPO = Path(__file__).resolve().parents[1]
DEFAULT_CATALOG = REPO / "data" / "spells_26161880.json"
# what each spell is FOR and what it NEEDS (tools/gen_spell_effects.py, from the spell data + purposes)
EFFECTS = REPO / "data" / "spell_effects.json"
USE_WHEN_CHARS = 140
MAX_ROWS = 40  # rows are short; the model needs every castable spell (spells agent, 2026-10-25)


@lru_cache(maxsize=1)
@lru_cache(maxsize=2)
def effects(path: str | None = None) -> dict:
    """data/spell_effects.json "spells" (id -> purposes, unlock, cost, cooldown, requirement...): the ONE
    loader for it (spells rows, the needs digest). {} when missing or bad."""
    try:
        return json.loads(Path(path or EFFECTS).read_text(encoding="utf-8")).get("spells") or {}
    except (OSError, ValueError):
        return {}


def _effects() -> dict:
    return effects()


def purpose_of(spell_id: str | None) -> dict:
    """{"for", "needs"} for one spell id from data/spell_effects.json; {} when unknown (nothing invented)."""
    e = _effects().get(spell_id or "") or {}
    out = {}
    if e.get("for"):
        out["for"] = e["for"]
    if e.get("needs"):
        out["needs"] = e["needs"]
    return out


def compact_row(row: dict) -> dict:
    out = {"name": row.get("name") or row.get("id"), "role": row.get("role", "other"),
           "use_when": (row.get("use_when") or "")[:USE_WHEN_CHARS]}
    out.update(purpose_of(row.get("id")))
    if row.get("how"):  # how it is really used (spells.lua, from data/spell_mechanics.json): e.g. drop 5 ore, then cast on them
        out["how"] = row["how"]
    reason = row.get("reason")
    if reason == Reason.ON_COOLDOWN:
        out["note"] = f"on cooldown ({row.get('remaining_s', 0):.0f}s)"
    elif reason == Reason.NOT_ENOUGH:
        out["note"] = "no runes for it"
    elif reason == REQUIREMENT:
        # the game's own special requirement is unmet (e.g. "A held melee weapon"): he can fix it himself
        need = row.get("needs") if isinstance(row.get("needs"), str) else out.get("needs")
        out["note"] = f"needs {need} first" if need else "its game requirement is not met"
    if "note" in out:
        # (M2 gap audit 2026-10-26) the Controller's spell_lines renders castable/reason, not `note`: without
        # these a spell on cooldown or out of runes read as castable to the model
        out["castable"], out["reason"] = False, out["note"]
    return out


REQUIREMENT = "requirement"  # spells.lua row.reason when the spell's SpecialRequirementsStrategy fails
# rows kept for the model: castable now, or blocked by something he can fix (wait, runes, hold the right tool)
FIXABLE = (Reason.ON_COOLDOWN, Reason.NOT_ENOUGH, REQUIREMENT)


def from_body(rows: list[dict]) -> list[dict]:
    keep = [r for r in rows if r.get("castable") or r.get("reason") in FIXABLE]
    return [compact_row(r) for r in keep][:MAX_ROWS]


def from_catalog(doc: dict, unlocked: set[str] | None = None) -> list[dict]:
    """Catalog fallback: spells Luis has unlocked (snapshot) whose route is verified in game."""
    if unlocked is None:
        players = doc.get("players") or []
        unlocked = set(players[0].get("spells_unlocked") or []) if players else set()
    routes = doc.get("routes") or {}
    out = []
    for sid, rec in sorted((doc.get("spells") or {}).items()):
        usage = rec.get("usage") or {}
        route = usage.get("route", "none")
        if sid not in unlocked or route == "none" or not (routes.get(route) or {}).get("verified"):
            continue
        out.append(compact_row({"name": rec.get("name") or usage.get("name") or sid, "role": usage.get("role"),
                                "use_when": usage.get("use_when")}))
    return out[:MAX_ROWS]


class SpellBook:
    def __init__(self, game: GameInterface, catalog_path: Path | None = DEFAULT_CATALOG, ttl: float = 60.0,
                 clock: Callable[[], float] = time.monotonic):
        self.game = game
        self.catalog_path = catalog_path
        self.ttl = ttl
        self.clock = clock
        self._at: float | None = None
        self._rows: list[dict] = []
        self.source = "none"

    def invalidate(self) -> None:
        self._at = None

    def castable(self) -> list[dict]:
        now = self.clock()
        if self._at is not None and now - self._at < self.ttl:
            return self._rows
        self._at = now
        res = self.game.spells()
        if res.get("ok") and isinstance(res["data"].get("spells"), list):
            self._rows, self.source = from_body(res["data"]["spells"]), "body"
        else:
            self._rows, self.source = self._from_file(), "catalog"
        return self._rows

    def _from_file(self) -> list[dict]:
        if not self.catalog_path or not Path(self.catalog_path).exists():
            return []
        try:
            return from_catalog(json.loads(Path(self.catalog_path).read_text(encoding="utf-8")))
        except (OSError, ValueError):
            return []

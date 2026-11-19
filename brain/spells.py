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
import math
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
    if el := element_words(e):  # the element says more than a generic "stronger melee hits"
        out["for"] = el
    if e.get("needs"):
        out["needs"] = e["needs"]
    return out


def element_words(e: dict) -> str | None:
    """What element a spell's verified effect carries (proof.effect[].damage_types), so he can match it to what an
    enemy is weak to or resists (Luis 2026-11-01: an element enchant is worth casting before any melee fight unless
    the enemy resists that element; the same for attack spells). None when the data names no element."""
    for fx in ((e.get("proof") or {}).get("effect") or []):
        types = [str(t).rsplit(".", 1)[-1] for t in (fx.get("damage_types") or []) if t]
        if not types:
            continue
        el = "/".join(types)
        if fx.get("kind") == "held_item_effect":
            secs = f" {fx['time_limit_s']:.0f} s" if isinstance(fx.get("time_limit_s"), (int, float)) else ""
            return f"+{el} damage on melee hits{secs}; cast before melee unless the enemy resists {el}"
        return f"{el} damage: best on an enemy weak to {el}"
    return None


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0 else None


def recharge_of(row: dict | None, effect: dict | None = None) -> float | None:
    """The game's recharge time after a cast (UtilitySpellData.CooldownDuration), in s: the body's row
    (``cooldown_s``; ``recharge_s`` on a compact row), else the game data's (data/spell_effects.json). None: unknown."""
    row = row or {}
    return _num(row.get("recharge_s")) or _num(row.get("cooldown_s")) or _num((effect or {}).get("cooldown_s"))


def recharging_words(left: float | None, recharge: float | None) -> str:
    """'recharging, 83 s left (300 s after each cast)': the seconds left as the body read them (the game's
    LastCastTimeBySpellData against the server clock), rounded up as the body's own sentence does."""
    words = "recharging" + (f", {math.ceil(left)} s left" if left else "")
    return words + (f" ({recharge:.0f} s after each cast)" if recharge else "")


def castable_words(recharge: float | None) -> str:
    return "castable now" + (f"; recharges {recharge:.0f} s after each cast" if recharge else "")


def status_words(row: dict | None, effect: dict | None = None) -> tuple[bool, str]:
    """(castable now, the words) for one of HIS spell rows, any shape (get_state ``spells``, the body's ``spells``
    read, a compact row): castable now and how long it then recharges, or the seconds left, or what blocks it.
    Live 2026-11-19 (L2-V1): "castable now" with no recharge time let plans queue four 300 s casts in a row."""
    row = row or {}
    recharge = recharge_of(row, effect)
    if row.get("reason") == Reason.ON_COOLDOWN or (row.get("castable") is False and _num(row.get("remaining_s"))):
        return False, recharging_words(_num(row.get("remaining_s")), recharge)
    if row.get("note") or row.get("castable", True) is False:
        return False, str(row.get("note") or row.get("reason") or "not castable now")
    return True, castable_words(recharge)


def state_lines(state: dict | None, cap: int = MAX_ROWS) -> list[str]:
    """His spells from get_state ``spells`` (the unlocked ones, read seconds ago), one short line each, for a prompt
    with no spell list of its own (the Planner's state): castable now and its recharge after each cast, the seconds
    left of a recharging one, or why it can't be cast. [] when the state has no spell rows."""
    out = []
    for r in (state or {}).get("spells") or []:
        if not isinstance(r, dict) or not r.get("name"):
            continue
        eff = effects().get(str(r.get("id") or ""))
        ok, words = status_words(r, eff)
        if not ok and not r.get("note"):
            words = (_note({**r, "recharge_s": recharge_of(r, eff)}, purpose_of(r.get("id")))
                     or f"not castable now ({r.get('reason') or '?'})")
        out.append(f"{r['name']}: {words}")
    return out[:cap]


def _note(row: dict, out: dict) -> str | None:
    """Why a FIXABLE row is not castable now, in words; None when it is castable or blocked by something else."""
    reason = row.get("reason")
    if reason == Reason.ON_COOLDOWN:
        return recharging_words(_num(row.get("remaining_s")), recharge_of(row))
    if reason == Reason.NOT_ENOUGH:
        return "no runes for it"
    if reason == REQUIREMENT:
        # the game's own special requirement is unmet (e.g. "A held melee weapon"): he can fix it himself
        need = row.get("needs") if isinstance(row.get("needs"), str) else out.get("needs")
        return f"needs {need} first" if need else "its game requirement is not met"
    return None


def compact_row(row: dict) -> dict:
    out = {"name": row.get("name") or row.get("id"), "role": row.get("role", "other"),
           "use_when": (row.get("use_when") or "")[:USE_WHEN_CHARS]}
    out.update(purpose_of(row.get("id")))
    if row.get("how"):  # how it is really used (spells.lua, from data/spell_mechanics.json): e.g. drop 5 ore, then cast on them
        out["how"] = row["how"]
    if recharge := recharge_of(row):
        out["recharge_s"] = recharge  # the game's CooldownDuration: a plan can space its casts
    if row.get("reason") == Reason.ON_COOLDOWN and _num(row.get("remaining_s")):
        out["remaining_s"] = float(row["remaining_s"])
    if note := _note(row, out):
        out["note"] = note
        # (M2 gap audit 2026-10-26) the Controller's spell_lines renders castable/reason, not `note`: without
        # these a spell on cooldown or out of runes read as castable to the model
        out["castable"], out["reason"] = False, note
    return out


def with_state(rows: list[dict], state: dict | None) -> list[dict]:
    """The compact rows (a cache up to ``SpellBook.ttl`` old) with the cooldown and castable facts of the state's own
    spell rows (get_state ``spells``, read seconds ago), matched by name: a spell cast since the cache read shows as
    recharging, and one recharged since shows castable. Other blocks keep the cached row."""
    fresh = {str(r.get("name") or "").lower(): r for r in (state or {}).get("spells") or [] if isinstance(r, dict)}
    if not fresh:
        return rows
    out = []
    for row in rows:
        f = fresh.get(str(row.get("name") or "").lower())
        if f is None or not (f.get("castable") is True or f.get("reason") in FIXABLE):
            out.append(row)
            continue
        new = {k: v for k, v in row.items() if k not in ("note", "castable", "reason", "remaining_s")}
        if recharge := recharge_of(f):
            new["recharge_s"] = recharge
        if f.get("reason") == Reason.ON_COOLDOWN and _num(f.get("remaining_s")):
            new["remaining_s"] = float(f["remaining_s"])
        if f.get("castable") is not True and (note := _note({**f, "recharge_s": new.get("recharge_s")}, new)):
            new["note"] = new["reason"] = note
            new["castable"] = False
        out.append(new)
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

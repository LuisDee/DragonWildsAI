"""The benchmark case spec (design §3): pydantic models, the chat-language lint and the case hash.

A case is what a player would say plus how the harness checks it was done. Predicates (`success`, `guards`) use the
shared format in brain/predicates.py plus evals/bench/leaves.py; they read observer evidence only (design §4)."""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from brain.interface import TOOLS

from . import CANARY

TIERS = ("T0", "T1", "T2", "T3")
RESULTS = ("pass", "fail", "unverifiable", "skip", "error", "invalid")
TARGETS = ("mock", "dev", "live_confirm")
# Families feed goal_targets.json metrics through the manifest's selector table (design §8.1).
FAMILIES = ("spell_cast", "spell_use", "station", "craft", "combat", "combat_basic", "tactics", "adversarial",
            "knowledge", "efficiency", "long_task", "gather", "skill_train", "capstone_stage", "capstone", "stress",
            "tactics_prep", "tactics_trend", "tactics_telegraph", "misc")
ASSET_ID = re.compile(r"\b(?:USD|ITEM|BP|DA|RECIPE|PerkV2|GE|SKILL)_[A-Za-z0-9_]+")
# A tool name the way code writes it: snake_case with an underscore (go_to, set_reflex_rule) or call syntax (cast(...)).
# Plain English verbs that happen to be tool names ("follow me", "drop it") are allowed: players say them.
TOOL_IDENT = re.compile(r"\b(" + "|".join(sorted((t for t in TOOLS if "_" in t), key=len, reverse=True)) + r")\b")
TOOL_CALL = re.compile(r"\b(" + "|".join(sorted(TOOLS, key=len, reverse=True)) + r")\s*\(")


class ChatLine(BaseModel):
    model_config = ConfigDict(extra="forbid")
    at_s: float = 0.0
    text: str
    # "player" = the test player on mock/dev. On live_confirm nothing is injected (design §7.4).
    from_: Literal["player"] = Field("player", alias="from")


class Hints(BaseModel):
    """A fixed ladder (design §3, finding 20): L1 a generic nudge, L2 a pointer, L3 the answer."""
    model_config = ConfigDict(extra="forbid")
    ladder: list[str] = Field(default_factory=list, max_length=3)


class Limits(BaseModel):
    model_config = ConfigDict(extra="forbid")
    wall_s: float = 300.0
    sim_s: float | None = None  # mock clock; default = wall_s
    model_calls: dict[str, int] = Field(default_factory=dict)  # {"haiku": n, "sonnet": n}; per-tier defaults
    hints_max: int = 0
    idle_s: float = 60.0
    repeat: int = 1


class Fixtures(BaseModel):
    model_config = ConfigDict(extra="allow")
    requires: list[dict] = Field(default_factory=list)  # predicates that must hold before the case starts
    setup: list[dict] = Field(default_factory=list)  # harness verbs (mock: BenchWorld; dev: mod/bench/fixtures.lua)
    scene: dict = Field(default_factory=dict)  # scene builder input (mock world / dev spawns)
    state_snapshot: str = "empty"  # evals/bench/state_snapshots/<name> (design §7.3)
    player_body: bool = False  # needs a player's body in the world (follow, delivery)


class Controls(BaseModel):
    """How the negative controls are made for this case (design §6). ambient and claims_only need nothing."""
    model_config = ConfigDict(extra="allow")
    wrong_action: list[dict] | None = None  # the oracle with a sibling substituted (tool calls)
    alt_means: list[dict] | None = None  # the predicate's proxy produced another way (tool calls and/or setup verbs)
    partial: list[dict] | None = None  # the oracle cut short (default: oracle minus its last step)
    na: dict[str, str] = Field(default_factory=dict)  # control -> why it doesn't apply (e.g. no sibling spell)


class Case(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)
    id: str
    version: int = 1
    tier: Literal["T0", "T1", "T2", "T3"]
    family: str
    long_task: str | None = None
    basic: str | None = None
    skill: str | None = None  # every_skill (M3): the skill asset name, e.g. "Mining"
    mode: str | None = None  # every_skill: asked | initiative | plus5
    capstone: str | None = None  # M6: slay_velgar_solo | ...
    authored_by: Literal["generator", "human", "data"] = "data"
    status: Literal["draft", "candidate", "suite"] = "candidate"
    tags: dict[str, Any] = Field(default_factory=dict)
    chat: list[ChatLine]
    phrasing_heldout: str | None = None
    forbid_terms: list[str] = Field(default_factory=list)  # words the chat must not contain (e.g. the spell's name)
    fixtures: Fixtures = Field(default_factory=Fixtures)
    success: dict
    guards: list[dict] = Field(default_factory=list)
    needs_fact: dict | None = None  # process metric: {kind, truth} (design §4.3)
    controls: Controls = Field(default_factory=Controls)
    limits: Limits = Field(default_factory=Limits)
    hints: Hints = Field(default_factory=Hints)
    targets: list[str] = Field(default_factory=lambda: ["mock", "dev"])
    risk: Literal["low", "medium", "high"] = "low"
    oracle: dict[str, list[dict] | str] = Field(default_factory=dict)  # target -> tool calls or "scripted:<file>"
    provenance: dict[str, Any] = Field(default_factory=dict)
    heldout: bool = False
    canary: str = CANARY

    @field_validator("family")
    @classmethod
    def _family(cls, v: str) -> str:
        if v not in FAMILIES:
            raise ValueError(f"unknown family {v!r}; one of {', '.join(FAMILIES)}")
        return v

    @field_validator("targets")
    @classmethod
    def _targets(cls, v: list[str]) -> list[str]:
        bad = [t for t in v if t not in TARGETS]
        if bad:
            raise ValueError(f"unknown target(s) {bad}")
        return v

    def texts(self) -> list[str]:
        """Every player-facing text (the overfit detector reads these)."""
        out = [c.text for c in self.chat] + list(self.hints.ladder)
        if self.phrasing_heldout:
            out.append(self.phrasing_heldout)
        return out


DEFAULT_CALLS = {"T0": {"haiku": 10, "sonnet": 0}, "T1": {"haiku": 60, "sonnet": 5},
                 "T2": {"haiku": 300, "sonnet": 30}, "T3": {"haiku": 800, "sonnet": 60}}  # main approved, 2026-10-25


def calls_cap(case: Case) -> dict[str, int]:
    return {**DEFAULT_CALLS[case.tier], **case.limits.model_calls}


# ------------------------------------------------------------------ lint


def lint(case: Case) -> list[str]:
    """Problems that make a case unusable (design §3). Empty = clean."""
    probs = []
    for t in case.texts():
        if m := ASSET_ID.search(t):
            probs.append(f"asset id {m.group(0)!r} in player text {t!r}")
        if m := TOOL_IDENT.search(t):
            probs.append(f"tool name {m.group(1)!r} in player text {t!r}")
        if m := TOOL_CALL.search(t):
            probs.append(f"tool call syntax {m.group(0)!r} in player text {t!r}")
        low = t.lower()
        if t in case.hints.ladder:  # the hint ladder may carry the answer (L3 = the answer, review finding 20)
            continue
        for term in case.forbid_terms:
            if term and re.search(rf"\b{re.escape(term.lower())}\b", low):
                probs.append(f"forbidden term {term!r} in player text {t!r}")
    # A delivery request needs a delivery predicate, not "in his bag" (review finding 10d).
    said = " ".join(c.text.lower() for c in case.chat)
    if re.search(r"\b(get|bring|give|fetch|hand)\s+(me|us)\b", said) and "delivered" not in json.dumps(case.success) \
            and "on_ground" not in json.dumps(case.success):
        probs.append("the player asks for delivery ('get me', 'bring me') but success has no delivered/on_ground leaf")
    if len(case.hints.ladder) < case.limits.hints_max:
        probs.append(f"hints_max {case.limits.hints_max} but only {len(case.hints.ladder)} ladder steps")
    if case.status == "suite" and not any(t in case.oracle for t in ("dev",)) and "dev" in case.targets:
        probs.append("a suite case scored on dev needs a dev oracle (positive control)")
    if case.status == "suite" and re.search(r"<[^<>]+>", json.dumps(case.model_dump(by_alias=True, exclude={"provenance"}))):
        probs.append("a suite case still has <...> placeholders (a dev fact is missing)")
    if case.status == "suite" and snapshot_digest(case.fixtures.state_snapshot) == "missing":
        probs.append(f"state snapshot {case.fixtures.state_snapshot!r} has no manifest (evals/bench/state_snapshots/<name>/manifest.json)")
    if case.canary != CANARY:
        probs.append("canary missing or changed")
    return probs


# ------------------------------------------------------------------ hashing and files


def _canon(obj: Any) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False, default=str)


SNAPSHOTS = Path(__file__).resolve().parent / "state_snapshots"


def snapshot_digest(name: str) -> str:
    """sha256 of a state snapshot's manifest (review C5): editing a snapshot changes every case that uses it.
    "empty" = no snapshot; a missing manifest hashes as "missing" (and fails the lint for suite cases)."""
    if not name or name == "empty":
        return "empty"
    f = SNAPSHOTS / name / "manifest.json"
    try:
        return hashlib.sha256(f.read_bytes()).hexdigest()[:16]
    except OSError:
        return "missing"


def case_hash(case: Case) -> str:
    """Changes whenever anything that affects scoring changes (text, predicates, fixtures incl. the CONTENT of the
    state snapshot, controls, limits, oracle)."""
    d = case.model_dump(by_alias=True, exclude={"status", "provenance", "heldout"})
    d["_snapshot_digest"] = snapshot_digest(case.fixtures.state_snapshot)
    return hashlib.sha256(_canon(d).encode("utf-8")).hexdigest()[:16]


def load_cases(path: Path) -> list[Case]:
    """A case file holds one case, a list, or {"cases": [...]}. Every file under a directory, sorted."""
    path = Path(path)
    files = sorted(path.rglob("*.json")) if path.is_dir() else [path]
    out: list[Case] = []
    for f in files:
        raw = json.loads(f.read_text(encoding="utf-8"))
        items = raw.get("cases") if isinstance(raw, dict) and "cases" in raw else raw
        for c in items if isinstance(items, list) else [items]:
            out.append(Case.model_validate(c))
    return out


def dump_cases(cases: list[Case], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {"canary": CANARY, "cases": [c.model_dump(by_alias=True, exclude_none=True) for c in cases]}
    path.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")

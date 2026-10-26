"""Case generation (design §5).

* T0 from data, no model (`t0_cases`): one cast case per manifest spell from data/spell_effects.json, with its proof
  (`spell_effect`), fixtures, a mock oracle and the controls. The n/a list is data-derived (the spells agent's
  `status`/`na_reason`: no perk unlocks it and/or no rune cost) and is printed, never dropped silently.
* T1 spell USE (`use_cases`): one case per purpose in spell_effects.json; the scene is bound from `world.needs`;
  chat states the need, never the spell (forbid_terms = the spell's name, "cast", "spell"). Purposes without a
  mock scene builder are dev-only drafts.
* T1-T3 proposer (`propose`): a model drafts candidate cases from catalog/wiki extracts and the SEEN archive only; an
  independent audit call sees just the chat and the predicate (finding 10c); invalid output gets one repair round.
* The frozen suite manifest (`manifest`): per family, the case ids and the denominator (finding 2).
"""
from __future__ import annotations

import hashlib
import json
import random
import re
from pathlib import Path
from typing import Any

from brain import predicates as P

from . import CANARY, hashes, leaves  # noqa: F401
from .spec import Case, case_hash, dump_cases, lint
from .world import load_spell_data, rune_item

ROOT = hashes.ROOT
SPELL_WORDS = ("cast", "spell", "spells")


def manifest_spells(spells: dict) -> tuple[list[str], dict[str, str]]:
    """(denominator spell ids, {n/a id: reason}) - data-derived only (review finding 2)."""
    den, na = [], {}
    for sid, sp in sorted(spells.items()):
        if sp.get("status") == "n/a":
            na[sid] = sp.get("na_reason") or "n/a in the spell data"
        else:
            den.append(sid)
    return den, na


# setup_checks category -> catalog item categories / range type (game data words, no item names)
_CHECK_CATS = {"melee_weapon": ("sword", "mace", "dagger", "scimitar", "greatsword", "greataxe", "hammer", "club"),
               "two_handed_bow": ("bow",), "fishing_rod": ("fishing_rod",), "logging_axe": ("axe",), "pickaxe": ("pickaxe",)}


def catalog_item(check_cat: str) -> str | None:
    """The lowest-tier catalog item that meets a setup check category (data/items_<build>.json)."""
    items = _items_catalog()
    cats = _CHECK_CATS.get(check_cat, (check_cat,))
    rows = sorted((v.get("tier") or 99, cats.index(v.get("category")), k) for k, v in items.items() if v.get("category") in cats
                  and "/Deprecated/" not in str(v.get("path") or "") and v.get("category") != "test")
    return rows[0][-1] if rows else None


_ITEMS: dict | None = None


def _items_catalog() -> dict:
    global _ITEMS
    if _ITEMS is None:
        f = sorted((ROOT / "data").glob("items_*.json"))
        _ITEMS = json.loads(f[-1].read_text(encoding="utf-8")).get("items") or {} if f else {}
    return _ITEMS


# a spell's usage.preconditions (the game data's own words) -> the T0 scene that meets it (2026-10-26: Bones to
# Peaches, Mucksplosion, Humidify and Magical Mending were "not cast" in the T0 batch because no setup met these)
PRECONDITION_SCENES = {
    "bones on the ground": {"verb": "ground_item", "item": "ITEM_Resources_AnimalBone", "count": 5, "at": [4, 0, 0],
                            "purpose": "the spell's precondition: bones on the ground"},
    "farm plots needing fertiliser": {"verb": "scene", "needs": "farm_plot",
                                      "purpose": "the spell's precondition: a farm plot (a dev place: none known yet)"},
    "dry farm plots": {"verb": "scene", "needs": "farm_plot",
                       "purpose": "the spell's precondition: a dry farm plot (a dev place: none known yet)"},
    "damaged item(s) dropped on the ground near the caster": {
        "verb": "ground_item", "item": "ITEM_Sword_Bronze", "count": 1, "durability_pct": 40, "at": [3, 0, 0],
        "purpose": "the spell's precondition: a damaged item on the ground (grant at 40% durability, unverified)"},
}
CARRY_UNITS = {  # setup_checks carried_<x>_units -> the container the game counts the units in
    "carried_compost_units": {"verb": "grant", "item": "ITEM_Bucket_Compost_Big", "count": 1,
                              "purpose": "the spell's requirement: compost units (a full compost bucket, unverified)"},
    "carried_water_units": {"verb": "grant", "item": "ITEM_WateringCan_Wood", "count": 1,
                            "purpose": "the spell's requirement: water units (a watering can, unverified that it starts full)"},
}


_USAGE: dict | None = None


def _usage(sid: str | None) -> dict:
    """The spell catalog's usage block (data/spells_<build>.json): preconditions in the game data's own words."""
    global _USAGE
    if _USAGE is None:
        f = sorted((ROOT / "data").glob("spells_*.json"))
        _USAGE = {k: (v or {}).get("usage") or {} for k, v in
                  (json.loads(f[-1].read_text(encoding="utf-8")).get("spells") or {}).items()} if f else {}
    return _USAGE.get(sid or "", {})


def _requirements(sp: dict, sid: str | None = None) -> list[dict]:
    """Harness fixture verbs that meet a spell's setup_checks (dev: mod/bench/fixtures.lua does the same)."""
    out = []
    for pre in ((sp.get("usage") or _usage(sid)).get("preconditions") or []):
        if pre in PRECONDITION_SCENES:
            out.append(dict(PRECONDITION_SCENES[pre]))
    for chk in sp.get("setup_checks") or []:
        for k, step in CARRY_UNITS.items():
            if chk.get(k):
                out.append(dict(step))
    for chk in sp.get("setup_checks") or []:
        if chk.get("claimed_bed"):  # Home Teleport: a bed he claims through the game's own interact, then 40 m away
            out.append({"verb": "claim_bed", "away_m": 40, "purpose": "the spell's requirement: a claimed bed"})
        for key in ("held_category", "carried_category"):
            if key in chk:
                item = catalog_item(chk[key])
                out.append({"verb": "grant", "item": item, "count": 1} if item else {"verb": "grant", "item": f"<{chk[key]}>"})
                if key == "held_category":
                    out.append({"verb": "hold", "category": chk[key], "item": item or f"<{chk[key]}>"})
    return out


def _sibling(sid: str, sp: dict, spells: dict, den: list[str]) -> str | None:
    """Another manifest spell with the same cast type and no shared evidence key: the wrong_action control."""
    mine = {leaves._key(e) for e in (sp.get("proof") or {}).get("effect") or []}
    for other in den:
        o = spells[other]
        if other != sid and o.get("cast_type") == sp.get("cast_type") and o.get("target") == sp.get("target") \
                and not (mine & {leaves._key(e) for e in (o.get("proof") or {}).get("effect") or []} - {None}):
            return other
    return None


def t0_cases(spells: dict | None = None, catalog: dict | None = None) -> tuple[list[Case], dict[str, str]]:
    if spells is None:
        spells, catalog = load_spell_data()
    den, na = manifest_spells(spells)
    cases = []
    for sid in den:
        sp = spells[sid]
        name = sp.get("name") or sid
        runes = {r: 2 * int(n) for r, n in (sp.get("cost") or {}).items()}
        setup: list[dict] = [{"verb": "unlock", "spell": sid}, {"verb": "grant_runes", "runes": runes}] + _requirements(sp, sid)
        args: dict[str, Any] = {"spell": name}
        near = {str((c.get("near") or {}).get("kind")) for c in sp.get("setup_checks") or [] if c.get("near")}
        if sp.get("target") == "thing" and "felled_log" in near:  # Splinter: a felled log within reach
            setup.append({"verb": "felled_log", "as": "tgt", "at": [4, 0, 0], "drops": "ITEM_Resources_Wood_Ash", "count": 3})
            args["target"] = "$tgt.id"
        elif sp.get("target") == "thing" and "target_thing" in near:  # Axtral: STANDING trees in front (main 10-26)
            setup.append({"verb": "scene", "as": "tgt", "needs": "standing_trees",
                          "purpose": "standing trees in front, >= 40 m from a lodestone"})
        oracle = [{"tool": "cast", "args": args}]
        if sp.get("cast_type") == "instant_after_move":  # Recall: beacon (setup cast) -> walk away -> HIS cast returns
            setup.append({"verb": "recall_beacon", "spell": name, "offset_m": [8, 0, 0],
                          "purpose": "Recall's first cast places the beacon (the body's own cast), then he walks 8 m away; "
                                     "the case is his second cast"})
        mock_oracle = oracle
        if any(st.get("verb") == "scene" and st.get("as") == "tgt" for st in setup):  # mock aims at its tree; dev: the body picks
            mock_oracle = [{"tool": "cast", "args": {**args, "target": "$tgt.id"}}]
        sib = _sibling(sid, sp, spells, den)
        controls: dict[str, Any] = {"na": {"partial": "a one-step oracle: cutting it short is do_nothing"}}
        if sib:
            s2 = spells[sib]
            setup += [{"verb": "unlock", "spell": sib},
                      {"verb": "grant_runes", "runes": {r: 2 * int(n) for r, n in (s2.get("cost") or {}).items()}}]
            controls["wrong_action"] = [{"tool": "cast", "args": {**args, "spell": s2.get("name") or sib}}]
        else:
            controls["na"]["wrong_action"] = "no sibling spell with the same cast type and target"
        kinds = {e.get("kind") for e in (sp.get("proof") or {}).get("effect") or []}
        if kinds & {"moved_m", "air_dash_m"}:
            controls["alt_means"] = [{"tool": "go_to", "args": {"target": [12.0, 0.0, 0.0]}}]
        elif kinds & {"drops_spawned", "target_gone"}:
            controls["alt_means"] = [{"setup": "ground_item", "item": "ITEM_Resources_Wood_Ash", "count": 3, "at": [4.2, 0, 0]}]
        else:
            controls["na"]["alt_means"] = "no other means produces this spell's own tag/GE/actor/cooldown"
        desc = ((catalog or {}).get(sid, {}).get("usage") or {}).get("use_when") or ""
        c = Case(id=f"t0_cast_{sid.removeprefix('USD_').lower()}", tier="T0", family="spell_cast", authored_by="data",
                 status="suite", tags={"spell": sid, "cast_type": sp.get("cast_type"), "confidence": sp.get("confidence")},
                 chat=[{"at_s": 0, "text": f"Claude, use {name} for me"}],
                 phrasing_heldout=f"go on then, let's see {name}",
                 fixtures={"setup": setup, "state_snapshot": "empty"},
                 success={"spell_effect": {"spell": sid}}, controls=controls,
                 limits={"wall_s": 300, "sim_s": 120, "idle_s": 30, "repeat": TRIALS_PER_CASE["spell_cast"]},
                 targets=["mock", "dev"],
                 oracle={"mock": mock_oracle, "dev": oracle},
                 provenance={"by": "generator.t0_cases", "from": "data/spell_effects.json", "description": desc})
        cases.append(c)
    return cases, na


# ------------------------------------------------------------------ T1 spell use (purposes)

# Scene builders by world.needs KIND (generic; the values come from the purpose data). Each returns
# (setup verbs, placeholder bindings for the purpose's <...> values, mock-simulable?, oracle steps, alt_means steps).
def _scene(needs: list[dict], name: str) -> tuple[list[dict], dict[str, str], bool, list[dict], list[dict] | None]:
    setup, bind, mock, oracle, alt = [], {}, True, [], None
    for n in needs or []:
        if "ledge_rise_m" in n:
            lo, hi = n["ledge_rise_m"]
            rise = round((float(lo) + float(hi)) / 2, 1)
            setup += [{"verb": "ledge", "as": "ledge", "top": [6.0, 0.0, rise]},
                      {"verb": "player", "name": "Tester", "at": [6.5, 0.0, rise]}]
            bind["<ledge top>"] = "$ledge.top"
            oracle += [{"tool": "cast", "args": {"spell": name}}, {"tool": "go_to", "args": {"target": "$ledge.id"}}]
            alt = [{"setup": "teleport_self", "to": "$ledge.top"}]  # on top without the spell: must fail
        elif (n.get("near") or {}).get("kind") == "felled_log":
            setup.append({"verb": "felled_log", "as": "log", "at": [4.0, 0.0, 0.0], "drops": "ITEM_Resources_Wood_Ash", "count": 3})
            bind["<the log's drop item>"] = "ITEM_Resources_Wood_Ash"
            oracle += [{"tool": "cast", "args": {"spell": name, "target": "$log.id"}}, {"pickup_all": "ITEM_Resources_Wood_Ash"}]
            alt = [{"setup": "ground_item", "item": "ITEM_Resources_Wood_Ash", "count": 3, "at": [4.2, 0, 0]}, {"pickup_all": "ITEM_Resources_Wood_Ash"}]
        else:
            mock = False  # a need with no mock scene builder: dev-only draft
    return setup, bind, mock, oracle, alt


def _subst(obj: Any, bind: dict[str, str]) -> Any:
    if isinstance(obj, str):
        return bind.get(obj, obj)
    if isinstance(obj, list):
        return [_subst(x, bind) for x in obj]
    if isinstance(obj, dict):
        return {k: _subst(v, bind) for k, v in obj.items()}
    return obj


def use_cases(spells: dict | None = None, phrasings: dict[str, str] | None = None) -> list[Case]:
    """One T1 case per (spell, purpose). `phrasings` = {purpose id: player line}; missing ones become drafts that
    need a phrasing (the generator's model step or a human)."""
    if spells is None:
        spells, _ = load_spell_data()
    den, _ = manifest_spells(spells)
    out = []
    for sid in den:
        sp = spells[sid]
        for pu in sp.get("purposes") or []:
            setup, bind, mock, oracle, alt = _scene((pu.get("world") or {}).get("needs"), str(sp.get("name") or sid))
            line = (phrasings or {}).get(pu["id"])
            runes = {r: 2 * int(n) for r, n in (sp.get("cost") or {}).items()}
            full_setup = [{"verb": "unlock", "spell": sid}, {"verb": "grant_runes", "runes": runes}] + _requirements(sp, sid) + setup
            success = {"purpose": {"spell": sid, "success": _subst(pu.get("success") or {}, bind)}}
            unbound = re.findall(r"<[^>]+>", json.dumps(success))
            status = "suite" if line and mock and not unbound and pu.get("observable") not in (False, None) else "draft"
            out.append(Case(id=f"t1_use_{sid.removeprefix('USD_').lower()}_{pu['id']}", tier="T1", family="spell_use",
                            authored_by="data", status=status,
                            tags={"spell": sid, "purpose": pu["id"], "observable": pu.get("observable"),
                                  "confidence": pu.get("confidence"), "unbound": unbound, "mock_scene": mock},
                            chat=[{"at_s": 0, "text": line or f"<phrase the need: {pu.get('situation')}>"}],
                            forbid_terms=[str(sp.get("name") or ""), *SPELL_WORDS],
                            fixtures={"setup": full_setup}, success=success,
                            controls={"alt_means": alt, "partial": oracle[:-1] if len(oracle) > 1 else None,
                                      "na": {} if len(oracle) > 1 else {"partial": "a one-step oracle"},
                                      **({} if alt else {"na": {"alt_means": "no mock means"}})},
                            oracle={"mock": oracle, "dev": oracle} if mock and oracle else {},
                            limits={"wall_s": 600, "sim_s": 300, "idle_s": 40}, targets=["mock", "dev"] if mock else ["dev"],
                            provenance={"by": "generator.use_cases", "situation": pu.get("situation"), "gap": pu.get("gap")}))
    return out


# ------------------------------------------------------------------ the every-spell stress suite (Luis, M2)

STRESS = ("combat", "cooldown_pressure", "low_runes", "out_of_reach", "moving_target")


def stress_cases(spells: dict | None = None, repeat: int = 3) -> list[Case]:
    """Every manifest spell x situations (combat, cooldown pressure, low runes, target out of reach, moving target),
    each repeated k times: per-spell reliability, latency and failure reasons in the report. Situations a spell can't
    have (no target -> no reach/moving case) are skipped; dev-only situations are drafts until the dev scene exists."""
    if spells is None:
        spells, _ = load_spell_data()
    den, _ = manifest_spells(spells)
    out = []
    for sid in den:
        sp = spells[sid]
        name = str(sp.get("name") or sid)
        cost = {r: int(n) for r, n in (sp.get("cost") or {}).items()}
        if not cost:
            continue
        base = [{"verb": "unlock", "spell": sid}] + _requirements(sp, sid)
        tgt = sp.get("target") in ("thing", "aim")
        for sit in STRESS:
            if sit in ("out_of_reach", "moving_target") and not tgt:
                continue
            setup = list(base)
            success: dict = {"spell_effect": {"spell": sid}}
            mock = True
            line = f"use {name}"
            oracle: list[dict] = [{"tool": "cast", "args": {"spell": name}}]
            if sit == "combat":
                setup += [{"verb": "grant_runes", "runes": {r: 2 * n for r, n in cost.items()}},
                          {"verb": "spawn", "kind": "goblin", "at": [3, 1, 0], "hp": 60, "hostile": True, "damage": 3}]
                line = f"use {name}, quick, we're in a fight here"
            elif sit == "cooldown_pressure":
                setup += [{"verb": "grant_runes", "runes": {r: 3 * n for r, n in cost.items()}}]
                success = {"casts": {"spell": sid, "at_least": 2}}
                line = f"use {name} twice for me, once now and again when it's ready"
                oracle = [oracle[0], {"wait_s": float(sp.get("cooldown_s") or 0) + 1}, oracle[0]]
            elif sit == "low_runes":
                setup += [{"verb": "grant_runes", "runes": {r: max(0, n - 1) for r, n in cost.items()}}]
                setup += [{"verb": "ground_item", "item": rune_item(r), "count": 2 * n, "at": [6, 2, 0]} for r, n in cost.items()]
                line = f"use {name}, there are some runes lying over there if you're short"
                oracle = [{"pickup_all": rune_item(r)} for r in cost] + oracle
            elif sit == "out_of_reach":
                setup += [{"verb": "grant_runes", "runes": {r: 2 * n for r, n in cost.items()}},
                          {"verb": "felled_log", "as": "tgt", "at": [28, 0, 0], "drops": "ITEM_Resources_Wood_Ash", "count": 3}]
                line = f"use {name} on that one way over there"
                oracle = [{"tool": "go_to", "args": {"target": [24.0, 0.0, 0.0]}},
                          {"tool": "cast", "args": {"spell": name, "target": "$tgt.id"}}]
            else:  # moving target: dev only (needs a moving creature scene)
                mock = False
                line = f"use {name} on that one running around"
            out.append(Case(id=f"stress_{sid.removeprefix('USD_').lower()}_{sit}", tier="T1", family="stress",
                            authored_by="data", status="suite" if mock else "draft",
                            tags={"spell": sid, "situation": sit}, chat=[{"at_s": 0, "text": line}],
                            fixtures={"setup": setup}, success=success,
                            limits={"wall_s": 600, "sim_s": max(240.0, 3 * float(sp.get("cooldown_s") or 0) + 60), "idle_s": 60,
                                    "repeat": repeat}, targets=["mock", "dev"] if mock else ["dev"],
                            controls={"na": {c: "stress cases measure reliability; validity comes from the T0 case"
                                             for c in ("wrong_action", "alt_means", "partial")}},
                            oracle={"mock": oracle, "dev": oracle},
                            provenance={"by": "generator.stress_cases"}))
    return out


# ------------------------------------------------------------------ the model proposer (T1-T3 candidates)

PROPOSE_SYS = """You draft HARD benchmark tasks for an AI companion that plays RuneScape: Dragonwilds as a real player.
Write each task as the line a player would type in chat (never tool or function names, never asset ids). Give a
success predicate that a referee can check from game state alone, using ONLY these leaves:
{leaves}
Prefer tasks that need research (wiki/game data), several steps or trips, the right tool or weapon, or recovery from
failure. Answer with JSON: {{"cases": [{{"id", "tier", "family", "chat", "success", "fixtures_setup", "alt_means",
"needs_fact"}}]}}."""

AUDIT_SYS = """You audit a benchmark task. You see only what the player said and the success check. Would the player say
the job was done when the check passes? What is missing or too weak (wrong item, no delivery, too few, passes without
doing the thing)? Answer JSON: {"ok": true|false, "problems": [..]}."""


def _json(text: str | None) -> Any:
    if not text:
        return None
    m = re.search(r"\{.*\}", text, re.S)
    try:
        return json.loads(m.group(0)) if m else None
    except ValueError:
        return None


def propose(llm, tier: str, n: int, extracts: str, archive: list[str], items=None, log=None) -> tuple[list[Case], list[dict]]:
    """Up to n candidate cases (status "candidate") plus a list of rejects with reasons. Calls: 1 propose + at most 1
    repair + 1 audit per batch. The archive holds SEEN case ids/texts only (held-out never reaches the model)."""
    doc = P.SCHEMA_DOC + "\n" + "\n".join(f"- {{\"{k}\": ...}}" for k in leaves.LEAVES)
    msgs = [{"role": "system", "content": PROPOSE_SYS.format(leaves=doc)},
            {"role": "user", "content": f"Tier {tier}. Draft {n} new tasks unlike these existing ones: {archive[:40]}.\n"
                                        f"Game facts you may use:\n{extracts}"}]
    raw = _json(llm.complete(msgs).content) or {}
    good, rejects, repair = [], [], []
    for d in (raw.get("cases") or [])[:n]:
        errs = P.errors(d.get("success") or {}, items)
        if errs:
            repair.append({"case": d, "errors": errs})
            continue
        good.append(d)
    if repair:
        msgs2 = msgs + [{"role": "assistant", "content": json.dumps(raw)},
                        {"role": "user", "content": "Fix these predicates (unknown names come with candidates): "
                                                    + json.dumps([{"id": r["case"].get("id"), "errors": r["errors"]} for r in repair])}]
        fixed = _json(llm.complete(msgs2).content) or {}
        for d in fixed.get("cases") or []:
            (good.append(d) if not P.errors(d.get("success") or {}, items) else rejects.append({"id": d.get("id"), "why": "invalid after repair"}))
    cases = []
    if good:
        audit = _json(llm.complete([{"role": "system", "content": AUDIT_SYS},
                                    {"role": "user", "content": json.dumps([{"id": d.get("id"), "chat": d.get("chat"),
                                                                             "success": d.get("success")} for d in good])}]).content)
        verdicts = {v.get("id"): v for v in (audit or {}).get("verdicts", [])} if isinstance(audit, dict) else {}
        for d in good:
            v = verdicts.get(d.get("id"), {"ok": True})
            if not v.get("ok", True):
                rejects.append({"id": d.get("id"), "why": "audit: " + "; ".join(v.get("problems") or [])})
                continue
            try:
                c = Case(id=str(d["id"]), tier=d.get("tier", tier), family=d.get("family", "misc"), authored_by="generator",
                         status="candidate", chat=[{"at_s": 0, "text": d["chat"] if isinstance(d["chat"], str) else d["chat"][0]}],
                         fixtures={"setup": d.get("fixtures_setup") or []}, success=d["success"],
                         controls={"alt_means": d.get("alt_means")} if d.get("alt_means") else {},
                         needs_fact=d.get("needs_fact"), targets=["dev"],
                         provenance={"by": "generator.propose", "model": getattr(llm, "model", None)})
            except Exception as exc:
                rejects.append({"id": d.get("id"), "why": f"spec: {exc}"})
                continue
            if p := lint(c):
                rejects.append({"id": c.id, "why": "lint: " + "; ".join(p)})
                continue
            cases.append(c)
    return cases, rejects


def split_heldout(cases: list[Case], seed: str, frac: float = 0.3) -> tuple[list[Case], list[Case]]:
    """Stratified by (tier, family), deterministic from the seed (the HEAD sha for the post-freeze draw)."""
    groups: dict[tuple, list[Case]] = {}
    for c in cases:
        groups.setdefault((c.tier, c.family), []).append(c)
    seen, held = [], []
    for key, cs in sorted(groups.items()):
        rng = random.Random(hashlib.sha256((seed + repr(key)).encode()).hexdigest())
        cs = sorted(cs, key=lambda c: c.id)
        rng.shuffle(cs)
        k = round(len(cs) * frac)
        for c in cs[:k]:
            c.heldout = True
        held += cs[:k]
        seen += cs[k:]
    return seen, held


def shingle_dupe(a: str, b: str, n: int = 4, thresh: float = 0.5) -> bool:
    def sh(t):
        w = re.findall(r"[a-z0-9']+", t.lower())
        return {tuple(w[i:i + n]) for i in range(max(0, len(w) - n + 1))}
    x, y = sh(a), sh(b)
    return bool(x and y) and len(x & y) / len(x | y) >= thresh


# ------------------------------------------------------------------ files


# Trials per case for a family's percentage target (main, 2026-10-25: spells k=2 -> 78 trials under the Wilson rule)
TRIALS_PER_CASE = {"spell_cast": 2}


def manifest(cases: list[Case], na: dict[str, str], version: int = 1) -> dict:
    fam: dict[str, list] = {}
    for c in cases:
        if c.status == "suite":
            fam.setdefault(c.family, []).append({"id": c.id, "hash": case_hash(c)})
    return {"schema": "dw_bench_manifest/1", "version": version, "build": hashes.game_build(), "canary": CANARY,
            "families": fam, "trials_per_case": {f: TRIALS_PER_CASE.get(f, 1) for f in fam},
            "denominators": {f: len(v) * TRIALS_PER_CASE.get(f, 1) for f, v in fam.items()},
            "na": {"spell_cast": na}, "approved_by": None, "_note": "Luis approves this manifest and its n/a list per build"}


def write_t0(out: Path) -> list[str]:
    spells, catalog = load_spell_data()
    t0, na = t0_cases(spells, catalog)
    use = use_cases(spells, DEFAULT_PHRASINGS)
    dump_cases(t0, out / "t0_spells.json")
    dump_cases(use, out / "t1_spell_use.json")
    stress = stress_cases(spells)
    dump_cases(stress, out / "stress_spells.json")
    man = manifest(t0 + use + stress, na)
    mdir = ROOT / "evals" / "bench" / "manifests" / str(hashes.game_build())
    mdir.mkdir(parents=True, exist_ok=True)
    (mdir / "suite_v1.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    lines = [f"T0 spell cases: {len(t0)} (manifest spells); n/a: {len(na)}"]
    lines += [f"  n/a {sid}: {why}" for sid, why in sorted(na.items())]
    lines.append(f"T1 spell-use cases: {len(use)} ({sum(c.status == 'suite' for c in use)} suite, "
                 f"{sum(c.status == 'draft' for c in use)} drafts needing a phrasing/scene/observability)")
    lines.append(f"stress cases: {len(stress)} ({sum(c.status == 'suite' for c in stress)} mock-runnable, "
                 f"x{stress[0].limits.repeat if stress else 0} repeats)")
    lines.append(f"manifest: {mdir / 'suite_v1.json'}")
    return lines


# Player lines for purposes that have a mock scene (hand-written; the rest are phrased by the model step).
DEFAULT_PHRASINGS = {
    "reach_high_ledge": "come up here, I'm on top of this rock",
    "split_felled_log": "we need wood, there's a log right there",
}

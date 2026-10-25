"""Generate data/spell_effects.json: per player spell, the game-observable change that proves a cast WORKED.

It is used by the eval benchmark (T0: one auto-generated case per unlocked spell) and documents what
client_mod/scripts/spells.lua's `cast` result reports.

Sources:
- data/spells_<build>.json, the game's own spell data: modules, GameplayEffects with add_tags and
  instance_class, held-equipment effects, costs, cooldowns, perks, special-requirement strategies.
- LIVE: what was observed live on Claude's client (2026-10-25, DISCOVERIES "Client spells (R2)").
  Live entries override and extend the data-derived proof and carry their evidence. They are data
  (observations keyed by asset id), not code rules.

Offline, deterministic. Run:  .venv\\Scripts\\python.exe -m tools.gen_spell_effects
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BUILD = "26161880"
SRC = REPO / "data" / f"spells_{BUILD}.json"
OUT = REPO / "data" / "spell_effects.json"

CAST_TYPES = {"Instant": "instant", "Placed": "placed", "Aimed": "aimed", "AllowMovementThenCastInstant": "instant_after_move"}

SIGNAL_KINDS = {
    "runes_spent": "carried rune counts fall by `cost` (cast reply: data.runes_spent)",
    "cooldown_started": "PlayerUtilityMagicComponent.LastCastTimeBySpellData gains/changes the spell (data.cooldown_started)",
    "tag_added": "gameplay tag `tag` appears on the pawn's GameplayEffectsComponent (data.effects.tags)",
    "ge_added": "a GameplayEffect instance whose class contains `class_contains` appears on the pawn (data.effects.ge)",
    "spell_actor": "a new UtilitySpell/actor of class `class` appears `near` the preview point or the target (data.spell_actor, data.landed_at)",
    "jump_apex_gain_m": "jump apex after the cast exceeds the apex before by at least `min` metres (probe: client_mod/commands/smoke_jump.lua)",
    "air_dash_m": "jump + one IA_Player_Evade press while falling ends at least `min` m away horizontally, kept by the server (probe: client_mod/commands/air_dash_test.lua; without the spell the server snaps him back)",
    "moved_m": "the cast itself moves the caster at least `min` metres (data.moved_m)",
    "target_gone": "the targeted thing is gone/converted after the cast (data.target_after == 'gone')",
    "target_health_drop": "the targeted thing's health falls by at least `min` (data.target_health vs before)",
    "drops_spawned": "world items whose item id contains `item_contains` appear near the target (look/census)",
    "held_item_effect": "the held weapon gains the enchant: its damage types include `damage_types` for `time_limit_s` (pawn PlayerEquipmentComponent held effect; to be read)",
    "world_module": "the spell changes the world through game module `module` (crop growth, water, compost ...); the proof needs a module-specific read (TBD)",
}

# Live observations (2026-10-25, Shockbyte world, client build 26162923, data build 26161880).
LIVE = {
    "USD_Windstep": {
        "effect": [{"kind": "tag_added", "tag": "Player.Spell.WindStep"},
                   {"kind": "ge_added", "class_contains": "DominionStatusEffect"},
                   {"kind": "jump_apex_gain_m", "min": 3.0, "probe": "client_mod/commands/smoke_jump.lua"}],
        "evidence": "21:27Z keyless slot (highlight+accept): Air -5, cooldown; tag Player.Spell.WindStep + DominionStatusEffect; jump apex 1.80 -> 7.38 m",
    },
    "USD_TempestShield": {
        "effect": [{"kind": "tag_added", "tag": "Player.Status.TempestShield"},
                   {"kind": "ge_added", "class_contains": "TempestShieldGameplayEffectInstance"}],
        "evidence": "21:30Z page 1 key 8: Air -15, cooldown; BP_TempestShieldGameplayEffectInstance_C + tag Player.Status.TempestShield",
    },
    "USD_PhaseDash": {
        "effect": [{"kind": "air_dash_m", "min": 6.0, "probe": "client_mod/commands/air_dash_test.lua"}],
        "evidence": "21:33Z page 4 key 1: Astral -10, Air -20, cooldown; no GE/tag. Air evade without it: 3.2 m peak, snapped back to 0 m; right after the cast: 8.4 m kept",
    },
    "USD_SummonShelter": {
        "effect": [{"kind": "spell_actor", "class": "BP_Magic_SummonShelter_C", "near": "preview"}],
        "setup": ["flat open ground within about 9 m (the game's preview rejects UI.Notification.SpellPlacement.GroundNotFlatEnough / .Blocked)"],
        "target": "ground",
        "evidence": "20:44Z: preview green, runes Earth -10 Astral -10 after the >4 s cast animation; BP_Magic_SummonShelter_C_2147450308 (Luis saw it). OurSpellActors reads empty on the client: match the new UtilitySpell near the preview",
    },
    "USD_Splinter": {
        "effect": [{"kind": "spell_actor", "class": "BP_Magic_Splinter_C", "near": "preview"},
                   {"kind": "target_gone"},
                   {"kind": "drops_spawned", "item_contains": "Wood"}],
        "setup": ["a felled or splittable log (ATreeLog) within about 8 m; aim at its GetMidPointWorldLocation (the actor origin is stale)"],
        "target": "thing",
        "evidence": "21:3xZ on BP_SplittableLog_Ash_C_2147462658: preview valid first time at the midpoint; BP_Magic_Splinter_C at the preview; Earth -10 Nature -5; the log split into 'Ash Logs' world items. Off the log the preview says UI.Notification.SpellPlacement.NoTarget.RequiresLog",
    },
}


def short(path: str | None) -> str | None:
    if not path:
        return None
    return path.rsplit(".", 1)[-1]


def derive(sid: str, rec: dict, doc: dict) -> dict:
    """The data-derived signature of one spell, from its modules."""
    effects = doc.get("effects") or {}
    held = doc.get("held_effects") or {}
    perks = doc.get("perks") or {}
    modules = rec.get("modules") or []
    kinds = {m.get("kind", "").replace("SpellModule_", "") for m in modules}
    cast_type = CAST_TYPES.get(rec.get("cast_type"), str(rec.get("cast_type")).lower())
    proof_required = []
    if rec.get("runes"):
        proof_required.append({"kind": "runes_spent"})
    proof_required.append({"kind": "cooldown_started"})
    effect = []
    target = "self" if cast_type.startswith("instant") else ("ground" if cast_type == "placed" else "aim")
    harmful = any("Damage" in k for k in kinds)
    for m in modules:
        k = m.get("kind", "").replace("SpellModule_", "")
        if k == "GameplayEffect":
            ge = effects.get(m.get("effect") or "") or {}
            for t in ge.get("add_tags") or []:
                effect.append({"kind": "tag_added", "tag": t})
            inst = short(ge.get("instance_class")) or short(m.get("effect"))
            if inst:
                effect.append({"kind": "ge_added", "class_contains": inst})
        elif k == "UtilityMagic" and m.get("utility_spell_class"):
            effect.append({"kind": "spell_actor", "class": short(m["utility_spell_class"]), "near": "preview" if cast_type != "instant" else "self"})
        elif k == "SpawnActor" and m.get("actor_class"):
            effect.append({"kind": "spell_actor", "class": short(m["actor_class"]), "near": "self"})
        elif k == "HeldEquipmentEffect":
            h = held.get(m.get("held_effect") or "") or {}
            effect.append({"kind": "held_item_effect", "damage_types": h.get("additive_damage_types") or h.get("additional_damage_types") or [],
                           "time_limit_s": h.get("time_limit_s"), "effect": short(m.get("held_effect"))})
        elif k == "LaunchCharacter":
            effect.append({"kind": "moved_m", "min": 1.0})
        elif k in ("Humidify", "Compost", "Grow", "Harvest", "Uneat", "SiphonRunes", "SiphonAnimaCharge"):
            effect.append({"kind": "world_module", "module": k})
    if harmful and cast_type != "instant":
        target = "thing"
        effect.append({"kind": "target_health_drop", "min": 1})
    perk = perks.get(rec.get("owning_perk") or "") or {}
    unlock = {"skill": (perk.get("skill_name") or "").replace("SKILL_", "") or None, "level": perk.get("level")} if perk else None
    req = None
    if rec.get("special_requirements_strategy") or rec.get("special_requirements"):
        req = {"strategy": short(rec.get("special_requirements_strategy")), "text": (rec.get("special_requirements") or "").strip() or None}
    setup = []
    if req and req.get("text"):
        setup.append(f"the game's special requirement: {req['text']}")
    if target == "ground":
        setup.append("open ground the game's placement preview accepts, within about 9 m")
    elif target == "thing":
        setup.append("a valid target thing within reach (the game's preview tag names what it needs)")
    out = {
        "name": rec.get("name") or sid,
        "cast_type": cast_type,
        "cost": rec.get("runes") or {},
        "cooldown_s": rec.get("cooldown_s"),
        "unlock": unlock,
        "requirement": req,
        "target": target,
        "harmful": harmful,
        "setup": setup,
        "proof": {"required": proof_required, "effect": effect},
        "confidence": "data" if effect else "data_weak",
        "evidence": None if effect else "no observable module in the spell data (Blueprint-only); needs a live observation",
        "modules": sorted(kinds),
    }
    return out


def build(doc: dict) -> dict:
    spells = {}
    for sid, rec in sorted((doc.get("spells") or {}).items()):
        # player spells only: a perk unlocks them and they cost something (internal assets have neither)
        if not rec.get("owning_perk") or not rec.get("runes"):
            continue
        sig = derive(sid, rec, doc)
        live = LIVE.get(sid)
        if live:
            seen = {json.dumps(e, sort_keys=True) for e in live["effect"]}
            extra = [e for e in sig["proof"]["effect"] if json.dumps(e, sort_keys=True) not in seen and e["kind"] not in {x["kind"] for x in live["effect"]}]
            sig["proof"]["effect"] = live["effect"] + extra
            for k in ("setup", "target"):
                if k in live:
                    sig[k] = live[k] if k == "target" else live[k] + [s for s in sig["setup"] if not s.startswith("open ground") and not s.startswith("a valid target")]
            sig["confidence"], sig["evidence"] = "live", live["evidence"]
        spells[sid] = sig
    return {
        "version": 1,
        "build": BUILD,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": [str(SRC.relative_to(REPO)).replace("\\", "/"), "tools/gen_spell_effects.py LIVE (DISCOVERIES 'Client spells (R2)')"],
        "how_to_prove": "ALL of proof.required, then at least one of proof.effect (prefer confidence=live entries). The cast reply carries runes_spent, cooldown_started, effects.{ge,tags}, spell_actor, landed_at, moved_m, target_after, target_health; jump/air-dash proofs need their probe.",
        "signal_kinds": SIGNAL_KINDS,
        "spells": spells,
    }


def main(argv: list[str]) -> int:
    doc = json.loads(SRC.read_text(encoding="utf-8"))
    out = build(doc)
    OUT.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    n = len(out["spells"])
    live = sum(1 for s in out["spells"].values() if s["confidence"] == "live")
    weak = [s["name"] for s in out["spells"].values() if s["confidence"] == "data_weak"]
    print(f"wrote {OUT.relative_to(REPO)}: {n} spells, {live} live-verified, {len(weak)} without a data-derived proof: {', '.join(weak)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

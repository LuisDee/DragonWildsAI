"""Build data/items_<build>.json, the weapon and armour catalog (design: docs/design/
robustness-and-item-catalog.md section 2; schema: data/README.md).

Drives mod/scripts/catalog.lua on the live server through debug_run:
  1. one call that describes every loaded item and lists the asset registry;
  2. optionally (default on) batches of explicit paths for the registry entries that were not
     loaded, which the mod loads with LoadAsset (synchronous: each batch stalls the game thread,
     so batches are small and paced);
then merges the raw files and normalises them.

  .venv\\Scripts\\python.exe -m tools.build_catalog                      # loaded + registry + load batches
  .venv\\Scripts\\python.exe -m tools.build_catalog --no-load            # loaded items only, no LoadAsset
  .venv\\Scripts\\python.exe -m tools.build_catalog --limit 5 --max-batches 2   # cautious first run
  .venv\\Scripts\\python.exe -m tools.build_catalog --merge-only logs\\catalog\\26161880_<ts>   # offline re-merge

Raw per-call files go to logs/catalog/<build>_<ts>/ (gitignored); the mod writes them itself.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from collections import Counter
from pathlib import Path

from brain.paths import REPO_ROOT

BUILD = "26161880"
SCHEMA = "dw_items/1"
ATTACKS = "/Game/Gameplay/Character/Player/Attacks"

# Category (from the asset folder) -> primary action class, read from the build-26161880 object
# dump (BlueprintGeneratedClass /Game/Gameplay/Character/Player/Attacks/<Folder>/PA_*). Used only
# for items whose own PrimaryActionClass could not be read, and after the per-category majority
# learned from items that did resolve. "mace" -> Club is a guess: there is no Attacks/Mace folder.
CATEGORY_ACTION_FALLBACK = {
    "sword": f"{ATTACKS}/Sword/PA_Attack_Sword.PA_Attack_Sword_C",
    "mace": f"{ATTACKS}/Club/PA_Attack_Club.PA_Attack_Club_C",
    "club": f"{ATTACKS}/Club/PA_Attack_Club.PA_Attack_Club_C",
    "greatsword": f"{ATTACKS}/2H_Greatsword/PA_Attack_2H_Greatsword.PA_Attack_2H_Greatsword_C",
    "greataxe": f"{ATTACKS}/2H_Axe/PA_Attack_GreatAxe.PA_Attack_GreatAxe_C",
    "hammer": f"{ATTACKS}/2H_Hammer/PA_Attack_2H_Hammer.PA_Attack_2H_Hammer_C",
    "axe": f"{ATTACKS}/Axe/PA_Attack_Hatchet.PA_Attack_Hatchet_C",
    "pickaxe": f"{ATTACKS}/Pickaxe/PA_Attack_Pickaxe.PA_Attack_Pickaxe_C",
    "dagger": f"{ATTACKS}/Dagger/PA_Attack_Dagger.PA_Attack_Dagger_C",
    "scimitar": f"{ATTACKS}/Scimitar/PA_Attack_Scimitar.PA_Attack_Scimitar_C",
    "bow": f"{ATTACKS}/Bow/PA_RangedAttack_Bow.PA_RangedAttack_Bow_C",
    "shortbow": f"{ATTACKS}/Shortbow/PA_RangedAttack_Shortbow.PA_RangedAttack_Shortbow_C",
    "crossbow": f"{ATTACKS}/Crossbow/PA_RangedAttack_Crossbow.PA_RangedAttack_Crossbow_C",
}

# Folder name under .../Equipment/Held/ -> category.
FOLDER_CATEGORY = {"hatchet": "axe", "greatsword": "greatsword", "greataxe": "greataxe", "scarabstaff": "staff",
                   "statuseffect_test": "test", "fishingrod": "fishing_rod"}
CLASS_CATEGORY = {"FishingRodHeldEquipmentData": "fishing_rod", "HarvestToolEquipmentData": "harvest_tool",
                  "HeldContainerEquipmentData": "container", "HeldTreeSeedData": "seed",
                  "SeedHeldEquipmentData": "seed", "ShieldData": "shield", "SpadeToolEquipmentData": "spade",
                  "JewelleryData": "jewellery"}
RANGED_CATS, MAGIC_CATS = {"bow", "shortbow", "longbow", "crossbow"}, {"staff", "wand"}
TOOL_CATS = {"axe", "pickaxe", "torch", "fishing_rod", "fishingnet", "harvest_tool", "spade", "seed", "container",
             "farming"}
# Tools whose primary action is a magic-kind UPlayerAction (planting, digging, netting): not magic weapons.
NON_COMBAT_CATS = {"seed", "container", "spade", "fishingnet", "fishing_rod", "farming", "harvest_tool"}
SLOT = {"Head": "head", "Body": "body", "Legs": "legs", "Cape": "cape", "Trinket": "trinket", "Necklace": "necklace",
        "Ammo": "ammo", "MagicAmmo": "magic_ammo", "CrossbowBolts": "crossbow_bolts", "FishingBait": "fishing_bait",
        "PlantSeed": "plant_seed", "JournalItem": "journal", "HeldAny": "hand_any", "HeldOnlyRight": "right_hand",
        "HeldOnlyLeft": "left_hand", "HeldTwoHanded": "two_handed"}
ACTION_KEYS = ("primary", "secondary", "special", "primary_sprint", "primary_visceral", "primary_jump")


# ------------------------------------------------------------------------------ live calls

def debug_run(client, args: dict, timeout: float) -> dict:
    res = client.request("debug_run", {"module": "catalog", "args": args}, timeout=timeout)
    if not res.get("ok"):
        raise RuntimeError(f"debug_run failed: {json.dumps(res)[:2000]}")
    result = (res.get("data") or {}).get("result") or {}
    if not result.get("ok"):
        raise RuntimeError(f"catalog.lua reported failure: {json.dumps(result)[:2000]}")
    return result


def run_live(a, raw_dir: Path) -> None:
    from brain.bridge_client import BridgeClient
    from brain.transport import file_transport_pair

    brain_side, _ = file_transport_pair()
    client = BridgeClient(brain_side)
    common = {"build": a.build, "registry_mode": a.registry_mode, "kismet_soft": a.kismet_soft, "sample": 2,
              "montage": a.montage or a.notifies, "notifies": a.notifies}

    print(f"[1] loaded items + registry -> {raw_dir}")
    first = debug_run(client, {**common, "loaded": True, "registry": True, "refresh": True,
                               "out": (raw_dir / "000_loaded.json").as_posix()}, a.timeout)
    print(json.dumps({k: first.get(k) for k in ("counts", "cpu_ms", "registry_calls", "errors")}, indent=1)[:3000])
    if a.no_load:
        return
    raw = json.loads((raw_dir / "000_loaded.json").read_text(encoding="utf-8"))
    todo = [e["path"] for e in raw.get("registry") or [] if not e.get("loaded")]
    print(f"[2] {len(todo)} registry entries not loaded; batches of {a.limit}")
    for n, start in enumerate(range(0, len(todo), a.limit), 1):
        if a.max_batches and n > a.max_batches:
            print(f"stopping after {a.max_batches} batches (--max-batches); {len(todo) - start} left")
            break
        batch = todo[start:start + a.limit]
        out = raw_dir / f"batch_{start:05d}.json"
        t = time.monotonic()
        r = debug_run(client, {**common, "loaded": False, "registry": False, "load": True, "attacks": True,
                               "paths": batch, "out": out.as_posix()}, a.timeout)
        c = r.get("counts") or {}
        print(f"  batch {n}: {c.get('described')} described, {c.get('loaded_now')} loaded, "
              f"{c.get('load_failed')} failed, cpu {r.get('cpu_ms')} ms, wall {time.monotonic() - t:.1f} s")
        if a.pause:
            time.sleep(a.pause)


# ------------------------------------------------------------------------------ merge + normalise

def merge_raw(raw_dir: Path) -> dict:
    files = sorted(raw_dir.glob("*.json"))
    if not files:
        raise SystemExit(f"no raw catalog files in {raw_dir}")
    merged = {"items": {}, "actions": {}, "attacks": {}, "collections": {}, "registry": {}, "errors": [],
              "files": [], "build": None}
    for f in files:
        doc = json.loads(f.read_text(encoding="utf-8"))
        merged["files"].append(f.name)
        merged["build"] = merged["build"] or doc.get("build")
        for it in doc.get("items") or []:
            if it.get("path"):
                merged["items"].setdefault(it["path"], it)
        for key in ("actions", "attacks", "collections"):
            for k, v in (doc.get(key) or {}).items():
                if k not in merged[key] or len(v) > len(merged[key][k]):
                    merged[key][k] = v
        for e in doc.get("registry") or []:
            merged["registry"].setdefault(e["path"], e)
        merged["errors"].extend(doc.get("errors") or [])
    return merged


def asset_name(path: str) -> str:
    return path.rsplit(".", 1)[-1] if "." in path else path.rsplit("/", 1)[-1]


def folder_category(path: str) -> str | None:
    m = re.search(r"/Equipment/Held/(?:UniqueWeapons/)?([^/]+)/", path)
    if m:
        f = m.group(1).lower()
        return FOLDER_CATEGORY.get(f, f)
    m = re.search(r"/Equipment/([^/]+)/", path)
    return m.group(1).lower() if m else None


def class_path(soft: dict | None) -> tuple[str | None, bool]:
    """Normalise a soft class reference read by the mod. Returns (path, inferred)."""
    if not soft:
        return None, False
    p = soft.get("loaded") or soft.get("path") or soft.get("kismet")
    if not p:
        return None, False
    if "." not in p.rsplit("/", 1)[-1]:  # package path only: assume the blueprint class convention
        base = p.rsplit("/", 1)[-1]
        return f"{p}.{base}_C", True
    return p, False


def chain(attacks: dict, first: str | None, cap: int = 16) -> list[str]:
    out, p = [], first
    while p and p not in out and len(out) < cap:
        out.append(p)
        p = (attacks.get(p) or {}).get("next")
    return out


# Notify classes in an attack montage (mod/scripts/catalog.lua describe_montage), times in seconds.
INPUT_WINDOW, DAMAGE_POINT = "AnimNotifyState_AttackInputWindow_C", "AnimNotify_AttackDamagePoint_C"
RESET_CHAIN, ALLOW_MOVE = "AnimNotify_AttackResetChain_C", "AnimNotify_AllowMovementInput_C"


def timing(rec: dict) -> dict | None:
    """Compact swing timing from an attack's montage notifies: montage length, the combo input
    window [start, end], damage points, the chain-reset point and when movement is allowed again."""
    mon = rec.get("montage_root_motion") or rec.get("montage")
    if not mon:
        return None
    out = {"montage": mon.get("path"), "length": mon.get("length"), "rate": mon.get("rate")}
    ns = mon.get("notifies") or []
    win = [n for n in ns if n.get("class") == INPUT_WINDOW and n.get("t") is not None]
    if win:
        w = min(win, key=lambda n: n["t"])
        out["input_window"] = [round(w["t"], 3), round(w["t"] + (w.get("dur") or 0.0), 3)]
    dmg = sorted(round(n["t"], 3) for n in ns if n.get("class") == DAMAGE_POINT and n.get("t") is not None)
    if dmg:
        out["damage_points"] = dmg
    for key, cls in (("reset_chain", RESET_CHAIN), ("allow_move", ALLOW_MOVE)):
        ts = [n["t"] for n in ns if n.get("class") == cls and n.get("t") is not None]
        if ts:
            out[key] = round(min(ts), 3)
    return {k: (round(v, 3) if isinstance(v, float) else v) for k, v in out.items() if v is not None}


def attacks_out(attacks: dict) -> dict:
    """Per-attack records for the catalog: raw montage notify lists replaced by `timing`."""
    out = {}
    for p, rec in attacks.items():
        r = {k: v for k, v in rec.items() if k not in ("montage", "montage_root_motion")}
        t = timing(rec)
        if t:
            r["timing"] = t
        out[p] = r
    return out


def short_chain(attacks: dict, first: str | None, cap: int = 16) -> list[str]:
    """The combo without perks: follow NextAttackClassNoRequiredPerk where an attack sets it."""
    out, p = [], first
    while p and p not in out and len(out) < cap:
        out.append(p)
        rec = attacks.get(p) or {}
        p = rec.get("next_no_perk") or rec.get("next")
    return out


def attack_set(m: dict, action_path: str | None) -> dict | None:
    if not action_path:
        return None
    act = m["actions"].get(action_path) or {}
    c = chain(m["attacks"], act.get("attack_data"))
    combo_ends = sorted({m["attacks"][p]["next_no_perk"] for p in c
                         if (m["attacks"].get(p) or {}).get("next_no_perk")})
    dmg = [m["attacks"][p].get("damage") for p in c if (m["attacks"].get(p) or {}).get("damage") is not None]
    sc = short_chain(m["attacks"], act.get("attack_data"))
    return {"action": action_path, "kind": act.get("kind"), "name": act.get("name"), "chain": c,
            "short_chain": sc if sc != c else None, "combo_ends": combo_ends, "damage": dmg or None,
            "damage_class": (m["attacks"].get(c[0]) or {}).get("damage_class_name") if c else None}


def range_type(cat: str | None, held: dict, primary: dict | None) -> str:
    kind = (primary or {}).get("kind")
    if kind == "ranged" or held.get("ranged_collection") or held.get("ammo_name") in ("Arrows", "CrossbowBolts") \
            or cat in RANGED_CATS:
        return "ranged"
    if cat in NON_COMBAT_CATS and not held.get("magic_collection"):
        return "none"
    if kind == "magic" or held.get("magic_collection") or held.get("ammo_name") == "Runes" or cat in MAGIC_CATS:
        return "magic"
    if kind == "melee":
        return "melee"
    return "none"


def normalise(m: dict, build: str) -> dict:
    raw_items = m["items"]
    names = Counter(asset_name(p) for p in raw_items)
    # Learn category -> primary action from items that resolved one.
    learned: dict[str, Counter] = {}
    for p, it in raw_items.items():
        prim = ((it.get("held") or {}).get("actions") or {}).get("primary")
        cat = CLASS_CATEGORY.get(it.get("class")) or folder_category(p)
        if prim and cat:
            learned.setdefault(cat, Counter())[prim] += 1

    items, sets = {}, {}
    for p, it in sorted(raw_items.items()):
        name = asset_name(p)
        iid = name if names[name] == 1 else f"{name}@{p.split('/')[1]}"
        cat = CLASS_CATEGORY.get(it.get("class")) or folder_category(p)
        slot_name = it.get("slot_name")
        rec = {
            "id": iid, "path": p, "name": it.get("name"), "kind": it.get("kind"), "class": it.get("class"),
            "category": cat, "category_tag": it.get("category_tag"), "filter_tags": it.get("filter_tags") or [],
            "granted_tags": it.get("granted_tags") or [], "slot": SLOT.get(slot_name, (slot_name or "").lower() or None),
            "slot_strategy": slot_name, "hand_preference": (it.get("hand_name") or "").lower() or None,
            "tier": it.get("tier"), "power_level": it.get("power_level"), "is_weapon": it.get("is_weapon"),
            "weight": it.get("weight"), "durability": it.get("base_durability"), "max_stack": it.get("max_stack"),
            "custom_stats": it.get("custom_stats") or [], "flavour": it.get("flavour"),
            "requirements": {k: it.get(k) for k in ("perk_required", "recipe_required", "entitlement_required")
                             if it.get(k)},
            "source": it.get("source"),
        }
        held = it.get("held")
        if held is not None:
            actor, inferred = class_path(held.get("actor_class"))
            acts = held.get("actions") or {}
            attacks = {}
            for k in ACTION_KEYS:
                if acts.get(k):
                    attacks[k] = attack_set(m, acts[k])
                    sets[acts[k]] = attacks[k]
            attack_source = "item" if attacks.get("primary") else None
            if not attacks.get("primary") and rec["kind"] == "held":
                guess = (learned.get(cat) or Counter()).most_common(1)
                fb = guess[0][0] if guess else CATEGORY_ACTION_FALLBACK.get(cat or "")
                if fb:
                    attacks["primary"] = attack_set(m, fb) if fb in m["actions"] else \
                        {"action": fb, "kind": None, "chain": [], "damage": None}
                    attack_source = "category_learned" if guess else "category_table"
            rc = held.get("ranged_collection")
            col = m["collections"].get(rc) if rc else None
            hand = "left" if rec["slot"] == "left_hand" or (rec["slot"] == "hand_any" and rec["hand_preference"] == "left") \
                else "right"
            rec.update({
                "held_actor_class": actor, "held_actor_class_inferred": inferred or None,
                "hand": hand, "socket": "prop_l" if hand == "left" else "prop_r",
                "range_type": range_type(cat, held, attacks.get("primary")),
                "role": "shield" if cat == "shield" else ("weapon" if it.get("is_weapon") else
                                                         ("tool" if cat in TOOL_CATS else "other")),
                "stats": {k: held.get(k) for k in ("damage_multiplier", "additional_damage_multiplier",
                                                   "blocking_damage_negation", "additional_blocking_damage_negation",
                                                   "stamina_cost_multiplier", "crit_chance_increase", "reload_duration",
                                                   "requires_reload") if held.get(k) is not None},
                "damage_types": held.get("damage_types") or [],
                "ammo": held.get("ammo_name"), "required_ammo_tag": held.get("required_ammo_tag"),
                "projectile_class": held.get("projectile_class"), "pose": held.get("pose_name"),
                "power_level_row": held.get("power_level_row"),
                "attacks": attacks, "attack_source": attack_source,
                "ranged": {"collection": rc, "quick_attack": (col or {}).get("quick_attack"),
                           "full_attack": (col or {}).get("full_attack")} if rc else None,
                "magic_collection": held.get("magic_collection"),
            })
        wear = it.get("wearable")
        if wear is not None:
            rec.update({"role": "armour", "range_type": None,
                        "stats": {"armor_weight": wear.get("armor_weight_name"), "warmth": wear.get("warmth_name")},
                        "data_row": wear.get("data_row"), "male_mesh": wear.get("male_mesh"),
                        "female_mesh": wear.get("female_mesh")})
        items[iid] = {k: v for k, v in rec.items() if v is not None}

    registry = m["registry"]
    missing = sorted(set(registry) - set(raw_items))
    return {
        "schema": SCHEMA, "build": build, "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": {"raw_files": m["files"], "registry_count": len(registry), "described_count": len(raw_items),
                   "missing_from_catalog": missing, "errors": m["errors"][:200]},
        "items": items, "attack_sets": sets, "attacks": attacks_out(m["attacks"]), "ranged_collections": m["collections"],
        "category_action_fallback": CATEGORY_ACTION_FALLBACK,
    }


def summary(cat: dict) -> str:
    items = cat["items"].values()
    by = lambda k: dict(Counter(str(i.get(k)) for i in items).most_common())  # noqa: E731
    held = [i for i in items if i.get("kind") == "held"]
    return json.dumps({
        "items": len(cat["items"]), "registry": cat["source"]["registry_count"],
        "missing": len(cat["source"]["missing_from_catalog"]), "by_kind": by("kind"), "by_category": by("category"),
        "by_range_type": by("range_type"), "by_slot": by("slot"),
        "held_without_actor_class": sum(1 for i in held if not i.get("held_actor_class")),
        "held_actor_class_inferred": sum(1 for i in held if i.get("held_actor_class_inferred")),
        "held_attack_source": dict(Counter(str(i.get("attack_source")) for i in held)),
        "errors": len(cat["source"]["errors"]),
    }, indent=1)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", default=BUILD)
    ap.add_argument("--limit", type=int, default=10, help="assets loaded per batch (each batch stalls the game thread)")
    ap.add_argument("--max-batches", type=int, default=0, help="stop after N load batches (0 = all)")
    ap.add_argument("--pause", type=float, default=1.0, help="seconds between batches")
    ap.add_argument("--timeout", type=float, default=120.0, help="bridge timeout per call, seconds")
    ap.add_argument("--no-load", action="store_true", help="describe loaded items only; never call LoadAsset")
    ap.add_argument("--registry-mode", choices=("class", "path"), default="class")
    ap.add_argument("--kismet-soft", action="store_true",
                    help="allow the Conv_SoftClassReferenceToString fallback for soft class paths")
    ap.add_argument("--montage", action="store_true", help="read each attack's montage length (property reads)")
    ap.add_argument("--notifies", action="store_true",
                    help="also read montage notify windows (combo input window, damage point, chain reset)")
    ap.add_argument("--merge-only", metavar="RAW_DIR", help="skip the server; merge an existing raw directory")
    ap.add_argument("--out", help="default data/items_<build>.json")
    a = ap.parse_args()

    if a.merge_only:
        raw_dir = Path(a.merge_only)
    else:
        raw_dir = REPO_ROOT / "logs" / "catalog" / f"{a.build}_{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
        raw_dir.mkdir(parents=True, exist_ok=True)
        try:
            run_live(a, raw_dir)
        except RuntimeError as exc:
            print(f"live run stopped: {exc}\nmerging what was written so far from {raw_dir}", file=sys.stderr)
    cat = normalise(merge_raw(raw_dir), a.build)
    out = Path(a.out) if a.out else REPO_ROOT / "data" / f"items_{a.build}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(cat, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {out}\n{summary(cat)}")


if __name__ == "__main__":
    main()

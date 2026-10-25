"""BenchWorld: the mock game driven by the build's catalogs, for LINT runs of benchmark cases (design §2, §6).

Mock results never count for GOAL (review finding 3). BenchWorld exists to develop and test the harness: the observer,
leaves, controls and runner, offline. What it adds over brain/mock MockGame:
- every spell from data/spell_effects.json (cost in rune items, cooldown, cast type) with effects simulated per
  evidence kind (tags, GEs, spell actors, displacement, drops, jump boost) - generic, never per spell name;
- a ground truth `probe()` independent of tool replies (the observer reads it), and `referee` events (like the dev
  server referee: damage with type, kills with kind id, teleports, item changes);
- a "lying body" switch to test sensor_mismatch (the reply claims what the probe doesn't see);
- bag capacity in slots, felled logs, ledges, creatures with kind ids and weaknesses;
- fixture verbs (grant, unlock, spawn, ...) and no free place names in get_state (finding 3).
"""
from __future__ import annotations

import json
import math
from collections import Counter
from pathlib import Path
from typing import Any

from brain.interface import Coords, Reason, fail, ok
from brain.mock.game import Entity, MockGame, Player

ROOT = Path(__file__).resolve().parents[2]
STACK = 99
RUNE_PREFIX = "ITEM_Rune_"
JUMP_BOOST_S = 10.0
NORMAL_JUMP_M = 1.8


def rune_item(name: str) -> str:
    return name if name.startswith("ITEM_") else RUNE_PREFIX + name


def load_spell_data(root: Path = ROOT) -> tuple[dict, dict]:
    """(spell_effects.json spells, spells_<build>.json spells) - the manifest data and the descriptions."""
    eff = json.loads((root / "data" / "spell_effects.json").read_text(encoding="utf-8"))
    cats = sorted((root / "data").glob("spells_*.json"))
    cat = json.loads(cats[-1].read_text(encoding="utf-8")) if cats else {}
    return eff.get("spells") or {}, cat.get("spells") or {}


class BenchWorld(MockGame):
    def __init__(self, spell_effects: dict | None = None, spell_catalog: dict | None = None) -> None:
        super().__init__()
        if spell_effects is None:
            spell_effects, spell_catalog = load_spell_data()
        self.spell_data = spell_effects
        self.spell_catalog = spell_catalog or {}
        self.unlocked = set()
        self.tags: dict[str, float] = {}  # tag -> expires at
        self.ges: dict[str, float] = {}  # GE class -> expires at
        self.cooldowns: dict[str, float] = {}  # spell id -> last cast time (LastCastTimeBySpellData)
        self.actors: list[dict] = []  # spell actors and scene things (felled logs, ledges)
        self.held: dict[str, Any] = {"item": None, "category": None, "effects": []}
        self.vitals = {"hydration": 80.0, "sustenance": 80.0}
        self.bag_slots = 24
        self.referee: list[dict] = []
        self.lie: str | None = None  # "claim_runes" | "hide_runes" | "claim_effect"
        self.places_known = False
        self.ledges: dict[str, dict] = {}
        self.things: dict[str, dict] = {}  # perceivable scene things: felled logs, ledges
        self.skills: dict[str, dict] = {}  # name -> {level, xp} (fixture "skill")

    # ------------------------------------------------------------------ fixtures (harness only)
    def setup(self, verb: str, **a) -> dict:
        """Harness fixture verbs (the mock twin of mod/bench/fixtures.lua). Never called by the companion."""
        if verb == "grant":
            self.inventory[a["item"]] += int(a.get("count", 1))
        elif verb == "grant_runes":
            for r, n in (a.get("runes") or {}).items():
                self.inventory[rune_item(r)] += int(n)
        elif verb == "unlock":
            self.unlocked.add(a["spell"])
        elif verb == "hold":
            self.held = {"item": a.get("item"), "category": a.get("category"), "effects": []}
        elif verb == "spawn":
            eid = self.add_entity(a.get("kind", "creature"), a.get("at", [5, 0, 0]), hp=int(a.get("hp", 30)),
                                  hostile=bool(a.get("hostile", True)), damage=int(a.get("damage", 5)))
            e = self.entities[eid]
            e.kind_id = a.get("kind_id", a.get("kind"))  # type: ignore[attr-defined]
            e.weakness = a.get("weakness")  # type: ignore[attr-defined]
            e.pl = a.get("power_level", 1)  # type: ignore[attr-defined]
            return {"id": eid}
        elif verb == "player":
            self.players[a.get("name", "Tester")] = Player(a.get("name", "Tester"), [float(c) for c in a.get("at", [2, 0, 0])])
        elif verb == "place":
            self.places[a["name"]] = [float(c) for c in a["at"]]
        elif verb == "ground_item":
            return {"id": self.add_ground_item(a["item"], int(a.get("count", 1)), a.get("at", [1, 0, 0]))}
        elif verb == "node":
            return {"id": self.add_node(a["resource"], a.get("at", [8, 0, 0]), int(a.get("remaining", 5)))}
        elif verb == "felled_log":
            tid = self._new_id("felled_log")
            self.things[tid] = {"id": tid, "name": a.get("name", "Felled Log"), "kind": "felled_log",
                                "position": [float(c) for c in a.get("at", [4, 0, 0])], "drops": a.get("drops", "log"),
                                "drop_count": int(a.get("count", 4)), "class_family": "TreeLog"}
            return {"id": tid, "drops": self.things[tid]["drops"]}
        elif verb == "ledge":
            tid = self._new_id("ledge")
            top = [float(c) for c in a["top"]]
            self.things[tid] = {"id": tid, "name": "high ledge", "kind": "ledge", "position": top,
                                "rise_m": float(a.get("rise_m", top[2]))}
            return {"id": tid, "top": top}
        elif verb in ("skill", "reset_skills"):
            self.skills[a["skill"]] = {"level": int(a.get("level", 1)), "xp": float(a.get("xp", 0))}
        elif verb == "teleport_self":
            self.pos = [float(c) for c in a["to"]]
        elif verb == "vital":
            self.vitals[a["stat"]] = float(a["value"])
        elif verb == "lie":
            self.lie = a.get("mode")
        else:
            raise ValueError(f"unknown fixture verb {verb!r}")
        return {}

    # ------------------------------------------------------------------ ground truth for the observer
    def probe(self) -> dict:
        """What a harness-owned read of the game shows (bench_probe.lua's twin): never derived from tool replies."""
        now = self.time
        return {"t": now, "position": list(self.pos), "health": self.health,
                "inventory": dict(+self.inventory),
                "tags": sorted(t for t, until in self.tags.items() if until > now),
                "ge": sorted(g for g, until in self.ges.items() if until > now),
                "cooldowns": dict(self.cooldowns),
                "held": {"item": self.held.get("item"), "effects": list(self.held.get("effects") or [])},
                "vitals": dict(self.vitals),
                "actors": [dict(a) for a in self.actors],
                "things": [dict(t) for t in self.things.values()],
                "ground": [{"id": g.id, "item": g.item, "count": g.count, "position": list(g.pos)} for g in self.ground.values()],
                "creatures": [{"id": e.id, "kind": e.kind, "kind_id": getattr(e, "kind_id", e.kind), "hp": e.hp,
                               "alive": e.alive, "position": list(e.pos)} for e in self.entities.values()],
                "players": [{"name": p.name, "position": list(p.pos), "inventory": dict(+p.inventory)}
                            for p in self.players.values()],
                "skills": {k: dict(v) for k, v in self.skills.items()},
                "jump_apex_m": self._jump_apex()}

    def _jump_apex(self) -> float:
        return NORMAL_JUMP_M + (5.0 if self.tags.get("_jump_boost", -1) > self.time else 0.0)

    def _ref(self, kind: str, **f) -> None:
        self.referee.append({"t": self.time, "kind": kind, **f})

    # ------------------------------------------------------------------ state the companion sees
    def bag_used(self) -> int:
        return sum(math.ceil(n / STACK) for n in self.inventory.values() if n > 0)

    def get_state(self):
        res = super().get_state()
        d = res["data"]
        if not self.places_known:
            d.pop("places", None)
        d["inventory_items"] = [{"item": i, "name": i, "count": n} for i, n in sorted(self.inventory.items()) if n > 0]
        d["bag"] = {"used": self.bag_used(), "capacity": self.bag_slots}
        d["hydration"], d["sustenance"] = self.vitals["hydration"], self.vitals["sustenance"]
        d["held"] = {"item": self.held.get("item")}
        return res

    def _things(self, radius: float) -> list[dict]:
        out = super()._things(radius)
        for t in self.things.values():
            dist = round(math.dist(t["position"], self.pos), 1)
            if dist <= radius:
                out.append({"id": t["id"], "name": t["name"], "kind": t["kind"], "verb": "look", "distance": dist,
                            **({"drops": t["drops"]} if "drops" in t else {}),
                            **({"height_m": t["rise_m"]} if "rise_m" in t else {})})
        return sorted(out, key=lambda t: t["distance"])

    def _resolve(self, target):
        if isinstance(target, str) and target in self.things:
            return self.things[target]["position"]
        return super()._resolve(target)

    # ------------------------------------------------------------------ movement with height (ledges)
    def go_to(self, target: str | Coords):
        dest = self._resolve(target)
        if dest is not None and dest[2] - self.pos[2] > NORMAL_JUMP_M + 0.2 and self._jump_apex() < dest[2] - self.pos[2]:
            self._begin("go_to", target=target)
            return fail(Reason.PATH_BLOCKED, detail=f"it is {dest[2] - self.pos[2]:.1f} m up; higher than I can jump")
        return super().go_to(target)

    # ------------------------------------------------------------------ spells from data
    def _sid(self, name: str) -> str | None:
        want = "".join(ch for ch in (name or "").lower() if ch.isalnum())
        for sid, sp in self.spell_data.items():
            if want in ("".join(ch for ch in sid.lower() if ch.isalnum()),
                        "".join(ch for ch in str(sp.get("name") or "").lower() if ch.isalnum())):
                return sid
        return None

    def _desc(self, sid: str) -> str:
        c = self.spell_catalog.get(sid) or {}
        return ((c.get("usage") or {}).get("use_when")) or str(self.spell_data[sid].get("name"))

    def spells(self):
        rows = []
        for sid in sorted(self.unlocked):
            sp = self.spell_data.get(sid) or {}
            why = self._block(sid)
            rows.append({"id": sid, "name": sp.get("name"), "role": sp.get("cast_type"), "use_when": self._desc(sid),
                         "castable": why is None, "reason": why,
                         "cost": [{"item": rune_item(r), "count": n, "have": self.inventory[rune_item(r)]}
                                  for r, n in (sp.get("cost") or {}).items()]})
        return ok(spells=rows)

    def _block(self, sid: str) -> str | None:
        sp = self.spell_data[sid]
        if sid not in self.unlocked:
            return Reason.NOT_UNLOCKED
        if any(self.inventory[rune_item(r)] < n for r, n in (sp.get("cost") or {}).items()):
            return Reason.NOT_ENOUGH
        last = self.cooldowns.get(sid)
        if last is not None and self.time - last < float(sp.get("cooldown_s") or 0):
            return Reason.ON_COOLDOWN
        for chk in sp.get("setup_checks") or []:
            if "held_category" in chk and self.held.get("category") != chk["held_category"]:
                return "requirement"
        return None

    def cast(self, spell: str, target=None):
        if rule := self._begin("cast", spell=spell, target=target):
            return self._apply_rule(rule)
        sid = self._sid(spell)
        if sid is None:
            return fail(Reason.UNKNOWN_TARGET, spell=spell, candidates=[self.spell_data[s].get("name") for s in sorted(self.unlocked)])
        why = self._block(sid)
        if why:
            return fail(why, spell=self.spell_data[sid].get("name"), id=sid)
        sp = self.spell_data[sid]
        point = self._resolve(target) if target not in (None, "self") else None
        if sp.get("target") == "thing" and point is None:
            return fail(Reason.NOTHING_IN_RANGE, detail="needs a target", id=sid)
        cost = {rune_item(r): int(n) for r, n in (sp.get("cost") or {}).items()}
        spent = dict(cost)
        if self.lie != "claim_runes":
            for item, n in cost.items():
                self.inventory[item] -= n
            self.cooldowns[sid] = self.time
        effects = {"ge": [], "tags": []}
        data: dict[str, Any] = {}
        if self.lie != "claim_runes":
            data = self._apply_effects(sid, sp, target, point, effects)
        self._advance(1.0)
        if self.lie == "hide_runes":
            spent = {}
        if self.lie == "claim_effect":
            effects["tags"].append("Fake.Tag")
        return ok(id=sid, spell=sp.get("name"), runes_spent=spent, cooldown_started=self.lie != "hide_runes",
                  effects=effects, **data)

    def _apply_effects(self, sid: str, sp: dict, target, point, effects: dict) -> dict:
        """Simulate the spell's documented evidence kinds (generic by kind, no spell names)."""
        data: dict[str, Any] = {}
        until = self.time + float(sp.get("cooldown_s") or 30) + 30
        for e in (sp.get("proof") or {}).get("effect") or []:
            k = e.get("kind")
            if k == "tag_added" and e.get("tag"):
                self.tags[e["tag"]] = until
                effects["tags"].append(e["tag"])
            elif k == "ge_added":
                cls = e.get("class") or e.get("class_contains")
                self.ges[cls] = until
                effects["ge"].append(cls)
            elif k == "spell_actor":
                a = {"id": self._new_id("spell_actor"), "class": e.get("class"), "spell": sid,
                     "position": list(point or self.pos), "t": self.time}
                self.actors.append(a)
                data.update(spell_actor=a["id"], landed_at=a["position"])
            elif k == "jump_apex_gain_m":
                self.tags["_jump_boost"] = self.time + JUMP_BOOST_S
            elif k in ("air_dash_m", "moved_m"):
                self.pos[0] += float(e.get("min", 5)) + 1.0
                data["moved_m"] = float(e.get("min", 5)) + 1.0
            elif k in ("target_gone", "drops_spawned", "target_health_drop") and isinstance(target, str):
                if target in self.things and self.things[target]["kind"] == "felled_log" and k != "target_health_drop":
                    t = self.things.pop(target)
                    for i in range(t["drop_count"]):
                        self.add_ground_item(t["drops"], 1, [t["position"][0] + 0.3 * i, t["position"][1], 0.0])
                    data["target_after"] = "gone"
                    self._ref("item_spawned", item=t["drops"], count=t["drop_count"], by=sid)
                elif target in self.entities and k == "target_health_drop":
                    ent = self.entities[target]
                    ent.hp -= 10
                    data["target_health"] = ent.hp
                    self._ref("damage", target=target, kind_id=getattr(ent, "kind_id", ent.kind), amount=10,
                              damage_type="DamageType.Magical", by="self", source=sid)
            elif k == "held_item_effect":
                self.held.setdefault("effects", []).extend(e.get("damage_types") or [])
        return data

    # ------------------------------------------------------------------ combat with the referee
    def attack(self, target: str):
        e = self.entities.get(target)
        hp0 = e.hp if e else None
        res = super().attack(target)
        if e is not None:
            dtype = next((x for x in self.held.get("effects") or [] if x.startswith("DamageType")), "DamageType.Physical")
            self._ref("damage", target=target, kind_id=getattr(e, "kind_id", e.kind), amount=(hp0 or 0) - max(e.hp, 0),
                      damage_type=dtype, by="self")
            if not e.alive:
                self._ref("death", who=target, kind_id=getattr(e, "kind_id", e.kind), killer="self")
                self._events.append(_activity("combat_end", target=e.kind, target_id=e.id, outcome="killed",
                                              target_class=getattr(e, "kind_id", e.kind)))
        return res

    def pickup(self, target: str, item: str | None = None, limit: int = 1):
        before = Counter(self.inventory)
        res = super().pickup(target, item, limit)
        gained = {k: self.inventory[k] - before[k] for k in self.inventory if self.inventory[k] > before[k]}
        for k, n in gained.items():
            self._ref("item_change", who="self", item=k, delta=n, via="pickup")
        return res


def _activity(kind: str, **f):
    from brain.interface import Activity
    return Activity(kind=kind, by="brain", ts=None, **f)

"""GearWorld: a mock game driven by the build's catalogs, for the Director's T3 job scenarios (director.md wave 4).

What it adds over MockGame, all from data/items_<build>.json and data/recipes_<build>.json (never per item name):
- items are real item ids; names, slots, tool categories and tiers come from the item catalog;
- resource nodes yield a catalog item, gated by a tool category and tier (the derived rock-gate table:
  wiki node infoboxes resolved to catalog tool tiers, tools/build_rock_gates.py); gathering gives skill XP;
- stations of real station types (recipes' ``stations``); ``craft`` uses the real recipe inputs/outputs/yields and
  the recipe's own skill XP; a processing station shows ``running`` while it works;
- ``equip`` (catalog slot), gear in ``gear``, a bag in slots (``inventory_full``), ``inventory_items`` rows;
- creatures with a class, power level and drops (looted into the bag, as the body's loot reflex does);
  ``attack`` emits a body-verified ``combat_end`` activity;
- ``drop`` makes world items (ids) at his or a player's feet; ``player_collect`` makes a player take them (the
  stack shows ``magnet_target`` first, then is gone);
- ``craft_plan``: a small read-only tree over the same recipes (the client's crafting.lua plan_tree is the live one);
- building (``build``, client build.lua's shape): pieces come from harness data (``add_buildable``: name,
  materials, kind = station | container | plot | other), cost real catalog items and give Construction XP; placed
  pieces show in ``structures`` (id, name, piece, position, distance) like the client's get_state.structures;
- containers (``store``/``take``, skills.lua's result shape: item, count, container, container_name, inside_now);
- farm plots (``tend``, farm.lua's shape: use a carried seed on an empty plot = plant; use nothing on a grown one =
  harvest) with growth over game time; ``farm_plots`` reads them. Seed -> crop is harness data (``add_buildable``
  ``crops``), never a table in the brain;
- primitives can be switched off (``remove_tool``) to provoke capability gaps; there is no teleport or quest
  primitive and no quest perception (gaps the board must log, never fake).
The Director and the benchmark only ever see get_state and tool results, like on the real body.
"""
from __future__ import annotations

import json
import math
from collections import Counter
from functools import lru_cache
from pathlib import Path
from typing import Any

from .. import item_stats, paths
from ..interface import Activity, ActionResult, Coords, GatherProgress, Reason, fail, ok
from ..situation import tokens
from .game import Entity, MockGame, ResourceNode

STATION_REACH_M = 60.0
DEFAULT_BAG_SLOTS = 24
STACK = 99


FROM_DATA = object()  # add_resource: take the node's gate from the rock-gate table


@lru_cache(maxsize=1)
def rock_gates() -> dict[str, dict]:
    """item id -> {category, min_tier, manual_xp, node} for nodes whose guaranteed drop is that item.
    From data/wiki/derived/rock_gates.json (tools/build_rock_gates.py; gitignored like the wiki mirror). Empty when
    absent: then nodes are ungated unless a test gives the gate."""
    f = paths.REPO_ROOT / "data" / "wiki" / "derived" / "rock_gates.json"
    try:
        nodes = json.loads(f.read_text(encoding="utf-8")).get("nodes") or []
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for n in nodes:
        always = [d for d in n.get("drops") or [] if str(d.get("rarity")).lower() == "always"] or (n.get("drops") or [])[:1]
        for d in always:
            for iid in d.get("items") or []:
                out.setdefault(iid, {"category": n.get("category"), "min_tier": n.get("min_tier"),
                                     "manual_xp": n.get("manual_xp"), "node": n.get("node")})
    return out


@lru_cache(maxsize=2)
def recipes_data(path: str | None = None) -> dict:
    files = sorted((paths.REPO_ROOT / "data").glob("recipes_*.json"))
    p = Path(path) if path else (files[-1] if files else None)
    return json.loads(p.read_text(encoding="utf-8")) if p else {}


def manifest() -> dict[str, dict]:
    """A capability manifest (client manifest.lua shape) for the tools this mock implements."""
    def a(desc, props, req=(), kind="action", **kw):
        return {"description": desc, "kind": kind, "llm": True, "moves": kind == "action",
                "args": {"type": "object", "properties": props, "required": list(req)}, **kw}
    s = {"type": "string"}
    i = {"type": "integer", "minimum": 1}
    return {
        "go_to": a("Walk to a player, an id, a place or [x, y, z].",
                   {"target": {"anyOf": [s, {"type": "array"}]}}, ["target"]),
        "gather": a("Harvest a resource kind nearby until you have count MORE of it.", {"resource": s, "count": i},
                    ["resource", "count"]),
        "craft": a("Craft an item at a station of the right type within 60 m from what you carry.",
                   {"item": s, "count": i}, ["item"]),
        "equip": a("Equip a carried item.", {"item": s}, ["item"], kind="waiter"),
        "drop": a("Drop carried items at your feet or a nearby player's feet.",
                  {"item": s, "count": i, "at": {"type": "string", "enum": ["feet", "player"]}, "player": s},
                  ["item", "count"], kind="waiter"),
        "attack": a("Fight a creature by its id until it is dead.", {"target": s}, ["target"]),
        "craft_plan": a("Plan how to make an item from the game's recipes over what you carry (read-only).",
                        {"item": s, "count": i}, ["item"], kind="read"),
        "buildables": a("Pieces you can build: name, materials, what you're still missing (read-only).",
                        {"about": s}, kind="read"),
        "build": a("Build one piece by its name from buildables (you need its materials), beside you.",
                   {"piece": s, "near": s}, ["piece"]),
        "store": a("Put carried items into a chest or storage by its id: walks there, moves them in, checks.",
                   {"item": s, "container": s, "count": i}, ["item", "container"]),
        "take": a("Take items out of a chest or storage by its id into your bag.",
                  {"item": s, "container": s, "count": i}, ["item", "container"]),
        "farm_plots": a("Farm plots near you: empty, planted (growing) or ready to harvest (read-only).", {},
                        kind="read"),
        "tend": a("Work a farm plot once: use a carried item on it (a seed plants it) or nothing (harvests a grown "
                  "crop). Trains Farming.", {"plot": s, "item": s}),
    }


class GearWorld(MockGame):
    manifest_tools = frozenset({"equip", "craft_plan", "buildables", "build", "store", "take", "farm_plots", "tend"})
    grow_s = 120.0  # game seconds from planting to harvest

    def __init__(self) -> None:
        super().__init__()
        self.cat = item_stats.catalog()
        self.rec = recipes_data()
        self.gear: dict[str, str] = {}
        self.skills: dict[str, list[float]] = {}
        self.bag_slots = DEFAULT_BAG_SLOTS
        self.stations: dict[str, dict] = {}
        self.node_meta: dict[str, dict] = {}
        self.creature_meta: dict[str, dict] = {}
        self.removed: set[str] = set()
        self.collecting: dict[str, str] = {}  # ground id -> player taking it
        self.buildables: dict[str, dict] = {}  # harness data: name -> {materials, kind, station, crops, xp}
        self.structures: dict[str, dict] = {}
        self.containers: dict[str, Counter] = {}
        self.plots: dict[str, dict] = {}
        self._names: dict[str, str] | None = None

    # ------------------------------------------------------------------ catalog helpers

    def names(self) -> dict[str, str]:
        if self._names is None:
            out = {k: (v or {}).get("name") or k for k, v in (self.rec.get("items") or {}).items()}
            out.update({k: v.get("name") or k for k, v in self.cat.items()})
            self._names = out
        return self._names

    def name_of(self, iid: str) -> str:
        return self.names().get(iid, iid)

    def resolve_item(self, q: str) -> str | None:
        if q in self.names():
            return q
        low = str(q).strip().lower()
        hit = [i for i, n in self.names().items() if str(n).lower() == low]
        return hit[0] if hit else None

    def _carried(self, iid: str) -> int:
        return int(self.inventory.get(iid, 0))

    def bag_used(self) -> int:
        return sum(math.ceil(n / STACK) for n in self.inventory.values() if n > 0)

    def _room_for(self, iid: str, n: int) -> bool:
        have = self._carried(iid)
        extra = math.ceil((have + n) / STACK) - math.ceil(have / STACK)
        return self.bag_used() + extra <= self.bag_slots

    # ------------------------------------------------------------------ world setup

    def carry(self, iid: str, n: int = 1) -> None:
        self.inventory[iid] += n

    def set_skill(self, name: str, level: int, xp: float = 0.0) -> None:
        self.skills[name] = [float(level), float(xp)]

    def _xp(self, skill: str | None, xp: float) -> None:
        if not skill or not xp:
            return
        key = skill[6:] if skill.startswith("SKILL_") else skill
        lvl, cur = self.skills.setdefault(key, [1.0, 0.0])
        cur += xp
        self.skills[key] = [1.0 + cur // 100.0, cur]  # mock curve: a level per 100 xp

    def add_resource(self, item: str, pos, remaining: int, tool: str | None | object = FROM_DATA,
                     min_tier: int | None = None, skill: str | None = None, xp: float | None = None) -> str:
        """A node that yields ``item``. Its tool gate comes from the derived rock-gate table (the wiki's node
        infobox resolved to catalog tiers, tools/build_rock_gates.py) unless given; no table row = no gate."""
        gate = rock_gates().get(item)
        if tool is FROM_DATA:
            tool = gate["category"] if gate else None
        if min_tier is None:
            min_tier = int(gate["min_tier"]) if gate and gate.get("min_tier") else 1
        if xp is None:
            xp = float(gate["manual_xp"]) if gate and str(gate.get("manual_xp") or "").isdigit() else 10.0
        nid = self.add_node(item, pos, remaining)
        self.node_meta[nid] = {"item": item, "tool": tool, "min_tier": min_tier, "skill": skill, "xp": xp}
        return nid

    def add_station(self, station_type: str, pos) -> str:
        sid = self._new_id("station")
        info = (self.rec.get("stations") or {}).get(station_type) or {}
        self.stations[sid] = {"id": sid, "station": station_type, "name": info.get("display_name") or station_type,
                              "kind": info.get("kind"), "position": list(map(float, pos)), "until": 0.0}
        return sid

    def add_creature(self, name: str, cls: str, pos, hp: int, power_level: int, drops: list[tuple[str, int]],
                     damage: int = 4, hostile: bool = True) -> str:
        eid = self.add_entity(name, pos, hp=hp, hostile=hostile, damage=damage)
        self.creature_meta[eid] = {"name": name, "class": cls, "power_level": power_level, "drops": list(drops)}
        return eid

    def add_buildable(self, name: str, materials: dict[str, int], kind: str = "other", station: str | None = None,
                      crops: dict[str, tuple[str, int]] | None = None, xp: float = 20.0) -> None:
        """A piece he can build (unlocked). kind: station (a ``station`` type from the recipes), container or plot
        (``crops``: seed item id -> (crop item id, yield))."""
        self.buildables[name] = {"materials": dict(materials), "kind": kind, "station": station,
                                 "crops": dict(crops or {}), "xp": xp}

    def remove_tool(self, name: str) -> None:
        self.removed.add(name)

    def player_collect(self, player: str, ground_id: str) -> None:
        """A player starts taking a stack (it flies to him: magnet_target), then it is gone."""
        if ground_id in self.ground:
            self.collecting[ground_id] = player

    def finish_collect(self) -> None:
        for gid in list(self.collecting):
            self.ground.pop(gid, None)
            self.collecting.pop(gid, None)

    # ------------------------------------------------------------------ perception

    def get_state(self) -> ActionResult:
        res = super().get_state()
        d = res["data"]
        d["inventory"] = {k: v for k, v in self.inventory.items() if v > 0}
        d["gear"] = dict(self.gear)
        d["inventory_items"] = ([{"item": i, "name": self.name_of(i), "count": n, "where": "bag"}
                                 for i, n in self.inventory.items() if n > 0]
                                + [{"item": i, "name": self.name_of(i), "equipped": True, "where": "loadout"}
                                   for i in self.gear.values()])
        d["skills"] = [{"skill": k, "level": v[0], "xp": v[1]} for k, v in sorted(self.skills.items())]
        d["bag"] = {"used": self.bag_used(), "capacity": self.bag_slots}
        near = []
        for st in self.stations.values():
            dist = math.dist(st["position"], self.pos)
            if dist <= STATION_REACH_M:
                near.append({"id": st["id"], "name": st["name"], "station": st["station"], "distance": round(dist, 1),
                             "running": self.time < st["until"]})
        d["stations_nearby"] = sorted(near, key=lambda r: r["distance"])
        d["structures"] = sorted(({"id": sid, "name": st["name"], "piece": st["name"], "position": st["position"],
                                   "distance": round(math.dist(st["position"], self.pos), 1)}
                                  for sid, st in self.structures.items()
                                  if math.dist(st["position"], self.pos) <= 30.0), key=lambda r: r["distance"])
        for r in d["nearby_resources"]:
            m = self.node_meta.get(r["id"])
            if m:
                r.update(item=m["item"], name=self.name_of(m["item"]))
        for e in d["nearby_entities"]:
            m = self.creature_meta.get(e["id"])
            if m:
                e.update(name=m["name"], power_level=m["power_level"], **{"class": m["class"]})
        for g in d["nearby_items"]:
            g["name"] = self.name_of(g["item"])
            if g["id"] in self.collecting:
                g["magnet_target"] = self.collecting[g["id"]]
        return res

    # ------------------------------------------------------------------ tools

    def _tool_ok(self, category: str | None, min_tier: int) -> bool:
        if not category:
            return True
        for iid in list(self.inventory) + list(self.gear.values()):
            e = self.cat.get(iid) or {}
            if (self.inventory.get(iid, 0) > 0 or iid in self.gear.values()) and e.get("category") == category \
                    and int(e.get("tier") or 0) >= min_tier:
                return True
        return False

    def gather(self, resource: str, count: int, radius: float | None = None) -> ActionResult:
        if "gather" in self.removed:
            return fail(Reason.NOT_IMPLEMENTED, tool="gather")
        rule = self._begin("gather", resource=resource, count=count)
        if rule:
            return self._apply_rule(rule)
        want = tokens(resource)
        reach = max(float(radius or 0), 30.0)
        cands = []
        for n in self.nodes.values():
            m = self.node_meta.get(n.id) or {"item": n.resource}
            words = tokens(m["item"]) | tokens(self.name_of(m["item"]))
            if n.remaining > 0 and (want <= words or resource in (m["item"], self.name_of(m["item"]))) \
                    and math.dist(n.pos, self.pos) <= reach:
                cands.append((math.dist(n.pos, self.pos), n, m))
        if not cands:
            return fail(Reason.NOTHING_IN_RANGE, resource=resource, detail=f"no {resource} within {reach:g} m")
        cands.sort(key=lambda x: x[0])
        got, item = 0, cands[0][2]["item"]
        for _, n, m in cands:
            if not self._tool_ok(m.get("tool"), int(m.get("min_tier") or 1)):
                if got == 0:
                    return fail(Reason.WRONG_TOOL, resource=resource, needs=m.get("tool"), tier=m.get("min_tier"))
                break
            self._walk(n.pos, 1.0)
            while n.remaining > 0 and got < count:
                if not self._room_for(m["item"], 1):
                    return fail(Reason.INVENTORY_FULL, item=m["item"], gathered=got,
                                detail="my bag is full")
                n.remaining -= 1
                self.inventory[m["item"]] += 1
                got += 1
                self._xp(m.get("skill"), m.get("xp") or 0)
                self._advance(2.0)
            self._progress(GatherProgress(resource=resource, item=m["item"], have=got, want=count))
            if got >= count:
                break
        if got < count:
            return fail(Reason.NOT_ENOUGH, resource=resource, item=item, gathered=got)
        return ok(resource=resource, item=item, gathered=got)

    def _recipes_for(self, iid: str) -> list[tuple[str, dict]]:
        out = []
        for rid, r in (self.rec.get("recipes") or {}).items():
            if r.get("test") or not r.get("stations") or not r.get("inputs"):
                continue
            if any(o.get("item") == iid for o in r.get("outputs") or []):
                out.append((rid, r))
        return sorted(out)

    def _near_station(self, types: list[str]) -> dict | None:
        best = None
        for st in self.stations.values():
            d = math.dist(st["position"], self.pos)
            if st["station"] in types and d <= STATION_REACH_M and (best is None or d < best[0]):
                best = (d, st)
        return best[1] if best else None

    def craft(self, item: str, count: int = 1) -> ActionResult:
        if "craft" in self.removed:
            return fail(Reason.NOT_IMPLEMENTED, tool="craft")
        iid = self.resolve_item(item)
        if iid is None:
            return fail(Reason.UNKNOWN_RECIPE, item=item)
        recs = self._recipes_for(iid)
        if not recs:
            return fail(Reason.UNKNOWN_RECIPE, item=item, detail=f"no recipe makes {self.name_of(iid)}")
        last_missing: dict = {}
        for rid, r in recs:
            st = self._near_station(r["stations"])
            if st is None:
                continue
            per = sum(o.get("count", 1) for o in r["outputs"] if o.get("item") == iid) or 1
            crafts = math.ceil(count / per)
            need = {i["item"]: i["count"] * crafts for i in r["inputs"]}
            missing = {self.name_of(k): v - self._carried(k) for k, v in need.items() if self._carried(k) < v}
            if missing:
                last_missing = missing
                continue
            self._walk(st["position"], 2.0)
            self.inventory -= Counter(need)
            self.inventory[iid] += crafts * per
            self._xp(r.get("skill"), float(r.get("xp") or 0) * crafts)
            t = float((r.get("processing_time") or [5, 5])[0]) if st.get("kind") == "processing" else 1.0
            st["until"] = self.time + t * crafts + 1.0 if st.get("kind") == "processing" else 0.0
            self._advance(min(t * crafts, 5.0))
            return ok(item=iid, recipe=rid, crafted=crafts * per, station=st["id"])
        if last_missing:
            return fail(Reason.MISSING_MATERIALS, item=iid, missing=last_missing)
        need_st = sorted({s for _, r in recs for s in r["stations"]})
        return fail(Reason.NOTHING_IN_RANGE, item=iid, stations=need_st,
                    detail=f"no {' or '.join(need_st)} within {STATION_REACH_M:g} m")

    def call_raw(self, tool: str, args: dict) -> ActionResult:
        if tool in self.removed:
            return fail(Reason.NOT_IMPLEMENTED, tool=tool)
        if tool == "equip":
            return self.equip(**args)
        if tool == "craft_plan":
            return self.craft_plan(**args)
        fn = {"buildables": self.list_buildables, "build": self.build, "store": self.store, "take": self.take,
              "farm_plots": self.farm_plots, "tend": self.tend}.get(tool)
        return fn(**args) if fn else fail(Reason.NOT_IMPLEMENTED, tool=tool)

    # ------------------------------------------------------------------ building, containers, farming

    def _missing(self, materials: dict[str, int]) -> dict[str, int]:
        return {self.name_of(i): n - self._carried(i) for i, n in materials.items() if self._carried(i) < n}

    def list_buildables(self, about: str | None = None) -> ActionResult:
        want = tokens(about or "")
        rows = [{"name": n, "materials": {self.name_of(i): c for i, c in b["materials"].items()},
                 "missing": self._missing(b["materials"])}
                for n, b in self.buildables.items() if not want or want & tokens(n)]
        return ok(pieces=rows)

    def build(self, piece: str, near: str | None = None, at=None) -> ActionResult:
        name = next((n for n in self.buildables if n.lower() == str(piece).lower()), None)
        if name is None:
            return fail(Reason.UNKNOWN_TARGET, piece=piece, detail=f"no buildable piece called {piece}")
        b = self.buildables[name]
        missing = self._missing(b["materials"])
        if missing:
            return fail(Reason.MISSING_MATERIALS, piece=name, missing=missing)
        self.inventory -= Counter(b["materials"])
        pos = [self.pos[0] + 2.0 + len(self.structures), self.pos[1], self.pos[2]]
        sid = self._new_id("piece")
        self.structures[sid] = {"name": name, "position": pos, "kind": b["kind"]}
        if b["kind"] == "station" and b.get("station"):
            st_id = self.add_station(b["station"], pos)
            self.structures[sid]["station_id"] = st_id
        elif b["kind"] == "container":
            self.containers[sid] = Counter()
        elif b["kind"] == "plot":
            self.plots[sid] = {"crop": None, "planted_at": None, "crops": b["crops"]}
        self._xp("Construction", b["xp"])
        self._advance(5.0)
        return ok(piece=name, id=sid, position=pos)

    def _transfer(self, item: str, container: str, count: int | None, deposit: bool) -> ActionResult:
        if container not in self.containers:  # a name, as find_thing resolves one: the nearest such container
            named = [k for k in self.containers if self.structures[k]["name"].lower() == str(container).lower()]
            container = min(named, key=lambda k: math.dist(self.structures[k]["position"], self.pos), default=container)
        box = self.containers.get(container)
        if box is None:
            return fail(Reason.UNKNOWN_TARGET, container=container, detail="I can't see that chest near me.")
        if math.dist(self.structures[container]["position"], self.pos) > 30.0:
            return fail(Reason.TOO_FAR, container=container)
        iid = self.resolve_item(item) or item
        src = self.inventory if deposit else box
        have = int(src.get(iid, 0))
        n = int(count or have)
        if have < 1 or n > have:
            return fail(Reason.NOT_IN_INVENTORY if deposit else Reason.NOTHING_IN_RANGE, item=item, have=have)
        if not deposit and not self._room_for(iid, n):
            return fail(Reason.INVENTORY_FULL, item=iid)
        self._walk(self.structures[container]["position"], 1.5)
        src[iid] -= n
        (box if deposit else self.inventory)[iid] += n
        return ok(item=iid, name=self.name_of(iid), count=n, container=container,
                  container_name=self.structures[container]["name"], inside_now=int(box.get(iid, 0)),
                  carried_now=self._carried(iid))

    def store(self, item: str, container: str, count: int | None = None) -> ActionResult:
        return self._transfer(item, container, count, True)

    def take(self, item: str, container: str, count: int | None = None) -> ActionResult:
        return self._transfer(item, container, count, False)

    def _plot_row(self, pid: str) -> dict:
        p = self.plots[pid]
        if p["crop"] is None:
            phase = "empty"
        else:
            phase = "ready" if self.time - p["planted_at"] >= self.grow_s else "growing"
        return {"id": pid, "phase": phase, "crop": self.name_of(p["crop"]) if p["crop"] else None,
                "distance": round(math.dist(self.structures[pid]["position"], self.pos), 1)}

    def farm_plots(self) -> ActionResult:
        return ok(plots=[self._plot_row(pid) for pid in self.plots])

    def tend(self, plot: str | None = None, item: str | None = None) -> ActionResult:
        pid = plot or min(self.plots, key=lambda k: math.dist(self.structures[k]["position"], self.pos), default=None)
        if pid not in self.plots:
            return fail(Reason.UNKNOWN_TARGET, plot=plot, detail="no farm plot near me")
        p, row = self.plots[pid], self._plot_row(pid)
        self._walk(self.structures[pid]["position"], 1.0)
        if item is not None:
            iid = self.resolve_item(item) or item
            if self._carried(iid) < 1:
                return fail(Reason.NOT_IN_INVENTORY, item=item)
            if row["phase"] != "empty" or iid not in p["crops"]:
                return fail(Reason.NOT_INTERACTABLE, plot=pid, phase=row["phase"],
                            detail=f"nothing happened using {self.name_of(iid)} on a {row['phase']} plot")
            self.inventory[iid] -= 1
            p["crop"], p["planted_at"], p["seed"] = p["crops"][iid][0], self.time, iid
            self._xp("Farming", 5.0)
            return ok(plot=pid, phase="growing", planted=self.name_of(iid))
        if row["phase"] != "ready":
            return fail(Reason.NOT_INTERACTABLE, plot=pid, phase=row["phase"],
                        detail=f"the plot is {row['phase']}" + (", not ready yet" if row["phase"] == "growing" else ""))
        crop, n = p["crops"][p["seed"]]
        self.inventory[crop] += n
        p["crop"] = p["planted_at"] = None
        self._xp("Farming", 15.0)
        return ok(plot=pid, phase="empty", item=crop, count=n)

    def equip(self, item: str) -> ActionResult:
        iid = self.resolve_item(item)
        if iid is None or self._carried(iid) < 1:
            return fail(Reason.NOT_IN_INVENTORY, item=item)
        st = item_stats.stats(iid, self.cat) or {}
        raw = str(st.get("slot") or "")
        slot = item_stats._slot_key(raw) or "held"
        if slot == "held":  # a shield (left_hand) goes in the left hand; one- and two-handed items in the right
            slot = "held_left" if raw == "left_hand" else "held_right"
            if raw == "two_handed":
                old_left = self.gear.pop("held_left", None)
                if old_left:
                    self.inventory[old_left] += 1
        old = self.gear.get(slot)
        if old:
            self.inventory[old] += 1
        self.inventory[iid] -= 1
        self.gear[slot] = iid
        return ok(item=iid, slot=slot, replaced=old)

    def craft_plan(self, item: str, count: int = 1) -> ActionResult:
        iid = self.resolve_item(item)
        if iid is None:
            return fail(Reason.UNKNOWN_RECIPE, item=item)

        def node(i: str, n: int, depth: int) -> dict:
            have = self._carried(i)
            out: dict[str, Any] = {"item": i, "name": self.name_of(i), "need": n, "have": have}
            recs = self._recipes_for(i)
            if have >= n or depth > 4 or not recs:
                out["status"] = "have" if have >= n else ("gather" if not recs else "depth")
                return out
            rid, r = self._best_recipe(i, recs)
            per = sum(o.get("count", 1) for o in r["outputs"] if o.get("item") == i) or 1
            crafts = math.ceil((n - have) / per)
            out.update(status="craft", recipe=rid, station=r["stations"], crafts=crafts,
                       inputs=[node(x["item"], x["count"] * crafts, depth + 1) for x in r["inputs"]])
            return out
        return ok(root=node(iid, count, 0))

    def _best_recipe(self, item: str, recs: list[tuple[str, dict]]) -> tuple[str, dict]:
        """Rank like the client planner (crafting.lua candidates): a station of its type near, then how many of
        its inputs he carries or can make without needing the item itself (no cycles), then the recipe id."""
        def score(rr):
            rid, r = rr
            near = self._near_station(r["stations"]) is not None
            ok_inputs = sum(1 for x in r["inputs"] if self._carried(x["item"]) >= x["count"] or
                            (self._recipes_for(x["item"]) and not any(o.get("item") == item for _, rx in
                             self._recipes_for(x["item"]) for o in rx.get("inputs") or [])))
            return (not near, -ok_inputs / max(1, len(r["inputs"])), rid)
        return sorted(recs, key=score)[0]

    def drop(self, item: str, count: int, at: str = "feet", player: str | None = None) -> ActionResult:
        iid = self.resolve_item(item) or item
        if self._carried(iid) < count:
            return fail(Reason.NOT_IN_INVENTORY, item=item, have=self._carried(iid))
        pos = list(self.pos)
        if at == "player":
            p = self.players.get(player or next(iter(self.players), ""))
            if p is None or math.dist(p.pos, self.pos) > 4.0:
                return fail(Reason.TOO_FAR, player=player)
            pos = list(p.pos)
        self.inventory[iid] -= count
        gid = self.add_ground_item(iid, count, pos)
        return ok(item=iid, count=count, world_items=[gid])

    def attack(self, target: str) -> ActionResult:
        e = self.entities.get(target)
        if e is None or not e.alive:
            return fail(Reason.UNKNOWN_TARGET, target=target)
        m = self.creature_meta.get(target, {"name": e.kind, "class": e.kind, "drops": []})
        self._walk(e.pos, 1.5)
        hp0 = self.health
        while e.hp > 0:
            e.hp -= 10
            if e.hp <= 0:
                break
            self.health -= e.damage
            self._advance(1.0)
            if self.health <= 0:
                self._events.append(Activity(kind="combat_end", by="brain", target=m["name"], target_id=target,
                                             target_class=m["class"], outcome="died"))
                return fail(Reason.COMPANION_DOWN)
        e.hp, e.alive = 0, False
        loot = []
        for iid, n in m.get("drops") or []:  # the body's loot reflex picks drops up (or leaves them when full)
            if self._room_for(iid, n):
                self.inventory[iid] += n
                loot.append({"item": iid, "name": self.name_of(iid), "count": n})
            else:
                self.add_ground_item(iid, n, list(e.pos))
        self._events.append(Activity(kind="combat_end", by="brain", target=m["name"], target_id=target,
                                     target_class=m["class"], outcome="killed", damage_taken=hp0 - self.health,
                                     loot=loot))
        return ok(target=target, killed=True, loot=loot)

    def pickup(self, target: str, item: str | None = None, limit: int = 1) -> ActionResult:
        g = self.ground.get(target)
        if g is None:
            return fail(Reason.UNKNOWN_TARGET, target=target)
        if not self._room_for(g.item, g.count):
            return fail(Reason.INVENTORY_FULL, item=g.item)
        self._walk(g.pos, 1.0)
        self.inventory[g.item] += g.count
        del self.ground[target]
        return ok(item=g.item, count=g.count, picked=[{"world_item": target, "item": g.item, "count": g.count}])

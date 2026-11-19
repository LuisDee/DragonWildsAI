"""The job tree of the open ask: what its target needs, laid out from the game's own data to full depth, each node's
status read from the game state every turn, each node's last failures from the body's outcome reports. DATA only:
code orders nothing, executes nothing and chooses no alternative (CLAUDE.md section 3: the model decides).

Why (docs/research/2026-11-18-job-tree-architecture.md, docs/research/2026-11-18-fix-audit.md): the copper rung V1
stood at 0 of 14 after about 16 changes, 9 of them one true fact added to a tool result per failure. The facts were
right; the form was wrong. They came one per failure (a chain of N hidden prerequisites cost N windows), they scrolled
out of his context ("the tier fact had left his context by the time he chose the stone pickaxe": 4 of 4 replays kept
the bone pickaxe with it back), and he had to assemble a dependency graph from scattered prose ("copper needs a bronze
pickaxe first"). Every system that reaches iron or diamond in Minecraft reliably holds the tree as data.

Search before building (adapted, not reused: none of these is a library for this game's data):
- GITM (arXiv 2305.17144): a goal as (object, count, material, tool), expanded recursively from recipe and wiki text
  until no prerequisite is left. Taken: the node form (item + count, its recipe inputs, the TOOL as a prerequisite
  edge), the external knowledge as the source.
- Optimus-1 (arXiv 2408.03615, HDKG): an explicit item graph from the game data and the wiki; for a target the
  sub-graph is pulled and handed to the planner (removing it cost about 20 %, the largest ablation). Taken: the
  sub-graph for the target, handed whole to the Planner; a compact view to the actor.
- Mindcraft ``src/agent/npc/item_goal.js`` (MIT): ItemNode with kinds craft / block+tool / smelt / hunt, a ``prereq``
  (table, furnace or tool), ``isDone()`` from the inventory and a ``fails`` count per node. Taken: the node kinds,
  done from the inventory, a failure memory per node. NOT taken: its code executing the tree (here the model acts).
- ADaPT (arXiv 2311.05772) and XENON's failure-aware memory (arXiv 2505.24157): a failure is localised to a node and
  remembered there. Taken: each node keeps its last two failures (tool, reason) from the outcome reports.
- Plan4MC's graph search (an order computed by code) is not taken: no order is imposed here.

Node kinds (``kind``) and how children join:
- item:    a thing with ``need`` / ``have``; its children are the WAYS to it (OR, all listed): craft, gather, drop,
           spell, trade.
- craft:   one recipe; its children are REQUIREMENTS (AND): each input item (counts for the crafts needed) and the
           station.
- station: the station a recipe names; near, in a base of his (roofed or not), its rule (data/station_rules.json:
           "needs a roof"); when none is near, its build-menu cost as requirement items (wiki build_facts).
- gather:  the resource node (wiki node_facts: found_in, map distance and direction from him; or in sight); its
           requirement child is the tool (a node's own gate when perceived, else the wiki's tool).
- tool:    "pickaxe tier 2+"; done when he carries one that meets it (his best named); its children are the tools of
           that kind and tier that a recipe makes (OR).
- drop:    a creature that drops it (bestiary: amount, rate, power level, where it lives, behaviour such as fleeing).
- spell:   a spell that makes it (spell_mechanics ``makes``): his and castable now, or why not.
- trade:   a trader's recipe: the price against what he carries.
Status per node, from game state only: done, ready (nothing known blocks it now), open (nothing known blocks it, not
at hand: none in sight), blocked (by the named children), cycle (needs something this path is already for).

The open ask's target comes from the game item names in the player's words (the same bookkeeping by game item names
open_ask.names_in does for a parked ask), with the number before the name ("thirty copper ore" -> Copper Ore x30).

Behind DW_JOB_TREE=1 (default off), so it can be A/B'd live. Persisted beside the open ask
(``<state>/worlds/<guid>/job_tree.json``): the target, the failures per node and the last tree built.
"""
from __future__ import annotations

import json
import math
import os
import re
import threading
import time
import functools
import heapq
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

FLAG = "DW_JOB_TREE"
FILE = "job_tree.json"
VERSION = 1
MAX_NODES = 90
MAX_DEPTH = 10
MAX_RECIPES = 3
MAX_DROPS = 3
MAX_TOOL_ALTS = 2
ALT_COST = 3  # an alternative after the first is expanded as if this many levels deeper
FAILS_KEPT = 2
DETAIL_CHARS = 110
CLIP = 150
COMPACT_READY = 5
COMPACT_BLOCKED = 5
COMPACT_LINE = 130
STATUSES = ("done", "ready", "open", "blocked", "cycle")
ABOUT = "from game data; status read from the game now; every way to a thing listed"


def enabled(env: dict | None = None) -> bool:
    return str((env if env is not None else os.environ).get(FLAG, "")).strip() == "1"


def _clip(s: str, n: int = CLIP) -> str:
    s = " ".join(str(s or "").split())
    return s if len(s) <= n else s[: n - 1].rsplit(" ", 1)[0] + "…"


def _tokens(s: str) -> frozenset:
    return frozenset(re.findall(r"[a-z0-9]+", str(s or "").lower()))


# ------------------------------------------------------------------ the game's data, as one object


@dataclass
class GameData:
    """The data the tree is expanded from. ``default()`` reads the repo's files; tests pass small fixtures.
    knowledge: node_facts(name) / build_facts(name) (brain.knowledge.Knowledge); places: brain.places.Places."""
    recipes: dict
    stations: dict
    items: dict  # item id -> {name, category?, tier?}
    knowledge: Any = None
    bestiary: dict = field(default_factory=dict)
    spell_makes: dict = field(default_factory=dict)  # item name (lower) -> [spell id]
    spells: dict = field(default_factory=dict)  # spell id -> effects (name, cost, requirement, unlock)
    station_rules: dict = field(default_factory=dict)
    places: Any = None

    def __post_init__(self) -> None:
        self.by_output: dict[str, list[tuple[str, dict]]] = {}
        self.ids: dict[str, str] = {}
        self.uses: dict[str, int] = {}  # item id -> how many recipes take it
        for rid, r in sorted(self.recipes.items()):
            if not isinstance(r, dict) or r.get("test"):
                continue
            for o in r.get("outputs") or []:
                if isinstance(o, dict) and o.get("item"):
                    self.by_output.setdefault(o["item"], []).append((rid, r))
            for x in (r.get("inputs") or []) + (r.get("outputs") or []):
                if isinstance(x, dict) and x.get("name") and x.get("item"):
                    self.ids.setdefault(str(x["name"]).lower(), x["item"])
            for x in r.get("inputs") or []:
                if isinstance(x, dict) and x.get("item"):
                    self.uses[x["item"]] = self.uses.get(x["item"], 0) + 1
        for iid, e in self.items.items():
            if isinstance(e, dict) and e.get("name"):
                self.ids.setdefault(str(e["name"]).lower(), iid)

    @classmethod
    def default(cls, knowledge=None, places=None) -> "GameData":
        from . import gear_plan, item_stats, needs, plan_sources, spells
        cat = needs.catalog()
        items: dict[str, dict] = {iid: {"name": e.get("name")} for iid, e in (cat.get("items") or {}).items()
                                  if isinstance(e, dict)}
        for iid, e in item_stats.catalog().items():
            if isinstance(e, dict):
                items.setdefault(iid, {}).update({k: e[k] for k in ("name", "category", "tier") if e.get(k) is not None})
        return cls(recipes=cat.get("recipes") or {}, stations=cat.get("stations") or {}, items=items,
                   knowledge=knowledge, bestiary=plan_sources.bestiary(), spell_makes=plan_sources.spell_makes(),
                   spells=spells.effects(), station_rules=gear_plan._station_rules(), places=places)

    def name(self, iid: str) -> str:
        e = self.items.get(iid) or {}
        if e.get("name"):
            return str(e["name"])
        for n, i in self.ids.items():
            if i == iid:
                return n.title()
        return re.sub(r"^ITEM_", "", iid).replace("_", " ")

    def vendor(self, sid: str) -> bool:
        st = self.stations.get(sid) or {}
        return bool(st.get("is_vendor")) or "merchant" in str(sid).lower()

    def station_name(self, sid: str) -> str | None:
        return (self.stations.get(sid) or {}).get("display_name")

    def tool_need(self, tool: str | None) -> tuple[str, int] | None:
        """The wiki's 'Bone pickaxe or better' / 'Stone logging axe (or better)' / 'Any pickaxe' -> (category, tier)."""
        if not tool:
            return None
        t = re.sub(r"\s*\(?\s*or better\s*\)?\s*$", "", tool.strip(), flags=re.I).strip().lower()
        m = re.match(r"any (\w+)$", t)
        if m:
            return m.group(1), 1
        for e in self.items.values():
            if str(e.get("name") or "").lower() == t and e.get("category") and isinstance(e.get("tier"), int):
                return str(e["category"]), int(e["tier"])
        return None


# ------------------------------------------------------------------ reading the game state


def counts(state: dict | None) -> dict[str, int]:
    from .plan_sources import counts as c
    return c(state)


def _carried_tools(state: dict | None, data: GameData) -> list[tuple[int, str, str]]:
    """(tier, name, category) of every tool he carries or holds (bag, hotbar, gear)."""
    ids = set(counts(state))
    gear = (state or {}).get("gear")
    if isinstance(gear, dict):
        ids |= {v for v in gear.values() if isinstance(v, str)}
    out = []
    for i in ids:
        e = data.items.get(i) or {}
        if e.get("category") and isinstance(e.get("tier"), int):
            out.append((int(e["tier"]), str(e.get("name") or i), str(e["category"])))
    return out


def _in_sight(state: dict | None) -> set[str]:
    names: set[str] = set()
    for e in (state or {}).get("nearby_entities") or []:
        if isinstance(e, dict) and e.get("name") and e.get("alive", True):
            names.add(str(e["name"]).lower())
    for r in (state or {}).get("further_off") or []:
        if isinstance(r, dict) and r.get("name") and str(r.get("category")) == "creatures":
            names.add(str(r["name"]).lower())
    return names


def _resource_in_sight(state: dict | None, iid: str) -> dict | None:
    best = None
    for key in ("nearby_resources", "further_off"):
        for r in (state or {}).get(key) or []:
            if isinstance(r, dict) and iid in (r.get("item"), r.get("drop_item")) and (
                    best is None or (r.get("distance") or 1e9) < (best.get("distance") or 1e9)):
                best = r
    return best


def _gate(state: dict | None, iid: str) -> tuple[str, int] | None:
    from .knowledge import node_gates
    g = node_gates(state).get(iid)
    return (g[0].lower(), int(g[1])) if g else None


def _region(state: dict | None, places) -> str | None:
    if places is None or not isinstance(state, dict) or state.get("position") is None:
        return None
    try:
        return places.region_name(state.get("position"))
    except Exception:  # map data is best effort
        return None


def _bases_with(state: dict | None, names: list[str]) -> list[dict]:
    want = {n.lower() for n in names}
    return [b for b in (state or {}).get("my_bases") or [] if isinstance(b, dict)
            and want & {str(s).lower() for s in b.get("stations") or []}]


# ------------------------------------------------------------------ building the tree


def _node(kind: str, nid: str, name: str, **kw) -> dict:
    return {"id": nid, "kind": kind, "name": name, **{k: v for k, v in kw.items() if v is not None}, "children": []}


def _or_status(ways: list[str]) -> str:
    if not ways:
        return "open"
    st = set(ways)
    if "done" in st or "ready" in st:
        return "ready"
    if st <= {"blocked", "cycle"}:
        return "blocked"
    return "open"


def _and_status(reqs: list[str]) -> str:
    return "ready" if all(r == "done" for r in reqs) else "blocked"


class _Builder:
    """Breadth first: the things nearest the target are expanded first, so the node cap cuts the far ends of the tree,
    never a step next to the target. A thing met again elsewhere is a reference to its first expansion."""

    def __init__(self, data: GameData, state: dict | None, spells: list[dict] | None, failures: dict | None):
        self.d, self.state = data, state or {}
        # his spells: the Controller's castable rows, else the state's own spell list (get_state ``spells``)
        self.spells = spells if spells is not None else (
            self.state["spells"] if isinstance(self.state.get("spells"), list) else None)
        self.have = counts(state)
        self.sight = _in_sight(state)
        self.region = _region(state, data.places)
        self.n = 0
        self.expanded: dict[str, dict] = {}
        self.stations_seen: dict[str, dict] = {}
        self._basic: dict[str, bool] = {}
        self.queue: list = []  # heap of (priority, order, node, path)
        self.order = 0
        self.failures = failures or {}
        self.unlocked = (self.state.get("recipes_unlocked") if isinstance(self.state.get("recipes_unlocked"), list)
                         else None)

    def mk(self, kind: str, nid: str, name: str, **kw) -> dict:
        self.n += 1
        n = _node(kind, nid, name, **kw)
        if self.failures.get(nid):
            n["failed"] = list(self.failures[nid])[-FAILS_KEPT:]
        return n

    # ---------------------------------------------------------------- structure (breadth first)

    def basic(self, iid: str) -> bool:
        """A thing the data says is gathered (a wiki node) or dropped (bestiary), not only made."""
        if iid not in self._basic:
            name = self.d.name(iid)
            nf = None
            if self.d.knowledge is not None and hasattr(self.d.knowledge, "node_facts"):
                try:
                    nf = self.d.knowledge.node_facts(name)
                except Exception:  # knowledge is best effort
                    nf = None
            self._basic[iid] = bool(nf) or name in (self.d.bestiary.get("dropped_by") or {})
        return self._basic[iid]

    def item(self, iid: str, need: int, path: frozenset, prio: float = 0) -> dict:
        name = self.d.name(iid)
        have = self.have.get(iid, 0)
        n = self.mk("item", f"item:{iid}", name, item=iid, need=need, have=have)
        if have >= need:
            n["status"] = "done"
        elif iid in path:
            n["status"] = "cycle"
        elif iid in self.expanded:
            n["ref"] = True
        elif self.n >= MAX_NODES or len(path) >= MAX_DEPTH:
            n["cut"], n["status"] = True, "open"
        else:
            self.expanded[iid] = n
            self.order += 1
            heapq.heappush(self.queue, (prio, self.order, n, path | {iid}))
        return n

    def run(self) -> None:
        while self.queue:
            prio, _, n, path = heapq.heappop(self.queue)
            if self.n >= MAX_NODES:
                n["cut"] = True
                continue
            iid, name, rest = n["item"], n["name"], n["need"] - n["have"]
            ways = self.crafts(iid, rest, path, prio) + self.gathers(iid, name, path, prio) + self.drops(name) \
                + self.casts(name) + self.trades(iid)
            n["children"] = [w for w in ways if w]
            if not n["children"]:
                n["none"] = True  # no way to it in the data

    def crafts(self, iid: str, rest: int, path: frozenset, prio: float = 0) -> list[dict]:
        rows = []
        for rid, r in self.d.by_output.get(iid) or []:
            sids = [s for s in r.get("stations") or [] if isinstance(s, str)]
            ins = [i for i in r.get("inputs") or [] if isinstance(i, dict) and i.get("item")]
            if (sids and all(self.d.vendor(s) for s in sids)) or not ins or any(i["item"] == iid for i in ins):
                continue
            locked = self.unlocked is not None and rid not in self.unlocked
            mine = -sum(1 for i in ins if self.have.get(i["item"], 0) > 0)  # recipes from what he carries first
            basic = -sum(1 for i in ins if self.basic(i["item"]))  # then from things gathered or dropped
            rows.append((locked, mine, basic, rid, r, sids, ins))
        rows.sort(key=lambda x: x[:4])
        out = []
        for k, (locked, _, _, rid, r, sids, ins) in enumerate(rows[:MAX_RECIPES]):
            p = prio + 1 + k * ALT_COST
            per = next((int(o.get("count") or 1) for o in r.get("outputs") or [] if o.get("item") == iid), 1)
            times = max(1, math.ceil(rest / max(1, per)))
            c = self.mk("craft", f"craft:{rid}", f"craft {self.d.name(iid)}", recipe=rid, times=times, per=per,
                        makes=per * times if per * times != rest else None, locked=locked or None)
            for i in ins:
                c["children"].append(self.item(i["item"], int(i.get("count") or 1) * times, path, p))
            if sids:
                c["children"].append(self.station(sids, path, p))
            out.append(c)
        if len(rows) > MAX_RECIPES and out:
            out[-1]["more_recipes"] = len(rows) - MAX_RECIPES
        return out

    def station(self, sids: list[str], path: frozenset, prio: float = 0) -> dict:
        names = list(dict.fromkeys(n for n in (self.d.station_name(s) for s in sids) if n))
        name = names[0] if names else re.sub(r"(?<=[a-z])(?=[A-Z])", " ", sids[-1])
        sid = next((s for s in sids if self.d.station_name(s) == name), sids[-1])
        want = {s.lower() for s in sids} | {n.lower() for n in names}
        near = next((r for r in self.state.get("stations_nearby") or [] if isinstance(r, dict) and want & {
            str(r.get("station") or "").lower(), str(r.get("name") or "").lower()}), None)
        rule = (self.d.station_rules.get(name) or {}).get("note")
        s = self.mk("station", f"station:{sid}", name, rule=rule)
        roofed = None
        bases = _bases_with(self.state, [name, *names])
        if bases:
            roofed = any(b.get("covered") for b in bases)
            b = bases[0]
            if isinstance(b.get("distance_m"), (int, float)):
                s["yours_at"] = f"{b['distance_m']:.0f} m {b.get('direction') or ''}".strip() + \
                    (", roofed" if b.get("covered") else ", no roof")
        if near is not None:
            s["near_m"] = round(float(near["distance"])) if isinstance(near.get("distance"), (int, float)) else 0
            if rule and "roof" in rule and roofed is False:
                s["status"], s["blocker"] = "blocked", "no roof over yours"
            else:
                s["status"] = "done"
            return s
        if s.get("yours_at"):
            s["status"] = "done"  # one of his, not in sight: where it is is on the node
            return s
        if sid in self.stations_seen:
            s["ref"] = True  # its build cost as listed at its first place
            return s
        self.stations_seen[sid] = s
        bf = None
        if self.d.knowledge is not None and hasattr(self.d.knowledge, "build_facts"):
            try:
                bf = self.d.knowledge.build_facts(name)
            except Exception:  # knowledge is best effort
                bf = None
        if not bf:
            s["status"] = "open"
            return s
        s["build"] = True
        if bf.get("unlock"):
            s["unlock"] = _clip(bf["unlock"], 110)
        key = f"build:{name}"
        if key in path:
            s["status"] = "cycle"
            return s
        for nm, cnt in bf.get("cost") or []:
            iid = self.d.ids.get(str(nm).lower())
            if iid:
                s["children"].append(self.item(iid, int(cnt), path | {key}, prio + 1))
        return s

    def gathers(self, iid: str, name: str, path: frozenset, prio: float = 0) -> list[dict]:
        nf = None
        if self.d.knowledge is not None and hasattr(self.d.knowledge, "node_facts"):
            try:
                nf = self.d.knowledge.node_facts(name)
            except Exception:  # knowledge is best effort
                nf = None
        if nf and not _node_names(nf.get("title"), name):
            nf = None  # the wiki node of another thing ("Copper Ore Node" for "Copper Salvage Pile")
        seen = _resource_in_sight(self.state, iid)
        if not nf and not seen:
            return []
        g = self.mk("gather", f"gather:{iid}", f"gather {name}", node=(nf or {}).get("title") or (seen or {}).get("name"))
        if nf and nf.get("location"):
            g["found_in"] = nf["location"]
            mp = _map_part(nf["location"], self.state, self.d.places)
            if mp:
                g["map"] = mp
        if seen:
            d = seen.get("distance")
            g["in_sight"] = f"{d:.0f} m" if isinstance(d, (int, float)) else "yes"
        gate = _gate(self.state, iid)
        need = gate or self.d.tool_need((nf or {}).get("tool"))
        if need:
            g["tool_from"] = "the node's own gate, seen" if gate else "wiki"
            g["children"].append(self.tool(need[0], need[1], path, prio + 1))
        return [g]

    def tool(self, cat: str, tier: int, path: frozenset, prio: float = 0) -> dict:
        key = f"tool:{cat}:{tier}"
        mine = sorted((t for t in _carried_tools(self.state, self.d) if t[2] == cat), reverse=True)
        t = self.mk("tool", key, f"{cat} tier {tier}+", best=f"{mine[0][1]} (tier {mine[0][0]})" if mine else "none")
        if mine and mine[0][0] >= tier:
            t["status"] = "done"
            return t
        if key in path:
            t["status"] = "cycle"
            return t
        alts = sorted((int(e["tier"]), str(e.get("name") or i), i) for i, e in self.d.items.items()
                      if e.get("category") == cat and isinstance(e.get("tier"), int) and e["tier"] >= tier
                      and any(not r.get("stations") or not all(self.d.vendor(s) for s in r["stations"])
                              for _, r in self.d.by_output.get(i) or []))
        for k, (_, _, i) in enumerate(alts[:MAX_TOOL_ALTS]):
            t["children"].append(self.item(i, 1, path | {key}, prio + 1 + k * ALT_COST))
        if len(alts) > MAX_TOOL_ALTS:
            t["more_tools"] = [f"{n} (tier {tr})" for tr, n, _ in alts[MAX_TOOL_ALTS:]]
        return t

    def drops(self, name: str) -> list[dict]:
        db = self.d.bestiary.get("dropped_by") or {}
        rec = db.get(name) or next((v for v in db.values() if name.lower() in
                                    {a.lower() for a in [v.get("item") or "", *(v.get("aliases") or [])]}), None)
        rows = []
        for r in (rec or {}).get("rows") or []:
            who = str(r.get("from") or "")
            if not who:
                continue
            cr = _creature(self.d.bestiary, who)
            pl = _pl(cr)
            locs = [x for x in cr.get("locations") or [] if isinstance(x, str)]
            here = 0 if who.lower() in self.sight else 1 if self.region and self.region in locs else 2
            rows.append((here, 0 if str(r.get("rate")) == "always" else 1, pl[0], who, r, cr, pl[1], locs))
        rows.sort(key=lambda x: x[:4])
        out = []
        for here, _, _, who, r, cr, pl_s, locs in rows[:MAX_DROPS]:
            amt = ", ".join(x for x in (str(r.get("amount") or ""), str(r.get("rate") or "")) if x)
            d = self.mk("drop", f"drop:{who}:{name}", who, amount=amt or None, pl=pl_s or None,
                        where="one in sight" if here == 0 else f"lives in {self.region}, your region" if here == 1
                        else (f"lives in {', '.join(locs[:3])}" if locs else None),
                        behaviour=_clip((cr.get("behaviour") or [""])[0], 110) or None,
                        aggressive=str(cr.get("aggressive")).lower() if cr.get("aggressive") else None)
            d["status"] = "ready" if here == 0 else "open"
            out.append(d)
        return out

    def casts(self, name: str) -> list[dict]:
        out = []
        mine = {str(r.get("name") or "").lower(): r for r in self.spells or [] if isinstance(r, dict)}
        for sid in self.d.spell_makes.get(name.lower(), []):
            e = self.d.spells.get(sid) or {}
            sname = e.get("name") or sid
            req = ((e.get("requirement") or {}).get("text") or "").strip()
            cost = " + ".join(f"{n} {r}" for r, n in (e.get("cost") or {}).items())
            s = self.mk("spell", f"spell:{sid}", sname, needs=req or None, runes=cost or None)
            row = mine.get(sname.lower())
            if self.spells is None:
                s["status"] = "open"
            elif row is not None and not row.get("note") and row.get("castable", True) is not False:
                s["status"], s["his"] = "ready", "yours, castable now"
            elif row is not None:
                s["status"], s["his"] = "blocked", f"yours, {row.get('note') or row.get('reason') or 'not castable now'}"
            else:
                u = e.get("unlock") or {}
                s["status"] = "blocked"
                s["his"] = "not among your spells" + (f"; unlocks at {u['skill']} {u['level']}"
                                                      if u.get("skill") and u.get("level") else "")
            out.append(s)
        return out

    def trades(self, iid: str) -> list[dict]:
        out = []
        for rid, r in self.d.by_output.get(iid) or []:
            sids = [s for s in r.get("stations") or [] if isinstance(s, str)]
            if not sids or not all(self.d.vendor(s) for s in sids):
                continue
            who = " or ".join(dict.fromkeys(self.d.station_name(s) or s.replace("_", " ") for s in sids))
            price = [(i["item"], i.get("name") or i["item"], int(i.get("count") or 1))
                     for i in r.get("inputs") or [] if isinstance(i, dict) and i.get("item")]
            t = self.mk("trade", f"trade:{rid}", who, price=" + ".join(f"{n} {nm}" for _, nm, n in price),
                        carry=", ".join(f"{self.have.get(i, 0)} {nm}" for i, nm, _ in price) or None)
            t["status"] = "ready" if all(self.have.get(i, 0) >= n for i, _, n in price) else "blocked"
            out.append(t)
        return out[:1]

    # ---------------------------------------------------------------- status (from the leaves up)

    def status(self, n: dict, busy: set | None = None) -> str:
        if n.get("status"):
            return n["status"]
        busy = busy if busy is not None else set()
        if id(n) in busy:
            return "open"
        busy.add(id(n))
        kids = [self.status(c, busy) for c in n.get("children") or []]
        k = n["kind"]
        if k == "item" and n.get("ref"):
            first = self.expanded.get(n["item"])
            st = self.rescaled(n, first, busy) if first is not None and first is not n else "open"
        elif k == "item" or k == "tool":
            st = _or_status(kids)
        elif k == "craft":
            st = "blocked" if n.get("locked") else _and_status(kids)
        elif k == "station" and n.get("ref"):
            first = self.stations_seen.get(n["id"].split(":", 1)[1])
            st = self.status(first, busy) if first is not None and first is not n else "open"
        elif k == "station":
            st = _and_status(kids) if n.get("build") else "open"
        elif k == "gather":
            st = "blocked" if n["children"] and kids[0] != "done" else "ready" if n.get("in_sight") else "open"
        else:
            st = "open"
        busy.discard(id(n))
        n["status"] = st
        return st

    def rescaled(self, n: dict, first: dict, busy: set) -> str:
        """A thing met again with its own count: the ways of its first place, the recipes' inputs scaled to this
        count (2 Coarse Thread for the Tannery is 6 fur, though the first place needed 8 thread). A craft way that is
        ready at this count is kept on the node as ``ready_by``."""
        self.status(first, busy)
        rest = n["need"] - n["have"]
        sts = []
        for w in first.get("children") or []:
            if w["kind"] != "craft" or w.get("locked"):
                sts.append(self.status(w, busy))  # read through status: a way of an ancestor still being walked has none yet
                continue
            times = max(1, math.ceil(rest / max(1, int(w.get("per") or 1))))
            ok = all((c["have"] >= c["need"] // max(1, w["times"]) * times) if c["kind"] == "item"
                     else self.status(c, busy) == "done" for c in w.get("children") or [])
            if ok and "ready_by" not in n:
                st = next((c for c in w.get("children") or [] if c["kind"] == "station"), None)
                at = "" if st is None else f" at {st['name']} " + (
                    "(near)" if "near_m" in st else f"(yours {st.get('yours_at')})")
                n["ready_by"] = w["name"] + (f" x{times}" if times > 1 else "") + at
            sts.append("ready" if ok else "blocked")
        return "ready" if "ready" in sts else _or_status(sts) if sts else "open"


_NODE_WORDS = frozenset({"ore", "logs", "log", "node", "tree", "rock", "rocks", "plant", "bush", "deposit", "raw"})


def _node_names(title: str | None, item: str) -> bool:
    """Does a wiki node title name this item ("Copper Ore Node" names Copper Ore, "Ash Tree" Ash Logs, "Flax (plant)"
    Flax; not Copper Salvage Pile)?"""
    return bool(title) and (_tokens(item) - _NODE_WORDS) <= _tokens(title)


def _creature(best: dict, name: str) -> dict:
    c = best.get("creatures") or {}
    return c.get(name) or next((v for k, v in c.items() if k.lower() == name.lower()), {})


def _pl(cr: dict) -> tuple[float, str]:
    pls = sorted({int(p) for v in cr.get("variants") or [] if isinstance(v, dict)
                  for p in re.findall(r"\d+", str(v.get("power_level", "")))})
    if not pls:
        return 99.0, ""
    return float(pls[0]), (f"PL {pls[0]}" if len(pls) == 1 else f"PL {pls[0]}-{pls[-1]}")


def _map_part(location: str, state: dict | None, places) -> str | None:
    if places is None or not isinstance(state, dict) or state.get("position") is None:
        return None
    try:
        from .result_knowledge import _map_part as mp
        return mp(location, state.get("position"), places)
    except Exception:  # map data is best effort
        return None


def build(data: GameData, targets: list[dict], state: dict | None, spells: list[dict] | None = None,
          failures: dict | None = None) -> dict:
    """The tree for ``targets`` ([{item, count}]) from ``data``, each node's status read from ``state`` (and the
    castable ``spells`` rows; None: not known), each node's kept ``failures`` ({node id: [rows]}) attached."""
    b = _Builder(data, state, spells, failures)
    roots = [b.item(t["item"], int(t.get("count") or 1), frozenset()) for t in targets if t.get("item")]
    b.run()
    for r in roots:
        b.status(r)
    return {"roots": roots, "nodes": b.n, "capped": b.n >= MAX_NODES}


def walk(node: dict, depth: int = 0, parent: dict | None = None):
    yield node, depth, parent
    for c in node.get("children") or []:
        yield from walk(c, depth + 1, node)


# ------------------------------------------------------------------ the target from the ask's words

_UNITS = {w: i for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve thirteen "
                                     "fourteen fifteen sixteen seventeen eighteen nineteen".split())}
_TENS = {w: 10 * i for i, w in enumerate("_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()) if i >= 2}


def _number(words: list[str]) -> int | None:
    """The count in the words just before a name: '30', 'thirty', 'twenty five', 'a hundred', 'a dozen'."""
    w = [x for x in words if x not in ("and",)]
    if not w:
        return None
    if w[-1].isdigit():
        return int(w[-1])
    if w[-1] == "dozen":
        return 12
    if w[-1] == "hundred":
        return 100
    if w[-1] in _UNITS:
        if len(w) >= 2 and w[-2] in _TENS:
            return _TENS[w[-2]] + _UNITS[w[-1]]
        return _UNITS[w[-1]]
    if w[-1] in _TENS:
        return _TENS[w[-1]]
    return None


def targets_from_words(words: str, data: GameData) -> list[dict]:
    """[{item, name, count}] for the game item names in the player's words (a name inside a longer named one is not
    its own), the number right before each name as its count (1 when none)."""
    from .open_ask import names_in
    names = sorted({e.get("name") for e in data.items.values() if isinstance(e, dict) and e.get("name")
                    and len(str(e["name"])) >= 3}, key=len)
    found = names_in(words, names)
    found = {n for n in found if not any(n != m and _tokens(n) < _tokens(m) for m in found)}
    toks = re.findall(r"[a-z0-9]+", str(words or "").lower().replace("-", " "))
    out = []
    for n in sorted(found, key=lambda n: " ".join(toks).find(" ".join(re.findall(r"[a-z0-9]+", n.lower())))):
        nt = re.findall(r"[a-z0-9]+", n.lower())
        at = next((i for i in range(len(toks) - len(nt) + 1) if toks[i:i + len(nt)] == nt), None)
        before = toks[max(0, (at or 0) - 2):at or 0]
        iid = data.ids.get(n.lower())
        if iid:
            out.append({"item": iid, "name": n, "count": _number(before) or 1})
    return out


# ------------------------------------------------------------------ what is shown


def _label(n: dict) -> str:
    k = n["kind"]
    if k == "item":
        return f"{n['name']} {n['have']}/{n['need']}"
    if k == "craft":
        return n["name"] + (f" x{n['times']}" if n.get("times", 1) > 1 else "")
    if k == "station":
        return ("build " if n.get("build") else "") + n["name"]
    if k == "tool":
        return f"{n['name']} (you carry: {n.get('best')})"
    if k == "drop":
        return f"{n['name']} drops it"
    if k == "spell":
        return f"cast {n['name']}"
    if k == "trade":
        return f"trader {n['name']}"
    return n["name"]


def _facts(n: dict) -> list[str]:
    k, out = n["kind"], []
    if k == "craft" and n.get("locked"):
        out.append("recipe not unlocked yet")
    if k == "craft" and n.get("makes"):
        out.append(f"makes {n['makes']}")
    if k == "craft":
        st = next((c for c in n.get("children") or [] if c["kind"] == "station"), None)
        if st is not None and st["status"] == "done":
            out.append(f"at {st['name']} " + ("(near)" if "near_m" in st else f"(yours {st.get('yours_at')})"))
    if k == "station":
        if "near_m" in n:
            out.append(f"one {n['near_m']} m from you")
        if n.get("yours_at"):
            out.append(f"yours {n['yours_at']}")
        if n.get("ref"):
            out.append("none near; its build cost as listed above")
        elif not n.get("build") and "near_m" not in n and not n.get("yours_at"):
            out.append("none near; no build recipe in the data")
        if n.get("rule"):
            out.append(n["rule"])
        if n.get("blocker"):
            out.append(n["blocker"])
        if n.get("unlock"):
            out.append(f"wiki: {n['unlock']}")
    if k == "gather":
        for key in ("node", "in_sight", "found_in", "map"):
            if n.get(key):
                out.append({"node": "{}", "in_sight": "one in sight {}", "found_in": "wiki: found in {}",
                            "map": "{}"}[key].format(n[key]))
    if k == "tool" and n.get("more_tools"):
        out.append("also: " + ", ".join(n["more_tools"][:3]))
    if k == "drop":
        out += [x for x in (n.get("amount"), n.get("pl"), n.get("where"),
                            n.get("aggressive") == "no" and "not aggressive", n.get("behaviour")) if x]
    if k == "spell":
        out += [x for x in (n.get("needs"), n.get("runes") and f"{n['runes']} runes", n.get("his")) if x]
    if k == "trade":
        out += [x for x in (n.get("price") and f"price {n['price']}", n.get("carry") and f"you carry {n['carry']}") if x]
    if k == "item" and n.get("ref"):
        out.append("its ways as listed above")
    if k == "item" and n.get("none"):
        out.append("no way to it in the data")
    if n.get("status") == "cycle":
        out.append("needs what this path is already for")
    return out


def _fail_text(f: dict, now: float | None) -> str:
    age = f" {_ago(f.get('t'), now)}" if now is not None and f.get("t") else ""
    return _clip(f"{f.get('tool')} {f.get('reason') or 'failed'}{age}" + (f": {f['detail']}" if f.get("detail") else ""),
                 DETAIL_CHARS + 40)


def _ago(t: float | None, now: float | None) -> str:
    if t is None or now is None:
        return ""
    s = max(0, round(now - t))
    return f"({s} s ago)" if s < 120 else f"({round(s / 60)} min ago)"


def _line(n: dict, now: float | None = None, with_fails: bool = True) -> str:
    bits = _facts(n)
    s = _label(n) + f" [{n['status']}]" + (f": {'; '.join(bits)}" if bits else "")
    if with_fails and n.get("failed"):
        s += " | failed: " + " / ".join(_fail_text(f, now) for f in n["failed"])
    return s


def full_text(tree: dict, now: float | None = None) -> str:
    """The whole tree, one node a line, indented; a way to a thing is marked 'or:' (alternatives side by side), a
    requirement is not (all of them)."""
    lines = []
    for root in tree.get("roots") or []:
        for n, depth, parent in walk(root):
            mark = "or: " if parent is not None and parent["kind"] in ("item", "tool") else ""
            lines.append("  " * depth + mark + _line(n, now))
    return "\n".join(lines)


def _for(n: dict, parent: dict | None) -> str:
    return f" (for {parent['name']} {parent['have']}/{parent['need']})" if parent and parent["kind"] == "item" else ""


def compact(tree: dict, now: float | None = None) -> dict:
    """The Controller's view: the target, the nodes nothing blocks now (ready, then open), the blocked steps with what
    blocks each (nearest the target first), and the failures kept on any node. Data only."""
    roots = tree.get("roots") or []
    out: dict[str, Any] = {"about": ABOUT, "target": [f"{r['name']}: you carry {r['have']} of {r['need']} [{r['status']}]"
                                                      for r in roots]}
    acts = ("craft", "gather", "drop", "spell", "trade", "station")
    seen, ready, open_, blocked, fails = set(), [], [], [], []
    for root in roots:
        for n, depth, parent in walk(root):
            if n.get("failed"):
                fails.append(f"{_label(n)}: " + " / ".join(_fail_text(f, now) for f in n["failed"]))
            if n["kind"] == "item" and n.get("ready_by") and n["id"] not in seen:
                seen.add(n["id"])
                ready.append((depth, f"{n['ready_by']} (for {n['name']} {n['have']}/{n['need']})"))
            if n["kind"] not in acts or n["id"] in seen:
                continue
            if n["kind"] == "station" and n["status"] == "done":
                continue
            seen.add(n["id"])
            bits = _facts(n)
            text = _label(n) + _for(n, parent) + (f": {'; '.join(bits)}" if bits else "")
            if n["status"] == "ready":
                ready.append((depth, text))
            elif n["status"] == "open":
                open_.append((depth, text))
            elif n["status"] == "blocked":
                by = [c for c in n.get("children") or [] if c["status"] != "done"]
                why = ", ".join(_label(c) + ("" if c["status"] == "blocked" else f" [{c['status']}]") for c in by[:4]) \
                    or "; ".join(x for x in (n.get("blocker"), n.get("his"), n.get("locked") and "recipe not unlocked",
                                             n.get("carry") and f"you carry {n['carry']}") if x)
                if n["kind"] == "trade":
                    continue  # a trader he can't pay: in the Planner's whole tree
                blocked.append((depth, _clip(_label(n) + _for(n, parent) + f" <- needs {why}", COMPACT_LINE + 30)))
    # nearest the target first (a stable sort keeps the tree's own order within a depth)
    out["nothing_blocks_now"] = [_clip(t, COMPACT_LINE) for _, t in sorted(ready, key=lambda x: x[0])][:COMPACT_READY]
    if not out["nothing_blocks_now"] and open_:
        out["not_at_hand"] = [_clip(t, COMPACT_LINE) for _, t in sorted(open_, key=lambda x: x[0])][:2]
    out["blocked"] = [t for _, t in sorted(blocked, key=lambda x: x[0])][:COMPACT_BLOCKED]
    if loops := needs_itself(tree):
        out["needs_the_target_itself"] = loops
    if fails:
        out["failed_lately"] = fails[:3]
    return {k: v for k, v in out.items() if v}


def needs_itself(tree: dict, limit: int = 2) -> list[str]:
    """The ways that need the target itself, as their chain of things: 'Bronze Pickaxe <- Bronze Bar <- Copper Ore 0/9'
    (a cycle node of a root's own item). Data: the game's recipes say so."""
    out: list[str] = []
    for root in tree.get("roots") or []:
        stack = [(root, [])]
        while stack and len(out) < limit:
            n, chain = stack.pop()
            names = chain + ([_label(n)] if n["kind"] == "item" and n is not root else [])
            if n["kind"] == "item" and n.get("status") == "cycle" and n.get("item") == root.get("item"):
                line = " <- ".join(names)
                if line not in out:
                    out.append(_clip(line, COMPACT_LINE))
                continue
            stack.extend((c, names) for c in reversed(n.get("children") or []))
    return out


def size(obj: Any) -> int:
    """Characters as sent (JSON for a dict, the text for a string)."""
    return len(obj) if isinstance(obj, str) else len(json.dumps(obj, ensure_ascii=False))


# ------------------------------------------------------------------ failures from outcome reports

TOOL_KINDS = {"gather": ("gather",), "craft": ("craft", "item"), "attack": ("drop",), "cast": ("spell",),
              "build": ("station",), "place": ("station",), "explore": ("gather", "drop"), "trade": ("trade",),
              "buy": ("trade",)}
ARG_KEYS = ("resource", "item", "spell", "target", "piece", "name", "about", "output")


def nodes_for(tree: dict, tool: str, args: dict | None) -> list[str]:
    """The node ids an outcome of ``tool`` with ``args`` is about: nodes of the kinds that tool acts on whose name
    (the item, creature, spell or station) and an argument name each other (bookkeeping by game names)."""
    kinds = TOOL_KINDS.get(tool)
    if not kinds:
        return []
    vals = [_tokens(v) for k, v in (args or {}).items() if k in ARG_KEYS and isinstance(v, str) and v.strip()]
    vals = [v for v in vals if v]
    out: list[str] = []
    for root in tree.get("roots") or []:
        for n, _, parent in walk(root):
            if n["kind"] not in kinds or n["id"] in out:
                continue
            names = {n["name"]}
            if n["kind"] in ("craft", "gather"):
                names.add(re.sub(r"^(craft|gather) ", "", n["name"]))
            if n["kind"] in ("drop", "spell") and parent is not None:
                names.add(n["name"])
            nt = [_tokens(x) for x in names]
            if any(v and t and (v <= t or t <= v) for v in vals for t in nt):
                out.append(n["id"])
    if tool == "craft":
        out = [i for i in out if i.startswith("craft:")] or out
    return out


# ------------------------------------------------------------------ one job, kept with the open ask


def path(world_dir: Path) -> Path:
    return Path(world_dir) / FILE


def _loop_only(refused):
    """A Keeper method that runs only on the thread that owns it (the agent loop's). The Keeper has no lock: its
    failures, last tree and lazily loaded game data (the knowledge index's sqlite) are the loop's. A background plan
    (DW_ASYNC_PLAN=1, agent._plan_in_background) gets the tree as text the loop built before submit, in a deep copy
    of the Planner's notes; a call from any other thread is refused (``refused`` returned, a job_tree_error row with
    where=off_thread) and never touches the Keeper."""
    def wrap(fn):
        @functools.wraps(fn)
        def guarded(self, *args, **kwargs):
            if self.owner is not None and threading.get_ident() != self.owner:
                self._log("job_tree_error", where="off_thread", method=fn.__name__,
                          error=f"Keeper.{fn.__name__} called from thread {threading.current_thread().name}, "
                                f"not the loop's; refused")
                return list(refused) if isinstance(refused, list) else refused
            return fn(self, *args, **kwargs)
        return guarded
    return wrap


class Keeper:
    """The job tree of the open ask: its target (from the player's words), the failures per node from the body's
    reports, the last tree built; on disk beside open_ask.json when a world folder is attached. Owned by the thread
    that made it (the agent loop's, ``owner``): not thread-safe, so every method that reads or changes it refuses
    another thread (_loop_only)."""

    def __init__(self, data_fn: Callable[[], GameData], log=None, wall: Callable[[], float] = time.time):
        self._data_fn, self._data = data_fn, None
        self.log, self.wall = log, wall
        self.ask: tuple | None = None
        self.targets: list[dict] = []
        self.failures: dict[str, list[dict]] = {}
        self.last: dict | None = None
        self.dir: Path | None = None
        self.owner: int | None = threading.get_ident()  # None: any thread (a tool run outside the agent)

    def data(self) -> GameData:
        if self._data is None:
            self._data = self._data_fn()
        return self._data

    def _log(self, kind: str, **kw) -> None:
        if self.log is not None:
            self.log.log(kind, **kw)

    @_loop_only([])
    def open(self, ask: tuple) -> list[dict]:
        """A new ask: its target from the game item names in its words; the failures of the ask before are dropped."""
        self.ask, self.failures, self.last = (ask[0], ask[1]), {}, None
        try:
            self.targets = targets_from_words(str(ask[1] or ""), self.data())
        except Exception as exc:  # data is best effort: no tree, the ask stands
            self.targets = []
            self._log("job_tree_error", where="target", error=repr(exc)[:200])
        self._log("job_tree_target", request=ask[1], targets=[f"{t['name']} x{t['count']}" for t in self.targets])
        self.save()
        return self.targets

    @_loop_only(None)
    def close(self) -> None:
        self.ask, self.targets, self.failures, self.last = None, [], {}, None
        if self.dir is not None:
            try:
                path(self.dir).unlink()
            except FileNotFoundError:
                pass
            except OSError as exc:
                self._log("job_tree_error", where="close", error=repr(exc)[:200])

    def active(self, ask: tuple | None) -> bool:
        from .open_ask import same_ask
        return bool(self.targets) and same_ask(ask, self.ask)

    @_loop_only(None)
    def tree(self, state: dict | None, spells: list[dict] | None = None) -> dict | None:
        if not self.targets:
            return None
        try:
            self.last = build(self.data(), self.targets, state, spells, self.failures)
        except Exception as exc:  # data is best effort: the last tree stands
            self._log("job_tree_error", where="build", error=repr(exc)[:200])
        return self.last

    @_loop_only(None)
    def compact_view(self, state: dict | None, spells: list[dict] | None = None, where: str | None = None) -> dict | None:
        t = self.tree(state, spells)
        if not t:
            return None
        v = compact(t, self.wall())
        if where:
            self._log("job_tree_shown", where=where, view="compact", nodes=t["nodes"], chars=size(v),
                      ready=len(v.get("nothing_blocks_now") or []), blocked=len(v.get("blocked") or []))
        return v

    @_loop_only(None)
    def full_view(self, state: dict | None, spells: list[dict] | None = None, where: str | None = None) -> str | None:
        t = self.tree(state, spells)
        if not t:
            return None
        text = full_text(t, self.wall())
        if where:
            self._log("job_tree_shown", where=where, view="full", nodes=t["nodes"], chars=len(text))
        return text

    @_loop_only([])
    def record(self, tool: str, args: dict | None, ok: bool, reason: str | None, detail: str | None,
               state: dict | None = None, spells: list[dict] | None = None) -> list[str]:
        """An outcome report: a failure is kept on the nodes it is about (the last FAILS_KEPT each). The ids hit."""
        if ok or not self.targets:
            return []
        t = self.last or self.tree(state, spells)
        ids = nodes_for(t or {}, tool, args)
        row = {"tool": tool, "reason": reason, "detail": _clip(detail, DETAIL_CHARS) if detail else None,
               "t": round(self.wall(), 1)}
        for i in ids:
            self.failures[i] = [*self.failures.get(i, []), row][-FAILS_KEPT:]
        if ids:
            self._log("job_tree_failure", tool=tool, reason=reason, nodes=ids)
            self.save()
        return ids

    # on disk
    @_loop_only(False)
    def attach(self, directory: Path, ask: tuple | None) -> bool:
        """Keep the job in ``directory`` from now on; bring back the one kept there when it is for ``ask``."""
        from .fileio import read_json
        from .open_ask import same_ask
        self.dir = Path(directory)
        rec = read_json(path(self.dir), None)
        if not isinstance(rec, dict) or not ask or not same_ask(tuple(rec.get("ask") or ()) or None, ask):
            return False
        self.ask = tuple(rec["ask"])
        self.targets = [t for t in rec.get("targets") or [] if isinstance(t, dict) and t.get("item")]
        self.failures = {k: list(v)[-FAILS_KEPT:] for k, v in (rec.get("failures") or {}).items() if isinstance(v, list)}
        self.last = rec.get("tree") if isinstance(rec.get("tree"), dict) else None
        self._log("job_tree_restored", request=self.ask[1], targets=len(self.targets), failures=len(self.failures))
        return True

    def save(self) -> None:
        if self.dir is None or not self.ask:
            return
        from .fileio import atomic_write
        try:
            self.dir.mkdir(parents=True, exist_ok=True)
            atomic_write(path(self.dir), json.dumps({"v": VERSION, "ask": list(self.ask), "targets": self.targets,
                                                     "failures": self.failures, "tree": self.last,
                                                     "saved_unix": round(self.wall(), 1)},
                                                    ensure_ascii=False, default=str))
        except (OSError, TypeError, ValueError) as exc:  # memory is best effort
            self._log("job_tree_error", where="save", error=repr(exc)[:200])


def _main(argv: list[str] | None = None) -> int:
    """python -m brain.job_tree "<words>" [--state STATE.json]: the tree for an ask's words over the repo's data."""
    import argparse
    ap = argparse.ArgumentParser(prog="python -m brain.job_tree")
    ap.add_argument("words")
    ap.add_argument("--state", default=None)
    ap.add_argument("--full", action="store_true")
    a = ap.parse_args(argv)
    from .knowledge import open_knowledge
    data = GameData.default(knowledge=open_knowledge())
    state = json.loads(Path(a.state).read_text(encoding="utf-8")) if a.state else {}
    tg = targets_from_words(a.words, data)
    t = build(data, tg, state)
    print(json.dumps(tg))
    print(full_text(t) if a.full else json.dumps(compact(t), indent=1, ensure_ascii=False))
    print(f"nodes {t['nodes']}, full {len(full_text(t))} chars, compact {size(compact(t))} chars")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())

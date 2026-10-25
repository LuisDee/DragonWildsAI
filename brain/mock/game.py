"""A small deterministic simulation of Dragonwilds implementing GameInterface.

Actions are synchronous: each one advances the simulated clock by the time it
would take (walking, harvesting, fighting). Failures can be scripted per tool
with ``script_failure`` to exercise the brain's retry/replan/ask-for-help paths.
"""
from __future__ import annotations

import functools
import inspect
import math
from collections import Counter
from dataclasses import dataclass, field

from ..interface import (
    ActionResult,
    Attacked,
    CommandReceived,
    Coords,
    Event,
    GameInterface,
    GatherProgress,
    Reason,
    fail,
    ok,
)
from ..situation import tokens

SPEED = 5.0  # metres per simulated second
HARVEST_TIME = 2.0  # seconds per unit gathered
GATHER_RANGE = 25.0  # how far gather() will look for nodes
NEARBY_RANGE = 60.0  # what get_state() reports
REACH = 4.0  # give / melee range
ARRIVE = 2.0  # go_to arrival tolerance
COMPANION_DAMAGE = 10

# item -> inputs per batch and how many items one batch yields
RECIPES: dict[str, dict] = {
    "plank": {"inputs": {"log": 1}, "yield": 2},
    "stone_axe": {"inputs": {"log": 1, "stone": 2}, "yield": 1},
    "campfire": {"inputs": {"log": 3, "stone": 2}, "yield": 1},
}

BLUEPRINTS: dict[str, dict[str, int]] = {
    "storage_hut": {"log": 10, "stone": 4},
    "campfire_ring": {"stone": 5},
}

# A few spells, shaped like the body's compact spell rows (body/spells.lua list({compact=true})).
SPELLS: dict[str, dict] = {
    "USD_TempestShield": {"name": "Tempest Shield", "role": "combat_defence", "cooldown_s": 45.0, "self": True,
                          "aliases": ["shield", "tempest"],
                          "use_when": "Block all damage for about a minute; cast before a big hit lands or when HP is low."},
    "USD_Windstep": {"name": "Windstep", "role": "combat_cc", "cooldown_s": 3.0, "aoe_m": 7.0,
                     "aliases": ["wind stomp", "stomp"],
                     "use_when": "Wind Stomp: a 7 m AoE stagger at the landing point; use on groups (great vs Kalphites)."},
    "USD_EnchantWeapon_Fire": {"name": "Enchant Weapon: Fire", "role": "weapon_buff", "cooldown_s": 300.0, "self": True,
                               "aliases": ["fire enchant"], "use_when": "Adds Fire to melee hits; use against Fire-weak enemies."},
}
SAFE_PLAYER_M = 10.5  # an area spell never lands this close to a player (body/spells.lua)
MAX_RULES_PER_ENEMY = 8


def _norm(name: str) -> str:
    return "".join(ch for ch in name.lower() if ch.isalnum()).removeprefix("usd")


def _scriptable(action):
    """Record the call, and if a scripted failure rule fires, apply it instead of acting."""
    sig = inspect.signature(action)

    @functools.wraps(action)
    def wrapper(self: "MockGame", *args, **kwargs) -> ActionResult:
        bound = sig.bind(self, *args, **kwargs)
        bound.apply_defaults()
        call_args = dict(bound.arguments)
        del call_args["self"]
        if rule := self._begin(action.__name__, **call_args):
            return self._apply_rule(rule)
        return action(self, *args, **kwargs)

    return wrapper


@dataclass
class Entity:
    id: str
    kind: str
    pos: list[float]
    hp: int
    hostile: bool = False
    damage: int = 0
    alive: bool = True


@dataclass
class ResourceNode:
    id: str
    resource: str
    pos: list[float]
    remaining: int


@dataclass
class Player:
    name: str
    pos: list[float]
    inventory: Counter = field(default_factory=Counter)


@dataclass
class GroundItem:
    id: str
    item: str
    count: int
    pos: list[float]


@dataclass
class Gatherable:
    """A ground gatherable (sticks, stones, plants). Like the real game's foliage, it is NOT in
    get_state: only look() reveals it, and interact() collects it into the inventory."""
    id: str
    name: str
    gives: str  # inventory item id
    pos: list[float]
    count: int = 1
    prompt: str = "Gather"


@dataclass
class FailureRule:
    tool: str
    reason: str
    times: int | None = 1  # None = every call
    text: str = "stop"  # command text for "interrupted"


class MockGame(GameInterface):
    def __init__(self) -> None:
        self.time = 0.0
        self.pos: list[float] = [0.0, 0.0, 0.0]
        self.health = 100
        self.max_health = 100
        self.inventory: Counter = Counter()
        self.following: str | None = None
        self.follow_distance = 3.0
        self.places: dict[str, list[float]] = {}
        self.players: dict[str, Player] = {}
        self.entities: dict[str, Entity] = {}
        self.nodes: dict[str, ResourceNode] = {}
        self.structures: list[dict] = []
        self.ground: dict[str, GroundItem] = {}  # items lying in the world (pickup / drop)
        self.chat: list[tuple[str, str]] = []  # (speaker, text)
        self.chat_times: list[float] = []  # simulated time of each companion line
        self.calls: list[tuple[str, dict]] = []  # every tool call, for test assertions
        self._rules: list[FailureRule] = []
        self._events: list[Event] = []
        self._ids = Counter()
        # spells: what Luis has unlocked (the bot mirrors him), per-spell ready time, casts made
        self.unlocked: set[str] = {"USD_TempestShield", "USD_Windstep"}
        self.spell_ready_at: dict[str, float] = {}
        self.casts: list[dict] = []
        # reflex rules per enemy kind, like body/rules.lua: {enemy: [rule]}
        self.reflex_rules: dict[str, list[dict]] = {}
        self._rule_ids = 0
        self.sleeping = False
        self.beds: dict[str, list[float]] = {}  # bed id -> position (free beds only)
        self.gatherables: dict[str, Gatherable] = {}
        self.world_guid: str | None = None  # world_info() answers not_implemented while None
        self._progress_listener = None

    # ------------------------------------------------------------------ world setup

    @classmethod
    def default_world(cls) -> "MockGame":
        g = cls()
        g.places = {"camp": [0.0, 0.0, 0.0], "lake": [40.0, 30.0, 0.0], "quarry": [-60.0, 0.0, 0.0]}
        g.players["Luis"] = Player("Luis", [2.0, 0.0, 0.0])
        for pos in ([10, 5, 0], [12, -6, 0], [-8, 9, 0]):
            g.add_node("log", pos, 5)
        g.add_node("stone", [6, -10, 0], 4)
        g.add_node("stone", [-60, 3, 0], 20)  # the quarry
        g.add_entity("wolf", [80, 80, 0], hp=30, hostile=True, damage=8)
        return g

    def _new_id(self, kind: str) -> str:
        self._ids[kind] += 1
        return f"{kind}_{self._ids[kind]}"

    def add_node(self, resource: str, pos, remaining: int) -> str:
        kind = {"log": "tree", "stone": "rock"}.get(resource, resource)
        nid = self._new_id(kind)
        self.nodes[nid] = ResourceNode(nid, resource, [float(c) for c in pos], remaining)
        return nid

    def add_entity(self, kind: str, pos, hp: int, hostile=False, damage=0) -> str:
        eid = self._new_id(kind)
        self.entities[eid] = Entity(eid, kind, [float(c) for c in pos], hp, hostile, damage)
        return eid

    def add_ground_item(self, item: str, count: int, pos) -> str:
        gid = self._new_id("world_item")
        self.ground[gid] = GroundItem(gid, item, count, [float(c) for c in pos])
        return gid

    def add_gatherable(self, name: str, gives: str, pos, count: int = 1) -> str:
        gid = self._new_id("gatherable")
        self.gatherables[gid] = Gatherable(gid, name, gives, [float(c) for c in pos], count)
        return gid

    def remove_nodes(self, resource: str, within: float | None = None) -> None:
        """Delete resource nodes (optionally only those within ``within`` of the companion)."""
        for nid, n in list(self.nodes.items()):
            if n.resource == resource and (within is None or math.dist(n.pos, self.pos) <= within):
                del self.nodes[nid]

    # ------------------------------------------------------------------ scripting

    def script_failure(self, tool: str, reason: str, times: int | None = 1, text: str = "stop") -> None:
        """Make the next ``times`` calls to ``tool`` fail with ``reason`` (None = always).

        Special reasons: ``interrupted`` (also emits command_received with ``text``),
        ``attacked`` (spawns a wolf beside the companion, emits attacked, and does
        partial work for gather), ``lie`` (reports success without doing anything).
        """
        self._rules.append(FailureRule(tool, reason, times, text))

    def player_say(self, text: str, player: str = "Luis") -> None:
        self.chat.append((player, text))
        self._events.append(CommandReceived(player=player, text=text))

    def move_player(self, name: str, pos) -> None:
        self.players[name].pos = [float(c) for c in pos]

    def _take_rule(self, tool: str) -> FailureRule | None:
        for rule in self._rules:
            if rule.tool == tool and (rule.times is None or rule.times > 0):
                if rule.times is not None:
                    rule.times -= 1
                return rule
        return None

    def _spawn_attacker(self) -> str:
        eid = self.add_entity("wolf", [self.pos[0] + 2, self.pos[1], self.pos[2]], hp=30, hostile=True, damage=8)
        self._events.append(Attacked(by=eid))
        self.health -= 8
        return eid

    def _apply_rule(self, rule: FailureRule) -> ActionResult:
        """Turn a triggered rule into the action's result (gather handles "attacked" itself)."""
        if rule.reason == "interrupted":
            self.player_say(rule.text)
            return fail(Reason.INTERRUPTED, by="Luis")
        if rule.reason == "attacked":
            return fail(Reason.ATTACKED, by=self._spawn_attacker())
        if rule.reason == "lie":
            return ok(note="mock lied: nothing happened")
        return fail(rule.reason)

    # ------------------------------------------------------------------ time

    def _advance(self, seconds: float) -> None:
        self.time += seconds
        if self.following and self.following in self.players:
            target = self.players[self.following].pos
            if math.dist(self.pos, target) > self.follow_distance:
                self._step_towards(target, self.follow_distance)

    def tick(self, seconds: float = 1.0) -> None:
        self._advance(seconds)

    def _step_towards(self, target: Coords, stop_at: float = 0.0) -> None:
        d = math.dist(self.pos, target)
        if d <= stop_at:
            return
        frac = (d - stop_at) / d
        self.pos = [p + (t - p) * frac for p, t in zip(self.pos, target)]

    def _walk(self, target: Coords, stop_at: float = 0.0) -> None:
        d = max(0.0, math.dist(self.pos, target) - stop_at)
        self._step_towards(target, stop_at)
        self.time += d / SPEED

    def _resolve(self, target: str | Coords) -> list[float] | None:
        if isinstance(target, list):
            return [float(c) for c in target]
        if target in self.places:
            return self.places[target]
        if target in self.players:
            return self.players[target].pos
        if target in self.entities and self.entities[target].alive:
            return self.entities[target].pos
        if target in self.nodes:
            return self.nodes[target].pos
        return None

    # ------------------------------------------------------------------ GameInterface

    def _begin(self, tool: str, **args) -> FailureRule | None:
        """Log the call for test assertions and return the scripted failure rule it triggers, if any."""
        self.calls.append((tool, args))
        return self._take_rule(tool)

    def get_state(self) -> ActionResult:
        def near(p):
            return math.dist(p, self.pos) <= NEARBY_RANGE

        return ok(
            time=self.time,
            position=list(self.pos),
            health=self.health,
            max_health=self.max_health,
            inventory=dict(+self.inventory),
            following=self.following,
            players=[
                {"name": p.name, "position": p.pos, "distance": round(math.dist(p.pos, self.pos), 1)}
                for p in self.players.values()
            ],
            nearby_entities=[
                {"id": e.id, "kind": e.kind, "position": e.pos, "hp": e.hp, "hostile": e.hostile,
                 "alive": e.alive, "distance": round(math.dist(e.pos, self.pos), 1)}
                for e in self.entities.values() if near(e.pos)
            ],
            nearby_resources=[
                {"id": n.id, "resource": n.resource, "position": n.pos, "remaining": n.remaining,
                 "distance": round(math.dist(n.pos, self.pos), 1)}
                for n in self.nodes.values() if n.remaining > 0 and near(n.pos)
            ],
            nearby_items=[
                {"id": g.id, "item": g.item, "count": g.count, "position": g.pos,
                 "distance": round(math.dist(g.pos, self.pos), 1)}
                for g in self.ground.values() if near(g.pos)
            ],
            structures=list(self.structures),
            places=sorted(self.places),
            spell_cooldowns={k: round(t - self.time, 1) for k, t in self.spell_ready_at.items() if t > self.time},
            sleeping=self.sleeping,
        )

    @_scriptable
    def follow(self, player: str, distance: float = 3.0) -> ActionResult:
        if player not in self.players:
            return fail(Reason.UNKNOWN_TARGET, target=player)
        self.following, self.follow_distance = player, distance
        self._walk(self.players[player].pos, distance)
        return ok(following=player)

    def stop(self) -> ActionResult:
        self._begin("stop")  # a scripted rule is consumed but never fails stop
        self.following = None
        return ok()

    @_scriptable
    def go_to(self, target: str | Coords) -> ActionResult:
        dest = self._resolve(target)
        if dest is None:
            return fail(Reason.UNKNOWN_TARGET, target=target)
        self.following = None
        # Stop just short of players/entities, on the spot for places/coords.
        stop_at = 1.5 if isinstance(target, str) and (target in self.players or target in self.entities) else 0.0
        self._walk(dest, stop_at)
        return ok(target_position=list(dest), position=list(self.pos), arrive_tolerance=ARRIVE + stop_at)

    @_scriptable
    def attack(self, target: str) -> ActionResult:
        e = self.entities.get(target)
        if e is None or not e.alive:
            return fail(Reason.UNKNOWN_TARGET, target=target)
        self._walk(e.pos, 1.5)
        while e.hp > 0:
            e.hp -= COMPANION_DAMAGE
            if e.hp <= 0:
                break
            self.health -= e.damage
            self._advance(1.0)
            if self.health <= 0:
                return fail(Reason.COMPANION_DOWN)
        e.hp, e.alive = 0, False
        return ok(target=target, killed=True)

    def gather(self, resource: str, count: int, radius: float | None = None) -> ActionResult:
        rule = self._begin("gather", resource=resource, count=count)
        reach = GATHER_RANGE if radius is None else max(float(radius), GATHER_RANGE)
        attacked = rule is not None and rule.reason == "attacked"
        if rule and not attacked:
            return self._apply_rule(rule)
        nodes = sorted(
            (n for n in self.nodes.values()
             if n.resource == resource and n.remaining > 0 and math.dist(n.pos, self.pos) <= reach),
            key=lambda n: math.dist(n.pos, self.pos),
        )
        if not nodes:
            return fail(Reason.NOTHING_IN_RANGE, resource=resource)
        self.following = None
        # When attacked mid-task, only about half the work gets done first.
        need = max(1, count // 2) if attacked else count
        got = 0
        for node in nodes:
            self._walk(node.pos, 1.0)
            take = min(node.remaining, need - got)
            node.remaining -= take
            self.inventory[resource] += take
            got += take
            self._advance(take * HARVEST_TIME)
            self._progress(GatherProgress(resource=resource, item=resource, have=got, want=count))
            if got >= need:
                break
        if attacked:
            return fail(Reason.ATTACKED, by=self._spawn_attacker(), gathered=got)
        if got < count:
            return fail(Reason.NOT_ENOUGH, resource=resource, gathered=got)
        return ok(resource=resource, gathered=got)

    @_scriptable
    def craft(self, item: str, count: int = 1) -> ActionResult:
        recipe = RECIPES.get(item)
        if recipe is None:
            return fail(Reason.UNKNOWN_RECIPE, item=item)
        batches = math.ceil(count / recipe["yield"])
        need = {k: v * batches for k, v in recipe["inputs"].items()}
        missing = {k: v - self.inventory[k] for k, v in need.items() if self.inventory[k] < v}
        if missing:
            return fail(Reason.MISSING_MATERIALS, missing=missing)
        self.inventory -= Counter(need)
        made = batches * recipe["yield"]
        self.inventory[item] += made
        self._advance(3.0 * batches)
        return ok(item=item, crafted=made)

    @_scriptable
    def place(self, blueprint: str, location: str | Coords) -> ActionResult:
        cost = BLUEPRINTS.get(blueprint)
        dest = self._resolve(location)
        if cost is None or dest is None:
            return fail(Reason.UNKNOWN_TARGET, blueprint=blueprint, location=location)
        if math.dist(dest, self.pos) > 10.0:
            return fail(Reason.TOO_FAR, distance=round(math.dist(dest, self.pos), 1))
        missing = {k: v - self.inventory[k] for k, v in cost.items() if self.inventory[k] < v}
        if missing:
            return fail(Reason.MISSING_MATERIALS, missing=missing)
        self.inventory -= Counter(cost)
        sid = self._new_id(blueprint)
        self.structures.append({"id": sid, "blueprint": blueprint, "position": list(dest)})
        self._advance(10.0)
        return ok(structure_id=sid)

    @_scriptable
    def give(self, player: str, item: str, count: int) -> ActionResult:
        p = self.players.get(player)
        if p is None:
            return fail(Reason.UNKNOWN_TARGET, target=player)
        if math.dist(p.pos, self.pos) > REACH:
            return fail(Reason.TOO_FAR, distance=round(math.dist(p.pos, self.pos), 1))
        if self.inventory[item] < count:
            return fail(Reason.MISSING_MATERIALS, missing={item: count - self.inventory[item]})
        self.inventory[item] -= count
        p.inventory[item] += count
        return ok(player=player, item=item, count=count)

    @_scriptable
    def pickup(self, target: str, item: str | None = None, limit: int = 1) -> ActionResult:
        def fits(g: GroundItem) -> bool:
            return item is None or item.lower() in g.item.lower()

        if target == "nearest":
            cands = sorted((g for g in self.ground.values()
                            if fits(g) and math.dist(g.pos, self.pos) <= GATHER_RANGE),
                           key=lambda g: math.dist(g.pos, self.pos))[:limit]
            if not cands:
                return fail(Reason.NOTHING_IN_RANGE, item=item)
        else:
            g = self.ground.get(target)
            if g is None or not fits(g):
                return fail(Reason.UNKNOWN_TARGET, target=target)
            cands = [g]
        self.following = None
        picked = []
        for g in cands:
            self._walk(g.pos, 0.5)
            del self.ground[g.id]
            self.inventory[g.item] += g.count
            picked.append({"world_item": g.id, "item": g.item, "count": g.count})
        first = picked[0]["item"]
        return ok(item=first, count=sum(p["count"] for p in picked if p["item"] == first), picked=picked,
                  inventory=dict(+self.inventory))

    @_scriptable
    def drop(self, item: str, count: int, at: str = "feet") -> ActionResult:
        if self.inventory[item] <= 0:
            return fail(Reason.NOT_IN_INVENTORY, item=item)
        if self.inventory[item] < count:
            return fail(Reason.NOT_ENOUGH, item=item, have=self.inventory[item])
        spot = list(self.pos)
        if at == "luis":
            luis = next(iter(self.players.values()), None)
            if luis is None or math.dist(luis.pos, self.pos) > REACH:
                return fail(Reason.TOO_FAR)
            spot = list(luis.pos)
        self.inventory[item] -= count
        gid = self.add_ground_item(item, count, spot)
        return ok(item=item, count=count, at=at, world_items=[gid], position=spot,
                  inventory_left=self.inventory[item])

    def say(self, text: str) -> ActionResult:
        self._begin("say", text=text)  # likewise for say
        self.chat.append(("companion", text))
        self.chat_times.append(self.time)
        return ok()

    # ------------------------------------------------------------------ spells

    @staticmethod
    def resolve_spell(name: str) -> str | None:
        want = _norm(name)
        for sid, sp in SPELLS.items():
            if want in (_norm(sid), _norm(sp["name"])) or want in {_norm(a) for a in sp["aliases"]}:
                return sid
        return None

    def _spell_block(self, sid: str) -> tuple[str | None, dict]:
        if sid not in self.unlocked:
            return Reason.NOT_UNLOCKED, {"spell": sid}
        left = self.spell_ready_at.get(sid, 0.0) - self.time
        if left > 0:
            return Reason.ON_COOLDOWN, {"spell": sid, "remaining_s": round(left, 1)}
        return None, {}

    @_scriptable
    def cast(self, spell: str, target: str | Coords | None = None) -> ActionResult:
        sid = self.resolve_spell(spell)
        if sid is None:
            return fail(Reason.UNKNOWN_SKILL, spell=spell)
        reason, data = self._spell_block(sid)
        if reason:
            return fail(reason, **data)
        sp = SPELLS[sid]
        point = list(self.pos) if target in (None, "self") or sp.get("self") else self._resolve(target)
        if point is None:
            return fail(Reason.UNKNOWN_TARGET, target=target)
        if sp.get("aoe_m"):
            near = min((math.dist(p.pos, point) for p in self.players.values()), default=math.inf)
            if near < SAFE_PLAYER_M:
                return fail(Reason.UNSAFE, spell=sid, player_m=round(near, 1), safe_m=SAFE_PLAYER_M)
        self.spell_ready_at[sid] = self.time + sp["cooldown_s"]
        self.casts.append({"spell": sid, "at": list(point), "time": self.time})
        self._advance(1.0)
        return ok(spell=sid, cooldown_s=sp["cooldown_s"], verified=True)

    @_scriptable
    def sleep(self, target: str | None = None, mode: str = "auto") -> ActionResult:
        bed = None
        if mode != "flag" and self.beds:
            bed = target if target in self.beds else min(self.beds, key=lambda b: math.dist(self.beds[b], self.pos))
            if target and target not in self.beds:
                return fail(Reason.UNKNOWN_TARGET, target=target)
            self._walk(self.beds[bed], 0.5)
        elif mode == "bed":
            return fail(Reason.NOTHING_IN_RANGE, detail="no free bed")
        self.following = None
        self.sleeping = True
        return ok(mode="bed" if bed else "flag", bed=bed, sleeping=True)

    @_scriptable
    def wake(self) -> ActionResult:
        was, self.sleeping = self.sleeping, False
        return ok(was=was, sleeping=False)

    def spells(self) -> ActionResult:
        """Not recorded in ``calls``: the Controller reads it for context."""
        rows = []
        for sid, sp in SPELLS.items():
            reason, data = self._spell_block(sid)
            if reason == Reason.NOT_UNLOCKED:
                continue
            rows.append({"id": sid, "name": sp["name"], "role": sp["role"], "use_when": sp["use_when"],
                         "castable": reason is None, "reason": reason, "remaining_s": data.get("remaining_s", 0)})
        return ok(spells=rows)

    # ------------------------------------------------------------------ reflex rules (body/rules.lua shape)

    @staticmethod
    def _enemy_key(enemy: str | None) -> str:
        k = "".join(ch for ch in (enemy or "*").lower() if ch.isalnum() or ch == "*")
        if k in ("", "any", "all"):
            return "*"
        return k[:-1] if len(k) > 3 and k.endswith("s") and not k.endswith("ss") else k

    def _all_rules(self) -> list[dict]:
        out = [r for rules in self.reflex_rules.values() for r in rules]
        return sorted(out, key=lambda r: int(r["id"][1:]))

    @_scriptable
    def set_reflex_rule(self, enemy: str = "*", trigger: dict | None = None, actions: list | None = None,
                        cooldown_s: float = 3.0, note: str | None = None) -> ActionResult:
        if not trigger or not actions:
            return fail(Reason.INVALID_ARGS, detail="trigger and actions are required")
        key = self._enemy_key(enemy)
        trig = {k: v for k, v in trigger.items() if v is not None}
        acts = [{k: v for k, v in a.items() if v is not None} for a in actions]
        warnings = []
        for a in acts:
            if a.get("kind") == "cast":
                sid = self.resolve_spell(a.get("spell") or "")
                if sid is None:
                    return fail(Reason.INVALID_ARGS, detail=f"unknown spell {a.get('spell')}")
                a["spell"] = sid
                if sid not in self.unlocked:
                    warnings.append({"action": "cast", "spell": sid, "reason": Reason.NOT_UNLOCKED})
        rules = self.reflex_rules.setdefault(key, [])
        rule = {"enemy": key, "trigger": trig, "actions": acts, "cooldown_s": cooldown_s, "note": note}
        for i, old in enumerate(rules):
            if old["trigger"] == trig:
                rule["id"] = old["id"]
                rules[i] = rule
                return ok(rule=rule, replaced=True, warnings=warnings, count=len(self._all_rules()))
        if len(rules) >= MAX_RULES_PER_ENEMY:
            return fail(Reason.INVALID_ARGS, detail=f"too many rules for {key}")
        self._rule_ids += 1
        rule["id"] = f"r{self._rule_ids}"
        rules.append(rule)
        return ok(rule=rule, replaced=False, warnings=warnings, count=len(self._all_rules()))

    def list_rules(self, enemy: str | None = None) -> ActionResult:
        """Not recorded in ``calls``: the Controller reads it for context."""
        want = self._enemy_key(enemy) if enemy else None
        rules = [r for r in self._all_rules() if want is None or r["enemy"] == "*" or r["enemy"] in want]
        return ok(rules=rules)

    @_scriptable
    def clear_rule(self, id: str | None = None, enemy: str | None = None, all: bool = False) -> ActionResult:
        removed: list[str] = []
        if all:
            removed = [r["id"] for r in self._all_rules()]
            self.reflex_rules.clear()
        elif id:
            for rules in self.reflex_rules.values():
                for r in list(rules):
                    if r["id"] == id:
                        rules.remove(r)
                        removed.append(id)
            if not removed:
                return fail(Reason.UNKNOWN_TARGET, id=id)
        elif enemy:
            removed = [r["id"] for r in self.reflex_rules.pop(self._enemy_key(enemy), [])]
        else:
            return fail(Reason.INVALID_ARGS, detail="id, enemy or all is required")
        return ok(removed=removed, count=len(self._all_rules()))

    # ------------------------------------------------------------------ progress (live, like the bridge)

    def set_progress_listener(self, listener) -> None:
        self._progress_listener = listener

    def _progress(self, ev: Event) -> None:
        self._events.append(ev)
        if self._progress_listener:
            self._progress_listener(ev)

    # ------------------------------------------------------------------ perception (body/perception.lua shape)

    def _things(self, radius: float) -> list[dict]:
        def entry(id_, name, kind, pos, actions, gives=(), state="available", count=1):
            d = math.dist(pos, self.pos)
            return {"id": id_, "name": name, "kind": kind, "gives": list(gives), "state": state, "count": count,
                    "distance_m": round(d, 1), "actions": [{"a": a} for a in actions], "_d": d}
        out = []
        for g in self.gatherables.values():
            out.append(entry(g.id, g.name, "gatherable", g.pos, ["interact"], [g.gives], count=g.count))
        for g in self.ground.values():
            out.append(entry(g.id, g.item, "item", g.pos, ["pickup", "interact"], [g.item], count=g.count))
        for e in self.entities.values():
            if e.alive:
                out.append(entry(e.id, e.kind, "creature", e.pos, ["attack"], state="alive"))
        for n in self.nodes.values():
            if n.remaining > 0:
                kind = {"log": "tree", "stone": "rock"}.get(n.resource, "resource")
                out.append(entry(n.id, f"{kind} ({n.resource})", kind, n.pos, ["gather"], [n.resource]))
        for p in self.players.values():
            out.append(entry(p.name, p.name, "player", p.pos, ["follow", "give"]))
        return sorted((t for t in out if t["_d"] <= radius), key=lambda t: t["_d"])

    @_scriptable
    def look(self, about: str | None = None, radius_m: float = 30.0, kinds: list[str] | None = None,
             max: int = 12) -> ActionResult:
        things = self._things(radius_m)
        if kinds:
            things = [t for t in things if t["kind"] in kinds]
        matched = None
        if about:
            want = tokens(about)
            hits = [t for t in things if want & (tokens(t["name"]) | {w for g in t["gives"] for w in tokens(g)}
                                                  | tokens(t["kind"]))]
            matched = bool(hits)
            things = hits or things
        for t in things:
            t.pop("_d", None)
        data = {"things": things[:max], "radius_m": radius_m}
        if about:
            data["matched"] = matched
        if len(things) > max:
            data.update(more=len(things) - max, hint="narrow with about= or radius_m=")
        return ok(**data)

    @_scriptable
    def inspect(self, target: str) -> ActionResult:
        t = next((x for x in self._things(NEARBY_RANGE) if x["id"] == target), None)
        if t is None:
            return fail(Reason.UNKNOWN_TARGET, target=target)
        t.pop("_d", None)
        return ok(**t, description=f"A {t['name']}.")

    @_scriptable
    def interact(self, target: str, secondary: bool = False) -> ActionResult:
        g = self.gatherables.get(target)
        if g is not None:
            if math.dist(g.pos, self.pos) > GATHER_RANGE:
                return fail(Reason.TOO_FAR, target=target)
            self.following = None
            self._walk(g.pos, 0.5)
            del self.gatherables[target]
            self.inventory[g.gives] += g.count
            self._advance(1.0)
            return ok(target=target, item=g.gives, count=g.count, prompt=g.prompt)
        if target in self.ground:
            res = self.pickup(target)
            return ok(target=target, item=res["data"]["item"], count=res["data"]["count"]) if res["ok"] else res
        if target in self.entities or target in self.nodes or target in self.players:
            return fail(Reason.NOT_INTERACTABLE, target=target)
        return fail(Reason.UNKNOWN_TARGET, target=target)

    def world_info(self) -> ActionResult:
        if not self.world_guid:
            return fail(Reason.NOT_IMPLEMENTED, tool="world_info")
        return ok(world_guid=self.world_guid, name="MockWorld")

    def poll_events(self) -> list[Event]:
        events, self._events = self._events, []
        return events

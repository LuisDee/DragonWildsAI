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
    Reason,
    fail,
    ok,
)

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
        self.chat: list[tuple[str, str]] = []  # (speaker, text)
        self.calls: list[tuple[str, dict]] = []  # every tool call, for test assertions
        self._rules: list[FailureRule] = []
        self._events: list[Event] = []
        self._ids = Counter()

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
            structures=list(self.structures),
            places=sorted(self.places),
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

    def gather(self, resource: str, count: int) -> ActionResult:
        rule = self._begin("gather", resource=resource, count=count)
        attacked = rule is not None and rule.reason == "attacked"
        if rule and not attacked:
            return self._apply_rule(rule)
        nodes = sorted(
            (n for n in self.nodes.values()
             if n.resource == resource and n.remaining > 0 and math.dist(n.pos, self.pos) <= GATHER_RANGE),
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

    def say(self, text: str) -> ActionResult:
        self._begin("say", text=text)  # likewise for say
        self.chat.append(("companion", text))
        return ok()

    def poll_events(self) -> list[Event]:
        events, self._events = self._events, []
        return events

"""GameInterface: the contract between the brain and a body (mock or real game).

Every action returns ``{"ok": bool, "reason": str | None, "data": dict}``.
Tool argument schemas are pydantic models; ``tool_schemas()`` turns them into
OpenAI-style function definitions, which LiteLLM forwards to any provider.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Annotated, Any, Literal, TypedDict, Union

from pydantic import BaseModel, Field, TypeAdapter

# --------------------------------------------------------------------------- results


class ActionResult(TypedDict):
    ok: bool
    reason: str | None
    data: dict[str, Any]


def ok(**data: Any) -> ActionResult:
    return {"ok": True, "reason": None, "data": data}


def fail(reason: str, **data: Any) -> ActionResult:
    return {"ok": False, "reason": reason, "data": data}


def from_wire(reply: dict) -> ActionResult:
    """Normalise a body ``result`` message into an ActionResult."""
    return {"ok": bool(reply.get("ok")), "reason": reply.get("reason"), "data": reply.get("data") or {}}


# Failure reasons shared by every body. Bodies may add others; the executor
# treats any reason outside INTERRUPTS and DETERMINISTIC as transient (retryable).
class Reason:
    PATH_BLOCKED = "path_blocked"
    NOTHING_IN_RANGE = "nothing_in_range"
    NOT_ENOUGH = "not_enough_resources"
    MISSING_MATERIALS = "missing_materials"
    UNKNOWN_TARGET = "unknown_target"
    UNKNOWN_RECIPE = "unknown_recipe"
    TOO_FAR = "too_far"
    INTERRUPTED = "interrupted"  # a player command pre-empted the action
    ATTACKED = "attacked"  # the companion was attacked mid-action
    COMPANION_DOWN = "companion_down"
    TIMEOUT = "timeout"
    INVALID_ARGS = "invalid_args"
    UNKNOWN_TOOL = "unknown_tool"
    NOT_IMPLEMENTED = "not_implemented"  # the body doesn't have this skill yet
    VERIFICATION_FAILED = "verification_failed"
    UNKNOWN_SKILL = "unknown_skill"  # the task names a skill the registry doesn't have
    BODY_ERROR = "body_error"  # the Lua body's handler crashed; transient (retryable)
    STATE_UNAVAILABLE = "state_unavailable"  # get_state failed, so nothing can be verified
    NOT_IN_INVENTORY = "not_in_inventory"  # the companion does not carry that item (drop/give/equip)
    # Spells (body/spells.lua) and reflex rules (body/rules.lua)
    ON_COOLDOWN = "on_cooldown"  # retryable: data.remaining_s says when (the executor waits short ones)
    NOT_UNLOCKED = "not_unlocked"  # Luis hasn't unlocked that spell (or its perk): the bot mirrors him
    UNSAFE = "unsafe"  # an area spell would land too close to a player
    CANT_SENSE = "cant_sense"  # a reflex rule trigger the body cannot sense
    # gather (body/gather.lua)
    WRONG_TOOL = "wrong_tool"  # no held tool of the right category/tier: equip one (or fetch it) first
    INVENTORY_FULL = "inventory_full"  # the bot's store refused more items: deliver/drop first

    # A player command or an attack pre-empted the action: not the skill's fault.
    INTERRUPTS: frozenset[str] = frozenset({INTERRUPTED, ATTACKED})
    # Retrying these cannot help; the plan has to change.
    DETERMINISTIC: frozenset[str] = frozenset({
        NOTHING_IN_RANGE, NOT_ENOUGH, MISSING_MATERIALS, UNKNOWN_TARGET, UNKNOWN_RECIPE, TOO_FAR,
        INVALID_ARGS, UNKNOWN_TOOL, NOT_IMPLEMENTED, COMPANION_DOWN, UNKNOWN_SKILL, STATE_UNAVAILABLE,
        NOT_UNLOCKED, UNSAFE, CANT_SENSE, NOT_IN_INVENTORY, WRONG_TOOL, INVENTORY_FULL,
    })
    # The companion simply cannot do this yet (skill missing on the body or in the registry).
    CANT_YET: frozenset[str] = frozenset({NOT_IMPLEMENTED, UNKNOWN_TOOL, UNKNOWN_SKILL})


# --------------------------------------------------------------------------- tool args

Coords = list[float]  # [x, y, z]


class NoArgs(BaseModel):
    pass


class FollowArgs(BaseModel):
    player: str = Field(description="Name of the player to follow.")
    distance: float = Field(3.0, ge=1.0, description="Distance to keep, in metres.")


class GoToArgs(BaseModel):
    target: str | Coords = Field(
        description="A named place from notes, an entity id, a player name, or [x, y, z]."
    )


class AttackArgs(BaseModel):
    target: str = Field(description="Entity id of the creature to attack, e.g. 'wolf_1'.")


class GatherArgs(BaseModel):
    resource: str = Field(description="Resource to harvest, e.g. 'oak' (oak logs), 'ash', 'stone' or 'rune_essence'.")
    count: int = Field(ge=1, description="How many more to gather (counted in the inventory).")
    radius: float | None = Field(None, gt=0, le=120,
                                 description="Initial search radius in metres (default 30; it widens when nothing is found).")


class CraftArgs(BaseModel):
    item: str = Field(description="Item to craft.")
    count: int = Field(1, ge=1)


class PlaceArgs(BaseModel):
    blueprint: str = Field(description="Saved blueprint name.")
    location: str | Coords = Field(description="Named place or [x, y, z].")


class GiveArgs(BaseModel):
    player: str
    item: str
    count: int = Field(ge=1)


class PickupArgs(BaseModel):
    target: str = Field(description="World item id from state nearby_items, or 'nearest'.")
    item: str | None = Field(None, description=(
        "Only items whose id or name contains this, e.g. 'oak'. ALWAYS set this when the player names "
        "what to pick up. Never pick up a different item than the one named: if nothing matching is in "
        "nearby_items, don't call pickup; say you can't see any."))
    limit: int = Field(1, ge=1, le=20, description="Pick up this many world items (nearest matching first).")


class DropArgs(BaseModel):
    item: str = Field(description="Carried item: an id from state inventory, or a name like 'oak logs'.")
    count: int = Field(ge=1, description="How many to drop.")
    at: Literal["feet", "luis"] = Field("feet", description="At the companion's feet, or at Luis's feet when he is close.")


class SayArgs(BaseModel):
    text: str


class RememberArgs(BaseModel):
    key: str = Field(description="Short key, e.g. 'place:lake_hut' or 'pref:luis_axe'.")
    value: str


class SleepArgs(BaseModel):
    target: str | None = Field(None, description="Omit for the nearest free bed; or a bed id.")
    mode: Literal["auto", "bed", "flag"] = Field(
        "auto", description="auto: a free bed if there is one, else just lie down on the spot.")


class CastArgs(BaseModel):
    spell: str = Field(description="Spell name as listed in castable_spells, e.g. 'Tempest Shield' or 'Windstep'.")
    target: str | Coords | None = Field(
        None, description="Omit or 'self' for self spells; an entity id for a targeted spell; or [x, y, z]."
    )


# Reflex rules (body/rules.lua): standing orders the body runs at game speed, no model in the loop.
# Only what the body can sense; the Controller must refuse anything else ("I can't sense that").
SENSABLE_TRIGGERS: dict[str, str] = {
    "telegraph": "an enemy of that kind starts an attack (raises claws, winds up); optional attack name filter",
    "enemy_hp_below": "the current target's health is below value percent",
    "cluster_at_least": "value or more enemies are bunched together around the target",
    "own_hp_below": "the companion's own health is below value percent",
    "luis_hp_below": "Luis's health is below value percent",
    "enemy_stunned": "the target is staggered or knocked down",
    "spell_ready": "the named spell is off cooldown and castable",
}
REFLEX_ACTIONS: dict[str, str] = {
    "cast": "cast a spell (spell, target self|enemy|cluster)",
    "evade": "step away from the enemy (distance_m, default 4)",
    "switch_weapon": "equip an owned weapon (item id)",
    "retreat": "run back to Luis (duration_s, default 4)",
    "focus_target": "switch the attack to the triggering enemy",
}


class ReflexTrigger(BaseModel):
    kind: Literal["telegraph", "enemy_hp_below", "cluster_at_least", "own_hp_below", "luis_hp_below",
                  "enemy_stunned", "spell_ready"] = Field(
        description="What to react to. " + "; ".join(f"{k}: {v}" for k, v in SENSABLE_TRIGGERS.items()))
    value: float | None = Field(None, description="Percent for *_hp_below, enemy count for cluster_at_least.")
    attack: str | None = Field(None, description="telegraph only: part of the enemy attack name, if Luis named one.")
    spell: str | None = Field(None, description="spell_ready only: the spell.")
    near_m: float | None = Field(None, description="telegraph only: how close the enemy must be (default 8 m).")


class ReflexAction(BaseModel):
    kind: Literal["cast", "evade", "switch_weapon", "retreat", "focus_target"] = Field(
        description="; ".join(f"{k}: {v}" for k, v in REFLEX_ACTIONS.items()))
    spell: str | None = Field(None, description="cast: the spell.")
    target: Literal["self", "enemy", "cluster"] | None = Field(None, description="cast: where to aim it.")
    item: str | None = Field(None, description="switch_weapon: item id, e.g. 'ITEM_Club_Wood'.")
    distance_m: float | None = Field(None, description="evade: metres to step away.")
    duration_s: float | None = Field(None, description="retreat: seconds to stay by Luis.")


class SetReflexRuleArgs(BaseModel):
    enemy: str = Field("*", description="Enemy kind it applies to, e.g. 'kalphite' (matches every Kalphite type), "
                                        "or '*' for any enemy. Rules are remembered per enemy kind.")
    trigger: ReflexTrigger
    actions: list[ReflexAction] = Field(min_length=1, max_length=3, description="Done in order when it fires.")
    cooldown_s: float = Field(3.0, ge=0.5, le=600, description="Minimum seconds between two firings.")
    note: str | None = Field(None, description="Luis's words, for the record.")


class ListRulesArgs(BaseModel):
    enemy: str | None = Field(None, description="Only rules that apply to this enemy kind.")


class ClearRuleArgs(BaseModel):
    id: str | None = Field(None, description="Rule id from reflex_rules, e.g. 'r2'.")
    enemy: str | None = Field(None, description="Clear every rule for this enemy kind.")
    all: bool = Field(False, description="Clear every rule.")


# name -> (args model, description). Order matters only for prompt readability.
TOOLS: dict[str, tuple[type[BaseModel], str]] = {
    "get_state": (NoArgs, "Position, health, inventory, nearby entities/resources/players."),
    "follow": (FollowArgs, "Follow a player continuously until stopped or interrupted."),
    "stop": (NoArgs, "Cancel the current action (including follow)."),
    "go_to": (GoToArgs, "Walk to coordinates, a named place, a player or an entity."),
    "attack": (AttackArgs, "Engage a target; reflexes keep fighting until it is resolved."),
    "gather": (GatherArgs, "Harvest a resource nearby until count is reached or it fails."),
    "craft": (CraftArgs, "Craft an item from carried materials."),
    "place": (PlaceArgs, "Build a saved blueprint at a location (later phase)."),
    "give": (GiveArgs, "Hand carried items to a player (walks to them, drops at their feet)."),
    "pickup": (PickupArgs, "Pick up an item lying on the ground into the companion's inventory."),
    "drop": (DropArgs, "Drop carried items on the ground (at the companion's or Luis's feet)."),
    "say": (SayArgs, "Chat output. Only the Controller speaks."),
    "remember": (RememberArgs, "Store a long-term fact in notes.json."),
    "cast": (CastArgs, "Cast one of the spells in castable_spells now (self, an enemy id, or a point)."),
    "sleep": (SleepArgs, "Go to sleep (nearest free bed, never someone else's) so the night can pass."),
    "wake": (NoArgs, "Get up after sleeping."),
    "set_reflex_rule": (SetReflexRuleArgs,
                        "Store a standing order ('every time X, do Y') that the body runs instantly during fights. "
                        "Only for triggers in the trigger list; same enemy + trigger replaces the old rule."),
    "list_rules": (ListRulesArgs, "List the standing orders (reflex rules)."),
    "clear_rule": (ClearRuleArgs, "Forget a standing order by id, every order for an enemy kind, or all."),
}

# Brain-side tools that talk to the body directly, not through the executor (no game state to verify
# beyond the body's own read-back of the stored rule).
RULE_TOOLS = ("set_reflex_rule", "list_rules", "clear_rule")

# Tools the body implements (remember is brain-side, in the state store).
BODY_TOOLS = [name for name in TOOLS if name != "remember"]


def tool_schema(name: str, description: str | None = None) -> dict:
    model, default_desc = TOOLS[name]
    params = model.model_json_schema()
    params.pop("title", None)
    return {
        "type": "function",
        "function": {"name": name, "description": description or default_desc, "parameters": params},
    }


def tool_schemas(names: list[str] | None = None) -> list[dict]:
    return [tool_schema(n) for n in (names or list(TOOLS))]


def validate_args(name: str, args: dict) -> dict:
    """Validate and normalise tool args; raises KeyError / pydantic.ValidationError."""
    model, _ = TOOLS[name]
    return model.model_validate(args).model_dump()


# --------------------------------------------------------------------------- events
# Body -> brain events (section 5).


class CommandReceived(BaseModel):
    type: Literal["command_received"] = "command_received"
    player: str
    text: str


class TaskDone(BaseModel):
    type: Literal["task_done"] = "task_done"
    task_id: str
    data: dict = {}


class TaskFailed(BaseModel):
    type: Literal["task_failed"] = "task_failed"
    task_id: str
    reason: str


class Attacked(BaseModel):
    type: Literal["attacked"] = "attacked"
    by: str


class GatherProgress(BaseModel):
    """gather's progress: have of want collected so far (body/gather.lua)."""
    type: Literal["gather_progress"] = "gather_progress"
    task_id: str | None = None
    resource: str | None = None
    item: str | None = None
    have: int
    want: int


class PlayerNearbyActivity(BaseModel):
    type: Literal["player_nearby_activity"] = "player_nearby_activity"
    player: str
    activity: str


Event = Annotated[
    Union[CommandReceived, TaskDone, TaskFailed, Attacked, PlayerNearbyActivity, GatherProgress],
    Field(discriminator="type"),
]
_event_adapter: TypeAdapter[Event] = TypeAdapter(Event)


def parse_event(raw: dict) -> Event:
    return _event_adapter.validate_python(raw)


# --------------------------------------------------------------------------- interface


class GameInterface(ABC):
    """Implemented by the mock game and by the real bridge client."""

    @abstractmethod
    def get_state(self) -> ActionResult: ...

    @abstractmethod
    def follow(self, player: str, distance: float = 3.0) -> ActionResult: ...

    @abstractmethod
    def stop(self) -> ActionResult: ...

    @abstractmethod
    def go_to(self, target: str | Coords) -> ActionResult: ...

    @abstractmethod
    def attack(self, target: str) -> ActionResult: ...

    @abstractmethod
    def gather(self, resource: str, count: int, radius: float | None = None) -> ActionResult: ...

    @abstractmethod
    def craft(self, item: str, count: int = 1) -> ActionResult: ...

    @abstractmethod
    def place(self, blueprint: str, location: str | Coords) -> ActionResult: ...

    @abstractmethod
    def give(self, player: str, item: str, count: int) -> ActionResult: ...

    @abstractmethod
    def pickup(self, target: str, item: str | None = None, limit: int = 1) -> ActionResult: ...

    @abstractmethod
    def drop(self, item: str, count: int, at: str = "feet") -> ActionResult: ...

    @abstractmethod
    def say(self, text: str) -> ActionResult: ...

    @abstractmethod
    def poll_events(self) -> list[Event]:
        """Return (and clear) events the body emitted since the last poll."""

    # Spells and reflex rules: optional, so older bodies (and test fakes) need not implement them.
    def cast(self, spell: str, target: str | Coords | None = None) -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="cast")

    def sleep(self, target: str | None = None, mode: str = "auto") -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="sleep")

    def wake(self) -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="wake")

    def spells(self) -> ActionResult:
        """Compact spell list ``data.spells`` [{id, name, role, use_when, castable, reason, remaining_s}]."""
        return fail(Reason.NOT_IMPLEMENTED, tool="spells")

    def set_reflex_rule(self, enemy: str = "*", trigger: dict | None = None, actions: list | None = None,
                        cooldown_s: float = 3.0, note: str | None = None) -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="set_reflex_rule")

    def list_rules(self, enemy: str | None = None) -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="list_rules")

    def clear_rule(self, id: str | None = None, enemy: str | None = None, all: bool = False) -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="clear_rule")

    def call(self, tool: str, args: dict) -> ActionResult:
        """Dispatch a tool by name after validating its arguments."""
        if tool not in BODY_TOOLS:
            return fail(Reason.UNKNOWN_TOOL, tool=tool)
        try:
            clean = validate_args(tool, args)
        except Exception as exc:  # pydantic.ValidationError
            return fail(Reason.INVALID_ARGS, error=str(exc))
        return getattr(self, tool)(**clean)

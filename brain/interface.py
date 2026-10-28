"""GameInterface: the contract between the brain and a body (mock or real game).

Every action returns ``{"ok": bool, "reason": str | None, "data": dict}``.
Tool argument schemas are pydantic models; ``tool_schemas()`` turns them into
OpenAI-style function definitions, which LiteLLM forwards to any provider.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Annotated, Any, Callable, Literal, TypedDict, Union

from pydantic import AliasChoices, ConfigDict, BaseModel, Field, TypeAdapter, model_validator

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
    # perception and interaction (body look/inspect/interact; research 2026-10-25 section 6)
    NOT_PERCEIVED = "not_perceived"  # brain-side grounding refusal: the named thing is not in what was perceived
    AMBIGUOUS_TARGET = "ambiguous_target"  # several perceived things match; data.candidates
    NOT_INTERACTABLE = "not_interactable"  # the target affords no interaction
    BUSY = "busy"  # another owner holds the pawn (data: owner, owner_level, owner_since, owner_age_s)
    BODY_RESTARTED = "body_restarted"  # the client bridge restarted while the command was in flight (L2)
    LOST_BY_BODY = "lost_by_body"  # the body is no longer working on the command and never answered (L2)
    RESTING = "resting"  # he lies in a bed (data.resting_in = its id): get up with interact on it first
    # building and containers (client build.lua / store / take; docs/design/build-primitive.md, review finding 16)
    NO_PERMISSION = "no_permission"  # the server's privileges (Build / OpenChests) don't allow it
    HOST_ONLY = "host_only"  # a piece only the world's host/owner may build
    LIMIT_REACHED = "limit_reached"  # the game's piece count limit
    BLOCKED = "blocked"  # every spot tried was refused by the game's placement check (data.why, data.tried)
    NOT_A_CONTAINER = "not_a_container"
    NOT_IN_CONTAINER = "not_in_container"
    CONTAINER_FULL = "container_full"

    # A player command or an attack pre-empted the action: not the skill's fault.
    INTERRUPTS: frozenset[str] = frozenset({INTERRUPTED, ATTACKED})
    # Retrying these cannot help; the plan has to change.
    DETERMINISTIC: frozenset[str] = frozenset({
        NOTHING_IN_RANGE, NOT_ENOUGH, MISSING_MATERIALS, UNKNOWN_TARGET, UNKNOWN_RECIPE, TOO_FAR,
        INVALID_ARGS, UNKNOWN_TOOL, NOT_IMPLEMENTED, COMPANION_DOWN, UNKNOWN_SKILL, STATE_UNAVAILABLE,
        NOT_UNLOCKED, UNSAFE, CANT_SENSE, NOT_IN_INVENTORY, WRONG_TOOL, INVENTORY_FULL,
        NOT_PERCEIVED, AMBIGUOUS_TARGET, NOT_INTERACTABLE, BUSY,
        # L2: never retried blindly (a lost or timed-out command goes back to the model, which decides)
        TIMEOUT, BODY_RESTARTED, LOST_BY_BODY, RESTING,
        NO_PERMISSION, HOST_ONLY, LIMIT_REACHED, BLOCKED, NOT_A_CONTAINER, NOT_IN_CONTAINER, CONTAINER_FULL,
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
    mode: str | None = Field(None, description="Optional profile acquisition mode.")
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
    at: Literal["feet", "player"] = Field("feet", description="At the companion's own feet, or at a nearby player's feet.")
    player: str | None = Field(None, description="at=player: whose feet (the player must be close).")


class LookArgs(BaseModel):
    about: str | None = Field(None, description=(
        "What the player named, in their words (e.g. 'sticks'). If nothing matches, the answer says "
        "matched=false and lists what IS around instead."))
    radius: float = Field(20.0, gt=0, le=80, description="Search radius in metres (the body caps it at 80).")
    max: int = Field(15, ge=1, le=40, description="At most this many entries, best matches first.")


class InspectArgs(BaseModel):
    target: str = Field(description="An id from a look result.")


class LookupArgs(BaseModel):
    query: str = Field(min_length=1, max_length=120, description=(
        "The thing or topic, in a few words: an item, recipe, creature, place, spell, perk, station or "
        "mechanic (e.g. 'pumpkin spice infusion', 'iron bar', 'oak tree', 'over eating')."))
    kind: str | None = Field(None, max_length=40, description=(
        "Optional filter, e.g. item, recipe, station, spell, perk, monster, resource node, location. "
        "Ignored when nothing of that kind matches."))


class InteractArgs(BaseModel):
    target: str = Field(description="An id from a look result whose actions include interact.")
    secondary: bool = Field(False, description="Use the thing's secondary interaction instead.")


# Composite client skills (client_mod/scripts/skills.lua). The body's capability manifest publishes the
# same arg names with its own descriptions; these models give the brain typed defaults and verifiers.
class FetchArgs(BaseModel):
    target: str | None = Field(None, description="An id from situation or look (a world item or ground pickup).")
    item: str | None = Field(None, description="What to pick up, by name or item id.")
    count: int = Field(1, ge=1, le=20, description="How many items.")

    @model_validator(mode="after")
    def _target_or_item(self):
        if not (self.target or self.item):
            raise ValueError("fetch needs target or item")
        return self


class ConsumeArgs(BaseModel):
    item: str = Field(description="The item's name or id, or 'food' / 'drink' (its kind).")


class ComeToArgs(BaseModel):
    player: str = Field(description="The player's exact name.")
    distance: float = Field(2.0, ge=1.0, le=10.0, description="Stop this close, metres.")


class RunSkillArgs(BaseModel):
    name: str = Field(description="Name of a learned skill listed in learned_skills.")
    params: dict[str, Any] = Field(default_factory=dict, description="Values for the skill's params.")


class SayArgs(BaseModel):
    text: str


class RememberArgs(BaseModel):
    key: str = Field(description="Short key, e.g. 'place:lake_hut' or 'pref:favourite_axe'.")
    value: str
    at: Literal["self", "player"] | None = Field(
        None, description="For a place: store the position where you stand (self) or where a player stands (player).")
    player: str | None = Field(None, description="With at=player: which player (default: the one talking).")


class SleepArgs(BaseModel):
    target: str | None = Field(None, description="Omit for the nearest free bed; or a bed id.")
    mode: Literal["auto", "bed", "shelter"] = Field(
        "auto", description="auto: a free bed if there is one, else summon a shelter and sleep in it.")


class CastArgs(BaseModel):
    spell: str = Field(description="Spell name as listed in castable_spells, e.g. 'Tempest Shield' or 'Windstep'.")
    target: str | Coords | None = Field(
        None, description="Omit or 'self' for self spells; an entity id for a targeted spell; or [x, y, z]."
    )
    # held-open spells (cast_type instant_after_move, e.g. Recall: open here, walk, finish = back here; live 2026-10-26
    # 19:39 UTC). Without this field validate_args dropped it, so the brain could never cast Recall usefully.
    walk_to: str | Coords | None = Field(
        None, description="Only for cast_type instant_after_move: where to walk (id or [x, y, z]) while it is held open."
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
    "inventory": (NoArgs, "Your full inventory: what you wear (by slot), hold, carry on the hotbar (with durability) "
                           "and in your bag, plus weight. Read-only: does not interrupt."),
    "look": (LookArgs, "Look around: every gatherable, world item, creature, player and station nearby, by its "
                       "in-game name, with distance and what you can do with it. Read-only: does not interrupt."),
    "inspect": (InspectArgs, "Details of one thing from a look result: what it is, what it gives, what it needs, "
                             "which actions work. Read-only."),
    "lookup": (LookupArgs, "Look up game knowledge: what an item is and does, how to make it, which regions of the world "
                           "something is found in, creatures and weaknesses, spells, perks, mechanics. Game data first "
                           "(authoritative), then the wiki with page links. Read-only: does not interrupt."),
    "interact": (InteractArgs,"Use a thing you looked at, like a player pressing E (gather sticks, open, pick)."),
    "run_skill": (RunSkillArgs, "Run a skill you learned earlier (listed in learned_skills) with its params."),
    # composite client skills (offered only when the body's manifest lists them)
    "fetch": (FetchArgs, "Pick up items lying on the ground into your inventory (find, walk, face, use, verify)."),
    "consume": (ConsumeArgs, "Eat or drink an item from your hotbar (or pick it up first if it lies nearby)."),
    "come_to": (ComeToArgs, "Walk to a player and stop next to them."),
    "recover_grave": (NoArgs, "Go to your own gravestone and take everything back."),
}

# Tools that only exist in a body's capability manifest (never offered without it).
MANIFEST_ONLY = ("fetch", "consume", "come_to", "recover_grave")

# Brain-side tools that talk to the body directly, not through the executor (no game state to verify
# beyond the body's own read-back of the stored rule).
RULE_TOOLS = ("set_reflex_rule", "list_rules", "clear_rule")

# Read-only perception tools: they never interrupt the current job and never end a Controller turn.
READ_TOOLS = ("look", "inspect", "inventory", "lookup")

# Brain-side tools (the state store / skill library / knowledge index), never sent to the body.
BRAIN_TOOLS = ("remember", "run_skill", "lookup")

# Tools the body implements.
BODY_TOOLS = [name for name in TOOLS if name not in BRAIN_TOOLS]


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


class ChatHeard(BaseModel):
    """One chat line from another player (client body: every line, not only addressed ones). The brain
    decides whether it is meant for the companion (run_live.LiveAgent). ``from`` on the wire."""
    model_config = ConfigDict(populate_by_name=True)
    type: Literal["chat_heard"] = "chat_heard"
    player: str = Field(validation_alias=AliasChoices("player", "from"))
    text: str
    ts: float | None = None
    mentions_me: bool | None = None  # body hint: a prefix or the companion's name as a whole word


class Attacked(BaseModel):
    type: Literal["attacked"] = "attacked"
    by: str  # attacker entity id (as in get_state.nearby_entities)
    name: str | None = None  # the attacker's in-game name, when the body knows it (client body)
    amount: float | None = None  # damage of the hit that raised the event
    hp: float | None = None  # own health after it


class Unreachable(BaseModel):
    """The body can't follow/reach the player (client move.lua), once per episode. ``reason`` is the
    body's verdict: no_route | too_high | gap_too_wide | leader_windstepped | ... (never guessed)."""
    type: Literal["unreachable"] = "unreachable"
    reason: str
    detail: str | None = None
    leader_pos: list[float] | None = None  # where the move was going (the leader, or a go_to target)
    my_pos: list[float] | None = None
    mode: str | None = None  # the body's move mode: follow | go_to (client move.lua; broker.py uses it)
    # move.lua v10 (client_bridge forwards them): what the move was going to, and for reason
    # "lead_me" (stuck with a player within 40 m: "can you lead me out?") where and whom to ask.
    target: str | None = None  # a name, or "point"
    target_kind: str | None = None  # player | actor | point
    where: str | None = None  # the trap's name, or "at (x, y, z)"
    helper: str | None = None  # the player asked to lead him out


class Resumed(BaseModel):
    """Following works again after an ``unreachable`` episode (``reachable_again``), or a player led
    him out of a trap (``led_out``)."""
    type: Literal["resumed"] = "resumed"
    reason: str | None = None  # reachable_again | led_out
    helper: str | None = None
    target_kind: str | None = None


class VitalsLow(BaseModel):
    """Hydration or sustenance is low and the companion carries nothing to fix it (client body):
    the brain asks the player for help instead of starving silently."""
    type: Literal["vitals_low"] = "vitals_low"
    stat: str  # hydration | sustenance
    value: float
    max: float | None = None
    has_food: bool | None = None
    has_drink: bool | None = None


class GatherProgress(BaseModel):
    """gather's progress: have of want collected so far (body/gather.lua)."""
    type: Literal["gather_progress"] = "gather_progress"
    task_id: str | None = None
    resource: str | None = None
    item: str | None = None
    have: int
    want: int


class TaskProgress(BaseModel):
    """Generic progress of a long body action (milestones of any skill); ``text`` is a short label."""
    type: Literal["task_progress"] = "task_progress"
    task_id: str | None = None
    text: str | None = None
    have: int | None = None
    want: int | None = None


PROGRESS_EVENTS = (GatherProgress, TaskProgress)


class PlayerNearbyActivity(BaseModel):
    type: Literal["player_nearby_activity"] = "player_nearby_activity"
    player: str
    activity: str


class ItemsDropped(BaseModel):
    """Another player dropped items near the companion (one per drop burst, client skills module):
    ``items`` = [{id, name, item, count, consumable, distance, dropped_by}]. A body situation: the
    model decides whether to pick them up and say thanks (broker.py), no code rule."""
    model_config = ConfigDict(extra="allow")
    type: Literal["items_dropped"] = "items_dropped"
    by: str | None = None
    players: list[str] = []
    items: list[dict] = []


class Activity(BaseModel):
    """One COMPLETED body episode, whoever started it (brain, a reflex, a debug/test command): the
    brain's episodic memory (broker.py). ``kind`` is open (combat_end, fled, grave_recovered,
    picked_up, consumed, death, respawned, trap_escaped, gather_done, follow_episode, ...) and every
    other field the body sends is kept (target, outcome, damage_taken, loot, items, where, ...)."""
    model_config = ConfigDict(extra="allow")
    type: Literal["activity"] = "activity"
    kind: str
    by: str | None = None  # brain | reflex | debug | unknown
    ts: float | None = None  # body epoch seconds

    def fields(self) -> dict:
        return {k: v for k, v in self.model_dump().items() if k not in ("type", "kind", "by", "ts", "iso") and v not in (None, [], "")}


Event = Annotated[
    Union[CommandReceived, ChatHeard, TaskDone, TaskFailed, Attacked, VitalsLow, Unreachable, Resumed,
          PlayerNearbyActivity, GatherProgress, TaskProgress, Activity, ItemsDropped],
    Field(discriminator="type"),
]
_event_adapter: TypeAdapter[Event] = TypeAdapter(Event)
EVENT_TYPES: frozenset[str] = frozenset(m.model_fields["type"].default for m in (
    CommandReceived, ChatHeard, TaskDone, TaskFailed, Attacked, VitalsLow, Unreachable, Resumed, PlayerNearbyActivity,
    GatherProgress, TaskProgress, Activity, ItemsDropped))


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
    def gather(self, resource: str, count: int, radius: float | None = None,
               mode: str | None = None) -> ActionResult: ...

    @abstractmethod
    def craft(self, item: str, count: int = 1) -> ActionResult: ...

    @abstractmethod
    def place(self, blueprint: str, location: str | Coords) -> ActionResult: ...

    @abstractmethod
    def give(self, player: str, item: str, count: int) -> ActionResult: ...

    @abstractmethod
    def pickup(self, target: str, item: str | None = None, limit: int = 1) -> ActionResult: ...

    @abstractmethod
    def drop(self, item: str, count: int, at: str = "feet", player: str | None = None) -> ActionResult: ...

    @abstractmethod
    def say(self, text: str) -> ActionResult: ...

    @abstractmethod
    def poll_events(self) -> list[Event]:
        """Return (and clear) events the body emitted since the last poll."""

    # Spells and reflex rules: optional, so older bodies (and test fakes) need not implement them.
    def cast(self, spell: str, target: str | Coords | None = None, walk_to: str | Coords | None = None) -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="cast")

    def sleep(self, target: str | None = None, mode: str = "auto") -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="sleep")

    def wake(self) -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="wake")

    # Perception (body/perception.lua, owned by the gather agent). Bodies without it answer
    # not_implemented, and the Controller then works from the get_state situation digest only.
    def look(self, about: str | None = None, radius: float = 20.0, max: int = 15) -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="look")

    def inspect(self, target: str) -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="inspect")

    def inventory(self) -> ActionResult:
        """Compact listing: ``{worn: {slot: name}, held: {right, left}, hotbar: [{slot, name, count,
        durability_pct}], bag: [...], weight}``. Read-only."""
        return fail(Reason.NOT_IMPLEMENTED, tool="inventory")

    def interact(self, target: str, secondary: bool = False) -> ActionResult:
        return fail(Reason.NOT_IMPLEMENTED, tool="interact")

    def world_info(self) -> ActionResult:
        """``data.world_guid`` (the save's WorldSaveGuid) and optionally ``data.name``."""
        return fail(Reason.NOT_IMPLEMENTED, tool="world_info")

    def set_progress_listener(self, listener: "Callable[[Event], None] | None") -> None:
        """Called with progress events as soon as the body emits them, even while an action is still
        running (the bridge waits inside the action call). Default: no live delivery."""

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

    # Set by discover; mocks may still register extra tools without a validator.
    manifest_tools: frozenset[str] = frozenset()
    manifest_validator = None

    def call(self, tool: str, args: dict) -> ActionResult:
        """Dispatch a tool by name after validating its arguments."""
        if tool in self.manifest_tools and self.manifest_validator is not None:
            try:
                clean = self.manifest_validator(tool, args)
            except Exception as exc:
                return fail(Reason.INVALID_ARGS, tool=tool, detail=str(exc))
            return self.call_manifest(tool, clean)
        if tool not in BODY_TOOLS:
            if tool in self.manifest_tools:
                return self.call_raw(tool, dict(args))
            return fail(Reason.UNKNOWN_TOOL, tool=tool)
        try:
            clean = validate_args(tool, args)
        except Exception as exc:  # pydantic.ValidationError
            return fail(Reason.INVALID_ARGS, error=str(exc))
        # Look the tool up on the class: an instance attribute of the same name (the mock's
        # ``inventory`` Counter) must not shadow the tool method.
        method = getattr(type(self), tool, None)
        if method is None:  # e.g. the composite skills: no typed method, sent by name
            return self.call_raw(tool, clean)
        # an optional arg left unset (None) is not passed to a method that does not take it
        import inspect
        params = inspect.signature(method).parameters
        if not any(p.kind == p.VAR_KEYWORD for p in params.values()):
            clean = {k: v for k, v in clean.items() if k in params or v is not None}
        return method(self, **clean)

    def call_manifest(self, tool: str, args: dict) -> ActionResult:
        """Dispatch already validated manifest args; bridge clients preserve them on the wire."""
        return self.call_raw(tool, args)

    def call_raw(self, tool: str, args: dict) -> ActionResult:
        """Send a tool without a typed method (bodies that can: the bridge client)."""
        return fail(Reason.NOT_IMPLEMENTED, tool=tool)

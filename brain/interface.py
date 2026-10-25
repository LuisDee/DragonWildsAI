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


# Failure reasons shared by every body. Bodies may add others; the executor
# treats unknown reasons as transient (retryable).
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
    VERIFICATION_FAILED = "verification_failed"


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
    resource: str = Field(description="Resource to harvest, e.g. 'log' or 'stone'.")
    count: int = Field(ge=1, description="How many to gather.")


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


class SayArgs(BaseModel):
    text: str


class RememberArgs(BaseModel):
    key: str = Field(description="Short key, e.g. 'place:lake_hut' or 'pref:luis_axe'.")
    value: str


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
    "give": (GiveArgs, "Hand items to a player who is within reach."),
    "say": (SayArgs, "Chat output. Only the Controller speaks."),
    "remember": (RememberArgs, "Store a long-term fact in notes.json."),
}

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


class PlayerNearbyActivity(BaseModel):
    type: Literal["player_nearby_activity"] = "player_nearby_activity"
    player: str
    activity: str


Event = Annotated[
    Union[CommandReceived, TaskDone, TaskFailed, Attacked, PlayerNearbyActivity],
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
    def gather(self, resource: str, count: int) -> ActionResult: ...

    @abstractmethod
    def craft(self, item: str, count: int = 1) -> ActionResult: ...

    @abstractmethod
    def place(self, blueprint: str, location: str | Coords) -> ActionResult: ...

    @abstractmethod
    def give(self, player: str, item: str, count: int) -> ActionResult: ...

    @abstractmethod
    def say(self, text: str) -> ActionResult: ...

    @abstractmethod
    def poll_events(self) -> list[Event]:
        """Return (and clear) events the body emitted since the last poll."""

    def call(self, tool: str, args: dict) -> ActionResult:
        """Dispatch a tool by name after validating its arguments."""
        if tool not in BODY_TOOLS:
            return fail(Reason.UNKNOWN_TOOL, tool=tool)
        try:
            clean = validate_args(tool, args)
        except Exception as exc:  # pydantic.ValidationError
            return fail(Reason.INVALID_ARGS, error=str(exc))
        return getattr(self, tool)(**clean)

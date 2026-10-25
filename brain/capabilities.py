"""Which tools the live body really implements, and the skill registry built from them.

CLAUDE.md principle 3: the Planner may only use skills the body can actually run.
The body is asked with the ``capabilities`` request (BRIDGE_PROTOCOL.md). A body
that predates it answers unknown_tool, so the brain falls back to probing every
body tool with empty args and ``probe: true``: an answer other than
not_implemented, unknown_tool or timeout means a real handler exists.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from . import protocol
from .bridge_client import BridgeClient
from .interface import BODY_TOOLS, Reason
from .jsonl_log import JsonlLogger
from .state_store import MOCK_SKILLS, SkillRegistry

# Planner/executor skills, in registry order. get_state and say are body tools but not skills.
PLANNER_SKILLS = MOCK_SKILLS
_ABSENT = {Reason.NOT_IMPLEMENTED, Reason.UNKNOWN_TOOL, Reason.TIMEOUT}


@dataclass
class Capabilities:
    tools: list[str]  # body tools that are implemented (protocol tool names only)
    source: str  # "capabilities" (the body said so) or "probe" (fallback)
    missing: dict[str, str] = field(default_factory=dict)  # body tool -> why it is not usable

    def skills(self) -> list[str]:
        return [s for s in PLANNER_SKILLS if s in self.tools]

    def registry(self) -> SkillRegistry:
        return SkillRegistry(self.skills())

    def has(self, tool: str) -> bool:
        return tool in self.tools


def discover(client: BridgeClient, log: JsonlLogger | None = None, timeout: float = 3.0) -> Capabilities:
    res = client.capabilities(timeout)
    reported = res["data"].get("tools") if res["ok"] else None
    if isinstance(reported, list):
        names = {t for t in reported if isinstance(t, str)}
        caps = Capabilities([t for t in BODY_TOOLS if t in names], "capabilities")
        caps.missing = {t: "not listed" for t in BODY_TOOLS if t not in names}
    else:
        caps = probe(client, timeout)
        caps.missing.setdefault(protocol.CAPABILITIES, str(res["reason"]))
    if log:
        log.log("capabilities", source=caps.source, tools=caps.tools, skills=caps.skills(), missing=caps.missing)
    return caps


def probe(client: BridgeClient, timeout: float = 3.0) -> Capabilities:
    """Fallback for bodies without ``capabilities``. Empty args, so a real handler should
    answer invalid_args without acting (stop and get_state take no args and are harmless)."""
    caps = Capabilities([], "probe")
    for tool in BODY_TOOLS:
        res = client.request(tool, {}, timeout, probe=True)
        if res["ok"] or res["reason"] not in _ABSENT:
            caps.tools.append(tool)
        else:
            caps.missing[tool] = res["reason"]
    return caps

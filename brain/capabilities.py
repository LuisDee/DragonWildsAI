"""Which tools the live body really implements, and the skill registry built from them.

CLAUDE.md principle 3: the Planner may only use skills the body can actually run.
The body is asked with the ``capabilities`` request (BRIDGE_PROTOCOL.md). A body
that predates it answers unknown_tool, so the brain falls back to probing every
body tool with empty args and ``probe: true``: an answer other than
not_implemented, unknown_tool or timeout means a real handler exists.

**Capability manifest** (streamline plan step 2; BRIDGE_PROTOCOL.md "Capability manifest"): a body
may also publish ``data.manifest`` = one entry per implemented tool {name, description, args (JSON
Schema), kind, llm, moves, priority, preconditions, duration_s, timeout_s, reasons, ground,
detail_is_speech} and ``data.aliases`` {legacy name: tool}. Then the LLM's tool list is built from
the manifest ONLY (``Capabilities.llm_tools`` / ``function_schema``), calls are validated against the
manifest's schema, the bridge waits each tool's ``timeout_s``, and legacy names (pickup) map to the
tool that does that job now (fetch). Precedent: MCP ``tools/list`` {name, description, inputSchema}
turned into the model's function list at connect time; MINDcraft's command table (name, description,
typed params, runAsAction timeout).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable

import jsonschema

from . import protocol
from .bridge_client import BridgeClient
from .interface import BODY_TOOLS, BRAIN_TOOLS, TOOLS, Reason, validate_args
from .jsonl_log import JsonlLogger
from .state_store import MOCK_SKILLS, SkillRegistry

# Planner/executor skills, in registry order. get_state and say are body tools but not skills.
PLANNER_SKILLS = MOCK_SKILLS
_ABSENT = {Reason.NOT_IMPLEMENTED, Reason.UNKNOWN_TOOL, Reason.TIMEOUT}

# Legacy tool -> how its args become the new tool's args (the body publishes the alias itself).
LEGACY_ARGS: dict[tuple[str, str], Callable[[dict], dict]] = {
    # pickup(target=<an id>) is interact on that id (one press picks up the stack); "nearest" has no id
    ("pickup", "interact"): lambda a: {} if a.get("target") in (None, "", "nearest") else {"target": a["target"]},
    ("pickup", "fetch"): lambda a: {k: v for k, v in {
        "target": None if a.get("target") in (None, "", "nearest") else a.get("target"),
        "item": a.get("item"), "count": a.get("limit") or a.get("count") or 1}.items() if v is not None},
}


# Prompt budget (speed plan 2.2: <= 8k tokens): the tool block is in the cached prefix but still costs
# latency. Bodies should keep descriptions short; this caps whatever they publish (at a sentence end).
DESC_CHARS, ARG_CHARS = 360, 140


def _cap(text: str, n: int) -> str:
    if len(text) <= n:
        return text
    cut = text[:n]
    end = max(cut.rfind(". "), cut.rfind("; "))
    return (cut[: end + 1] if end > n // 2 else cut.rsplit(" ", 1)[0] + "…").strip()


def _cap_args(schema: dict) -> dict:
    out = dict(schema)
    props = schema.get("properties")
    if isinstance(props, dict):
        out["properties"] = {}
        for k, p in props.items():
            if isinstance(p, dict) and isinstance(p.get("description"), str):
                p = {**p, "description": _cap(p["description"], ARG_CHARS)}
            out["properties"][k] = p
    return out


class ManifestError(ValueError):
    """A call's args do not satisfy the body's published schema."""


@dataclass
class Capabilities:
    tools: list[str]  # body tools that are implemented (protocol tool names only)
    source: str  # "capabilities" (the body said so) or "probe" (fallback)
    missing: dict[str, str] = field(default_factory=dict)  # body tool -> why it is not usable
    extras: list[str] = field(default_factory=list)  # other names the body listed (debug tools, combat_status)
    manifest: dict[str, dict] = field(default_factory=dict)  # tool -> manifest entry (empty: old body)
    aliases: dict[str, str] = field(default_factory=dict)  # legacy name -> tool

    # ------------------------------------------------------------ skills
    def skills(self) -> list[str]:
        if self.manifest:  # the body's own list: every LLM-facing tool that acts (not reads)
            return [n for n, e in self.manifest.items()
                    if e.get("llm") and e.get("kind") in ("action", "waiter") and n not in BRAIN_TOOLS and n != "say"]
        return [s for s in PLANNER_SKILLS if s in self.tools]

    def registry(self) -> SkillRegistry:
        specs = {n: self.manifest[n] for n in self.skills() if n not in TOOLS}
        return SkillRegistry(self.skills(), specs)

    def has(self, tool: str) -> bool:
        return tool in self.tools or tool in self.manifest

    # ------------------------------------------------------------ manifest views
    @property
    def has_manifest(self) -> bool:
        return bool(self.manifest)

    def llm_tools(self) -> list[str]:
        """Tools to offer the model, in the body's order: reads first, then actions."""
        names = [n for n, e in self.manifest.items() if e.get("llm") and n not in BRAIN_TOOLS]
        return sorted(names, key=lambda n: (self.manifest[n].get("kind") != "read", names.index(n)))

    def read_tools(self) -> set[str]:
        return {n for n, e in self.manifest.items() if e.get("kind") == "read"}

    def function_schema(self, name: str) -> dict:
        """OpenAI-style function definition from the body's own description and JSON schema."""
        e = self.manifest[name]
        params = dict(e.get("args") or {"type": "object", "properties": {}})
        if not isinstance(params.get("properties"), dict):
            params["properties"] = {}
        desc = _cap(str(e.get("description") or (TOOLS[name][1] if name in TOOLS else name)), DESC_CHARS)
        params = _cap_args(params)
        return {"type": "function", "function": {"name": name, "description": desc, "parameters": params}}

    def timeouts(self) -> dict[str, float]:
        """Per-tool wait for the bridge client (the body's timeout_s, a little extra for the wire)."""
        out = {}
        for n, e in self.manifest.items():
            t = e.get("timeout_s")
            if isinstance(t, (int, float)) and t > 0:
                out[n] = float(t) + 5.0
        return out

    def speaks_detail(self, tool: str) -> bool:
        return bool(self.manifest.get(tool, {}).get("detail_is_speech"))

    def ground_spec(self, tool: str) -> dict[str, str]:
        g = self.manifest.get(tool, {}).get("ground")
        return dict(g) if isinstance(g, dict) else {}

    def resolve(self, name: str, args: dict) -> tuple[str, dict]:
        """A legacy name (pickup) -> the tool the body says does it now (fetch), with mapped args."""
        new = self.aliases.get(name)
        if not new or new not in self.manifest or name in self.manifest:
            return name, args
        mapper = LEGACY_ARGS.get((name, new))
        return new, (mapper(args) if mapper else dict(args))

    def validate(self, name: str, args: dict) -> dict:
        """Check args against the body's published schema, fill its top-level defaults, then (when the
        brain has a typed model for the tool) normalise through it. Raises ManifestError/ValueError."""
        e = self.manifest.get(name)
        clean = {k: v for k, v in (args or {}).items() if v is not None}
        if e is not None:
            schema = e.get("args") or {"type": "object"}
            try:
                jsonschema.validate(clean, schema)
            except jsonschema.ValidationError as exc:
                raise ManifestError(f"{name}: {exc.message}") from exc
            for k, p in (schema.get("properties") or {}).items():
                if k not in clean and isinstance(p, dict) and "default" in p:
                    clean[k] = p["default"]
        if name in TOOLS:  # typed defaults; unset optionals stay absent (the body's schema decides them)
            return {k: v for k, v in validate_args(name, clean).items() if v is not None}
        return clean


def _parse_manifest(raw: Any) -> dict[str, dict]:
    out: dict[str, dict] = {}
    if isinstance(raw, list):
        for e in raw:
            if isinstance(e, dict) and isinstance(e.get("name"), str):
                out[e["name"]] = e
    elif isinstance(raw, dict):  # {name: entry}
        for n, e in raw.items():
            if isinstance(e, dict):
                out[n] = {**e, "name": n}
    return out


def discover(client: BridgeClient, log: JsonlLogger | None = None, timeout: float = 3.0) -> Capabilities:
    res = client.capabilities(timeout)
    reported = res["data"].get("tools") if res["ok"] else None
    if isinstance(reported, list):
        names = {t for t in reported if isinstance(t, str)}
        caps = Capabilities([t for t in BODY_TOOLS if t in names], "capabilities")
        caps.missing = {t: "not listed" for t in BODY_TOOLS if t not in names}
        caps.extras = sorted(n for n in names if n not in BODY_TOOLS)
        caps.manifest = {n: e for n, e in _parse_manifest(res["data"].get("manifest")).items() if n in names}
        al = res["data"].get("aliases")
        caps.aliases = {k: v for k, v in al.items() if isinstance(v, str)} if isinstance(al, dict) else {}
    else:
        caps = probe(client, timeout)
        caps.missing.setdefault(protocol.CAPABILITIES, str(res["reason"]))
    if caps.manifest:
        client.timeouts.update(caps.timeouts())
        client.manifest_tools = frozenset(n for n in caps.manifest if n not in BODY_TOOLS)
    if log:
        log.log("capabilities", source=caps.source, tools=caps.tools, skills=caps.skills(), missing=caps.missing,
                manifest=sorted(caps.manifest), llm_tools=caps.llm_tools() if caps.manifest else None,
                aliases=caps.aliases)
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

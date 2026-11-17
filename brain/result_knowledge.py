"""What the brain's own knowledge says about where a thing is found, added to a gather or explore result that
failed because the thing was not found (live 2026-11-17, job "thirty copper ore in the chest at your base": two
explores of 8 legs around home, then gather "I can't find any copper within 90 m of me", and he parked the ask
asking the player for a patch; the wiki's Copper Ore Node page names three regions and he never called lookup).

Facts only, with their source: the node's location line and tool from the wiki. Nothing when the knowledge has no
node for the name. It tells him what the wiki says, never what to do (CLAUDE.md section 3)."""
from __future__ import annotations

from typing import Any

MAX_CHARS = 200
# gather's "not found" (client_mod/scripts/gather.lua): no_resource_nearby, and no_node_of_kind for a category;
# the older body (mod/body/gather.lua) gives no why. Nodes there but used up or left alone are not "not found".
GATHER_NOT_FOUND = (None, "no_resource_nearby", "no_node_of_kind")


def query_of(tool: str, args: dict | None, result: dict | None) -> str | None:
    """The thing a failed gather or explore looked for and did not find, else None."""
    if not isinstance(result, dict) or result.get("ok") is not False or result.get("reason") != "nothing_in_range":
        return None
    args = args if isinstance(args, dict) else {}
    data = result.get("data") if isinstance(result.get("data"), dict) else {}
    if tool == "gather":
        if data.get("why") not in GATHER_NOT_FOUND or data.get("used_up") or data.get("left_alone"):
            return None
        q = args.get("resource") or data.get("resource")
    elif tool == "explore":
        q = args.get("about") or data.get("about")
    else:
        return None
    return q if isinstance(q, str) and q.strip() else None


def note(knowledge: Any, tool: str, args: dict | None, result: dict | None) -> tuple[str, str] | None:
    """(query, text) for a not-found gather/explore result whose thing the knowledge places, else None."""
    q = query_of(tool, args, result)
    if q is None or knowledge is None or not hasattr(knowledge, "node_facts"):
        return None
    try:
        f = knowledge.node_facts(q)
    except Exception:  # knowledge is best effort; never break the turn on it
        return None
    if not f:
        return None
    facts = [x for x in (f.get("location") and f"found in {f['location']}", f.get("tool") and f"tool: {f['tool']}") if x]
    text = f"wiki, {f['title']}: " + "; ".join(facts)
    if len(text) > MAX_CHARS:
        text = text[: MAX_CHARS - 1].rsplit(" ", 1)[0] + "…"
    return q, text


def enrich(knowledge: Any, tool: str, args: dict | None, result: dict, log=None) -> bool:
    """Add ``result["knowledge"]`` (and log result_knowledge) when ``note`` has one. True when added."""
    got = note(knowledge, tool, args, result)
    if got is None:
        return False
    result["knowledge"] = got[1]
    if log is not None:
        log.log("result_knowledge", tool=tool, query=got[0], added=got[1])
    return True

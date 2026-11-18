"""Who this character was copied from, on a harness fork (tools/job_run.py, tools/quest_run.py; dev world only).

A test window plays a FORK of ClaudeDev: a new save with a new name and guid, copied from ClaudeDev's (or from a
checkpoint that was itself copied from him): same items, history and account. The world's base crates belong to
ClaudeDev (UOwnershipComponent.OwningCharacterGuid E71C5DC1...), and the body shows a container's owner truthfully
(client_mod/scripts/sense.lua owner_row: "ClaudeDev (another character of your account)"). So the fork refused its own
base crates in about half the trials: "the crates here are ClaudeDev's, not mine, I won't use them" (2026-11-18 runs
091424, 092356, 101804, 102841-N1-I5, voided). In real play the character IS ClaudeDev and those crates are his.

The harness knows the fork's line and says it in DW_FORKED_FROM when it starts the brain: "name:GUID[;name:GUID...]",
the characters this one was copied from (ClaudeDev first). With it, the brain (one place: BridgeClient's data filter,
set by run_live) shows a container owned by one of them as "owner: ClaudeDev (the character you were copied from for
this test: his things are yours)" with mine = true, and the Controller's persona says once that he is a test copy.
The game's own read stays in the bridge_recv rows, and the row keeps owner_name / owner_guid / same_account and gets
copied_from = true, so a grader that wants THIS character (job_run.self_owned) can still tell. Without the variable
nothing changes (real play; Shockbyte never sets it).
"""
from __future__ import annotations

import os
import re
from typing import Any, Callable

ENV = "DW_FORKED_FROM"
_HEX = re.compile(r"[^0-9A-Fa-f]")


def _guid(g: Any) -> str | None:
    s = _HEX.sub("", str(g or "")).upper()
    return s if len(s) == 32 else None


def parse(value: str | None) -> list[tuple[str, str | None]]:
    """[(name, GUID or None)] from "name:guid;name:guid" (a bare name is matched by name only)."""
    out: list[tuple[str, str | None]] = []
    for part in str(value or "").split(";"):
        name, _, guid = part.strip().partition(":")
        if name.strip():
            out.append((name.strip(), _guid(guid)))
    return out


def from_env(env: dict | None = None) -> list[tuple[str, str | None]]:
    return parse((env if env is not None else os.environ).get(ENV))


def value(chars: list[tuple[str | None, str | None]], played_guid: str | None = None) -> str:
    """The DW_FORKED_FROM value for a character copied from ``chars`` (nearest source last or first, any order):
    each named one once, never the played character itself (a checkpoint pair plays its own saved character)."""
    me, seen, parts = _guid(played_guid), set(), []
    for name, guid in chars:
        g = _guid(guid)
        if not name or (g and g == me) or (g or name) in seen:
            continue
        seen.add(g or name)
        parts.append(f"{name}:{g}" if g else str(name))
    return ";".join(parts)


def owner_words(name: str) -> str:
    return f"{name} (the character you were copied from for this test: his things are yours)"


def identity(line: list[tuple[str, str | None]]) -> str:
    """The persona's one line about himself on a fork; "" when he is not one."""
    names = [n for n, _ in line]
    if not names:
        return ""
    who = " and ".join(dict.fromkeys(names))
    return (f"This character is a test copy of {who}: copied from his save for this test, with the same items, "
            f"history and account. What {who} owns in this world (crates, chests, stations) is yours to use.")


def _match(row: dict, line: list[tuple[str, str | None]]) -> str | None:
    g, n = _guid(row.get("owner_guid")), row.get("owner_name")
    for name, guid in line:
        if (g and guid and g == guid) or (not (g and guid) and n and n == name):
            return name
    return None


def mark(data: Any, line: list[tuple[str, str | None]], ids: list | None = None) -> int:
    """Reword, in place, every owner read in ``data`` (any depth) that names a character of ``line``; the count.
    ``ids``: each reworded row's id (or container) is appended to it."""
    if not line:
        return 0
    n = 0
    stack = [data]
    while stack:
        x = stack.pop()
        if isinstance(x, dict):
            if ("owner_guid" in x or "owner_name" in x) and x.get("mine") is not True and x.get("owner") != "yours":
                name = _match(x, line)
                if name:
                    x["owner"], x["mine"], x["copied_from"] = owner_words(name), True, True
                    n += 1
                    if ids is not None:
                        ids.append(x.get("id") or x.get("container") or x.get("name"))
            stack.extend(v for v in x.values() if isinstance(v, (dict, list)))
        elif isinstance(x, list):
            stack.extend(v for v in x if isinstance(v, (dict, list)))
    return n


def data_filter(line: list[tuple[str, str | None]], log: Any = None) -> Callable[[dict], int] | None:
    """BridgeClient.data_filter for this line, or None (not a fork). With ``log`` (a JsonlLogger): one
    ``fork_owner_shown`` row the first time each container is shown as his (tools.unseen's signature)."""
    if not line:
        return None
    logged: set = set()

    def run(data: dict) -> int:
        ids: list = []
        n = mark(data, line, ids)
        new = [i for i in dict.fromkeys(ids) if i not in logged]
        if new and log is not None:
            logged.update(new)
            log.log("fork_owner_shown", ids=new, line=[name for name, _ in line])
        return n
    return run

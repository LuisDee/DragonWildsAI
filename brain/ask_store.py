"""The open ask on disk: it survives a brain restart (goal item 1 of docs/GOAL-2026-11-17-long-jobs.md).

Before this the ask lived only in memory (``Agent._open_request``): run 20261118-021010-N1-I5 killed the brain 4 s into
a gather for "fill the chest", and the new brain knew no ask (it boiled water instead).

One record per world, ``<state>/worlds/<world guid>/open_ask.json`` (beside progress.jsonl and containers.json), written
atomically (``fileio.atomic_write``: temp file + os.replace) whenever the ask changes: heard, a fact kept with it, a body
call started or ended for it, parked, reopened. A closed (done) ask removes the file. At startup the agent reads it back
(``Agent.attach_ask_store``) and the first turn gets ``where_you_were``: the ask, how long ago, what the game shows now
(carried, the containers he saw inside), and a call that was running when the old brain stopped, said as unknown. Data
only: nothing here says what to do.

Prior art (search-before-building, 2026-11-18):
- LangGraph checkpointers save a run's state keyed by ``thread_id`` and resume from it; ``delete_thread`` drops all of
  a thread's checkpoints (https://docs.langchain.com/oss/python/langgraph/persistence,
  https://reference.langchain.com/python/langgraph.checkpoint/base/BaseCheckpointSaver). Here the thread is the world:
  one small record per world guid, and ``clear_world`` is its delete_thread (a harness starting a trial fresh).
- Temporal: a worker can finish an activity and crash before its result is recorded; the service has no record of the
  completion (https://docs.temporal.io/encyclopedia/activities/activity-definition,
  https://docs.temporal.io/best-practices/error-handling). Its advice is to check the external system before acting
  again. So the lost call is never replayed or assumed done: it is said as unknown, beside what the game shows now.

Harness: ``python -m brain.ask_store clear <world guid> [--state-dir DIR]`` (or ``clear_world(guid, state_root)``)
removes the world's open ask, so a trial that reuses a character name (one world guid) never meets the last trial's ask.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from . import paths, worlds
from .fileio import atomic_write, read_json

FILE = "open_ask.json"
VERSION = 1
STEPS_KEPT = 5
CONTAINERS_SHOWN = 6
LOST_CALL = "a call was running when the brain stopped; its result was not seen"
ABOUT = ("the brain stopped and started again; this is the request that was open then, as saved, and what the game "
         "shows now")


def path(world_dir: Path) -> Path:
    return Path(world_dir) / FILE


def load(world_dir: Path) -> dict | None:
    rec = read_json(path(world_dir), None)
    if not isinstance(rec, dict) or not str(rec.get("words") or "").strip() or rec.get("state") not in ("open", "parked"):
        return None
    return rec


def save(world_dir: Path, rec: dict) -> None:
    Path(world_dir).mkdir(parents=True, exist_ok=True)
    atomic_write(path(world_dir), json.dumps({"v": VERSION, **rec}, indent=1, ensure_ascii=False, default=str))


def clear(world_dir: Path) -> bool:
    """Remove the world's open ask. True when there was one."""
    p = path(world_dir)
    try:
        p.unlink()
        return True
    except FileNotFoundError:
        return False


def world_dir(guid: str, state_root: Path | None = None) -> Path:
    g = worlds.sanitize(guid)
    if not g:
        raise ValueError(f"not a usable world guid: {guid!r}")
    return Path(state_root or paths.state_dir()) / "worlds" / g


def clear_world(guid: str, state_root: Path | None = None) -> bool:
    """The harness's fresh start: the open ask of world ``guid`` (the brain's DW_WORLD_GUID, e.g. ``dev_<fork>``)
    removed. Call it with the brain stopped (a running brain writes the ask it holds again)."""
    return clear(world_dir(guid, state_root))


# ------------------------------------------------------------------ what is kept of the game at the ask

def baseline(state: dict | None) -> dict | None:
    """The part of a state read the open-ask turn compares against (open_ask.changes): bag, names, gear, quests."""
    if not isinstance(state, dict) or "inventory" not in state:
        return None
    return {k: state[k] for k in ("inventory", "inventory_items", "gear", "quests", "position") if k in state}


# ------------------------------------------------------------------ the first turn after a restart

def _name(item: str, names: dict, cat: dict) -> str:
    from .open_ask import _name as n
    return n(item, names, cat)


def _ago(t: float | None, now: float) -> int | None:
    return None if not isinstance(t, (int, float)) else max(0, round(now - t))


def carried(state: dict | None, cat: dict | None = None, limit: int = 30) -> dict | str:
    from .open_ask import _names_of
    inv = (state or {}).get("inventory")
    if not isinstance(inv, dict):
        return "unknown: no state read now"
    names = _names_of(state)
    rows = sorted(((k, int(v)) for k, v in inv.items() if isinstance(v, (int, float)) and v), key=lambda kv: -kv[1])
    return {_name(k, names, cat or {}): v for k, v in rows[:limit]} or "nothing"


def containers_seen(snapshot: dict | None, now: float, cat: dict | None = None,
                    limit: int = CONTAINERS_SHOWN) -> list[dict]:
    """The containers he saw inside (brain/stash.py ``containers.json``), newest first: what each held when he saw it."""
    rows = [r for r in (snapshot or {}).values() if isinstance(r, dict) and r.get("items")]
    rows.sort(key=lambda r: -float(r.get("t") or 0))
    out = []
    for r in rows[:limit]:
        p = r.get("position") or []
        at = f" at ({p[0]:.0f},{p[1]:.0f})" if isinstance(p, list) and len(p) >= 2 else ""
        out.append({"container": f"{'your' if r.get('mine') else 'the'} {r.get('name') or 'container'}{at}",
                    "items": {_name(k, {}, cat or {}): v for k, v in sorted(r["items"].items())},
                    "seen_s_ago": _ago(r.get("t"), now)})
    return out


def where_you_were(rec: dict, now: float, state: dict | None, containers: dict | None = None,
                   cat: dict | None = None) -> dict:
    """The situation the first turn after a restart decides on: the saved ask and the game now, as data."""
    from .open_ask import changes, readable
    ask = {"player": rec.get("player"), "words": rec.get("words"), "asked_s_ago": _ago(rec.get("asked_unix"), now),
           "state": rec.get("state")}
    if rec.get("state") == "parked" and rec.get("park_reason"):
        ask["park_reason"] = rec["park_reason"]
    # when the record was last written (it is written on change, so the brain may have run on after it)
    out: dict = {"open_request": ask, "record_saved_s_ago": _ago(rec.get("saved_unix"), now)}
    if rec.get("goal"):
        out["goal_running_for_it"] = rec["goal"]
    facts = [f"{f.get('source')}, {_ago(f.get('t_unix'), now)} s ago: {f.get('text')}" if f.get("t_unix") else
             f"{f.get('source')}: {f.get('text')}" for f in rec.get("facts") or [] if isinstance(f, dict)]
    if facts:
        out["known_facts"] = facts
    steps = [{**{k: v for k, v in s.items() if k != "t_unix"}, "s_ago": _ago(s.get("t_unix"), now)}
             for s in rec.get("steps") or [] if isinstance(s, dict)]
    if steps:
        out["last_steps"] = steps
    fl = rec.get("in_flight")
    if isinstance(fl, dict) and fl.get("tool"):
        out["call_running_when_stopped"] = {"tool": fl["tool"], "args": fl.get("args") or {},
                                            "started_s_ago": _ago(fl.get("t_unix"), now), "result": LOST_CALL}
    game = {"carried": carried(state, cat)}
    if rec.get("baseline") and readable(state):
        game["changed_since_asked"] = changes(rec["baseline"], state, cat)
    seen = containers_seen(containers, now, cat)
    game["containers_seen"] = seen or "none remembered"
    out["game_now"] = game
    return {"type": "brain_restarted", "about": ABOUT, "where_you_were": out}


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m brain.ask_store", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("clear", "show"):
        p = sub.add_parser(name)
        p.add_argument("world", help="the world guid (DW_WORLD_GUID, e.g. dev_<fork name>)")
        p.add_argument("--state-dir", default=None, help="state root (default: DW_STATE_DIR or logs/state)")
    a = ap.parse_args(argv)
    d = world_dir(a.world, Path(a.state_dir) if a.state_dir else None)
    if a.cmd == "clear":
        print(f"{'cleared' if clear(d) else 'no open ask in'} {path(d)}")
    else:
        print(json.dumps(load(d), indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())

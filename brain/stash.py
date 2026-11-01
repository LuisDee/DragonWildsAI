"""Containers he has seen inside, per world: what each crate or chest held when he last opened it.

Every take, store or inspect result that names a container and lists its contents is recorded as
``{container id: {name, position, mine, items: {item id: count}, t}}``. The record lives in the world's
state folder as ``containers.json``. Item ids come from the item catalog and recipe names (the body
reports display names such as "2 Ash Logs").

The position comes from the result itself (inspect) or from the last state that showed that container
(``interactables`` / ``structures``). The record is what he SAW: someone else may have emptied the crate since.
``labels()`` is the form ``brain/gear_plan.py`` takes as ``stash``:
``{"your Crate at (169,1888)": [item ids]}``.

Graves are left out: ``graves_remembered`` already holds them.
"""
from __future__ import annotations

import re
import threading
import time
from pathlib import Path
from typing import Any, Callable

from .fileio import atomic_write, read_json

CONTAINER_TOOLS = ("take", "store", "inspect", "open")
_COUNTED = re.compile(r"^\s*(\d+)\s*x?\s+(.+?)\s*$")


def _parse(entry: Any) -> tuple[str | None, str | None, int]:
    """(item id or None, display name or None, count) from {"name","item","count"} or "2 Ash Logs"."""
    if isinstance(entry, dict):
        return entry.get("item"), entry.get("name"), int(entry.get("count") or 1)
    s = str(entry)
    m = _COUNTED.match(s)
    return (None, m.group(2), int(m.group(1))) if m else (None, s.strip(), 1)


def _item_id(name: str | None) -> str | None:
    if not name:
        return None
    from . import gear_plan, item_stats  # lazy: item and recipe data load on first use
    return gear_plan._id_of(name, item_stats.catalog())


class Stash:
    def __init__(self, path: str | Path, clock: Callable[[], float] = time.time):
        self.path = Path(path)
        self.clock = clock
        data = read_json(self.path, {})
        self._seen: dict[str, dict] = data if isinstance(data, dict) else {}
        self._where: dict[str, tuple[list, bool]] = {}  # container id -> (position, mine) from the last state
        self._lock = threading.Lock()

    # ------------------------------------------------------------------ feeds

    def observe_state(self, data: dict) -> None:
        """Remember where the containers in sight are, and put what he saw inside them on the state."""
        for key in ("interactables", "structures"):
            for e in data.get(key) or []:
                if isinstance(e, dict) and e.get("id") and isinstance(e.get("position"), list):
                    self._where[str(e["id"])] = (e["position"], bool(e.get("mine")))
        data["containers_remembered"] = self.labels()

    def observe_result(self, tool: str, args: dict | None, res: dict) -> bool:
        """Record a container's contents from one tool result. True when something was recorded."""
        if tool not in CONTAINER_TOOLS or not isinstance(res, dict):
            return False
        d = res.get("data") if isinstance(res.get("data"), dict) else {}
        contents = d.get("contents")
        cid = d.get("container") or (d.get("id") if tool == "inspect" else None)
        if not cid or not isinstance(contents, list) or "Gravestone" in str(cid):
            return False
        items: dict[str, int] = {}
        for entry in contents:
            iid, name, n = _parse(entry)
            iid = iid or _item_id(name)
            if iid:
                items[iid] = items.get(iid, 0) + n
        pos, mine = self._where.get(str(cid), (None, False))
        if isinstance(d.get("position"), list):
            pos = d["position"]
        name = d.get("container_name") or d.get("name") or re.sub(r"^BP_(BaseBuilding_)?|_C_\d+$", "", str(cid))
        with self._lock:
            prev = self._seen.get(str(cid)) or {}
            self._seen[str(cid)] = {"name": name, "position": pos or prev.get("position"),
                                    "mine": mine or bool(d.get("mine")) or bool(prev.get("mine")),
                                    "items": items, "t": round(self.clock(), 1)}
            try:
                atomic_write(self.path, _dumps(self._seen))
            except OSError:
                pass  # memory is best effort
        return True

    # ------------------------------------------------------------------ reads

    def labels(self) -> dict[str, list[str]]:
        """{"your Crate at (169,1888)": [item ids]} for every container he saw something in."""
        out: dict[str, list[str]] = {}
        with self._lock:
            rows = list(self._seen.values())
        for r in rows:
            if not r.get("items"):
                continue
            p = r.get("position") or []
            at = f" at ({p[0]:.0f},{p[1]:.0f})" if len(p) >= 2 else ""
            label = f"{'your' if r.get('mine') else 'the'} {r.get('name') or 'container'}{at}"
            out.setdefault(label, []).extend(sorted(r["items"]))
        return out

    def snapshot(self) -> dict:
        with self._lock:
            return {k: dict(v) for k, v in self._seen.items()}


def _dumps(obj: Any) -> str:
    import json
    return json.dumps(obj, indent=1, sort_keys=True)

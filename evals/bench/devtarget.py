"""The DEV target (design §7): Claude's real client on the local dev server, judged by the harness's own probes.

* probe: client_mod/commands/bench_probe.lua through the DWClient runner (read-only; verified 2026-10-25).
* referee: mod/bench/referee.lua on the dev server (read-only polling; verified item_change, damage, death), tailed from
  logs/bench/referee.jsonl. Only REFEREE_SUPPORTS kinds count; others evaluate null.
* fixtures: mod/bench/fixtures.lua through the server bridge's debug_run (dev only): grant / grant_runes (AddItemByData
  with a copied live tag container), unlock (ProgressComponent:UnlockSpells), spawn (SpawnActor). Verified live.
* guards (review finding 13): before every setup call and every brain action the client must be on a LOOPBACK /
  this-VM server that is not a forbidden target (client_forbid_targets.txt: shockbyte), no other player may be on the
  dev server, and the live brain (run_live) must not be running. A failed guard raises observer.Abort.
Nothing here runs without main's go-ahead for that run; the harness never touches Shockbyte.
"""
from __future__ import annotations

import json
import re
import socket
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from .hashes import ROOT
from .observer import Abort
from .serverlog import ServerLogReferee, merge

REFEREE_LOG = ROOT / "logs" / "bench" / "referee.jsonl"
RAISE_ROUNDS = 6  # raise_skills: each round closes ~90% of the XP gap (dev, 2026-10-26)
SETUP_LOG = ROOT / "logs" / "bench" / "fixture_setup.jsonl"  # every fixture call on dev, with its purpose (main 2026-10-26)
PROBE_CMD = ROOT / "client_mod" / "commands" / "bench_probe.lua"
# verified kinds (DISCOVERIES 2026-10-25/26): damage carries by + damage_type (v1.1 hooks), deaths by, telegraphs;
# defended events carry `how` only for dodges seen with the evade tag / parry / block hooks (else a gap); teleport is
# polled (no `via` yet -> a gap for teleports{via})
REFEREE_SUPPORTS = frozenset({"item_change", "damage", "death", "telegraph", "defended", "teleport", "spell_actor",
                              "spell_state"})
RECIPES_GLOB = "recipes_*.json"
SPELLS_GLOB = "spells_*.json"


def _newest(glob: str) -> dict:
    f = sorted((ROOT / "data").glob(glob))
    return json.loads(f[-1].read_text(encoding="utf-8")) if f else {}


def item_path(item_id: str) -> str | None:
    """The asset path for an item id, from the catalogs (recipes items, then the equipment catalog)."""
    for glob in (RECIPES_GLOB, "items_*.json"):
        rec = (_newest(glob).get("items") or {}).get(item_id)
        if rec and rec.get("path"):
            return rec["path"]
    return None


def spell_path(spell_id: str) -> str | None:
    rec = (_newest(SPELLS_GLOB).get("spells") or {}).get(spell_id)
    return (rec or {}).get("path")


def spell_actor_classes() -> list[str]:
    """Short class names of every actor a spell spawns (SpawnActor / UtilityMagic modules in the spell data)."""
    out: set[str] = set()
    for sp in (_newest(SPELLS_GLOB).get("spells") or {}).values():
        for m in sp.get("modules") or []:
            path = m.get("actor_class") or m.get("utility_spell_class")
            if path:
                out.add(str(path).rsplit(".", 1)[-1])
    try:  # view actors a spell switches the camera to (Eye of Oculus' BP_OculusCamera_C): short-lived, so polled too
        eff = json.loads((ROOT / "data" / "spell_effects.json").read_text(encoding="utf-8"))
        for sp in (eff.get("spells") or eff).values():
            for e in ((sp or {}).get("proof") or {}).get("effect") or []:
                if e.get("kind") == "view_target" and e.get("class"):
                    out.add(str(e["class"]))
    except (OSError, ValueError, AttributeError):
        pass
    return sorted(out)


def normalise_probe(p: dict) -> dict:
    """Lua empty tables encode as [] - dict fields come back as lists when empty."""
    out = dict(p)
    for k in ("cooldowns", "inventory", "skills", "vitals"):
        if isinstance(out.get(k), list):
            out[k] = {}
    return out


def is_loopback_or_local(host: str) -> bool:
    if host in ("127.0.0.1", "localhost", "::1"):
        return True
    try:
        mine = {a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None)}
    except OSError:
        mine = set()
    return host in mine


@dataclass
class DevTarget:
    """Glue for one dev run. Callables are injected so tests can fake every side effect."""
    character_guid: str
    client_cmd: Callable[[Path, str, dict | None, float], dict | None]
    server_debug: Callable[[dict], dict]  # debug_run args -> reply
    joined: Callable[[], str | None]  # "host:port" of the client's server
    forbidden: Callable[[], list[str]]  # addresses of forbidden targets (Shockbyte)
    brain_running: Callable[[], bool]
    referee_log: Path = REFEREE_LOG
    _ref_off: int = 0
    setup_log: list[dict] = field(default_factory=list)
    server_log: ServerLogReferee = field(default_factory=ServerLogReferee)  # server-authoritative dodges (serverlog.py)

    # ---------------------------------------------------------------- guards
    def guard(self, tool: str = "", args: dict | None = None) -> None:
        j = self.joined() or ""
        host = j.rsplit(":", 1)[0] if ":" in j else j
        if not j:
            raise Abort("cannot tell which server the client is on")
        if j in self.forbidden() or host in [f.rsplit(":", 1)[0] for f in self.forbidden()]:
            raise Abort(f"client is on a forbidden server ({j})")
        if not is_loopback_or_local(host):
            raise Abort(f"client is on {j}, not the local dev server")
        if self.brain_running():
            raise Abort("the live brain (run_live) is running: two brains on one pawn")

    # ---------------------------------------------------------------- evidence
    def probe(self) -> dict:
        r = self.client_cmd(PROBE_CMD, "bench_probe", {}, 30.0)
        res = (r or {}).get("result") or {}
        if not res.get("ok"):
            raise Abort(f"probe failed: {(r or {}).get('error') or res.get('error') or 'no answer'}")
        return normalise_probe(res["probe"])

    def referee_start(self) -> None:
        self.referee_log.parent.mkdir(parents=True, exist_ok=True)
        self._ref_off = self.referee_log.stat().st_size if self.referee_log.exists() else 0
        r = self.server_debug({"part": "referee", "action": "start", "watch": "ClaudeDev",
                               "spell_actor_classes": spell_actor_classes()})
        res = (r.get("data") or {}).get("result") or {}
        if not res.get("ok"):
            raise Abort(f"referee did not start: {r}")
        self.server_log.start(res.get("pawn"))  # no pawn name (older referee): the hook events stay the only source

    def referee_stop(self) -> None:
        self.server_debug({"part": "referee", "action": "stop"})

    def referee_events(self) -> list[dict]:
        """New referee lines since the last call, in the leaves' shape (`self` = the benchmark character)."""
        if not self.referee_log.exists():
            return merge([], self.server_log.read(), self.server_log.active)
        with open(self.referee_log, "rb") as f:
            f.seek(self._ref_off)
            data = f.read()
            self._ref_off = f.tell()
        out = []
        for line in data.decode("utf-8", "replace").splitlines():
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("kind") in REFEREE_SUPPORTS:
                out.append(e)
        return merge(out, self.server_log.read(), self.server_log.active)

    # ---------------------------------------------------------------- fixtures (harness only; dev only)
    def setup(self, verb: str, purpose: str = "case setup", **a) -> dict:
        self.guard("setup", a)
        args: dict[str, Any] = {"part": "fixtures", "verb": verb, "character_guid": self.character_guid}
        if verb == "grant":
            args.update(path=item_path(a["item"]), count=int(a.get("count", 1)))
        elif verb == "grant_runes":
            args["items"] = [{"path": item_path(r if r.startswith("ITEM_") else f"ITEM_Rune_{r}"), "count": int(n)}
                             for r, n in (a.get("runes") or {}).items()]
        elif verb == "unlock":
            args["paths"] = [spell_path(a["spell"])]
        elif verb == "spawn":
            args.update({"class": a.get("class") or a.get("kind_id"), "offset_m": a.get("offset_m") or a.get("at") or [5, 0, 0]})
        else:
            args.update(a)
        r = self.server_debug(args)
        res = (r.get("data") or {}).get("result") or {}
        for _ in range(RAISE_ROUNDS if verb == "raise_skills" else 0):  # one step per call: the XP lands a tick later
            if res.get("ok") or not res.get("pending") or any((x or {}).get("error") for x in (res.get("results") or {}).values()):
                break
            time.sleep(1.5)
            res = ((self.server_debug(args).get("data") or {}).get("result")) or {}
        row = {"t": time.time(), "verb": verb, "args": a, "purpose": purpose, "ok": bool(res.get("ok")), "error": res.get("error")}
        self.setup_log.append(row)
        try:
            SETUP_LOG.parent.mkdir(parents=True, exist_ok=True)
            with open(SETUP_LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps(row, default=str) + "\n")
        except OSError:
            pass
        if not res.get("ok"):
            raise Abort(f"fixture {verb} failed: {res.get('error')}")
        return res


def forbidden_addresses(secrets: Path = ROOT / "client_io" / "secrets", state: Path = ROOT / "logs" / "state") -> list[str]:
    """host:port of every forbidden target (logs/state/client_forbid_targets.txt names, resolved from secrets)."""
    names = []
    f = state / "client_forbid_targets.txt"
    if f.exists():
        names = [x.strip() for x in f.read_text(encoding="utf-8-sig").splitlines() if x.strip() and not x.startswith("#")]
    out = []
    for n in names:
        p = secrets / ("server.txt" if n == "shockbyte" else f"server_{n}.txt")
        if p.exists():
            line = p.read_text(encoding="utf-8-sig").splitlines()[:1]
            if line and line[0].strip():
                out.append(line[0].strip())
    return out


def joined_from_game_log(path: Path | None = None) -> str | None:
    """The client's server from its game log: the last 'RemoteAddr: host:port' of a join (LoadMap lines may omit the
    port on a loopback join)."""
    from tools.scenario_run import GAME_LOG
    path = path or GAME_LOG
    last = None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "SendInitialJoin" in line and "RemoteAddr:" in line:
                    last = line
    except OSError:
        return None
    m = re.search(r"RemoteAddr: ([0-9A-Za-z.\-]+:\d+)", last or "")
    return m.group(1) if m else None

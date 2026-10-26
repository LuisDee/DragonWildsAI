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
RAISE_ROUNDS = 12  # raise_skills: round 1 adds a quarter of the gap, later rounds ~97% by the measured ratio
SETUP_LOG = ROOT / "logs" / "bench" / "fixture_setup.jsonl"  # every fixture call on dev, with its purpose (main 2026-10-26)
PROBE_CMD = ROOT / "client_mod" / "commands" / "bench_probe.lua"
# verified kinds (DISCOVERIES 2026-10-25/26): damage carries by + damage_type (v1.1 hooks), deaths by, telegraphs;
# defended events carry `how` only for dodges seen with the evade tag / parry / block hooks (else a gap); teleport is
# polled (no `via` yet -> a gap for teleports{via})
REFEREE_SUPPORTS = frozenset({"item_change", "damage", "death", "telegraph", "defended", "teleport", "spell_actor",
                              "spell_state", "target_effect", "dash"})
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
    try:  # hypothesis actors (evals/bench/spell_observables.json); class_contains polls its base class
        hyp = json.loads((ROOT / "evals" / "bench" / "spell_observables.json").read_text(encoding="utf-8"))
        for h in (hyp.get("spells") or {}).values():
            for e in h.get("effects") or []:
                if e.get("kind") == "spell_actor" and e.get("class"):
                    out.add(str(e["class"]))
                elif e.get("kind") == "spell_actor" and e.get("class_contains") == "BP_DivineRock_":
                    out.add("DivineRock")  # ADivineRock: FindAllOf returns its BP_DivineRock_<Ore> subclasses
    except (OSError, ValueError, AttributeError):
        pass
    try:  # view actors a spell switches the camera to (Eye of Oculus' BP_OculusCamera_C): short-lived, so polled too
        eff = json.loads((ROOT / "data" / "spell_effects.json").read_text(encoding="utf-8"))
        for sp in (eff.get("spells") or eff).values():
            for e in ((sp or {}).get("proof") or {}).get("effect") or []:
                if e.get("kind") == "view_target" and e.get("class"):
                    out.add(str(e["class"]))
    except (OSError, ValueError, AttributeError):
        pass
    return sorted(out)


def spawn_class_paths() -> dict:
    try:
        return json.loads((ROOT / "evals" / "bench" / "spawn_classes.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def dev_places() -> dict:
    """Known dev spots by need (measured on dev; a dev fact, not companion knowledge)."""
    try:
        return json.loads((ROOT / "evals" / "bench" / "dev_places.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


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
    body_call: Callable[[str, dict], dict] | None = None  # the body's own tool over the client debug channel (setup)
    character_name: str = "ClaudeDev"  # the referee watches this name; devchar.CharacterSwitch changes it per case
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
        r = self.server_debug({"part": "referee", "action": "start", "watch": self.character_name,
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

    # ---------------------------------------------------------------- setup through the body / a known place
    def _client_setup(self, verb: str, purpose: str, a: dict) -> dict:
        """hold = the body's verified `equip` tool on an item he already carries (granted just before);
        scene = teleport to a known dev place for what the case needs (evals/bench/dev_places.json)."""
        if verb == "claim_bed":
            return self._claim_bed(purpose, a)
        if verb == "after_cast_move":  # Recall: armed now, run by harness_after() right after his cast of that spell
            self.pending_after_cast = {"spell": a.get("spell"), "offset_m": a.get("offset_m") or [8, 0, 0],
                                       "wait_s": float(a.get("wait_s", 6.0))}
            res = {"ok": True, "armed": self.pending_after_cast}
            self._log_setup(verb, a, purpose, res)
            return res
        if verb == "hold":
            if self.body_call is None:
                res = {"ok": False, "error": "no body channel for hold"}
            else:
                r = self.body_call("equip", {"item": a.get("item")}) or {}
                res = {"ok": bool(r.get("ok")), "error": r.get("reason"), "data": r.get("data")}
        else:
            place = (dev_places().get(str(a.get("needs"))) or {})
            if not place.get("at"):
                res = {"ok": False, "error": f"no dev place for {a.get('needs')!r} (evals/bench/dev_places.json)"}
            else:
                return self.setup("teleport", purpose=f"{purpose} [{a.get('needs')}]", at=place["at"])
        self._log_setup(verb, a, purpose, res)
        if not res.get("ok"):
            raise Abort(f"fixture {verb} failed: {res.get('error')}")
        return res

    def beds(self) -> list[dict]:
        r = self.server_debug({"part": "fixtures", "action": "beds", "character_guid": self.character_guid})
        return ((r.get("data") or {}).get("result") or {}).get("beds") or []

    def _claim_bed(self, purpose: str, a: dict) -> dict:
        """Home Teleport needs a bed he has claimed. The claim is the game's own path: stand at a bed (teleport
        fixture) and use the body's `interact` on it (primary, then the secondary option); the dev server's
        UBedComponent:IsClaimedByPlayer is the proof. Then he is put `away_m` from it so the spell has to move him."""
        def fail(why: str) -> dict:
            res = {"ok": False, "error": why}
            self._log_setup("claim_bed", a, purpose, res)
            raise Abort(f"fixture claim_bed failed: {why}")
        beds = self.beds()
        bed = next((b for b in beds if b.get("mine")), None) or next((b for b in beds if not b.get("claimed")), None)
        if bed is None:
            return fail("no bed he can claim on the dev world (build or place one first)")
        if not bed.get("mine"):
            if self.body_call is None:
                return fail("no body channel for interact")
            x, y, z = bed["position"]
            self.setup("teleport", purpose=f"{purpose} [stand at the bed]", at=[x + 1.5, y, z + 0.5])
            look = self.body_call("look", {"about": "bed", "radius": 6}) or {}
            things = ((look.get("data") or {}).get("things") or [])
            tid = next((t.get("id") for t in things if "bed" in str(t.get("name") or t.get("class") or "").lower()), None)
            if not tid:
                return fail("the body sees no bed next to it")
            for secondary in (False, True):
                self.body_call("interact", {"target": tid, "secondary": secondary})
                time.sleep(1.0)
                if any(b.get("mine") for b in self.beds()):
                    break
            else:
                return fail("interact did not claim the bed (no claim option?)")
        away = float(a.get("away_m", 40))
        x, y, z = bed["position"]
        self.setup("teleport", purpose=f"{purpose} [{away:g} m from his bed]", at=[x + away, y, z + 1.0])
        res = {"ok": True, "bed": bed.get("id"), "away_m": away}
        self._log_setup("claim_bed", a, purpose, res)
        return res

    def harness_after(self, tool: str, args: dict, reply: dict, before: dict) -> dict | None:
        """Harness motion inside a case (Recall): right after his cast of the armed spell, WALK him (the body's own
        go_to, never a position write) offset_m away, then wait out the spell; the observation records where he
        started and where the walk took him."""
        p = getattr(self, "pending_after_cast", None)
        if not p or tool != "cast" or self.body_call is None:
            return None
        if str((args or {}).get("spell") or "").lower() not in {str(p.get("spell") or "").lower(), str(p.get("name") or "").lower()}:
            return None
        self.pending_after_cast = None
        start = (before or {}).get("position")
        if not start:
            return {"after_cast_move": "no start position"}
        off = p["offset_m"]
        goal = [start[0] + off[0], start[1] + off[1], start[2] + (off[2] if len(off) > 2 else 0)]
        self.body_call("go_to", {"target": goal})
        mid = (self.probe() or {}).get("position")
        time.sleep(p["wait_s"])
        return {"after_cast_move": {"start": start, "goal": goal, "mid": mid}}

    def _log_setup(self, verb: str, a: dict, purpose: str, res: dict) -> None:
        row = {"t": time.time(), "verb": verb, "args": a, "purpose": purpose, "ok": bool(res.get("ok")), "error": res.get("error")}
        self.setup_log.append(row)
        try:
            SETUP_LOG.parent.mkdir(parents=True, exist_ok=True)
            with open(SETUP_LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps(row, default=str) + "\n")
        except OSError:
            pass

    # ---------------------------------------------------------------- fixtures (harness only; dev only)
    def setup(self, verb: str, purpose: str = "case setup", **a) -> dict:
        self.guard("setup", a)
        if verb in ("hold", "scene", "claim_bed", "after_cast_move"):
            return self._client_setup(verb, purpose, a)
        args: dict[str, Any] = {"part": "fixtures", "verb": verb, "character_guid": self.character_guid}
        if verb == "grant":
            args.update(path=item_path(a["item"]), count=int(a.get("count", 1)))
        elif verb == "grant_runes":
            args["items"] = [{"path": item_path(r if r.startswith("ITEM_") else f"ITEM_Rune_{r}"), "count": int(n)}
                             for r, n in (a.get("runes") or {}).items()]
        elif verb == "unlock":
            args["paths"] = [spell_path(a["spell"])]
        elif verb == "spawn":
            cls = a.get("class") or a.get("kind_id")
            args.update({"class": cls, "offset_m": a.get("offset_m") or a.get("at") or [5, 0, 0]})
            if spawn_class_paths().get(str(cls)):
                args["class_path"] = spawn_class_paths()[str(cls)]  # loaded first if nothing has loaded it yet
        else:
            args.update(a)
        r = self.server_debug(args)
        res = (r.get("data") or {}).get("result") or {}
        for _ in range(RAISE_ROUNDS if verb == "raise_skills" else 0):  # one step per call: the XP lands a tick later
            if res.get("ok") or not res.get("pending") or any((x or {}).get("error") for x in (res.get("results") or {}).values()):
                break
            time.sleep(1.5)
            res = ((self.server_debug(args).get("data") or {}).get("result")) or {}
        if verb == "raise_skills" and a.get("except") and a["except"] in (res.get("results") or {}):
            res = {"ok": False, "error": f"raise_skills touched the target skill {a['except']}"}  # main's condition
        self._log_setup(verb, a, purpose, res)
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

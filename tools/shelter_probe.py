"""Shelter probe on the DEV world: the station shelter read (crafting.lua W.shelter, 4e35601) tried on the live client
before a window, body only (no brain, no model calls, API spend 0). A harness tool for the main session.

  .venv\\Scripts\\python.exe -m tools.shelter_probe read --confirm                            # where ClaudeDev stands, 30 m
  .venv\\Scripts\\python.exe -m tools.shelter_probe read --teleport-to roofed_base --confirm  # at his roofed house first
  .venv\\Scripts\\python.exe -m tools.shelter_probe read                                      # no --confirm: says what it would do

Why: W.shelter makes new engine calls (the BuildingShelterComponent's property reads RoofRays, ShelterRays,
SweepRayDistance, SweepRayThickness, ValidityPercentage, bIncludeNonBuildingPartActors, RequiresRoofText;
FindAllOf("BuildingShelterComponent") and GetOwner; the build line trace per ray). pcall cannot catch a native crash,
so they are tried here, offline, before a window runs them (CLAUDE.md section 4).

read  One bridge call `shelter_read {radius}` (crafting.lua: read-only, each station its own pcall): every station
      within --radius from the census and from FindAllOf("BuildingShelterComponent") -> GetOwner, with the
      component's raw values and the two checks (roof yes/partly/no with ray hits, side hits % vs the needed %, the
      open sides by compass). Then a `ping`, and the client's UE4SS crash dumps counted before and after. The row
      (logs/evals/shelter_probe.jsonl) carries per station: id, name, rule, roof, side %, needed %, open sides,
      sheltered, the raw property values (ray counts, distance, thickness, threshold, any-actor flag, texts); the full
      reply (every ray vector) goes to logs/evals/shelter_probe/<run>_read.json; client.log lines of the read
      ("crafting: shelter ...", errors) are captured. No shelter-requiring station in range is said, never fixed:
      the probe builds, moves (beyond --teleport-to), presses and crafts nothing.
--teleport-to <spot>  First the dev `teleport` fixture (server K2_TeleportTo, the one tools/vault_probe.py uses) to a
      named spot (SPOTS here, evals/bench/dev_places.json: roofed_base = outside his roofed house in the base world,
      BuildingPiece_124's door), wait until he stands still, then read; afterwards he is teleported back to where he
      stood (--stay keeps him there). A hostile within --hostile-m or health under --min-health after the placement
      sends him back without the read (vault_probe's abort rules).

Guards (refused = exit 2, a row with `refused`, nothing touched): --confirm given; DevTarget.guard (the local dev
server, never Shockbyte, no live brain); the client's pawn is ClaudeDev and the dev server lists exactly that one
player by GUID (never with Luis or anyone else on the dev world); the live lock ("shelter-probe"), unless the caller
holds it (DW_LIVE_OWNER).

Reading the row: a PASS is ok=true, reply_ok=true, ping_ok=true, new_dumps=0 (a station list, possibly empty, with
raw values). A CRASH is reply_ok=false and/or ping_ok=false and/or new_dumps>0 (crashed=true; the dump names in
`dumps`); the client watchdog reboots the client. reply_ok=false with ping_ok=true and no dump is a bridge refusal
(e.g. not_implemented: the client has not hot-loaded the new crafting.lua yet) - `reason` says which.

Start from a named world (rule 9) when the reading matters: `tools\\stop_server.ps1 -Hold`, `tools.world_snapshot
restore base --confirm`, `tools\\start_server.ps1`, `tools\\client_boot.ps1 -Target dev`.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from tools import vault_probe as vp

ROOT = vp.ROOT
OUT = ROOT / "logs" / "evals" / "shelter_probe.jsonl"
REPLIES = ROOT / "logs" / "evals" / "shelter_probe"
CLIENT_LOG = vp.CLIENT_LOG
CLIENT_DUMPS = Path(os.environ.get("DW_CLIENT_DUMP_DIR") or os.path.join(
    os.environ.get("DW_CLIENT_WIN64") or r"C:\Program Files (x86)\Steam\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64",
    "ue4ss"))
LOCK_OWNER = "shelter-probe"
RADIUS_M = 30.0
READ_TIMEOUT_S = 60.0
LOG_KEYS = ("crafting: shelter", "shelter_read", "BuildingShelter", "stack traceback", "error", "Error")
SHELTER_RULES = ("shelter_only", "outside_only")


def spots() -> dict[str, dict[str, Any]]:
    """The named dev-world spots (evals/bench/dev_places.json, through vault_probe.spots)."""
    return vp.spots()


def dump_names(d: Path = CLIENT_DUMPS) -> set[str]:
    try:
        return {p.name for p in d.glob("crash_*.dmp")}
    except OSError:
        return set()


# ------------------------------------------------------------------ pure readers (tested)
def station_row(s: dict) -> dict:
    """One station of the shelter_read reply, as the row keeps it: the facts and the raw values (ray lists as counts;
    the vectors stay in the replies file)."""
    sh = s.get("shelter") or {}
    raw = dict(s.get("raw") or {})
    for k in ("RoofRays", "ShelterRays"):
        if isinstance(raw.get(k), list):
            raw[k + "_n"] = len(raw.pop(k))
    return {"id": s.get("id"), "name": s.get("name"), "class": s.get("class"), "distance": s.get("distance"),
            "position": s.get("position"), "yaw": s.get("yaw"), "source": s.get("source"),
            "component": s.get("component"), "rule": s.get("rule"), "requirement": s.get("requirement"),
            "roof": sh.get("roof"), "roof_hits": sh.get("roof_hits"), "roof_n": sh.get("roof_n"),
            "side_hits": sh.get("side_hits"), "side_n": sh.get("side_n"), "side_pct": sh.get("side_pct"),
            "need_pct": sh.get("need_pct"), "open": sh.get("open"), "sides_ok": sh.get("sides_ok"),
            "sheltered": sh.get("sheltered"), "from": sh.get("from") or sh.get("roof_from"),
            "facts": s.get("facts"), "raw": raw or None, "error": s.get("error")}


def summarize(reply: dict) -> dict:
    """The shelter_read reply -> stations (row form), the shelter-requiring ones, and the reply's own errors."""
    d = vp.data(reply)
    rows = [station_row(s) for s in d.get("stations") or [] if isinstance(s, dict)]
    needing = [r for r in rows if r.get("rule") in SHELTER_RULES]
    return {"stations": rows, "shelter_stations": len(needing), "census_n": d.get("census_n"),
            "components_n": d.get("components_n"), "read_errors": d.get("errors"),
            "station_errors": [r["id"] for r in rows if r.get("error")]}


def reply_detail(reply: dict) -> str | None:
    d = reply.get("data")
    return reply.get("detail") or (d.get("detail") if isinstance(d, dict) else None)


def line(r: dict) -> str:
    """One station in a print line: name, rule, roof, side % vs needed %, open sides."""
    if r.get("rule") not in SHELTER_RULES:
        return f"{r.get('name') or r.get('id')}: {r.get('rule') or 'no shelter component'}"
    return (f"{r.get('name') or r.get('id')} {r.get('distance')} m {r.get('rule')}: roof {r.get('roof')} "
            f"{r.get('roof_hits')}/{r.get('roof_n')}, sides {r.get('side_pct')}% (needs {r.get('need_pct')}%), "
            f"open [{','.join(r.get('open') or [])}]" + (f" ERROR {r['error']}" if r.get("error") else ""))


# ------------------------------------------------------------------ the probe
@dataclass
class ShelterProbe(vp.Probe):
    """vault_probe.Probe's guard, rows and teleport; its own out file, client log keys and the read."""
    out: Path = OUT
    replies: Path = REPLIES
    client_dumps: Path = CLIENT_DUMPS
    dumps_fn: Any = None  # tests: () -> set of dump names
    radius: float = RADIUS_M
    character: str = vp.MAIN_CHARACTER
    rows: list[dict] = field(default_factory=list)

    def record(self, step: str, ok: bool | None, **kw) -> dict:
        row = {"ts": round(time.time(), 1), "run": self.run, "step": step, "ok": ok, "head": vp.head(),
               "character": self.character, "api_spend": 0, **kw}
        self.rows.append(row)
        self.out.parent.mkdir(parents=True, exist_ok=True)
        with self.out.open("a", encoding="utf-8") as f:
            f.write(json.dumps(row, default=str) + "\n")
        mark = "REFUSED" if kw.get("refused") else ("ABORT" if kw.get("aborted") else
                                                     ("CRASH" if kw.get("crashed") else ("OK" if ok else "FAIL")))
        bits = [f"{k}={kw[k]}" for k in ("refused", "aborted", "position", "reply_ok", "reason", "ping_ok", "new_dumps",
                                         "shelter_stations", "detail", "error") if kw.get(k) is not None]
        self.print_fn(f"shelter_probe {step} {mark} " + " ".join(bits)[:600])
        for r in kw.get("stations") or []:
            self.print_fn("  " + line(r))
        return row

    def req(self, tool: str, args: dict | None = None, timeout: float = 30.0) -> dict:
        try:
            r = self.cli.request(tool, args or {}, timeout=timeout)
        except Exception as exc:  # a dead client: the bridge connection fails, which the row records
            return {"ok": False, "reason": "request_error", "detail": repr(exc)[:300]}
        return r if isinstance(r, dict) else {"ok": False, "reason": repr(r)}

    def dumps(self) -> set[str]:
        return set(self.dumps_fn()) if self.dumps_fn else dump_names(self.client_dumps)

    def read(self, spot: str | None = None, stay: bool = False) -> dict:
        start = self.position()
        placed = None
        if spot:
            at = spots()[spot]["at"]
            t = self.teleport(at, f"shelter probe: stand at {spot} to read the shelter of stations near it")
            placed = {"spot": spot, "at": at, "position": t.get("position"), "ok": t.get("ok"), "fell": t.get("fell"),
                      "detail": t.get("detail")}
            st = self.state()
            why = ("fell %s m after the teleport" % t.get("drop_m")) if t.get("fell") else \
                (None if t.get("ok") else (t.get("detail") or "placement failed")) or \
                vp.abort_reason(st, (), self.hostile_m, self.min_health)
            if why:
                row = self.record("read", False, aborted=why, placed=placed)
                self.back(start, stay, f"abort: {why}")
                return row
        here = self.position()
        d0, off = self.dumps(), vp.log_size(self.client_log)
        t0 = time.monotonic()
        reply = self.req("shelter_read", {"radius": self.radius}, READ_TIMEOUT_S)
        read_s = round(time.monotonic() - t0, 2)
        ping = self.req("ping", {}, 10)
        new = sorted(self.dumps() - d0)
        lines = vp.log_lines(self.client_log, off, LOG_KEYS)
        s = summarize(reply)
        self.replies.mkdir(parents=True, exist_ok=True)
        rf = self.replies / f"{self.run}_read.json"
        rf.write_text(json.dumps({"shelter_read": reply, "ping": ping}, default=str, indent=1), encoding="utf-8")
        reply_ok, ping_ok = reply.get("ok") is True, ping.get("ok") is True
        crashed = bool(new) or not ping_ok
        detail = None
        if reply_ok and s["shelter_stations"] == 0:
            detail = (f"no shelter-requiring station within {self.radius:g} m"
                      + (f" of {spot}" if spot else "") + " (the probe builds nothing)")
        row = self.record("read", reply_ok and ping_ok and not new, radius=self.radius, placed=placed,
                          position=here, reply_ok=reply_ok, reason=None if reply_ok else reply.get("reason"),
                          reply_detail=None if reply_ok else reply_detail(reply),
                          read_s=read_s, ping_ok=ping_ok, new_dumps=len(new), dumps=new or None, crashed=crashed or None,
                          client_log=lines, detail=detail,
                          replies_file=str(rf.relative_to(ROOT)) if rf.is_relative_to(ROOT) else str(rf), **s)
        if spot and not crashed:
            self.back(start, stay, "after the read")
        return row

    def back(self, start: list[float] | None, stay: bool, why: str) -> None:
        if stay or not start:
            return
        try:
            t = self.teleport(start, f"shelter probe: back where he stood ({why})")
        except Exception as exc:  # recorded; the read's row stands
            t = {"ok": False, "detail": repr(exc)[:300]}
        self.record("back", bool(t.get("ok")), position=t.get("position"), why=why, detail=t.get("detail"))


# ------------------------------------------------------------------ live wiring
def default_probe(**kw) -> ShelterProbe:
    from evals.bench.devrun import default_dev
    from tools.chat_ladder import _debug_client
    return ShelterProbe(cli=_debug_client(), dev=default_dev(), **kw)


@contextlib.contextmanager
def lock_window(wait_s: float):
    """The live lock, unless the caller's window already holds it."""
    from tools import live_lock
    cur = live_lock.read()
    if cur and not cur["stale"] and cur["owner"] == os.environ.get("DW_LIVE_OWNER"):
        yield
        return
    with live_lock.held(LOCK_OWNER, wait_s=wait_s):
        yield


def run_read(probe: ShelterProbe, spot: str | None, stay: bool) -> int:
    try:
        probe.guard("read")
    except vp.Refused as exc:
        probe.record("read", False, refused=str(exc))
        return 2
    try:
        row = probe.read(spot, stay)
    except Exception as exc:  # harness fault: recorded
        probe.record("read", None, error=repr(exc)[:400])
        return 1
    return 0 if row.get("ok") else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("step", choices=("read",))
    ap.add_argument("--confirm", action="store_true", help="really call the client (dev world only)")
    ap.add_argument("--radius", type=float, default=RADIUS_M, help="metres round him (1-120)")
    ap.add_argument("--teleport-to", dest="spot", default=None, help="a named dev spot to stand at first (roofed_base, ...)")
    ap.add_argument("--stay", action="store_true", help="after --teleport-to, leave him there")
    ap.add_argument("--hostile-m", type=float, default=vp.HOSTILE_M)
    ap.add_argument("--min-health", type=float, default=vp.MIN_HEALTH)
    ap.add_argument("--wait", type=float, default=1800.0, help="seconds to wait for the live lock")
    a = ap.parse_args(argv)
    sp = spots()
    if a.spot and a.spot not in sp:
        ap.error(f"unknown spot {a.spot!r} (known: {', '.join(sp)})")
    if not a.confirm:
        where = (f"teleport {vp.MAIN_CHARACTER} to {a.spot} {sp[a.spot]['at']} (dev fixture), then "
                 if a.spot else f"where {vp.MAIN_CHARACTER} stands, ")
        back = "" if not a.spot else (" He stays there." if a.stay else " Then he is teleported back where he stood.")
        print(f"dry: would {where}call shelter_read radius {a.radius:g} m (read-only: the shelter checks and the "
              f"BuildingShelterComponent's raw values of every station in range), then ping and count client crash "
              f"dumps in {CLIENT_DUMPS}.{back} Body only, API spend 0, rows to {OUT}. Add --confirm (dev world only).")
        return 0
    with lock_window(a.wait):
        probe = default_probe(radius=a.radius, hostile_m=a.hostile_m, min_health=a.min_health)
        return run_read(probe, a.spot, a.stay)


if __name__ == "__main__":
    sys.exit(main())

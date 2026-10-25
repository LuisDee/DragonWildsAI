"""Automated, server-only smoke test (CLAUDE.md section 8; run after every game patch and before play).

  .venv\\Scripts\\python.exe -m tools.smoke_test                 # live checks over the bridge + offline catalog checks
  .venv\\Scripts\\python.exe -m tools.smoke_test --offline       # catalog / dependency checks only (server down)
  .venv\\Scripts\\python.exe -m tools.smoke_test --active        # also run the player checks when someone is connected
  .venv\\Scripts\\python.exe -m tools.smoke_test --json logs\\smoke.json

Exit code 0 when nothing FAILED (SKIPs do not fail), 1 otherwise.

Live checks are read-only: ping, capabilities, get_state, body_status, debug_run body_probe (a survey
that never spawns, moves or writes). Checks that need a connected player (body_spawn visible, follow,
say relay, attack) are always listed; they SKIP with a reason when nobody is connected, and also when
a player is connected but --active was not given, because they act in the world (spawn the puppet,
follow, speak, fight). The in-game yes/no confirmation of those stays with Luis (CLAUDE.md section 2).
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from tools import patch_pipeline as pp

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"
REQUIRED_TOOLS = ["ping", "get_state", "follow", "stop", "go_to", "attack", "say", "body_status", "body_spawn", "debug_run"]
STATE_KEYS = ["position", "health", "inventory", "players", "nearby_entities"]
# Spot items: (label, preferred id, predicate for the fallback search, extra check)
MIN_ITEMS, MIN_ATTACK_SETS = 100, 10


def res(name: str, status: str, detail: str = "", **extra) -> dict:
    return {"name": name, "status": status, "detail": detail, **extra}


# ------------------------------------------------------------------------------ live checks

def run_live(client, active: bool = False, timeout: float = 15.0) -> list[dict]:
    """Checks over a BridgeClient-like object (anything with ``request(tool, args, timeout)``)."""
    out: list[dict] = []

    def call(tool, args=None, t=timeout):
        t0 = time.perf_counter()
        r = client.request(tool, args or {}, timeout=t)
        return r, time.perf_counter() - t0

    r, dt = call("ping", t=5.0)
    if not r.get("ok"):
        out.append(res("ping", FAIL, f"no pong within 5 s ({r.get('reason')}): is the server up and the mod loaded?"))
        for n in ("capabilities", "get_state", "body_status", "debug_run body_probe"):
            out.append(res(n, SKIP, "bridge not answering"))
        out += player_checks_skipped("bridge not answering")
        return out
    out.append(res("ping", PASS, f"round trip {dt * 1000:.0f} ms"))

    r, _ = call("capabilities", t=5.0)
    tools = (r.get("data") or {}).get("tools") if r.get("ok") else None
    if not tools:
        out.append(res("capabilities", FAIL, f"no tool list ({r.get('reason')})"))
    else:
        missing = [t for t in REQUIRED_TOOLS if t not in tools]
        protocol = pp.parse_bridge_tools(pp.Ctx().protocol_md)["protocol"]
        todo = [t for t in protocol if t not in tools]
        out.append(res("capabilities", FAIL if missing else PASS,
                       (f"missing required tools: {missing}" if missing else f"{len(tools)} tools, all {len(REQUIRED_TOOLS)} required present")
                       + (f"; protocol tools not implemented yet (informational): {todo}" if todo else "")))

    r, _ = call("get_state")
    data = r.get("data") or {}
    state_ok = isinstance(data, dict) and all(k in data for k in STATE_KEYS)
    # companion_down just means the puppet is not spawned: the exporter itself still answered.
    if r.get("ok") or (r.get("reason") == "companion_down" and state_ok):
        out.append(res("get_state", PASS if state_ok else FAIL,
                       ("puppet up" if r.get("ok") else "puppet not spawned (companion_down), exporter answered")
                       + (f"; players={len(data.get('players') or [])}" if state_ok else f"; missing keys {[k for k in STATE_KEYS if k not in data]}")))
    else:
        out.append(res("get_state", FAIL, f"{r.get('reason')}: {json.dumps(data)[:200]}"))
    players = data.get("players") if isinstance(data, dict) and isinstance(data.get("players"), list) else []

    r, _ = call("body_status")
    out.append(res("body_status", PASS if r.get("ok") else FAIL,
                   json.dumps((r.get("data") or {}).get("puppet"))[:160] if r.get("ok") else str(r.get("reason"))))

    r, dt = call("debug_run", {"module": "body_probe", "args": {"max_names": 2, "nav_query": False}}, t=60.0)
    result = ((r.get("data") or {}).get("result")) if r.get("ok") else None
    if r.get("ok") and isinstance(result, dict) and result.get("ok") is not False:
        out.append(res("debug_run body_probe", PASS, f"{dt:.1f} s, ai_characters={result.get('ai_characters')}, players={result.get('players')}"))
    else:
        out.append(res("debug_run body_probe", FAIL, f"{r.get('reason')}: {json.dumps(r.get('data'))[:240]}"))

    if not players:
        out += player_checks_skipped("no player connected")
    elif not active:
        out += player_checks_skipped(f"{len(players)} player(s) connected but --active not given (these act in the world)")
    else:
        out += run_player_checks(call, players)
    return out


PLAYER_CHECKS = ["body_spawn (puppet appears)", "follow", "say relay", "attack"]


def player_checks_skipped(why: str) -> list[dict]:
    return [res(n, SKIP, why) for n in PLAYER_CHECKS]


def run_player_checks(call, players: list[dict]) -> list[dict]:
    out = []
    who = next((p.get("name") for p in players if p.get("name")), None)
    r, _ = call("body_spawn", t=60.0)
    out.append(res(PLAYER_CHECKS[0], PASS if r.get("ok") else FAIL,
                   (json.dumps(r.get("data"))[:140] if r.get("ok") else f"{r.get('reason')}") + "  [ask Luis: is the companion visible?]"))
    if not r.get("ok") or not who:
        return out + [res(n, SKIP, "puppet did not spawn" if not r.get("ok") else "no named player") for n in PLAYER_CHECKS[1:]]
    r, _ = call("follow", {"player": who, "distance": 3.0}, t=30.0)
    out.append(res(PLAYER_CHECKS[1], PASS if r.get("ok") else FAIL, str(r.get("reason") or "following") ))
    call("stop")
    r, _ = call("say", {"text": "smoke test: hello"})
    out.append(res(PLAYER_CHECKS[2], PASS if r.get("ok") else FAIL,
                   (str(r.get("reason")) if not r.get("ok") else "sent") + "  [ask Luis: did he see the chat line from Claude?]"))
    r, _ = call("get_state")
    hostile = [e for e in ((r.get("data") or {}).get("nearby_entities") or []) if e.get("hostile") is True and e.get("alive", True)]
    if not hostile:
        out.append(res(PLAYER_CHECKS[3], SKIP, "no hostile creature nearby"))
    else:
        r, _ = call("attack", {"target": hostile[0].get("id")}, t=60.0)
        out.append(res(PLAYER_CHECKS[3], PASS if r.get("ok") else FAIL, str(r.get("reason") or hostile[0].get("id"))))
        call("stop")
    return out


# ------------------------------------------------------------------------------ offline checks

def _first(items: dict, pred):
    return next(((k, v) for k, v in items.items() if pred(v)), (None, None))


def check_catalog(data_dir: Path, build: str | None) -> list[dict]:
    out = []
    if not build:
        return [res("catalog build", FAIL, "installed server build unknown (no appmanifest); pass --build")]
    p = data_dir / f"items_{build}.json"
    if not p.exists():
        return [res("catalog items file", FAIL, f"{p.name} missing: run `tools.build_catalog` for build {build} "
                                              f"(RUNBOOK-patch.md step 6)")]
    cat = json.loads(p.read_text(encoding="utf-8"))
    items, sets = cat.get("items") or {}, cat.get("attack_sets") or {}
    bad = []
    if cat.get("schema") != "dw_items/1":
        bad.append(f"schema {cat.get('schema')}")
    if str(cat.get("build")) != str(build):
        bad.append(f"file says build {cat.get('build')}")
    if len(items) < MIN_ITEMS or len(sets) < MIN_ATTACK_SETS:
        bad.append(f"only {len(items)} items / {len(sets)} attack sets")
    out.append(res("catalog items file", FAIL if bad else PASS, "; ".join(bad) or f"{len(items)} items, {len(sets)} attack sets, build {build}"))

    problems = []
    src = cat.get("source") or {}
    if src.get("missing_from_catalog"):
        problems.append(f"{len(src['missing_from_catalog'])} registry items never described")
    if src.get("errors"):
        problems.append(f"{len(src['errors'])} build errors")
    unresolved = [k for k, it in items.items() if it.get("role") == "weapon" and
                  ((it.get("attacks") or {}).get("primary") or {}).get("action") not in sets
                  and not (it.get("ranged") or it.get("magic_collection"))]
    if unresolved:
        problems.append(f"{len(unresolved)} weapons with no resolvable primary attack set ({', '.join(unresolved[:3])})")
    out.append(res("catalog integrity", FAIL if problems else PASS, "; ".join(problems) or "no missing items, no errors, every weapon has an attack set"))

    # Spot items: a preferred id, else the first of the category, so a patch that only renames one item still tests the shape.
    def spot(label, pref, pred, extra):
        k, it = (pref, items.get(pref)) if items.get(pref) and pred(items[pref]) else _first(items, pred)
        if not it:
            return f"{label}: none in catalog"
        err = extra(it)
        return f"{label} {k}: {err}" if err else None

    def melee_ok(it):
        a = ((it.get("attacks") or {}).get("primary") or {}).get("action")
        return None if (sets.get(a) or {}).get("chain") else "no attack chain"

    errs = [e for e in (
        spot("melee", "ITEM_Sword_Iron", lambda i: i.get("role") == "weapon" and i.get("range_type") == "melee" and i.get("category") == "sword", melee_ok),
        spot("ranged", "ITEM_Longbow_Hunter", lambda i: i.get("range_type") == "ranged", lambda i: None if (i.get("ranged") or {}).get("collection") else "no ranged collection"),
        spot("magic", "ITEM_Staff_Ancestral", lambda i: i.get("range_type") == "magic" and i.get("category") == "staff", lambda i: None if i.get("magic_collection") else "no magic collection"),
        spot("armour", "ITEM_Armour_T4_Body_Iron", lambda i: i.get("kind") == "wearable" and i.get("slot") == "body", lambda i: None if i.get("path") else "no path"),
        spot("tool", "ITEM_Pickaxe_Iron", lambda i: i.get("category") == "pickaxe", lambda i: None if i.get("held_actor_class") else "no held actor class"),
    ) if e]
    out.append(res("catalog spot items", FAIL if errs else PASS, "; ".join(errs) or "melee, ranged, magic, armour and tool items look right"))

    sp = data_dir / f"spells_{build}.json"
    if not sp.exists():
        out.append(res("spell catalog", FAIL, f"{sp.name} missing"))
    else:
        s = json.loads(sp.read_text(encoding="utf-8"))
        spells = s.get("spells") or {}
        untagged = [k for k, v in spells.items() if not (v.get("usage") or {}).get("role")]
        e = []
        if not spells:
            e.append("no spells")
        if s.get("spell_count") not in (None, len(spells)):
            e.append(f"spell_count {s.get('spell_count')} != {len(spells)}")
        if untagged:
            e.append(f"{len(untagged)} spells without a role tag ({', '.join(untagged[:3])})")
        out.append(res("spell catalog", FAIL if e else PASS, "; ".join(e) or f"{len(spells)} spells, all have role tags"))
    return out


def check_dependencies(ctx: pp.Ctx, build: str | None) -> list[dict]:
    """Every /Script class and member the mod hooks or calls must exist in the installed build's dump."""
    if not build or not ctx.dump_dir(build).exists():
        return [res("dependencies resolve in dump", SKIP, f"no snapshot dumps/{build}: run `patch_pipeline snapshot` first")]
    idx = pp.ensure_index(ctx, build)
    deps = pp.extract_deps(ctx, idx)
    chk = pp.check_deps(deps, idx, idx, pp.catalog_paths(ctx, build))
    script = [u for u in chk["unresolved"] if u["kind"] in ("script_class", "script_member", "script_module", "class_name", "enum")
              and u.get("tier") in ("core", "tooling")]
    unloaded = [u for u in chk["unresolved"] if u["kind"] in ("asset", "asset_member")]
    if script:
        return [res("dependencies resolve in dump", FAIL,
                    f"{len(script)} native dependencies not in the dump: " + "; ".join(f"{u['dep']} ({', '.join(u['uses'][:1])})" for u in script[:5]))]
    return [res("dependencies resolve in dump", PASS,
                f"{deps['counts']['total']} dependencies; all native classes/members resolve; {len(unloaded)} asset paths were unloaded in the dump (informational)")]


# ------------------------------------------------------------------------------ main

def print_results(results: list[dict]) -> None:
    w = max(len(r["name"]) for r in results)
    for r in results:
        print(f"[{r['status']}] {r['name'].ljust(w)}  {r['detail']}")
    c = {s: sum(1 for r in results if r["status"] == s) for s in (PASS, FAIL, SKIP)}
    print(f"\n{c[PASS]} passed, {c[FAIL]} failed, {c[SKIP]} skipped")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", help="default: the installed server build (SteamCMD appmanifest)")
    ap.add_argument("--offline", action="store_true", help="skip the live bridge checks")
    ap.add_argument("--active", action="store_true", help="run the player checks (they act in the world) when a player is connected")
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("--json", metavar="PATH", help="also write the results as JSON")
    a = ap.parse_args(argv)
    build = a.build or pp.server_build_id()
    ctx = pp.Ctx()
    results: list[dict] = []
    if a.offline:
        results.append(res("ping", SKIP, "--offline"))
        results += [res(n, SKIP, "--offline") for n in ("capabilities", "get_state", "body_status", "debug_run body_probe")]
        results += player_checks_skipped("--offline")
    else:
        from brain.bridge_client import BridgeClient
        from brain.jsonl_log import JsonlLogger
        from brain.transport import file_transport_pair
        brain_side, _ = file_transport_pair()
        client = BridgeClient(brain_side, JsonlLogger.session("smoke"))
        results += run_live(client, active=a.active, timeout=a.timeout)
    results += check_catalog(ctx.data_dir, build)
    results += check_dependencies(ctx, build)
    print(f"smoke test, server build {build}, {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print_results(results)
    if a.json:
        Path(a.json).parent.mkdir(parents=True, exist_ok=True)
        Path(a.json).write_text(json.dumps({"build": build, "ts": time.time(), "results": results}, indent=1), encoding="utf-8")
    return 1 if any(r["status"] == FAIL for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())

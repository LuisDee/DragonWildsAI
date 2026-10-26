"""M3 skill routes, live: one no-model debug call per skill, in the Director's checklist order
(docs/design/director.md §15). DEV WORLD ONLY.

  .venv\\Scripts\\python.exe -m tools.skill_routes            (all rows, in order)
  .venv\\Scripts\\python.exe -m tools.skill_routes --only Woodcutting,Fishing
  .venv\\Scripts\\python.exe -m tools.skill_routes --dry-run  (parse + guards + plan only, no calls)

Per row:
  1. read get_state.skills (the body's own SkillComponent rows), resolve the row's placeholders (<cheapest>, <weak
     creature>, <spade> ...) from read tools (recipes, census, inventory, spells), run the row's ONE tool call over the
     bridge's debug channel (never the model), read the skills again;
  2. PASS = the tool answered ok AND that skill's xp rose (> 0);
  3. a missing prerequisite (the body's own reason: wrong_tool, nothing_in_range, missing_materials, not_unlocked,
     not_enough_resources, not_in_inventory, unknown_target, invalid_args from a placeholder that resolved to nothing) =
     SKIPPED with that reason named. Never granted, unless the row's precondition cell says "fixture ok", in which case
     the named fixture grant runs first (logged as quick, through the eval agent's DevTarget.setup);
  4. not_implemented / unknown_tool / verification_failed = a GAP (logged, the row stops);
  5. fight rows (attack / cast at a target): health polled every second through the client runner; below 50 % the
     action is stopped (`stop`) and the remaining fight rows are skipped (stop rule).
Results: logs/skills/routes_<ts>.json (+ printed). Guards: the client slot must be held by --owner (default "skills",
tools/client_slot.py); the dev-target guard (evals.bench.devrun DevTarget.guard) refuses anything but the dev world and
refuses while the live brain runs.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
DIRECTOR = ROOT / "docs" / "design" / "director.md"
LOGS = ROOT / "logs" / "skills"
CMD, OUT = ROOT / "client_io" / "cmd", ROOT / "client_io" / "out"

PREREQ_REASONS = {"wrong_tool", "nothing_in_range", "missing_materials", "not_unlocked", "not_enough_resources",
                  "not_in_inventory", "unknown_target", "unknown_recipe", "path_blocked", "too_far"}
GAP_REASONS = {"not_implemented", "unknown_tool", "verification_failed"}
FIGHT_TOOLS = {"attack", "cast", "shoot"}
HP_STOP = 0.5


# ---------------------------------------------------------------------------------------------- parsing (pure)
@dataclass
class Route:
    n: int
    skill: str
    tool: str
    args: dict
    placeholders: dict  # arg -> placeholder text ("<cheapest>")
    before: list  # read tools to run first ("agility_courses" ...), informational
    precondition: str
    risk: str
    fixture: list = field(default_factory=list)  # grants allowed by the row ("fixture ok: ITEM_X x1")

    @property
    def fight(self) -> bool:
        return self.tool in FIGHT_TOOLS


CALL_RE = re.compile(r"`([a-z_]+)\s*(\{[^`]*\})?`")
FIXTURE_RE = re.compile(r"fixture ok(?::\s*([^)|]+))?", re.I)


def parse_args(text: str | None) -> tuple[dict, dict]:
    """`{resource: ash, count: 2}` / `{item: <a cooked food>}` -> (args, placeholders). Values: ints, quoted or bare
    strings; <...> values become placeholders (resolved at run time)."""
    args, ph = {}, {}
    if not text:
        return args, ph
    body = text.strip()[1:-1]
    for part in re.split(r",(?![^<]*>)", body):
        if ":" not in part:
            k = part.strip()
            if re.fullmatch(r"[a-z_]+", k):
                ph[k] = f"<{k}>"  # a bare key (`target`) is resolved at run time like a placeholder
            continue
        k, v = part.split(":", 1)
        k, v = k.strip(), v.strip().strip('"').strip("'")
        if not k:
            continue
        if v.startswith("<") and v.endswith(">"):
            ph[k] = v
        elif re.fullmatch(r"-?\d+", v):
            args[k] = int(v)
        else:
            args[k] = v
    return args, ph


def parse_checklist(md: str) -> list[Route]:
    """The §15 table of director.md -> routes in order."""
    m = re.search(r"^## 15\..*?$(.*?)(?=^## \d+\.|\Z)", md, re.S | re.M)
    if not m:
        raise ValueError("director.md has no §15 live verification table")
    routes = []
    for line in m.group(1).splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5 or not cells[0].isdigit():
            continue
        n, skill, call, pre, risk = int(cells[0]), cells[1], cells[2], cells[3], cells[4]
        calls = CALL_RE.findall(call)
        if not calls:
            continue
        # the row's ACTION is the first call with args (or the first call); the others before it are read tools
        main = next((c for c in calls if c[1]), calls[0])
        before = [c[0] for c in calls if c is not main and c[0] != main[0]]
        args, ph = parse_args(main[1])
        fx = []
        fm = FIXTURE_RE.search(pre)
        if fm:
            fx = [s.strip() for s in (fm.group(1) or "").split(";") if s.strip()]
        routes.append(Route(n, skill, main[0], args, ph, before, pre, risk, fx))
    return routes


def classify(res: dict, xp_gain: float | None) -> tuple[str, str]:
    """One tool reply + the xp delta -> (verdict, why). verdict: pass | skipped | gap | failed."""
    reason = res.get("reason")
    detail = ((res.get("data") or {}).get("detail")) or reason or ""
    if res.get("ok"):
        if xp_gain and xp_gain > 0:
            return "pass", f"ok, xp +{xp_gain:g}"
        return "failed", "the tool answered ok but the skill's xp did not rise"
    if reason in GAP_REASONS:
        return "gap", f"{reason}: {detail}"
    if reason in PREREQ_REASONS or reason == "invalid_args":
        return "skipped", f"prerequisite missing ({reason}): {detail}"
    return "failed", f"{reason}: {detail}"


def xp_of(skills: Any, name: str) -> float | None:
    for r in skills or []:
        if isinstance(r, dict) and str(r.get("skill", "")).lower() == name.lower() and isinstance(r.get("xp"), (int, float)):
            return float(r["xp"])
    return None


# ---------------------------------------------------------------------------------------------- placeholder resolvers
# Test tooling, not the brain: each placeholder is resolved from the body's own read tools; nothing resolves -> None
# (the row is skipped with the reason named).
def _first(rows, pred):
    for r in rows or []:
        if pred(r):
            return r
    return None


def resolve(ph: str, call: Callable[[str, dict], dict]) -> Any:
    p = ph.strip("<>").lower()
    if "cheapest" in p or "cooked food" in p:
        st = "Campfire" if "cooked" in p else None
        r = call("recipes", {"station": st} if st else {})
        rows = ((r.get("data") or {}).get("recipes") or (r.get("data") or {}).get("craftable") or [])
        ok = [x for x in rows if isinstance(x, dict) and (x.get("craftable") or x.get("status") in ("craft", "ready", None))]
        x = ok[0] if ok else None
        return x and (x.get("item") or x.get("name") or x.get("output"))
    if "creature" in p or p == "target":
        st = call("get_state", {})
        cs = ((st.get("data") or {}).get("nearby_entities") or (st.get("data") or {}).get("creatures") or [])
        cs = [c for c in cs if isinstance(c, dict) and not c.get("player")]
        cs.sort(key=lambda c: (c.get("pl") or c.get("power_level") or 99, c.get("distance") or 999))
        return cs[0].get("id") if cs else None
    if "spade" in p or "bow" in p:
        word = "shovel" if "spade" in p else "bow"
        inv = call("inventory", {})
        d = inv.get("data") or {}
        for where in ("hotbar", "bag", "loadout"):
            x = _first(d.get(where), lambda e: word in str(e.get("category", "")).lower() or word in str(e.get("name", "")).lower())
            if x:
                return x.get("name") or x.get("item")
        return None
    if "combat spell" in p:
        sp = call("spells", {})
        rows = (sp.get("data") or {}).get("spells") or []
        x = _first(rows, lambda s: s.get("castable") and (s.get("role") == "attack" or s.get("harmful")))
        return x and x.get("name")
    return None


# ---------------------------------------------------------------------------------------------- runner
@dataclass
class Env:
    call: Callable[[str, dict, float], dict]  # bridge debug call (tool, args, timeout) -> reply
    health: Callable[[], float | None]  # fraction 0..1 (client runner), None = unknown
    slot_ok: Callable[[], bool]
    guard: Callable[[], None]  # raises on a non-dev world / brain running
    grant: Callable[[str, int], dict] | None = None
    sleep: Callable[[float], None] = time.sleep


def check_guards(env: Env) -> str | None:
    if not env.slot_ok():
        return "the client slot is not held by this owner (python -m tools.client_slot take skills 30)"
    try:
        env.guard()
    except Exception as exc:  # the dev-target guard raises Abort with the reason
        return f"dev-world guard refused: {exc}"
    return None


def run_route(env: Env, r: Route, timeout: float = 900) -> dict:
    row: dict = {"n": r.n, "skill": r.skill, "tool": r.tool, "precondition": r.precondition}
    s0 = (env.call("get_state", {}, 15).get("data") or {}).get("skills")
    x0 = xp_of(s0, r.skill)
    for t in r.before:
        row.setdefault("reads", {})[t] = env.call(t, {}, 15).get("data")
    args = dict(r.args)
    for k, ph in r.placeholders.items():
        v = resolve(ph, lambda tool, a: env.call(tool, a, 15))
        if v is None:
            row.update(verdict="skipped", why=f"prerequisite missing: nothing for {ph} ({r.precondition})")
            return row
        args[k] = v
    for g in r.fixture:
        m = re.match(r"(\S+)(?:\s*x(\d+))?", g)
        if m and env.grant:
            row.setdefault("fixtures", []).append({"grant": m.group(1), "count": int(m.group(2) or 1), "quick": True,
                                                   "result": env.grant(m.group(1), int(m.group(2) or 1))})
    if "weapon" in args:  # a row naming the weapon to use: take it out first (equip), the action picks what is held
        w = args.pop("weapon")
        row["equip"] = env.call("equip", {"item": w}, 15)
        if not row["equip"].get("ok"):
            row.update(verdict="skipped", why=f"prerequisite missing: couldn't take out {w}: {(row['equip'].get('data') or {}).get('detail') or row['equip'].get('reason')}")
            return row
    row["args"] = args
    box: dict = {}
    th = threading.Thread(target=lambda: box.update(res=env.call(r.tool, args, timeout)), daemon=True)
    th.start()
    low = None
    while th.is_alive():
        if r.fight:
            h = env.health()
            if h is not None and h < HP_STOP:
                low = h
                env.call("stop", {}, 10)
                th.join(15)
                break
        env.sleep(1.0)
        th.join(0.01)
    res = box.get("res") or {"ok": False, "reason": "timeout"}
    s1 = (env.call("get_state", {}, 15).get("data") or {}).get("skills")
    x1 = xp_of(s1, r.skill)
    gain = (x1 - x0) if (x0 is not None and x1 is not None) else None
    row.update(result={"ok": res.get("ok"), "reason": res.get("reason"), "detail": (res.get("data") or {}).get("detail")},
               xp_before=x0, xp_after=x1, xp_gain=gain)
    if low is not None:
        row.update(verdict="stopped_low_hp", why=f"health fell to {low:.0%} (< 50 %): stopped")
    else:
        row["verdict"], row["why"] = classify(res, gain)
    return row


def run(env: Env, routes: list[Route], only: set[str] | None = None) -> dict:
    refused = check_guards(env)
    if refused:
        return {"ok": False, "refused": refused, "rows": []}
    rows, stop_fights = [], False
    for r in routes:
        if only and r.skill.lower() not in only:
            continue
        if r.fight and stop_fights:
            rows.append({"n": r.n, "skill": r.skill, "verdict": "skipped", "why": "an earlier fight row stopped on low health"})
            continue
        row = run_route(env, r)
        rows.append(row)
        print(json.dumps({k: row.get(k) for k in ("n", "skill", "verdict", "why", "xp_gain")}), flush=True)
        if row.get("verdict") == "stopped_low_hp":
            stop_fights = True
    summary: dict = {}
    for x in rows:
        summary[x["verdict"]] = summary.get(x["verdict"], 0) + 1
    return {"ok": True, "summary": summary, "rows": rows,
            "gaps": [f"{x['skill']}: {x['why']}" for x in rows if x["verdict"] == "gap"]}


# ---------------------------------------------------------------------------------------------- live glue
def _client_runner(name: str, lua: str, timeout: float = 20) -> dict:
    out = OUT / f"{name}.json"
    if out.exists():
        out.unlink()
    tmp = CMD / f"{name}.lua.tmp"
    tmp.write_text(lua, encoding="utf-8")
    os.replace(tmp, CMD / f"{name}.lua")
    with open(CMD / "queue.txt", "a", encoding="utf-8") as q:
        q.write(name + "\n")
    t0 = time.time()
    while time.time() - t0 < timeout:
        if out.exists():
            time.sleep(0.1)
            try:
                return json.loads(out.read_text(encoding="utf-8"))
            except ValueError:
                pass
        time.sleep(0.3)
    return {"ok": False, "error": "timeout"}


HEALTH_LUA = r'''
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    local s = inst and inst.module.API.module("sense")
    local me = s and s.me and s.me(log)
    if not me then return { ok = false } end
    return { ok = true, hp = me.health, max = me.max_health }
end
'''


def live_env(owner: str) -> Env:
    sys.path.insert(0, str(ROOT))
    from brain.bridge_client import BridgeClient
    from brain.transport import file_transport_pair
    from evals.bench.devrun import default_dev
    from tools.client_slot import _load, holder
    client = BridgeClient(file_transport_pair(body="client", channel="debug")[0])
    dev = default_dev()

    def health() -> float | None:
        r = (_client_runner("routes_hp", HEALTH_LUA).get("result") or {})
        return (r["hp"] / r["max"]) if r.get("ok") and r.get("max") else None

    def slot_ok() -> bool:
        h = holder(_load())
        return bool(h and h.get("owner") == owner and not h.get("reserved"))

    return Env(call=lambda tool, args, t: client.request(tool, args, timeout=t), health=health, slot_ok=slot_ok,
               guard=lambda: dev.guard("skill_routes", {}),
               grant=lambda item, n: dev.setup("grant", purpose="quick: skill_routes fixture (checklist row allows it)", item=item, count=n))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--only", default="", help="comma-separated skill names")
    ap.add_argument("--owner", default="skills", help="who must hold the client slot")
    ap.add_argument("--dry-run", action="store_true", help="parse + plan only (no client, no guards)")
    a = ap.parse_args(argv)
    routes = parse_checklist(DIRECTOR.read_text(encoding="utf-8"))
    only = {s.strip().lower() for s in a.only.split(",") if s.strip()} or None
    if a.dry_run:
        print(json.dumps([{"n": r.n, "skill": r.skill, "tool": r.tool, "args": r.args, "placeholders": r.placeholders,
                           "before": r.before, "fight": r.fight, "fixture": r.fixture} for r in routes
                          if not only or r.skill.lower() in only], indent=1))
        return 0
    out = run(live_env(a.owner), routes, only)
    LOGS.mkdir(parents=True, exist_ok=True)
    p = LOGS / f"routes_{time.strftime('%Y%m%d-%H%M%S')}.json"
    p.write_text(json.dumps(out, indent=1, default=str), encoding="utf-8")
    print(json.dumps(out.get("summary") or out, indent=1))
    print("saved", p)
    return 0 if out.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())

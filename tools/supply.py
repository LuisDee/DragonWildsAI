"""Top Claude up with food and clean water before a live test run on the DEV server (a harness fixture, not play).

Luis (2026-11-01): "maybe every run give claude some food and water so he doesnt block testing". Survival kept
blocking the other skills' live tests (thirst at 0.5 HP, a death by thirst + poison). This puts real items in his
bag through the dev fixture `grant` (evals/bench: dev server only, refuses while any other player is on); he still
eats and drinks them himself (the fed reflex). Survival tests (eat/drink by comparing options) run WITHOUT it.

    .venv\\Scripts\\python.exe -m tools.supply                 # top up to 6 food + 6 water
    .venv\\Scripts\\python.exe -m tools.supply --food 10 --heal # and set full health first if he is below 30 HP
    .venv\\Scripts\\python.exe -m tools.supply --check         # report only
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FOOD = "ITEM_Consumable_Meat_Fillet"   # cooked: what the chat ladder's fixture already grants
WATER = "ITEM_Consumable_Water_Clean"


def counts(inv: dict) -> dict[str, int]:
    out: dict[str, int] = {}
    for row in (inv.get("hotbar") or []) + (inv.get("bag") or []):
        if row.get("item"):
            out[row["item"]] = out.get(row["item"], 0) + int(row.get("count") or 0)
    return out


def last_hp(path: Path = ROOT / "client_io" / "events" / "vitals.jsonl") -> float | None:
    """His latest HP from the vitals watcher's survival rows (client_io/events/vitals.jsonl)."""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()[-200:]
    except OSError:
        return None
    for line in reversed(lines):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("type") == "survival" and isinstance(r.get("hp"), (int, float)):
            return float(r["hp"])
    return None


def top_up(dev, food: int, water: int, heal: bool = False, check: bool = False, purpose: str = "supply") -> dict:
    r = dev.body_call("inventory", {})
    if not r.get("ok"):
        return {"ok": False, "why": f"inventory read failed: {r.get('reason')}"}
    have = counts(r.get("data") or {})
    out = {"ok": True, "have": {FOOD: have.get(FOOD, 0), WATER: have.get(WATER, 0)}, "granted": {}}
    if heal and not check:
        hp = last_hp()
        if isinstance(hp, (int, float)) and hp < 30:
            dev.setup("set_health", purpose=f"{purpose}: health {hp:.0f} < 30", value=100)
            out["healed_from"] = hp
    for item, want in ((FOOD, food), (WATER, water)):
        need = want - have.get(item, 0)
        if need > 0 and not check:
            dev.setup("grant", purpose=f"{purpose}: top up to {want}", item=item, count=need)
            out["granted"][item] = need
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--food", type=int, default=6)
    ap.add_argument("--water", type=int, default=6)
    ap.add_argument("--heal", action="store_true", help="set full health first when he is below 30 HP")
    ap.add_argument("--check", action="store_true", help="report only, grant nothing")
    ap.add_argument("--purpose", default="supply before a live test")
    a = ap.parse_args(argv)
    from evals.bench.devrun import default_dev
    dev = default_dev()
    dev.brain_running = lambda: False  # a top-up between runs; the grant itself is guarded (dev only, nobody else on)
    try:
        res = top_up(dev, a.food, a.water, heal=a.heal, check=a.check, purpose=a.purpose)
    except Exception as exc:  # the fixture's guards raise (another player connected, not the dev server)
        res = {"ok": False, "why": str(exc)}
    print(json.dumps(res))
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())

r"""Rock / resource-node tool gates from the local wiki mirror, resolved to tool tiers through the item catalog.

    .venv\Scripts\python.exe -m tools.build_rock_gates          # writes data/wiki/derived/rock_gates.json

Why: the game catalogs carry item tiers but no node gates. The live gate is read from each rock actor
(`DamageComponent.DamageModifiers[...].RequiredCategory/RequiredTier`, DISCOVERIES "Rocks"); only the stone boulder's
(pickaxe tier 1) is verified in game. The wiki's "Mining info" infobox names the least pickaxe per node
("tool=Bone pickaxe or better") and its manual XP, and its Drops table names the item. Here that pickaxe name is
resolved to its catalog `tier`, so GearWorld (brain/mock/gear_world.py) is as strict as the wiki says the game is.

The wiki is CC BY-NC-SA 3.0, so the output stays beside the mirror (data/wiki/ is gitignored), never in git.
Every row says source=wiki: in game, the live gate wins.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from brain import item_stats, paths

OUT = paths.REPO_ROOT / "data" / "wiki" / "derived" / "rock_gates.json"
INFO = re.compile(r"Mining info: (.+)")
DROP = re.compile(r"DropsLine: name=([^;]+); quantity=([^;]*); rarity=([^\n;]+)")


def _fields(text: str) -> dict[str, str]:
    m = INFO.search(text)
    if not m:
        return {}
    return {k.strip(): v.strip() for k, v in (p.split("=", 1) for p in m.group(1).split(";") if "=" in p)}


def build(pages_dir: Path | None = None) -> dict:
    cat = item_stats.catalog()
    by_name = {(e.get("name") or "").lower(): (iid, e) for iid, e in cat.items() if e.get("name")}
    names = dict(by_name)
    from brain.predicates import Items
    items = Items()
    rows = []
    for f in sorted((pages_dir or paths.REPO_ROOT / "data" / "wiki" / "pages").glob("*.json")):
        try:
            page = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        texts = "\n".join(s.get("text") or "" for s in page.get("sections") or [])
        info = _fields(texts)
        tool = info.get("tool")
        if not tool:
            continue
        m = re.match(r"(.+?) or better", tool, re.I)
        tool_name = (m.group(1) if m else tool).strip()
        tier, category, tool_item = None, None, None
        if tool_name.lower() == "any pickaxe":
            tier, category = 1, "pickaxe"
        else:
            hit = names.get(tool_name.lower())
            if hit:
                tool_item, e = hit
                tier, category = e.get("tier"), e.get("category")
        drops = []
        for name, qty, rarity in DROP.findall(texts):
            try:
                ids = list(items.resolve(name.strip()))
            except Exception:
                ids = []
            drops.append({"name": name.strip(), "items": ids, "quantity": qty.strip(), "rarity": rarity.strip()})
        rows.append({"node": page.get("title"), "tool": tool, "tool_item": tool_item, "category": category,
                     "min_tier": tier, "manual_xp": info.get("manual_xp"), "drops": drops,
                     "source": "wiki", "url": page.get("url")})
    return {"schema": "dw_rock_gates/1", "licence": "derived from CC BY-NC-SA 3.0 wiki text: never commit",
            "note": "the live gate on the rock actor wins in game", "nodes": rows}


def main() -> int:
    data = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, indent=1, ensure_ascii=False), encoding="utf-8")
    ok = sum(1 for r in data["nodes"] if r["min_tier"] is not None)
    print(f"{len(data['nodes'])} nodes ({ok} with a resolved tier) -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""A clone of ClaudeDev's character save with chosen quests cleared, for repeat quest runs on dev (main + Luis,
2026-11-01). The dev server keeps its own cached copy of every character it has seen, keyed by char_guid
(CachedCharacterStates, DISCOVERIES "Where the live character comes from"), so editing ClaudeDev.json in place would not
reset him; a clone with a NEW char_guid is a character the server has never seen, and it loads from the file.

    .venv\\Scripts\\python.exe -m tools.quest_clone make --name ClaudeQ1     # writes SaveCharacters\\ClaudeQ1.json
    .venv\\Scripts\\python.exe -m tools.quest_clone show --name ClaudeQ1     # its quest log, as the file holds it

What is cleared: the quests whose QuestData asset is in --quests (default: the FTUE chain First Steps, Getting
Started, Ratcatcher, Rune Mysteries 1 + 2, and the second First Steps, which Rune Mysteries 2 gives), found by their
PersistenceID from a live read of his quest log (client_mod/commands/quest_ids_probe.lua); their QuestLocations (the
markers of those quests from a live read, client_mod/commands/quest_locations_probe.lua, matched by name, and by the
quest suffix of the name for markers with no live actor: "Zanik_Objective_NPC_RM" -> "_RM"); a QuestTrackedMain that
pointed at one; and the chain's "WOMTempleHidden" bool (on Dragon Slayer; a just-out-of-the-temple character has
none, and it hides the temple's Wise Old Man whom First Steps needs). The first First Steps is not removed but RESET
to the state the game itself saved for characters who had just left the temple (Claude.json and ClaudeGuest.json:
given at Objective2 "speak to the Wise Old Man", entry and exit volumes passed, his marker on, Doric's off), because
the game gives that quest from the temple's entry volume, which a clone (spawned where ClaudeDev stood) never crosses.
The cleared quests' deliverables leave his bag (data/quest_deliverables.json: Stone Club, Rat Roast and its raw meat,
Ash Logs, Rune Essence, Air and Astral Runes): a player meeting those quests holds none of them (live ClaudeQ2-Q5: an
inherited Stone Club made Getting Started one talk, and four Rat Roasts made Ratcatcher one).
He starts fed, watered and rested (VITALS at VITALS_START), as a player who meets these quests is: the clones took
ClaudeDev's bars as they stood (2026-11-16: rest 5, water 6), and Rune Mysteries run 20261116-074002 spent 5 of its 15
minutes on a bedroll and water before the quest's second part.
Everything else (level, skills, gear, tools, spells, recipes, position) is kept byte for byte, so a run measures the
quests, not a level-1 start. ClaudeDev.json and its .backup are only read; each clone's pristine copy is kept in
logs/quests/clones/ before its first load.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SAVE_DIR = Path(os.environ.get("LOCALAPPDATA", "")) / "RSDragonwilds" / "Saved" / "SaveCharacters"
SOURCE = "ClaudeDev"
KEEP_DIR = ROOT / "logs" / "quests" / "clones"
IDS_PROBE = ROOT / "client_io" / "out" / "quest_ids_probe.json"
LOC_PROBE = ROOT / "client_io" / "out" / "quest_locations_probe.json"
DELIVERABLES = ROOT / "data" / "quest_deliverables.json"
FIRST = "Quest_FTUE_GS"  # the first First Steps
CHAIN = (FIRST, "Quest_FTUE_RtftJ", "Quest_FTUE_RC", "Quest_FTUE_LO", "Quest_FTUE_RM", "Quest_FTUE_FS")
CHAIN_BOOLS = ("WOMTempleHidden",)
# First Steps as the game saved it for Claude and ClaudeGuest just after the temple (both files, 2026-10/11):
FIRST_RESET = {"QuestState": 1, "QuestObjective": "Objective2", "QuestInts": [], "QuestBools": [
    {"QuestVariableName": "HasTriggeredEntryVolume", "QuestVariableValue": True},
    {"QuestVariableName": "HasTriggeredExitVolume", "QuestVariableValue": True}]}
FIRST_LOCATIONS = [{"QuestLocationId": "WOM_Objective_FTUE_GS", "QuestLocationsState": True},
                   {"QuestLocationId": "Doric_Objective_FTUE_GS", "QuestLocationsState": False}]
# the survival bars a clone starts with: (block, value key) in GameProgress.Character
VITALS = (("Sustenance", "SustenanceValue"), ("Hydration", "HydrationValue"), ("Endurance", "EnduranceValue"))
VITALS_START = 100


def _copy(v):
    return json.loads(json.dumps(v))


def _probe(path: Path) -> dict:
    d = json.loads(path.read_text(encoding="utf-8"))
    return d.get("result", d)


def removal(assets: tuple[str, ...]) -> tuple[dict[str, str], set[str], set[str]]:
    """{QuestId: asset}, the marker names and the marker-name suffixes of the quests to clear, from the live probes."""
    ids = {q["id"]: q["asset"] for q in _probe(IDS_PROBE).get("quests") or [] if q.get("asset") in assets and q.get("id")}
    missing = set(assets) - set(ids.values())
    if missing:
        raise SystemExit(f"no PersistenceID for {sorted(missing)}: run client_mod/commands/quest_ids_probe.lua on ClaudeDev")
    rows = _probe(LOC_PROBE).get("subsystem") or []
    names = {r["name"] for r in rows if r.get("asset") in assets and r.get("name")}
    suffixes = {"_" + n.rsplit("_", 1)[-1] for n in names if "_FTUE_" in n}  # Zanik_Objective_FTUE_RM -> _RM
    return ids, names, suffixes


def _marker_of(loc_id: str, names: set[str], suffixes: set[str]) -> bool:
    return loc_id in names or any(loc_id.endswith(s) for s in suffixes)


def deliverables(assets: tuple[str, ...]) -> dict[str, str]:
    """{item persistence id: item} of what the quests with these assets ask for (by quest name, from the ids probe)."""
    d = json.loads(DELIVERABLES.read_text(encoding="utf-8"))
    names = {q.get("name") for q in _probe(IDS_PROBE).get("quests") or [] if q.get("asset") in assets}
    items = {i for n in names for i in d["quests"].get(n) or []}
    missing = items - set(d["persistence_ids"])
    if missing:
        raise SystemExit(f"no item persistence id for {sorted(missing)} in {DELIVERABLES.name}")
    return {d["persistence_ids"][i]: i for i in items}


def clear(save: dict, ids: dict[str, str], names: set[str], suffixes: set[str], name: str,
          strip: dict[str, str] | None = None) -> dict:
    out = _copy(save)
    inv = out["GameProgress"].get("Inventory") or {}
    for slot in [k for k, v in inv.items() if isinstance(v, dict) and v.get("ItemData") in (strip or {})]:
        del inv[slot]  # a cleared quest's deliverable: a player meeting the quest holds none
    # a loadout slot can hold a bag item by its slot index ({"PlayerInventoryItemIndex": 40}: his Air Runes); one left
    # pointing at a stripped slot makes the server refuse the character (live ClaudeQ6 21:18Z: "CharCantLoad" x3)
    lo = out["GameProgress"].get("Loadout") or {}
    for slot in [k for k, v in lo.items() if isinstance(v, dict) and "PlayerInventoryItemIndex" in v
                 and str(v["PlayerInventoryItemIndex"]) not in inv]:
        del lo[slot]
    out["meta_data"]["char_guid"] = uuid.uuid4().hex.upper()
    out["meta_data"]["char_name"] = name
    ch = out["GameProgress"].get("Character") or {}
    for blk, key in VITALS:
        if isinstance(ch.get(blk), dict) and key in ch[blk]:
            ch[blk][key] = VITALS_START
    qp = out["GameProgress"]["QuestProgress"]
    first = next((i for i, a in ids.items() if a == FIRST), None)
    quests = []
    for q in qp.get("Quests") or []:
        if q.get("QuestId") == first:
            quests.append({"QuestId": first, **_copy(FIRST_RESET)})
        elif q.get("QuestId") not in ids:
            q["QuestBools"] = [b for b in q.get("QuestBools") or [] if b.get("QuestVariableName") not in CHAIN_BOOLS]
            quests.append(q)
    qp["Quests"] = quests
    locs = [l for l in qp.get("QuestLocations") or [] if not _marker_of(str(l.get("QuestLocationId") or ""), names, suffixes)]
    qp["QuestLocations"] = (_copy(FIRST_LOCATIONS) if first else []) + locs
    if qp.get("QuestTrackedMain") in ids:
        qp["QuestTrackedMain"] = first or next((q["QuestId"] for q in quests if q.get("QuestState") == 1), "")
    return out


def ue_json(v, depth: int, nl: str = "\r\n") -> str:
    """A value as Unreal's pretty JSON writer lays it out (tabs; an object value opens on the next line, an array on
    the same line; [] when empty), so a rewritten block matches the bytes the game writes (checked by a round trip)."""
    tab = "\t" * depth
    if isinstance(v, dict):
        items = []
        for k, x in v.items():
            head = f"{tab}\t{json.dumps(k, ensure_ascii=False)}:"
            items.append(f"{head}{nl}{tab}\t{ue_json(x, depth + 1, nl)}" if isinstance(x, dict) and x
                         else f"{head} {ue_json(x, depth + 1, nl)}")
        return "{" + nl + ("," + nl).join(items) + nl + tab + "}" if items else "{}"
    if isinstance(v, list):
        if not v:
            return "[]"
        return "[" + nl + ("," + nl).join(f"{tab}\t{ue_json(x, depth + 1, nl)}" for x in v) + nl + tab + "]"
    return json.dumps(v, ensure_ascii=False)


def _block(text: str, key: str) -> tuple[int, int, int]:
    """(start, end, depth) of the object value of the one `"key":` in text (start at its "{")."""
    if text.count(f'"{key}":') != 1:
        raise SystemExit(f"{key} is not in the file exactly once")
    i = text.index(f'"{key}":')
    start = text.index("{", i)
    line = text[text.rindex("\n", 0, i) + 1:i]
    depth = len(line) - len(line.lstrip("\t"))
    return start, _obj_end(text, start), depth


def _drop(text: str, key: str, slots: list[str]) -> str:
    """text with these entries of the `"key":` object cut out as text, each with one separating comma (the game's
    floats do not survive a Python re-dump: 6.3928642787233e+17 comes back 6.3928642787232998e+17)."""
    a, b, depth = _block(text, key)
    blk = text[a:b]
    for k in slots:
        tag = "\n" + "\t" * (depth + 1) + json.dumps(k) + ":"
        if blk.count(tag) != 1:
            raise SystemExit(f"{key}.{k} is not in the file exactly once")
        i = blk.index(tag) + 1  # the entry's line
        e = _obj_end(blk, blk.index("{", i))
        if blk[e] == ",":  # an entry follows: cut through its comma and line break
            blk = blk[:i] + blk[blk.index("\n", e) + 1:]
        else:  # the last entry: cut from the previous entry's comma
            blk = blk[:blk.rindex(",", 0, i)] + blk[e:]
    return text[:a] + blk + text[b:]


def _obj_end(text: str, start: int) -> int:
    """The index just past the "}" that closes the object opening at text[start]."""
    level, j, in_str = 0, start, False
    while True:
        c = text[j]
        if in_str:
            if c == "\\":
                j += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            level += 1
        elif c == "}":
            level -= 1
            if level == 0:
                return j + 1
        j += 1


def dangling(src: dict, out: dict) -> list[str]:
    """Load check: every reference in the clone into his bag must still find its item, or the server refuses the
    character (live ClaudeQ6: CharCantLoad). A reference is an `...InventoryItemIndex` (a bag slot number; negative =
    none) anywhere outside the bag, or any value outside the bag equal to the GUID of a bag item the clone lost.
    -> the paths of the ones that point at nothing ([] = safe to write)."""
    inv0, inv = src["GameProgress"].get("Inventory") or {}, out["GameProgress"].get("Inventory") or {}
    lost = {v.get("GUID") for k, v in inv0.items() if k not in inv and isinstance(v, dict) and v.get("GUID")}
    bad: list[str] = []

    def walk(v, path: str) -> None:
        if path == "GameProgress.Inventory":
            return
        if isinstance(v, dict):
            for k, x in v.items():
                p = f"{path}.{k}" if path else k
                if k.endswith("InventoryItemIndex") and isinstance(x, int) and x >= 0 and str(x) not in inv:
                    bad.append(f"{p} = {x} (no bag slot {x})")
                walk(x, p)
        elif isinstance(v, list):
            for i, x in enumerate(v):
                walk(x, f"{path}[{i}]")
        elif isinstance(v, str) and v in lost:
            bad.append(f"{path} = {v} (the GUID of a stripped bag item)")
    walk(out, "")
    return bad


def render(text: str, out: dict) -> str:
    """The source file's text with only meta_data's guid and name and the QuestProgress block replaced, and the
    stripped bag slots cut out; every other byte (floats, position, order) stays as the game wrote it."""
    src = json.loads(text)
    a, b, depth = _block(text, "QuestProgress")
    if ue_json(src["GameProgress"]["QuestProgress"], depth) != text[a:b]:
        raise SystemExit("QuestProgress does not round-trip in the game's layout; not writing")
    body = text[:a] + ue_json(out["GameProgress"]["QuestProgress"], depth) + text[b:]
    for key in ("Inventory", "Loadout"):
        gone = [k for k in src["GameProgress"].get(key) or {} if k not in out["GameProgress"].get(key) or {}]
        if gone:
            body = _drop(body, key, gone)
    ch0, ch1 = src["GameProgress"].get("Character") or {}, out["GameProgress"].get("Character") or {}
    for blk, key in VITALS:  # only the number after the one `"<key>":`
        if (ch0.get(blk) or {}).get(key) == (ch1.get(blk) or {}).get(key):
            continue
        pat = re.compile(r'("%s":\s*)-?[0-9][0-9.eE+-]*' % key)
        if len(pat.findall(body)) != 1:
            raise SystemExit(f"{key} is not in the file exactly once")
        body = pat.sub(lambda m: m.group(1) + json.dumps(ch1[blk][key]), body)
    for k in ("char_guid", "char_name"):
        old = f'"{k}": {json.dumps(src["meta_data"][k])}'
        if body.count(old) != 1:
            raise SystemExit(f"{k} is not in the file exactly once")
        body = body.replace(old, f'"{k}": {json.dumps(out["meta_data"][k])}')
    if json.loads(body) != out:
        raise SystemExit("the rewritten file does not parse back to the clone; not writing")
    return body


def cmd_make(a) -> int:
    if a.name == SOURCE or not a.name:
        print("refusing: a clone needs its own name")
        return 2
    target = SAVE_DIR / f"{a.name}.json"
    if target.exists() and not a.force:
        print(f"{target} exists (pass --force to rewrite a clone that has never been loaded)")
        return 2
    raw = (SAVE_DIR / f"{SOURCE}.json").read_bytes().decode("utf-8")
    src = json.loads(raw)
    ids, names, suffixes = removal(tuple(a.quests))
    strip = deliverables(tuple(a.quests))
    out = clear(src, ids, names, suffixes, a.name, strip)
    bad = dangling(src, out)
    if bad:  # never hand the server a character it cannot load
        raise SystemExit("refusing to write the clone, it has references into the bag that find nothing:\n  "
                         + "\n  ".join(bad))
    text = render(raw, out).encode("utf-8")
    inv0, inv1 = src["GameProgress"].get("Inventory") or {}, out["GameProgress"].get("Inventory") or {}
    stripped = [{"slot": k, "item": strip[v["ItemData"]], "count": v.get("Count", 1)} for k, v in inv0.items()
                if k not in inv1 and isinstance(v, dict)]
    lo0, lo1 = src["GameProgress"].get("Loadout") or {}, out["GameProgress"].get("Loadout") or {}
    stripped += [{"loadout_slot": k, **v} for k, v in lo0.items() if k not in lo1]
    KEEP_DIR.mkdir(parents=True, exist_ok=True)
    (KEEP_DIR / f"{a.name}.json").write_bytes(text)
    tmp = target.with_suffix(".json.tmp")
    tmp.write_bytes(text)
    os.replace(tmp, target)
    qp0, qp1 = src["GameProgress"]["QuestProgress"], out["GameProgress"]["QuestProgress"]
    loc0, loc1 = ({l["QuestLocationId"] for l in q["QuestLocations"]} for q in (qp0, qp1))
    print(json.dumps({"clone": str(target), "kept_copy": str(KEEP_DIR / f"{a.name}.json"),
                      "char_guid": out["meta_data"]["char_guid"], "cleared_quests": sorted(ids.values()),
                      "quests": f"{len(qp0['Quests'])} -> {len(qp1['Quests'])}", "stripped_from_bag": stripped,
                      "removed_locations": sorted(loc0 - loc1), "added_locations": sorted(loc1 - loc0),
                      "tracked": f"{qp0.get('QuestTrackedMain')} -> {qp1.get('QuestTrackedMain')}"}, indent=1))
    return 0


def cmd_show(a) -> int:
    d = json.loads((SAVE_DIR / f"{a.name}.json").read_text(encoding="utf-8-sig"))
    qp = d["GameProgress"]["QuestProgress"]
    names = {q["id"]: q["asset"] for q in _probe(IDS_PROBE).get("quests") or []} if IDS_PROBE.exists() else {}
    print(d["meta_data"])
    for q in qp["Quests"]:
        print(f"  {names.get(q['QuestId'], q['QuestId']):<26} state {q['QuestState']} {q['QuestObjective']}")
    print("  locations:", [l["QuestLocationId"] for l in qp["QuestLocations"]], "tracked:", qp.get("QuestTrackedMain"))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("make")
    m.add_argument("--name", required=True)
    m.add_argument("--quests", nargs="+", default=list(CHAIN), help="QuestData assets to clear")
    m.add_argument("--force", action="store_true")
    s = sub.add_parser("show")
    s.add_argument("--name", required=True)
    a = ap.parse_args(argv)
    return {"make": cmd_make, "show": cmd_show}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

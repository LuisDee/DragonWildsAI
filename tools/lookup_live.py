r"""Goal item 3, live half (docs/GOAL-2026-11-17-long-jobs.md): a player asks about an enemy, a region or a vault in
chat, and his spoken answer is scored against the game and wiki facts, with the offline lookup evals' own scorer.

Per case: stop the body, say ONE line as the dev test player ("Tester", the dev server mod's speech_direct, the same
sender as tools/chat_ladder.py and tools/job_run.py), wait until the brain has answered and gone quiet, then score
  * hit / coverage: his `say` rows in the case's window against the case's SPOKEN key: only the offline answer groups
    of the fact types its question asks, by one written rule for every set (``spoken_key``, below; 2026-11-19, after
    window lk-20261119T050935Z keyed region levels for "where is tin"), matched with speech's tolerance (``said_has``:
    endings, word order in a short window, the bestiary's aliases); every key group needs one alternative; coverage
    is the share of groups he said;
  * used_lookup: a `lookup` call in the brain log in that window (Controller tool_call, Planner planner_research,
    Director director_lookup), with its queries;
  * lookup_hit: the same scorer over what his lookups returned (the facts were in front of him, or not).
The spoken form of a wiki level ("power level1 3") is also accepted as "level 3" / "level three": one rule for every
alternative, written before any live answer was read (``spoken``).

Sets, reported apart:
  * tuned:    evals/lookup_{enemies,regions,vaults}_cases.jsonl, per case;
  * heldout:  evals/lookup_{enemies,regions,vaults}_heldout.jsonl, SCORED, NEVER read for tuning: their rows carry
              no line, no answer and no case name (a short hash), and print as totals only (CLAUDE.md, Breadth);
  * decision: a line where knowledge should change an action ("should we go fight the garou with what you've got?").
              Scored ONLY on whether his answer cites the creature's true power level or health (data/bestiary.json);
              what he decides is recorded, never scored.
A case's line is "claude, <question>?"; a question that is only a name becomes "claude, what do you know about <name>?".

  .venv\Scripts\python.exe -m tools.lookup_live plan                     # lines, sets, the call estimate; no side effects
  .venv\Scripts\python.exe -m tools.lookup_live run --confirm --start-brain [--sets tuned,heldout,decision] [--limit N]
  .venv\Scripts\python.exe -m tools.lookup_live report                   # per window: tuned, held-out, decision apart
  .venv\Scripts\python.exe -m tools.lookup_live rescore --run lk-...       # a saved window, scored with today's keys

Rows: logs/evals/lookup_live.jsonl. Guards (tools/chat_ladder.py): --confirm; dev server only; no hold file; nobody
else drove the client in the last 60 s; the body fit; no other brain unless --use-running-brain; a Haiku call cap
(--max-haiku) and the brain's spend cap (today's spend + --usd). It moves nothing: no placement, no grants.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import random
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from brain import paths
from tools import obs

ROOT = paths.REPO_ROOT
OUT = ROOT / "logs" / "evals" / "lookup_live.jsonl"
FAMILIES = ("enemies", "regions", "vaults")
SETS = ("tuned", "heldout", "decision")
WORLD = "dev_lookup"     # a clean brain world store (no parked boards or old notes)
HEARD_S, QUIET_S, ANSWER_S, GAP_S, POLL_S = 30.0, 10.0, 150.0, 4.0, 2.0
CALLS_PER_CASE = (2, 4)  # Haiku calls a question costs: a turn that reads (lookup), a turn that says; a third if he reads twice

DECISIONS = [
    {"id": "decide-garou", "line": "claude, should we go fight the garou with what you've got?", "creature": "garou"},
    {"id": "decide-vault-overlord", "line": "claude, are we ready to take on the vault overlord with your gear?",
     "creature": "vault overlord"},
]

QUESTION_START = re.compile(r"^(what|whats|what's|how|where|which|who|whom|why|when|is|are|can|could|does|do|did|"
                            r"should|tell|will|would|any)\b", re.I)
NUM_WORDS = {str(i): w for i, w in enumerate(("zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                                              "nine", "ten", "eleven", "twelve"))}
POWER_LEVEL = re.compile(r"\bpower level(?:1)?\s+(\d+)\b", re.I)  # "power level1 3": the wiki's footnote 1


def _enemies_eval():
    spec = importlib.util.spec_from_file_location("lookup_enemies_eval", ROOT / "evals" / "lookup_enemies_eval.py")
    ev = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ev)
    return ev


EV = _enemies_eval()  # score, norm, returned_text: the offline evals' own


# ------------------------------------------------------------------------------ cases


def case_files(family: str) -> tuple[Path, Path]:
    return ROOT / "evals" / f"lookup_{family}_cases.jsonl", ROOT / "evals" / f"lookup_{family}_heldout.jsonl"


def _read_cases(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines() if x.strip()]


def line_for(question: str) -> str:
    """What the player says. A bare name ("Crasorak Kara") is asked about; a question is asked as it is."""
    q = " ".join(str(question or "").split()).rstrip(" ?.!")
    if not q:
        return ""
    if not QUESTION_START.match(q):
        q = f"what do you know about {q}"
    return f"claude, {q}?"


def hid(set_name: str, family: str, case_id: str) -> str:
    """A held-out case's name in the rows: stable across windows (paired counts), the case itself unread."""
    return f"{family}-{hashlib.sha1(case_id.encode('utf-8')).hexdigest()[:8]}" if set_name == "heldout" else case_id


def load(sets=SETS, families=FAMILIES) -> list[dict]:
    """Every case to ask, as {set, family, id, line, answers}. Held-out answers stay in memory for the scorer only."""
    out: list[dict] = []
    for fam in families:
        tuned, held = case_files(fam)
        for set_name, path in (("tuned", tuned), ("heldout", held)):
            if set_name not in sets:
                continue
            for c in _read_cases(path):
                k = spoken_key(c.get("question") or c["query"], c.get("kind"), c["answers"])
                out.append({"set": set_name, "family": fam, "id": hid(set_name, fam, c["id"]), "kind": c.get("kind"),
                            "line": line_for(c.get("question") or c["query"]), "answers": c["answers"],
                            "key": k["key"], "key_how": {x: k[x] for x in ("asked", "open", "fallback")}})
    if "decision" in sets:
        best = bestiary()
        for d in DECISIONS:
            facts = true_facts(best, d["creature"])
            out.append({"set": "decision", "family": "decision", "id": d["id"], "kind": "decision", "line": d["line"],
                        "creature": d["creature"], "answers": decision_answers(facts), "facts": facts,
                        "key": decision_answers(facts),  # its question asks the power level or health: the same rule
                        "key_how": {"asked": ["level", "number"], "open": False, "fallback": False}})
    return out


# ------------------------------------------------------------------------------ facts and scoring


def bestiary(path: Path | None = None) -> dict:
    try:
        return json.loads((path or ROOT / "data" / "bestiary.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def true_facts(best: dict, creature: str) -> dict:
    """The power levels and health of every bestiary creature the name covers ("garou": every Garou kind)."""
    want = EV.norm(creature)
    levels, health, names = set(), set(), []
    for name, c in ((best or {}).get("creatures") or {}).items():
        if not any(want in EV.norm(n) for n in [name, *(c.get("aliases") or [])]):
            continue
        names.append(name)
        for v in c.get("variants") or []:
            if re.fullmatch(r"\d+", str(v.get("power_level") or "").strip()):
                levels.add(str(v["power_level"]).strip())
            h = re.match(r"[\d,]+", str(v.get("health") or "").strip())
            if h:
                health.add(h.group(0))
    return {"creatures": sorted(names), "levels": sorted(levels, key=int), "health": sorted(health)}


def decision_answers(facts: dict) -> list[list[str]]:
    """One group: any true power level of the creature, or any true health figure. Empty facts: no group (never a hit)."""
    alts = [a for n in facts.get("levels") or [] for a in (f"level {n}", f"level {NUM_WORDS.get(n, n)}", f"pl {n}")]
    alts += list(facts.get("health") or [])
    return [alts] if alts else []


def spoken(answers: list[list[str]]) -> list[list[str]]:
    """Each group plus the spoken form of a wiki power level: "power level1 3" also as "level 3" and "level three"."""
    out = []
    for g in answers:
        extra = []
        for a in g:
            for m in POWER_LEVEL.finditer(str(a)):
                n = m.group(1)
                extra += [f"level {n}", f"level {NUM_WORDS.get(n, n)}", f"pl {n}", f"pl{n}"]
        out.append(list(dict.fromkeys([*g, *extra])))
    return out


def score_spoken(answers: list[list[str]], said: str, voc: dict | None = None) -> dict:
    groups = spoken(answers)
    hit, missing = said_score(groups, said, voc)
    return {"hit": bool(hit), "coverage": round((len(groups) - len(missing)) / len(groups), 3) if groups else 0.0,
            "missing": missing}


# ------------------------------------------------------------------------------ the spoken key (one written rule)
#
# The offline keys ask "does the lookup RESULT contain X" and hold every fact of the page (a region's level and garou
# kinds for "where is tin", a door coordinate, the boss for "how do I get in", a quest name). A spoken answer is keyed
# on only the facts its QUESTION asks. The rule, applied to every case of every set alike (no case is keyed by hand):
#   1. each offline answer group gets the fact types of its alternatives, from the bestiary's own names:
#      place (a region, province or vault name or alias, or any creature's location), creature (a creature name or
#      alias, a vault's enemy or boss, a region's resident), level ("power level N" / "level N"), number (a bare figure:
#      health, a coordinate), resist (resist/immune), weakness ("weak" or only damage kinds, with a damage kind the
#      bestiary uses), attack (in some creature's attack names, or a phrase of its attack notes); none: untyped
#      (an item, a quest, a way in);
#   2. the question's words name the types it asks (ASKS, in order): "where" or "which/what vault" ask a place and only
#      that; "what drops X" asks a source (creature, place or untyped); "drop/loot/chest" an item (untyped);
#      "attack/mechanics/fight" attacks; "weak/hurts" weakness; "resist/immune" resistance; "level/how strong/how
#      dangerous" the power level; "health" a number; "lives/enemies/inside/boss" creatures; "get in/enter/unlock"
#      a place or the way in (untyped);
#   3. a specific question keeps every group of an asked type; a question that asks none (a bare name, "what is X
#      like") is open and asks the thing's identity by the case's kind (OPEN), with all groups of one type merged into
#      one (any true fact of that type);
#   4. a key the rule leaves empty keeps the offline key (counted as a fallback, never silently).
# Matching (said_has) tolerates what speech changes and the facts do not: plural and verb endings ("putrid rats",
# "breathes", "resist"), word order inside a short window ("poison breath" ~ "breathes poison", "red, blue and green
# shades" ~ "red shade"), and the bestiary's aliases of a creature, vault or region name. A figure is matched in order.

OPEN = {"vault": ("place", "creature"), "region": ("level", "creature"), "resource": ("place",), "item": ("place",)}
OPEN_DEFAULT = ("place", "level")  # a creature (every enemies kind)
PLACE_ONLY = re.compile(r"\bwhere\b|\b(which|what) (vault|kara|region|area|place|province)\b", re.I)
ASKS = [
    (re.compile(r"\b(what|who|which \w+) drops\b", re.I), {"creature", "place", None}),
    (re.compile(r"\bdrops?\b|\bloot\b|\bchests?\b", re.I), {None}),
    (re.compile(r"\battacks?\b|\bmechanics?\b|\bfight\b|\bmoves\b", re.I), {"attack"}),
    (re.compile(r"\bweak|\bhurts?\b", re.I), {"weakness"}),
    (re.compile(r"\bresist|\bimmune", re.I), {"resist"}),
    (re.compile(r"\blevel\b|\bhow (strong|dangerous|tough|hard)\b", re.I), {"level"}),
    (re.compile(r"\bhealth\b|\bhp\b|\bhit ?points\b", re.I), {"number"}),
    (re.compile(r"\b(lives?|live|enemies|enemy|creatures?|monsters?|inside|boss|holds?)\b", re.I), {"creature"}),
    (re.compile(r"\bget (in|into)\b|\benter\b|\bunlock\b", re.I), {"place", None}),
]
STOP = {"the", "a", "an", "to", "of", "and", "or", "is", "are", "in", "its", "it", "s"}
WINDOW_SLACK = 3  # extra words a phrase may be spread over when spoken ("red, blue and green shades")
_VOCAB: dict | None = None


def stem(word: str) -> str:
    """A word without the endings speech adds (plural, verb, -ness/-ance): the same rule on both sides of a match."""
    w = word.lower()
    if len(w) <= 3 or w.isdigit():
        return w
    for suf, rep in (("ies", "y"), ("ves", "f"), ("ness", ""), ("ance", ""), ("ing", ""), ("ed", "")):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            w = w[: -len(suf)] + rep
            break
    if len(w) >= 7 and w.endswith("ant"):
        w = w[:-3]
    if w.endswith("s") and not w.endswith("ss") and len(w) > 3:
        w = w[:-1]
    if w.endswith("e") and len(w) > 3:
        w = w[:-1]
    return w


def stems(text: str) -> list[str]:
    return [stem(t) for t in EV.norm(text).split()]


def _key(text: str) -> tuple[str, ...]:
    return tuple(stems(text))


def vocab(best: dict | None = None) -> dict:
    """The bestiary's own names by fact type, its aliases, and the text of every attack (built once)."""
    global _VOCAB
    if best is None and _VOCAB is not None:
        return _VOCAB
    if best is None:  # always the real file (a test's stand-in bestiary() never becomes the cached vocabulary)
        try:
            b = json.loads((ROOT / "data" / "bestiary.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            b = {}
    else:
        b = best
    place, creature, aliases, styles, attack_names, attack_notes = set(), set(), {}, set(), [], []

    def alias_group(names):
        names = [n for n in names if n]
        for n in names:
            aliases.setdefault(_key(n), set()).update(names)

    for name, r in (b.get("regions") or {}).items():
        place.update(_key(n) for n in [name, *(r.get("aliases") or []), r.get("province")] if n)
        alias_group([name, *(r.get("aliases") or [])])
        creature.update(_key(x.get("name") or "") for x in r.get("residents") or [])
    for name, v in (b.get("vaults") or {}).items():
        place.update(_key(n) for n in [name, *(v.get("aliases") or []), v.get("area"), v.get("province")] if n)
        alias_group([name, *(v.get("aliases") or [])])
        creature.update(_key(x.get("name") or "") for x in v.get("enemies") or [])
        creature.update(_key(x.get("creature") or "") for x in v.get("boss") or [])
    for name, c in (b.get("creatures") or {}).items():
        creature.update(_key(n) for n in [name, *(c.get("aliases") or [])])
        alias_group([name, *(c.get("aliases") or [])])
        place.update(_key(x) for x in c.get("locations") or [])
        for k in ("weak", "resist", "immune"):
            for v in c.get(k) or []:
                styles.update(stems(v))
        attack_names += [str(a.get("name") or "") for a in (c.get("attacks") or []) + (c.get("observed_attacks") or [])]
        attack_names += [re.sub(r"(?<=[a-z])(?=[A-Z])", " ", str(a.get("name") or "")) for a in c.get("game_attacks") or []]
        attack_notes += [str(x) for x in c.get("attack_notes") or []]
    styles -= {"a", "n", "no", "none", "can", "be", "immune", "to", "any", "attack", "style", "level"}
    styles = {s for s in styles if not s.isdigit()}
    out = {"place": place - {()}, "creature": creature - {()}, "aliases": aliases, "styles": styles,
           "attack_names": " " + " ".join(stems(" \n ".join(attack_names))) + " ",
           "attack_notes": " " + " ".join(stems(" \n ".join(attack_notes))) + " "}
    if best is None:
        _VOCAB = out
    return out


def alt_types(alt: str, voc: dict) -> set:
    """The fact types of one answer alternative (rule step 1); an empty set is untyped."""
    a, k = str(alt).lower(), _key(alt)
    out = set()
    if re.search(r"\b(power )?level\s*1?\s+\d+|\bpl\s*\d", a):
        out.add("level")
    if re.fullmatch(r"[\d,.\s]+", a.strip()):
        out.add("number")
    if re.search(r"\bresist|\bimmun", a):
        out.add("resist")
    elif (re.search(r"\bweak", a) or set(k) <= voc["styles"]) and set(k) & voc["styles"]:
        out.add("weakness")
    if k in voc["place"]:
        out.add("place")
    if k in voc["creature"]:
        out.add("creature")
    phrase = f" {' '.join(k)} "
    if k and not out and (phrase in voc["attack_names"] or (len(k) > 1 and phrase in voc["attack_notes"])):
        out.add("attack")  # one word must be in an attack's name; a phrase may also be in the attack notes
    return out


def group_types(group: list[str], voc: dict) -> set:
    out = set()
    for a in group:
        out |= alt_types(a, voc) or {None}
    return out


def asked(question: str) -> set | None:
    """The fact types a question asks (rule step 2); None: it asks none (open)."""
    q = str(question or "")
    if PLACE_ONLY.search(q):
        return {"place"}
    out = set()
    for rx, types in ASKS:
        if rx.search(q):
            out |= types
    return out or None


def spoken_key(question: str, kind: str | None, answers: list[list[str]], voc: dict | None = None) -> dict:
    """{key, asked, open, fallback}: the case's spoken key by the rule above. Never reads any answer he gave."""
    voc = voc or vocab()
    typed = [(g, group_types(g, voc)) for g in answers]
    want = asked(question)
    if want is not None:
        key = [g for g, t in typed if t & want]
        how = {"asked": sorted(str(x) for x in want), "open": False}
    else:
        want_open = OPEN.get(str(kind or ""), OPEN_DEFAULT)
        key = []
        for t in want_open:
            merged = list(dict.fromkeys(a for g, ts in typed if t in ts for a in g))
            if merged:
                key.append(merged)
        how = {"asked": list(want_open), "open": True}
    if not key:
        return {"key": answers, **how, "fallback": True}
    return {"key": key, **how, "fallback": False}


def said_has(alt: str, said: list[str], voc: dict | None = None) -> bool:
    """One alternative in what he said (stemmed words): a figure in order, words within a short window, or any of the
    bestiary's aliases of the name."""
    voc = voc or vocab()
    forms = [alt, *sorted(voc["aliases"].get(_key(alt), ()))]
    for f in forms:
        toks = stems(f)
        if not toks:
            continue
        if any(t.isdigit() for t in toks) or len(toks) == 1:
            n = len(toks)
            if any(said[i:i + n] == toks for i in range(len(said) - n + 1)):
                return True
            continue
        content = {t for t in toks if t not in STOP} or set(toks)
        w = len(toks) + WINDOW_SLACK
        if any(content <= set(said[i:i + w]) for i in range(max(1, len(said) - w + 1))):
            return True
    return False


def said_score(groups: list[list[str]], text: str, voc: dict | None = None) -> tuple[bool, list[list[str]]]:
    """(hit, the groups he said nothing of): EV.score's shape with said_has's tolerance."""
    said = stems(text)
    missing = [g for g in groups if not any(said_has(a, said, voc) for a in g if EV.norm(a).strip())]
    return (bool(groups) and not missing), missing


def levels_said(text: str) -> list[str]:
    """Every "level N" he said (digits or words): recorded beside a decision, never scored."""
    words = {w: d for d, w in NUM_WORDS.items()}
    out = []
    for m in re.finditer(r"\blevel\s+(\d+|" + "|".join(words) + r")\b", text or "", re.I):
        v = m.group(1).lower()
        out.append(words.get(v, v))
    return out


# ------------------------------------------------------------------------------ the brain log of one case


def said_text(rows: list[dict]) -> list[str]:
    return [str(r.get("text") or "") for r in rows if r.get("kind") == "say" and r.get("text")]


def lookups(rows: list[dict]) -> list[dict]:
    """His lookup calls, by whoever made them: Controller (tool_call), Planner (planner_research), Director."""
    out = []
    for r in rows:
        k = r.get("kind")
        if k in ("tool_call", "planner_research") and r.get("tool") == "lookup":
            out.append({"by": "planner" if k == "planner_research" else "controller",
                        "query": str((r.get("args") or {}).get("query") or "")})
        elif k == "director_lookup":
            out.append({"by": "director", "query": str(r.get("query") or "")})
    return out


def lookup_returned(rows: list[dict]) -> str:
    """The text of what the Controller's lookups returned (tool_result rows): what he had in front of him."""
    return "\n".join(EV.returned_text((r.get("result") or {}).get("data") or {}) for r in rows
                     if r.get("kind") == "tool_result" and r.get("tool") == "lookup" and isinstance(r.get("result"), dict))


def heard(rows: list[dict], line: str) -> float | None:
    return next((r["ts"] for r in rows if r.get("kind") == "event" and
                 (r.get("event") or {}).get("type") in ("chat_heard", "command_received") and
                 obs._norm((r.get("event") or {}).get("text")) == obs._norm(line)), None)


def settled(rows: list[dict], now: float, t0: float) -> tuple[bool, float]:
    """(nothing open, seconds since the last brain activity): no prompt without its response, no tool call without
    its result."""
    busy = [r for r in rows if r.get("kind") in ("prompt", "llm_response", "tool_call", "tool_result", "say",
                                                 "planner_research")]
    open_prompt = bool(busy) and busy[-1].get("kind") == "prompt"
    called = {r.get("task_id") for r in rows if r.get("kind") == "tool_call" and r.get("task_id")}
    done = {r.get("task_id") for r in rows if r.get("kind") == "tool_result" and r.get("task_id")}
    reads = [r.get("kind") for r in rows if r.get("kind") in ("tool_call", "tool_result") and not r.get("task_id")]
    open_tools = bool(called - done) or reads.count("tool_call") > reads.count("tool_result")
    return (not open_prompt and not open_tools), now - (busy[-1]["ts"] if busy else t0)


def score_case(case: dict, rows: list[dict]) -> dict:
    """The scored row of one case from its window's brain rows (no I/O)."""
    from tools.chat_ladder import model_calls
    said = said_text(rows)
    text = "\n".join(said)
    key = case.get("key") or case["answers"]  # the spoken key (spoken_key); a hand-made case: its answers
    s = score_spoken(key, text)
    lk = lookups(rows)
    got = lookup_returned(rows)
    lk_hit = said_score(spoken(key), got)[0] if got else False
    calls = model_calls(rows)
    row = {"set": case["set"], "family": case["family"], "case": case["id"], "kind": case.get("kind"),
           "hit": s["hit"], "coverage": s["coverage"], "spoke": bool(said), "used_lookup": bool(lk),
           "lookups": len(lk), "lookup_hit": bool(lk_hit), "haiku_calls": calls["haiku"],
           "sonnet_calls": calls["sonnet"], "calls": calls["calls"], "usd": calls["usd"],
           "key_fallback": bool((case.get("key_how") or {}).get("fallback"))}
    if case["set"] == "heldout":  # scored, never read: no line, no answers, no words
        return row
    row.update({"line": case["line"], "said": said, "missing": s["missing"], "key_how": case.get("key_how"),
                "lookup_queries": [x["query"] for x in lk], "lookup_by": sorted({x["by"] for x in lk})})
    if case["set"] == "decision":  # what he decides is his: recorded, never scored
        row.update({"creature": case.get("creature"), "facts": case.get("facts"), "levels_said": levels_said(text),
                    "tools_called": [r.get("tool") for r in rows if r.get("kind") == "tool_call" and r.get("task_id")]})
    return row


# ------------------------------------------------------------------------------ one case, live or fake


class LiveIO:
    """The window's real I/O: the dev sender, the brain log, the body's stop."""

    def __init__(self, brain_file: Path, cli):
        self.brain_file, self.cli = brain_file, cli

    def send(self, line: str) -> tuple[bool, str]:
        from tools import m1_session
        return m1_session.send_speech_direct(line)

    def rows(self, t0: float, t1: float) -> list[dict]:
        from tools.chat_ladder import brain_rows
        return brain_rows([self.brain_file], t0, t1)

    def stop(self) -> None:
        try:
            self.cli.request("stop", {}, timeout=10)
        except Exception:  # noqa: BLE001  (a stop that fails leaves the next case's own guards)
            pass


def ask(case: dict, io, haiku_left: int, clock=time.time, sleep=time.sleep) -> dict:
    """Stop, send the case's line, wait until he answered and went quiet, score. Never raises on the game."""
    io.stop()
    sleep(GAP_S)
    t0 = clock()
    ok, detail = io.send(case["line"])
    if not ok:
        return {"set": case["set"], "family": case["family"], "case": case["id"], "skipped": True,
                "why": f"the line was not sent: {str(detail)[-160:]}"}
    from tools.chat_ladder import model_calls
    heard_at, why = None, None
    while True:
        now = clock()
        rows = io.rows(t0 - 1, now + 1)
        heard_at = heard_at or heard(rows, case["line"])
        calm, quiet = settled(rows, now, t0)
        if heard_at is None and now - t0 > HEARD_S:
            why = "never heard"
        elif model_calls(rows)["haiku"] > haiku_left:
            why = "haiku call cap"
        elif heard_at and calm and quiet >= QUIET_S and any(r.get("kind") == "llm_response" for r in rows):
            why = "quiet"
        elif now - t0 > ANSWER_S:
            why = "deadline"
        if why:
            break
        sleep(POLL_S)
    ended = clock()
    io.stop()  # a decision he acts on is his; the next question starts from a standing body
    row = score_case(case, io.rows(t0 - 1, ended + 1))
    row.update({"sent_at": obs._iso(t0), "heard_s": round(heard_at - t0, 1) if heard_at else None, "ended": why,
                "wall_s": round(ended - t0, 1)})
    return row


def order(cases: list[dict], seed: int) -> list[dict]:
    """Decisions first (no earlier answer about the same creature in his recent context), then tuned and held-out
    interleaved in a seeded shuffle (neither set always benefits from what the other set put in context)."""
    rest = [c for c in cases if c["set"] != "decision"]
    random.Random(seed).shuffle(rest)
    return [c for c in cases if c["set"] == "decision"] + rest


# ------------------------------------------------------------------------------ report


def _frac(rows: list[dict], key: str) -> str:
    return f"{sum(1 for r in rows if r.get(key))}/{len(rows)}"


def summary(rows: list[dict]) -> list[str]:
    out = []
    done = [r for r in rows if not r.get("skipped")]
    for set_name in SETS:
        rs = [r for r in done if r.get("set") == set_name]
        if not rs:
            continue
        cov = sum(r.get("coverage") or 0 for r in rs) / len(rs)
        head = "cited true level/health" if set_name == "decision" else "said every fact"
        line = (f"{set_name.upper():<9} {head} {_frac(rs, 'hit')}, mean coverage {cov:.0%}; used lookup "
                f"{_frac(rs, 'used_lookup')}; lookup returned the facts {_frac(rs, 'lookup_hit')}; spoke "
                f"{_frac(rs, 'spoke')}; calls haiku {sum(r.get('haiku_calls') or 0 for r in rs)} sonnet "
                f"{sum(r.get('sonnet_calls') or 0 for r in rs)}")
        if set_name != "decision":
            fams = {f: [r for r in rs if r.get("family") == f] for f in FAMILIES}
            line += "  (" + ", ".join(f"{f} {_frac(v, 'hit')}" for f, v in fams.items() if v) + ")"
        out.append(line)
    skipped = [r for r in rows if r.get("skipped")]
    if skipped:
        out.append(f"skipped {len(skipped)}: " + "; ".join(sorted({str(r.get('why'))[:80] for r in skipped})))
    return out


def case_line(row: dict) -> str | None:
    """One printed line per tuned or decision case; a held-out case prints nothing."""
    if row.get("set") == "heldout":
        return None
    if row.get("skipped"):
        return f"  skip {row['case']:<26} {row.get('why')}"
    mark = "hit " if row["hit"] else "MISS"
    s = (f"  {mark} {row['set'][:3]} {row['case']:<26} cov {row['coverage']:.0%} lookup {row['lookups']} "
         f"({'returned facts' if row['lookup_hit'] else 'facts not returned'}) {row.get('wall_s')} s "
         f"{row.get('ended')}")
    if row["set"] == "decision":
        s += f" levels said {row.get('levels_said')} true {row.get('facts', {}).get('levels')}"
    elif not row["hit"]:
        s += f"\n       missing: {row.get('missing')}"
    return s


# ------------------------------------------------------------------------------ commands


def cmd_plan(a) -> int:
    cases = load(_sets(a), _families(a))
    for c in cases:
        if c["set"] != "heldout":
            print(f"  {c['set']:<8} {c['family']:<8} {c['id']:<26} \"{c['line']}\"  groups {len(c['answers'])}")
    n = {s: sum(1 for c in cases if c["set"] == s) for s in SETS}
    print(f"cases: tuned {n['tuned']}, held-out {n['heldout']} (scored, never shown), decision {n['decision']}")
    lo, hi = CALLS_PER_CASE
    print(f"model calls: about {lo * len(cases)}-{hi * len(cases)} Haiku (Controller: {lo}-{hi} a question), Sonnet only "
          f"if he plans; cap --max-haiku (default {a.max_haiku}); brain spend cap = today's spend + --usd")
    return 0


def _sets(a) -> tuple[str, ...]:
    s = tuple(x.strip() for x in (getattr(a, "sets", None) or ",".join(SETS)).split(",") if x.strip())
    bad = [x for x in s if x not in SETS]
    if bad:
        raise SystemExit(f"unknown set(s) {bad}; sets are {SETS}")
    return s


def _families(a) -> tuple[str, ...]:
    return tuple(x.strip() for x in (getattr(a, "families", None) or ",".join(FAMILIES)).split(",") if x.strip())


def write_row(row: dict, path: Path | None = None) -> None:
    p = path or OUT
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": round(time.time(), 3), **row}, ensure_ascii=False, default=str) + "\n")


def run_cases(cases: list[dict], io, run_id: str, max_haiku: int, out: Path | None = None, brain_log: str = "",
              stop_check=lambda: None, clock=time.time, sleep=time.sleep, echo=print) -> list[dict]:
    """Ask every case in order; one row each to `out`. Stops at the Haiku cap, at a line never heard, or when
    stop_check() names a reason (someone else is driving the client)."""
    rows, haiku = [], 0
    for i, case in enumerate(cases):
        if (why := stop_check()):
            echo(f"stopping: {why}")
            break
        row = ask(case, io, max_haiku - haiku, clock=clock, sleep=sleep)
        row.update({"run_id": run_id, "order": i, "brain_log": brain_log})
        write_row(row, out)
        rows.append(row)
        haiku += row.get("haiku_calls") or 0
        if (ln := case_line(row)):
            echo(ln)
        if haiku >= max_haiku or row.get("ended") in ("never heard", "haiku call cap"):
            echo("stopping: " + ("Haiku call cap reached" if haiku >= max_haiku or row.get("ended") == "haiku call cap"
                                 else "the brain never heard the line"))
            break
    return rows


def cmd_run(a) -> int:
    from tools import chat_ladder as cl, spend
    if not a.confirm:
        print("refusing: a live window sends test chat to the brain on the dev server; pass --confirm")
        return 2
    a.world = a.world or WORLD
    bad = [b for b in cl.preflight(a) if not b.startswith("the nav helper")]  # nothing walks: routes are not needed
    if bad:
        print("not running:\n  " + "\n  ".join(bad))
        return 3
    cases = order(load(_sets(a), _families(a)), a.seed)
    cases = cases[:a.limit] if a.limit else cases
    before = spend.spend_today()
    print(f"spend before: ${before['spent_usd']:.4f} ({before['state']}); {len(cases)} cases, seed {a.seed}")
    if before["state"] != "ok":
        print("not running: spend is past the warn level")
        return 3
    ok, why = cl.ensure_sender()
    print(f"sender: {why}")
    if not ok:
        return 4
    cli = cl._debug_client()
    proc, bfile = (cl.start_brain(a, before["spent_usd"]) if a.start_brain else (None, None))
    bfile = bfile or cl._brain_file(a, proc)
    if bfile is None:
        cl.stop_brain(proc)
        print("not running: the brain did not start (logs/brain-chat-ladder-console.log)")
        return 4
    run_id = datetime.now(timezone.utc).strftime("lk-%Y%m%dT%H%M%SZ")
    t_run = time.time()
    try:
        rows = run_cases(cases, LiveIO(bfile, cli), run_id, a.max_haiku, brain_log=bfile.name,
                         stop_check=lambda: cl.foreign_driver(t_run) or next(
                             (f"hold file {p.name}" for p in cl.HOLD_FILES if p.exists()), None))
    finally:
        cl.stop_brain(proc)
    after = spend.spend_today()
    print(f"window {run_id}\n" + "\n".join(summary(rows)) +
          f"\nspend: ${before['spent_usd']:.4f} -> ${after['spent_usd']:.4f} (+${after['spent_usd'] - before['spent_usd']:.4f})")
    return 0


def cmd_report(a) -> int:
    rows = list(obs.jsonl(OUT)) if OUT.exists() else []
    runs: dict[str, list[dict]] = {}
    for r in rows:
        runs.setdefault(r.get("run_id") or "?", []).append(r)
    if not runs:
        print("no windows yet")
        return 1
    for rid, rs in runs.items():
        print(f"{rid}  ({len(rs)} cases, brain log {rs[0].get('brain_log')})")
        for ln in summary(rs):
            print("  " + ln)
    return 0


def _epoch(iso: str | None) -> float | None:
    try:
        return datetime.strptime(str(iso), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def rescore(rows: list[dict], cases: list[dict], brain_rows_of) -> list[dict]:
    """A window's rows scored again with today's keys, from the brain log of each case's own window (sent_at is cut to
    the second: [sent_at - 1, sent_at + wall_s + 2], as ask() reads [t0 - 1, end + 1]). brain_rows_of(file, t0, t1).
    A held-out row stays a held-out row: score_case gives it no line, answer or words."""
    by_id = {(c["set"], c["id"]): c for c in cases}
    out = []
    for r in rows:
        meta = {k: r.get(k) for k in ("sent_at", "heard_s", "ended", "wall_s", "run_id", "order", "brain_log")}
        c, t0 = by_id.get((r.get("set"), r.get("case"))), _epoch(r.get("sent_at"))
        if r.get("skipped") or c is None or t0 is None or not r.get("brain_log"):
            out.append({"set": r.get("set"), "family": r.get("family"), "case": r.get("case"), "skipped": True,
                        "why": r.get("why") or "no case or window to rescore", **meta})
            continue
        brain = brain_rows_of(r["brain_log"], t0 - 1, t0 + float(r.get("wall_s") or 0) + 2)
        out.append({**score_case(c, brain), **meta, "was_hit": bool(r.get("hit"))})
    return out


def cmd_rescore(a) -> int:
    """Score a saved window again with the spoken keys, from the brain log (nothing is written)."""
    src = Path(a.file) if a.file else OUT
    rows = [r for r in obs.jsonl(src) if r.get("run_id") == a.run] if src.exists() else []
    if not rows:
        print(f"no rows of {a.run} in {src}")
        return 1
    logs = Path(a.logs) if a.logs else paths.LIVE_ROOT / "logs"
    cache: dict[str, list[dict]] = {}

    def brain_rows_of(name: str, t0: float, t1: float) -> list[dict]:
        if name not in cache:
            f = logs / name
            cache[name] = sorted((d for d in obs.jsonl(f) if isinstance(d.get("ts"), (int, float))),
                                 key=lambda d: d["ts"]) if f.exists() else []
        return [d for d in cache[name] if t0 <= d["ts"] <= t1]

    new = rescore(rows, load(), brain_rows_of)
    print(f"{a.run}: {len(rows)} rows; offline keys (as run):")
    for ln in summary(rows):
        print("  " + ln)
    print("spoken keys (rescored):")
    for ln in summary(new):
        print("  " + ln)
    fb = {s: sum(1 for r in new if r.get("set") == s and r.get("key_fallback")) for s in SETS}
    print("  keys left to the offline key (rule found no asked fact): " + ", ".join(f"{s} {n}" for s, n in fb.items()))
    for r in new:
        if (ln := case_line(r)):
            print(ln + ("" if r.get("hit") == r.get("was_hit") else f"   (was {'hit' if r.get('was_hit') else 'MISS'})"))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "run"):
        p = sub.add_parser(name)
        p.add_argument("--sets", default=",".join(SETS), help="comma-separated: tuned, heldout, decision")
        p.add_argument("--families", default=",".join(FAMILIES), help="comma-separated: enemies, regions, vaults")
        p.add_argument("--max-haiku", type=int, default=200)
        if name == "run":
            p.add_argument("--confirm", action="store_true")
            p.add_argument("--limit", type=int, default=0, help="only the first N cases of the order")
            p.add_argument("--seed", type=int, default=int(time.time()) % 100000)
            p.add_argument("--start-brain", action="store_true", help="start a brain for the window (player Tester)")
            p.add_argument("--use-running-brain", action="store_true")
            p.add_argument("--world", default=WORLD)
            p.add_argument("--usd", type=float, default=1.50, help="the brain's spend cap above today's spend")
    sub.add_parser("report")
    r = sub.add_parser("rescore", help="score a saved window again with the spoken keys (prints; writes nothing)")
    r.add_argument("--run", required=True, help="the window's run_id, e.g. lk-20261119T050935Z")
    r.add_argument("--file", default="", help="rows file (default logs/evals/lookup_live.jsonl)")
    r.add_argument("--logs", default="", help="the brain logs' directory (default the live tree's logs)")
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    return {"plan": cmd_plan, "run": cmd_run, "report": cmd_report, "rescore": cmd_rescore}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())

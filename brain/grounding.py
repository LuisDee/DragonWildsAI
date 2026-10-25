"""Grounding as ASSISTANCE (streamline plan step 4, R4): which perceived things the player's words
could mean, typos and all, given to the model as information.

Live bugs (2026-10-25):
- 19:23-19:25: code-side grounding turned leftover chat words into item names and refused the
  model's (correct) target: "I can't see any dsgrab / look then / smh / find path around here".
- Later: for "here man pick these runes up" Haiku correctly called pickup(item="Rune", limit=20),
  and the code veto refused it because "man runes" didn't match.

Binding rule (Luis, docs/design/PRINCIPLES.md #2): code never vetoes or rewrites the model's tool or
args based on the player's wording, and uses no phrase or keyword tables. So this module only
INFORMS:
- ``read(text, things)``: the player's words that match something perceived right now, typo-tolerant
  ("pumkin" -> Pumpkin, "infusuion" -> Infusion, "sandwhiches" -> Sandwich). Words that match nothing
  perceived are simply not references; nothing is ever said back from them.
- ``hints(reading)``: compact candidate matches (name, id, distance) for the Controller context
  (``references``). The model decides, and asks the player when unsure; the body reports outcomes
  truthfully.

Matching uses the stdlib difflib SequenceMatcher (searched 2026-10-25: difflib is the no-dependency
option; rapidfuzz only pays off on large candidate lists). Guards from the live lines: fuzzy only for
words of 5+ letters, with the same first letter ("what"~"wheat" and "bring"~"ring" are not typos),
and a ratio of at least 0.84 ("sonon"~"onion" at 0.80 is rejected).
"""
from __future__ import annotations

import difflib
import re
from dataclasses import dataclass, field
from typing import Iterable

from . import situation as sit

FUZZY_CUTOFF, FUZZY_MIN_LEN = 0.84, 5
MAX_HINTS = 4  # references per command
MAX_MATCHES = 3  # candidates per reference


def _clean(word: str) -> str:
    """'infr0ont' -> 'infroont', 'sooo' -> 'soo': digits typed for letters, long repeats."""
    w = word.lower().translate(str.maketrans("01345", "oleas"))
    w = re.sub(r"[^a-z]", "", w)
    return re.sub(r"(.)\1{2,}", r"\1\1", w)


def _stem(word: str) -> str | None:
    """The digest's own stemming ('sandwiches' -> 'sandwich'); None for words it ignores."""
    t = sit.tokens(word)
    return next(iter(t)) if t else None


def ref_words(thing: sit.Thing) -> set[str]:
    """Words that identify a thing by what it IS: its name, what it gives, its item id. Not its kind
    or prompt ('item', 'Collect'), which every thing of that sort shares."""
    words = set() if "DEFAULT DISPLAY NAME" in (thing.name or "") else sit.tokens(thing.name)
    for g in thing.gives:
        words |= sit.tokens(g)
    for e in thing.extra:
        if e and e.upper().startswith("ITEM_"):
            words |= sit.tokens(e)
    return {w for w in words if len(w) >= 3}


def similar(word: str, other: str) -> bool:
    if word == other:
        return True
    if len(word) < FUZZY_MIN_LEN or word[0] != other[:1]:
        return False
    return difflib.SequenceMatcher(None, word, other).ratio() >= FUZZY_CUTOFF


@dataclass
class Ref:
    said: str  # as typed
    word: str  # the perceived word it matched ('pumpkin')
    things: list[sit.Thing] = field(default_factory=list)


@dataclass
class Reading:
    text: str
    refs: list[Ref] = field(default_factory=list)

    def corrected(self) -> dict[str, str]:
        return {r.said: r.word for r in self.refs if r.said != r.word}


def read(text: str | None, things: Iterable[sit.Thing], exclude: Iterable[str] = ()) -> Reading:
    """The player's words that refer to perceived things. ``exclude``: people's names (the player,
    the companion), which are addressed, not things."""
    things = [t for t in things if t.kind != "player"]
    skip = {w for e in exclude for w in sit.tokens(str(e))}
    index: dict[str, list[sit.Thing]] = {}
    for t in things:
        for w in ref_words(t):
            index.setdefault(w, []).append(t)
    r = Reading(text or "")
    seen = set()
    for raw in re.findall(r"[A-Za-z0-9']+", r.text):
        w = _stem(_clean(raw))
        if not w or w in skip or w in seen:
            continue
        seen.add(w)
        hit = w if w in index else next((k for k in index if similar(w, k)), None)
        if hit:
            r.refs.append(Ref(raw.lower(), hit, list(index[hit])))
    return r


def hints(reading: Reading) -> list[dict]:
    """For the model: [{said, matches: [{name, id, distance_m, kind}]}], nearest first, bounded."""
    out = []
    for ref in reading.refs[:MAX_HINTS]:
        best: dict[str, sit.Thing] = {}
        for t in sorted(ref.things, key=lambda t: t.distance if t.distance is not None else 1e9):
            best.setdefault(t.name, t)
        matches = [{"name": t.name, "id": t.id, "kind": t.kind,
                    "distance_m": round(t.distance, 1) if isinstance(t.distance, (int, float)) else None}
                   for t in list(best.values())[:MAX_MATCHES]]
        out.append({"said": ref.said, **({"read_as": ref.word} if ref.said != ref.word else {}), "matches": matches})
    return out

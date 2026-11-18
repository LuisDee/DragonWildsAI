"""A structured entry per creature and per vault (or dungeon), built from the wiki mirror's own structure, plus the
reverse index "what gives item X". Output: data/bestiary.json. Offline: no model, no game, no network.

Sources (all in the repo, read only):
* data/wiki/pages/*.json  the wiki mirror (CC BY-NC-SA, see data/wiki/manifest.json): monster infoboxes, DropsLine
  rows, Attacks / Combat mechanics sections, "<Name>/Strategies" pages, vault pages (Enemies tables, Resources),
  "Chest (<vault>)" pages, the "Boss" page tables and the "Dragonkin Vault" page tables.
* data/wiki/manifest.json  the wiki's redirects, used as aliases.
* dumps/<build>/UE4SS_ObjectDump.txt and data/skills/dev/combat_knowledge.json (optional): the game's class and
  asset names for a creature (BP_AI_GiantRat_..., ATK_GiantRat_...), used as aliases. Names only.
* data/skills/*/combat_knowledge.json and combat_memory_*.json (optional, gitignored, written by his own client): the
  enemy attacks he has met in his own fights, by the game's attack asset name (ATK_GiantRat_Attack_01), with the
  measured wind-up, lunge and the damage he took. Field ``observed_attacks``, src tag "own fights".
* data/bestiary_external.json (committed snapshot; refresh with ``fetch-metabot``): the weakness, resistance and
  immunity lines of metabot.gg's datamined Dragonwilds bestiary (https://metabot.gg/en/dragonwilds/bestiary; its terms:
  free to use with a credit link to that page). Used only to fill a weak/resist/immune field the wiki lacks; src tag
  "metabot.gg". Its "No notable affinities" is not used: on 11 creatures its own journal line contradicts it.

Neither the game dump nor the mirror holds attack damage, affinities or vault chest items: the dump has only the
data-table names (docs/research/2026-11-17-bestiary-gaps.md has the read-only live probe plan).
* ``--from-probe`` (optional, repeatable): the output of client_mod/commands/bestiary_tables_probe.lua run on his client
  (the game's journal weaknesses, attack damage table, each loaded attack's damage types and flags, the enemy loot
  tables, loaded vault chests' loot rolls). Src tag "game"; merged last, so it outranks the wiki and metabot.gg (a
  replaced value is kept under ``differs``). Fields ``journal``, ``game_attacks``, ``game_drops``, vault ``chest_items``.

Each entry carries ``text``: what a player reads (facts only, no advice, no order of actions), under 1,500 characters,
and ``src``: for every field, the wiki page ids it came from.

    .venv\\Scripts\\python.exe -m tools.build_bestiary build            # writes data/bestiary.json
    .venv\\Scripts\\python.exe -m tools.build_bestiary build --from-probe client_io/out/bestiary_tables_probe.json
    .venv\\Scripts\\python.exe -m tools.build_bestiary show "giant rat"  # what the lookup would return first
    .venv\\Scripts\\python.exe -m tools.build_bestiary score            # tuned half of evals/lookup_enemies_eval.py
    .venv\\Scripts\\python.exe -m tools.build_bestiary score --heldout-once   # adds the held-out half's one number
    .venv\\Scripts\\python.exe -m tools.build_bestiary fetch-metabot [--html saved.html]  # refresh the snapshot (network)

``score`` runs the existing eval's own functions with a lookup that consults data/bestiary.json first and falls back
to brain.knowledge.Knowledge.lookup. No brain file is changed.
"""
from __future__ import annotations

import argparse
import html
import importlib.util
import json
import re
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
WIKI = ROOT / "data" / "wiki"
OUT = ROOT / "data" / "bestiary.json"
DUMP = ROOT / "dumps" / "26574459" / "UE4SS_ObjectDump.txt"
COMBAT_KNOWLEDGE = ROOT / "data" / "skills" / "dev" / "combat_knowledge.json"
SKILLS = ROOT / "data" / "skills"  # <world>/combat_knowledge.json, <world>/combat_memory_<character>.json
EXTERNAL = ROOT / "data" / "bestiary_external.json"
METABOT_URL = "https://metabot.gg/en/dragonwilds/bestiary"
OWN = "own fights"  # src tag: observed by his own client
METABOT = "metabot.gg"  # src tag: metabot.gg's datamined bestiary
GAME = "game"  # src tag: the game's own tables, read on his client (client_mod/commands/bestiary_tables_probe.lua)
SCHEMA = "dw_bestiary/1"
ENTRY_CHARS = 1500  # an entry's text, at most
TEXT_BUDGET = 3000  # all result texts of one lookup with the bestiary (entries first, then the old lookup's results)
MAX_ENTRIES = 2  # entries per lookup

# A sentence that tells the reader what to do is advice, not a fact: such sentences are left out of every entry.
ADVICE = re.compile(r"\b(recommend\w*|should|advis\w*|suggest\w*|it is (?:best|better|easier|wise)|much easier|"
                    r"make sure|be careful|beware|watch (?:out|for)|you can|you will need|you'll want|"
                    r"players? (?:will )?(?:need|want) to|try to|don't|do not)\b", re.I)
ATTACK_HEAD = re.compile(r"attack|mechanic|moveset|abilit|combat|phase", re.I)
ATTACK_SENT = re.compile(r"\battacks? (?:are|is|include|includes|consist)\b", re.I)
LEAD_ATTACK = re.compile(r"\b(attack\w*|breath|strikes?|charges?|slams?|spits?|throws?|barrages?)\b", re.I)
# A lead sentence on how the creature reacts to a player: it flees, flies or runs away, or is too fast to catch.
BEHAVIOUR = re.compile(r"\b(?:fle(?:e|es|eing|d)|run(?:s|ning)? away|ran away|fl(?:y|ies|ew|ying) (?:away|off)|scared|"
                       r"too fast to|outrun\w*)\b", re.I)
OPENS = re.compile(r"\b(locked|unlock\w*|open(?:ed|s)?|keys?|requires?|must be|effig\w*|statues?|levers?|blocked|"
                   r"cleared|mined|cut through|soul rift\w*)\b", re.I)


# ------------------------------------------------------------------------------ wikitext


def find_templates(text: str) -> list[tuple[int, int, str, str]]:
    """Top-level templates: (start, end, name, inner) with nested {{ }} balanced."""
    out, i, n = [], 0, len(text)
    while True:
        i = text.find("{{", i)
        if i < 0:
            return out
        depth, j = 0, i
        while j < n - 1:
            two = text[j:j + 2]
            if two == "{{":
                depth += 1
                j += 2
            elif two == "}}":
                depth -= 1
                j += 2
                if depth == 0:
                    break
            else:
                j += 1
        inner = text[i + 2:j - 2] if depth == 0 else text[i + 2:]
        name = re.split(r"[|\n]", inner, 1)[0].strip()
        out.append((i, j, name, inner))
        if depth != 0:
            return out
        i = j


def split_top(inner: str) -> list[str]:
    """Split on '|' outside nested {{ }} and [[ ]]."""
    parts, buf, depth, i = [], [], 0, 0
    while i < len(inner):
        two = inner[i:i + 2]
        if two in ("{{", "[["):
            depth += 1
            buf.append(two)
            i += 2
            continue
        if two in ("}}", "]]") and depth:
            depth -= 1
            buf.append(two)
            i += 2
            continue
        if inner[i] == "|" and depth == 0:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(inner[i])
        i += 1
    parts.append("".join(buf))
    return parts


def params(inner: str) -> tuple[list[str], dict[str, str]]:
    """A template's positional and named params (names lower case, spaces and underscores folded)."""
    pos, named = [], {}
    for p in split_top(inner)[1:]:
        m = re.match(r"\s*([A-Za-z0-9_ \-]+?)\s*=(.*)$", p, re.S)
        if m:
            named.setdefault(re.sub(r"[\s_]+", "_", m.group(1).strip().lower()), m.group(2).strip())
        else:
            pos.append(p.strip())
    return pos, named


def _link(m: re.Match) -> str:
    inner = m.group(1)
    if re.match(r"\s*(file|image|category|media):", inner, re.I):
        return ""
    parts = inner.split("|")
    return (parts[-1] if len(parts) > 1 else parts[0].split("#")[0]).strip()


def _template_text(m: re.Match) -> str:
    inner = m.group(1)
    parts = [p.strip() for p in inner.split("|")]
    name = parts[0].lower()
    named = {k.strip().lower(): v.strip() for k, v in (p.split("=", 1) for p in parts[1:] if "=" in p)}
    pos = [p for p in parts[1:] if "=" not in p]
    if name in ("plink", "plinkt"):
        return named.get("txt") or (pos[0] if pos else "")
    if name == "rsl":
        return pos[1] if len(pos) > 1 else (pos[0] if pos else "")
    if name == "na":
        return "none"
    if name in ("dropnote", "nowrap", "small"):
        return pos[0] if pos else ""
    return ""


def plain(text: str) -> str:
    """Wikitext to the words a reader sees: links to their label, known inline templates to text, the rest dropped."""
    s = text or ""
    s = re.sub(r"<!--.*?-->", "", s, flags=re.S)
    s = re.sub(r"<ref[^>]*/>", "", s)
    s = re.sub(r"<ref[^>]*>.*?</ref>", "", s, flags=re.S)
    s = re.sub(r"<gallery.*?</gallery>", "", s, flags=re.S | re.I)
    for _ in range(6):  # innermost first
        s2 = re.sub(r"\[\[([^\[\]]*)\]\]", _link, s)
        s2 = re.sub(r"\{\{([^{}]*)\}\}", _template_text, s2)
        if s2 == s:
            break
        s = s2
    s = re.sub(r"\{\|.*?\|\}", "", s, flags=re.S)  # tables are read by table_rows, never as prose
    s = re.sub(r"'{2,}", "", s)
    s = re.sub(r"<br\s*/?>", ", ", s, flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(s).replace(" ", " ")
    s = re.sub(r"[ \t]+", " ", s)
    return s.strip()


def one_line(text: str) -> str:
    t = plain(text)
    t = re.sub(r"\n\s*\*+\s*", "; ", t)  # a bullet list inside one value
    t = re.sub(r"^\s*\*+\s*", "", t)
    return re.sub(r"\s+", " ", t).strip(" ,;")


def bullets(text: str, level: int = 1) -> list[str]:
    """The plain text of each bullet of exactly ``level`` stars."""
    rx = re.compile(r"^\*{%d}(?!\*)\s*(.+)$" % level, re.M)
    return [b for b in (one_line(m.group(1)) for m in rx.finditer(text or "")) if b]


def sentences(text: str) -> list[str]:
    """Sentences, never across a line break (a heading or a bullet ends a sentence)."""
    out = []
    for line in re.split(r"\n+", text or ""):
        t = re.sub(r"\s+", " ", line).strip()
        if not t or re.fullmatch(r"=+.*=+", t):
            continue
        out += [s.strip() for s in re.split(r"(?<=[.!?])\s+(?=[A-Z\"'(])", t) if s.strip()]
    return out


# A clause that starts with an order ("dodge the attack", "Simply dodge out of the way") is advice too.
IMPERATIVE = re.compile(r"^\s*(?:simply |just |then |so )?(?:dodge|block|use|stay|avoid|keep|run|step|move|parry|wait|"
                        r"retaliate|roll|stand|bring|equip|go|hide|focus|kill|lure|stack|cast|drink|eat|pray|position|"
                        r"remember|note that|consider)\b", re.I)


def fact_clauses(sentence: str) -> str:
    """The sentence without its advice clauses ('X; dodge it, then hit back' -> 'X.'); '' when nothing is left."""
    keep = []
    for clause in re.split(r";\s*|,\s*(?=then\b)", sentence):
        if clause.strip() and not ADVICE.search(clause) and not IMPERATIVE.search(clause):
            keep.append(clause.strip().rstrip("."))
    out = "; ".join(keep)
    return out[:1].upper() + out[1:] + "." if keep else ""


def facts_only(sents: Iterable[str]) -> list[str]:
    return [f for f in (fact_clauses(s) for s in sents) if f]


def sections(wikitext: str) -> list[dict]:
    """[{level, heading, path, body}], the lead first (level 1, heading None). ``path`` holds parent headings."""
    out = [{"level": 1, "heading": None, "path": [], "body": ""}]
    stack: list[tuple[int, str]] = []
    for line in (wikitext or "").split("\n"):
        m = re.match(r"^(={2,6})\s*(.*?)\s*\1\s*$", line)
        if m:
            lvl, head = len(m.group(1)), one_line(m.group(2))
            while stack and stack[-1][0] >= lvl:
                stack.pop()
            out.append({"level": lvl, "heading": head, "path": [h for _, h in stack], "body": ""})
            stack.append((lvl, head))
        else:
            out[-1]["body"] += line + "\n"
    return out


def link_targets(text: str) -> list[str]:
    return [m.group(1).split("#")[0].strip() for m in re.finditer(r"\[\[([^\]|#]+(?:#[^\]|]*)?)(?:\|[^\]]*)?\]\]", text or "")
            if not re.match(r"\s*(file|image|category|media):", m.group(1), re.I)]


def _cell_attr_strip(cell: str) -> tuple[str, int]:
    """'colspan="2" |Boss' -> ('Boss', 2). Only when the part before the bar is attributes."""
    m = re.match(r'^\s*((?:[a-z\-]+\s*=\s*(?:"[^"]*"|\S+)\s*)+)\|(?!\|)(.*)$', cell, re.S | re.I)
    if m and "[[" not in m.group(1) and "{{" not in m.group(1):
        span = re.search(r'colspan\s*=\s*"?(\d+)', m.group(1), re.I)
        return m.group(2), int(span.group(1)) if span else 1
    return cell, 1


def table_rows(text: str) -> list[tuple[list[str], list[list[str]]]]:
    """Every wikitable in ``text``: (header names, rows of raw cells). Header colspans are expanded."""
    out = []
    for tm in re.finditer(r"^\{\|.*?^\|\}", text or "", re.S | re.M):
        header: list[str] = []
        rows: list[list[str]] = []
        for chunk in re.split(r"^\|-.*$", tm.group(0), flags=re.M):
            cells: list[str] = []
            is_head = False
            for line in chunk.split("\n"):
                if line.startswith("{|") or line.startswith("|}") or line.startswith("|+"):
                    continue
                if line.startswith("!"):
                    is_head = True
                    for c in re.split(r"!!|\|\|", line[1:]):
                        c, span = _cell_attr_strip(c)
                        cells += [one_line(c)] * span
                elif line.startswith("|"):
                    for c in line[1:].split("||"):
                        cells.append(_cell_attr_strip(c)[0])
                elif cells:
                    cells[-1] += "\n" + line
            if not cells:
                continue
            if is_head and not rows:
                header = [one_line(c) for c in cells]  # the last header row before the data names the columns
            elif is_head and all(not re.search(r"\w", c) for c in cells):
                continue
            elif not is_head:
                rows.append(cells)
        out.append((header, rows))
    return out


def cell_items(cell: str) -> list[str]:
    """A table cell as a list: its bullet lines or lines, plain, without 'none' and set headings ('...set:')."""
    lines = [one_line(re.sub(r"^\*+\s*", "", ln)) for ln in re.split(r"\n|<br\s*/?>", cell or "", flags=re.I)]
    return [x for x in lines if x and x.lower() not in ("none", "n/a", "-") and not x.endswith(":")]


# ------------------------------------------------------------------------------ the mirror


class Mirror:
    """The wiki mirror on disk, with title resolution through the wiki's own redirects."""

    def __init__(self, root: Path = WIKI):
        man = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        self.redirects: dict[str, str] = man.get("redirects") or {}
        self.pages: dict[str, dict] = {}
        for title, meta in (man.get("pages") or {}).items():
            p = root / meta["file"]
            if p.exists():
                d = json.loads(p.read_text(encoding="utf-8"))
                self.pages[d.get("title") or title] = d
        self._lower = {t.lower(): t for t in self.pages}
        self._redir_lower = {k.lower(): v for k, v in self.redirects.items()}

    @classmethod
    def from_pages(cls, pages: dict[str, dict], redirects: dict[str, str] | None = None) -> "Mirror":
        m = cls.__new__(cls)
        m.pages, m.redirects = dict(pages), dict(redirects or {})
        m._lower = {t.lower(): t for t in m.pages}
        m._redir_lower = {k.lower(): v for k, v in m.redirects.items()}
        return m

    def resolve(self, name: str) -> str | None:
        n = (name or "").strip().replace("_", " ")
        if not n:
            return None
        for cand in (n, n[:1].upper() + n[1:]):
            if cand in self.pages:
                return cand
        hit = self._lower.get(n.lower())
        if hit:
            return hit
        tgt = self._redir_lower.get(n.lower())
        if tgt:
            return self._lower.get(tgt.lower(), tgt)
        if n.lower().endswith("s"):  # [[Vault core|Vault cores]] style plurals in plain names
            return self._lower.get(n.lower()[:-1])
        return None

    def pid(self, title: str) -> int | None:
        d = self.pages.get(title)
        return int(d["pageid"]) if d and d.get("pageid") is not None else None

    def wikitext(self, title: str) -> str:
        return (self.pages.get(title) or {}).get("wikitext") or ""

    def aliases_of(self, title: str) -> list[str]:
        return [k for k, v in self.redirects.items() if v == title]


class Src:
    """Per-field page ids for one entry."""

    def __init__(self):
        self.d: dict[str, list[int]] = defaultdict(list)

    def add(self, field: str, pid: int | str | None) -> None:  # a wiki page id, or a named source (OWN, METABOT)
        if pid is not None and pid not in self.d[field]:
            self.d[field].append(pid)

    def out(self) -> dict[str, list[int]]:
        return {k: v for k, v in self.d.items() if v}


# ------------------------------------------------------------------------------ creatures


def monster_infoboxes(wikitext: str) -> list[tuple[str | None, dict[str, str]]]:
    """(label, named params) per Infobox Monster, inside a Multi Infobox or not. Label from the Multi Infobox textN."""
    out = []
    for s, e, name, inner in find_templates(wikitext):
        low = name.lower()
        if low == "infobox monster":
            out.append((None, params(inner)[1]))
        elif low == "multi infobox":
            _, named = params(inner)
            for key, val in named.items():
                m = re.match(r"item(\d+)$", key)
                if not m:
                    continue
                for _, _, nm, inn in find_templates(val):
                    if nm.lower() == "infobox monster":
                        out.append((one_line(named.get(f"text{m.group(1)}", "")) or None, params(inn)[1]))
    return out


def _list_values(raw: str | None) -> list[str]:
    """'* 5\\n* 6' or '[[A]]<br>[[B]]' or 'A, B' -> items, plain."""
    if not raw:
        return []
    raw = re.sub(r"<br\s*/?>", "\n", raw, flags=re.I)
    if re.search(r"^\s*\*", raw, re.M):
        items = [one_line(x) for x in re.split(r"^\s*\*+", raw, flags=re.M)]
    else:
        items = [one_line(x) for x in raw.split("\n")]
    return [x for x in items if x]


def _split_names(v: str) -> list[str]:
    out = []
    for part in re.split(r",|\band\b|/", v or ""):
        part = part.strip(" .")
        if part:
            out.append(part)
    return out


def variants_of(label: str | None, box: dict[str, str]) -> list[dict]:
    """Versions of one monster infobox: [{label, power_level, health, location}]."""
    nums = sorted({int(m.group(1)) for k in box for m in [re.match(r"(?:version|power_level|health|location)(\d+)$", k)] if m})
    out = []
    if nums:
        for n in nums:
            pl = one_line(box.get(f"power_level{n}") or box.get("power_level") or "")
            hp = one_line(box.get(f"health{n}") or box.get("health") or "")
            loc = _list_values(box.get(f"location{n}") or box.get("location") or "")
            ver = one_line(box.get(f"version{n}") or "")
            if re.fullmatch(r"(?:power level|pl|level) ?\d+", ver, re.I):
                ver = ""
            out.append({"label": " ".join(x for x in (label, ver) if x) or None, "power_level": pl, "health": hp,
                        "location": loc})
        return out
    pls, hps = _list_values(box.get("power_level")), _list_values(box.get("health"))
    loc = _list_values(box.get("location"))
    if len(pls) > 1 or len(hps) > 1:
        for i in range(max(len(pls), len(hps))):
            pl = pls[i] if i < len(pls) else ""
            hp = hps[i] if i < len(hps) else ""
            m = re.match(r"(.*?)\s*\((.+)\)\s*$", pl)
            sub = None
            if m:
                pl, sub = m.group(1), m.group(2)
            hp = re.sub(r"\s*\(.+\)\s*$", "", hp)
            out.append({"label": " ".join(x for x in (label, sub) if x) or None, "power_level": pl, "health": hp,
                        "location": loc if len(pls) <= 1 else []})
        return out
    return [{"label": label, "power_level": pls[0] if pls else "", "health": hps[0] if hps else "", "location": loc}]


def drops_of(wikitext: str) -> list[dict]:
    """DropsLine rows: item, amount, rate, note, group (the heading above them)."""
    out = []
    for sec in sections(wikitext):
        for _, _, name, inner in find_templates(sec["body"]):
            if name.lower() != "dropsline":
                continue
            _, p = params(inner)
            item = one_line(p.get("name", ""))
            if not item:
                continue
            rate = one_line(p.get("rarity", ""))
            row = {"item": item, "amount": one_line(p.get("quantity", "")), "rate": "always" if rate.lower() == "always" else rate,
                   "group": sec["heading"] or ""}
            note = one_line(p.get("raritynotes", ""))
            if note:
                row["note"] = note
            out.append(row)
    return out


def _attack_item(b: str) -> dict | None:
    """One attack bullet: {name, does} with advice clauses removed; None when only advice is left."""
    m = re.match(r"^([^:.]{2,40}?)\s*(?::| - | – | — |, where )\s*(.+)$", b)
    if m and not IMPERATIVE.search(m.group(1)):
        does = " ".join(facts_only(sentences(m.group(2))))
        return {"name": m.group(1).strip(), "does": does}
    does = " ".join(facts_only(sentences(b)))
    return {"name": "", "does": does} if does else None


def _attack_items(body: str) -> list[dict]:
    out = [x for x in (_attack_item(b) for b in bullets(body, 1)) if x]
    if not out:  # prose only
        for s in facts_only(sentences(plain(body)))[:3]:
            out.append({"name": "", "does": s})
    return out


def attacks_of(mirror: Mirror, title: str, src: Src) -> tuple[list[dict], list[str]]:
    """Attack list from the page's attack-like sections and from a Strategies page's "main attacks are:" list, and
    statement sentences ("His main attacks are ...") from the Strategies page and from the lead (after its first
    sentence, which is the entry's lead)."""
    items: list[dict] = []
    said: list[str] = []
    secs = sections(mirror.wikitext(title))
    for sec in secs[1:]:
        if sec["heading"] and ATTACK_HEAD.search(sec["heading"]) and "drop" not in sec["heading"].lower():
            got = _attack_items(sec["body"])
            if got:
                items += got
                src.add("attacks", mirror.pid(title))
    lead = facts_only(sentences(plain(secs[0]["body"]))) if secs else []
    lead_att = [s for s in lead[1:] if LEAD_ATTACK.search(s) and not BEHAVIOUR.search(s)]  # a flee is behaviour
    if lead_att:
        said += lead_att[:2]
        src.add("attack_notes", mirror.pid(title))
    for sub in (f"{title}/Strategies", f"{title}/Strategy"):
        if sub not in mirror.pages:
            continue
        lines = mirror.wikitext(sub).split("\n")
        for i, line in enumerate(lines):
            if line.lstrip().startswith("*"):
                continue
            text = one_line(line)
            if not ATTACK_SENT.search(text):
                continue
            if text.rstrip().endswith(":"):  # "Fuzan's main attacks are:" then a bullet list
                for nxt in lines[i + 1:]:
                    if not nxt.lstrip().startswith("*"):
                        if nxt.strip():
                            break
                        continue
                    it = _attack_item(one_line(nxt))
                    if it:
                        items.append(it)
                src.add("attacks", mirror.pid(sub))
            else:
                hits = [x for x in facts_only(sentences(text)) if ATTACK_SENT.search(x)]
                if hits:
                    said += hits[:1]
                    src.add("attack_notes", mirror.pid(sub))
    return items, list(dict.fromkeys(said))[:3]


def class_aliases(names: Iterable[str], dump: Path | None = DUMP, combat: Path | None = COMBAT_KNOWLEDGE) -> dict[str, list[str]]:
    """Game class or asset stems per creature name, from names only: AI folders (/Gameplay/AI/GiantRat/),
    BP_AI_<X>_Character_C, DT_ATK_<X>, and the combat memory's 'Giant Rat:ATK_GiantRat_...' keys."""
    want = {re.sub(r"[^a-z0-9]", "", n.lower()): n for n in names}
    found: dict[str, set[str]] = defaultdict(set)

    def offer(stem: str) -> None:
        key = re.sub(r"[^a-z0-9]", "", stem.lower())
        for k in (key, re.sub(r"^dragon", "", key)):
            if k in want:
                found[want[k]].add(stem)
                return

    if dump and Path(dump).exists():
        text = Path(dump).read_text(encoding="utf-8", errors="ignore")
        for rx in (r"/Gameplay/AI/([A-Za-z0-9]+)/", r"\bBP_AI_([A-Za-z0-9]+)_Character_C\b", r"\bDT_(?:ATK|DAA)_([A-Za-z0-9]+)\b"):
            for stem in set(re.findall(rx, text)):
                offer(stem)
    if combat and Path(combat).exists():
        try:
            ck = json.loads(Path(combat).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            ck = {}
        for key in ((ck.get("defense") or {}).get("attacks") or {}):
            m = re.match(r"(.+?):ATK_([A-Za-z0-9]+?)_", key)
            if m and m.group(1) in want.values():
                found[m.group(1)].add(m.group(2))
    return {k: sorted(v) for k, v in found.items()}


def _norm(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


def observed_attacks(names: Iterable[str], skills: Path | None = SKILLS) -> dict[str, list[dict]]:
    """The enemy attacks his own client met, per creature name: every 'Creature:ATK_<Stem>_<Attack>' record of
    <world>/combat_knowledge.json and <world>/combat_memory_*.json (client_mod/scripts/defense.lua). Copies of one
    memory are not summed: per attack the record seen most often is kept. Dodges and non-ATK keys are left out."""
    want = set(names)
    best: dict[tuple[str, str], tuple[dict, str | None]] = {}
    if not skills or not Path(skills).exists():
        return {}
    files = sorted(Path(skills).glob("*/combat_knowledge.json")) + sorted(Path(skills).glob("*/combat_memory_*.json"))
    for f in files:
        try:
            doc = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        attacks = ((doc.get("defense") or {}).get("attacks") or {}) if isinstance(doc, dict) else {}
        for key, r in attacks.items():
            m = re.fullmatch(r"(.+?):(ATK_[A-Za-z0-9]+?_([A-Za-z0-9_]+))", key)
            if not m or m.group(1) not in want or re.search(r"dodge", m.group(3), re.I) or not isinstance(r, dict):
                continue
            seen = int(r.get("n") or 0) + int(r.get("hit") or 0)
            if seen <= 0:
                continue
            k = (m.group(1), m.group(2))
            if k not in best or seen > int(best[k][0].get("n") or 0) + int(best[k][0].get("hit") or 0):
                best[k] = (r, doc.get("build"))
    out: dict[str, list[dict]] = defaultdict(list)
    for (creature, asset), (r, build) in sorted(best.items()):
        def num(x, scale=1.0, nd=1):
            return round(float(x) * scale, nd) if isinstance(x, (int, float)) and x > 0 else None
        item = {"name": re.sub(r"^ATK_[A-Za-z0-9]+?_", "", asset).replace("_", " "), "asset": asset,
                "seen": int(r.get("n") or 0), "hits_on_him": int(r.get("hit") or 0),
                "impact_s": num(r.get("impact_s"), 1, 2), "lunge_m": num(r.get("lunge_cm"), 0.01),
                "damage_to_him": num(r.get("damage"), 1, 0), "build": str(build) if build else None}
        out[creature].append({k: v for k, v in item.items() if v is not None})
    return dict(out)


def parse_metabot(page: str) -> dict[str, dict]:
    """metabot.gg/en/dragonwilds/bestiary (server-rendered list items): per card its name, faction, the affinity line
    ("Weak: Stab" / "Resists: Crush" / "Immune: ...") and the journal-style lines in its lore ("Weakness: Stab",
    "Resistance: Crush", "Immune: Poison"). Cards named "BOSS" (unnamed) are skipped."""
    out: dict[str, dict] = {}
    for body in re.findall(r'<li id="[^"]+" class="[^"]*_card[^"]*">(.*?)</li>', page, re.S):
        nm = re.search(r'_name">(.*?)</span>', body, re.S)
        name = html.unescape(re.sub(r"<.*?>", "", nm.group(1))).strip() if nm else ""
        if not name or name.upper() == "BOSS":
            continue
        fac = re.search(r'_faction">(.*?)</span>', body, re.S)
        rec: dict[str, Any] = {"faction": html.unescape(fac.group(1)).strip() if fac else None, "affinity": {}, "journal": {}}
        aff = re.search(r'_affinities">(.*?)</div>', body, re.S)
        for label, val in re.findall(r"(Weak|Resists|Immune): ([^<]+)", aff.group(1) if aff else ""):
            rec["affinity"][{"Weak": "weak", "Resists": "resist", "Immune": "immune"}[label]] = \
                [x.strip() for x in html.unescape(val).split(",") if x.strip()]
        lore = re.search(r'_lore">(.*?)</p>', body, re.S)
        for label, val in re.findall(r"^(Weakness|Resistance|Immune): (.+)$", html.unescape(lore.group(1)) if lore else "", re.M):
            rec["journal"][{"Weakness": "weak", "Resistance": "resist", "Immune": "immune"}[label]] = \
                [x.strip() for x in val.split(",") if x.strip()]
        rec = {k: v for k, v in rec.items() if v}
        if name not in out:
            out[name] = rec
    return out


def fetch_metabot(path: Path = EXTERNAL, html_file: Path | None = None) -> dict:
    """Write the metabot.gg bestiary snapshot (network unless html_file is given)."""
    if html_file:
        page = Path(html_file).read_text(encoding="utf-8")
    else:
        import urllib.request
        req = urllib.request.Request(METABOT_URL, headers={"User-Agent": "dragonwilds-companion-bestiary/1"})
        with urllib.request.urlopen(req, timeout=30) as r:
            page = r.read().decode("utf-8")
    cards = parse_metabot(page)
    doc = {"schema": "dw_bestiary_external/1", "source": METABOT, "url": METABOT_URL,
           "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "terms": "MetaBot.GG data is free to use with a credit link to the page it came from (metabot.gg/llms.txt).",
           "note": "'affinity' is the card's Weak/Resists/Immune line; 'journal' its Weakness/Resistance/Immune lore lines.",
           "creatures": cards}
    Path(path).write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    return doc


def apply_external(creatures: dict[str, dict], path: Path | None = EXTERNAL) -> int:
    """Fill weak / resist / immune that the wiki lacks from the metabot.gg snapshot: its journal line first, else its
    affinity line. A wiki value is never replaced. Returns the number of fields filled."""
    if not path or not Path(path).exists():
        return 0
    try:
        ext = json.loads(Path(path).read_text(encoding="utf-8")).get("creatures") or {}
    except (OSError, ValueError):
        return 0
    index: dict[str, list[str]] = defaultdict(list)
    for title, e in creatures.items():
        for n in {title, e["name"], *(e.get("aliases") or [])}:
            if title not in index[_norm(n)]:
                index[_norm(n)].append(title)
    filled = 0
    for name, rec in ext.items():
        hits = index.get(_norm(name)) or []
        if len(hits) != 1:
            continue
        e = creatures[hits[0]]
        for field in ("weak", "resist", "immune"):
            val = (rec.get("journal") or {}).get(field) or (rec.get("affinity") or {}).get(field)
            if val and not e.get(field):
                e[field] = list(val)
                e["_src"].add(field, METABOT)
                filled += 1
    return filled


# ------------------------------------------------------------------------------ the game's own tables (live probe)

GAME_WORDS = {"stab", "slash", "crush", "fire", "water", "earth", "air", "magic", "ranged", "melee", "poison", "bleed",
              "burning", "frost", "ice", "lightning", "arrow", "arrows"}
JOURNAL_LINE = re.compile(r"^\s*(weak(?:ness(?:es)?)?|resist(?:ance|ances|s)?|immun(?:e|ity|ities))\s*:\s*(.+)$", re.I)
DAMAGE_CLASS = {1: "melee", 2: "magic", 3: "ranged"}


PROBE_GROUPS = ("journal", "attack_damage", "ai_data", "attacks", "enemy_loot", "chests")
# a version-1 result has no unread_by_group: its lines are filed by their label (first match wins)
_UNREAD_LABELS = (("journal", "journal"), ("attack_damage", "attack_damage"), ("DT_AIAttackDamage", "attack_damage"),
                  ("ai_data", "ai_data"), ("DT_AIData", "ai_data"), ("attack", "attacks"), ("enemy_loot", "enemy_loot"),
                  ("DT_EnemyLoot", "enemy_loot"), ("DT_CompositeEnemyLoot", "enemy_loot"), ("loot row", "enemy_loot"),
                  ("chest", "chests"), ("item set", "chests"))


def _probe_groups(res: dict) -> set[str]:
    """The groups one probe call ran: its `groups` (version 2), else the groups of its sections that were not skipped,
    else (an old result with no sections) all of them."""
    if isinstance(res.get("groups"), list):
        return {g for g in res["groups"] if g in PROBE_GROUPS}
    secs = res.get("sections")
    if isinstance(secs, dict) and secs:
        return {k.split(":")[0] for k, v in secs.items() if not (isinstance(v, dict) and v.get("skipped"))} & set(PROBE_GROUPS)
    return set(PROBE_GROUPS)


def _probe_unread(res: dict) -> dict[str, list[str]]:
    """group -> unread lines of one call (its unread_by_group, else its flat list filed by label)."""
    ubg = res.get("unread_by_group")
    if ubg is not None:
        return {g: list(v) for g, v in ubg.items() if isinstance(v, list)} if isinstance(ubg, dict) else {}
    out: dict[str, list[str]] = {}
    for x in res.get("unread") or []:
        g = next((grp for pre, grp in _UNREAD_LABELS if str(x).startswith(pre)), "other")
        out.setdefault(g, []).append(x)
    return out


def _ranges(idx: list[int]) -> str:
    parts, i = [], 0
    while i < len(idx):
        j = i
        while j + 1 < len(idx) and idx[j + 1] == idx[j] + 1:
            j += 1
        parts.append(str(idx[i]) if i == j else f"{idx[i]}-{idx[j]}")
        i = j + 1
    return ", ".join(parts)


def load_probe(paths: Iterable[Path | str]) -> dict:
    """One or more outputs of client_mod/commands/bestiary_tables_probe.lua (the runner's {ok, result} or the bare
    result), as their union: attacks by asset, journal entries by asset, table rows by table, chests by actor id.
    A run near other creatures loads other attack classes, so several runs add up.

    The probe runs one group per call (ARGS.only): journal, attack_damage, ai_data, attacks, enemy_loot, chests. A file
    contributes only the groups it ran, so partial files combine. A later file's group replaces that group only: its
    entries replace the same entries, and its unread lines replace the earlier lines of that group (a group a file did
    not run keeps the lines of the file that did). Attack registry slices (ARGS.start) add up: their unread lines are
    kept per slice start, and the paths no slice walked are listed as unread."""
    u: dict[str, Any] = {"files": [], "journal": {}, "attack_damage": {}, "attacks": {}, "registry": set(),
                         "enemy_loot": {}, "loot_rows": {}, "chests": {}, "unread": [], "groups": {}}
    unread: dict[str, tuple[bool, list[str]]] = {}  # group (attacks: per slice start) -> (ran, lines)
    walked: dict[int, set[int]] = {}                 # registry size -> path indices walked
    for p in paths:
        raw = json.loads(Path(p).read_text(encoding="utf-8"))
        res = raw.get("result", raw) if isinstance(raw, dict) else {}
        if not isinstance(res, dict) or res.get("probe") != "bestiary_tables_probe":
            raise ValueError(f"{p}: not a bestiary_tables_probe result (ok={raw.get('ok') if isinstance(raw, dict) else None}, "
                             f"error={raw.get('error') if isinstance(raw, dict) else None})")
        name = Path(p).name
        u["files"].append(str(p))
        ran = _probe_groups(res)
        att = res.get("attacks") if isinstance(res.get("attacks"), dict) else {}
        walk = att.get("walk") if isinstance(att.get("walk"), dict) else {}
        per = _probe_unread(res)

        def key(g: str) -> str:
            return f"attacks@{walk.get('start') or 1}" if g == "attacks" else f"other@{name}" if g == "other" else g
        for g in ran:  # a group this file ran: its lines (maybe none) replace the earlier ones
            unread[key(g)] = (True, [f"{name}: {x}" for x in per.get(g, [])])
            u["groups"][g] = name
        for g, lines in per.items():  # lines of a group it did not run (skipped): kept unless a file did run it
            if g not in ran and not unread.get(key(g), (False, []))[0]:
                unread[key(g)] = (False, [f"{name}: {x}" for x in lines])
        if "journal" in ran:
            for e in (res.get("journal") or {}).get("entries") or []:
                if e.get("asset"):
                    u["journal"][e["asset"]] = e
        if "attack_damage" in ran:
            for t, tab in (res.get("attack_damage") or {}).items():
                if isinstance(tab, dict) and isinstance(tab.get("rows"), dict):
                    u["attack_damage"].setdefault(t, {}).update(tab["rows"])
        u["registry"] |= set((att.get("registry") or {}).get("paths") or [])
        if "attacks" in ran:
            if isinstance(att.get("loaded"), dict):
                u["attacks"].update(att["loaded"])
            if isinstance(walk.get("n"), int) and isinstance(walk.get("start"), int) and isinstance(walk.get("stop"), int):
                walked.setdefault(walk["n"], set()).update(range(walk["start"], walk["stop"] + 1))
        if "enemy_loot" in ran:
            for t, tab in (res.get("enemy_loot") or {}).items():
                if isinstance(tab, dict) and isinstance(tab.get("rows"), dict):
                    u["enemy_loot"].setdefault(t, {}).update(tab["rows"])
            for k, r in (res.get("loot_rows") or {}).items():
                if r or k not in u["loot_rows"]:
                    u["loot_rows"][k] = r
        if "chests" in ran:
            for c in (res.get("chests") or {}).get("actors") or []:
                c = dict(c)
                c.setdefault("vault", res.get("vault"))
                u["chests"][(c.get("vault"), c.get("id"))] = c
    for _, lines in unread.values():
        u["unread"] += lines
    if walked:
        n = max(walked)
        got = {i for i in walked[n] if 1 <= i <= n}
        u["registry_walk"] = {"n": n, "covered": len(got)}
        if len(got) < n:
            u["unread"].append(f"attacks: the registry walk covered {len(got)} of {n} paths; not walked: "
                               f"{_ranges(sorted(set(range(1, n + 1)) - got))}")
    return u


def _game_affinities(lines: list[str]) -> dict[str, list[str]]:
    """The journal's Weaknesses lines -> {weak, resist, immune}: 'Weakness: Stab', 'Resistance: Crush, Air',
    'Immune: Poison', or a bare damage word ('Stab' = weak). Lore lines ('Occasionally lacks confidence') are not facts."""
    out: dict[str, list[str]] = {}
    for ln in lines:
        m = JOURNAL_LINE.match(ln or "")
        if m:
            field = {"w": "weak", "r": "resist", "i": "immune"}[m.group(1)[0].lower()]
            vals = [x.strip(" .") for x in re.split(r",|/|\band\b", m.group(2)) if x.strip(" .")]
        elif (ln or "").strip(" .").lower() in GAME_WORDS:
            field, vals = "weak", [ln.strip(" .")]
        else:
            continue
        for v in vals:
            if v not in out.setdefault(field, []):
                out[field].append(v)
    return out


def _creature_index(creatures: dict[str, dict]) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """norm(name, title, alias) -> titles; norm(game class stem) -> titles."""
    names: dict[str, list[str]] = defaultdict(list)
    stems: dict[str, list[str]] = defaultdict(list)
    for title, e in creatures.items():
        for n in {title, e["name"], *(e.get("aliases") or [])}:
            if title not in names[_norm(n)]:
                names[_norm(n)].append(title)
        for s in e.get("class_names") or []:
            if title not in stems[_norm(s)]:
                stems[_norm(s)].append(title)
    return names, stems


def _one(hits: list[str] | None) -> str | None:
    return hits[0] if hits and len(hits) == 1 else None


def _ai_folder(path: str | None) -> str | None:
    m = re.search(r"/Gameplay/AI/([A-Za-z0-9]+)/", path or "")
    return m.group(1) if m else None


def _items(rows: list[dict]) -> list[dict]:
    out = []
    for r in rows or []:
        it = {"item": r.get("item_name") or r.get("item"), "id": r.get("item"), "min": r.get("min"), "max": r.get("max"),
              "chance": r.get("chance")}
        if r.get("damagers_only"):
            it["damagers_only"] = True
        out.append({k: v for k, v in it.items() if v is not None})
    return out


def apply_probe(creatures: dict[str, dict], vaults: dict[str, dict], probe: dict) -> dict:
    """Merge the game's own data (load_probe) into the entries, src tag GAME. Preferred over the wiki and metabot.gg:
    a journal weakness replaces their value, and what it replaced is kept under ``differs`` with its sources. Adds
    ``journal``, ``game_attacks`` (per attack: damage per hit from the attack damage table, damage types, melee /
    magic / ranged, unblockable / unparryable, effects), ``game_drops`` (per minimum power level) and, on vaults,
    ``chest_items``. Returns what matched and what did not."""
    names, stems = _creature_index(creatures)
    stats: dict[str, Any] = {"files": probe["files"], "journal_matched": 0, "affinity_fields": 0, "replaced": 0,
                             "attacks_matched": 0, "drops_matched": 0, "chests_placed": 0,
                             "unmatched": {"journal": [], "attacks": [], "enemy_loot": [], "chests": []},
                             "unread": probe["unread"][:50]}

    def setf(e: dict, field: str, value: Any) -> None:
        e[field] = value
        e["_src"].d[field] = [GAME]

    # 1. the journal: weaknesses, resistances, immunities
    for asset, j in sorted(probe["journal"].items()):
        title = _one(names.get(_norm(j.get("name") or ""))) or _one(stems.get(_norm(_ai_folder(j.get("ai_data")) or "")))
        if not title:
            if j.get("weaknesses") and j.get("name"):
                stats["unmatched"]["journal"].append(j["name"])
            continue
        e = creatures[title]
        stats["journal_matched"] += 1
        rec = {k: v for k, v in (("entry", asset), ("lines", j.get("weaknesses")), ("power_level", j.get("power_level")),
                                 ("locations", j.get("locations"))) if v}
        setf(e, "journal", rec)
        for field, vals in _game_affinities(j.get("weaknesses") or []).items():
            old = e.get(field)
            if old and [x.lower() for x in old] != [x.lower() for x in vals]:
                e.setdefault("differs", {})[field] = {"values": old, "src": list(e["_src"].d.get(field, []))}
                for i in e["_src"].d.get(field, []):
                    e["_src"].add("differs", i)
                stats["replaced"] += 1
            setf(e, field, vals)
            stats["affinity_fields"] += 1

    # 2. attacks: each loaded ATK_<Stem>_<Name> default, and damage rows no loaded attack names
    by_creature: dict[str, list[dict]] = defaultdict(list)
    keys: dict[str, list[str]] = defaultdict(list)  # game stems first, then creature names ("Zogre" -> zogre)
    for k, ts in list(stems.items()) + list(names.items()):
        keys[k] += [t for t in ts if t not in keys[k]]
    longest = sorted(((s, t) for s, t in keys.items() if len(s) >= 3), key=lambda kv: -len(kv[0]))
    used_rows: set[tuple[str, str]] = set()

    def owner(asset: str, path: str | None) -> str | None:
        folder = _norm(_ai_folder(path) or "")
        hit = _one(stems.get(folder)) or _one(names.get(folder))
        if hit:
            return hit
        for s, titles in longest:
            if _norm(asset).startswith("atk" + s) and len(titles) == 1:
                return titles[0]
        return None

    for asset, a in sorted(probe["attacks"].items()):
        title = owner(asset, a.get("path"))
        hits = a.get("hits") or []
        for h in hits:
            if h.get("table") and h.get("row"):
                used_rows.add((h["table"], h["row"]))
        if not title:
            stats["unmatched"]["attacks"].append(asset)
            continue
        dmg = [h.get("damage") if h.get("damage") is not None else probe["attack_damage"].get(h.get("table") or "", {}).get(h.get("row"))
               for h in hits]
        types = list(dict.fromkeys(t.rsplit(".", 1)[-1].lower() for h in hits for t in h.get("types") or []))
        classes = list(dict.fromkeys(DAMAGE_CLASS[h["damage_class"]] for h in hits if h.get("damage_class") in DAMAGE_CLASS))
        item = {"name": re.sub(r"^ATK_[A-Za-z0-9]+?_", "", asset).replace("_", " "), "asset": asset,
                "damage": [d for d in dmg if isinstance(d, (int, float))] or None, "types": types or None,
                "class": classes or None, "unblockable": a.get("unblockable"), "unparryable": a.get("unparryable"),
                "effects": [re.sub(r"_C$", "", x) for x in a.get("effects") or []] or None,
                "next": re.sub(r"_C$", "", a["next"]) if a.get("next") else None}
        by_creature[title].append({k: v for k, v in item.items() if v})
    for table, rows in sorted(probe["attack_damage"].items()):
        for row, dmg in sorted(rows.items()):
            if (table, row) in used_rows or not isinstance(dmg, (int, float)):
                continue
            stem, title = next(((s, ts[0]) for s, ts in longest if len(ts) == 1 and _norm(row).startswith(s)), (None, None))
            if title:
                parts = row.split("_")
                cut = next((i for i in range(1, len(parts)) if _norm("".join(parts[:i])) == stem), 0)
                by_creature[title].append({"name": " ".join(parts[cut:]) or row, "row": f"{table}:{row}", "damage": [dmg]})
    for title, atts in by_creature.items():
        setf(creatures[title], "game_attacks", atts)
        stats["attacks_matched"] += len(atts)

    # 3. drops per minimum power level, through each drop row
    for table, rows in sorted(probe["enemy_loot"].items()):
        for row, levels in sorted(rows.items()):
            title = _one(names.get(_norm(row))) or _one(stems.get(_norm(row)))
            if not title:
                stats["unmatched"]["enemy_loot"].append(row)
                continue
            out = []
            for lv in levels or []:
                drops = []
                for key in lv.get("drops") or []:
                    d = probe["loot_rows"].get(key)
                    if not d:
                        continue
                    drops.append({k: v for k, v in (("chance", d.get("drop_chance")), ("conditions", d.get("conditions")),
                                                    ("items", _items(d.get("items")))) if v})
                if drops:
                    out.append({"min_power_level": lv.get("min_power_level"), "drops": drops})
            if out:
                setf(creatures[title], "game_drops", out)
                stats["drops_matched"] += 1

    # 4. vault chests: placed by the run's vault label, else by the vault's name inside the profile or roll row
    vnames = {_norm(t): t for t in vaults} | {_norm(a): t for t, v in vaults.items() for a in v.get("aliases") or []}
    for (label, cid), c in sorted(probe["chests"].items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
        if not (c.get("guaranteed_sets") or c.get("guaranteed_items") or c.get("extra_sets")):
            continue
        title = vnames.get(_norm(label or ""))
        if not title:
            rows = _norm(" ".join(str((c.get(k) or {}).get("row") or "") for k in ("profile", "roll")))
            title = next((t for n, t in vnames.items() if n and n in rows), None) or \
                next((t for t in vaults if len(t.split()[0]) >= 5 and _norm(t.split()[0]) in rows), None)
        if not title:
            stats["unmatched"]["chests"].append(f"{cid} ({(c.get('profile') or {}).get('row')})")
            continue
        v = vaults[title]
        ci = v.get("chest_items") or {"rolls": []}
        roll = (c.get("roll") or {}).get("row")
        if roll not in [r.get("roll") for r in ci["rolls"]]:
            ci["rolls"].append({k: val for k, val in (
                ("roll", roll), ("respawn", c.get("respawn")),
                ("guaranteed", _items(c.get("guaranteed_items")) + [i for s in c.get("guaranteed_sets") or [] for i in _items(s.get("items"))]),
                ("extra_rolls", [c.get("min_extra_rolls"), c.get("max_extra_rolls")] if c.get("max_extra_rolls") else None),
                ("extra_sets", [{"chance": s.get("chance"), "items": _items(s.get("items"))} for s in c.get("extra_sets") or []]),
            ) if val})
            ci["rolls"].sort(key=lambda r: str(r.get("roll")))
        setf(v, "chest_items", ci)
        stats["chests_placed"] += 1
    return stats


def build_creatures(mirror: Mirror) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for title, page in sorted(mirror.pages.items()):
        wt = page.get("wikitext") or ""
        if "/" in title or not re.search(r"\{\{\s*Infobox Monster", wt, re.I):
            continue
        boxes = monster_infoboxes(wt)
        if not boxes:
            continue
        pid = mirror.pid(title)
        src = Src()
        merged: dict[str, str] = {}
        variants: list[dict] = []
        for label, box in boxes:
            for k, v in box.items():
                if one_line(v) and k not in merged:
                    merged[k] = v
            variants += variants_of(label, box)
        name = one_line(merged.get("name", "")) or title
        e: dict[str, Any] = {"kind": "creature", "name": name, "title": title, "page": pid,
                             "aliases": sorted({a for a in [title, re.sub(r"\s*\(.*\)$", "", title)] + mirror.aliases_of(title)
                                                if a and a != name})}
        vs = [v for v in variants if v["power_level"] or v["health"]]
        if vs:
            e["variants"] = [{k: v[k] for k in ("label", "power_level", "health") if v[k]} for v in vs]
            src.add("variants", pid)
        for key, field in (("race", "race"), ("weakness", "weak"), ("resistance", "resist"), ("immune", "immune"),
                           ("aggressive", "aggressive"), ("respawn", "respawn")):
            val = one_line(merged.get(key, ""))
            if val:
                e[field] = _split_names(val) if field in ("weak", "resist", "immune") else val
                src.add(field, pid)
        locs: list[str] = []
        raw_locs = [x for _, box in boxes for k, val in box.items() if re.fullmatch(r"location\d*", k)
                    for x in _list_values(val)]
        for v in variants + [{"location": raw_locs}]:
            for x in v["location"]:
                for y in re.split(r",\s*", x):
                    y = y.strip(" .")
                    if y and y not in locs:
                        locs.append(y)
        if locs:
            e["locations"] = locs
            src.add("locations", pid)
        secs = sections(wt)
        lead = facts_only(sentences(plain(secs[0]["body"])))
        if lead:
            e["lead"] = lead[0][:300]
            src.add("lead", pid)
        behaviour = [x[:300] for x in lead[1:] if BEHAVIOUR.search(x)]  # flees, flies away, too fast to catch
        if behaviour:
            e["behaviour"] = behaviour[:2]
            src.add("behaviour", pid)
        items, said = attacks_of(mirror, title, src)
        if items:
            e["attacks"] = items
        if said:
            e["attack_notes"] = said
        drops = drops_of(wt)
        if drops:
            e["drops"] = drops
            src.add("drops", pid)
        e["_src"] = src
        out[title] = e
    names = {e["name"] for e in out.values()} | set(out)
    cls = class_aliases(names)
    for title, e in out.items():
        stems = sorted(set(cls.get(title, [])) | set(cls.get(e["name"], [])))
        if stems:
            e["class_names"] = stems
    seen = observed_attacks(names)
    for title, e in out.items():
        obs = seen.get(e["name"]) or seen.get(title)
        if obs:
            e["observed_attacks"] = obs
            e["_src"].add("observed_attacks", OWN)
    return out


# ------------------------------------------------------------------------------ boss tables and vaults


def boss_rows(mirror: Mirror) -> list[dict]:
    """Rows of the 'Boss' page tables: {group, creature, power_level, health, weakness, locations, drops}."""
    title = mirror.resolve("Boss")
    if not title:
        return []
    out = []
    for sec in sections(mirror.wikitext(title)):
        for header, rows in table_rows(sec["body"]):
            hl = [h.lower() for h in header]
            for cells in rows:
                rec = {"group": sec["heading"] or "", "page": mirror.pid(title)}
                for i, c in enumerate(cells):
                    h = hl[i] if i < len(hl) else ""
                    if i == 0:
                        t = (link_targets(c) or [one_line(c)])[0]
                        rec["creature"] = mirror.resolve(t) or one_line(c)
                    elif h == "power level":
                        rec["power_level"] = ", ".join(cell_items(c))
                    elif h == "health":
                        rec["health"] = ", ".join(cell_items(c))
                    elif h == "weakness":
                        rec["weakness"] = ", ".join(cell_items(c))
                    elif h == "location":
                        rec["locations"] = [mirror.resolve(t) or t for t in link_targets(c)] or cell_items(c)
                    elif "drops" in h:
                        rec["drops"] = cell_items(re.sub(r"<br\s*/?>", "\n", c))
                if rec.get("creature"):
                    out.append(rec)
    return out


def vault_index(mirror: Mirror) -> dict[str, dict]:
    """From the 'Dragonkin Vault' page: per vault, order, power level, area, common and notable enemies, recipes,
    and the page's own words about shards in chests."""
    title = mirror.resolve("Dragonkin Vault")
    out: dict[str, dict] = defaultdict(dict)
    if not title:
        return out
    pid = mirror.pid(title)
    for sec in sections(mirror.wikitext(title)):
        for header, rows in table_rows(sec["body"]):
            hl = [h.lower() for h in header]
            for cells in rows:
                if "vault" not in hl:
                    continue
                vcol = hl.index("vault")
                if vcol >= len(cells):
                    continue
                targets = link_targets(cells[vcol])
                if not targets:
                    continue
                v = mirror.resolve(targets[0]) or targets[0]
                rec = out[v]
                rec.setdefault("_pid", pid)
                for i, c in enumerate(cells):
                    h = hl[i] if i < len(hl) else ""
                    if h == "order":
                        rec["order"] = one_line(c)
                    elif h == "power level":
                        rec["power_level"] = one_line(c)
                    elif h == "area":
                        rec["area"] = one_line(c)
                    elif h.startswith("common"):
                        rec["common"] = [mirror.resolve(t) or t for t in link_targets(c)]
                    elif h.startswith("unique"):
                        rec["notable"] = [mirror.resolve(t) or t for t in link_targets(c)]
                    elif h == "recipe":
                        rec["recipes"] = cell_items(c)
    return out


def shard_note(mirror: Mirror) -> tuple[str | None, int | None]:
    """The Dragonkin Vault page's sentence on vault shards (its Rewards list), verbatim."""
    title = mirror.resolve("Dragonkin Vault")
    if not title:
        return None, None
    for b in bullets(mirror.wikitext(title)):
        if b.lower().startswith("vault shard"):
            return b, mirror.pid(title)
    return None, None


def vault_enemies(body: str, mirror: Mirror) -> tuple[list[dict], list[str]]:
    """An Enemies section: rows {name, amount, power_level, group}, and other bullets (traps)."""
    rows: list[dict] = []
    pos = 0
    group = ""
    for tm in re.finditer(r"^\{\|.*?^\|\}", body, re.S | re.M):
        before = body[pos:tm.start()]
        bl = bullets(before)
        if bl:
            group = bl[-1]
        pl_m = re.search(r"(?:power )?level (\d+)", group, re.I)
        for header, cells_rows in table_rows(tm.group(0)):
            hl = [h.lower() for h in header]
            for cells in cells_rows:
                t = link_targets(cells[0])
                name = mirror.resolve(t[0]) if t else None
                rec = {"name": name or one_line(cells[0]),
                       "amount": one_line(cells[1]) if len(cells) > 1 else ""}
                if "power level" in hl and hl.index("power level") < len(cells):
                    rec["power_level"] = one_line(cells[hl.index("power level")])
                elif pl_m:
                    rec["power_level"] = pl_m.group(1)
                elif group:
                    rec["group"] = group.rstrip(":")
                rows.append(rec)
        pos = tm.end()
    extra = [b for b in bullets(body[pos:]) if not ADVICE.search(b)]
    return rows, extra


def chest_text(mirror: Mirror, vault: str) -> tuple[str | None, int | None]:
    """'Chest (<vault>)': what its drop sections hold. Drop tables kept only as templates are named by their heading
    and rate, and marked as not itemised in the mirror."""
    title = mirror.resolve(f"Chest ({vault})")
    if not title:
        return None, None
    secs = sections(mirror.wikitext(title))
    parts: list[str] = []
    templated = False
    for top in ("Drops", "Additional"):
        names: list[str] = []
        intro = ""
        for sec in secs:
            if sec["heading"] == top:
                intro = " ".join(facts_only(sentences(plain(sec["body"]))))
            if not ((sec["heading"] == top and sec["level"] == 2) or (sec["path"] and sec["path"][0] == top)):
                continue
            rows = [r for r in drops_of("== x ==\n" + sec["body"])]
            if rows:
                names += [f"{r['item']} {r['amount']} ({r['rate']})".replace("  ", " ") for r in rows]
                continue
            for _, _, nm, inner in find_templates(sec["body"]):
                if nm.endswith("DropTable") and nm.lower() not in ("dropstablehead",):
                    pos, _ = params(inner)
                    rate = pos[0] if pos else ""
                    label = (sec["heading"] if sec["heading"] != top else re.sub(r"(?<=[a-z])(?=[A-Z0-9])", " ", nm[:-9])).lower()
                    names.append(f"{label} {rate}".strip())
                    templated = True
        if names:
            head = "Always" if top == "Drops" else "Extra rolls"
            parts.append(f"{head}: {', '.join(dict.fromkeys(names))}." + (f" {intro}" if intro and top != "Drops" else ""))
    if not parts:
        return None, mirror.pid(title)
    if templated:
        parts.append("The items inside these tables are not in the mirror.")
    return " ".join(parts), mirror.pid(title)


def build_vaults(mirror: Mirror, creatures: dict[str, dict], bosses: list[dict]) -> dict[str, dict]:
    idx = vault_index(mirror)
    shard, shard_pid = shard_note(mirror)
    titles = set(idx)
    for t, page in mirror.pages.items():
        if t.endswith(" Kara") and re.search(r"\{\{\s*Infobox Scenery", page.get("wikitext") or "", re.I):
            titles.add(t)
    out: dict[str, dict] = {}
    for title in sorted(t for t in titles if t in mirror.pages):
        wt = mirror.wikitext(title)
        pid = mirror.pid(title)
        src = Src()
        info = idx.get(title, {})
        e: dict[str, Any] = {"kind": "vault", "name": title, "title": title, "page": pid,
                             "aliases": sorted(set(mirror.aliases_of(title)))}
        box = {}
        for _, _, nm, inner in find_templates(wt):
            if nm.lower() == "infobox scenery":
                box = params(inner)[1]
                break
        area = one_line(box.get("location", "")) or info.get("area", "")
        if area:
            e["area"] = area
            src.add("area", pid if box.get("location") else info.get("_pid"))
        for k in ("power_level", "order"):
            if info.get(k):
                e[k] = info[k]
                src.add(k, info["_pid"])
        secs = sections(wt)
        lead = facts_only(sentences(plain(secs[0]["body"])))
        if lead:
            e["lead"] = lead[0][:300]
            src.add("lead", pid)
        opens = [s for s in lead[1:] if OPENS.search(s)]
        for sec in secs[1:]:
            if sec["heading"] and re.search(r"unlock|entr", sec["heading"], re.I):
                opens += facts_only(sentences(plain(sec["body"])))[:2]
        if opens:
            e["opens"] = opens[:3]
            src.add("opens", pid)
        enemies: list[dict] = []
        extras: list[str] = []
        for sec in secs[1:]:
            h = (sec["heading"] or "").lower()
            if h in ("enemies", "monsters"):
                rows, more = vault_enemies(sec["body"], mirror)
                enemies += rows
                extras += more
            elif h in ("hazards", "traps & mechanisms", "traps"):
                extras += [b.split(" - ")[0] for b in bullets(sec["body"])]
            elif h in ("nodes", "plants", "other") and (sec["path"][:1] == ["Resources"] or h in ("nodes", "plants")):
                e.setdefault("resources", {})[h] = [b for b in bullets(sec["body"]) if not ADVICE.search(b)]
                src.add("resources", pid)
            elif h.startswith("notable loot"):
                e["notable_loot"] = [b.split(" - ")[0].split(": ")[0] for b in bullets(sec["body"])] or \
                    [one_line(re.split(r"\]\]", ln)[0] + "]]").split(":")[0] for ln in sec["body"].split("\n")
                     if ln.strip().startswith("[[") and not re.match(r"\[\[\s*(file|image|category):", ln.strip(), re.I)][:4]
                src.add("notable_loot", pid)
            elif h == "recipes":
                e["recipes"] = [b for b in bullets(sec["body"]) + bullets(sec["body"], 2) if not b.endswith(":")]
                src.add("recipes", pid)
        if enemies:
            e["enemies"] = enemies
            src.add("enemies", pid)
        if extras:
            e["hazards"] = list(dict.fromkeys(extras))
            src.add("hazards", pid)
        if info.get("common") or info.get("notable"):
            e["listed_enemies"] = {"common": info.get("common", []), "notable": info.get("notable", [])}
            src.add("listed_enemies", info["_pid"])
        if not e.get("recipes") and info.get("recipes"):
            e["recipes"] = info["recipes"]
            src.add("recipes", info["_pid"])
        boss = [b for b in bosses if b["group"].lower().startswith("vault") and title in (b.get("locations") or [])]
        if boss:
            e["boss"] = [{k: b[k] for k in ("creature", "power_level", "health", "weakness") if b.get(k)} for b in boss]
            src.add("boss", boss[0]["page"])
        chest, cpid = chest_text(mirror, title)
        if chest:
            e["chests"] = chest
            src.add("chests", cpid)
        if shard:
            e["shards"] = shard
            src.add("shards", shard_pid)
        e["_src"] = src
        out[title] = e
    return out


def build_dungeons(mirror: Mirror, creatures: dict[str, dict], vaults: dict[str, dict]) -> dict[str, dict]:
    """Other dungeons and combat activities: a page (not a creature, not a vault) whose lead calls it a dungeon, cave
    or activity and whose Monsters/Enemies section links creatures."""
    out = {}
    for title, page in sorted(mirror.pages.items()):
        if title in creatures or title in vaults or "/" in title:
            continue
        wt = page.get("wikitext") or ""
        secs = sections(wt)
        lead = plain(secs[0]["body"]) if secs else ""
        if not re.search(r"\b(dungeon|cave|activity|raid)\b", lead[:600], re.I):
            continue
        mons = [s for s in secs[1:] if (s["heading"] or "").lower() in ("monsters", "enemies")]
        found: list[str] = []
        for s in mons:
            body = s["body"] + "".join(x["body"] for x in secs if x["path"][:1] == [s["heading"]])
            for t in link_targets(body):
                r = mirror.resolve(t)
                if r in creatures and r not in found:
                    found.append(r)
        if len(found) < 2:
            continue
        pid = mirror.pid(title)
        src = Src()
        e: dict[str, Any] = {"kind": "dungeon", "name": title, "title": title, "page": pid,
                             "aliases": sorted(set(mirror.aliases_of(title))), "enemies": [{"name": n} for n in found]}
        src.add("enemies", pid)
        ls = facts_only(sentences(lead))
        if ls:
            e["lead"] = ls[0][:300]
            src.add("lead", pid)
        text = plain(wt)
        boss = [n for n in creatures if re.search(r"\b(?:before )?fighting " + re.escape(n) + r"\b", text)
                or re.search(re.escape(n) + r"[^.]{0,40}\bboss\b", text)]
        if boss:
            e["boss"] = [{"creature": b} for b in boss]
            src.add("boss", pid)
        e["_src"] = src
        out[title] = e
    return out


# ------------------------------------------------------------------------------ reverse index


def build_reverse(creatures: dict[str, dict], vaults: dict[str, dict], bosses: list[dict], mirror: Mirror) -> dict[str, list[dict]]:
    rev: dict[str, list[dict]] = defaultdict(list)

    def add(item: str, row: dict) -> None:
        item = item.strip()
        if not item:
            return
        key = mirror.resolve(item) or item
        if not any(r["from"] == row["from"] and r["how"] == row["how"] for r in rev[key]):
            rev[key].append(row)

    for title, e in creatures.items():
        for d in e.get("drops") or []:
            add(d["item"], {"from": e["name"], "how": "drop", "amount": d["amount"], "rate": d["rate"], "src": e["page"]})
    for b in bosses:
        cr = creatures.get(b["creature"])
        for it in b.get("drops") or []:
            add(it, {"from": cr["name"] if cr else b["creature"], "how": "drop", "amount": "", "rate": "", "src": b["page"]})
    for title, e in vaults.items():
        for it in (e.get("resources") or {}).get("other", []):
            name = re.split(r"\s+-\s+|\s*\(", it)[0].strip()
            if name.lower().startswith("chest"):
                continue
            add(name, {"from": title, "how": "vault", "amount": "", "rate": "", "src": e["page"]})
        for it in e.get("recipes") or []:
            add(it, {"from": title, "how": "recipe learned in vault", "amount": "", "rate": "", "src": (e["_src"].d.get("recipes") or [e["page"]])[0]})
        for it in e.get("notable_loot") or []:
            add(re.sub(r"\s+Vestige$", "", it), {"from": title, "how": "vault loot", "amount": "", "rate": "", "src": e["page"]})
    shard, spid = shard_note(mirror)
    if shard:
        add("Vault Shard", {"from": "every dragonkin vault", "how": "vault chests and vault monsters", "amount": "", "rate": "",
                            "src": spid, "note": shard})
    return {k: v for k, v in sorted(rev.items())}


# ------------------------------------------------------------------------------ text


def _and(xs: list[str]) -> str:
    xs = [x for x in xs if x]
    return xs[0] if len(xs) == 1 else ", ".join(xs[:-1]) + " and " + xs[-1] if xs else ""


def _tidy(text: str) -> str:
    """'total..' -> 'total.'; a stray '}}' left by a broken template is dropped."""
    text = re.sub(r"\{\{|\}\}", "", text)
    return re.sub(r"([.!?])\.(?=\s|$)", r"\1", text).strip()


def _fit(parts: list[str], shrinkers: list) -> str:
    parts = [_tidy(p) for p in parts if p]
    text = "\n".join(p for p in parts if p)
    for fn in shrinkers:
        if len(text) <= ENTRY_CHARS:
            break
        parts = fn(parts)
        text = "\n".join(p for p in parts if p)
    if len(text) > ENTRY_CHARS:
        text = text[:ENTRY_CHARS - 1].rsplit(" ", 1)[0] + "…"
    return text


NAMED_SOURCES = {METABOT: "metabot.gg datamined bestiary", OWN: "his own fights", GAME: "the game's own data on his client"}


def _sources(src: dict[str, list]) -> str:
    ids = sorted({i for v in src.values() for i in v if isinstance(i, int)})
    named: dict[str, list[str]] = defaultdict(list)
    for field, v in src.items():
        for i in v:
            if isinstance(i, str):
                named[i].append(field.replace("observed_attacks", "attacks seen").replace("game_attacks", "attacks")
                                .replace("game_drops", "drops").replace("chest_items", "chest loot")
                                .replace("weak", "weak to").replace("resist", "resistant to").replace("immune", "immune to"))
    bits = (["wiki pages " + ", ".join(str(i) for i in ids)] if ids else []) + \
        [f"{NAMED_SOURCES.get(k, k)} ({', '.join(fs)})" for k, fs in named.items()]
    return "Sources: " + "; ".join(bits) + "." if bits else ""


def _observed_line(obs: list[dict], short: bool = False) -> str:
    """'Seen in his own fights: Attack 01 (seen 137, impact 1.07 s after the wind-up, lunge 2.4 m, 13 damage to him)'."""
    bits = []
    for a in obs:
        if short:
            bits.append(a["name"])
            continue
        fx = [f"seen {a['seen']}" if a.get("seen") else None,
              f"impact {a['impact_s']} s after the wind-up" if a.get("impact_s") else None,
              f"lunge {a['lunge_m']} m" if a.get("lunge_m") else None,
              f"about {a['damage_to_him']:.0f} damage to him per hit" if a.get("damage_to_him") else None]
        bits.append(f"{a['name']} ({', '.join(x for x in fx if x)})")
    return "Attacks seen in his own fights (the game's attack names; damage is what he took through his armour): " + \
        "; ".join(bits) + "."


def _pct(x: Any) -> str | None:
    if not isinstance(x, (int, float)):
        return None
    return "always" if x >= 1 else f"{x * 100:.3g} %"


def _amount(it: dict) -> str:
    lo, hi = it.get("min"), it.get("max")
    return "" if lo is None else f" {lo}" if hi in (None, lo) else f" {lo}-{hi}"


def _game_attack_line(atts: list[dict], short: bool = False) -> str:
    """'Attacks in the game's data: Bite (12 damage, stab, melee, unblockable, effect GE_Poison); ...'."""
    bits = []
    for a in atts:
        dmg = a.get("damage") or []
        d = (f"{dmg[0]:g} damage" if len(dmg) == 1 else ("damage " + " + ".join(f"{x:g}" for x in dmg))) if dmg else None
        fx = [d] if short else [d, ", ".join(a.get("types") or []) or None, ", ".join(a.get("class") or []) or None,
                                "unblockable" if a.get("unblockable") else None, "unparryable" if a.get("unparryable") else None,
                                ("effect " + ", ".join(a["effects"])) if a.get("effects") else None]
        fx = [x for x in fx if x]
        bits.append(a["name"] + (f" ({', '.join(fx)})" if fx else ""))
    return "Attacks in the game's data (base damage before armour): " + "; ".join(bits) + "."


def _game_drops_line(levels: list[dict], cap: int | None = None) -> str:
    """'Drops in the game's tables: from power level 1: Raw Rat Meat 1 (always); from power level 3: ...'."""
    parts, n = [], 0
    for lv in levels:
        items = []
        for d in lv["drops"]:
            roll = _pct(d.get("chance"))
            cond = " at " + " and ".join(map(str, d["conditions"])) if d.get("conditions") else ""
            for it in d.get("items") or []:
                ch = _pct(it.get("chance"))
                odds = ch if roll in (None, "always") else (f"{ch} of a {roll} roll" if ch else f"a {roll} roll")
                items.append(f"{it.get('item')}{_amount(it)}" + (f" ({odds}{cond})" if odds or cond else ""))
        if cap is not None and n + len(items) > cap:
            items = items[:max(0, cap - n)] + ["and more"]
        n += len(items)
        if items:
            parts.append((f"from power level {lv['min_power_level']}: " if lv.get("min_power_level") is not None else "") +
                         ", ".join(items))
        if cap is not None and n >= cap:
            break
    return "Drops in the game's tables: " + "; ".join(parts) + "." if parts else ""


def creature_text(e: dict, vault_rows: list[str], boss_of: list[str], short: int = 0) -> str:
    """short: 0 full, 1 attack names only, 2 also drops cut, 3 also lead dropped."""
    head = f"{e['name']}: creature" + (f", {_and(boss_of)}" if boss_of else "") + "."

    def build(level: int) -> list[str]:
        p = [head]
        if e.get("lead") and level < 3:
            p.append(e["lead"])
        vs = e.get("variants") or []
        if vs:
            bits = []
            for v in vs:
                generic = re.fullmatch(r"monster|npc|(?:pl|power level|level) ?\d+", (v.get("label") or "").lower())
                lab = f"{v['label']}: " if v.get("label") and not generic else ""
                pl = f"power level {v['power_level']}" if v.get("power_level") else ""
                hp = f"health {v['health']}" if v.get("health") else ""
                bit = lab + ", ".join(x for x in (pl, hp) if x)
                bits.append(bit[:1].upper() + bit[1:])
            p.append(". ".join(bits) + ".")
        fx = []
        if e.get("race"):
            fx.append(f"Race: {e['race']}.")
        fx.append(f"Weak to {_and(e['weak'])}." if e.get("weak") else "Weak to: not in the mirror.")
        if e.get("resist"):
            fx.append(f"Resistant to {_and(e['resist'])}.")
        if e.get("immune"):
            imm = e["immune"]
            fx.append(f"Immune: {imm[0]}." if len(imm) == 1 and len(imm[0].split()) > 3 else f"Immune to {_and(imm)}.")
        for f, d in (e.get("differs") or {}).items():
            label = {"weak": "weak to", "resist": "resistant to", "immune": "immune to"}.get(f, f)
            fx.append(f"(The game's journal says {label} {_and(e[f])}; other sources said {_and(d['values'])}.)")
        if e.get("aggressive"):
            fx.append(f"Aggressive: {e['aggressive']}.")
        if e.get("respawn"):
            fx.append(f"Respawn: {e['respawn']}.")
        p.append(" ".join(fx))
        for b in e.get("behaviour") or []:
            p.append(f"Behaviour: {b}")
        if e.get("locations"):
            p.append(f"Lives in: {', '.join(e['locations'])}.")
        if vault_rows:
            p.append(f"In vaults or dungeons: {'; '.join(vault_rows)}.")
        att = e.get("attacks") or []
        if att:
            if level >= 1:
                names = [a["name"] for a in att if a["name"]]
                s = "Attacks: " + ("; ".join(names) + "." if names else " ".join(a["does"][:120] for a in att[:2]))
            else:
                s = "Attacks: " + " ".join(f"{a['name']}: {a['does']}" if a["name"] else a["does"] for a in att)
            p.append(s)
        for n in (e.get("attack_notes") or [])[: (2 if level < 2 else 1)]:
            p.append(n if level < 1 else n[:240])
        if e.get("game_attacks"):
            p.append(_game_attack_line(e["game_attacks"], short=level >= 1))
        if not att and not e.get("attack_notes") and not e.get("game_attacks"):
            p.append("Attacks: not in the mirror.")
        if e.get("observed_attacks") and level < 3:
            p.append(_observed_line(e["observed_attacks"], short=level >= 2))
        if e.get("game_drops"):
            p.append(_game_drops_line(e["game_drops"], cap=None if level < 2 else 8))
        dr = [] if e.get("game_drops") and level >= 2 else (e.get("drops") or [])  # short of space: the game's tables stand
        if dr:
            items = [f"{d['item']} {d['amount']} ({d['rate']})".replace("  ", " ") for d in dr]
            if level >= 2 and len(items) > 8:
                items = items[:8] + [f"and {len(dr) - 8} more on the wiki page"]
            p.append("Drops: " + ", ".join(items) + ".")
        elif not e.get("game_drops"):
            p.append("Drops: not in the mirror.")
        p.append(_sources(e["src"]))
        return p

    text = ""
    for level in range(short, 4):
        text = "\n".join(_tidy(x) for x in build(level) if x)
        if len(text) <= ENTRY_CHARS:
            return text
    return _fit([text], [])


def _chest_line(ci: dict) -> str:
    """'Chest loot in the game's tables: always Vault Core 1; plus 1-2 rolls among: Skill Tome 1-3 (50 %) [set 10 %].'"""
    bits = []
    for r in ci.get("rolls") or []:
        b = []
        if r.get("guaranteed"):
            b.append("always " + ", ".join(f"{i.get('item')}{_amount(i)}" for i in r["guaranteed"]))
        if r.get("extra_sets"):
            lo, hi = (r.get("extra_rolls") or [None, None])[:2]
            n = f"{lo}-{hi} " if lo is not None and hi not in (None, lo) else (f"{hi} " if hi else "")
            sets = []
            for st in r["extra_sets"]:
                items = ", ".join(f"{i.get('item')}{_amount(i)}" +
                                  (f" ({_pct(i.get('chance'))})" if _pct(i.get("chance")) not in (None, "always") else "")
                                  for i in st.get("items") or [])
                sc = _pct(st.get("chance"))
                sets.append(items + (f" [set {sc}]" if sc not in (None, "always") else ""))
            b.append(f"plus {n}rolls among: " + "; ".join(sets))
        if b:
            bits.append("; ".join(b))
    return "Chest loot in the game's tables: " + " | ".join(bits) + "." if bits else ""


def vault_text(e: dict, creatures: dict[str, dict]) -> str:
    kind = "dragonkin vault" if e["kind"] == "vault" else "dungeon"
    head = f"{e['name']}: {kind}" + (f" in {e['area']}" if e.get("area") else "") + \
        (f", power level {e['power_level']}" if e.get("power_level") else "") + \
        (f", number {e['order']} in the wiki's standard order" if e.get("order") else "") + "."
    p = [head]
    if e.get("lead"):
        p.append(e["lead"])
    if e["kind"] == "vault":
        p.append("Opens: " + " ".join(e["opens"]) if e.get("opens") else "Opens: not in the mirror.")
    en = e.get("enemies") or []
    if en:
        groups: dict[str, list[str]] = defaultdict(list)
        for r in en:
            g = f"power level {r['power_level']}" if r.get("power_level") else (r.get("group") or "")
            groups[g].append(f"{r['name']} {r['amount']}".strip() if r.get("amount") else r["name"])
        p.append("Enemies: " + "; ".join((f"{g}: " if g else "") + ", ".join(v) for g, v in groups.items()) + ".")
    elif e.get("listed_enemies"):
        le = e["listed_enemies"]
        p.append(f"Enemies: {', '.join(le.get('common', []) + le.get('notable', []))}.")
    else:
        p.append("Enemies: not in the mirror.")
    if e.get("hazards"):
        p.append(f"Hazards: {', '.join(e['hazards'])}.")
    if e.get("boss"):
        bits = []
        for b in e["boss"]:
            c = creatures.get(b["creature"])
            nm = c["name"] if c else b["creature"]
            fx = [f"power level {b['power_level']}" if b.get("power_level") else "",
                  f"health {b['health']}" if b.get("health") else "",
                  f"weak to {b['weakness']}" if b.get("weakness") else ""]
            fx = [x for x in fx if x]
            bits.append(nm + (f" ({'; '.join(fx)})" if fx else ""))
        p.append("Boss: " + "; ".join(bits) + ".")
    elif e["kind"] == "vault":
        p.append("Boss: not in the mirror's boss table.")
    if (e.get("listed_enemies") or {}).get("notable"):
        p.append(f"Notable enemies (Dragonkin Vault list): {', '.join(e['listed_enemies']['notable'])}.")
    if e.get("chest_items"):
        p.append(_chest_line(e["chest_items"]))
    if e["kind"] == "vault" and (e.get("chests") or not e.get("chest_items")):
        p.append(f"Chests: {e['chests']}" if e.get("chests") else "Chests: contents not in the mirror.")
        if e.get("shards"):
            p.append(e["shards"])
    if e.get("recipes"):
        p.append(f"Recipes learned here: {', '.join(e['recipes'])}.")
    if e.get("notable_loot"):
        p.append(f"Notable loot: {', '.join(e['notable_loot'])}.")
    res = e.get("resources") or {}
    if res:
        p.append("Resources: " + "; ".join(f"{k}: {', '.join(v)}" for k, v in res.items() if v) + ".")
    p.append(_sources(e["src"]))

    def drop_resources(parts):
        return [x for x in parts if not x.startswith("Resources:")]

    def drop_lead(parts):
        return [x for x in parts if x != e.get("lead")]
    return _fit(p, [drop_resources, drop_lead])


def reverse_text(item: str, rows: list[dict]) -> str:
    drops = [r for r in rows if r["how"] == "drop"]
    other = [r for r in rows if r["how"] != "drop"]
    p = [f"{item}: where it comes from (wiki mirror)."]
    if drops:
        bits = []
        for r in drops:
            fx = ", ".join(x for x in (r.get("amount"), r.get("rate")) if x)
            bits.append(r["from"] + (f" ({fx})" if fx else ""))
        p.append("Dropped by: " + "; ".join(bits) + ".")
    for r in other:
        p.append(r["note"] if r.get("note") else f"{r['how'].capitalize()}: {r['from']}.")
    ids = sorted({r["src"] for r in rows if r.get("src") is not None})
    p.append("Sources: wiki pages " + ", ".join(map(str, ids)) + "." if ids else "")
    return _fit(p, [lambda parts: parts[:2] + [f"and {len(other)} more sources"] + parts[-1:]])


# ------------------------------------------------------------------------------ build


def build(mirror: Mirror | None = None, probe: dict | None = None) -> dict:
    """probe: load_probe() of the live bestiary_tables_probe outputs; merged last, so it outranks every other source."""
    mirror = mirror or Mirror()
    creatures = build_creatures(mirror)
    bosses = boss_rows(mirror)
    vaults = build_vaults(mirror, creatures, bosses)
    dungeons = build_dungeons(mirror, creatures, vaults)
    reverse = build_reverse(creatures, vaults, bosses, mirror)
    # creature to vault membership, and boss roles
    in_vault: dict[str, list[str]] = defaultdict(list)
    for v in list(vaults.values()) + list(dungeons.values()):
        for r in v.get("enemies") or []:
            if r["name"] in creatures:
                bit = v["name"] + (f" ({r['amount']}" if r.get("amount") else " (") + \
                    (f", power level {r['power_level']})" if r.get("power_level") else (f", {r['group']})" if r.get("group") else ")"))
                bit = bit.replace(" ()", "")
                if bit not in in_vault[r["name"]]:
                    in_vault[r["name"]].append(bit)
                creatures[r["name"]]["_src"].add("vaults", v["page"])
        for name in (v.get("listed_enemies") or {}).get("common", []) + (v.get("listed_enemies") or {}).get("notable", []):
            if name in creatures and not any(x.startswith(v["name"]) for x in in_vault[name]):
                in_vault[name].append(v["name"])
                creatures[name]["_src"].add("vaults", v["_src"].d.get("listed_enemies", [None])[0])
    roles: dict[str, list[str]] = defaultdict(list)
    for b in bosses:
        if b["creature"] in creatures:
            g = b["group"].lower()
            role = ("vault boss in " + _and(b.get("locations") or [])) if g.startswith("vault") else \
                ("world boss" if g.startswith("world") else "mini boss" if g.startswith("mini") else g)
            if role not in roles[b["creature"]]:
                roles[b["creature"]].append(role)
                creatures[b["creature"]]["_src"].add("role", b["page"])
            cr = creatures[b["creature"]]
            if not cr.get("weak") and b.get("weakness"):  # the infobox has none; the Boss table names one
                cr["weak"] = [b["weakness"]]
                cr["_src"].add("weak", b["page"])
    apply_external(creatures)  # after every wiki source: it fills only what the wiki left empty
    probe_stats = apply_probe(creatures, vaults, probe) if probe else None  # the game's own data: last, it wins
    for v in dungeons.values():
        for b in v.get("boss") or []:
            if b["creature"] in creatures:
                roles[b["creature"]].append(f"boss of {v['name']}")
                creatures[b["creature"]]["_src"].add("role", v["page"])
    doc: dict[str, Any] = {"schema": SCHEMA, "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                           "source": "wiki mirror data/wiki (CC BY-NC-SA 3.0); page ids are its pageids. Named src tags: "
                                     f"'{METABOT}' = {METABOT_URL} (snapshot data/bestiary_external.json), "
                                     f"'{OWN}' = his client's combat memory (data/skills/*/combat_*.json), "
                                     f"'{GAME}' = the game's own tables read on his client "
                                     "(client_mod/commands/bestiary_tables_probe.lua, merged with --from-probe)",
                           "creatures": {}, "vaults": {}, "dropped_by": {}}
    if probe_stats:
        doc["probe"] = probe_stats
    for title, e in creatures.items():
        if in_vault.get(title):
            e["vaults"] = in_vault[title]
        if roles.get(title):
            e["role"] = roles[title]
        e["src"] = e.pop("_src").out()
        e["text"] = creature_text(e, e.get("vaults") or [], e.get("role") or [])
        doc["creatures"][title] = e
    for title, e in list(vaults.items()) + list(dungeons.items()):
        e["src"] = e.pop("_src").out()
        e["text"] = vault_text(e, creatures)
        doc["vaults"][title] = e
    for item, rows in reverse.items():
        doc["dropped_by"][item] = {"item": item, "rows": rows, "aliases": _item_aliases(item, mirror),
                                   "text": reverse_text(item, rows)}
    doc["counts"] = counts(doc)
    return doc


def _item_aliases(item: str, mirror: Mirror) -> list[str]:
    al = set(mirror.aliases_of(item))
    m = re.match(r"^[A-Z]+:\s*(.+)$", item)  # "MOUNT: Springdown Runner"
    if m:
        al.add(m.group(1))
    return sorted(al)


CREATURE_FIELDS = ("variants", "weak", "resist", "immune", "locations", "attacks_any", "drops",
                   "weak_wiki", "resist_wiki", "immune_wiki", "attacks_wiki", "observed_attacks",
                   "journal", "game_attacks", "game_drops")
VAULT_FIELDS = ("area", "power_level", "opens", "enemies", "boss", "chests", "chest_items", "recipes")


def counts(doc: dict) -> dict:
    cr = doc["creatures"].values()
    va = [v for v in doc["vaults"].values() if v["kind"] == "vault"]
    du = [v for v in doc["vaults"].values() if v["kind"] == "dungeon"]

    def has(e, f):
        if f == "attacks_any":
            return bool(e.get("attacks") or e.get("attack_notes") or e.get("observed_attacks") or e.get("game_attacks"))
        if f == "attacks_wiki":
            return bool(e.get("attacks") or e.get("attack_notes"))
        if f in ("weak_wiki", "resist_wiki", "immune_wiki"):
            return any(isinstance(i, int) for i in e["src"].get(f[:-5], []))
        return bool(e.get(f))
    return {"creatures": len(doc["creatures"]), "vaults": len(va), "dungeons": len(du),
            "reverse_items": len(doc["dropped_by"]),
            "reverse_rows": sum(len(v["rows"]) for v in doc["dropped_by"].values()),
            "creatures_missing": {f: sum(1 for e in cr if not has(e, f)) for f in CREATURE_FIELDS},
            "vaults_missing": {f: sum(1 for e in va if not has(e, f)) for f in VAULT_FIELDS},
            "max_text": max((len(e["text"]) for sec in ("creatures", "vaults", "dropped_by") for e in doc[sec].values()), default=0)}


# ------------------------------------------------------------------------------ lookup with the bestiary


def _words(text: str) -> list[str]:
    from brain.knowledge import _stem, words
    return [_stem(w) for w in words(text)]


class Bestiary:
    """Name or alias matching over data/bestiary.json: the entries a query names, longest name first."""

    def __init__(self, doc: dict | None = None, path: Path = OUT):
        self.doc = doc if doc is not None else json.loads(Path(path).read_text(encoding="utf-8"))
        self.names: list[tuple[tuple[str, ...], int, str, str]] = []  # (words, priority, section, key)
        for sec, prio in (("creatures", 0), ("vaults", 0), ("dropped_by", 1)):
            for key, e in self.doc.get(sec, {}).items():
                for n in {e.get("name") or e.get("item") or key, key, *(e.get("aliases") or []), *(e.get("class_names") or [])}:
                    w = tuple(_words(n))
                    if w and (len(w) > 1 or len(w[0]) >= 4):
                        self.names.append((w, prio, sec, key))
        self.names.sort(key=lambda r: (-len(r[0]), r[1]))

    def match(self, query: str) -> list[tuple[str, str]]:
        q = _words(query)
        used = [False] * len(q)
        out: list[tuple[str, str]] = []
        for w, _prio, sec, key in self.names:
            n = len(w)
            for i in range(len(q) - n + 1):
                if tuple(q[i:i + n]) == w and not any(used[i:i + n]):
                    if (sec, key) not in out:
                        out.append((sec, key))
                    for j in range(i, i + n):
                        used[j] = True
                    break
        return out[:MAX_ENTRIES]

    def entry(self, sec: str, key: str) -> dict:
        return self.doc[sec][key]


class BestiaryLookup:
    """What lookup WOULD return with the bestiary: matched entries first (each under ENTRY_CHARS), then the old
    lookup's results in their order while the texts stay within TEXT_BUDGET."""

    def __init__(self, knowledge, bestiary: Bestiary, budget: int = TEXT_BUDGET):
        self.k = knowledge
        self.b = bestiary
        self.budget = budget  # 0: the entries alone (a measure of the bestiary, not a mode for the brain)
        self.build = getattr(knowledge, "build", None)

    def stats(self) -> dict:
        return self.k.stats()

    def lookup(self, query: str, kind: str | None = None) -> dict:
        res = self.k.lookup(query, kind)
        if not res.get("ok"):
            return res
        data = dict(res.get("data") or {})
        merged, info = merge(self.b, query, data.get("results") or [], self.budget)
        if not info:
            return res
        data["results"] = merged
        data["bestiary"] = info["entries"]
        return {**res, "data": data}


def merge(bestiary: Bestiary, query: str, results: list[dict], budget: int = TEXT_BUDGET) -> tuple[list[dict], dict | None]:
    """The entries ``query`` names first, then ``results`` in their order while all texts stay within ``budget``.
    Returns (results, info); info is None when no entry matched (results unchanged), else what a log line needs."""
    hits = bestiary.match(query or "")
    if not hits:
        return results, None
    mine = []
    for sec, key in hits:
        e = bestiary.entry(sec, key)
        mine.append({"source": "bestiary (wiki mirror)", "authoritative": False,
                     "kind": {"creatures": "creature", "vaults": e.get("kind", "vault"), "dropped_by": "item sources"}[sec],
                     "title": e.get("name") or e.get("item") or key, "text": e["text"]})
    used = sum(len(m["text"]) for m in mine)
    rest = []
    for r in results:
        n = len(str(r.get("text") or ""))
        if used + n <= budget:
            rest.append(r)
            used += n
    return mine + rest, {"entries": [m["title"] for m in mine], "chars": used, "old_kept": len(rest),
                         "old_dropped": len(results) - len(rest)}


# ------------------------------------------------------------------------------ score (the eval's own functions)


def load_eval():
    spec = importlib.util.spec_from_file_location("lookup_enemies_eval", ROOT / "evals" / "lookup_enemies_eval.py")
    ev = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ev)
    return ev


def score(heldout_once: bool = False, db: str | None = None, show_misses: bool = True) -> int:
    ev = load_eval()
    knowledge = ev.open_index(db)
    base_tuned = ev.run_all(knowledge, ev.load_cases(ev.TUNED))
    look = BestiaryLookup(knowledge, Bestiary())
    tuned = ev.run_all(look, ev.load_cases(ev.TUNED))
    only = ev.run_all(BestiaryLookup(knowledge, look.b, budget=0), ev.load_cases(ev.TUNED))
    b, a, o = ev.summarise(base_tuned), ev.summarise(tuned), ev.summarise(only)
    sizes = [len(look.b.entry(*m)["text"]) for c in ev.load_cases(ev.TUNED) for m in look.b.match(c["query"])[:1]]
    print(f"index build {knowledge.build}")
    print(f"BEFORE (lookup today)   TUNED {b['hits']}/{b['n']}  by kind: "
          + ", ".join(f"{k} {h}/{n}" for k, (h, n) in b["by_kind"].items())
          + f"  mean {b['mean_chars']} chars, max {b['max_chars']}, mean {b['mean_ms']} ms")
    print(f"AFTER  (bestiary first) TUNED {a['hits']}/{a['n']}  by kind: "
          + ", ".join(f"{k} {h}/{n}" for k, (h, n) in a["by_kind"].items())
          + f"  mean {a['mean_chars']} chars, max {a['max_chars']}, mean {a['mean_ms']} ms")
    print(f"ENTRY ONLY (no fallback) TUNED {o['hits']}/{o['n']}  by kind: "
          + ", ".join(f"{k} {h}/{n}" for k, (h, n) in o["by_kind"].items())
          + f"  entry text mean {round(sum(sizes) / max(1, len(sizes)))} chars, max {max(sizes, default=0)}"
          + f"  ({len(sizes)} of {o['n']} queries matched an entry)")
    if show_misses:
        for r, r0 in zip(tuned, only):
            r = {**r, "entry_only": r0["hit"]}
            first = (r["titles"] or [None])[0]
            print(f"  {'hit ' if r['hit'] else 'MISS'} {r['id']:<24} q={r['query']!r:<32} first={first!r} {r['chars']} chars"
                  + f" entry-only {'hit' if r['entry_only'] else 'miss'}" + ("" if r["hit"] else f" missing={r['missing']}"))
    if heldout_once:
        held = ev.run_all(look, ev.load_cases(ev.HELDOUT))
        print(ev.report(tuned, held).splitlines()[-1])  # the eval's own one line for the held-out half
    return 0


# ------------------------------------------------------------------------------ cli


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    bp = sub.add_parser("build", help="write data/bestiary.json")
    bp.add_argument("--from-probe", type=Path, action="append", default=[], metavar="FILE",
                    help="merge the game's own tables from a bestiary_tables_probe output "
                         "(client_io/out/bestiary_tables_probe.json); repeat for several runs or one-group calls (ARGS.only; a later file's group replaces that group only, attack slices add up)")
    s = sub.add_parser("show", help="the bestiary entries a query matches")
    s.add_argument("query")
    sc = sub.add_parser("score", help="the lookup eval's tuned half with the bestiary first")
    sc.add_argument("--heldout-once", action="store_true", help="also print the held-out half's one number")
    sc.add_argument("--db", help="a knowledge.sqlite to use instead of the live index")
    fm = sub.add_parser("fetch-metabot", help=f"refresh {EXTERNAL.name} from {METABOT_URL} (network)")
    fm.add_argument("--html", type=Path, help="parse this saved copy of the page instead of fetching it")
    a = ap.parse_args(argv)
    if a.cmd == "fetch-metabot":
        doc = fetch_metabot(EXTERNAL, a.html)
        print(f"wrote {EXTERNAL}: {len(doc['creatures'])} creatures")
        return 0
    if a.cmd == "build":
        t0 = time.perf_counter()
        doc = build(probe=load_probe(a.from_probe) if a.from_probe else None)
        OUT.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
        print(json.dumps(doc["counts"], indent=1))
        if doc.get("probe"):
            pr = {k: v for k, v in doc["probe"].items() if k not in ("unread", "unmatched")}
            pr["unmatched"] = {k: len(v) for k, v in doc["probe"]["unmatched"].items()}
            pr["unread"] = len(doc["probe"]["unread"])
            print("probe:", json.dumps(pr))
        print(f"wrote {OUT} in {time.perf_counter() - t0:.1f} s")
        return 0
    if a.cmd == "show":
        b = Bestiary()
        for sec, key in b.match(a.query):
            print(f"--- {sec}/{key}\n{b.entry(sec, key)['text']}\n")
        return 0
    if a.cmd == "score":
        return score(a.heldout_once, a.db)
    return 1


if __name__ == "__main__":
    sys.exit(main())

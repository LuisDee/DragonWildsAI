"""Game knowledge for the brain: one searchable index over game data (authoritative) and the local
wiki mirror (secondary), behind the read-only ``lookup`` tool.

Design: docs/design/knowledge-lookup.md (research 2026-10-25-scalable-agent-frameworks.md section 4).
Prior art: PUBG Ally's knowledge-lookup tool ("tool results are the only ground truth"), Mindcraft's
``!searchWiki``, GITM's wiki + recipe retrieval.

* **Game docs** are generated from the newest ``data/items_*.json``, ``data/recipes_*.json`` (items,
  recipes, stations) and ``data/spells_*.json`` (spells, perks); nothing is hand-written. Every one is
  labelled ``authoritative`` with its build.
* **Wiki docs** are the section chunks of ``data/wiki/pages/*.json`` (tools/wiki_mirror.py), with the
  page URL (attribution, CC BY-NC-SA 3.0). Redirect titles are aliases.
* **Retrieval:** SQLite FTS5 (BM25, ``porter unicode61`` stemming), title and aliases weighted, then a
  title-coverage re-rank so the thing *named* wins over pages that merely mention it. Game results
  always come before wiki results.
* The index is cached in ``data/wiki/knowledge.sqlite`` (gitignored with the mirror) and rebuilt when
  any source file changes; with no mirror it is game-only and in memory.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterable

from .fileio import read_json
from .paths import REPO_ROOT, _env_path

SCHEMA = 9  # bump when the doc format changes (forces a rebuild)
GAME_K, WIKI_K = 3, 2  # results per tier
POOL = 200  # BM25 candidates per tier for the title re-rank
SNIPPET = {0: 900, 1: 520}  # characters per snippet, by tier (game cards are cut by whole fields: _clip_card)
NOTE = ("Game data (authoritative=true) is read from this game build and wins over the wiki. Wiki text is "
        "community-written and may be outdated; say so if it matters. Answer only from these results.")
# Function words only (English, not game facts): they carry no meaning for BM25 over names.
STOP = frozenset("""a an and are as at be by can could do does did for from get got how i if in into is it its
me my of on or our should so some that the their them then there these they this to us was we what when where
which who why will with would you your about any much many""".split())


def data_dir() -> Path:
    return _env_path("DW_DATA_DIR", REPO_ROOT / "data")


def wiki_dir() -> Path:
    return _env_path("DW_WIKI_DIR", REPO_ROOT / "data" / "wiki")


# ------------------------------------------------------------------------------ text helpers


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", (text or "").lower())


def _stem(w: str) -> str:
    """Crude plural folding for the title re-rank (FTS5's porter does the real stemming)."""
    if len(w) <= 3 or w.endswith("ss"):
        return w
    for suf, rep in (("ies", "y"), ("ves", "f"), ("xes", "x"), ("ches", "ch"), ("shes", "sh"), ("s", "")):
        if w.endswith(suf):
            return w[: -len(suf)] + rep
    return w


def _terms(text: str) -> set[str]:
    return {_stem(w) for w in words(text) if w not in STOP}


def _humanize(ident: str | None) -> str:
    """'ItemFilter.Type.Consumable.Drink' -> 'Consumable Drink'; 'SKILL_Artisan' -> 'Artisan';
    'ToolsMeleeBench' -> 'Tools Melee Bench'."""
    if not ident:
        return ""
    s = str(ident)
    s = re.sub(r"^(ItemFilter|Item|SKILL)[._]", "", s)
    s = re.sub(r"^(Type|Material|Equipment)\.", "", s)
    s = s.replace(".", " ").replace("_", " ")
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", s).strip()


def _clip(text: str, limit: int) -> str:
    t = " ".join(str(text).split()) if "\n" not in text else re.sub(r"[ \t]+", " ", text).strip()
    if len(t) <= limit:
        return t
    return t[: limit - 1].rsplit(" ", 1)[0] + "…"


NL = chr(10)  # game cards hold one field per line
HOW = "How to get: "
OR = " | OR | "


def _clip_card(body: str, limit: int) -> str:
    """A game-data card within ``limit`` characters WITHOUT cutting a field: structured facts (recipe inputs and
    counts, stations, unlocks) are never cut mid-way. In order: shorten the "Used in" list, drop the flavour
    description, keep whole recipe alternatives (saying how many more exist), then drop trailing facts."""
    if len(body) <= limit:
        return body
    lines = body.split(NL)

    def total() -> int:
        return sum(len(x) + 1 for x in lines)
    for i, ln in enumerate(lines):
        if ln.startswith("Used in ") and ": " in ln:
            head, rest = ln.split(": ", 1)
            names = rest.rstrip("…").split(", ")
            lines[i] = f"{head}: {', '.join(names[:4])}" + ("…" if len(names) > 4 else "")
    if total() > limit:
        lines = [x for x in lines if not x.startswith("Description: ")]
    for i, ln in enumerate(lines):
        if total() <= limit or not ln.startswith(HOW):
            continue
        alts = ln[len(HOW):].split(OR)
        other = total() - len(ln) - 1
        keep: list[str] = []
        for a in alts:
            if keep and other + len(HOW + OR.join(keep + [a])) + 60 > limit:
                break
            keep.append(a)
        more = len(alts) - len(keep)
        lines[i] = HOW + OR.join(keep) + (f"{OR}{more} more way(s): look up its recipes" if more else "")
    while total() > limit and len(lines) > 2:  # trailing facts go last; the first line and How to get stay
        drop = next((j for j in range(len(lines) - 1, 0, -1) if not lines[j].startswith(HOW)), None)
        if drop is None:
            break
        lines.pop(drop)
    return NL.join(lines)


def newest(directory: Path, prefix: str) -> Path | None:
    """The newest <prefix>_<build>.json in ``directory`` (builds sort by name), or None."""
    files = sorted(Path(directory).glob(f"{prefix}_*.json"))
    return files[-1] if files else None


_newest = newest  # older callers


def _deprecated(rec: dict) -> bool:
    """Assets the game itself files as deprecated or test (folder / suffix in the asset path)."""
    path = str(rec.get("path") or "")
    return bool(rec.get("test")) or "/Deprecated/" in path or re.search(r"_OLD(\.|$)", path) is not None


# ------------------------------------------------------------------------------ game docs


def _count_list(entries: Iterable[dict]) -> str:
    return " + ".join(f"{e.get('count', 1)} {e.get('name') or e.get('item')}" for e in entries)


def game_docs(data: Path) -> tuple[list[dict], str | None]:
    """Docs generated from the build's catalogs: items, recipes, stations, spells, perks."""
    docs: list[dict] = []
    items_f, recipes_f, spells_f = (_newest(data, p) for p in ("items", "recipes", "spells"))
    items = json.loads(items_f.read_text(encoding="utf-8")) if items_f else {}
    recipes = json.loads(recipes_f.read_text(encoding="utf-8")) if recipes_f else {}
    spells = json.loads(spells_f.read_text(encoding="utf-8")) if spells_f else {}
    build = items.get("build") or recipes.get("build") or spells.get("build")
    stations = recipes.get("stations") or {}

    def station_name(sid: str) -> str:
        st = stations.get(sid) or {}
        return st.get("display_name") or _humanize(sid.split("@")[0])

    live_recipes = {rid: r for rid, r in (recipes.get("recipes") or {}).items() if not _deprecated(r)}
    made_by: dict[str, list[dict]] = {}
    used_in: dict[str, list[str]] = {}
    for r in live_recipes.values():
        for o in r.get("outputs") or []:
            made_by.setdefault(o.get("item"), []).append(r)
        for i in r.get("inputs") or []:
            outs = [o.get("name") or o.get("item") for o in r.get("outputs") or []]
            used_in.setdefault(i.get("item"), []).extend(outs)

    # Internal class names in unlock conditions -> the station's in-game name (from the same data).
    class_names = {c: st.get("display_name") for st in stations.values() for c in st.get("class_names") or []
                   if st.get("display_name")}
    item_names = {iid: it.get("name") for src in (recipes.get("items") or {}, items.get("items") or {})
                  for iid, it in src.items() if it.get("name")}

    def is_vendor(sid: str) -> bool:
        st = stations.get(sid) or {}
        # is_vendor from the station table; Umbral Sands traders carry it only in their asset name
        return bool(st.get("is_vendor")) or "merchant" in sid.lower()

    def unlock_text(q: str) -> str:
        q = re.sub(r"\b(BP_\w+?_C)\b", lambda m: class_names.get(m.group(1)) or _humanize(m.group(1)[3:-2]), q)
        return " ".join(q.split())

    def recipe_line(r: dict) -> str:
        sids = r.get("stations") or []
        where = " or ".join(dict.fromkeys(station_name(x) for x in sids)) or "no station"
        outs, ins = _count_list(r.get("outputs") or []), _count_list(r.get("inputs") or [])
        if sids and all(is_vendor(x) for x in sids):
            line = f"buy {outs} from {where} (trader) for {ins}"
        else:
            line = f"{outs} from {ins} at {where}"
            if "processing" in set(r.get("station_kinds") or []):
                lo, hi = ((r.get("processing_time") or []) + [None, None])[:2]
                span = f"{lo:g}s" if hi is None or lo == hi else f"{lo:g}-{hi:g}s"
                line += f" (processing: load ingredients + fuel, {span}, collect)" if lo is not None else " (processing)"
            if r.get("skill"):
                line += f", {_humanize(r['skill'])} skill"
        if r.get("alternative"):
            alt = r["alternative"]
            line += f", sometimes {alt.get('count', 1)} {item_names.get(alt.get('item')) or alt.get('item')} instead"
        unlock = [x.get("query") for x in (r.get("unlock") or {}).get("bundles") or [] if x.get("query")]
        if unlock:
            line += f"; unlock: {unlock_text(unlock[0])}"
        return line

    # ---- items: the full equipment catalog merged with every item recipes/stations reference
    merged: dict[str, dict] = {}
    for iid, it in (recipes.get("items") or {}).items():
        merged[iid] = dict(it)
    for iid, it in (items.get("items") or {}).items():
        merged[iid] = {**merged.get(iid, {}), **it}
    for iid, it in merged.items():
        if _deprecated(it) or not it.get("name") or it.get("category") == "test":
            continue
        parts = []
        cat = _humanize(it.get("category_tag") or it.get("category"))
        if it.get("kind") in ("held", "wearable"):
            desc = [it.get("role"), it.get("category"), f"slot {it['slot']}" if it.get("slot") else None,
                    f"tier {it['tier']}" if it.get("tier") else None,
                    it.get("range_type") if it.get("range_type") not in (None, "none") else None]
            parts.append("Equipment: " + ", ".join(str(d) for d in desc if d))
        elif cat:
            parts.append(f"Type: {cat}")
        if it.get("flavour"):
            flav = re.sub(r"\{[A-Za-z]+\}", "", it["flavour"]).strip()
            if flav:
                parts.append(f"Description: {flav.rstrip('.')}")
        recs = made_by.get(iid) or []
        crafted = [r for r in recs if not all(is_vendor(x) for x in r.get("stations") or [])]
        if recs:
            parts.append("How to get: " + " | OR | ".join(recipe_line(r) for r in (crafted + [r for r in recs if r not in crafted])[:4]))
        if not crafted:
            parts.append("No crafting recipe makes it (gathered, dropped or found in the world)")
        stats = [f"{s.get('name')} {s.get('value')}" for s in it.get("custom_stats") or [] if s.get("name")]
        if stats:
            parts.append("Stats: " + "; ".join(stats))
        if it.get("damage_types"):
            parts.append("Damage types: " + ", ".join(_humanize(t).split()[-1] for t in it["damage_types"]))
        facts = [f"weight {it['weight']:g}" if isinstance(it.get("weight"), (int, float)) else None,
                 f"stacks to {it['max_stack']}" if (it.get("max_stack") or 0) > 1 else None,
                 f"durability {it['durability']:g}" if (it.get("durability") or -1) > 0 else None,
                 f"fuel value {it['fuel_value']:g}" if it.get("fuel_value") else None]
        facts = [f for f in facts if f]
        if facts:
            parts.append(", ".join(facts).capitalize())

        uses = list(dict.fromkeys(used_in.get(iid) or []))
        if uses:
            parts.append(f"Used in {len(uses)} recipe(s): " + ", ".join(uses[:8]) + ("…" if len(uses) > 8 else ""))
        tags = f"item {cat} {it.get('category') or ''}" + (" recipe craft make" if crafted else "")
        docs.append({"tier": 0, "kind": "item", "title": it["name"], "tags": tags,
                     "body": NL.join(parts), "ref": iid})  # one field per line: cut by whole fields

    # ---- stations
    for sid, st in stations.items():
        if st.get("test") or not st.get("recipes") or not st.get("display_name"):
            continue
        names = list(dict.fromkeys(next((o.get("name") for o in live_recipes[r].get("outputs") or []), r)
                                   for r in st["recipes"] if r in live_recipes))
        fuels = [recipes.get("items", {}).get(f, {}).get("name") or f for f in st.get("accepted_fuels") or []]
        body = (f"{st['display_name']} is a {st.get('kind')} station" + (" (a vendor)" if st.get("is_vendor") else "")
                + f". It makes {len(names)} things, e.g. " + ", ".join(names[:12])
                + (f". Fuel: {', '.join(fuels)}" if fuels else "")
                + (f". You build it from the build menu ({_humanize(Path(st['building']).stem.split('.')[0])})"
                   if st.get("building") else "")
                + (f". Interact prompt: {st['interaction'].get('prompt')}" if (st.get("interaction") or {}).get("prompt") else ""))
        docs.append({"tier": 0, "kind": "station", "title": st["display_name"], "tags": f"station {st.get('kind')}",
                     "body": body, "ref": sid})

    # ---- spells and perks
    perks = spells.get("perks") or {}
    for sid, sp in (spells.get("spells") or {}).items():
        u = sp.get("usage") or {}
        name = sp.get("name") or u.get("name") or _humanize(sid)
        parts = [f"Spell ({_humanize(u.get('role'))})" if u.get("role") else "Spell"]
        if u.get("use_when"):
            parts.append(u["use_when"])
        if u.get("runes"):
            parts.append("Runes: " + ", ".join(f"{n} {r}" for r, n in u["runes"].items()))
        if sp.get("cooldown_s") or u.get("cooldown_s"):
            parts.append(f"Cooldown {sp.get('cooldown_s') or u.get('cooldown_s'):g}s")
        if u.get("preconditions"):
            parts.append("Needs: " + "; ".join(u["preconditions"]))
        perk = perks.get(sp.get("owning_perk") or "")
        if perk:
            parts.append(f"Unlocked by the perk {perk.get('name')} ({_humanize(perk.get('skill_name'))} level {perk.get('level')})")
        elif (u.get("wiki") or {}).get("level"):
            parts.append(f"Unlock: {u['wiki'].get('skill')} level {u['wiki']['level']} (per the wiki)")
        docs.append({"tier": 0, "kind": "spell", "title": name, "tags": f"spell magic {u.get('role') or ''}",
                     "body": NL.join(parts), "ref": sid})
    spell_names = {v.get("asset") or k: v.get("name") for k, v in (spells.get("spells") or {}).items()}
    for pid, pk in perks.items():
        if not pk.get("name"):
            continue
        sp = (spells.get("perk_to_spell") or {}).get(pid)
        body = f"Perk of the {_humanize(pk.get('skill_name'))} skill at level {pk.get('level')}"
        if sp:
            body += f"; it unlocks the spell {spell_names.get(sp) or _humanize(str(sp).split('.')[-1])}"
        docs.append({"tier": 0, "kind": "perk", "title": pk["name"], "tags": "perk skill unlock", "body": body,
                     "ref": pid})
    return docs, build


# ------------------------------------------------------------------------------ wiki docs


def wiki_docs(root: Path) -> list[dict]:
    man_f = root / "manifest.json"
    if not man_f.exists():
        return []
    man = json.loads(man_f.read_text(encoding="utf-8"))
    aliases: dict[str, list[str]] = {}
    for src, dst in (man.get("redirects") or {}).items():
        aliases.setdefault(dst, []).append(src)
    docs = []
    for title, info in (man.get("pages") or {}).items():
        f = root / info["file"]
        try:
            rec = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        tags = " ".join([rec.get("infobox") or "", *rec.get("categories", [])])
        unlocks = unlock_facts(rec)
        for sec in rec.get("sections") or []:
            lead = sec.get("heading") is None and not sec.get("part")
            body = sec["text"]
            url = rec["url"] + ("#" + sec["anchor"].replace(" ", "_") if sec.get("anchor") else "")
            docs.append({"tier": 1, "kind": (rec.get("infobox") or "page").lower(), "title": rec["title"],
                         "aliases": " | ".join(aliases.get(title, [])) if lead else "",
                         "tags": f"{tags} {sec.get('heading') or ''}", "heading": sec.get("heading") or "",
                         "body": body, "url": url, "ref": str(rec.get("pageid"))})
        if unlocks:  # how it unlocks, lifted out of the page's prose into a doc of its own (index time)
            docs.append({"tier": 1, "kind": (rec.get("infobox") or "page").lower(), "title": rec["title"],
                         "aliases": "", "tags": f"{tags} Unlock", "heading": "Unlock",
                         "body": f"Unlock: {' '.join(unlocks)}", "url": rec["url"], "ref": str(rec.get("pageid"))})
    return docs


_SENTENCE = re.compile(r"[^.!?\n]*\bunlock\w*\b[^.!?\n]*[.!?]", re.I)


def unlock_facts(rec: dict, limit: int = 3) -> list[str]:
    """Sentences of a wiki page that say how the thing unlocks ("The spinning wheel is unlocked when players
    harvest from flax plants ..."), from any of its sections, deduplicated. Data from the page itself."""
    out: list[str] = []
    for sec in rec.get("sections") or []:
        for m in _SENTENCE.finditer(sec.get("text") or ""):
            line = " ".join(m.group(0).split())
            if 12 <= len(line) <= 300 and line not in out:
                out.append(line)
            if len(out) >= limit:
                return out
    return out


# ------------------------------------------------------------------------------ the index


def _fts_ok() -> bool:
    try:
        sqlite3.connect(":memory:").execute("CREATE VIRTUAL TABLE t USING fts5(a, tokenize='porter unicode61')")
        return True
    except sqlite3.OperationalError:
        return False


def skill_rows(root: Path) -> dict[str, dict]:
    """skill key ('attack', predicates._skill_key) -> {name, how, about, url, training_page} from the wiki mirror's
    skill pages (infobox Skill; ``how`` = the infobox description, the in-game line, e.g. "Defeat enemies with melee
    weapons to level this skill."). Built once with the index (Knowledge._build); data only, never a table here."""
    from .predicates import _skill_key
    out: dict[str, dict] = {}
    titles: set[str] = set()
    pages = Path(root) / "pages"
    for f in sorted(pages.glob("*.json")) if pages.is_dir() else []:
        d = read_json(f, default=None)
        if not isinstance(d, dict):
            continue
        titles.add(str(d.get("title") or ""))
        if str(d.get("infobox") or "").lower() != "skill":
            continue
        lead = next((x.get("text") or "" for x in d.get("sections") or [] if not x.get("heading")), "")
        name = re.search(r"^name:\s*(.+)$", lead, re.M)
        how = re.search(r"^description:\s*(.+)$", lead, re.M)
        body = re.sub(r"^(name|description):.*$", "", lead, flags=re.M).strip()
        nm = (name.group(1) if name else d.get("title") or "").strip()
        out[_skill_key(nm)] = {"name": nm, "how": how.group(1).strip() if how else None,
                               "about": " ".join(body.split())[:400], "url": d.get("url")}
    for v in out.values():
        v["training_page"] = f"{v['name']} training" in titles
    return out


@lru_cache(maxsize=4)
def skill_pages(root: Path | None = None) -> dict[str, dict]:
    """The skill rows the index was built with (meta ``skill_pages``); parsed from the pages only when there is no
    built index yet."""
    root = Path(root) if root else wiki_dir()
    db = root / "knowledge.sqlite"
    if db.exists():
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            try:
                row = con.execute("SELECT v FROM meta WHERE k='skill_pages'").fetchone()
            finally:
                con.close()
            if row and row[0]:
                return json.loads(row[0])
        except (sqlite3.Error, ValueError):
            pass
    return skill_rows(root)


class Knowledge:
    """``lookup(query, kind)`` over game data + wiki. Thread-safe for reads."""

    def __init__(self, data: Path | None = None, wiki: Path | None = None, db_path: Path | None = None,
                 rebuild: bool = False, log=None):
        self.data = Path(data) if data else data_dir()
        self.wiki = Path(wiki) if wiki else wiki_dir()
        self.log = log
        self._lock = threading.Lock()
        if not _fts_ok():
            raise RuntimeError("this sqlite3 has no FTS5")
        has_wiki = (self.wiki / "manifest.json").exists()
        self.db_path = Path(db_path) if db_path else (self.wiki / "knowledge.sqlite" if has_wiki else None)
        sig = self._signature()
        self.db = self._connect()
        if rebuild or self._meta("signature") != sig:
            self._build(sig)
        self.build = self._meta("build")

    # ---------------------------------------------------------------- build

    def _signature(self) -> str:
        files = [p for p in (_newest(self.data, n) for n in ("items", "recipes", "spells")) if p]
        man = self.wiki / "manifest.json"
        if man.exists():
            files.append(man)
        pages = self.wiki / "pages"
        sig = [[f.name, f.stat().st_size, f.stat().st_mtime_ns] for f in files]
        if pages.is_dir():
            stats = [e.stat() for e in os.scandir(pages) if e.name.endswith(".json")]
            sig.append(["pages", len(stats), max((s.st_mtime_ns for s in stats), default=0)])
        return json.dumps([SCHEMA, sig])

    def _connect(self) -> sqlite3.Connection:
        target = str(self.db_path) if self.db_path else ":memory:"
        db = sqlite3.connect(target, check_same_thread=False)
        db.execute("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
        return db

    def _meta(self, key: str) -> str | None:
        row = self.db.execute("SELECT v FROM meta WHERE k=?", (key,)).fetchone()
        return row[0] if row else None

    def _build(self, sig: str) -> None:
        gdocs, build = game_docs(self.data)
        wdocs = wiki_docs(self.wiki)
        with self.db:
            self.db.execute("DROP TABLE IF EXISTS docs")
            self.db.execute("CREATE VIRTUAL TABLE docs USING fts5(title, aliases, tags, body, tier UNINDEXED, "
                            "kind UNINDEXED, heading UNINDEXED, url UNINDEXED, ref UNINDEXED, "
                            "tokenize='porter unicode61 remove_diacritics 2')")
            self.db.executemany(
                "INSERT INTO docs(title, aliases, tags, body, tier, kind, heading, url, ref) VALUES (?,?,?,?,?,?,?,?,?)",
                [(d["title"], d.get("aliases", ""), d.get("tags", ""), d["body"], d["tier"], d["kind"],
                  d.get("heading", ""), d.get("url", ""), d.get("ref", "")) for d in gdocs + wdocs])
            self.db.execute("DELETE FROM meta")
            self.db.executemany("INSERT INTO meta(k, v) VALUES (?, ?)",
                                [("signature", sig), ("build", build or ""), ("game_docs", str(len(gdocs))),
                                 ("wiki_docs", str(len(wdocs))),
                                 ("skill_pages", json.dumps(skill_rows(self.wiki), ensure_ascii=False))])
        if self.log:
            self.log.log("knowledge_built", game_docs=len(gdocs), wiki_docs=len(wdocs), build=build)

    def stats(self) -> dict:
        kinds = dict(self.db.execute("SELECT kind, count(*) FROM docs GROUP BY kind ORDER BY count(*) DESC"
                                     ).fetchall())
        return {"build": self.build, "game_docs": int(self._meta("game_docs") or 0),
                "wiki_docs": int(self._meta("wiki_docs") or 0), "kinds": kinds, "db": str(self.db_path or ":memory:")}

    def kinds(self, top: int = 12) -> list[str]:
        """The kinds a lookup can filter on, from the data (game kinds first, then the wiki's commonest)."""
        rows = self.db.execute("SELECT kind, min(tier), count(*) FROM docs GROUP BY kind "
                               "ORDER BY min(tier), count(*) DESC").fetchall()
        return [k for k, _, _ in rows if k and k != "page"][:top]

    # ---------------------------------------------------------------- search

    def _search(self, tier: int, terms: list[str], kind: str | None, limit: int) -> list[dict]:
        q = " OR ".join(f'"{t}"' for t in terms)
        sql = ("SELECT title, aliases, tags, body, kind, heading, url, ref, bm25(docs, 12.0, 8.0, 2.0, 1.0) AS s "
               "FROM docs WHERE docs MATCH ? AND tier = ?")
        args: list[Any] = [q, tier]
        if kind:
            sql += " AND (kind = ? OR instr(lower(tags), ?) > 0)"
            args += [kind, kind]
        sql += " ORDER BY s LIMIT ?"
        args.append(limit)
        with self._lock:
            rows = self.db.execute(sql, args).fetchall()
        keys = ("title", "aliases", "tags", "body", "kind", "heading", "url", "ref", "bm25")
        return [dict(zip(keys, r)) for r in rows]

    @staticmethod
    def _coverage(r: dict, query_terms: set[str]) -> tuple[float, float]:
        """(share of the title's words the query names, rank score) for the best of title and aliases."""
        best = (0.0, 0.0)
        for name in [r["title"], *(r["aliases"].split("|") if r["aliases"] else [])]:
            t = _terms(name)
            if not t:
                continue
            hit = len(t & query_terms)
            cov = hit / len(t)
            score = cov + hit / max(1, len(query_terms)) + (1.0 if t == query_terms else 0.0)
            best = max(best, (cov, score), key=lambda x: x[1])
        return best

    def _rerank(self, rows: list[dict], query_terms: set[str]) -> list[dict]:
        """The thing NAMED first (title/alias coverage of the query), a page's lead section before its
        other sections, then BM25."""
        for r in rows:
            r["cov"], r["score"] = self._coverage(r, query_terms)
        return sorted(rows, key=lambda r: (-round(r["score"], 3), 0 if not r["heading"] else 1, r["bm25"]))

    def lookup(self, query: str, kind: str | None = None, k_game: int = GAME_K, k_wiki: int = WIKI_K) -> dict:
        terms = [w for w in dict.fromkeys(words(query)) if w not in STOP]
        if not terms:
            return {"ok": False, "reason": "invalid_args", "data": {"error": "empty query"}}
        kind = (kind or "").strip().lower() or None
        qterms = {_stem(t) for t in terms}
        out: list[dict] = []
        found = {tier: self._search(tier, terms, kind, POOL) for tier in (0, 1)}
        kind_ignored = bool(kind) and not any(found.values())
        if kind_ignored:  # nothing of that kind: the filter was a guess, search everything
            found = {tier: self._search(tier, terms, None, POOL) for tier in (0, 1)}
        for tier, k in ((0, k_game), (1, k_wiki)):
            ranked = self._rerank(found[tier], qterms)
            if tier == 0:  # game data only when it is about the thing named, never loosely related items
                ranked = [r for r in ranked if r["cov"] >= 0.5]
            if tier == 1:  # one snippet per page section, at most two sections per page
                seen: dict[str, int] = {}
                picked = []
                for r in ranked:
                    if seen.get(r["title"], 0) >= 2:
                        continue
                    seen[r["title"]] = seen.get(r["title"], 0) + 1
                    picked.append(r)
                ranked = picked
            for r in ranked[:k]:
                item = {"source": f"game data (build {self.build})" if tier == 0 else "wiki",
                        "authoritative": tier == 0, "kind": r["kind"], "title": r["title"],
                        "text": _clip_card(r["body"], SNIPPET[0]) if tier == 0 else _clip(r["body"], SNIPPET[tier])}
                if tier == 1:
                    if r["heading"]:
                        item["section"] = r["heading"]
                    item["url"] = r["url"]
                out.append(item)
        data: dict[str, Any] = {"query": query, "results": out, "note": NOTE}
        if kind_ignored:
            data["kind_ignored"] = True
        if not out:
            data["note"] = "Nothing found in game data or the wiki. Say you don't know rather than guess."
        return {"ok": True, "reason": None, "data": data}


def open_knowledge(log=None) -> Knowledge | None:
    """The default index for the live brain, or None (then the lookup tool is not offered)."""
    try:
        return Knowledge(log=log)
    except Exception as exc:  # knowledge is optional; never block the brain on it
        if log:
            log.log("knowledge_unavailable", error=repr(exc))
        return None

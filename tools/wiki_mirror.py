"""Local mirror of the RuneScape: Dragonwilds wiki, as clean text for the brain's ``lookup`` tool.

Design: docs/design/knowledge-lookup.md (research 2026-10-25-scalable-agent-frameworks.md section 4.2).

* **Source:** the official MediaWiki Action API (``api.php``), used exactly as Weird Gloop's Help:APIs
  page asks: a descriptive User-Agent with contact, sequential requests >= 1 s apart, ``maxlag=5``
  with Retry-After back-off, gzip. No official dump exists (the only bulk path, Special:Export,
  returns the same wikitext). A full mirror is about 100 requests; later runs fetch only pages whose
  revision id changed.
* **Conversion:** wikitext -> text with mwparserfromhell (structural rules, no per-template list):
  infoboxes become ``key: value`` lines, templates with named params a ``Name: k=v; ...`` line,
  inline link-style templates keep their text, navboxes and short stand-alone templates are dropped,
  tables become one ``a | b | c`` line per row, refs/files/comments go, and so do sections that carry
  no game facts (update history, references, gallery, journal lore).
* **Storage (gitignored, CC BY-NC-SA 3.0, never published):** ``data/wiki/pages/<pageid>.json``
  (title, revid, url, infobox type, sections, raw wikitext) and ``data/wiki/manifest.json``
  (page -> pageid, revid, fetched_at, file; redirects as aliases). After a refresh the knowledge
  index (brain/knowledge.py) is rebuilt.

Usage (repo root):
    .venv\\Scripts\\python.exe -m tools.wiki_mirror                 # incremental refresh + index
    .venv\\Scripts\\python.exe -m tools.wiki_mirror --full          # refetch every page
    .venv\\Scripts\\python.exe -m tools.wiki_mirror --titles "Iron Bar|Wolf"
    .venv\\Scripts\\python.exe -m tools.wiki_mirror --reconvert     # re-run conversion offline
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SITE = "https://dragonwilds.runescape.wiki"
API = SITE + "/api.php"
LICENCE = "CC BY-NC-SA 3.0 (https://meta.weirdgloop.org/w/Meta:Copyrights)"
CONTACT = os.environ.get("DW_WIKI_CONTACT", "luisdeburnaybastos@gmail.com")
USER_AGENT = (f"DWCompanion-wiki-mirror/1.0 (private non-commercial AI-companion research; local mirror, "
              f"~1 req/s, incremental by revid; contact {CONTACT})")
BATCH = 50  # titles per content request (the API's non-bot limit)
SCHEMA = "dw_wiki_page/1"

# Sections without game facts (wiki structure, not game data): dropped with their subsections.
SKIP_SECTIONS = {"update history", "references", "gallery", "journal", "external links", "see also",
                 "navigation", "changes"}
# Infobox keys that are presentation only.
SKIP_KEY = re.compile(r"^(image|caption|imagesize|alt|release|update|removal|version|aka|id|members)", re.I)
MAX_CHUNK = 1800  # characters per stored section chunk


def wiki_dir() -> Path:
    v = os.environ.get("DW_WIKI_DIR")
    return Path(v) if v else REPO_ROOT / "data" / "wiki"


def page_url(title: str, anchor: str | None = None) -> str:
    url = SITE + "/w/" + urllib.parse.quote(title.replace(" ", "_"), safe="/:()',!")
    return url + ("#" + urllib.parse.quote(anchor.replace(" ", "_"), safe="()',!") if anchor else "")


# ------------------------------------------------------------------------------ conversion


def _mw():
    import mwparserfromhell  # tool-only dependency (brain/requirements.txt)
    return mwparserfromhell


def _is_inline(nodes: list, i: int) -> bool:
    """True when the node at i shares its line with other text (an inline template)."""
    from mwparserfromhell.nodes import Text
    prev = nodes[i - 1] if i > 0 else None
    nxt = nodes[i + 1] if i + 1 < len(nodes) else None
    before = isinstance(prev, Text) and not str(prev).endswith("\n") and str(prev).strip() != ""
    before = before or (prev is not None and not isinstance(prev, Text))
    after = isinstance(nxt, Text) and not str(nxt).startswith("\n") and str(nxt).strip() != ""
    return before or after


class Converter:
    """Wikitext -> plain text. Collects the page's infobox type and categories on the way."""

    def __init__(self):
        self.infobox: str | None = None
        self.categories: list[str] = []

    def render(self, code) -> str:
        nodes = list(code.nodes)
        return "".join(self._node(n, nodes, i) for i, n in enumerate(nodes))

    def _param_value(self, p) -> str:
        return _squash(self.render(p.value))

    def _template(self, t, inline: bool) -> str:
        name = _squash(self.render(t.name))
        if not name or name.startswith("#"):  # parser functions
            return ""
        named = [(str(p.name).strip(), self._param_value(p)) for p in t.params if p.showkey]
        positional = [self._param_value(p) for p in t.params if not p.showkey]
        if name.lower().startswith("infobox"):
            if self.infobox is None:
                self.infobox = name[len("infobox"):].strip() or name
            lines = [f"{k.replace('_', ' ')}: {v}" for k, v in named if v and not SKIP_KEY.match(k)]
            return "\n" + "\n".join(lines) + "\n" if lines else ""
        named = [(k, v) for k, v in named if v]
        if named:
            body = "; ".join(f"{k}={v}" for k, v in named)
            return f"\n{name}: {body}\n" if not inline else f"{name}: {body}"
        positional = [v for v in positional if v]
        if not positional:
            return ""  # navboxes, table heads/feet
        if inline:
            return " ".join(positional)
        long = [v for v in positional if len(v) > 40]
        return "\n" + "\n".join(long) + "\n" if long else ""

    def _node(self, n, nodes: list, i: int) -> str:
        from mwparserfromhell import nodes as N
        if isinstance(n, N.Text):
            return str(n)
        if isinstance(n, N.Comment):
            return ""
        if isinstance(n, N.HTMLEntity):
            return n.normalize()
        if isinstance(n, N.Wikilink):
            target = str(n.title).strip()
            ns = target.lstrip(":").split(":", 1)[0].lower() if ":" in target else ""
            if ns in ("file", "image", "media"):
                return ""
            if ns == "category":
                if not target.startswith(":"):
                    self.categories.append(target.split(":", 1)[1].split("|")[0].strip())
                    return ""
            text = self.render(n.text) if n.text is not None else target.lstrip(":").split("#")[0]
            return text
        if isinstance(n, N.ExternalLink):
            return self.render(n.title) if n.title is not None else ""
        if isinstance(n, N.Template):
            return self._template(n, _is_inline(nodes, i))
        if isinstance(n, N.Heading):
            return "\n" + _squash(self.render(n.title)) + "\n"
        if isinstance(n, N.Argument):
            return ""
        if isinstance(n, N.Tag):
            tag = str(n.tag).lower()
            if tag in ("ref", "references", "gallery", "nowiki", "math", "score", "templatedata", "mapframe"):
                return ""
            if tag == "br":
                return "\n"
            if tag in ("tr",):
                return "\n" + self.render(n.contents) if n.contents is not None else "\n"
            if tag in ("td", "th"):
                inner = _squash(self.render(n.contents)) if n.contents is not None else ""
                return (inner or "-") + " | "  # keep empty cells so columns stay aligned
            if tag == "li":
                return "- "
            if tag == "dt" or tag == "dd":
                return ""
            if n.contents is None:
                return ""
            inner = self.render(n.contents)
            if tag == "table":
                return "\n" + inner + "\n"
            if tag == "tabber":
                return "\n" + inner.replace("|-|", "\n") + "\n"
            return inner
        return ""


def _squash(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _clean(text: str) -> str:
    lines = []
    for line in text.splitlines():
        line = re.sub(r"[ \t]+", " ", line).strip()
        line = re.sub(r"(\s*\|\s*)+$", "", line)  # trailing cell separators
        line = re.sub(r"^\|\s*", "", line)
        if not line or re.fullmatch(r"[\W_]+", line) or re.fullmatch(r"\w+=", line):
            continue
        lines.append(line)
    out = "\n".join(lines)
    return re.sub(r"\n{3,}", "\n\n", out).strip()


def _chunks(text: str, limit: int = MAX_CHUNK) -> list[str]:
    if len(text) <= limit:
        return [text]
    out, cur = [], ""
    for para in text.split("\n"):
        while len(para) > limit:  # one huge line (a long table row)
            out.append((cur + "\n" + para[:limit]).strip()) if cur else out.append(para[:limit])
            cur, para = "", para[limit:]
        if len(cur) + len(para) + 1 > limit and cur:
            out.append(cur.strip())
            cur = ""
        cur += "\n" + para
    if cur.strip():
        out.append(cur.strip())
    return out


def convert(title: str, wikitext: str) -> dict:
    """{infobox, categories, sections: [{heading, anchor, level, text}]} for one page."""
    mw = _mw()
    code = mw.parse(wikitext)
    conv = Converter()
    sections, skip_level = [], None
    for sec in code.get_sections(flat=True, include_lead=True):
        heads = sec.filter_headings(recursive=False)
        head = heads[0] if heads and sec.nodes and sec.nodes[0] is heads[0] else None
        level = head.level if head is not None else 1
        heading = _squash(conv.render(head.title)) if head is not None else None
        if skip_level is not None and level > skip_level:
            continue
        skip_level = None
        if heading and heading.lower() in SKIP_SECTIONS:
            skip_level = level
            continue
        body = mw.parse("")
        body.nodes.extend(sec.nodes[1:] if head is not None else sec.nodes)
        text = _clean(conv.render(body))
        for j, chunk in enumerate(_chunks(text)):
            if chunk:
                sections.append({"heading": heading, "anchor": heading, "level": level, "part": j, "text": chunk})
    return {"infobox": conv.infobox, "categories": sorted(set(conv.categories)), "sections": sections}


# ------------------------------------------------------------------------------ API client


class Api:
    """Sequential, rate-limited, maxlag-aware MediaWiki API client."""

    def __init__(self, interval: float = 1.0, api: str = API, user_agent: str = USER_AGENT, log=print):
        self.interval, self.api, self.ua, self.log = max(1.0, interval), api, user_agent, log
        self._last = 0.0
        self.requests = 0

    def get(self, **params) -> dict:
        params = {"format": "json", "formatversion": "2", "maxlag": "5", **params}
        url = self.api + "?" + urllib.parse.urlencode(params)
        for attempt in range(6):
            wait = self._last + self.interval - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            self._last = time.monotonic()
            self.requests += 1
            req = urllib.request.Request(url, headers={"User-Agent": self.ua, "Accept-Encoding": "gzip"})
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    raw = resp.read()
                    if resp.headers.get("Content-Encoding") == "gzip":
                        raw = gzip.decompress(raw)
                    retry_after = resp.headers.get("Retry-After")
                data = json.loads(raw.decode("utf-8"))
            except urllib.error.HTTPError as exc:
                if exc.code in (429, 500, 502, 503, 504):
                    delay = float(exc.headers.get("Retry-After") or 5 * 2 ** attempt)
                    self.log(f"  HTTP {exc.code}; backing off {delay:.0f}s")
                    time.sleep(delay)
                    continue
                raise
            err = data.get("error") or {}
            if err.get("code") == "maxlag":
                delay = float(retry_after or 5)
                self.log(f"  server lagged ({err.get('lag')}s); waiting {delay:.0f}s")
                time.sleep(delay)
                continue
            if err:
                raise RuntimeError(f"API error {err.get('code')}: {err.get('info')}")
            return data
        raise RuntimeError("API: gave up after repeated back-off")

    def query_all(self, **params):
        """Yield each ``query`` block, following ``continue``."""
        cont: dict = {}
        while True:
            data = self.get(action="query", **params, **cont)
            if "query" in data:
                yield data["query"]
            if "continue" not in data:
                return
            cont = data["continue"]


def list_pages(api: Api) -> dict[str, dict]:
    """Namespace-0 articles (no redirects): title -> {pageid, revid}."""
    out = {}
    for q in api.query_all(generator="allpages", gapnamespace="0", gapfilterredir="nonredirects",
                           gaplimit="max", prop="info"):
        for p in q.get("pages", []):
            out[p["title"]] = {"pageid": p["pageid"], "revid": p.get("lastrevid")}
    return out


def list_redirects(api: Api) -> dict[str, str]:
    """Namespace-0 redirect title -> target title (aliases for the index)."""
    out = {}
    for q in api.query_all(generator="allpages", gapnamespace="0", gapfilterredir="redirects",
                           gaplimit="max", redirects="1", prop="info"):
        for r in q.get("redirects", []):
            out[r["from"]] = r["to"]
    return out


def fetch_content(api: Api, pageids: list[int]):
    """Yield (page dict) with the current revision's wikitext, 50 pages per request."""
    for i in range(0, len(pageids), BATCH):
        batch = "|".join(str(p) for p in pageids[i:i + BATCH])
        for q in api.query_all(pageids=batch, prop="revisions", rvprop="ids|timestamp|content", rvslots="main"):
            for p in q.get("pages", []):
                revs = p.get("revisions") or []
                if revs and "content" in (revs[0].get("slots", {}).get("main") or {}):
                    yield p


# ------------------------------------------------------------------------------ mirror


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def load_manifest(root: Path) -> dict:
    f = root / "manifest.json"
    if f.exists():
        return json.loads(f.read_text(encoding="utf-8"))
    return {"pages": {}, "redirects": {}}


def page_record(p: dict, fetched_at: str) -> dict:
    rev = p["revisions"][0]
    text = rev["slots"]["main"]["content"]
    return {"schema": SCHEMA, "title": p["title"], "pageid": p["pageid"], "revid": rev.get("revid"),
            "timestamp": rev.get("timestamp"), "fetched_at": fetched_at, "url": page_url(p["title"]),
            "licence": LICENCE, **convert(p["title"], text), "wikitext": text}


def mirror(root: Path, api: Api, full: bool = False, titles: list[str] | None = None,
           limit: int | None = None, log=print) -> dict:
    root.mkdir(parents=True, exist_ok=True)
    (root / "pages").mkdir(exist_ok=True)
    man = load_manifest(root)
    pages = man.setdefault("pages", {})
    if titles:
        data = api.get(action="query", titles="|".join(titles), prop="info", redirects="1")
        wanted = {p["title"]: {"pageid": p["pageid"], "revid": p.get("lastrevid")}
                  for p in data["query"].get("pages", []) if "pageid" in p}
        live = None
    else:
        log("listing pages ...")
        live = list_pages(api)
        wanted = live
        log(f"  {len(live)} articles")
        log("listing redirects ...")
        man["redirects"] = list_redirects(api)
        log(f"  {len(man['redirects'])} redirects")
    todo = [t for t, info in wanted.items()
            if full or titles or t not in pages or pages[t].get("revid") != info["revid"]]
    if limit:
        todo = todo[:limit]
    log(f"fetching {len(todo)} page(s) ...")
    done = 0
    for p in fetch_content(api, [wanted[t]["pageid"] for t in todo]):
        rec = page_record(p, _now())
        f = f"pages/{rec['pageid']}.json"
        _write_json(root / f, rec)
        pages[rec["title"]] = {"pageid": rec["pageid"], "revid": rec["revid"], "fetched_at": rec["fetched_at"],
                               "file": f}
        done += 1
        if done % 200 == 0:
            log(f"  {done}/{len(todo)}")
    removed = []
    if live is not None and not limit:  # pages deleted or turned into redirects since the last run
        for t in [t for t in pages if t not in live]:
            (root / pages[t]["file"]).unlink(missing_ok=True)
            removed.append(t)
            del pages[t]
    man.update({"site": SITE, "api": API, "licence": LICENCE, "user_agent": api.ua, "updated_at": _now()})
    _write_json(root / "manifest.json", man)
    log(f"done: {done} fetched, {len(removed)} removed, {len(pages)} pages, {api.requests} API requests")
    return {"fetched": done, "removed": removed, "pages": len(pages), "requests": api.requests}


def reconvert(root: Path, log=print) -> int:
    n = 0
    for f in sorted((root / "pages").glob("*.json")):
        rec = json.loads(f.read_text(encoding="utf-8"))
        rec.update(convert(rec["title"], rec["wikitext"]))
        _write_json(f, rec)
        n += 1
    log(f"reconverted {n} pages")
    return n


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dir", type=Path, default=None, help="mirror directory (default data/wiki, or DW_WIKI_DIR)")
    ap.add_argument("--full", action="store_true", help="refetch every page, not only changed ones")
    ap.add_argument("--titles", help="only these titles, '|'-separated")
    ap.add_argument("--limit", type=int, help="at most N pages (testing)")
    ap.add_argument("--interval", type=float, default=1.0, help="seconds between requests (min 1)")
    ap.add_argument("--reconvert", action="store_true", help="re-run the text conversion offline, no network")
    ap.add_argument("--no-index", action="store_true", help="skip rebuilding the knowledge index")
    a = ap.parse_args(argv)
    root = a.dir or wiki_dir()
    if a.reconvert:
        reconvert(root)
    else:
        mirror(root, Api(a.interval), full=a.full, titles=a.titles.split("|") if a.titles else None, limit=a.limit)
    if not a.no_index:
        sys.path.insert(0, str(REPO_ROOT))
        from brain.knowledge import Knowledge
        k = Knowledge(wiki=root, rebuild=True)
        print("knowledge index:", k.stats())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

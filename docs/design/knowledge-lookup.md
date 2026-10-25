# Design note: game knowledge for the brain (`lookup` + local wiki mirror), 2026-10-25

Template: `docs/design/PRINCIPLES.md`. Earlier recommendation: `docs/research/2026-10-25-scalable-agent-frameworks.md` section 4, design `robustness-and-item-catalog.md` sections 18-19.

- **Goal (what Luis sees):** ask Claude "what does a pumpkin spice infusion do?", "how do I make an iron bar?", "where do I find oak trees?" and get a short, correct answer drawn from game data first and the wiki second, instead of a guess. The Controller decides for itself when to look something up.

- **Approach (layers and files):**
  - `tools/wiki_mirror.py` (new) is an offline refresh script.
    - It reads pages through the official MediaWiki Action API (`api.php`), sequentially, with at least 1 s between requests, `maxlag=5` with Retry-After back-off, and a descriptive User-Agent with contact details.
    - It enumerates namespace 0 with `generator=allpages&prop=info` (lastrevid), resolves redirects into aliases, and fetches wikitext 50 titles per request. That is about 100 requests for the whole wiki.
    - Refreshes are incremental by revid.
    - It converts wikitext to clean text with **mwparserfromhell**:
      - Infobox templates become `key: value` lines.
      - Other named-parameter templates (e.g. Recipe, DropsLine) become a compact `k=v` line.
      - Navboxes and short positional templates are dropped; inline link templates keep their text.
      - Tables become one ` | ` line per row.
      - Refs, files, comments, and the "Update history"/"References"/"Gallery"/"Journal" sections are dropped.
    - Output goes to `data/wiki/` (gitignored): `pages/<pageid>.json` (raw wikitext and converted sections) and `manifest.json` (page → pageid, revid, fetched_at, plus the site, licence and redirects).
  - `brain/knowledge.py` (new) is a SQLite **FTS5** index (`porter unicode61` stemming, BM25 with the title weighted).
    - **Game docs** are generated from `data/items_*.json`, `data/recipes_*.json` (items, recipes, stations) and `data/spells_*.json` (spells, perks). They are labelled `authoritative: true`, with source `game:<build>`.
    - **Wiki docs** are one chunk per section, prefixed with the page title, with source `wiki` and a page URL with a section anchor.
    - Game results always rank before wiki results.
    - The index is cached at `data/wiki/knowledge.sqlite` and rebuilt when any source file's size or mtime changes. With no mirror it is game-only and in memory.
  - `brain/interface.py`: the new `lookup {query, kind?}` tool goes into `READ_TOOLS` (read-only, non-interrupting) and `BRAIN_TOOLS` (never sent to the body).
  - `brain/controller.py`:
    - `_read` answers `lookup` from `Knowledge`, and the tool is offered only when a Knowledge index exists.
    - The persona gets one line: "use lookup when unsure about a game fact; game data beats wiki."
  - Wiring is in `run_live.py`/`agent.py`. There are offline tests, plus a tiny real-model eval (5 Haiku calls).

- **Precedent (reuse):**
  - PUBG Ally has a knowledge-lookup tool over a curated dictionary, and "tool results are the only ground truth".
  - Mindcraft's `!searchWiki`, GITM's wiki-plus-recipe retrieval and MineDojo's wiki KB (research section 1).
  - SQLite FTS5 BM25 is already used by `brain/skill_library.py`.
  - mwparserfromhell (MIT) is the standard wikitext parser.
  - The MediaWiki API etiquette (serial requests, maxlag, User-Agent) and Weird Gloop's Help:APIs ("set a User-Agent that describes what you're using it for"; no explicit rate limit) apply.
  - **Built:** only the glue (template-to-text rules, doc generation from our catalogs).

- **Generality check:**
  - No item, creature or place names in code. Every doc is generated from the catalogs and the wiki, so a new patch or a new wiki page is covered by re-running the generators.
  - Template handling is structural (infobox, named or positional parameters), not per template name.
  - The section skip list ("Update history", "References", ...) is wiki-structure config, not game facts.
  - The `kind` filter values come from the data (doc kinds and wiki infobox types), and the tool description lists them from the index.

- **Principles touched:**
  - 2: the model decides when to look up. There are no keyword triggers.
  - 3: no fact lists in code.
  - 5: knowledge is *information*, never state. Wiki text is labelled non-authoritative.
  - **One tension for Luis:** the wiki's `robots.txt` has `Disallow: /*api.php` for `User-Agent: *`.
    - That is a crawler directive. Weird Gloop's own API page invites API clients that set a descriptive UA, and the project already used the Bucket API for recipe checks.
    - The API mirror is about 100 requests in total, versus about 3,900 HTML page loads for a robots-compliant HTML crawl. It is far lighter on their servers.
    - I proceed with the API at ≤1 req/s and flag it. If Luis prefers, ask on the wiki Discord #api-discussion.
  - **Decision on bulk access (main approved, 2026-10-25): use the API.**
    - Checked first for official dumps or a documented bulk export:
      - Weird Gloop publishes no dump files. A search of meta.weirdgloop.org, runescape.wiki and the Dragonwilds wiki found none, and there is no `Meta:Database dumps` page.
      - The only documented bulk path is **Special:Export**. The wiki's own `Dragonwilds:AutoWikiBrowser` page says "Database dumps can be downloaded using Special:Export". It is equally covered by robots.txt (`Disallow: /w/Special:`).
    - The Action API is therefore used exactly as Help:APIs invites:
      - a descriptive UA with contact;
      - sequential requests, ≥1 s apart;
      - `maxlag=5`;
      - incremental by revid.
    - It returns the same wikitext as Special:Export, with revids for incremental refresh.
    - Sources:
      - https://runescape.wiki/w/Help:APIs
      - https://dragonwilds.runescape.wiki/robots.txt
      - https://dragonwilds.runescape.wiki/w/Dragonwilds:AutoWikiBrowser
      - https://www.mediawiki.org/wiki/Manual:Maxlag_parameter
      - https://meta.weirdgloop.org/w/Meta:Copyrights
  - **Licence:** CC BY-NC-SA 3.0. The mirror stays local (gitignored), each snippet carries its page URL (attribution), and nothing is published.

- **Acceptance test:**
  - Offline:
    - The converter runs on fixture wikitext (infobox, Recipe, DropsLine, tables, refs).
    - The index ranks game data first.
    - `lookup` returns sourced snippets, is a READ tool (no interrupt, turn continues), and is offered only with a Knowledge index.
    - The principle guard tests still pass.
  - Real model:
    - 3 held-out questions → Haiku calls `lookup`, then answers with the right fact (Soul Food heal over time; 3 Iron Ore at a Furnace; Brynmoor/Ghornfell/Fellhollow).
    - About 5-6 calls.
  - Live: not needed, since this is a brain-only read tool. Main restarts the brain.

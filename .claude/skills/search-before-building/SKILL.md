---
name: search-before-building
description: >-
  Before writing ANY new code, script, tool, mod logic, brain logic, ops plumbing, fix or workaround in
  the Dragonwilds companion project, first web-search whether it has already been solved, what the
  idiomatic practice is, and what the docs say, then choose reuse > adapt > build and record the
  decision with sources. Use this whenever you are about to implement something new, pick a library,
  hit a crash, hang or engine limitation, see unfamiliar UE5/UE4SS/Windows behaviour, write a helper
  that feels generic, or brief a subagent to build something — even if the task seems small or you
  think you already know the answer. Skip it only for trivial edits to code that already exists.
---

# Search before building

Luis's standing rule for this project: *don't hand-roll what already exists; somebody has very likely
hit the same or a similar problem, or the answer is documented.* Searching first is cheap. Building
the wrong thing, or a worse copy of an existing tool, costs hours and leaves maintenance behind.
CLAUDE.md section 0 ("Building principles") makes this binding.

## When it applies

Run it before you:
- write a new module, script, tool, service, parser, loop, supervisor, logger or similar;
- add a dependency or choose between libraries;
- work around a crash, hang, freeze or "it silently does nothing" behaviour;
- reverse-engineer an engine mechanic (replication, AI, UI, inventory, damage, chat);
- write a subagent brief that asks it to build something.

Skip it for trivial edits inside existing code, or when the answer is already recorded in
`docs/DISCOVERIES.md` or `docs/research/` (check there first: it's the cheapest search of all).

## The three questions (answer all three, briefly)

1. **Has this been done?** Existing OSS projects, mods, libraries, managed tools or Windows built-ins that
   solve this exact or a similar problem.
2. **What is the idiomatic way?** The established pattern or paradigm for this class of problem: how
   Unreal, UE4SS mods, game-AI or ops people normally do it.
3. **What do the docs and source say?** The API or engine behaviour, from primary sources (official
   docs, source code, issue trackers) rather than guesses.

## Search checklist

Start with the repo: grep `docs/DISCOVERIES.md`, `docs/research/` and `docs/ARCHITECTURE.md`. Then
search the web. Run several queries at once, varying the phrasing, and prefer primary sources.

| Problem area | Query patterns and places |
|---|---|
| UE4SS / Lua modding | `"<thing>" UE4SS`, UE4SS docs (docs.ue4ss.com), UE4SS GitHub source, issues and discussions, Nexus mods for UE5 games with server-side Lua (Palworld, Motor Town, Abiotic Factor) |
| Unreal Engine behaviour | `"<symptom>" Unreal Engine 5`, `site:forums.unrealengine.com`, `site:issues.unrealengine.com`, Epic docs, Lyra/ShooterGame patterns |
| Dragonwilds specifics | Nexus Dragonwilds mods, GitHub (e.g. RSE-Server), runescape.wiki (Dragonwilds), hosting-provider knowledge bases, the dump in `dumps/<build>/` |
| Game AI / companion design | `behavior tree utility AI <topic>`, mineflayer and Mindcraft plugins, LLM game-agent papers (arXiv), the PUBG Ally / PIANO / GITM prior art in CLAUDE.md section 10 |
| Windows ops | `"<task>" Windows Server`, built-ins first (Task Scheduler, logman, services), then standard tools (NSSM, WinSW, Sysinternals) |
| Python / Lua libraries | PyPI or LuaRocks plus GitHub activity and licence; prefer maintained, permissive and small |

If the first pass is thin or off-target, use the `extended` search mode, or fetch the primary page
or source file. A web search that returns "nothing relevant" is still a finding: say so.

## Decide: reuse > adapt > build

- **Reuse / adopt** an existing tool or library when it fits; vendor it with its licence when needed (see `mod/body/vendor/`).
- **Adapt** a known pattern or snippet, citing where it came from.
- **Build** only when nothing fits. When you do, design it as a shared service or data profile so
  the next capability is cheaper (CLAUDE.md section 0, principle 2).

## Record the decision

Add a short entry where it will be found again: `docs/DISCOVERIES.md` for verified engine facts, the
relevant `docs/research/*.md` or design doc for choices. Template:

```markdown
### <Decision title> (YYYY-MM-DD)
- Need: <one line>
- Searched: <queries / places>
- Found: <existing tools/patterns/docs, with links>
- Decision: reuse | adapt | build. <what and why>
- Sources: <URLs>
```

## In subagent briefs

Subagents don't see this conversation, so put the rule in the brief explicitly:

> Before building anything, web-search for existing solutions, the idiomatic practice and the
> relevant docs (UE4SS docs/source, UE forums and issues, Nexus/GitHub, PyPI/LuaRocks). Prefer
> reuse > adapt > build. Cite the sources you relied on in your report, and say explicitly when a
> search found nothing.

## Examples from this project

- **Done well:**
  - The UE4SS dwmapi proxy hung the server. Searching led to the UE4SS source (the proxy is built from `dwmapi`) and to **Ultimate ASI Loader**, a standard universal proxy, instead of writing our own loader.
  - JSON with null and `{}` support: **dkjson** instead of patching rxi.
  - Behaviour trees: vendored **beehive.lua**.
  - The nameplate: UE forum threads plus push-model issue reports gave the diagnostic steps.
- **Missed:**
  - The watchdog keep-alive was hand-written before checking **NSSM / WinSW** (standard Windows service supervisors).
  - An early JSON encoder was hand-rolled before the library search.

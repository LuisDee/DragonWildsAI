# North Star: principles every design must satisfy

Every agent brief references this page. Every build starts with a design note that is checked against it.
These come from Luis's decisions (CLAUDE.md section 0). Breaking one needs Luis's explicit OK.

## Principles
1. **Real player paths only.**
   - Claude is a real game client. Act through the game's own client paths: UI handlers, Enhanced Input actions, character input calls.
   - Never emulate outcomes: no writing health, inventory, damage or crafting results.
   - Never call server RPC implementations directly. Never grant items.
2. **The model infers; we don't map.**
   - No phrase→skill tables or keyword rules.
   - The brain gets a truthful tool list (generated from the body's capabilities), honest perception and recent context, and decides.
   - Fix missing tools, perception or context; never add special cases.
   - **Code never overrides the model's interpretation or decisions** (no vetoes, no "you said X so I refuse" checks). Code may only (a) give the model information (perception, context, candidate matches), (b) report outcomes truthfully, (c) enforce Luis's explicit safety rules (e.g. never attack players). If unsure, the model asks the player.
3. **Generic, never hard-coded.**
   - No item, creature, place or recipe lists in code.
   - Use game data (reflection, data assets, catalogs) and data profiles. Learned facts (routes, traps, links, skills) are per-world data.
4. **Two speeds.**
   - The LLM chooses and parameterises skills on events, never at tick speed.
   - Deterministic layers (reflexes, movement, combat) run at frame rate and report verified results.
5. **Verified state only.** A step is done when the game state confirms it; the model's claims are never state.
6. **Search for precedent first.** Reuse > adapt > build, with sources (the search-before-building skill).
7. **Communication is paramount.** Every failure surfaces one specific, truthful reason that Claude says in chat. Persistent behaviours never end silently.
8. **Remember what worked.** Routes, traps, jump links and skills are learned once and reused, per world.
9. **One owner per resource.**
   - The pawn goes through the arbiter. Files have one owning agent.
   - Main integrates and commits. Live tests run one at a time.
10. **Test where it's safe.**
    - Offline tests first, then the dev-server scenario suite, then a short live check with Luis.
    - Every live bug becomes a regression test.

## Anti-patterns (the tests in tests/test_principles.py fail on these)
- Code that vetoes or rewrites the model's chosen tool/args based on the player's wording ("grounding vetoes").
- Phrase/keyword→tool tables in brain/ (e.g. dicts of utterances, `if "get your stuff" in text`).
- Hard-coded item, creature or place names in client_mod/scripts movement, skills or brain logic. Data files and tests are exempt.
- Client-mod calls to `Server_*` functions, or writes to Health/Inventory/Damage properties.
- Emulated outcomes or "fallback" fakes that make a test pass.

## Design note template (half a page, before code)
- **Goal:** what Luis will see.
- **Approach:** layers and files touched.
- **Precedent:** how others do it, with links. Name what you reuse.
- **Generality check:** would the next item, phrase, area or enemy need special-casing? If yes → wrong layer; redesign.
- **Principles touched:** any bent? Why? Needs Luis's OK?
- **Acceptance test:** offline, scenario and live, with held-out cases for generalisation.

## Review gate
- A **reviewer agent with fresh context** reviews each design note against this page before implementation, and does a cold review of the code at the end of each wave.
- Main sends Luis a one-line "Plan: X; precedent: Y" before any change in behaviour he would notice.

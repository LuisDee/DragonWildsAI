# Scalable perception, reasoning and tool use: prior art and the recommended brain (2026-10-25)

**Question (Luis):** "We want Haiku to do the thinking and use the appropriate tool calls to achieve it. It must be scalable: it must see what is around it, know what an item is, and work out how to reach the goal with its available tools." There must be no hand-coded per-item or per-task logic.

**Failure that prompted this:** "claude pick up the sticks". Sticks are ground gatherables (`BP_Spawner_AshBranch_*`, `BaseInteractableResource`), and they are foliage until converted, so they never appeared in `nearby_items`. Haiku picked up the only item it could see (DISCOVERIES, "item-substitution bug").

**Added later by Luis:**
- (1) A knowledge base: a mirror of the Dragonwilds wiki behind a `lookup` / `how_to` tool, with game data primary.
- (2) Crafting across several stations and multi-step recipes, where an item can be obtained in several ways.

Build ID for every game fact below: **26161880**. Facts marked *(wiki)* come from the community wiki and have not been checked against game data.

---

## 0. Recommendation in one page

1. **Perceive through the game's own data, not hand-written lists.**
   - A body tool, **`look`**, takes a census of every actor near the bot that is a world actor, world item, interactable, creature, player or station. It converts foliage first, so sticks and stones appear.
   - Each thing is described by game data: `AWorldActor.DisplayName`, what it gives (`ABaseInteractableResource.ItemData`, `UItemDropComponent`), its state, the distance, and the **actions it affords**.
   - **`inspect(target)`** gives details for one thing.
   - The Controller always gets a ≤10-line `surroundings` digest built from the same census, so common commands still take one model call.
2. **Affordances come from components, never from item names.**
   - `UInteractionComponent` supplies the interact action and its prompt text (`InteractionPrompt`, `SecondaryInteractionPrompt`, `GetInteractionPrompt(Player)`).
   - A world item affords pickup. A destructible with a tool gate affords gather. A hostile AI affords attack. `UCraftingStationComponent.ValidRecipes` affords craft. A player affords follow and give.
   - This is the game industry's "smart object" pattern: objects advertise what can be done with them, so new content works without the agent knowing about it in advance.
3. **Knowledge is a tool, game data first.**
   - `lookup(name)` returns a short card per thing: what it is, its game ids, the ways to obtain it, its uses and where it is found.
   - The card merges the generated catalogs (items, spells, enemies, **recipes**, **world objects**) with a **local mirror of the Dragonwilds wiki**: the MediaWiki API plus the wiki's structured `Bucket` tables (`recipe`, `dropsline`, `infobox_item`).
   - Retrieval is SQLite FTS5 (BM25), with embeddings optional later.
   - A deterministic **name resolver** maps player words ("sticks", "oak") to game ids, or answers "I can't see/know X" with suggestions.
4. **Crafting and "how do I get X" is deterministic search over a recipe graph, not LLM arithmetic.**
   - A cost-ranked backward chainer (`brain/recipes.py`) tries, in order: inventory → items on the ground nearby → gather → loot → sub-craft at the required station (stations need to be present; recipes need to be unlocked).
   - It outputs an ordinary task list that the existing executor verifies step by step.
   - Sonnet chooses between options and handles what the chainer can't (Plan4MC: "the LLM builds the graph, search plans").
5. **A Voyager/GITM-style skill library, stored as data, not code.**
   - When a goal is completed and **verified from game state**, Sonnet generalises the task list into a named, parameterised skill with preconditions and a postcondition.
   - Skills are retrieved by similarity (top 3 in the Controller context). Haiku runs a matching skill with `run_skill(name, params)` without involving Sonnet.
   - Success and failure counts, plus measured costs, are kept per skill and feed back into the chainer.
6. **Haiku thinks, Sonnet plans.**
   - The Controller (Haiku) becomes a **bounded ReAct loop**: at most 3 model calls per command. Read-only tools (`look`, `inspect`, `lookup`) don't end the turn; the first action tool commits; speech comes last.
   - Haiku escalates with `start_goal` when no skill matches or a step fails.
   - Sonnet plans, replans (DEPS), and writes skill entries.
7. **Keep our harness and add components.**
   - No agent framework provides event-driven interrupts, state-verified steps and a single voice, which is where our value lies.
   - Adopt: the official **MCP Python SDK** for a dev and ops facade over `GameInterface` (Claude Code or the Agent SDK can drive the bot), kept off the live hot path; **SQLite FTS5** for retrieval (built in); and the documented wiki API.
   - Build small: the resolver, the chainer, the skill store.
8. **Context and cost.**
   - Use stable cached prefixes (persona plus tool schemas), a bounded per-call context, no transcripts, and ≤14 tools.
   - Tool search and programmatic tool calling are not needed yet: both make sense above ~10 tools or ~10K tokens of definitions. Revisit if the tool count grows.
   - About $0.001 per Haiku command, and about $0.02 per Sonnet plan.

---

## 1. Why the current brain fails, in one paragraph

The Controller sees a raw `get_state`: entities, `nearby_items` and a few puppet internals. It gets one shot to pick one action. Three things are missing:
- **Perception:** ground gatherables, trees, rocks and stations are invisible (only world items and creatures are exported).
- **Knowledge:** Dragonwilds (early access in 2025) is almost absent from model pretraining, so the model cannot know that "sticks" are a gatherable, or what an "Iron Logging Axe" needs.
- **A way to look before acting:** there is a single call and no read-only tools.

The Minecraft agents below succeed largely because the model already knows Minecraft:
- Voyager says GPT-3.5 "already knows much of Minecraft".
- JARVIS-1 found that LLaMA-2-70B without Minecraft knowledge performed poorly.
- Odyssey fine-tuned LLaMA-3 on 390K wiki Q&A entries.

**We have to supply that knowledge as tools and data.** That is the central design consequence.

---

## 2. Comparison of existing systems

| System | Perception | Action space | Knowledge | Memory / skills | Model, latency | What worked | What failed / limits |
|---|---|---|---|---|---|---|---|
| **Mindcraft** (mineflayer) [1][2] | Text query commands: `!stats`, `!inventory`, `!nearbyBlocks`, `!entities`, `!craftable`, `!savedPlaces`, `!getCraftingPlan` | ~41 `!action` commands with typed params (`!collectBlocks type num`, `!craftRecipe`, `!searchForBlock`, `!goToPlayer`, `!useOn`); `!newAction` writes JS (off by default: "Do not connect this bot to public servers with coding enabled") | Model pretraining; `!searchWiki` scrapes minecraft.wiki; `getDetailedCraftingPlan` from minecraft-data | Summarised memory ≤500 chars; named places (`memory_bank`); embedding-selected examples (`select_num`=2) and skill docs; always-on "modes" (self_defense, unstuck, item_collecting) | Any provider; one command per turn | Broad command coverage; modes as reflexes; typed param validation (`Invalid item type: X`, no suggestions) | MineCollab: performance drops up to 15% when agents must communicate detailed plans; communication is "the primary bottleneck" [3]. Crafting planner uses only the first recipe and ignores tables and smelting [2] |
| **Voyager** [4] | Text state (inventory, equipment, nearby blocks and entities, biome, health, position), added gradually during a warm-up | **Code**: JS against mineflayer plus control primitives | GPT-4 pretraining; optional wiki retrieval for the curriculum | **Skill library**: key = embedding of the skill's description, value = code; top-5 retrieval by query (task + env feedback); skills compose | GPT-4 (code), GPT-3.5 (descriptions); up to 4 iterations per task | 3.3× more unique items; tech tree up to 15.3× faster; zero-shot generalisation using the library | Without self-verification −73% items (the most important feedback); hallucinated items ("copper sword"), invalid API calls; cost (GPT-4 ≈15× GPT-3.5); text-only perception |
| **GITM** [5] | LiDAR rays plus a voxel map (no RGB); feedback after every action | 9 structured actions (`equip, explore, approach, mine/attack, dig_down, go_up, build, craft/smelt, apply`), each a **hand-written script** | Decomposer retrieves **wiki text and recipes** with sentence embeddings; goal → (object, count, material, tool, info) sub-goal tree | **Text memory**: sub-goal → list of successful action sequences; after N=5, an LLM summarises them into one reference plan | GPT-3.5; CPU only (32 cores) | Unlocked all 262 Overworld items; ObtainDiamond 67.5% (VPT 20%, DEPS 0.6%); memory: iron pickaxe 57.5→95%, diamond 35→67.5% | Relies on scripted interfaces per action; recipe knowledge from the wiki must be accurate |
| **JARVIS-1** [6] | Vision (MineCLIP / CLIP) plus symbols | Goal-conditioned controller (STEVE-1) | Pretrained LLM; backward reasoning to sub-goals | **Multimodal memory**: (task, state, plan); filtered by text similarity, ranked by visual similarity to the current state; top-k plans in context. **Self-check** (simulate the plan, predict inventory) and **self-explain** (on failure) | GPT-class planner | 200+ tasks; short tasks 89–94%; diamond pickaxe 6.22% (VPT 2.5%) | The low-level controller is the bottleneck; needs a strong LLM (LLaMA-2-70B weak without Minecraft knowledge) |
| **Odyssey** [7] | As Voyager | Code over **40 primitive + 183 compositional** skills | LLaMA-3 fine-tuned on 390K+ wiki Q&A | Skill library | Open model | Broader open-world tasks; public datasets and weights | Fine-tuning a domain model is costly; not needed with tool-based knowledge |
| **MineDojo** [8] | Pixels | Keyboard and mouse | Internet knowledge base: 730K YouTube videos, ~7K wiki pages, 340K Reddit posts | — | RL + MineCLIP reward | Benchmark and knowledge base | RL-scale compute; not an LLM tool-use design |
| **Plan4MC** [9] | Pixels (RL skills) | 3 skill types: Finding, Manipulation, Crafting (one action) | **LLM-generated skill graph** (`consume`, `require`, `equip`, `obtain` with quantities), checked against the game DB (6 errors in 55 corrected) | — | GPT-3.5 used only offline | **DFS backward from the goal** over the graph, tracking held items; replans after every skill. 40 tasks, many with >10 skills | RL skills are weak at finding; "LLM only builds the graph" to avoid run-time LLM errors |
| **DEPS** [10] | Text feedback | LLM plan over controller goals | Pretraining | — | GPT-class | **Describe → Explain → Plan → Select** (a goal selector ranks parallel sub-goals by steps to completion); 70+ tasks, performance nearly doubled | Needs a trained selector; explanation quality limits it |
| **DECKARD** [11] | Pixels | RL subgoal policies | LLM-hypothesised abstract world model (subgoal graph) | Corrected by experience ("Wake" phase) | Few-shot LLM | Order-of-magnitude sample efficiency; robust to LLM errors because hypotheses are verified | RL training needed |
| **Cradle** (GCC) [12] | Screenshots only (GPT-4o plus Grounding DINO / SAM) | Keyboard and mouse via generated code "skills" | In-game tutorials | Episodic (last 5 interactions plus a summary) and procedural (skills, retrieved by `text-embedding-ada-002` cosine, top-K) | GPT-4o; the game is **paused** during calls | RDR2 missions; Stardew farming; Cities: Skylines | Poor spatial perception, circles aimlessly; real-time combat weak (20% on one mission); cost and latency |
| **SIMA 2** (DeepMind) [13] | 720p pixels, "no privileged information" | 96 keys, clicks, discretised mouse | Gemini | Self-improvement: Gemini task setter plus reward model | **Flash-Lite "due to the latency constraints of embodied action"**; Pro gives instructions every k steps | ≈2× SIMA 1; generalises to unseen games (ASKA, MineDojo) | "Very long-horizon, complex tasks", short memory, precise control |
| **PUBG Ally** (KRAFTON + NVIDIA ACE) [14] | **Observation tools** return plain-text state on demand ("You are armed with M416, 24/30 bullets") | Speech plus game actions handed to a **behaviour tree** (System 1) | **Knowledge-lookup tool** over a curated dictionary of weapons, items and rules; "tool results are the only ground truth"; the model is taught to re-observe rather than recall | Long-term player profile plus match history; short-term match memory | 2B on-device SLM; prompt structured for KV-cache reuse | Event-driven; reflexes never wait on the model | Players reported hesitation, delayed prompts, unfinished tasks, inconsistent memory (CLAUDE.md section 10) |
| **Project Sid / PIANO** [15] | Text | Minecraft skills | — | Shared agent state; 10 concurrent modules; **Cognitive Controller bottleneck**; **Action Awareness** compares expected and observed outcomes | Reflexes are small non-LLM nets | Coherent speech and action; 10–1000+ agents | "Stuck in repetitive patterns", compounding hallucinations; lack of vision and spatial reasoning is "the primary challenge" |
| **minecraft-mcp-server** [16] | MCP tools: `get-position`, `find-blocks`, `find-entity`, `list-inventory`, `read-chat` | MCP tools: `move-to-position`, `dig-block`, `place-block`, `equip-item`, `smelt-item`, `send-chat` | Model pretraining | None | Claude Desktop | Any MCP client can drive a bot | Thin wrappers, no verification, no reflexes, no memory |
| **ReAct / CodeAct** [17][18] | — | ReAct: interleaved thought → tool → observation. CodeAct: Python code as the unified action space | — | — | — | CodeAct: up to 20% higher success than JSON/text actions (17 LLMs) | Code actions need a sandbox; crash and security risk in our setting |
| **Agent Workflow Memory** [19] | Web | Web actions | — | Induces reusable **workflows** (description plus steps) from successful trajectories; offline or online | GPT-4 | +24.6% relative (Mind2Web), +51.1% (WebArena) | Evaluator quality gates what gets stored |

### Lessons that shape our design

- **L1. Structured game-state queries beat pixels for a server-side agent.** Every strong text agent perceives through APIs (Mindcraft, Voyager, GITM, PUBG Ally). The pixel agents (Cradle, SIMA 2) are slower and weakest at spatial precision. We have reflection, so we query.
- **L2. Name grounding must be supplied.** Minecraft agents get names for free from pretraining plus validation against `minecraft-data`. Mindcraft does not even suggest corrections. For Dragonwilds we need a catalog-backed resolver and a lookup tool, as PUBG Ally's curated dictionary is. "Tool results are the only ground truth" is exactly the rule our substitution bug broke.
- **L3. The LLM chooses parameterised, hand-written skills** (GITM, Mindcraft, PUBG Ally, Plan4MC). Code-as-action (Voyager, CodeAct, Odyssey) buys composability. In our setting generated code would mean native crash risk (R1–R15) and a security surface (Mindcraft ships it disabled). **We take the composability, not the code:** skills are declarative step lists over verified primitives.
- **L4. Verification is the most valuable feedback.** Voyager loses 73% without self-verification, and PIANO's Action Awareness and JARVIS-1's self-check point the same way. Our executor already verifies from game state, deterministically, which is better than an LLM critic. Skills are saved **only** after state-verified success.
- **L5. Memory of what worked has large measured effects**: GITM (+37.5 points on iron pickaxe), AWM (+24.6% and +51.1%), Voyager (plateaus without its library). The skill library is worth building.
- **L6. Retrieval keys are short descriptions and K is small**: Voyager top-5, Mindcraft 2, Cradle top-K, JARVIS-1 task plus state.
- **L7. Dependency planning is search, not generation.** Plan4MC: the LLM builds the graph and DFS plans over it. Mindcraft and GITM use recipe data. We extract the graph from game data, so the search is fully deterministic and the LLM only chooses between options and handles exceptions.
- **L8. Fast and slow split, with the fast model small** (PUBG Ally 2B, SIMA 2 Flash-Lite, PIANO non-LLM reflexes). This matches CLAUDE.md principle 1: Haiku plus the Lua behaviour tree.
- **L9. Design against these failure modes:**
  - loops and compounding hallucination (PIANO);
  - hesitation and unfinished tasks (PUBG Ally);
  - aimless circling (Cradle);
  - invented items (Voyager);
  - plan chatter (MineCollab).

  Mitigations: hard caps, verified state, "I can't see X" instead of guessing, and short speech.
- **L10. Tool design:**
  - Few consolidated tools, high-signal outputs with natural names, actionable errors (Anthropic [20]).
  - Selection accuracy degrades above 30–50 tools; tool search is worth it at ≥10 tools or ≥10K tokens of definitions [21][22].

---

## 3. General agent and tool-use patterns, applied to us

### 3.1 Anthropic guidance

- **Writing tools for agents** [20]:
  - Consolidate multi-step operations (`schedule_event`, not list plus create).
  - Return meaningful context with natural-language names (offer a `response_format` concise/detailed if needed).
  - Paginate and truncate with sensible defaults, and steer toward narrower queries.
  - Make errors actionable.
  - Describe each tool "as you would to a new hire".
  - Iterate with evals.

  For us: `look` returns names and affordances, not class paths. Errors say what to do (`wrong_tool: need an axe of tier ≥1; you carry none`). Lists are capped with "N more, narrow with about=".
- **Context engineering** [23]:
  - "The smallest possible set of high-signal tokens".
  - **Just-in-time retrieval**: keep lightweight identifiers and load details through tools, in a **hybrid** with a small preloaded summary.
  - Structured notes outside the context window (Claude Plays Pokémon).

  For us: a preloaded `surroundings` digest, with `look`, `inspect` and `lookup` on demand; notes and skills in files.
- **Advanced tool use** [21]:
  - Tool Search Tool: 85% fewer definition tokens; Opus 4 accuracy 49→74% on MCP evals.
  - Programmatic Tool Calling: 37% fewer tokens; it removes model passes for chains of 3+ dependent calls.
  - Tool Use Examples: 72→90% on complex parameters.

  Recommended order: fix your biggest bottleneck first.
- **Docs check (2026-10-25):** tool search (regex and BM25, `defer_loading`, custom client-side search returning `tool_reference` blocks; up to 10,000 deferred tools; 3–5 loaded per search) and programmatic tool calling (`code_execution_20260120`+, `allowed_callers`) are both supported on **Claude Haiku 5.5** and Sonnet 5.5 [22][24].
  - Both are Anthropic-native request features. Through our LiteLLM adapter they would need an Anthropic-native client in `brain/llm.py`.
  - Neither pays off yet: we have ~14 tools and a few thousand tokens of schemas. PTC also adds code-container round trips to a latency-sensitive loop.
  - **Use them when:** tools exceed ~20, or we expose many skills as tools (tool search, preferably the custom variant over our skill index), or for offline Sonnet jobs that crunch catalogs (PTC).
- **Code execution with MCP** [25]: present tools as code files, "search_tools", 150K→2K tokens, and save working code as `./skills/` with a SKILL.md. This is the same "skills accumulate" idea as Voyager. We implement it as data skills (L3).
- **Caching (skill docs):** Haiku 5.5 and Sonnet 5.5 cache prefixes from **512 tokens**. Keep tools → system → stable context first, and volatile state last. Changing the tool list mid-session invalidates the cache, so keep the Controller's tool list fixed.

### 3.2 ReAct vs single-shot vs CodeAct for the Controller

- **Today:** single-shot, one action. It cannot look before acting, which caused the sticks bug.
- **Recommended: bounded ReAct** (thought → read-only tool → observation → action):
  - A hard cap of 3 model calls per command.
  - Read-only tools don't interrupt the current job and don't count as actions.
  - The first action tool commits the turn. Speech is generated with or after the action, keeping the single voice.
  - With the `surroundings` digest preloaded, "follow me" and "kill that wolf" still take one call. "Pick up the sticks" takes one call if sticks are in the digest, or two if Haiku needs `look(about="sticks")`.
- **CodeAct:** rejected for the live loop. Composition happens through skills.

### 3.3 MCP: should the bridge be an MCP server?

**Yes, as a facade, not as the brain's transport.**

- **For:**
  - Any MCP client (Claude Code, the Claude Agent SDK, Claude Desktop) could drive or inspect the bot. That is useful for development ("Claude Code, look around and pick up the stick" without the brain), for tool evals, and for agent-written diagnostics.
  - The official Python SDK (MIT, Python ≥3.11, stdio and Streamable HTTP) makes a server out of type-hinted functions [26].
  - LiteLLM can load MCP tools in OpenAI format (`experimental_mcp_client.load_mcp_tools(..., format="openai")`) [27], and the Agent SDK supports in-process SDK MCP servers (`create_sdk_mcp_server`) [28].
- **Against putting it on the hot path:**
  - The Controller needs in-process control of interrupts, verification, single voice and per-call bounded context, and adds nothing by speaking MCP to itself.
  - The Anthropic **MCP connector** requires a server reachable from Anthropic's side (a public URL). Our VM only exposes UDP 7777, and opening an inbound endpoint to drive the bot is an unnecessary risk.
- **Constraint:** there is one puppet. Two controllers (live brain plus an MCP client) must not command it at once. The MCP server takes an exclusive "control lease" file, and the brain refuses actions while the lease is held (read-only tools stay allowed).
- **Shape:** `brain/mcp_server.py` wraps `GameInterface` / `BridgeClient`: the same tool names and the same pydantic schemas (`interface.TOOLS`), plus `lookup` and `run_skill`. It runs over stdio for Claude Code.

---

## 4. Knowledge base: game data primary, wiki secondary

### 4.1 Game data: what to extract (from `dumps/26161880/CXXHeaderDump/Dominion.hpp`)

| Fact | Source class / property | Notes |
|---|---|---|
| Item name, flavour text, stack, category, weight | `UItemData.Name` (FText), `FlavourText`, `MaxStackSize`, `Category` (tag), `ItemFilterTags` | Extend `data/items_<build>.json` (today it holds equipment only) to **all** `UItemData` (resources, food, runes) |
| Recipe | `URecipeData.ItemsConsumed` / `ItemsCreated` (`FItemDataContainer{ItemData, Count}`), `ExtraItemsCreated`, `AlternativeItemCreated`, `FuelConsumedOverride`, `CraftTime`, `MinProcessingTime`/`MaxProcessingTime`, `SkillUsedToCraft`, `VendorReputationRequirement`, `bIgnoreAutomaticUnlocks` | `URuneRecipeData` subclass for runes |
| Which station crafts what | `UCraftingStationComponent.ValidRecipes`, `CraftingDataRowHandle` → `FCraftingStationDataTableRow.LabeledRecipes` (`FLabeledCraftableCategory{Label, Collection}`), `DisplayName`, `StationBuildingPieceData` | Station → its buildable piece, so "no station nearby" can become "build one" |
| Processing stations (furnace, kiln) | `UProcessingStationComponent.ProcessingStationRowHandle` → `FProcessingStationDataRow.Recipes`, `AcceptedFuels`, `MaxResourceSlots`, `ProcessingRate`; outputs spawn as world items (`SpawnItemClass`) | Asynchronous: load ingredients plus fuel, wait, collect (pickup) |
| Unlocks | `UProgressComponent.RecipesUnlocked` (TSet), `BuildingsUnlocked`; `UnlockRecipes(...)` | Mirror Luis's unlocks (same policy as spells, design section 9) |
| Craft RPC (player) | `UInventoryController:Server_CraftRecipe(CraftingStation, Recipe, Count, BonusCount, XPMultiplier, BonusXPMultiplier, TArray<UInventoryComponent*> Inventories)` | **Takes a TArray of objects and very likely lives on the PlayerController (UNVERIFIED).** The puppet has no PlayerController inventory (R1/R8 class of risk). See open question Q2 |
| Buildings | `UBuildingPieceData.DisplayName`, `Description`, `Requirements` (`FResourceRequirement{Amount, ItemData}`) | For the later place/build skill |
| World objects | `AWorldActor.DisplayName` (FText, on every world actor), `WorldActorTags`; `ABaseInteractableResource.ItemData`, `ItemDropComponent`, `ResourceState`, `IsResourceAvailable()`; `AFellableTree.StumpDisplayName`, `TreeData`; `FItemDropData{ItemDataClass, MinToDrop, MaxToDrop, ProbabilityOfDrop}` | Generated `data/world_<build>.json`: class → name, gives, tool gate, interaction prompts. This replaces `resource_profiles.lua` aliases over time |
| Interaction | `UInteractionComponent.InteractionPrompt`, `SecondaryInteractionPrompt`, `bHasSecondaryInteraction`, `InteractionType` (PrimaryAndSecondary / Hold), `InteractionDistance`, `CanInteractConditions`; `GetInteractionPrompt(PlayerCharacter)` | The affordance source (section 6.3) |

Generate these offline like the item catalog: debug_run plus `tools/build_*.py`, with output in `data/*_<build>.json`. Regenerate in the patch pipeline (design section 11).

### 4.2 The wiki: what it offers and how to mirror it

- **Site:** `https://dragonwilds.runescape.wiki`.
  - MediaWiki 1.45.3, API at `/api.php`.
  - Extensions: **Bucket** (structured data), TextExtracts, CirrusSearch, Scribunto.
  - 3,852 articles and 21,434 pages, so a full mirror is small [29].
- **Structured data via Bucket** (`action=bucket`). Tables include `recipe`, `dropsline`, `infobox_item`, `infobox_npc`, `infobox_spell`, `infobox_weapon`, `storeline`, `item_perks` and `object_id`. Verified with live queries:
  - `recipe`: fields `uses_material`, `uses_facility`, `output`, `uses_skill`, `json`. Example: *Iron Logging Axe* = 6 Iron Bar + 4 Oak Logs + 2 Wool Thread at the **Blacksmith's Bench** *(wiki)*.
  - Alternatives: *Iron Bar* = 3 Iron Ore **or** 9 Iron Salvage Pile at the **Furnace**; *Wool Thread* = 1 Fleece **or** 3 Soft Animal Fur at the **Spinning Wheel** *(wiki)*.
  - Oak Logs feed Wall (Build Menu), bows (Fletching Bench), axes and pickaxes (Blacksmith's Bench), Oak Battlestaff (Mystic Forge) and Charcoal (Kiln).
  - `dropsline`: e.g. *Oak Tree → Oak Logs ×28, Always* *(wiki)*.
  - `infobox_item`: name, type, stack limit, description, weight.
  - `object_id`: **empty (0 rows)**, so there is no wiki→game-id mapping. Join on display names.
- **Prose:** wikitext through `action=query&prop=revisions&rvprop=content&rvslots=main` (batches of 50 titles), or rendered text through `action=parse` / TextExtracts. Enumerate with `list=allpages`, and update incrementally with `list=recentchanges`.
- **Etiquette** [30][31]:
  - No hard rate limit, but they "reserve the right to limit access" for heavy use.
  - A **descriptive User-Agent with contact** is required; default `python-requests` / `curl` agents are blocked.
  - Use the Discord #api-discussion channel for anything large.
  - Our plan: sequential requests about one per second with `maxlag=5`. A full mirror is about 21K pages ÷ 50 per request ≈ 430 requests. After that, daily or post-patch `recentchanges` deltas.
- **Licence:** content is **CC BY-NC-SA 3.0** (Weird Gloop terms; RuneScape is a Jagex trademark).
  - A private, non-commercial mirror used as model context is fine.
  - Keep the source URL on every chunk (attribution). Don't publish the mirror. If shared, it stays non-commercial and under the same licence.
  - Recommended: keep the raw mirror out of git (`data/wiki/` gitignored) and commit the fetch script plus the derived name-join report.
- **Indexing:**
  - Chunk prose by section (H2/H3), prefixed with the page title, about 300–500 tokens per chunk.
  - Store chunks in **SQLite FTS5** (BM25 ranking, built into Python's `sqlite3`; check `fts5` is compiled in), in the same DB as the skill index.
  - Queries are mostly names ("oak logs", "furnace", "kalphite"), where BM25 is strong.
  - Add embeddings only if evals show misses: `fastembed` (ONNX, CPU, bge-small 384-d) [32], or `sqlite-vec`, with **reciprocal rank fusion** [33].
  - `bm25s` is the pure-Python alternative if FTS5 is unavailable [34].
- **Exposure:** never browse live mid-game (latency, etiquette). The `lookup` tool reads the local DB.

### 4.3 The `lookup` tool and the resolver

- **`brain/knowledge.py`**:
  - Loads the catalogs (items, recipes, world, spells, enemies) plus the wiki DB.
  - Builds one **entity table** keyed by game id, with display names, aliases (plural/singular, wiki name, the item a gatherable gives: a gatherable whose `ItemData` is "X" is findable as "X"), kind, and source.
- **`resolve(text, kinds=None) → [{id, name, kind, score}]`**:
  - Deterministic: exact → normalised (case, plural, punctuation) → alias → fuzzy, then FTS.
  - Used by the tools, which accept names, and by the Controller loop.
  - If ambiguous it returns several; if empty it returns the nearest suggestions. Mindcraft returns a bare "Invalid item type".
- **`lookup(name)`**: up to 3 cards, each about 120 tokens:

```json
{"name":"Iron Logging Axe","kind":"item","ids":["ITEM_..._IronLoggingAxe"],
 "what":"<UItemData.FlavourText>",
 "obtain":[{"how":"craft","station":"Blacksmith's Bench","needs":{"Iron Bar":6,"Oak Logs":4,"Wool Thread":2},"unlocked":true}],
 "uses":["chop trees (axe, tier from catalog)"],
 "where":"(wiki) ...", "source":["game:26161880","wiki:Iron_Logging_Axe"]}
```

`how_to(item, count)` is `lookup` plus the recipe chainer's best plan summarised (section 5). The Controller has `lookup`. The Planner has `lookup` plus `plan_obtain`.

---

## 5. Crafting: backward chaining over a recipe graph with costs

### 5.1 What the prior art does

- **Plan4MC** [9]: the skill graph has `consume`, `require` (not consumed, e.g. `crafting_table_nearby`), `equip` and `obtain`, with edge quantities.
  - DFS backward from the goal over parents, tracking held items: use what is held, otherwise recurse for the remainder.
  - Replan from the current inventory after every executed skill.
- **Mindcraft `getDetailedCraftingPlan`** [2]: recursive over minecraft-data recipes with a **leftovers** ledger ("use leftovers first, then inventory"). Items with no recipe are "base" (gathered). It uses only the first recipe and models neither tables nor smelting.
- **mineflayer-crafting-util** [35]: `planCraft(item, {availableItems, includeRecursion, multipleRecipes, careAboutExisting})` → `{success, itemsRequired, recipesToDo}`.
- **GITM** [5]: the goal becomes a sub-goal tree from the wiki and recipes, executed post-order.
- **DECKARD** [11]: the LLM hypothesises the graph and experience corrects it. That applies to our wiki data: wiki edges are hypotheses until game data or a verified craft confirms them.
- **GOAP** (F.E.A.R., Orkin [36]): A* over world states with action preconditions, effects and costs; replans when the world changes.
- **HTN** (GTPyhop [37], BSD-3-Clause-Clear): backtracking task decomposition with Run-Lazy-Lookahead for acting. Method order gives "inventory first, then …" naturally, but it finds a plan rather than the cheapest one.

### 5.2 Recommended: `brain/recipes.py`, a cost-ranked AND-OR chainer

**Graph** (built at startup from `data/recipes_<build>.json` + `data/world_<build>.json` + catalogs; wiki edges used only where game data has none, and flagged):
- **Item nodes.** Each item has **obtain methods** (OR):
  - `have`: bot inventory;
  - `ground`: `nearby_items` and ground gatherables seen by `look`;
  - `gather`: world objects whose `gives` include it, with tool gate category/tier, expected yield and observed seconds per unit;
  - `loot`: enemies whose drops include it;
  - `craft`: one method per `URecipeData` producing it, at station S;
  - `process`: processing-station recipe plus fuel, asynchronous;
  - `ask`: Luis (last resort).
- **Recipe nodes** (AND):
  - `consume` inputs × qty;
  - `require` station kind S (present, or buildable from `StationBuildingPieceData`);
  - `unlocked` (mirrors Luis's `RecipesUnlocked`);
  - outputs × qty (including `ExtraItemsCreated`; `ChanceToProduceExtraItems` is ignored when planning).
- **Gather methods carry `equip`:** a tool category and tier. That is a **require**, recursively obtainable (craft an axe), never consumed.

**Search:** `obtain(item, n, ledger, depth)`:
1. Take `min(n, ledger[item])` from a virtual inventory ledger (Plan4MC Algorithm 1 plus Mindcraft leftovers), which avoids double-counting across sibling branches.
2. For the remainder, cost every feasible method:
   - `ground` = travel time to the items;
   - `gather` = travel + n × observed seconds per unit (default from the profile, updated from skill stats), plus the cost of obtaining the tool if it is not held;
   - `craft` = Σ obtain(input) + travel to the nearest known station S + craft time × applications. Applications = ⌈remainder / output qty⌉; surplus goes back to the ledger.
   - If no station S is known, the cost is "build S" (place skill, later) or infeasible with the reason `need_station:S`.
   - `process` = the same plus fuel plus processing time.
3. Pick the **cheapest feasible**. Keep the next-best alternative for the explanation and for replanning.
4. Guards: cycle detection (an item on the current path), depth ≤ 6, a node budget, and memoisation per (item, ledger digest).
5. Unknown sources return `unknown_source:item` → the Planner uses `lookup` or asks Luis.

**Output:**
- (a) An **ordered task list in the existing `Task` format**: e.g. `go_to(<furnace>)`, `gather(...)`, `pickup(...)`, `craft(recipe, count, station)`.
- (b) A compact **explanation tree** for speech and for Sonnet: "6 Iron Bar ← 18 Iron Ore at the Furnace; 2 Wool Thread ← 2 Fleece at the Spinning Wheel (none known: ask)".
- (c) Alternatives with costs.

**Who does what:**
- The chainer does all the quantities and ordering.
- **Sonnet** sees the result as a tool output (`plan_obtain`) and decides: accept, choose an alternative ("use the iron in Luis's chest"), or ask Luis. It does no recipe arithmetic, which is where LLMs make errors (Plan4MC's rationale).
- **Haiku** uses `how_to` to answer "what do I need for X?" in chat.

**Verification:**
- Every step is verified by the executor (inventory deltas and positions, as today). `craft` needs a verifier: the store gained the outputs and lost the inputs.
- At plan level, the target count must be in the inventory.

**Replanning:**
- First re-run the chainer from the **current** inventory and perception (cheap, deterministic, as Plan4MC alternates planning and acting).
- Only when it fails, or the same failure repeats, use DEPS replanning with Sonnet.
- A wiki edge that fails in game is marked `refuted` for that build (the DECKARD idea).

**Composition with the skill library:**
- The chainer regenerates crafting plans cheaply, so plain "obtain X" plans are **not** stored as skills.
- Skills store what the chainer can't express: multi-goal jobs ("chop, then bring to me"), place-bound routines, building, farming.
- Skills also store **empirical costs** (seconds per oak log gathered, success rate per station) that the chainer reads as method costs.

**Build vs adopt** (search-before-building record): see section 6.8, records D1–D5.

---

## 6. The recommended brain, mapped to our modules

```
chat / events ──► Agent (event-driven) ──► Controller (Haiku, bounded ReAct ≤3 calls)
                                             │ context: persona+tools (cached) │ situation digest │ top-3 skills │ goal
                                             │ read-only: look · inspect · lookup · how_to          (no interrupt)
                                             │ actions:   follow · stop · go_to · attack · interact · pickup · drop
                                             │            give · cast · gather · run_skill · start_goal · remember · rules
                                             ▼
                                     Executor (deterministic, verifies each step from fresh state)
                                             ▲                      │
                 Planner (Sonnet): goal → plan_obtain / skills / primitives; DEPS replan; names new skills
                                             │
       knowledge.py (catalogs + wiki FTS + resolver) · recipes.py (chainer) · skill_library.py (FTS + stats)
                                             │
                    bridge ⇄ body: look/inspect/interact (new) + existing primitives + Lua BT loops
```

### 6.1 Perception (body plus brain)

**Body `look(radius_m=30, about=None, kinds=None, max=12)`**: new handler in `mod/body/perception.lua`, census in `mod/body/sense.lua`.
- **Census classes (generic bases only):**
  - `AWorldActor` subclasses: `ABaseInteractableResource` (Gatherable/Harvestable/Salvageable/Animated), `ADestructibleWorldActor` (`AFellableTree`, rocks), `AOreNode`;
  - `ARuntimeSpawnedWorldItem`;
  - AI characters;
  - players;
  - actors with `UCraftingStationComponent` / `UProcessingStationComponent` / storage.
- **Convert foliage around the bot first** (`sense.convert_foliage`, already throttled). Sticks, stones and plants are foliage ISM instances until converted. Without this the sticks bug persists.
- **Per thing:** `{id, name, kind, gives[], state, distance_m, dir, actions[]}`.
  - `name` = `DisplayName`, or `StumpDisplayName` for a stump.
  - `gives` = names of `ItemData` / drop config.
  - `state` = available / stump / felled / processing / dead.
  - `dir` = "ahead-left" relative to the bot's facing.
  - `actions` per section 6.3.
- **Grouping:** "Oak Tree ×14 (nearest 6 m)", so the output stays small.
- **`about` filter:** the body does a cheap substring prefilter over name, gives and class word. **If nothing matches, it returns the unfiltered top groups** with `matched:false`. That gives the model what it needs to say "I can't see any sticks, but there are Ash Logs and Stone here".
- **Truncation:** `max` items, plus `"more": N, "hint": "narrow with about= or radius_m="`.

**`get_state` stays the executor's verification source.** The Controller and Planner get a slim **situation view** (`brain/situation.py`):
- self: HP, held, gear short names, position only if needed;
- inventory as display name × count;
- players near: name and distance;
- current action;
- active goal and step;
- `surroundings`: ≤10 groups from the body's digest (an extender on `get_state` computed with the same census, without foliage conversion, so it stays cheap).

Drop `puppet`, `not_implemented` and raw entity dumps from model context. Ids appear only inside `look` results, where the model needs them for actions.

### 6.2 Name grounding and the "never substitute" rule

The tool-level rule is enforced in code, not only in the prompt:
- `pickup` / `interact` / `attack` accept `target` (an id from look) **or** `what` (a name).
- If `what` is given, the body or brain resolves it against **perceived** things only (resolver over look results).
- No match → `unknown_target` with `data.seen` (what is there) and `data.known` (what the name means, from `lookup`).
- The persona keeps one line: "act only on things in tool results; if absent, say so."

### 6.3 Affordances: per-target actions from the game's systems

Derived from components and classes, the same for every item, existing or future:

| Condition (generic) | Affordance | Body tool | Precondition text |
|---|---|---|---|
| Has `UInteractionComponent`, prompt enabled | `interact` (prompt text, e.g. the game's own "Pick up"/"Gather" FText); `interact_secondary` if `bHasSecondaryInteraction`; `hold` if `InteractionType=Hold` | `interact(target, secondary=false)` | `InteractionDistance`; `CanInteractConditions` can't be evaluated cheaply, so the body tries and verifies |
| `ARuntimeSpawnedWorldItem` | `pickup` | `pickup` (verified magnet route) | — |
| Destructible with health plus a tool gate (`BP_DamageModifier_SpecificWeapon_C`, read via `hitcheck`) | `gather` | `gather(resource=<name>)` | "needs axe tier ≥1" from the gate |
| AI character, hostile or attackable | `attack` | `attack` | — |
| `UCraftingStationComponent` | `craft` (recipe names from `ValidRecipes`) | `craft` (P7.3) | unlocked recipes; materials |
| `UProcessingStationComponent` | `process` | `process` (later) | accepted fuels |
| Player | `follow`, `give` | `follow`, `give` | — |

- **`inspect(target)`** returns one thing's full card:
  - description (`FlavourText` / `Description`, or a wiki snippet);
  - `gives` with min/max;
  - tool gate;
  - station recipes (top 10 plus a count);
  - state;
  - actions with preconditions;
  - verified flags per action route (e.g. `interact: route unverified for puppet`), so the model knows what will fail.
- **Prior art:** UE5 **Smart Objects** (definitions advertise slots and behaviours; agents query by tags) [38], and The Sims' advertising objects ("new objects could be added later without the Sims having any foreknowledge") [39]. Our census reads the game's own interaction components, which are its smart objects.

### 6.4 Action primitives vs composed skills

| Layer | Examples | Where | Rule |
|---|---|---|---|
| Body primitives (verified, tick-safe) | `go_to, follow, stop, look, inspect, interact, pickup, drop, give, attack, cast, gather, craft, place` | Lua handlers in `skills.lua` / `item_skills.lua` / `gather.lua` / new `perception.lua` | Probe-safe, verified-state success (ARCHITECTURE rule 8) |
| Body loops (tick speed) | gather's BT (scan → approach → swing → collect → repeat), combat BT, reflex rules | Lua beehive BT | Anything needing <1 s reactions stays here |
| Brain-composed skills (data) | `deliver_resource(resource, stacks, player)`, `restock_runes_at(place)` | `skill_library.py` JSON | Steps are only registered primitives or other skills; verified like plans |
| Deterministic planners | recipe chainer | `recipes.py` | No model in the arithmetic |

### 6.5 The skill library (`brain/skill_library.py`)

**Format** (one JSON record per skill, in `logs/state/skills/skills.json`; promoted to the committed `data/skills/` after Luis reviews them):

```json
{"name":"deliver_resource_stacks",
 "description":"Gather N stacks of a tree/rock resource and drop them at a player's feet.",
 "params":{"resource":"str (gather resource, e.g. 'oak')","stacks":"int","player":"str"},
 "preconditions":[{"held_tool_for":"$resource"}],
 "steps":[{"skill":"gather","args":{"resource":"$resource","count":"$stack_size"},"repeat":"$stacks"},
          {"skill":"go_to","args":{"target":"$player"}},
          {"skill":"drop","args":{"item":"$resource_item","count":"$stacks*$stack_size","at":"luis"}}],
 "postcondition":{"inventory_delta":{"$resource_item":"-$stacks*$stack_size"}},
 "derived":{"$stack_size":"catalog.max_stack($resource_item)","$resource_item":"resolve_drop($resource)"},
 "stats":{"runs":3,"ok":3,"avg_s":612,"sec_per_unit":{"oak":1.5}},
 "origin":{"goal":"chop trees until 4 stacks of oak logs then bring them to me","build":"26161880","created":"..."}}
```

**Save** (`agent.py`, after `goal done`):
1. Only if every task was verified **and** the goal postcondition holds in fresh state (Voyager's verification gate, done deterministically).
2. One Sonnet call ("generalise this verified task list into a skill: name, description, parameters drawn from the goal text, preconditions, postcondition").
3. Validate the record with pydantic against the registry: steps must be registered skills.
4. Dedupe: name or description similarity above a threshold → merge stats and keep the shorter verified variant. After 5 variants, Sonnet consolidates them (GITM N=5).

**Retrieve:**
- FTS5 over name, description and origin goal; top-3 records, about 80 tokens each, in the Controller context.
- Embeddings later if needed, as for the wiki.
- The Planner gets top-5.

**Use:**
1. The Controller calls `run_skill(name, params)`.
2. The agent checks preconditions against the situation, expands the steps (`$` substitution, `repeat`), and runs them as a goal tree through the executor.
3. A failing step goes to normal DEPS replanning, with the skill's text as context, and the skill stats are updated.
4. After ≥4 runs with >50% failures the skill is flagged `suspect` and is not offered.

**Scope:**
- Procedures are **global** (they generalise across worlds).
- Place-bound skills reference **named places**, resolved per world (`WorldSaveGuid` notes, design section 15).

### 6.6 How Haiku and Sonnet split the work

| Decision | Who | Why |
|---|---|---|
| Interpret chat, ground names (`look`, `lookup`), single actions, standing orders, all speech | **Haiku** Controller | Latency; most commands are one action |
| Run a retrieved skill whose preconditions hold | **Haiku** (`run_skill`) | No Sonnet call for repeat jobs. This is how capability gets cheaper over time (design section 14) |
| Multi-step goal with no matching skill; any crafting depth > 1 | **Sonnet** Planner (via `start_goal`), using `plan_obtain` + `lookup` | Needs judgement over options; chainer output keeps it grounded |
| Replan after a deterministic failure the chainer can't fix | **Sonnet** (DEPS) | Explanation quality |
| Name and generalise a new skill; consolidate variants; draft resource profiles from `watch` data (design section 14) | **Sonnet**, offline or after the goal | Not latency-bound |
| Quantities, ordering, preconditions, verification, retries | **Code** (chainer, executor) | Determinism (L4, L7) |

**Escalation rules in the persona:**
- "If a listed skill fits and its parameters are clear, call `run_skill`."
- "If the job has several steps and no skill fits, call `start_goal`."
- "If a step failed and you don't know why, call `start_goal` with what happened" (Sonnet replans).

### 6.7 Context and cost control

- **Prompt layout:**
  - [tools (fixed list) → persona] = the cached prefix (over 512 tokens, so it caches on Haiku 5.5 and Sonnet 5.5);
  - then situation, top-3 skills, relevant notes (places plus the top-k notes by FTS, not all of `notes.json`), the active goal, and the last N=10 events.
  - No transcript. Each ReAct step appends only the tool result.
- **Budgets:** ≤3 model calls per command; `look` ≤12 entries; `lookup` ≤3 cards; skills ≤3. The Planner gets ≤2 `lookup` / `plan_obtain` rounds before it must plan or ask.
- **Rate:** event coalescing as today (design section 3). No timers.
- **Estimated cost:**

  | Call | Input tokens | Output | Price | Cost per call |
  |---|---|---|---|---|
  | Haiku 5.5 step | ~3K (≈2K cached) | ~150 | $0.10 / $0.50 per M | ~$0.0003 |
  | Haiku 5.5 command (1–2 steps) | | | | ~$0.0005 |
  | Sonnet 5.5 plan | ~6K | ~1K | $2 / $10 per M | ~$0.02 |
  | Sonnet 5.5 skill naming | ~3K | ~400 | $2 / $10 per M | ~$0.01 |

  An active hour (~200 commands, ~10 goals) costs about $0.4.
- **Tool search:** not needed while ≤14 always-loaded tools. Skills are **not** individual tools: they go through `run_skill` plus retrieval, which keeps the tool list fixed and the cache warm. If tools pass ~20 (building, farming, crafting variants), defer the rare ones with the tool search tool, which Haiku 5.5 supports and which appends rather than swaps definitions.
- **LiteLLM caveat:** confirm `cache_control` pass-through for Anthropic in our LiteLLM version, and log `cache_read_input_tokens`. Tool search and PTC would need an Anthropic-native client in `llm.py`, behind the same `LLMClient` protocol.

### 6.8 Adopt vs build (decision records)

**D1: Agent harness (2026-10-25)**
- Need: an event-driven Controller and Planner loop with interrupts, verified steps and a single voice.
- Searched: game-agent frameworks; Python agent frameworks with tool calling; the Anthropic Tool Runner; the Claude Agent SDK; GamingAgent; Cradle; mineflayer-like abstractions.
- Found:
  - GamingAgent [40] and Cradle [12] are pixel- or keyboard-based.
  - Mindcraft and mineflayer are tied to the Minecraft protocol (JS).
  - The general frameworks (Tool Runner, Agent SDK, pydantic-ai, LangGraph, smolagents) loop over tools, but none model interrupts, game-state verification or one-voice speech.
- Decision: **keep** our harness (under 1,000 lines today). **Adapt** patterns (ReAct, the Voyager library, the DEPS replan).

**D2: MCP facade**
- Need: let Claude Code or Agent-SDK agents drive and inspect the bot.
- Found: the official MCP Python SDK (MIT) [26]; minecraft-mcp-server as precedent [16].
- Decision: **adopt** the SDK for `brain/mcp_server.py` over stdio, with a control lease. Not on the live path. No MCP connector (it would need a public endpoint).

**D3: Retrieval (wiki, skills, notes)**
- Found: SQLite FTS5 (built in, BM25); bm25s [34]; fastembed [32]; sqlite-vec + RRF [33].
- Decision: **adopt FTS5** now; embeddings are optional later through fastembed / sqlite-vec.

**D4: Recipe planner**
- Found:
  - mineflayer-crafting-util [35] and Mindcraft's planner [2] are JS, Minecraft-specific, use the first recipe only and have no stations.
  - GOAP implementations are engine-bound (Godot, C++).
  - GTPyhop [37] is Python HTN with backtracking, but finds the first plan rather than the cheapest, and has no quantities or ledger.
- Decision: **build small** (~200 lines plus tests), adapting Plan4MC's Algorithm 1 and Mindcraft's leftovers ledger. Revisit GTPyhop if building and farming need hierarchical methods.

**D5: Wiki fetch**
- Found: the documented MediaWiki API plus the Bucket API; etiquette pages [30][31]. `rswiki-wrapper` targets RS3/OSRS prices, not Dragonwilds pages.
- Decision: **plain HTTP with the documented API** in `tools/wiki_mirror.py` (descriptive User-Agent, about 1 request per second, `maxlag`).

---

## 7. Worked examples

### 7.1 "claude pick up the sticks"

1. **Body:** the chat hook → `command_received{player:"Luis", text:"claude pick up the sticks"}`.
2. **Agent** → Controller, with the situation. Its `surroundings` digest (a census without foliage conversion) shows: `Oak Logs ×2 (world item, 1 m)`, `Oak Tree ×9 (6 m)`, `Luis (2 m)`.
3. **Haiku, call 1:** sticks aren't in the digest. Rule: "only act on perceived things". It calls `look(about="sticks", radius_m=20)` (read-only, no interrupt).
4. **Body:** converts foliage within 20 m, takes the census, prefilters on "stick". It matches `gives` of the `BP_Spawner_AshBranch_*` actors, whose `ItemData` names the stick item:
   `{matched:true, things:[{id:"g_ashbranch_3", name:"<DisplayName>", kind:"gatherable", gives:["<stick item name>"], distance_m:4.2, dir:"ahead-right", actions:[{a:"interact", prompt:"<game prompt FText>"}]}, … ×3]}`
   (Names in angle brackets are game strings still to read; this design does not assume them.)
5. **Haiku, call 2:** calls `interact(target="g_ashbranch_3")`. The rule "no item name given → it is the thing the player named" holds because the target came from a matched look. Its text: "Grabbing those sticks."
6. **Executor:**
   - Baseline state → `interact`.
   - The body walks within `InteractionDistance`, runs the interaction route, and routes the grant into the bot store.
   - Verifier: target state became unavailable or gone **and** the store gained `gives`.
   - Success → speech.
   - If Luis said "the sticks" (plural), Haiku can pass `limit` / repeat via `interact(what="sticks", limit=3)`.
7. **Absent case:** look returns `matched:false` plus what is there. Haiku says "I can't see any sticks around here, only oak logs and trees." No action, no substitution. The `pickup` tool's own guard also refuses a mismatched `what`.
8. **Unknown word case** ("pick up the flurbs"): `look` has no match and `lookup("flurbs")` gives no entity and no suggestions. Haiku: "I don't know what flurbs are."

**Cost:** 2 Haiku calls (~$0.001), 2 bridge round trips (~0.2 s each) plus the walk.
**Blocker:** step 6's interaction route for a PlayerController-less puppet (open question Q1, section 9).

### 7.2 "chop trees until 4 stacks of oak logs then bring them to me"

**First time (empty library):**
1. **Haiku:** multi-step, and the top-3 skills don't fit (the library is empty). It calls `start_goal("gather 4 stacks of oak logs and bring them to Luis")`. Speech: "On it, 4 stacks of oak coming up."
2. **Planner (Sonnet):** context = goal, situation, skills (none), notes. Tools: `lookup` and `plan_obtain`.
   - `lookup("oak logs")` → item `ITEM_Resources_Wood_Oak`, `max_stack` from the catalog (99 per the store tests; read from the catalog, never assumed). Obtain: gather from Oak Tree (axe, tier 1) yields ~28 per tree *(wiki dropsline)*, refined by the gather profile. Stack math: 4 × max_stack.
   - `plan_obtain(ITEM_Resources_Wood_Oak, 4×max_stack)` → the chainer:
     - `have` = current store count;
     - `ground` = any oak logs within range (cheap: pickup first);
     - `gather` requires an axe: the bot's held axe is checked against the tool gate. If none, obtain(axe): inventory → craft (needs a station and materials) → else `ask`.
     - Output: `[pickup(oak) if any] + gather(oak, 99) × 4`, split per stack so each task fits the body's time cap (90 s + 20 s per unit, max 1700 s) and gives a checkpoint per stack.
   - Sonnet appends delivery: `go_to(Luis)`, `drop(item="oak logs", count=4×stack, at="luis")`. drop spawns one world item per stack, at most 10 per call, so this is fine.
3. **Executor:** runs each task.
   - `gather_progress` events go to the log, and Haiku can answer "how's it going?" from goal progress.
   - Each gather is verified by the inventory delta on the resolved item key. Partial progress resumes with the remainder (existing `_remaining_args`).
   - Luis's commands interrupt; the job resumes or is cancelled as today.
4. **Deliberate failure** (the Phase 8 gate): no oak within 120 m → `nothing_in_range` (deterministic):
   - The chainer re-runs. The ground and gather methods are infeasible here, so it finds a gather site from `notes` places (e.g. "oak grove") if known.
   - Otherwise Sonnet DEPS: describe ("gathered 1/4 stacks, then nothing in range") → explain ("no oak trees within 120 m of here") → plan: `go_to(place)` and gather, or a `lookup("Oak Tree")` wiki location → else `ask_help`: "I've run out of oak trees nearby. Where should I look?"
5. **Success:** every task is verified, and the postcondition (Luis-side drop verified and store delta) holds.
   - The agent asks Sonnet to generalise this into `deliver_resource_stacks(resource, stacks, player)` (section 6.5), with `sec_per_unit.oak` measured from the run.

**Next time:** "claude get me 2 stacks of ash logs":
1. The FTS skill retrieval puts `deliver_resource_stacks` in the top 3.
2. Haiku checks the preconditions it can see (it holds an axe; `lookup("ash logs")` says gather from Ash Tree, axe tier 1).
3. Haiku calls `run_skill("deliver_resource_stacks", {resource:"ash", stacks:2, player:"Luis"})`.
4. No Sonnet call. The executor verifies every step as before, and the stats update.

---

## 8. Implementation steps (ordered), with the files that change

Each step follows ARCHITECTURE section 4 (probe-safe handler, verified success, Lua and pytest tests, capabilities, BRIDGE_PROTOCOL.md), and search-before-building for anything new.

1. **`look` + `inspect`, read-only body perception** (fixes half of the sticks bug; no native writes).
   - `mod/body/sense.lua`: a generic census spec over the base classes in section 6.1; descriptor reads (`DisplayName`, `ItemData`, drop config, `ResourceState`, interaction prompt fields); grouping; foliage conversion before `look`.
   - New `mod/body/perception.lua`: handlers `look`, `inspect`; `get_state` extender `surroundings`.
   - `mod/scripts/bridge.lua` `M.TOOLS`; `mod/scripts/main.lua` (register).
   - `mod/tests/test_perception.lua` (fake world: gatherable, tree, world item, station, AI).
   - `brain/BRIDGE_PROTOCOL.md`.
   - **Live check:** Luis stands near sticks; compare `look` with what he sees (one yes/no question). Record FText reads and prompt strings in DISCOVERIES.
2. **Controller as a bounded ReAct loop with grounding.**
   - `brain/interface.py`: `LookArgs`, `InspectArgs`, `LookupArgs`, `InteractArgs`, `RunSkillArgs`; `READ_TOOLS`; `Reason` additions (`ambiguous_target`, `not_interactable`).
   - `brain/controller.py`: loop (≤3 calls, read-only tools inline, first action commits), persona rewrite (grounding, escalation rules), situation view.
   - New `brain/situation.py` (slim view).
   - `brain/agent.py`: consume the loop's decision.
   - `brain/llm.py`: return assistant tool-call messages for the loop; cache-control pass-through.
   - `brain/mock/game.py` + `brain/fake_body.py`: ground gatherables, look, inspect, interact.
   - `evals/controller_cases.jsonl`: grounding cases (sticks present, absent, unknown word, ambiguous, "the logs" vs "the sticks").
   - **Before running evals:** state the call count and model, e.g. 20 cases × ≤3 Haiku calls.
3. **World-object catalog** (perception names and affordances for every class, generated).
   - Extend `mod/scripts/catalog.lua` (or a new `mod/scripts/world_dump.lua`) plus a new `tools/build_world_catalog.py` → `data/world_26161880.json`. Document in `data/README.md`.
   - Later: `mod/body/resource_profiles.lua` aliases come from it. The patch pipeline diffs it.
4. **Generic `interact`** (the other half of the sticks bug; the gate for chests, stations and farming).
   - Discovery: which interaction route works for a PlayerController-less puppet, and where grants go (`Server_RequestInteraction` on the puppet's `BP_Components_InteractionManager`, vs calling the bound handler `ABaseInteractableResource:OnInteraction(puppet)` / `DropItems(puppet)` and collecting the spawned drops). This is an **offline canary first** (risk register: R1/R8-like null-controller paths).
   - Files: `mod/body/items.lua` (route), `mod/body/perception.lua` (handler), `mod/experiments/interact_probe.lua`, tests; `executor.VERIFIERS["interact"]`.
5. **Knowledge base.**
   - **Recipes and stations:** `mod/scripts/recipe_dump.lua` + `tools/build_recipes.py` → `data/recipes_26161880.json` (URecipeData, station components and data rows, processing rows, building pieces). Unlock mirror read from Luis's `UProgressComponent.RecipesUnlocked`.
   - Extend the item catalog to all `UItemData`.
   - **Wiki:** `tools/wiki_mirror.py` → `data/wiki/` (gitignored; Bucket tables plus section chunks into SQLite FTS5), with a name-join report (wiki name ↔ game id) committed under `data/`.
   - **Brain:** new `brain/knowledge.py` (entity table, `resolve`, `lookup`); `lookup` tool in `interface.py` / `controller.py` / `planner.py`; tests `tests/test_knowledge.py` (offline fixtures).
6. **Recipe chainer.**
   - New `brain/recipes.py` (+ `tests/test_recipes.py`: alternatives such as Iron Bar ore vs salvage, leftovers, station missing, unlock missing, cycle, tool `require`).
   - `brain/planner.py`: a `plan_obtain` tool in the planning prompt, and plan validation against the chainer output.
   - Body `craft` skill (P7.3) per open question Q2.
   - `executor.VERIFIERS["craft"]`; `state_store.MOCK_SKILLS` += `craft` (already listed) and `interact`.
7. **Skill library.**
   - New `brain/skill_library.py` (pydantic records, FTS index, stats, expansion of `$`/`repeat`).
   - `brain/agent.py`: `run_skill` handling, save-on-verified-success, stats updates.
   - `brain/planner.py`: a "generalise into skill" prompt.
   - `brain/controller.py`: top-3 skills in context.
   - Mock scenario test: a second similar goal runs with **zero** Planner calls.
8. **MCP facade.** New `brain/mcp_server.py` (official MCP Python SDK, stdio) over `BridgeClient` plus `knowledge`, `skill_library`; a control-lease file honoured by `brain/agent.py`; a `.mcp.json` entry for Claude Code (dev only).
9. **Docs and tasks.**
   - `docs/ARCHITECTURE.md`: brain modules and recipes ("add a perceivable class", "add a knowledge source", "promote a skill").
   - `docs/tasks.json`: append tasks for steps 1–8 (do not restructure).
   - `docs/DISCOVERIES.md` for each verified read or route.

---

## 9. Open decisions for Luis

- **Q1. Interaction grant route for the puppet** (step 4): emulate like the verified emulated hit in gather (call the resource's handler and collect the drops into the bot store), or insist on the player RPC path. The emulated path is likely faster to make safe.
- **Q2. Crafting for the bot:** `Server_CraftRecipe` needs a PlayerController `UInventoryController` and a `TArray<UInventoryComponent*>`. The puppet has neither, and TArray-of-object args are on our risk list. Options:
  - (a) emulated craft: near a station whose `ValidRecipes` holds the recipe, the recipe unlocked for Luis, consume from the bot store, add outputs, play the station or montage feedback;
  - (b) research a puppet-owned `InventoryComponent` (big, risky).

  The proposal is (a) first, with "acts like a player" visuals as a follow-up.
- **Q3. Wiki mirror storage:** gitignored local mirror (proposed) vs committed. The licence is CC BY-NC-SA 3.0: attribution and non-commercial use either way.
- **Q4. Skill promotion:** auto-use learned skills immediately (proposed, since they are already state-verified) or after Luis reviews them.

---

## Sources

1. Mindcraft README and source: https://github.com/mindcraft-bots/mindcraft · commands: https://raw.githubusercontent.com/mindcraft-bots/mindcraft/main/src/agent/commands/queries.js · https://raw.githubusercontent.com/mindcraft-bots/mindcraft/main/src/agent/commands/actions.js · param validation: https://raw.githubusercontent.com/mindcraft-bots/mindcraft/main/src/agent/commands/index.js · profile prompts: https://raw.githubusercontent.com/mindcraft-bots/mindcraft/main/profiles/defaults/_default.json · examples and skill docs retrieval: https://raw.githubusercontent.com/mindcraft-bots/mindcraft/main/src/utils/examples.js · https://raw.githubusercontent.com/mindcraft-bots/mindcraft/main/src/agent/library/skill_library.js
2. Mindcraft crafting planner: https://raw.githubusercontent.com/mindcraft-bots/mindcraft/main/src/utils/mcdata.js
3. MineCollab (Mindcraft paper): https://arxiv.org/abs/2504.17950
4. Voyager: https://arxiv.org/abs/2305.16291 (HTML: https://arxiv.org/html/2305.16291)
5. GITM: https://arxiv.org/abs/2305.17144 (HTML: https://arxiv.org/html/2305.17144)
6. JARVIS-1: https://arxiv.org/abs/2311.05997 (HTML: https://arxiv.org/html/2311.05997)
7. Odyssey: https://arxiv.org/abs/2407.15325
8. MineDojo: https://arxiv.org/abs/2206.08853 · https://minedojo.org/
9. Plan4MC: https://arxiv.org/abs/2303.16563 (HTML: https://arxiv.org/html/2303.16563)
10. DEPS: https://arxiv.org/abs/2302.01560
11. DECKARD: https://arxiv.org/abs/2301.12050
12. Cradle: https://arxiv.org/abs/2403.03186 (HTML: https://arxiv.org/html/2403.03186)
13. SIMA 2: https://arxiv.org/html/2512.04797v1 · https://deepmind.google/blog/sima-2-an-agent-that-plays-reasons-and-learns-with-you-in-virtual-3d-worlds/
14. PUBG Ally / NVIDIA ACE: https://developer.nvidia.com/blog/how-krafton-built-pubg-ally-a-co-playable-character-powered-by-nvidia-ace/
15. Project Sid / PIANO: https://arxiv.org/abs/2411.00114
16. minecraft-mcp-server: https://github.com/yuniko-software/minecraft-mcp-server
17. ReAct: https://arxiv.org/abs/2210.03629
18. CodeAct: https://arxiv.org/abs/2402.01030
19. Agent Workflow Memory: https://arxiv.org/abs/2409.07429
20. Anthropic, Writing effective tools for agents: https://www.anthropic.com/engineering/writing-tools-for-agents
21. Anthropic, Advanced tool use: https://www.anthropic.com/engineering/advanced-tool-use
22. Tool search tool docs (model compatibility incl. Haiku 5.5): https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool
23. Anthropic, Effective context engineering: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
24. Programmatic tool calling docs (supported models incl. Haiku 5.5): https://platform.claude.com/docs/en/agents-and-tools/tool-use/programmatic-tool-calling
25. Anthropic, Code execution with MCP: https://www.anthropic.com/engineering/code-execution-with-mcp
26. MCP Python SDK: https://github.com/modelcontextprotocol/python-sdk
27. LiteLLM MCP client (`load_mcp_tools`): https://www.mintlify.com/BerriAI/litellm/advanced/mcp-tools
28. Claude Agent SDK (Python), in-process MCP tools: https://github.com/anthropics/claude-agent-sdk-python
29. Dragonwilds wiki: https://dragonwilds.runescape.wiki/w/Special:Version · API siteinfo and Bucket queries (`https://dragonwilds.runescape.wiki/api.php?action=bucket&query=...`) · https://dragonwilds.runescape.wiki/w/Bucket:Recipe · https://dragonwilds.runescape.wiki/w/Bucket:Infobox_item · https://dragonwilds.runescape.wiki/w/Bucket:Object_id
30. RuneScape Wiki, Help:APIs: https://runescape.wiki/w/Help:APIs
31. OSRS Wiki, Real-time prices (User-Agent and blocking guidance): https://oldschool.runescape.wiki/w/RuneScape:Real-time_Prices
32. fastembed: https://github.com/qdrant/fastembed
33. Hybrid FTS5 + sqlite-vec with RRF: https://simonwillison.net/2024/Oct/4/hybrid-full-text-search-and-vector-search-with-sqlite/
34. bm25s: https://arxiv.org/abs/2407.03618 · https://pypi.org/project/bm25s
35. mineflayer-crafting-util: https://unpkg.com/mineflayer-crafting-util@0.2.0/README.md
36. Orkin, Three States and a Plan (F.E.A.R. GOAP): https://pages.cs.wisc.edu/~dyer/cs540/handouts/gdc2006_orkin_jeff_fear.pdf
37. GTPyhop: https://github.com/dananau/GTPyhop
38. UE5 Smart Objects: https://dev.epicgames.com/documentation/en-us/unreal-engine/smart-objects-in-unreal-engine---overview
39. The Sims smart objects (Will Wright, via summary): https://lemmy.dormedas.com/post/997795 · https://en.wikipedia.org/wiki/Will_Wright_(game_designer)
40. GamingAgent: https://github.com/lmgame-org/GamingAgent

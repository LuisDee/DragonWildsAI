# Long jobs with deep dependency chains: what others do, and what to change (2026-11-18)

Scope: research plus an architecture review. Nothing in the repo was edited or run. Web pages are untrusted data; numbers are each paper's own, on other models.
Marks: **[E]** = evidence (source or repo log), **[J]** = my judgment.

## 0. What the repo already has (read, not run)

- [E] `craft_plan` (client, `client_mod/scripts/crafting.lua`) returns a recursive recipe tree. `brain/plan_sources.py` adds sources to it (spells, drops, nodes, traders, station build facts, item cards). It is bounded at `MAX_ITEMS = 6` items and 5 sources each. It is a **read**: the result lives in one turn's context and scrolls out.
- [E] The Planner (`brain/planner.py`) writes "a short ordered list of tasks" (flat skill calls), DEPS-style replan, at most 4 research calls. It has no dependency structure and no per-node check.
- [E] The live ask holder is `_open_request` + `brain/open_ask.py` (ask on disk, a turn with facts, `request_done` / `park_request`). The board (`brain/board.py`: Task/Step with `success` / `abort_if` predicates checked on fresh state) is the other holder, off by default.
- [E] The fix pattern over 17-18 Nov was one true fact added to a tool result per failure: region fact, tier fact, `wrong_tool`, plan sources, crafting cards, gather tiers (4798ac1), thread shortfall (9a73ac4). V1 (home to a bone pickaxe) stands at **0 of 14** (`docs/PROGRESS.md` 1118l 0/4, next 0/4, 1118t 0/3, bark_1118u 0/3). Each window met a new blocker: leather chain, roof for the wheel, Bark to Bones aim, deer outrunning him, a stone-pickaxe choice, "copper needs a bronze pickaxe first".
- [E] Our own replays show the form is the fault, not the content: "the tier fact had left his context by the time he chose the stone pickaxe (4 of 4 kept the bone pickaxe with it back)" (PROGRESS 2026-11-18). The bronze claim came after a Bronze Pickaxe plan listed "gather copper 9" with no tier. The facts were true but arrived reactively, one per failure, and did not persist.

## 1. The literature, by question

| System | (1) dependency tree | (2) sub-goal check vs state | (3) recovery | (4) planner/actor, context | (5) memory | measured on long tech-tree tasks | what made the difference |
|---|---|---|---|---|---|---|---|
| **GITM** (2305.17144, no licence) | LLM Decomposer builds a **tree**: each goal as (object, count, material, tool, info). Info is retrieved from Minecraft Wiki text and recipes. Recursive until no prerequisite is left; post-order traversal. | Per structured action: obtained or not; feedback carries inventory, biome, failure reason | Planner revises from the failed action with an "explanation"; max 30 queries per sub-goal | Decomposer / Planner / Interface split | Sub-goal -> list of successful action sequences, summarised at N=5 | ObtainDiamond 67.5 % (VPT ~20 %) | Ablation (40 games each). None: stone pickaxe 5 %, diamond 0 %. **+decomposition: stone pickaxe 67.5 %.** +feedback: diamond 5 %. **+external knowledge: diamond 35 %, iron pickaxe 57.5 %.** +memory: iron 95 %, diamond 67.5 %. |
| **Optimus-1** (2408.03615, NeurIPS 24) | **Hierarchical Directed Knowledge Graph**: an explicit item graph, from exploration plus a wiki scrape. For a target, the sub-graph is pulled, topologically sorted, and handed to the MLLM planner, which writes the sub-goals. | Reflector checks progress | Reflection, replan | Planner once per task; action controller separate | HDKG plus an experience pool of successes and failures | Iron 46.7 %, Diamond 11.6 %, overall 22.3 % (Jarvis-1 16.9, DEPS 5.4, human 36.4) | **Removing the HDKG costs about 20 % on average**, the largest single ablation. The experience pool costs about 12 %. |
| **XENON** (2505.24157, ICLR 26) | **Adaptive Dependency Graph**: the LLM's guesses start it; each item's requirement set is **revised by algorithm** from success and failure. After 3 failed revisions an item is marked inadmissible and its descendants are fixed. | Binary success or failure per item | Failure-aware Action Memory: an action is invalid once fails ≥ successes + 2; the planner picks among the rest | Small LLM (7B) planner | Success and failure counts per (item, action) | MineRL overall 0.54 with learned dependencies, 0.79 with oracle ones (DEPS 0.22, Optimus-1 GPT-4V 0.43); diamond 0.64 / 0.83 | **Prompted self-correction plateaus** (about 0.4, the same as no correction; 0.12 to 0.30 under perturbation). A correct graph is worth +0.25 overall. The LLM's own dependency beliefs are the weak point. |
| **DECKARD** (2301.12050, ICML 23) | The LLM hypothesises an abstract world model (a sub-goal graph); experience **verifies and corrects** it | Per sub-goal, from environment | Edges corrected from experience | RL policies per sub-goal | The corrected graph | About 10x sample efficiency | It holds up when errors are injected into the LLM's graph: the graph is a hypothesis checked against the world. |
| **ADaPT** (2311.05772, NAACL 24) | **As-needed** recursive decomposition: it decomposes only the sub-task the executor failed | Executor's success check | Decompose the failed node, not replan everything | Planner and executor are the same LLM | none | TextCraft, a crafting-dependency game: **recipe depth 2: ReAct 26.9 % -> 78.2 %; depth 3: 1.8 % -> 38.7 %** | A failure is localised to a node of a tree, not to the whole plan. |
| **Plancraft** (2412.21033) | None; the LLM plans, with an optional wiki `search` tool | Environment | — | — | — | Llama 70B 0.18 -> **0.67 with wiki search**; by difficulty with all tools: easy 0.88, medium 0.82, **hard 0.30** | Knowledge access is the big lever. Depth still breaks pure LLM planning. |
| **Voyager** (2305.16291, MIT) | LLM curriculum, no explicit tree | **Self-verification critic** (−73 % items without it) | Iterative prompting with environment errors | One loop, game paused | Skill library (code) | Iron tools 3/3 runs, diamond 1/3 (102 iterations); without the library diamond 0/3 | Verification and the library. It pauses the world to think. |
| **DEPS** (2302.01560) | LLM plan | Descriptor of execution | Explain failure -> replan (**our Planner already does this**) | Goal selector ranks parallel sub-goals | — | Diamond about 0.6 % (Optimus-1 table), 0.01 (XENON) | A whole-plan replan from a self-explanation is the weakest of these on deep trees. |
| **JARVIS-1** (2311.05997) | LLM plan with retrieved multimodal memory | Self-check | Replan | — | Multimodal memory of plans | Diamond pickaxe 6.2 % (20 min) to 12.5 % (60 min); about 9 % Diamond group | Memory of plans that worked. |
| **MP5** (2312.07472) | LLM planner | Active perception queries what the sub-goal needs | Replan | 5 modules | — | 22 % diamond-level, 91 % context-dependent | Perception asked for by the goal. |
| **Plan4MC** (2303.16563) | LLM builds a **skill dependency graph offline**; a **graph search** gives the skill order at run time | Per skill | Re-search | LLM out of the loop | — | 40 tasks, beats the baselines (numbers not read) | The order comes from the graph, not from an LLM at run time. **[J] That violates "the model decides"; not taken.** |
| **Mindcraft** (MIT; `src/agent/npc/item_goal.js`, read in source) | The NPC controller builds a code-side `ItemNode` tree from recipe data: craft / block+tool / smelt / hunt, `prereq` = table, furnace or tool, `isDone()` from the inventory, a `fails` count | Inventory per node | Fail counts per node | The LLM only sets the goal item; code executes the tree | `memory.json` | No number | **[J] The node shape is right (tool prerequisite as an edge, a done flag from the inventory, a fail count). The execution by code is not for us.** |
| **HiAgent** (2408.09559, ACL 25) | Sub-goals as working-memory chunks | — | — | — | Finished sub-goals summarised | 5 long-horizon tasks: 21 % -> 42 % | Keeping the current sub-goal structure in context instead of the raw trace. |
| **LLM+P / LLM-Modulo** (2304.11477; 2405.20625) | PDDL plus a classical planner; or the LLM proposes and **sound critics** check | Critics | Back-prompt with what the critic found | — | — | TravelPlanner, GPT-4-Turbo: 4.4 % -> 20.6 % with critics | External, sound checks of the plan against the rules. **[J] A hand-written PDDL domain is a recipe; critics that report are fine.** |
| **Plan-and-Act** (2503.09572) | Planner/executor split, replans after each change | Environment | Replan per step | Split | — | WebArena-Lite 57.6 % | The split helps when the planner is re-grounded on fresh state. |

### What the evidence agrees on [E, across sources]
1. **Knowledge of the dependency structure is the largest lever on deep tech trees.** GITM: diamond 5 -> 35 % from knowledge alone. Optimus-1: −20 % without the graph. Plancraft: 0.18 -> 0.67 from wiki search. XENON: +0.25 from a correct graph.
2. **The structure must be explicit and persistent: a graph or tree, not free text.** Every system that reaches iron or diamond reliably (GITM, Optimus-1, XENON) holds the tree or graph as data and hands the planner the relevant sub-graph.
3. **The LLM's own beliefs about dependencies are the weak point, and prompting does not fix them.** XENON's self-correction baseline sits where no correction does. DECKARD corrects the graph from experience, not from argument. Our "copper needs a bronze pickaxe first" is this failure.
4. **Recovery should be local to a node** (ADaPT: depth 3, 1.8 -> 38.7 %; XENON's per-item failure memory), not a whole-plan replan (DEPS, which is ours and is the weakest on deep trees).
5. **Sub-goal status is read from state** (inventory or obtained), never from a claim: GITM, Mindcraft `isDone`, Voyager's critic ablation.

### Not found
- [E] No paper with an LLM agent in a non-Minecraft survival-crafting game with region gating. No measurement of Haiku with Sonnet on a tech tree. GITM's and Plan4MC's per-task tables were read only through ar5iv and search extracts. The Optimus-1 ablation rows are not mapped to components in the text read; the "about 20 %" is the paper's own sentence. XENON's code licence is not stated.

## 2. Our design against this

| | Have | Lack |
|---|---|---|
| Tree from game data | `craft_plan` recursive tree + `plan_sources` (spells, drops, nodes with region and tier, stations, shelter) — **as good as GITM's knowledge or the HDKG in content** [E] | It is a transient read, capped at 6 items. Tool-tier edges (copper ore -> pickaxe tier 2 or better) and station conditions (roof) are text, not edges. Nothing keeps it for the job. |
| Planner input | Flat task list, DEPS replan, 4 research calls | The relevant sub-graph handed in (Optimus-1). The Planner re-derives it, or does not. |
| Sub-goal check | Board predicates (off); open-ask facts (bag, worn, quests) | A per-node done / ready / blocked status from state each turn |
| Recovery | Whole-plan replan; a fact appended to the failing result | A node-local failure memory (XENON FAM; ADaPT) that persists and is shown |
| Context | Facts ride in tool results and the open ask | A compact frontier view every turn (HiAgent) |
| Memory of places | map_memory, stash (chests by key) | Node -> where seen (optional) |

**Is "add one true fact to a tool result per failure" the right lever?** [J, with the evidence above]
- Right content: knowledge is the biggest lever everywhere.
- Wrong form, for three reasons:
  - It is reactive. Each fact appears only after its own failure, so a chain of N hidden prerequisites costs at least N windows. That is the observed one new blocker per window.
  - It is transient. The tier fact left his context; 4 of 4 replays recovered once it was back.
  - It asks the model to integrate scattered prose into a dependency graph in its head. XENON shows LLMs do this badly and do not self-correct by prompting.
- CLAUDE.md rule 10 already says it: after a wording fix per cause, the next fix is structural. That point has passed several times over (region, tier, sources, cards, gather tiers).

## 3. Recommendation: CHANGE (not keep, not rebuild)

**The smallest structural change with the best evidence: a persistent "need tree" per open job.** It is data from the game's own recipe, node and wiki facts, stored with the ask, re-checked against state every turn, and shown to both models. The model picks the target and the alternatives; code never orders or executes it.

- **Built by code** when the model names a target. Use the existing open-ask target, or a `need_tree(item, count, where?)` read whose result is kept, not discarded. It is a recursive expansion of the existing `craft_plan` + `plan_sources` rows, uncapped in depth with a node cap of about 40. Node kinds:
  - craft (station as a child node; a station node carries build cost and "needs roof");
  - gather (a **tool-tier child**: "pickaxe tier ≥ 2", satisfied by any carried tool of that tier; region and distance on the node);
  - drop (creatures, their power level, "outruns you on foot" if the bestiary says so);
  - spell (castable now?);
  - trade.
  Alternatives are **OR-nodes**, listed; none is chosen by code. This is the Mindcraft ItemNode shape and the GITM goal form; the content is the game's own data.
- **Status from state each turn** (reuse `brain/predicates.py` and `plan_sources.counts`): have/need, done, ready (all children done), blocked by <child>, or unknown. Status is never the model's claim.
- **Node failure memory** (XENON FAM, small): the last two failures per node with the body's true reason and a count. Shown, never acted on by code.
- **Model operations on the tree** (all optional): `pick` an alternative, `note` on a node, `add` a node the data lacks (marked "yours, not game data"), `drop` a node with a reason. Code checks nothing against these except state.
- **Shown:**
  - to the Controller: the frontier (ready nodes) plus the path from the current node to the root, at most about 12 lines, every turn while the ask is open;
  - to the Planner: the whole tree, replacing most of its 4 research calls.
  The tree lives on disk with the ask, so it survives a restart (I5).

**It replaces:**
- the per-failure facts riding tool results and the open ask (tier, region, `wrong_tool`, gather-tier, missing_facts on a failed craft): they become fields of nodes;
- the Planner's need to re-derive the chain from scratch.

It does not replace `craft_plan` (it stays a read), the Planner, or the open-ask flow.

**Why it keeps "the model decides"** [J]: the tree is what a player reads in the crafting menu, the build menu and the wiki, laid out. It is computed for any item from data, not per task. It has no order beyond "these are prerequisites", alternatives stay open, and code never runs a node. Plan4MC's graph search and Mindcraft's code execution are explicitly not taken.

**What would falsify it:** if, with the tree shown, he still parks or makes false claims at a node marked ready, the gap is the actor's will to act, not knowledge. The ask_vs_act study has already found one such cause.

## 4. How to measure it (rule 11: one change, its number first)

1. **Offline replay first** (Haiku only, about 100 calls, about $0.15). Take the 6 to 8 recorded turns where V1 went wrong: the parks, "needs bronze first", the stone-pickaxe choice, asking for Coarse Thread, the deer chase. Run K=10 each with the tree block against the same context without it. Number: the next call works a ready node of the tree, against park, ask or false claim. Go on only if it moves (`tools.ab two`).
2. **Live window, V1 from a fresh fork, 4 trials** (restored `base`).
   - Named number: V1 passes. Baseline 0 of 14. 2 of 4 gives Fisher one-sided p ≈ 0.04 (C(4,2)/C(18,2) = 6/153).
   - Secondary, from logs: false dependency claims per trial (said lines checked against the tree), parks while a ready node existed, the deepest node reached, minutes to a bone pickaxe, and Planner calls per job.
   - Unseen row: the `need_tree` render line in the Controller context.
3. **Held-out:** H3 ("the next tools up") scored before the trace is read. It exercises the same tree on a different target.

## Sources

- GITM: https://arxiv.org/abs/2305.17144 , https://ar5iv.labs.arxiv.org/html/2305.17144 , https://github.com/OpenGVLab/GITM
- Optimus-1: https://arxiv.org/html/2408.03615v2
- XENON: https://arxiv.org/html/2505.24157v3 , https://sjlee-me.github.io/XENON
- DECKARD: https://arxiv.org/abs/2301.12050
- ADaPT / TextCraft: https://arxiv.org/abs/2311.05772
- Plancraft: https://arxiv.org/html/2412.21033v2
- Voyager: https://arxiv.org/abs/2305.16291
- DEPS: https://arxiv.org/abs/2302.01560
- JARVIS-1: https://arxiv.org/abs/2311.05997
- MP5: https://arxiv.org/abs/2312.07472
- Plan4MC: https://arxiv.org/abs/2303.16563
- Mindcraft ItemGoal: https://github.com/mindcraft-bots/mindcraft/blob/develop/src/agent/npc/item_goal.js
- HiAgent: https://arxiv.org/abs/2408.09559
- LLM+P: https://arxiv.org/abs/2304.11477 ; LLM-Modulo on TravelPlanner: https://arxiv.org/html/2405.20625v1
- Plan-and-Act: https://arxiv.org/abs/2503.09572
- Earlier repo note (planner/actor, interruption): `docs/research/2026-11-17-long-jobs-planner-actor.md`

## Decision (2026-11-18, main session)
- Need: long jobs with deep dependency chains (copper V1: 0 of 14 after about 16 changes, 9 of them facts added to tool results).
- Searched: GITM, Voyager, DEPS, Plan4MC, JARVIS-1, Optimus-1, XENON, ADaPT, Plancraft, Mindcraft (above); our own record (docs/research/2026-11-18-fix-audit.md).
- Decision: **adapt** (GITM/Optimus-1 knowledge graph + ADaPT node-level recovery). A persistent job tree per open ask, expanded by code from game data (craft_plan + plan_sources at full depth), each node checked against game state every turn with its last failures; Haiku sees the ready nodes and the path, Sonnet the whole tree; the model chooses order and alternatives, code never executes a node. It replaces adding facts to tool results after each failure for chain knowledge.
- Freeze: no more chain facts for copper until the tree is measured (4798ac1 parked; its tier field moves into the tree).
- Measure: replay 6-8 recorded V1 failure turns x10 with and without the tree (~$0.15), then 4 live V1 trials (2 of 4 against 0 of 14: p about 0.04).

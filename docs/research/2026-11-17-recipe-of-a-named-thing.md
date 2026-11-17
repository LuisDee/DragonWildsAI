# A craft tried before its materials: what others do, and what was taken (2026-11-17)

### The recipe of a thing his quests or job name is shown, with what he carries (2026-11-17)
- Need: he calls `craft` to find out what a recipe takes. On 16 and 17 Nov, 29 of 292 crafts ended `missing_materials`, 21 of them the Stone Club of Getting Started. Of the 46 logs with a Stone Club craft, 21 held such a try, and none read `recipes` or `craft_plan` first. 19 of the 21 were the Controller's own call right after Doric's talk; 2 were steps of a plan. Each is a miss by the goal's bars. It is the largest open cause in the failure ledger (Getting Started, 6 runs).
- Why he does it: the quest step names the thing ("craft a Stone Club"), nothing he sees says what it takes, and one `craft` call answers that as well as a lookup does. The one-shot Planner cannot look anything up and wrote "The exact recipe amounts are a guess" (it planned 4 Ash Logs and 4 Stone; the recipe takes 6 and 8). A sentence in craft's description that points to `recipes` did not move it (binned on 16 Nov, 4 of 6 either way).
- Searched: LLM game agents and crafting prerequisites (Minecraft agents); a probing action against a read-only lookup; where recipe knowledge is put.
- Found:
  - GITM and JARVIS-1 put the recipe of the target item into the planner's context from a knowledge base, keyed by the item the goal names.
  - Voyager learns what a craft takes from the failed craft's own feedback, so a failed try is its lookup. That is what he does now, and here it is a miss.
  - Nothing found that compares a probing action with a lookup tool.
- Decision: adapt (retrieval into the context, as GITM and JARVIS-1 do).
  - `brain/needs.py` `named_recipes`: for each thing a quest step, the job or a waiting job names by its whole in-game name, the catalog's recipe with what he carries: "Stone Club at a Crafting Table takes 8 Stone (you have 4) and 6 Ash Logs (you have 4)". Only things a station makes; vendor recipes are left out; at most 3; a recipe that is not in his unlocked list says so.
  - The Controller sees it as a situation line after the quests line. The Planner gets it in its notes, for the goal's words and the quest steps.
  - It is what the crafting menu shows a player. It names no step and no order, and it works for any item the catalog holds. A name is matched to game data, not to a skill.
  - The craft's own reason now names every missing thing (1cffdc4).
- Measured offline: the failing turn of chain 101313 (0 Ash Logs carried, right after Doric's talk) replayed 10 times each way with Haiku: a craft first 6 of 10 as logged; 0 of 10 with the line (9 gathered 6 Ash Logs first, 1 started a goal that gathers first).
- Not taken: more words in craft's description (measured, no movement). A code check that refuses or reorders the craft (code never rewrites his decision). Loosening the grader's miss rule (Luis's call).
- Limits: the line shows the catalog's recipe, not the live menu; "not among your unlocked recipes yet" does not know a recipe that unlocks on using its station. A thing named only by a nickname is not matched. Live confirmation: Getting Started from `gs_start`.
- Sources: https://arxiv.org/abs/2305.17144 (GITM), https://arxiv.org/html/2311.15209v3 (JARVIS-1), https://arxiv.org/abs/2305.16291 (Voyager), https://arxiv.org/pdf/2410.22194 , https://arxiv.org/html/2505.18607v1 , https://ecva.net/papers/eccv_2024/papers_ECCV/papers/01280.pdf

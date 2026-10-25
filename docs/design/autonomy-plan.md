# Speed and long-horizon autonomy plan (2026-10-25, after the 21:00–21:16 session)

## 1. Where the time goes (measured from logs/brain-live-*.jsonl, last two sessions)
| Stage | Measured | Note |
|---|---|---|
| Chat line → first action or speech | **p50 5.0 s, p90 6.4 s** (n=41) | |
| ↳ "not named" burst debounce | ~2–3 s | Luis rarely says "claude", so most lines wait for the burst to end |
| ↳ game-state reads before each turn | **2.8 `get_state` per model turn** | each 0.1–0.4 s, and they're redundant |
| ↳ Haiku call | p50 1.9 s, p90 2.8 s; prompt ~13.3k tokens (≈65% cached) | |
| **Failing actions** (the real "slow") | Splinter: 22 s timeout × 2 executor attempts × 3 = **~2 min**; go_to from bed: 46 s + 125 s | slow failure + blind retries |
| Talk without action | "I'll try Splinter again now" with no tool call | the turn ends; nothing happens |

**Conclusion:** model thinking is about 2 s and isn't the main problem. He feels slow because of (a) the debounce, (b) actions that fail slowly and are retried blindly, and (c) turns that only talk. He looks stupid because the model lacks facts at decision time (what Splinter targets, the preview semantics) and because the body's primitives fail at things a player finds trivial (L14/L15).

## 2. Speed fixes (now, broker + skills agents)
1. **Debounce:** a line from the player he is with (the only player in range, or the last one he spoke with) counts as addressed; burst window ≤ 0.8 s. *Accept: p50 chat→first action ≤ 2.5 s.*
2. **One state read per turn** (cached ≤ 1 s), and a **trimmed digest**: only what's relevant (nearby top-N, held, vitals, the current goal). *Accept: prompt ≤ 8k tokens.*
3. **Fail fast:** every skill has a progress watchdog (no progress for N s → fail with a reason). Spells resolve or cancel within about 6 s. No executor retries; the result goes to the model.
4. **Act on the stream:** start the first tool call as soon as its input has streamed (the Anthropic streaming tool input) instead of waiting for the whole response. Precedent: speculative/streamed tool calling ([Stream blog](https://getstream.io/blog/speculative-tool-calling-voice/)), [Speculative Actions, ICLR 2026](https://arxiv.org/html/2510.04371v1). Only read-only tools are ever speculated.
5. **No talk-only promises:** if the reply promises an action and calls no tool, the model gets one continuation turn (information, not a veto). Regression test: the 21:02:56 and 21:15:01 replays.

## 3. Reliability first (autonomy grows only as fast as the primitives; CLAUDE.md risk 8)
- Open: L14/L15 preview spells, L7 interact on the right item, L8 go_to any id, L13 late-success detection.
- Each primitive gets a dev-server scenario in `tools/scenarios/dev_suite.json`, run before live sessions.

## 4. Long-horizon autonomy ("go get better gear, level skills of your choice, for hours")
Three loops at three speeds (as in PIANO and PUBG Ally, CLAUDE.md §10):

| Loop | Model | Cadence | Owns |
|---|---|---|---|
| Reflex | none (Lua) | frame | movement, combat defence, stay fed, verify |
| Controller | Haiku | on events (chat, results) | speech, interrupts, one step at a time, small fixes |
| **Director** | **Sonnet** | on goal start, subgoal done/failed, every ~5 min | the goal tree, choosing subgoals, replanning, research |

**What the Director needs (new infrastructure):**
1. **Goal tree, persisted** (`logs/state/worlds/<w>/goals.json`): goal → subgoals, each with a **success test checkable from state** (e.g. `equipped(Head).tier ≥ 4`, `skill(Mining) ≥ 60`, `inventory(ITEM_Bar_Iron) ≥ 20`), status, attempts and the last failure. Survives restarts (principle 5).
2. **Research tools** for the Director: `lookup` (wiki + game data, already built: 1207 game docs, 9138 wiki docs), a **recipe graph** from the game's crafting data (what makes X, where, with what), the **gear comparator** (`brain/item_stats.py`), and **map memory** (places, resource nodes and stations seen, lodestones; from the census and navmem).
3. **Curriculum** (Voyager): for an open goal ("level what you like"), the Director proposes the next achievable subgoal from current skills, gear, known resources and past failures, scored by value and feasibility.
4. **Executor bridge:** a subgoal runs as Controller turns with the subgoal as the "current task" in context, and the Controller reports done or failed. Done is decided by the success test on fresh state, never by the model's claim (principle 5).
5. **Replan on failure** (DEPS: describe → explain → plan), with an attempt cap. When stuck, the Controller asks Luis once, specifically (principle 8).
6. **Skill library** (Voyager, already scaffolded in `data/skills/<world>`): successful subgoal action sequences are saved and reused ("smelt iron bars at the base furnace").
7. **Interruptible:** Luis's chat preempts. The goal pauses and resumes. Progress reports at milestones (not on a timer): "Mining 52 → 55, 20 iron bars smelted".
8. **Budget:** Sonnet about 10–30 calls/hour (on subgoal boundaries), Haiku per step. State estimated cost per hour before the first long run.

**Acceptance ladder:**
1. "get a better pickaxe": mine ore → smelt → craft at a station → equip → compare stats. Dev server, then live.
2. "level Mining to N": a loop with re-stocking and food.
3. Open: "get better gear, level what you like" for 1 h without help; reported, interruptible.

## 5. Order
1. Speed fixes §2 and reliability §3 (in progress: broker, skills, spells agents).
2. Director + goal tree + success tests + research tools §4.1–4.5 (new agent, after the design review gate).
3. Curriculum + skill library reuse §4.3/4.6, then the acceptance ladder.

## Precedent
- PIANO / Project Sid: concurrent loops at different speeds (https://arxiv.org/abs/2411.00114).
- Voyager: curriculum, skill library, self-verification (https://arxiv.org/abs/2305.16291).
- DEPS: replanning (https://arxiv.org/abs/2302.01560).
- GITM: the LLM parameterises scripted skills (https://github.com/opengvlab/gitm).
- Mindcraft / MineCollab: tools and self-guided play; embodied collaboration is hard (https://arxiv.org/abs/2504.17950).
- ReAcTree: a tree of agent nodes per subgoal with working memory (AAMAS 2026, https://www.emergentmind.com/topics/reactree).
- HiMAC: planner/executor split for long horizons (https://arxiv.org/abs/2603.00977).
- Speculative actions for latency (https://arxiv.org/html/2510.04371v1).

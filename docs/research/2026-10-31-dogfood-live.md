# Dog-food live session, 2026-10-31: what Haiku sees vs what happened (TASK-0)

Dev world only: the client joined 127.0.0.1:7777 as ClaudeDev. The code was main HEAD 41fa4cc, deployed as-is. All times are UTC.

Evidence (gitignored, durable):
- `logs/dogfood-20261031/`: per-action run JSONs with a 2 s position and move-status trace plus log slices, the full dump of the 44 live prompts (`live_prompts.txt`), and the driver and timeline scripts.
- `logs/brain-live-20261031-201532-10852.jsonl`: the live brain session.
- `logs/client/client.log` (19:00–19:39), `client_io/events/vitals.jsonl`, the dev server log.

## 0. TL;DR

1. **The death loop reproduced live (19:16–19:23).**
   - The trigger was infrastructure, not the model. The dev-server **nav oracle** (`tools.nav_oracle serve`) and the client watchdog both stopped at about 19:06:08–11. This agent did not stop them, and nothing restarted them.
   - From then on, every long move ran the same cycle: `forward observed route proposed` → `memory connector not admitted: sweep_blocking; planning toward actual goal` → 38–40 s with **zero movement segments** → `failed timeout`.
   - Haiku was told a different, mis-categorised reason each time: `path_blocked … no closer than 62 m`, `nothing_in_range … saw no lexical candidate for 'water'` (after 0 m travelled), and `verification_failed: route unavailable: oracle_unavailable`.
   - It cycled collect_water → look → explore → go_to → go_to → collect_water. That took **14 Haiku calls and about 330k prompt tokens with 0 m moved**, while hydration hit 0 and HP fell 100 → 24.
   - I restarted the oracle at 19:22:57 (the same command the watchdog uses). The very next explore found water in 30 s, collect_water got 3 in 6 s, and he survived.
2. **The model was not the weak link.** Given the observations it received, Haiku's choices were mostly sensible: water first, look, then explore, boil water at a campfire, ask the player for a landmark. Every bad outcome traces to the body or harness telling it something false, stale or vague, or to code overruling or racing it.
3. **The gap is client → model, not server → client.** The dev server log shows nothing about Claude's movement, routing or survival (only EOS heartbeats, telemetry, station and save lines). The client mod log already knows the true cause of every failure. The model gets a lossy, sometimes wrong, summary of it.
4. **Movement is slow by construction.**
   - Following a remembered route with the Codex terrain checks runs at **0.8–1.1 m/s** (27 of 45 samples in `checking_terrain`). The oracle navmesh path runs at **4.0 m/s**.
   - go_to has a fixed 120 s deadline, so any memory-route trip over ~125 m times out "while progressing fine". The reply says only `timeout: movement deadline reached`, with no progress figure.
5. **Haiku has no idea where it is.**
   - The situation never states its position, region ("Temple Woods"), inside/outside the temple, or any named landmark.
   - The 514 landmarks in `data/places_26161880.json` never reach it. go_to "Doric" gives `unknown_target`, and `look` caps at 80 m.
   - So "head over to Zanik" ends in Haiku asking the player for a landmark, twice.

## 1. Setup and safety record

- **Boot** (`client_boot.ps1 -Release -Target dev`):
  - In world in 58 s: pick_char picked index 3 "ClaudeDev", then join_server target dev.
  - Verified in the game log: `19:00:33 Welcomed by server … LoadMap: 127.0.0.1/Game/Maps/World/L_World`.
  - Shockbyte is in `client_forbid_targets.txt`.
- **Commit charge** (CIM FreeVirtualMemory; limit 12,554 MB):

  | Time | Free commit | Notes |
  |---|---|---|
  | 18:58 | ~2,281 MB | client off; FreePhys 1,206 MB |
  | 19:01 | — | client up: committed 12.54 of 13.16 GB, FreePhys 614 MB, pages/s 122 |
  | 19:05 | **435 MB** | the low point (the coordinator's wall is 300 MB) |
  | 19:13 | 3,727 MB | something external freed ~3.3 GB |
  | before the brain | 3,668 MB | |
  | end, client stopped | 5,686 MB | |

  It never went under 300 MB.
- **Spend:**
  - Before: $0.0000 (0 calls today).
  - After: **$0.0381, 44 calls**: all Haiku 5.5, 43 controller plus 1 warm-up, **0 Sonnet**, Director off.
  - Tokens: 1,098k prompt (871k cache reads, 115k cache writes) vs 7.7k completion.
  - The brain had `DW_SPEND_CAP_USD=1.50` and was stopped by me at 19:33:3x. Its last prompt was killed in flight.
- **What I changed:**
  - No source edits and no commits.
  - I restarted the nav oracle at 19:22:57 with the watchdog's exact command (`.venv python -u -m tools.nav_oracle serve >> logs\nav_oracle.log`). **It is still running.** The client watchdog is still dead; I did not restart it.
  - I sent 3 test chat lines as "Tester" through the dev server mod's `speech_direct` (prove passed: `patched=ClaudeDev==control`).
  - The client was stopped with `stop_client.ps1 -Hold`, which wrote `logs/client.stopped`. I also wrote a note to `logs/client.hold`, because the boot's `-Release` had removed the stale one.
  - ClaudeDev was left at Zanik [265.5, 1824.3, −41.2].
- **Brain run:** `start_brain.ps1 -Body client -World dev_director`, with `DW_PLAYER_NAME=Tester` and `DW_DIRECTOR=0`. That world folder still carries Codex's parked board tasks (070540ab and others); with the Director off they never ran.

## 2. Direct drive (no LLM), side by side

Each row is one bridge call on the debug channel, sampled every 2 s.

| # | Call (start → target) | What the model would get (reply) | What really happened (client log / trace) | Gap |
|---|---|---|---|---|
| a1 19:03:4x | `go_to "Doric"` (58 m) | `unknown_target / target_not_visible` in 10 s | Body resolves only perceived ids, graves, players, coordinates. `get_state.places=[]`, `not_implemented:["places"]` | The 514 landmarks in data/places_*.json are never resolvable |
| a2 19:04:07 | `go_to [109.08,1846.32,-31.31]` (58 m) | `verification_failed: walking terrain: target_support_mismatch`, horizontal error 22.3 m | Memory route (39 pts) at ~0.9 m/s. Stalled at [87.1,1838.3], 22 m short. Then `memory connector not admitted: scan_timeout` → nav → refused | A guard refusal reported in terrain jargon. It does not say "a safety check refused the last 22 m", nor whether retrying makes sense |
| reflex | (fed reflex, 19:03:43 on) | `reflex_inventory_read_unknown: inventory could not be read completely` every ~60 s | The truth: **no water carried at all** (inventory dump) | The partial read-status (83f0ce3) turns "no water" into "unknown" |
| a3 19:05:5x | `consume "drink"` | `not_in_inventory: "I don't have anything to drink on me."` | True | none |
| a4 19:06:15 | `collect_water 2` from [88,1838] | ok, 2 Dirty Water, 54 s | Learned shore point (worked 61×); memory route, ~1 m/s | none (works when started outside the temple) |
| a5 19:07:24 | `consume "Dirty Water"` | ok, hydration 22.2 → 32.2 | Hotbar slot use | none. **But the drain is ~2.8–5.4 %/min** (30.5 → 27.7 in 30 s standing still), so 1 Dirty Water ≈ 2–3 min of life |
| a6 19:07:47 | `gather stone 2` | ok, +4, 18 s | 8 swings, 7 hits, node broken | none |
| a7 19:08:21 | `go_to Zanik [266.88,1823.95,-41.26]` (215 m) | `timeout: movement deadline reached` | **128 m covered in 120 s, 1.07 m/s**, every sample verdict "ok". 87-point memory route, `spr=false spd=0` on every segment (stop-start) | Progress was steady. Haiku is told "failed" with no "128 m done, 125 m left, keep going" |
| a8 19:10:43 | `go_to temple lodestone [50.65,1890.26,-34.88]` from [149,1869] (100 m) | ok, 108 s | Memory route (49 pts), 1.08 m/s, `memory: self route r154 added` | none, but slow |
| a9 19:34:15 | the same target from [102.5,1867.7] (after the brain) | ok, 87 s | memory → nav near the end, 0.8 m/s | Same target **failed for Haiku from the pond side at 19:28** (`sweep_blocking`, 40.9 m short). The outcome depends on the start point, and the model can't see that |
| a10 19:36:12 | Zanik again, oracle alive, from the lodestone | leg 1: `timeout`, plus `route_feedback.route_endpoint [83.2,1873.9]` | leg 1: memory route, **99 m / 120 s = 0.83 m/s**, 27/45 samples `checking_terrain`. The chosen remembered route **ends 137 m from the goal** | Route choice picks a prefix that leads nowhere, and the deadline hides it |
| | | leg 2: ok | leg 2: **nav source, 136 m in 34 s = 4.0 m/s**, arrived | The navmesh path is 5× faster than the guarded memory follower |

Boot oddity: at 19:00:52, 3 s after the pawn appeared, the body ran an unrequested `go_to d=1562cm src=nav` and moved 15 m. No log line names who asked for it.

## 3. Live brain: three chat lines plus autonomous reviews

Calls per episode, from the `episode_id` groups:

| Episode | Calls | Prompt tokens | Tool results |
|---|---|---|---|
| review-0001 19:16:11 | 1 | 20k | — |
| **chat-0002 "you look parched mate, sort yourself out" 19:16:13** | 7 | 163k | collect_water− look+ explore− go_to− go_to− collect_water− |
| review-0003 19:22:32 | 7 | 171k | consume− move_item+ consume+ look+ lodestones+ explore+ collect_water+ |
| **chat-0004 "head over to Zanik … meet you there" 19:24:00** | 4 | 98k | look+ lookup+ |
| review-0005 19:25:08 | 6 | 170k | look+ look+ craft+ consume− inventory+ |
| **chat-0006 "chop a few logs then bring them back to the lodestone in the temple" 19:26:38** | 7 | 169k | gather+ lodestones+ go_to− go_to− teleport− |
| review-0007 19:31:37 | 7 | 197k | look+ look+ collect_water+ craft+ consume− consume− look+ explore+ |
| review-0008 19:33:18 | 5 | 96k | look+ explore− go_to+ consume+ look+ (killed) |

**5 of the 8 episodes, 26 of the 44 calls, were autonomous `situation_review`s.** No player spoke in them.

Per call: the system prompt is 11.3k chars, plus 48 tool schemas at 29k chars, plus a user state of 26–30k chars. Inside a chain this grows to 61k chars, about 20k → 33k prompt tokens. The ratio of prompt to completion tokens is about 143 to 1.

### 3a. Line 1, "you look parched mate": the death loop

- **Situation given** (19:16:13): `water: parched [14%]`, `carried: Dirty Water x1 (hotbar)` (there was none left by then), `remembered: Water Volume seen 4406 min ago, 161 m NE`. Nothing about where it is.
- **Haiku's choices:**
  1. collect_water.
  2. On failure: look water (radius 120 → `invalid_args: 120 is greater than the maximum of 80`) → look 80.
  3. `explore water` + say "water spot's blocked off, looking for another one".
  4. go_to the second water volume → go_to the far one.
  5. collect_water again.
  6. say "hydration's nearly gone … got any drink on you?"

  Each step was rational on what it was told.
- **What really happened** (`client.log`): see the table below. The client log never shows a physical block in this window. Every failure is the same planner stall after the memory-connector refusal. That stall is consistent with the oracle being gone (move.lua:18 "required before long-trip input", :513-521 `oracle_unavailable`).

  | Time | Client log |
  |---|---|
  | 19:16:16 | `forward observed route proposed (41 points)`; then walking, 84 → 62 m to the water |
  | 19:16:45 | `memory connector not admitted: sweep_blocking; planning toward actual goal` |
  | 19:16:45–19:17:10 | no movement for 25 s → no-progress watchdog → `path_blocked` |
  | 19:17:15 → 19:20:35 (explore) | the same refusal, then a 38 s stall, then `failed timeout`, **6 times**. Trail stuck at [77.1,1860.5], `travelled_m: 0` → reported as `nothing_in_range` |
  | 19:20:38, 19:21:21 (go_to ×2) | the same stall, then `route unavailable: oracle_unavailable` |
- **What the code added on top:**
  - **19:16:13, a race:** the autonomous review's collect_water was interrupted by the arriving chat (`bridge_wait_interrupted … why: addressed chat`). It became `state_unavailable`, and **code said in chat "I can't collect water yet: I can't read the game state."** That is false.
  - **19:22:31:** the chain hit its budget and deadline. **Code said "I couldn't finish the earlier request before time ran out."** and then read the raw failure detail aloud.
  - **19:23:22:** 14 queued body events were delivered only after the chain ended. They included `reflex_no_hotbar_food: food only in the bag; move it to the hotbar` (first raised 19:18:08) and `vitals_low hydration 11.2 has_drink=false`. Haiku never saw these while it was looping.
- **Recovery:** the oracle came back at 19:22:57. Then:
  - 19:22:43 explore → found a Water Volume 40 m away at 19:23:14;
  - 19:23:16 collect_water 3 → ok in 6 s;
  - 19:23:23 the floor reflex drank at hydration 0.0 with HP 24 (`status:["dehydration"]` damage events).

### 3b. Line 2, "head over to Zanik": no semantic map

- Haiku: `look about Zanik r80` (nothing) → `lookup Zanik` (wiki: "location: Temple Woods - Bramblemead Valley …", no coordinates) → say "no sign of Zanik near me … give me a landmark".
- The places file has Zanik at [266.88,1823.95,-41.26], 215 m away. Direct go_to reached it in 2 legs (a10).
- Then `talk_only_check`: "You replied without calling any tool…" cost one extra call, and Haiku gave an empty answer.
- 19:25:08, autonomous review: the same Zanik look plus `look Tester`, and the **same question asked again**. Then a good self-directed fix:
  - `craft Clean Water @ campfire` → ok;
  - `consume Clean Water` → `not_in_inventory`, because **the reflex had drunk it within a second of the craft finishing**;
  - inventory → private note "Hydration's back up to about 38% … went down fine" (correct), and it chose silence;
  - **code then said the failure detail aloud anyway**: "I don't have any Clean Water on me… (Water Rune isn't something I can eat or drink.)".

### 3c. Line 3, "chop a few logs then bring them back to the lodestone in the temple"

- gather Ash ×5: ok in 44 s.
- `lodestones` → go_to the lodestone at 19:27:29 → **`busy: movement owner token required`**. The cause: the fed reflex ate Redberries at 19:27:26, 1 s after gather released, and its 4 s consumable verification held movement. Haiku retried the identical call.
- The retry gave `verification_failed: walking terrain: sweep_blocking`, partial, 40.9 m short, 4 m vertical error.
- Haiku then tried `teleport` to the lodestone the tool had marked **`"here": true` at `distance: 68`** → `already_there: That's the lodestone I'm next to`. The tool data contradicts itself.
- Finally Haiku said "route to the temple lodestone keeps getting blocked, can you guide me or come meet me?". Reasonable.

### 3d. Silent drops of survival alarms (19:28–19:31)

- `vitals_low hydration 16.3 (max now 75.0) has_drink=false` → triage `decide` → **`situation_stale: "fixed before it was voiced"`**, although nothing had fixed it. This happened 4 times.
- The max dropping 100 → 75 (Soulscourge from Dirty Water) never reached the model. The prompts contain 0 mentions of `dehydration`, damage events or the max-stat drop. Soulscourge appears only inside the reflex's "held back" reason string.
- A periodic review (19:31:37, "worse: false") did eventually trigger collect_water ×3 → craft Clean Water ×3. Then consume → `busy: consumable verification pending` **twice, 1 s apart**, ~30k tokens each, because the reflex was drinking.

## 4. The no-progress loop: mechanism, trigger and history

**Trigger:**
1. A dependency fails silently (the nav oracle; on Shockbyte there is **no oracle at all**, because it is a dev-server crutch).
2. Or a guard refuses (sweep_blocking, target_support_mismatch, owner token).
3. Or a reflex contends for the same resource.

**Mechanism:**
- The body stalls, then reports a *generic* failure category.
- The category often contradicts the evidence: `nothing_in_range` after 0 m travelled, `path_blocked` with no obstacle, `timeout` while progressing.
- The detail is jargon (`sweep_blocking`, `oracle_unavailable`, `movement owner token required`).
- The model cannot tell "retry", "wait 4 s", "this will never work from here" and "the infrastructure is down" apart, so it tries the next plausible tool.
- Each failed turn costs ~25–33k prompt tokens.
- The chain ends on a turn budget or deadline with a canned line. Then the next `situation_review` (vitals still falling) restarts the same search from scratch, because "progress since last call" is not represented anywhere.

**History** (my sweep of `logs/brain-live-2026102[89]-*` and `-20261030-*`): the same pattern shows across these sessions.

| | Oct 28–29 | Oct 30 |
|---|---|---|
| LLM calls (controller logs) | 607 | 185 |
| Movement-type results | 121 | 44 |
| Movement ok | **23 (19%)** | **8 (18%)** |

Top failures:
- Oct 28–29: `go_to route_ended_before_goal` 22, `route unavailable: no_path` 13, **`explore … saw nothing matching 'water'` 12**, `interact path_blocked Redberries` 11, `consume busy` 6, `companion_down: character is dead` 4.
- Oct 30: `route_ended_before_goal` 14, `consume busy` 8, `movement owner token required` 6.
- The 199-call session at 20261028-223001: look ok 31, go_to verification_failed 13, explore nothing_in_range 9, of 103 chat decisions.

## 5. What the client receives, and what reaches the model

| Category (source) | Captured by the client mod | Reaches Haiku | Dropped or distorted |
|---|---|---|---|
| Replicated actors: creatures, NPCs, items, resource nodes, foliage, stations, water volumes, lodestones, graves (`sense`/census r30, `look` ≤ 80 m) | yes, with ids, positions, class, prompt verb | situation lists creatures (odds), need-fixes and graves; look/census on demand | everything beyond 80 m; lexical-only matching (`explore redberries` matched "Redberry Seeds"); "remembered" water ranked by age wrong (a 4,406 min old 161 m hit shown instead of the pond used 39 s earlier) |
| Own pawn: position, yaw, speed, movement mode, floor | yes (`me`, `move_status`: status, source, speed, stuck_n, progress {dist, best_dist, verdict}) | **position only inside tool results**; body_status "standing still for 38 s" | no position, region or landmark in the situation; movement source and speed and the "checking terrain" share never; `move_status.progress` (verdict ok, dist) thrown away on timeout |
| Static map knowledge: `data/places_26161880.json` (6 provinces, 31 regions with polygons, 514 landmarks) | on disk; `places.lua` exists | **nothing** (`not_implemented:["places"]`) | named-place go_to, "where am I", bearings |
| Own stats: HP, hydration, sustenance, endurance, stamina, max values | yes (`vitals` every 30 s plus OnRep health) | percent plus feel word plus "empty in ~N min" (good) | **max-stat changes** (100 → 75); `vitals_low` alarms dropped as "fixed before it was voiced" |
| Status effects and damage (`DamageComponent` multicasts, `OnRep_FatalDamageInfo`, gameplay effects) | yes (`status:["dehydration"]`, amounts, instigator) | not as such | "you are taking dehydration damage, −2 HP / 30 s"; the Soulscourge stack |
| Inventory and equipment (hotbar, bag, loadout, worn; instances) | yes | yes, but every count is "at least" and "Inventory read: carried partial" | the read-status gaps cause the reflex to say "unknown" instead of "no water" |
| Chat (`Client_ReceiveChatMessage`, player events) | yes | yes (last lines with ago_s) | the code's own canned lines appear in history as if Claude said them |
| Combat (AI attack/impact, block/parry, AI actions) | yes (hooks registered, 6,371 dispatches) | odds per creature only | no recent-hit summary |
| Crafting results (`Client_OnCraftingResultHandler`) | yes | via craft results | none |
| Server-side queries: navmesh via the dev-server oracle (`FindPathToLocationSynchronously`) | dev only | only as `oracle_unavailable` jargon in failure details | its health (down since 19:06) never stated; **absent on Shockbyte** |
| Client traces: terrain columns, ledges, water probes | yes (`terrain`, `move`, `traversal`) | a terrain-history blob in older prompts; `terrain` tool | the "why I stopped" in plain words |
| UI state: open screens, modal gates | yes (`reflex_blocked: the Processing + Inventory screen is open`) | only as delayed recent_activity | live "a screen is open" state |
| Reflex activity (eat/drink/hold-back) | yes | `recent_activity`, but **batched and delivered after chains end** | timely "the reflex just drank X" |
| Time, quests, skills, spells | yes | yes (spells 9.4k chars on every call) | the opposite problem: too much |
| Game client log (engine) and dev server log | yes | no | nothing there about movement or survival; not worth surfacing |

## 6. How to see more, and stop the loop

These are ordered by leverage, and each is a quick live-testable change. None of them is a phrase→skill map. All of them are code *informing* the model truthfully, in line with Luis's rules.

1. **A truthful outcome contract on every failure** (body side, about 1 helper):
   - `cause`: one of `infra_down(dep)`, `guard_refused(which, evidence)`, `physically_blocked(trace)`, `deadline_while_progressing`, `contended(owner, eta_s)`, `not_found(searched_m)`;
   - `progress`: `{start_m, end_m, travelled_m, rate_mps}`;
   - `retry`: `{same_call_useful: bool, after_s}`.

   Examples:
   - a7 becomes "walked 128 m at 1.1 m/s, 125 m left; go_to again continues".
   - explore becomes "travelled 0 m: the navigation helper is down".

   This removes the mis-categorised `nothing_in_range` and `path_blocked`. Precedent: Voyager feeds execution errors plus inventory and nearby-entity deltas back into the next prompt.
2. **Dependency health in `body_status`:** "navigation helper DOWN since 19:06: trips over ~10 m will stall". Also restart it (the watchdog died too, and nothing supervises the watchdog; the project rule says use NSSM/WinSW).
3. **Progress since the last call** (brain side): the delta of position, vitals, inventory and distance-to-goal since the previous model call, plus a stagnation counter ("3 calls, 0 m moved, hydration −9").
4. **Loop and stagnation detector:**
   - Reuse the published thresholds: OpenHands StuckDetector flags the same action and same error ≥ 3 times, and alternating pairs ≥ 6 cycles; LoopGuard's rule is repetition *plus* stagnant state; LoopBuster uses a stasis limit.
   - On a hit, tell the model the pattern and the true cause, and escalate to asking the player. Never silence it, and never add a canned line.
   - Today's chain budget and deadline stop the turn but not the *next* review.
5. **Where-am-I and a named-place map:**
   - A situation line such as "Temple Woods (Brynmoor), inside the temple, 2 m from the temple lodestone; named nearby: Wise Old Man 6 m S, Doric 58 m SE, Vannaka 128 m SE, Zanik 215 m E".
   - go_to accepts a landmark name, resolved to its nearest instance from `data/places_*.json` plus learned places.
   - Precedent: Mindcraft's `!stats` (location) and `!nearbyBlocks` queries; Voyager's observation (biome, position, nearby blocks and entities); MEM2EGO, MapNav and topological-map-as-text work.
   - A semantic map is needed: a text map from data we already have. A perception model is not needed: the client already has exact actor data, and the problem is what we pass on.
6. **Movement summary in every move result:** source mix, speed, and the reason it stopped in plain words. Also remove the fixed 120 s deadline while progress is "ok". Measured: memory follower 0.8–1.1 m/s vs navmesh 4.0 m/s, so the guard layers (walk_guard, sampled_ground_walk, connector admission) are the cost. This matches the handover's delete list.
7. **Reflex ↔ model arbitration:**
   - The model's `consume X` after the reflex consumed X should report the reflex's success ("your reflex just drank it: 13 → 38").
   - `busy` should name the owner and the time left ("reflex eating, 3 s").
   - Reflex events should go into the *current* chain, not be batched until after it.
8. **Stop code from speaking for the model:**
   - Delete the canned lines ("I can't read the game state", "couldn't finish … before time ran out").
   - Stop auto-speaking failure details after the model chose silence.
   - Fix the interrupt race that produces `state_unavailable`.
9. **Fix the false or stale data:**
   - lodestones `here:true` at 40–68 m;
   - `situation_stale` dropping unfixed vitals;
   - the stale Oct-30 note `state:body_link "…at 0 water, 1% HP"`, still injected;
   - "remembered" water sorted by age wrongly;
   - inventory "partial" making the reflex say "unknown" instead of "no water".
10. **A prompt diet:** 48 tools (29k chars), 9.4k chars of spells and 8,764-item graves on every call. The ratio of prompt to completion tokens is ~143:1. Trim to what the current task needs. The cost is low today ($0.0381 for 44 calls), but the context is noise that hides items 1–5.

**On the goal** (Luis asked): "temple 200 m round trip" measured the guard stack, not play. The dev world drains survival at ~3–5 %/min, and the only water is dirty, so survival is a treadmill that dominates every session. A better near-term goal: **an hour of self-directed play on dev with zero silent failures.** Every failure carries a true cause; every chain either progresses or tells the player why within 2 calls; there are no deaths from thirst; and it is measured by stagnation-detector hits per hour and movement success above 80%.

## 7. Search record (search-before-building)

- **Loop detection:** found OpenHands StuckDetector (thresholds above), LoopGuard and loopguard-runtime (repetition plus stagnation, then a graded warn → replan → stop policy), agent-loop-guard, CrewAI LoopDetector PR #4684 (exact, fuzzy and cyclic), and LoopBuster (spend cap plus stasis limit). **Nothing game-specific turned up.** The generic pattern applies: action repetition AND unchanged world state.
- **Observation design:** the Voyager paper (2305.16291) puts inventory, equipment, nearby blocks and entities, biome, position, time and health in the observation, and feeds execution errors back. For Mindcraft, the `!stats` and `!nearbyBlocks` query commands (as quoted by the Lemonade and Novita docs) separate queries from actions. **I did not find the full `!nearbyBlocks` output format.**
- **Semantic maps as text for LLM agents:** MEM2EGO (2502.14254), MapNav (2502.13451), topological map memory (2405.10620), and an embodied-navigation survey (2311.00530). All are academic; **none is for games.**
- The PUBG Ally and NVIDIA ACE design was already covered in CLAUDE.md §10 and not re-searched. The parallel research agent owns the wider survey.

Sources: [OpenHands stuck detector](https://docs.openhands.dev/sdk/guides/agent-stuck-detector) · [loopguard-runtime](https://pypi.org/project/loopguard-runtime/) · [agent-loop-guard](https://github.com/ArkNill/agent-loop-guard) · [CrewAI LoopDetector PR](https://github.com/crewAIInc/crewAI/pull/4684) · [LoopBuster](https://github.com/liuchunwei732-cmyk/loopbuster/wiki) · [Voyager](https://arxiv.org/abs/2305.16291) · [Mindcraft prompt notes (Lemonade)](https://lemonade-server.ai/docs/server/apps/mindcraft) · [MINDcraft guide (Novita)](https://novita.ai/blog/mindcraft-unleashing-novita-ai-llm-api-in-minecraft/) · [MEM2EGO](https://www.arxiv.org/pdf/2502.14254) · [MapNav](https://web3.arxiv.org/pdf/2502.13451v1) · [Topological map memory](https://www.arxiv.org/pdf/2405.10620) · [Embodied navigation survey](https://arxiv.org/pdf/2311.00530)

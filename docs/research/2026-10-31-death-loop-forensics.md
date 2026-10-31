# Death-loop forensics: why the agent burns tokens without progress, and what Haiku sees vs what happened (2026-10-31)

Read-only analysis (TASK-0, HANDOVER-2026-10-31). No code was changed, the game was not touched and no model calls were made.

- **Data:**
  - 83 `logs/brain-live-*.jsonl` sessions (10-25 to 10-30) and the daily bridge logs `logs/brain-2026102*.jsonl`;
  - `logs/client/client.log` (mover trace) and `logs/client/mod_*.jsonl`;
  - `client_io/events/vitals.jsonl` (covers 10-30 00:22Z onwards only);
  - the a914 and a907 native samples (`logs/recovery/temple-repeat-a914/`, `logs/recovery/model-choice-full-a907/actual-native-route.jsonl`; one sample per 1.3–1.5 s, including the arbiter owner token);
  - the dev-server log `C:\GameServers\Dragonwilds\RSDragonwilds\Saved\Logs\RSDragonwilds.log` and the client UE logs `%LOCALAPPDATA%\RSDragonwilds\Saved\Logs\`;
  - `logs/nav_oracle.log`.
- **Times:** all times are UTC.
- **Costs:** computed with `tools/spend.py:price` and `data/model_prices.json`.
- **Scripts:** in the session scratchpad (Appendix A), not in the repo.

---

## 0. Answer in one paragraph

The loop is not one bug. It is a **closed cycle of four things**, and each one feeds the next:

1. **The body stops moving.** Since 10-28 the movement layer *refuses* or *crawls* instead of walking:
   - route-authority refusals in ~10 s with ~0–6 m moved;
   - guarded walking at **1.1 m/s** against a 120 s deadline;
   - "busy" refusals caused by the body's own eat/drink reflex.
2. **It reports the stop in words that are not true about the world.** The model sees `route unavailable: route_ended_before_goal`, `walking terrain: sweep_blocking`, `busy: movement owner token required` and a 6 KB stale terrain blob. It never sees "the walkable map ends 3.7 m below you", "you were eating" or "that route took you away from the goal".
3. **Haiku retries or invents a physical cause.** Examples: "too steep", "stalling by a wall", "not off a cliff I think", "check my movement lock". Then it escalates (`report_step blocked`).
4. **The Director (Sonnet) replans around the invented cause.** It writes new waypoints or a "Release the stuck movement" step. That costs 3.9–6.4 calls of ~30k prompt tokens per accepted decision, and at the time a 20 calls/hour window parked the job.

None of the replans can change step 1, so the cycle repeats until a bound (turns, budget, 900 s) ends it.

On 10-29/30, **Sonnet was 95–97 % of spend** and the cost per completed board step rose **5×** (from $0.08 to $0.42–0.45).

---

## 1. Episodes

### E1 — Good contrast: Director run 1, 10-26 07:46–07:53 (`brain-live-20261026-084634-10200.jsonl`)

The job was "chop 5 ash logs, then drop them".

- **Cost:** 6.7 min, 38 Haiku and 7 Sonnet calls, **$0.137**.
- **Actions:** world actions 17 ok and 5 failed; 6 board steps done.
- **Prompt sizes:** Haiku p50 16.3k tokens, Sonnet p50 8.8k.
- **Speed:** step-to-step gaps were p50 3 s (DISCOVERIES "Director live smoke, run 1").

| t | call | result | next decision |
|---|---|---|---|
| 07:47:17 | Haiku `explore{about: ash tree}` | FAIL `already_in_sight` "Ash Stump is already in sight (1.13 m, id …)" | 07:47:20 `gather ash 5` |
| 07:47:26 | `gather` | FAIL `wrong_tool` "I tried to take out my Stone Logging Axe but it didn't come out" | 07:47:29 `inventory` |
| 07:47:31 | `equip ITEM_Logging_Axe_Stone` + `gather 4` | OK, "Got 5 ash" | 07:48:12 `drop 5` → `report_step done` |
| 07:49:07 | step failed "no progress: Ash Logs +0/5" | Director replan in 3 Sonnet calls ("trees here depleted, explore further") | worked at 07:50:28 |

**Why it worked:** every failure reason was a *world fact* the model could act on (an object at 1.13 m; the axe not in hand). Recovery took one turn. The prompts held about 3 KB of situation and no blobs. Speech still had a known bug (it said "EMPTY" ×3).

The only loop here was an **unpassable verifier**: `gained 5` and `lost 5` read the same net delta, so the step could never pass. That was fixed in `director.net_conflicts`.

### E2 — Live with Luis, 10-28 21:30–22:12 (`brain-live-20261028-223001-12804.jsonl`, world goochlands_guest)

- **Cost:** 42.6 min, **179 Haiku and 20 Sonnet calls, $0.52**.
- **Movement:** go_to succeeded 3 times out of 20; Haiku was nudged for "no tool" 29 times.

| t | Haiku saw | what really happened (client.log) | what Claude said |
|---|---|---|---|
| 21:31:03, 21:31:06 | go_to Zezima → `verification_failed`, "route unavailable: invalid_route", then "…route_ended_before_goal" (0–3 s each) | `local plan #1 (route_observation)`, then `move: failed verification_failed` at once (client.log 30966–30969). The body did not move. Luis was up a slope; the follow trail had worked seconds earlier (`trail=nil/52`). | "still stuck, the ground between us is too steep for a route" (invented). Luis: "yeah you are being an idiot walk to me". |
| 21:32:20, 21:32:27 | the same two refusals | the same | code: "Sorry, I couldn't walk somewhere." ×2. Luis: "STOP GOING AROUND THE SIIIIIIDE". |
| 22:03:56–22:04:06 | `explore{goblin}` → `nothing_in_range`, then an observation with **health 0.0** at z **−70.39** (from −36…−41); then only "Recent: you died 9 s ago and respawned". The combat summary said `damage_taken=0`. | Explore leg: `local plan #1 (wall_ahead)` at (60403,186910,−3990), then `move: failed companion_down` (client.log 32143–32146). He **fell ~30 m**. `sense.lua:868` emits a `fatal` event with `killed_by` to vitals.jsonl; **no brain code reads it** (grep of `brain/` for killed_by/fatal: none). | "got knocked out… no idea what hit me… not off a cliff I think" (false). Luis: "did you walk off a cliff?" |
| 22:04:29–22:08:25 | go_to grave ×3 → "route unavailable: no_path"; explore water ×3 → nothing_in_range | respawned at the temple (56,1883); the grave was 559 m away | Luis: "use your brain" |

### E3 — The temple-ledge loop, 10-30 02:22:54–02:28:07 (`brain-live-20261030-032253-13032.jsonl`)

- **Cost:** 5.2 min, 15 Haiku and 9 Sonnet calls, **$0.41 (Sonnet 96 %)**.
- **Movement:** 10 go_to failures, 0 successes. The body stayed within ~3 m of [58, 1901, −31.15] the whole time.

| t | call (who) | result (Haiku's view) | reality (client.log 40421–40573) |
|---|---|---|---|
| 02:22:54–02:23:20 | Sonnet ×3: plan | 3-step plan | – |
| 02:23:45 | go_to lodestone [50.65, 1890.26, −34.88] (Haiku) | `route unavailable: route_ended_before_goal` | `local plan failed: walls everywhere`. Knee-height probes from z −31.15 toward the −32.05 floor below all read as blocked. **He is on the temple upper level, 3.7 m above the lodestone floor.** The ramp a player can walk is not on the NPC navmesh (DISCOVERIES "Temple ramp"). |
| 02:23:47, 02:23:49 | consume Clean Water, then Bread | `busy: consumable verification pending` ×2 | `arbiter: granted skill:consume … preempting fed:drink` → `released (busy)`: it collided with the fed reflex |
| 02:23:59, 02:24:11 | go_to the lodestone actor, then board go_to | the same refusal | the same "walls everywhere" |
| 02:24:15 | `run_skill walk_to_location` | code: "Sorry, I can't walk to location yet." | – |
| 02:24:16–02:24:47 | step failed → **Sonnet ×3 replan** ("walk down in short hops") | 3 hop go_tos → `invalid_route` ×3 | `stuck n=1..3`, `backtrack`, `bug2 wall-following`; moved 0–4 cm per window |
| 02:26:25 | report_step blocked + say "keeps stalling by a wall here, need you to clear a path" | – | there is no wall: it is a drop |
| 02:26:25–02:26:54 | **Sonnet ×3 replan** ("route through the Wise Old Man") | go_to → route_ended_before_goal; `explore{ramp or slope going down}` → nothing_in_range (explore is lexical: no actor is called "ramp") | – |
| 02:27:54 | `cast Windstep` + go_to | the cast is OK; the go_to is refused, because go_to has no "use the Windstep" path | – |
| 02:28:07 | pause_board; say "can you walk round or clear a path?" | – | – |

**The loop:** refusal → a variant target → the same refusal → Director replan → a new variant. The replans could not help, because the refusal does not depend on the target: every target off the navmesh's connected component is refused.

**Per-prompt payload:** each prompt carried ~40 raw `barrier_samples` / `line_hit_candidate` coordinates marked "capsule_clearance unknown, connectivity unknown, not movement authority".

### E4 — a907, the one counted success, 10-30 04:24–04:33 (`brain-live-20261030-052411-8628.jsonl`)

- **Cost:** 23 Haiku and 16 Sonnet calls, **$0.564**.
- **Movement:** go_to succeeded 2 times out of 9; 4 movement `busy` refusals.

| t | event | detail |
|---|---|---|
| 04:24:39–04:25:04 | drink step | `consume` in_bag → move_item inventory_full → drop seeds → move_item → consume `busy` ×2 → ok. The chain hit its 4-turn cap. |
| 04:25:26 → 04:27:27 | board go_to [182, 1815] | **timeout after 120 s** at [101.6, 1803.1] |
| 04:27:28 (reflex) | fed reflex eats (stat 39.7 < 40) | `vitals.jsonl:1050` |
| 04:27:31 | Haiku retries go_to | **busy, "movement owner token required"**. Code says in chat: "Sorry, I couldn't walk somewhere: movement owner token required." |
| 04:27:35 → 04:27:49 | board run 2 go_to | **ok in 14 s** |
| 04:29:15 | go_to → `walking terrain: sweep_blocking` at [226.05, 1790.0] | that point is already **202 m** from the lodestone, so the checkpoint passed |
| 04:29:17, 04:29:20 | go_to back ×2 | busy ×2 (reflex drink at 04:29:16, `vitals.jsonl:1056`) |
| 04:29:24 → 04:31:25 | go_to back | timeout after 120 s at [80.0, 1859.1] |
| 04:31:27 | go_to | busy (reflex eat at 04:31:27, `vitals.jsonl:1062`) |
| 04:31:30 | report_step blocked; say "my walk keeps failing with a busy error… can you restart my link" | – |
| 04:31:31–04:31:57 | **Sonnet ×5 replan** | first step "Release movement and stand still", which is a non-existent fault. Then advisory → empty → repair. |
| 04:32:00 | Haiku, woken by situation_review, go_to [51, 1890] | ok in 37 s → job done 04:33:05 |
| 04:33:12 | Haiku to the player | "temple walk test isn't done yet, **my walks only got about 40m out**". False: the board recorded 202 m. No trip summary exists anywhere in the prompt. |

### E5 — a914, the failed repeat, 10-30 05:25:27–05:40:29 (`brain-live-20261030-062527-9232.jsonl` and `logs/recovery/temple-repeat-a914/`)

- **Calls:** 900 s bound, **17 Haiku and 16 Sonnet calls**.
- **Tokens and cost:** 984k prompt tokens, **$0.547** (Sonnet $0.521).
- **Time:** **515 s in waiting_budget**; the first movement started at **+407 s**; total movement time was 342 s.
- **Outcome:** 0 of 1 trips.

| UTC | +s | who / call | what Haiku/Sonnet was told | what really happened |
|---|---|---|---|---|
| 05:25:29–05:26:08 | 0–39 | Sonnet ×5 (plan) | research ×2 → "Research is over" → "no JSON object" → repair → "required checkpoints cannot belong to loops" → repair | The 5th answer was valid but discarded: the dispatch restarted at 05:26:08 (`planning-advisory-replay.json`). ~137k prompt tokens were lost. |
| 05:26:08–05:26:28 | 39–59 | Sonnet ×3 | plan accepted (3 checkpoints) | – |
| 05:26:29 | 60 | board | `waiting_budget` | The 20/h window still held a907's 16 calls (04:24–04:33). It reopened at 05:31:58, exactly one hour after a907's calls. **329 s idle.** |
| 05:26:29–05:31:43 | 60–375 | Haiku ×5 | woken by a notice and by situation_review (sustenance 50 → 48 %) | 1 say, 4 no-ops, ~24k prompt tokens each |
| 05:31:58–05:32:15 | 390–407 | Sonnet ×3 (prepare) | – | – |
| 05:32:16 → 05:34:10 | 408–522 | board first_call go_to [182.12, 1814.69, −28.78] | `verification_failed`; body_status "walking terrain: sweep_blocking"; 76.9 m short | `forward observed route proposed (90 points)`, src=memory, **1.08 m/s, sprint off**. Then nav at 0.99 m/s, then `local plan (wall_ahead)`, then the walk-guard sweep stopped it at [105.39, 1819.87] (client.log 42964–43086; native samples). |
| 05:34:10 | – | fed reflex | (not shown) | Eats Seared Anchovies. The stat was 35.4, below the 40 % threshold since mid-walk, so the reflex had been waiting for the mover to let go. **Arbiter owner token 6 at 05:34:10.9–05:34:13.7** (native samples). |
| 05:34:12 | 523 | Haiku: go_to the same target | 0.2 s → `busy`, "movement owner token required" | **It was the reflex eating**, not a stuck lock |
| 05:34:15 | 527 | Haiku: run_skill walk_to_location | code says in chat: "Sorry, I couldn't walk somewhere: movement owner token required." | – |
| 05:34:18 → 05:34:30 | 531–543 | board run 2 go_to | ok | src=nav, **sprint, 6.83 m/s: 77 m in 11 s** |
| 05:34:34 → 05:36:34 | 547–667 | board first_call go_to [250, 1790, −28] | `timeout`, "movement deadline reached", at [136.68, 1869.76] | Memory prefix r152 (89 points) at 1.10 m/s. **Goal distance went 73 → 157 → 140 m: he walked away from the goal for 2 minutes.** |
| 05:36:39 | 671 | Haiku: consume + go_to | consume busy ("consumable verification pending") → retry ok | – |
| 05:36:44 | 677 | Haiku: go_to [250, 1790, −28] | 0.2 s busy | **Reflex eat (owner 12, 05:36:42.7–05:36:45.5; `vitals.jsonl:1118`)** |
| 05:36:47 | 679 | Haiku: report_step blocked, "Movement needs resetting or a different route"; say "can you check my movement lock or nudge me somewhere?" | – | a false diagnosis, shown to the player |
| 05:36:48–05:37:23 | 680–716 | Sonnet ×5 (replan) | JSON with step "Release the stuck movement" → advisory "its test only counts time" → empty → repair → accepted | plans around a fault that does not exist |
| 05:37:23 | 716 | board | `waiting_budget` until the end | 185 s |
| 05:37:26 → 05:39:02 | 719–815 | Haiku (situation_review wake) go_to the temple lodestone, on its own initiative | ok | memory route at 1.10 m/s |
| 05:40:29 | 902 | session end | – | The return error was 0.25 m, but there was no 200 m crossing |

---

## 2. Loop patterns, precisely

| # | Pattern | Mechanism | Evidence |
|---|---|---|---|
| L1 | **Refuse → retry with variations** | `move.lua:2143` sets `nav_fail="route_ended_before_goal"` when the oracle path ends short. `move.lua:2262` then finishes the go_to with `verification_failed: route unavailable: <why>` instead of walking the last segment. The baseline walked straight or followed breadcrumbs (`3c76837:move.lua:1279` `nav_bad` → trail). | 10-28..30: 36 route_ended_before_goal, 13 no_path, 6 invalid_route and 12 walking-terrain refusals. Median duration ~10 s, median 0–6 m moved (§4.3). E3: 10 in a row. |
| L2 | **Transient busy, misdiagnosed and escalated** | `move.lua:3645–3647` refuses any go_to that has no owner token whenever *any* non-implicit arbiter owner exists. That includes the fed reflex, which requests the arbiter with `uses_move = false` (`inventory.lua:1057`). The arbiter's own `owns_move` honours that flag (`arbiter.lua:259`); move.lua does not. The reflex can only fire once a move releases, so it fires **exactly when the brain retries**. | **6/6** go_to busy refusals on 10-30 fall 0.9–4.2 s after a reflex use in `vitals.jsonl`. a914's native samples show owner tokens 6 and 12 during the refusals. Both temple trials then planned a "release stuck movement" step. |
| L3 | **Replans that change nothing** | The Director gets only the reason string, so it varies targets, hops, explore or Windstep. The refusal is the same for every off-component target. | E3: 2 replans (6 Sonnet calls) with 0 m progress. 10-29 155917: 18 Sonnet calls for 3 decisions and 0 world successes. |
| L4 | **Director self-repair churn** | Free-text JSON goes through repair ("no JSON object", "checkpoints cannot belong to loops"), then the "Before you commit" advisory, then truncation at `max_tokens = 2048` (since fixed: 41fa4cc and `llm.py:249` = 16000). | Calls per accepted decision: 3.6 (10-26), 5.7 (10-27), 6.4 (10-29), 3.9 (10-30). 13 completions hit exactly 2048 (10-26..29). Repair/advisory prompts on 10-30: 5 and 3. |
| L5 | **Budget-window parking** | `board.HourlyWindow` at 20/h (historical; now 0 = off, `board.py:772`). The window was **shared across sessions**, so one trial starved the next. | a914: 515 of 900 s waiting. 10-30: 14.9 min. 10-26: 28.3 min. |
| L6 | **Crawl → deadline timeout** | Guarded walking (`walk_guarded` for memory and local routes, `move.lua:3114–3134`) forbids sprint (`move.lua:3323`) and steps through sampled walk targets. Combined with the 120 s go_to deadline (`move.lua:3759`), a guarded leg covers at most ~130 m. | Native samples: memory route **1.17 m/s (a907, 267 m) and 1.09 m/s (a914, 307 m)**. Unguarded nav with sprint: **6.02 and 6.83 m/s**. All 3 go_to timeouts on 10-30 lasted 120.5 s. |
| L7 | **Idle wakes** | situation_review fires on 2–3 % vitals drift and sends a full 24–32k-token prompt | 10-29: 8 of 9 such wakes did nothing; 10-30: 6 of 13. Cheap in dollars (Haiku), but they add turns and noise. |
| L8 | **Unpassable verifier** (pre-Codex) | A done-test can never become true | E1 (10-26), fixed |

**Board first call:** the board runs each step's first call *before* Haiku sees the step. **34 of 50** first calls failed. Haiku then repeated the identical call 6 times (all within 5 s, which is the reflex window), changed only the arguments 9 times, and switched tool 18 times.

---

## 3. Gap analysis: Haiku's view vs reality

### 3.1 The moments

| Moment | What the prompt contained | What the logs show | Truthful? | Actionable? |
|---|---|---|---|---|
| a914 05:34:10 go_to #1 | "go_to [182, 1815, −29] failed: verification_failed (walking terrain: sweep_blocking)", 76.9 m short, plus 3 copies of a **terrain blob 6,785 s old centred on the temple 70 m away** | crawled 82 m on a memory route at 1.1 m/s; a sweep guard stopped it on open ground; a fresh nav sprint did the rest in 11 s | jargon; the blob is stale | no: nothing tells him "retrying will work" or why it was slow |
| a914 / a907 busy ×6 | "busy: movement owner token required" | the fed reflex eating for 3–4 s (owner tokens 6 and 12) | **misleading**: it implies a stuck lock | no. The truthful text would be "eating (reflex), ~4 s; retry after". |
| a914 05:36:34 timeout | "timeout: movement deadline reached" at [136.7, 1869.8] | the memory route went 73 → 157 → 140 m from the goal | true but incomplete | no: he never learns the route went *away* from the goal |
| E3 ledge | "route unavailable: route_ended_before_goal / invalid_route" + ~40 barrier samples | "local plan failed: walls everywhere"; on an upper level 3.7 m above the target floor | jargon | no: he never learns "you're above it; the way down is a drop or the ramp" |
| E2 21:31 | "route unavailable: invalid_route" | a code gate after a partial route; Luis was a few metres up a slope | jargon → **invented "too steep"** | no |
| E2 22:04 death | "you died 9 s ago and respawned"; health 0 at z −70 | a ~30 m fall during an explore leg; the `fatal`/`killed_by` event was captured but never read | incomplete → **invented "not off a cliff"** | no |
| a907 end | board checkpoints and the last move only | a 202 m crossing at 04:29:15 | → **invented "only 40 m"** | – |
| every prompt on 10-30 | note `state:body_link`: "body bridge keeps restarting, craft/move commands dropped; at 0 water, 1% HP, no food" | written 10-26 18:59 (remember call, episode situation-0033); false since then; **in 45 sessions and 110 of 110 Haiku prompts on 10-30**; still in `logs/state/worlds/dev_director/notes.json:3` | **false** | primes "link broken" explanations |
| every prompt on 10-28..30 | "Inventory read: carried partial"; "Astral Rune x2079 (at least)" | complete reads mislabelled (83f0ce3; audit §0.6) | less honest | – |

### 3.2 What the prompt is made of (a914, first Haiku prompt, 64 KB, `composition.py`)

| Part | Size | Share |
|---|---|---|
| tool schemas (55 tools, ~25 read-only "look first" tools) | 31.4 KB | 49 % |
| system prompt | 12.0 KB | 19 % |
| `castable_spells` (41 spells, every prompt) | 9.4 KB | 15 % |
| stale terrain blob | 5.8 KB | 9 % |
| board JSON (2 parked jobs with developer-trial notes) | 2.1 KB | 3 % |
| **the actual situation lines** (where, around, creatures, vitals) | **~2 KB** | **~3 %** |

There is **no position, no place or region name, no floor/level, and no "what changed since the last action"**. `brain/situation.py:654` lists `position` and `places` as covered, but the summary renders neither. The body's coordinates appear only in follow-up "Current observation" JSON and in board progress strings.

Compare 10-25: 13 KB in total, half of it system prompt and no blobs.

### 3.3 What the client receives and where it goes

| Information (source) | Captured by the mod? | Reaches the model? | Verdict |
|---|---|---|---|
| Own transform (replicated movement; server corrections via ClientAdjustPosition) | position by poll; corrections **not hooked** | only in follow-up JSON and board progress; never in the digest | **dropped** as a semantic fact ("you're 3.7 m above X", "you fell 30 m") |
| Movement-mode changes (walking → falling) and Z deltas | not logged | no | **dropped** (the death cause) |
| Own vitals (`HealthComponent:OnRep_AuthoritativeHealth`, hydration/sustenance/endurance) | yes (`sense.lua:875`; vitals.jsonl) | yes, as words and % | **surfaced**; also drives noisy wakes (L7) |
| Damage multicasts (`Multicast_Apply*DamageFromGameplayEffect`) | yes (210 rows on 10-30) | only inside `combat_end` summaries | out-of-combat damage is **dropped** |
| `DamageComponent:OnRep_FatalDamageInfo` (killed_by) | yes (`sense.lua:868`) | **no** (no brain reader) | **dropped** |
| Replicated actors in relevancy (players, creatures, items, resources, interactables) | yes (sense census) | yes ("Around / Creatures / Usable"), lines cut at 240 chars with raw ids (`fol:BP_BM_Tree_Ash_03_C@1124,…`) | surfaced, but noisy ids |
| AI actions (`Multicast_StartAIAction`, attack telegraphs) | yes (combat) | as combat outcomes | right level (reflex) |
| Chat (`Client_ReceiveChatMessage`) | yes | yes | **surfaced, good** |
| Inventory (replicated inventory component) | yes | yes, but mislabelled "partial / at least" | **degraded** |
| Quests, journal, skills, time of day | yes | yes | surfaced; mostly irrelevant to the step |
| Region polygons / places (static data) | yes (`places.lua`) | known names only; the current region is not stated | **dropped** as "where am I" |
| **Navmesh paths** (the headless client has no NavigationSystem; `tools/nav_oracle.py` asks the **dev server's NPC navmesh**) | yes | reduced to "route unavailable: X" | **dropped**: where the path ends and its height difference. The server navmesh is **truncated at every boot**: "Navmesh bounds are too large! Limiting requested tiles count (1367840) to (1048576)" (server log 2026-10-26 16:46:34, 22 occurrences in all server logs). In the current `nav_oracle.log`, **288 of 1,302 answers are partial and 88 are no_path**. On Shockbyte there is no oracle at all. |
| Local physics probes (line traces, `K2_FindFloor`, walk-guard sweeps, local planner) | yes | raw (terrain blob, barrier_samples, "capsule_clearance unknown") | **noise**: big and stale, with no conclusion |
| Mod-internal state (arbiter owner, guard verdicts) | yes | as "movement owner token required" | **misleading** |
| Server log (dev) | – | – | No gameplay ground truth: logins, TeleportTo, SaveStateToJson, journal unlocks, and Kebbit "could not find a valid Goal Point" warnings. No damage, death, movement or correction lines. |
| Client UE log | – | – | Shipping verbosity: no movement, nav or damage lines. The mod's `client.log` is the only movement trace. |

---

## 4. Quantification

### 4.1 Model-issued go_to by day (`goto_reasons.py`; brain-live tool_result)

| Day | ok/total | Top failure reasons |
|---|---|---|
| 10-25 | 21/36 (58 %) | unknown_target 5, path_blocked leader_above_jump_height 4, timeout 3, "move said arrived but N m away" 2 |
| 10-26 | 20/36 (56 %) | **body_restarted 13** (client hang era), interrupted 2 |
| 10-27 | 7/11 | one each: interrupted, no grave, verification, no_route |
| 10-28 | 11/59 (19 %) | **route_ended_before_goal 20, no_path 12**, companion_down 4, invalid_route 3, target_not_visible 3 |
| 10-29 | 2/14 (14 %) | floor_not_walkable 3, local route unavailable 3, route_ended_before_goal 2, sweep/target_support 2, busy 1 |
| 10-30 | 7/40 (18 %) | **route_ended_before_goal 14, busy (owner token) 6**, invalid_route 3, sweep_blocking 3, timeout 3 |

- **Other bridge callers** (live_queue, dev tools, trial prep; daily `brain-2026102*.jsonl`) on the same days: 67 % (10-28), 46 % (10-29), 62 % (10-30). They used shorter, chosen targets.
- **Client mover** (`client.log`): `move: arrived`/`failed` was 206/31 (10-25), 472/21 (10-26), 138/205 (10-28), 42/42 (10-29), 34/34 (10-30).
- **"walls everywhere"** local-planner failures existed before Codex too: 135 on 10-25, 107 on 10-26. The baseline then *fell back to walking*; HEAD fails instead.

### 4.2 go_to duration and displacement by outcome (`goto_dur.py`)

- **Refusals:** route_ended_before_goal took median 10.5 s and moved median 6.2 m (10-30); no_path took 10.5 s and moved 0.0 m (10-28); busy took 0.2 s.
- **Timeouts:** 120.5 s, moving 116 m (crawl).
- **Successes:** 12.3 s median, 41 m.

### 4.3 Speed by route source (native samples)

| Trial | memory, no sprint | local | nav, no sprint | nav, sprint |
|---|---|---|---|---|
| a907 | 267 m / 228 s = **1.17 m/s** | 0.75 m/s | 1.41 m/s | 115 m / 19 s = **6.02 m/s** |
| a914 | 307 m / 283 s = **1.09 m/s** | 0.94 m/s | 0.87 m/s | 67 m / 10 s = **6.83 m/s** |

Player MaxWalkSpeed is 4.5 m/s and sprint 6.8 m/s (DISCOVERIES.md:1330, :2975), so guarded walking runs at **¼ of walk speed and ⅙ of sprint speed**.

### 4.4 Calls, spend and success by day (`loops.py`)

| Day | Calls | $ | Sonnet share | World actions ok/fail | Calls per ok action | Board steps done/failed | $ per step done | waiting_budget |
|---|---|---|---|---|---|---|---|---|
| 10-25 | 304 | 0.22 | 0 % | 72/80 | 4.2 | – | – | 0 |
| 10-26 | 351 | 1.12 | 77 % | 69/93 | 5.1 | 13/4 | 0.085 | 28.3 min |
| 10-27 | 193 | 0.98 | 87 % | 81/42 | 2.4 | 12/3 | 0.080 | 0.6 min |
| 10-28 | 494 | 0.83 | 58 % | 94/119 | 5.3 | 2/0 | 0.303 | 5.2 min |
| 10-29 | 113 | 1.78 | **97 %** | **4/23** | **28.2** | 4/4 | **0.445** | 2.8 min |
| 10-30 | 184 | 2.95 | **95 %** | 27/57 | 6.8 | 7/11 | **0.421** | 14.9 min |

### 4.5 Prompt size (usage.prompt tokens, `daily_bridge.py`)

| Day | Haiku p50 / p90 / max | Sonnet p50 / p90 / max |
|---|---|---|
| 10-25 | 13.7k / 19.5k / 26.5k | – |
| 10-26 | 18.7k / 22.2k / 34.3k | 11.5k / 14.4k / 16.2k |
| 10-27 | 22.6k / 26.4k / 29.3k | 13.7k / 17.6k / 19.7k |
| 10-28 | 20.3k / 25.6k / 36.7k | 14.7k / 16.9k / 17.6k |
| 10-29 | 23.9k / 31.3k / 36.3k | 21.4k / 25.2k / 29.4k |
| 10-30 | **29.5k / 38.8k / 44.2k** | **29.1k / 36.0k / 42.4k** |

- **Continuations:** within a chain the prompt grows ~3–6k per turn, because each tool result re-embeds the terrain blob. On a914 it went 29k → 35k → 42k in 3 turns.
- **Logged rows:** full requests are 64–117 KB.
- **Noise and staleness on 10-30 Haiku prompts:**
  - the stale body_link note: 110/110;
  - "(at least)" counts: 110/110;
  - the terrain blob: 78/110 (median **3 copies** per prompt);
  - barrier_samples: 31/110;
  - "owner token" text: 31/110.

### 4.6 Director efficiency (`director_stats.py`)

| Day | Sonnet calls | Accepted decisions | Calls/decision | Avg prompt | Truncated at 2048 |
|---|---|---|---|---|---|
| 10-26 | 40 | 11 | 3.6 | 11.3k | 3 |
| 10-27 | 40 | 7 | 5.7 | 14.2k | 4 |
| 10-29 | 64 | 10 | 6.4 | 20.9k | 5 |
| 10-30 | 74 | 19 | 3.9 | 29.7k | 0 (but repairs 5, advisories 3, non-JSON answers 4) |

Each accepted JSON plan cost 1.5–2.5k completion tokens, and it was regenerated in full on every repair.

---

## 5. Conclusions: the top 3 causes, ranked

### Cause 1. The body refuses or crawls instead of walking (code gates, not the game)

**Evidence:**
- go_to success fell from 56–58 % to 14–21 % (§4.1).
- 67 of ~110 failures on 10-28..30 are route-authority or walk-guard refusals that end in ~10 s with ≤6 m moved (§4.2).
- Guarded walking runs at 1.1 m/s against 6–6.8 m/s with sprint, which makes 120 s timeouts structural (§4.3).
- An unguarded retry immediately succeeded several times (a914 05:34:18; a907 04:27:35; E2 21:31:23).
- The underlying world fact is that the oracle uses the *NPC* navmesh. That navmesh is tile-truncated at boot and misses player-walkable links (the temple ramp, ledges). 22 % of oracle answers are partial.

**Smallest change that stops the loop:**
1. In `move.lua:2143`/`:2262`, treat `route_ended_before_goal`, `no_path` and `invalid_route` as **"walk on"**. Steer straight at the goal (or along the leader trail when following) for a bounded distance (≤30 m, or until `stuck n=3`), keep only the KillZ check, and fail only on *measured* non-progress. This is the baseline's `nav_bad` → trail/straight fallback.
2. In `move.lua:3114/3323`, drop `walk_guarded` for memory routes, or at least allow sprint on them. A remembered route was walked once, so walk it at player speed.
3. Raise the go_to deadline from a fixed 120 s to about `max(120, 3 × distance / 4.5 m/s)`.

These match the HANDOVER SIMPLIFY items ("route authority: fall back to walking").

### Cause 2. Failure feedback is untrue or unusable, and perception carries stale noise instead of the facts that matter

**Evidence:**
- 6/6 busy refusals were the body's own reflex, reported as "movement owner token required". Both temple trials then planned around a non-existent stuck lock.
- The timeout never says "walked away from the goal".
- Refusals arrive as jargon plus raw ray samples.
- A death never says "fell 30 m": `killed_by` is captured and dropped.
- A false 4-day-old note says the body link is broken, in 100 % of prompts.
- Inventory is mislabelled "partial".
- The situation the model needs is about 3 % of a 64 KB prompt.
- The result: Haiku invented causes in front of the player in every episode (E2, E3, E4, E5).

**Smallest changes:**
1. **Fix the busy bug at its source.** In `move.lua:3645`, skip the refusal when `old_owner.uses_move == false`, or wait out its `lease_s` (≤ `verify_s + 2` ≈ 6 s). Name the owner in any remaining busy text: "busy: eating Seared Anchovies (reflex), ~4 s".
2. **Give every movement result one honest sentence the body computes:**
   - where it started and ended;
   - metres moved and the closest approach to the goal;
   - "moving away" when the distance grew;
   - for partial routes: "walkable map ends N m short and H m above/below you";
   - for falls: "fell H m".
   Also add a `fell`/`killed_by` line to `recent_life` (`situation.py:393`) from the existing `fatal` event and the Z delta.
3. **Clean up what the model sees:**
   - strip `terrain`, `navigation_observation` and `barrier_samples` from model-visible results (keep them in logs);
   - delete the stale `state:body_link` note now, and give `state:*` notes a TTL;
   - revert inventory read-status (83f0ce3);
   - add a "Where:" line with position, region name and height relative to the target.

### Cause 3. The planning layer amplifies every body failure into Sonnet calls and wall-clock waits

**Evidence:**
- Sonnet was 95–97 % of spend on 10-29/30.
- It took 3.9–6.4 calls per accepted decision, with prompts of 21–30k tokens.
- 13 plans were truncated at 2048 tokens, and there were repair and advisory loops.
- a914 spent 407 s before its first step and 515 of 900 s in waiting_budget. The window was shared with the previous trial.
- Every step that Haiku reported as blocked, even a 4 s eating collision, triggered a full replan that could not change the body (E3: 2 replans with 0 m progress).

**Smallest changes:**
- Already landed: no hourly window, and planner `max_tokens` 16000 (41fa4cc, `llm.py:249`).
- Return the plan as a forced tool call (structured output) instead of free JSON plus repairs.
- Drop the "Before you commit" advisory second pass (it lost a valid plan in a914).
- **Add a no-progress breaker in the board.** If two runs of a step end with the same reason signature *and* <2 m net displacement, do not call the Director again with the same inputs. Report the specific reason once and park the step. This is information, not a veto: the model can still resume.
- Don't escalate `busy` or `timeout` to a replan: the executor retries once after the owner releases.

### What else feeds the loop (lower rank)

- Idle situation_review wakes (L7). Fix: wake only on threshold crossings, not on 2 % drift.
- The fixed 4-turn chain cap ends recoveries mid-way (a907 04:25:04, E3 02:24:02).
- Code speaks internal jargon to the player (`controller.py:1128` passes the `detail` sentence through, e.g. "movement owner token required"; `tools.obs` already flags this as `raw_code_spoken`).

---

## 6. Observability that would close the perception gap

**Already there:** `tools.obs anomalies` flagged only `repeated_failure` (E3), `tool_timeout` and `raw_code_spoken` (a914). It sees **none** of these root causes:
- the reflex owner;
- the 1.1 m/s crawl;
- code-gate refusals versus world failures;
- the Director churn;
- budget parking.

**Proposals:**

1. **A per-action trip record from the body** (one JSON row per go_to/follow/explore, same id as the bridge command):
   - start and end position, path length, closest goal distance, and whether the goal distance grew;
   - the source sequence (memory/nav/local/straight) with time and speed in each, and sprint on/off;
   - every arbiter owner seen during the action and right after it, with name and `uses_move`;
   - local-planner verdicts and oracle answers (partial endpoint, Z gap);
   - min/max Z and any falling segment, damage taken with instigator, and `fatal.killed_by`.

   It goes to the log in full, and the model gets a one-sentence summary of it. This alone would have explained E2, E3, E4 and E5.
2. **A brain-side before/after diff on every tool result:** position delta, HP delta, inventory delta, new and lost things in sight. Use it both for the "what happened" line and for the no-progress breaker.
3. **Hook the replicated signals the client already gets but drops:**
   - `CharacterMovementComponent` movement-mode changes (Falling → Walking with ΔZ);
   - server position corrections (`ClientAdjustPosition` / `ClientVeryShortAdjustPosition`, as counts per action);
   - the existing `OnRep_FatalDamageInfo` row, routed to the brain.

   Register through `hookhub.lua` (once per process, never unregistered), and test offline first. pcall cannot catch native crashes.
4. **A one-off RPC census to classify the server → client stream.** In a short dev session, count every `Client_*`, `Multicast_*` and `OnRep_*` UFunction that fires on the local pawn, controller and components. That is the inventory of "what the client receives", ranked by frequency, and it settles what is worth surfacing. **[UNVERIFIED]** whether a ProcessEvent-wide filter by function flags is safe in UE4SS on this build: test it on the dev world, never with Luis connected.
5. **Join the traces automatically.** Extend `tools/obs.py` to join `client.log` move lines, `vitals.jsonl` and the trip record by command id and time. Emit a "Haiku saw / reality" table per episode (the tables above, generated), plus new detectors:
   - `busy_after_reflex`;
   - `crawl` (<2 m/s over 30 s);
   - `moving_away`;
   - `refusal_without_motion`;
   - `replan_same_inputs`;
   - `director_calls_per_decision > 4`;
   - `stale_note` (age > 1 day).
6. **Keep vitals.jsonl** rotated per day instead of truncated: the Oct 28 death evidence is gone.

**Do we need semantic mapping or a perception model?** Not first. The failures above are mislabelled *existing* signals. The one genuinely missing semantic layer is **vertical/connectivity**: floor level, "the walkable link is a drop or a ramp", and the fact that the NPC navmesh is not equal to player-walkable space. A small learned graph of player-traversed edges (navmem already records routes: r152, r153 …), used as walkable links with drop and jump edges, is that layer. Feed it as one line ("you are on the temple upper level; the way down is the ramp at X or a 3.7 m drop"), not as coordinates.

---

## Appendix A — Scripts (session scratchpad, not in the repo)

All are in `C:\Users\ADMINI~1\AppData\Local\Temp\claude\C--gameserver\6f9e176f-ff3b-4d34-b8fd-670cf47fb39a\scratchpad\`. Run them with `C:\gameserver\.venv\Scripts\python.exe`.

| Script | What it produces |
|---|---|
| `inventory.py` | per-session calls, tokens and go_to |
| `loops.py` | loop metrics per session and per day; writes `loops.json` |
| `timeline.py` / `compact.py` | episode timelines |
| `dumpprompt.py` | the full prompt nearest a timestamp |
| `goto_reasons.py`, `goto_dur.py` | §4.1, §4.2 |
| `busy_corr.py` | busy vs reflex correlation |
| `director_stats.py` | §4.6 |
| `composition.py` | §3.2 |
| `wakes.py` | L7 |
| `daily_bridge.py` | §4.1 non-model callers, §4.5 |
| `native.py` | a914 native samples at a time window |

**Caveats:**
- Logs before ~10-27 store only the delta messages of follow-up turns. Prompt sizes therefore use `usage.prompt` tokens, not row length.
- vitals.jsonl covers only 10-30, so busy-reflex correlation before then is unverified (1 busy on 10-29 had no coverage).
- The goochlands_guest session (E2) ran on a non-dev world, so the dev-server log has no record of it.

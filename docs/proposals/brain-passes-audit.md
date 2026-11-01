# Brain extra passes: what they cost and whether they change anything (2026-11-01)

Read-only audit of every model call the brain makes beyond answering the player. Nothing was changed.

## Data and method

- **Logs.** All 101 `logs/brain-live-*.jsonl` sessions (Oct 25 to Nov 1): 12.8 h of session span and 1,916 model calls. Each `prompt` row is paired with its `llm_response` (18 prompts with no response are left out) and priced with `tools/spend.py:price` against `data/model_prices.json`.
- **Classifying calls.** Each call is assigned to a pass by:
  - its `step` tag: `0` = the main call; `1..n` = a read follow-up; `turnN` = a chain turn; `checkN` = the talk-only check; `*final` = the final pass;
  - the last user note: `PROMISE_NOTE`, success, failure, parked or last-turn;
  - the episode prefix: `chat-`, `review-`, `situation-` or `board-`.
- **Ladder.** `logs/evals/chat_ladder.jsonl` has 95 legs over 13 runs (Oct 31 20:44 to Nov 1 01:22, about 1.5 h of session span). Each leg's `calls_by_episode` is mapped back to the brain log it came from.
- **Outcomes.** These come from the `say`, `tool_call`, `tool_result`, `chain_turn`, `talk_only_check`, `controller_final_pass`, `*_unspoken` and `speech_redecided` rows.
  - Every review episode was classified by rule (below), and I checked the list by hand.
  - Scripts: `C:\Users\ADMINI~1\AppData\Local\Temp\claude\C--gameserver\6f9e176f-ff3b-4d34-b8fd-670cf47fb39a\scratchpad\passes.py`, `agg.py` and `outcomes.py`.
- **Line numbers** are for the working tree on 2026-11-01. `brain/controller.py` is being edited by another agent (persona text is moving out), so its numbers shift.
- The `logs/brain-YYYYMMDD.jsonl` daily logs are bridge-only, with 0 prompt rows, so they add nothing here.

## Headline

1. **Money is not the problem.**
   - All Haiku Controller calls together cost **$1.39 in 12.8 h**, about **$0.0008 per call** (around 17k prompt tokens, mostly cache reads).
   - The Sonnet Director is **$4.47, 76% of all spend**, and it is not one of these passes.
   - The real costs are:
     - calls and latency: the single-threaded brain is busy, and the player waits;
     - noise: lines repeated seconds apart, and "what's next?" right after he arrived;
     - complexity.
2. **Second-opinion passes are about 22% of all calls** (417 of 1,916) and **21% of ladder calls** (67 of 325): reviews 307, promise checks 71, talk-only checks 71, final pass 6, redecide 2 (some of the checks run inside review episodes). The after-success chain turn adds another **13% overall and 28% on the ladder**.
3. **Situation reviews are the biggest second-opinion pass.**
   - They also did the most real good: **23 self-care runs**, eating, drinking, and a shelter plus sleep.
   - But **62% of review episodes were silent, repeated a line or failed silently**.
   - On the ladder, 73% were.
   - Most are triggered by hunger or thirst crossing 50%. The stay-fed reflex owns that stat (it eats or drinks below 40%) and so does the body's vitals_low situation (below 15% with nothing carried).
4. **Since the say channel (Oct 28), the talk-only check almost never changes anything.** In 55 runs it added 0 actions, and 4 lines were corrected. Most "rewordings" are the same words said again, and it holds the line back about 1 s.
5. **The promise check sometimes catches something real.** 7 of 67 runs produced a useful catch, including one false "I'm at the lodestone now" (it was not there) turned into a walk there. 63% of runs come back empty.

## Table

The "/h" column is calls per hour of all play; "/leg" is calls per ladder leg.

| Pass | Code | Added because | /h | /leg | Calls (share) | $ | p50 latency, who waits | Outcome | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| Main reply (+ read steps) | `controller.py` `decide` / `_loop` | — (baseline) | 50.5 | 1.18 | 646 (33.7%) | 0.57 | 1.9 s, the player | the answer | — |
| **Situation review** (`review-` episodes) | `broker.py:63-71, 655-726` (`_watch`, `review_due`); `agent.py:162-180, 266-292` | Luis 2026-10-25, "proactive"; L10 (stayed in bed after day) | 24.0 | 0.53 | 307 (16.0%); 15.4% of ladder | 0.27 | 1.5 s per call; episodes median 5.5 s, p90 65 s, max 203 s; the player waited 10 times | 109 episodes: **23 self-care fixes**, 12 new lines, 6 arrival lines the chat left out, **18 repeats, 40 silent, 10 acted but failed silently** | **KEEP, tighten the trigger, fold into the chain** |
| Body situation (`situation-` episodes) | `broker.py:397-410` (`assess`); `agent.py:234-237` | streamline step 3; communication paramount | 10.5 | 0.15 | 134 (7.0%) | 0.10 | 1.4 s | 35 episodes: 17 fixes (eat, gather, follow), 15 honest lines, 3 silent, failed | KEEP |
| Event triage | `broker.py:360-410` | — | 0 calls | — | 0 | 0 | — | 164 verdicts: 104 decide, 60 drop (stale or coalesced) | KEEP (it is the cheap gate) |
| Chain turn after failure | `agent.py:440-466`; `controller.py:784` `next_turn` | the agent loop (live 21:43, the shelter plan died) | 25.2 | 0.44 | 322 (16.8%) | 0.23 | 1.4 s | 352 turns: 281 recovery attempts, 57 honest lines, 14 empty | KEEP (this is "say why it failed") |
| Chain turn after success | same | the same agent loop | 19.8 | **0.95** | 253 (13.2%); **27.7% of ladder** | 0.15 | 1.3 s; the arrival line waits for it | 267 turns: **134 next steps**, 77 report lines (mostly "I'm at X now"), 45 empty. Ladder: 51 report, 19 empty, 9 next steps | **MERGE** (a done line on the action) |
| Promise check (`PROMISE_NOTE`) | `agent.py:56, 413-419, 446` | L5 ("I'll walk closer and cast it", no call) | 5.5 | 0.04 | 71 (3.7%) | 0.03 | 1.2 s; nobody waits (the line was already said) | 67 runs: 42 empty, 25 acted, about 7 useful | **MERGE with the talk-only check** |
| Talk-only check (`TALK_ONLY_NOTE`) | `controller.py:62, 383, 817-842` | GOAL M1 talk_without_action (48edc9d) | 5.5 | 0.13 | 71 (3.7%) | 0.03 | 1.0 s (p90 1.6 s); **the line waits** | 67 runs: 3 added an action (all Oct 26), about 4 material corrections, 54 the same line again, 9 no change, 1 error | **CUT as its own pass, merge into one check** |
| Final pass (`FINAL_PASS_NOTE`) | `controller.py:81, 669-690` | live 22:20:15 (look, look, inventory, then nothing) | 0.5 | 0.01 | 6 | 0.01 | 1.9 s | 6 of 6 turned "nothing" into a line or an action | KEEP |
| Redecide (`speech_redecided`) | `agent.py:684-698` | single voice, speak-time check | 0.5 | 0 | 2 logged (6 events) | ~0 | 2 s | stopped a false "right on you" after `near_player` flipped to false | KEEP |
| `failure_unspoken` / `situation_unspoken` | `agent.py:463, 475`; `controller.py:1082` | dc5a8e1 (code never talks over the model) | 0 calls | — | 0 | 0 | — | markers: 1 and 69. 17 of the 69 "fixed by the model's own action" had no body action succeed | KEEP; rename the label |
| Director review (`REVIEW_EVERY_S`) | `director.py:63, 1510-1517` | the board | 1 dispatch ever | 0 | about 1 Sonnet call | ~0.03 | — | 1 | irrelevant |

## Per pass, with samples

### 1. Situation review

**How it fires.**
- `_review_tick` reads state every 30 s.
- `broker._watch` records any stat crossing 50, 30 or 15%, plus day/night, the sleep window opening, a full bag, or idling near a player.
- `review_due` then emits once nothing is busy and 20 s have passed since the last "busy".

**Two measured flaws in that trigger.**
1. **The 50% hunger/thirst band fires before anything is needed.**
   - The reflex eats and drinks below 40% (`client_mod/scripts/inventory.lua:661`).
   - The body sends `vitals_low` below 15% when he carries nothing (`client_mod/scripts/client_bridge.lua:1353`).
   - Of the 40 silent reviews, 25 were hunger or thirst only. Typical triggers: "a bit thirsty" or "a bit peckish", answered with an empty reply.
2. **It fires the moment a chain ends.**
   - `note_busy` is stamped when an action **starts** (`agent.py:312, 350`). A go_to longer than 20 s has therefore already used up the quiet window by the time it arrives.
   - On the ladder, **18 of 30 reviews started within 0.6 s of the chat episode ending**. The band change built up while he was busy, and the review fired as soon as he stopped.

**Outcome classes for the 109 episodes.**
- **A, self-care fix succeeded (23 episodes, 126 calls).** Examples:
  - 10-27 20:52, "badly hurt": gather → consume → collect_water → consume, all ok.
  - 10-27 21:34, "nearly dead": "got some redberries, eating now. still badly off though".
  - 10-30 03:24: cast Summon Shelter → consume → interact with the bed.
  - 10-31 19:22: move_item → consume → collect_water. "no water in sight, the known spots won't path from here. searching around, badly parched".
  - 10-31 23:43 (review-0006-3e56, 12 calls): killed a Giant Rat, summoned a shelter and went to bed. But his line "rats dead. I'm wiped, gonna kip in a shelter here" was never said (a step failed first), and 4 identical `cast busy` retries cost 4 calls.
- **B, new line (12):**
  - 10-25 22:12: "Zezima, no water anywhere I've looked, and no food on me. Got any drink or food spare?"
  - 10-31 22:56: "this one's the Law vent, not Astral. where's the Astral one, you want me there?" (a real correction).
- **C, arrival line the chat chain left out (6).** 11-01 01:11: "I'm at Vannaka now, what's next?". The chain's after-success turn was empty, and "on my way to Vannaka" had been said 21 s earlier.
- **D, repeat of a line said less than 60 s before (18).**
  - 11-01 00:40: "at the vent now, what's next?", 1 s after "at the vent now".
  - 11-01 00:17: "here at Zanik, what next?", 1 s after "here at Zanik".
  - 10-26 18:02: "I can't get the game to let me use the Campfire.", 33 s after the identical line.
  - 10-28 22:12: "no way down from here and no water in reach. can you drop me a drink or a Law Rune for the lodestone?", 2 s after the situation line "no water up here, no way down that I can find, lodestone needs a Law Rune I don't have…".
- **E, silent (40 episodes, 45 calls).** For example 10-31 22:22 review-0003-88ca: "a bit thirsty", 1 s after "I'm at Vannaka now", and the reply was empty.
- **F, acted but failed silently (10).** 10-31 23:00 review-0012-9c94: "a bit peckish" plus night → cast Summon Shelter fails `nothing_in_range` → a go_to to a spot, interrupted by the next ladder line. Nothing was said, and it was logged as "fixed by the model's own action".
- **By era:**
  - Oct 25–30, the survival-crisis runs (unreachable water): A 21, B 12, D 13, E 26, F 7.
  - The ladder: A 2, B 2, C 4, D 5, **E 14**, F 3.

**Verdict: KEEP.** It is the only proactive behaviour, and it produced the 23 fixes. Make it cheaper:
- (a) Drop the 50% band for hydration and sustenance (`REVIEW_BANDS` per stat; the 30% and 15% bands stay). This cuts 41 episodes and 80 calls all-time (14 episodes and 28 calls on the ladder). The 6 fixes it would have produced still happen at the 30% band.
- (b) Fold a pending review into the running chain's last turn, as `since_last_turn` (the `_news` path), instead of opening a new episode 0.3 s after it.
- (c) Stamp `note_busy` when a chain ends too, so a review never lands right on top of his own line.
- **Expected:** ladder review calls 50 → about 11; all-time about −100 of 307.

### 2. Chain turn after success

This is the standard agent loop: the tool results go back to the model.
- **The core case:** 134 of 267 turns called the next step, as in "make an axe then cut a tree". Keep that.
- **The rest:** after a single verified action, the call exists only to say the report line ("I'm at Doric now", "at the Earth Anima Vent now") or to stop (45 empty turns).
- On the ladder that is **70 of 79 turns**, about 1.3 s each, and the arrival line waits for it.

**Verdict: MERGE.**
- Let the model put its own completion line on the action, e.g. `go_to(target, done_line="I'm at Doric")`. This reuses the held-line mechanism (`ANNOUNCE_FIRST` / `held_line_said`, `agent.py:658-665`).
- When that action is the turn's last call and it is **verified ok**, code says the model's line and the chain ends. Any failure runs the failure turn exactly as now.
- The model chooses this, so code does not decide for it. The precedent is LangChain's `return_direct` tool flag: the tool's output goes straight back, with no further model call.
- **Expected:** about 75 of 325 ladder calls (−22%, about 0.75 per leg), about 120 calls all-time, and arrival lines about 1.3 s sooner. Test it in one ladder run: it is a prompt change plus about 20 lines.

### 3 and 4. Promise check and talk-only check

These are the same idea at two places.
- The promise check fires on turn 0 and runs after the line has been said.
- The talk-only check fires on later turns, holds the line, and makes one more call.

Both decide on shape (said something, called no tool), never on words.

**Promise check: 67 runs.**
- **Useful (about 7):**
  - 10-31 23:47: "I'm at the lodestone now, right by the Wise Old Man. Where are you?", with no call and not true, became go_to plus "my bad, I'm not there yet, walking to the lodestone now" (verified ok).
  - 10-26 17:52: "…so I'll go find something to eat" → gather ok.
  - 10-26 17:58: "…so I'm heading to the lake." → go_to ok.
  - 10-27 20:25: "I'm low on food and water so I'll sort that first" → consume ok.
  - 10-28 21:41: "I'll open the closest ones and check" → interact ok.
- **Empty (42), plain answers.** Examples: "already at the lodestone, right here"; "just tunic and leggings on, plus the noggin bag…"; "can't see a Water vent nearby, only a Law Anima Vent about 80 m off…".

**Talk-only check: 67 runs.**
- **Added an action (3, all on Oct 26, before the say channel):** "Can't find the water spot from here…" → go_to; "Drinking and checking my bag both keep failing…" → consume.
- **Material corrections (about 4).** The model dropped a promise of something it was not going to do:
  - "hang on… can't walk to the grave. checking what happened" → "game says my character is dead, so I can't walk to the grave. are you seeing me as dead too?"
  - "got the first one open, checking what's in it" → "first chest is open, can't see the contents from here though…"
  - "…checking if I'm still up" → "think I got knocked out and maybe respawned somewhere else…"
- **The same words again (54).** For example the four lines at 11-01 00:42–00:44 ("still stuck, game says my character is dead…"), each re-said word for word; and 10-31 20:45 "I'm at Vannaka, what's up?".
- **Since 10-31 22:00:** 12 runs and 0 changes.

**Verdict: merge them into one check.**
- Say first, so the line is never held.
- Gate it on the model's own declaration in `say`, e.g. a required `next: "done" | "acting"` field.
- When the model says `acting` and called no action tool, the one check turn runs (`PROMISE_NOTE`). When it says `done`, there is no check. This is the model's own statement, not a word list and not a veto.
- **Expected:** −110 of 142 calls all-time, −13 of 16 on the ladder, and the 1 s line hold disappears from failure turns.
- If a schema field feels too heavy, the minimum is to delete the talk-only check: it has had no live benefit since the say channel. The promise check stays.

### 5. Body situations, event triage and the failure turn

**KEEP.**
- The deterministic triage already drops 60 of 164 events: stale, coalesced, or a voiced unreachable inside its cooldown.
- The 35 episodes left gave real fixes or honest asks. For example:
  - 10-31 23:33: "at the Earth vent. grabbing that cabbage and potatoes nearby, starving otherwise" → "got a chicken and cooked a fillet, eating fine for now".
  - 10-28 22:42: "yeah there's a redberry bush right by me, starving so grabbing those now".
- Failure turns are where "can't, and why" comes from:
  - "still stuck at the ledge, route up keeps failing. can you come down to me?"
  - "no crafting table here, cutting some ash to build one" + gather.
- One weakness: repeated identical failures with looks in between are not "parked". In review-0006-3e56 a cast came back `busy` 4 times, costing 4 calls. `progress.py`'s breaker could ignore read calls when it compares.

### 6. Final pass, redecide and the markers

- **Final pass and redecide:** keep. Both are rare, cheap, and changed the outcome every time they ran.
- **`situation_unspoken` mislabel:** `acted` (`agent.py:390`) becomes true when any action *ran*, so failed or interrupted actions are logged "fixed by the model's own action" (17 of 69).
  - Most ended `interrupted` because a newer command took the floor, which is fine.
  - Rename the label to "the model acted" so the logs stop overstating fixes.

## Top 3 changes by savings

| # | Change | Ladder calls saved (of 325) | All-time calls saved (of 1,916) | Other gain | Risk to Luis's rules |
|---|---|---|---|---|---|
| 1 | **A done line on the action** (model-authored, said on a verified ok, `return_direct`-style), so a single verified action needs no follow-up call | about 75 (−22%) | about 120 (−6%) | arrival line about 1.3 s sooner | Low. The model still writes every line, failures still get their turn, and multi-step chains are unchanged |
| 2 | **Review trigger:** drop the 50% hunger/thirst band; fold a pending review into the chain's last turn; restart the quiet window when a chain ends | about 39 (−12%) | about 100 (−5%) | removes the "at the vent now" → "at the vent now, what's next?" repeats; 25 of 40 silent calls disappear | Low. Self-care still triggers at 30% and 15%, and at vitals_low |
| 3 | **One check instead of two:** say first, then one check turn only when the model's `say` declares an action follows | about 13 (−4%) | about 110 (−6%) | no more 1 s hold on failure-turn lines; one code path | Low. It keeps the "I'm at the lodestone" honesty catch |

Together these cut about 40% of ladder calls (about 3.4 → 2.1 per leg) and about 17% of all Controller calls, with no loss of any useful outcome seen in the logs.

**Caveats.**
- "Useful" is a heuristic. Every review episode was listed and checked by hand, but the class edges are soft.
- Most of the review evidence comes from the Oct 26–30 crisis runs. The ladder era is only about 1.5 h.
- `board-` episodes (Director-driven Controller runs, 331 calls) are counted inside main and chain but not analysed on their own.

# What he is shown after a silent stop with the ask open: an offline replay (2026-11-17)

## The question

A player's ask is closed by code on any turn where the model calls no tool (`brain/agent.py`, `request_closed`). Nothing checks the game. Five wording fixes did not hold live (`docs/RETRO-2026-11-17-session.md` row 4), so rule 10 asks for a structural change. If the code kept the ask open and ran one more turn, and that turn showed him something different, would he go on? And would he go on when the ask really is done?

## What was done

- Harness: `tools/replay_open_ask.py` (tests: `tests/test_replay_open_ask.py`, 13 tests). Results: `logs/evals/replay_open_ask-20261117-185812.jsonl` (pilot: `-185601`).
- Each case is a recorded closing turn: the exact messages, the exact tool list and the effort of the logged call, rebuilt as `tools/replay_episode.py` does. The extra turn appends the silent reply (and a "said" result for a `say` in it), a fresh `Current observation` (`brain/controller.current_observation` on the last state read before the close) and one user message with the variant's block. Only that one call is replayed. Nothing ran against the game, client or brain.
- Model: Haiku 5.5 (`anthropic/claude-haiku-5-5`) through `brain/llm.controller_llm()`, effort low, as live.

## Cases

Logs exist from 15 Nov on (none for 10 to 14 Nov). Sources: every `request_closed` (81, from 16 Nov 13:26), runs that heard a goal end that came from an ask and stopped with no world call, and the `grave` and `gear_up` gate runs.

| | found | used | evidence |
|---|---|---|---|
| ask open at the close | 21 | 19 | quest runs: `logs/evals/quest_runs.jsonl` has the quest not complete at the close (16); `rung4_gate` gear_up leg done false (3) |
| ask done at the close | 93 | 18 | quest complete before the close (77); grave leg done true (16). 18 picked spread over quest, grave and chat or body runs (seed 17) |

- Left out: 2 grave runs the gate called not done (10 of 12 items back at its end) while the state at the close shows all 12 back. The evidence disagrees with itself.
- Left out: 1 run where he was dead at the close (`20261116-222100`).
- Chop, mine and spells gates were not used: their only end state is the bag, so D would equal B.
- 16 of the 19 open cases are Rune Mysteries or Ratcatcher; 3 are gear_up. Every open case is a different trial.

## Variants

Each block is data. No variant says what to do.

| | the turn after the silent one |
|---|---|
| A | none (today). Counts as stopped. No call. |
| A1 | calibration: the closing call re-sent unchanged. Does the replay reproduce the live stop? |
| B | `Open request: {"open_request": {"player", "words", "asked_s_ago", "changed_since_asked": {"bag", "worn", "quests"}}}`, the changes read from the body's own state rows at the ask and at the close |
| C | B, plus `"open_until": "request_done or park_request is called"`, and two tools in the list: `request_done(evidence)` "Close the player's open request as finished. The request stays open until request_done or park_request is called." and `park_request(reason)` "Stop working on the player's open request for now. The player hears the reason. ..." |
| D | B, plus `"game_state_now"`: the quest log (active steps, complete list), armour PL now against the best he can reach (`brain/gear_plan.plan`), the graves he remembers. The same block for every ask: no mapping from his words to a kind of ask. |

## Rubric

Applied by code to the tool names, blind to the variant (`outcome()` and `passed()`):

- world: any body call other than `say`, a read or a need. need: `consume`, `collect_water`, a shelter cast, rest in a bed, boiling water. read: quests, look, craft_plan and the other read-only tools.
- Open ask: pass = a world call. A stop, a `say` only, a need, `park_request` or `request_done` fails. Lenient: a read also passes (live, a read runs inline and he gets another call).
- Done ask: pass = no world call.
- Judgement: I read every world call on the open side in a shuffled list with the variant hidden (`blind.py` in the session scratchpad). All were on the ask (gather rune essence, `start_goal` for the quest step, talk to Zanik, interact with an essence geyser or an Anima Vent, explore for rune essence). One was unclear: `use_action primary` with the pickaxe held next to an essence geyser. I counted it as on the ask before unblinding.

## Results

k of n replays (2 per case per variant; A1 once per case). 95 % Wilson intervals. Fisher's exact test, two-sided.

| variant | open ask: went on | p vs A | p vs B | done ask: no new work | p vs A |
|---|---|---|---|---|---|
| A (today) | 0 of 38 = 0 % (0 to 9 %) | | 0.0004 | 36 of 36 = 100 % (90 to 100 %) | |
| A1 (calibration) | 2 of 19 = 11 % (3 to 31 %) | 0.11 | 0.18 | 16 of 18 = 89 % (67 to 97 %) | 0.11 |
| B | 11 of 38 = 29 % (17 to 45 %) | 0.0004 | | 36 of 36 = 100 % (90 to 100 %) | 1.0 |
| C | 12 of 38 = 32 % (19 to 47 %) | 0.0002 | 1.0 | 35 of 36 = 97 % (86 to 100 %) | 1.0 |
| D | 11 of 38 = 29 % (17 to 45 %) | 0.0004 | 1.0 | 32 of 36 = 89 % (75 to 96 %) | 0.11 |

Lenient (a read counts): C 13 of 38, D 13 of 38, B 11 of 38.

Cases, not replays (at least 1 of 2 went on): B 7 of 19, C 8 of 19, D 7 of 19. The two replays of a case are not independent: read the p values above as optimistic.

How each variant ended when he did not go on (open side, 38 replays each):

| | empty | say only | need | read | park | done claimed |
|---|---|---|---|---|---|---|
| B | 17 | 8 | 2 | 0 | | |
| C | 0 | 0 | 1 | 1 | 15 | 9 |
| D | 14 | 7 | 4 | 2 | | |

Where it worked and where it did not:

- It works on the runs that heard a goal end (the ash hand-in) with the quest moved on: 6 of 11 such cases went on in B, 8 of 11 in C (a case counts when at least 1 of its 2 replays went on).
- It did not work on the chat runs that stopped after a body failure (essence out of reach, rocks mined out, no free campfire, Rune Altar would not place): B 1 of 5 cases. There C parked with a specific reason in 10 of 10 replays.
- It did not work on gear_up: 0 of 6 replays went on in B, C or D. In C he claimed it done 4 of 6 ("Bronze Sword and Bronze Shield equipped; tunic, leggings and cowl worn"), with armour PL 1 against a reachable 3. D's gear line (PL 1, best 3, three slots below best) moved him to `craft_plan` reads in 2 of 6, no world call.
- D's quest log and gear data caused false work on done asks: 4 of 36 (go to the Wise Old Man for the next quest, go to Vannaka, go back to a grave). B: 0 of 36.
- Calibration: A1 went on in 2 of 19 open cases where live went on in 0. The replay is close to live but acts somewhat more.

## Examples (quoted)

| variant | case | what he did |
|---|---|---|
| A (live) | gear_up 181801 | nothing: no call, no text, after equipping a sword and shield and lying down to rest |
| A (live) | Rune Mysteries 073824 | `say` "ash done, Zanik took it. next step is rune essence, mining near here", then stood |
| A (live) | Rune Mysteries 185142 | text only: "I'm not doing anything else this turn; the line I already said covers it." |
| A1 | Rune Mysteries 114618 | `gather rune_essence 20` (live had stopped) |
| A1 | gear_up 182835 | `say` "done. cape on, sword and shield in hand, food and water on the hotbar. ready to go" |
| A1 | grave 234018 (done) | interact with a gravestone: "my weapons and logs are in another grave, going for that now" |
| B | Rune Mysteries 055158 | `start_goal` "Do the Rune Mysteries quest for Zanik: mine Rune Essence nearby, then craft some Air and Astral Runes ..." and `say` "zanik's got a new step, mining rune esse..." |
| B | Rune Mysteries 102023 | `say` "did Zanik's bit ... next is mining rune essence and making air and astral runes", no call (a promise with no call) |
| B | gear_up 181801 | nothing |
| C | Rune Mysteries 153450 | `park_request` "Zanik's quest needs rune essence, but the essence here is floating out of my reach and my pickaxe can't knock it down." |
| C | Ratcatcher 214420 | `park_request` "Ratcatcher is at the cooking step: I have raw rat meat, but both campfires nearby hold other people's items and I can't build one." |
| C | gear_up 181801 | `request_done` "Bronze Sword and Bronze Shield equipped; tunic, leggings and cowl worn; ... resting in my Summon Shelter." (false) |
| D | Rune Mysteries 185142 | `explore` rune essence and `say` "still on it, the nearby essence rocks are empty. I'll hunt for a live one" |
| D | gear_up 181801 | `say` "sword and shield are on. my armour's weak though, better gear is in my grave about 400 m off. resting first, then I'll go get it" (no call) |
| D | Rune Mysteries 204449 (done) | `go_to` Wise Old Man Objective: "Zanik's quest is done. Next I'll head to the Wise Old Man in Bramblemead for First Steps." (false work) |

## Recommendation

Build C: keep the ask open on a silent close, run one more turn that carries the open ask as data (B's block), and offer `request_done(evidence)` and `park_request(reason)` as the only ways an ask ends.

- On going on, B, C and D do the same (29 to 32 %, p = 1.0 between them). The gain is the extra turn with the ask as data, about 0 % to about 30 %.
- C costs no more false work than B (1 of 36 against 0 of 36). D costs 4 of 36: do not show the quest log and gear plan as a block on every ask.
- C changes how the rest end. In B, 25 of the 27 replays that did not go on ended in silence or a line. In C, 24 of 26 ended in a logged `park_request` with a reason or a `request_done` with evidence. A park reason is what section 3 asks for (he says what he cannot do and why). A done claim is a claim, and now a readable one: the next fix can tell it back (the tool's result carries the quest log or the gear numbers against his evidence), which is rule 10 "told back", not a veto.
- What it will not fix: gear_up. There he believes the ask is done. That needs the target told back on his done claim, or a perception change; it is the next structural candidate, not this one.
- Cost per silent close: one Haiku call, about 37 k prompt tokens, about 1.1 s, about $0.0005 to $0.0008 with the prefix cached (measured: B and D $0.00043 to $0.00082 a call). The two tools add about 150 tokens to every Controller call; with them always in the list the prefix stays cached.

Log line for `tools.unseen` (the main session adds it with the change): one row per kept-open turn, and one per end.

- `{"kind": "open_ask_turn", "request": ..., "asked_s_ago": ..., "outcome": "world|park|done_claim|silent"}` when the extra turn runs. Signature: `"kind": "open_ask_turn"`.
- `"kind": "request_parked"` and `"kind": "request_done_claimed"` (with reason or evidence) replace `request_closed` for a closed ask.

Live window to confirm:

- Number: of silent closes with the ask's quest step open, the share whose extra turn makes a world call on the ask. Today 0 (`request_closed` with the step open: 7 of 7 quest cases stood). Expected about 30 %, at most about 45 %.
- Trials: `python -m tools.ab need 0.0 0.3` gives 22 closes per side; `need 0.05 0.35` gives 27. The 0 % side is the logs above (19 cases), so the window needs about 22 silent closes with the step open after the change.
- Where: Rune Mysteries step trials from the checkpoint after the ash hand-in, since 8 of 11 such cases went on under C in the replay. A close with the step open came in roughly 1 run in 5 there (5 of 26 runs on 16 and 17 Nov), so this is about 100 trials: not one window. Count every kept-open turn across the next windows by its log line, and judge with `tools.ab two 0 19 k n`.
- Second number: on closes with the ask done, the share whose extra turn starts new work. Replay: 1 of 36. Bar: not above about 10 %.

## Spend

267 Haiku 5.5 calls (8 pilot, 259 batch), $0.36 by LiteLLM's own cost (pilot $0.019, batch $0.341). Spend today before the batch: $3.22 of $10.

## What I did not check

- Only the one turn after the silent one. A world call there is not a finished ask: whether he then completes the step, and how the later turns go, is not measured.
- Reads were not run: a read-only reply ends the sample. Live, the read runs inline and he gets another call (lenient column).
- The tools in C were present only on the extra turn. Offered on every turn, they may change earlier turns too (an early `request_done` or park); not replayed.
- The silent reply carries no thinking blocks (the logs do not keep them for the last call of a request). Live, the extra turn would carry them.
- No cache nonce: replays of one case share the cached prefix. `tools/replay_episode.py` notes that a cold cache changed behaviour in one earlier study.
- The open cases are 16 quest cases from two quests and 3 gear_up runs; 2 reps each. No other long job (build, gather to a count, vault) is in the set, because no such ask was closed silently in the logs.
- D's gear block comes from `gear_plan.plan(state)` with no containers seen (the brain also passes what it saw in chests).
- The scoring treats every park and done claim on an open ask as a fail, even where the reason was true (several parks name real skill faults from the ledger: essence out of reach, rocks mined out).

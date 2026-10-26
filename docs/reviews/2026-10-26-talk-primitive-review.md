# Review: `docs/design/talk-primitive.md` (NPC dialogue: `talk {target?, choose?, leave?}`), 2026-10-26

Reviewer: a fresh-context agent. I did not write the note. I reviewed it before deployment.

**Read:**
- `docs/design/PRINCIPLES.md`, CLAUDE.md §0;
- `client_mod/scripts/input.lua` (the whole file);
- `skills.lua`: the interact episode, l.140-480 and 930-985;
- `inventory.lua`: `interact_target`, `press_interact`, `use`, the stay-fed reflex `R.tick`;
- `combat.lua`: `gated` / `inject`, and the input-mode escape at l.1820-1840;
- `spells.lua`: its gate calls at l.562-570 and 1183;
- `client_bridge.lua`: pause handling;
- `client_mod/commands/bench_probe.lua` (quests);
- DISCOVERIES: the census, interact, input modes and quests (l.1647);
- dump `26161880`:
  - `CommonConversationRuntime.hpp` (whole) and its `_enums.hpp`;
  - `Dominion.hpp` l.6450 (`FQuestProgress`), 10216-10239, 11256, 17810-17880, 19236, 19333, 20422, 29541;
  - `WBP_Conversation_MainPanel.hpp`, `WBP_DomConversationOptionButton.hpp`;
  - `UE4SS_ObjectDump.txt` (search for `DIM_*`).

**Also searched (web):** how CommonUI and Enhanced Input interact (finding 6).

## Verdict: APPROVE WITH CHANGES (design); the code is not reviewable (finding 0)

The direction is right:
- the player's own interact press;
- the panel's own option, continue and cancel input actions;
- read-only payload and quest reads;
- `RequestServerAdvanceConversation` / `ServerAdvanceConversation` / `Server_StartConversation` and the async start node are correctly rejected;
- the model chooses, and code only resolves its pick against the shown list;
- nothing names an NPC or quest.

Findings 1–5 must change before the code is written or deployed. They cover:
- **pressing Continue can pick an option for the model** (finding 1);
- **a dialogue the gate cannot clean up or tell apart from the spell modes** (findings 2–4);
- **verification that gives false negatives on looping dialogue hubs** (finding 5).

---

## 0. The code under review does not exist (blocker for deployment)

- `client_mod/scripts/talk.lua` and `client_mod/tests/test_talk.lua` are not in the working tree, in any git commit (`git log --all`; HEAD `000f743` adds only the design note), in any worktree, or anywhere on disk.
- The note's §7 "Offline" acceptance therefore has no evidence.
- **Required:** land both files. Then a fresh-context cold review of the code is needed (PRINCIPLES "Review gate") before any live P1-P3.
- This review covers the design only. Where I say "the code must…", the reviewer of the code should check it.

## (1) Is every step a real player UI input?

Mostly yes: interact (E), the option's number-key action, Continue, Cancel (Esc). Two gaps:

**1. Continue may confirm the highlighted option. That would be code choosing for the model. MUST FIX.**
- `UConversationMainPanel` has `CurrentSelectedOption` (l.17842), and `UConversationAnswerButton` has a `SelectInputAction`. That is the usual CommonUI pattern: navigation highlights an option, and an accept or continue key confirms it.
- If `ContinueInputAction` on a node *with options* confirms the highlighted one (option 1 by default), then §3 step 3 ("press Continue until a real choice appears") picks option 1 whenever its read is a frame late, or when a payload with options lands between the read and the press.
- **Required:**
  - (a) Press Continue only when a read **in the same tick** shows zero `UserChoiceAvailable`/`UserChoiceUnavailable` options **and** `AllOptions` is empty.
  - (b) Press once per *verified* payload update (finding 5's counter), never twice on one node.
  - (c) Add "does Continue confirm `CurrentSelectedOption` when options are shown?" to the [UNVERIFIED] list and probe it in P2. Use a node where the first option is harmless, or prove it read-only by watching `CurrentSelectedOption` only.
  - (d) An offline test: "options appear between read and press → no Continue is sent".

**2. The option key may only highlight, not confirm (two-step selection).**
- `SelectInputAction` plus `CurrentSelectedOption` also allow "the number key selects, then Continue/Accept confirms".
- **Required:**
  - The choose path verifies in two stages.
  - If `CurrentSelectedOption` becomes the chosen item but no payload arrives, the code may press confirm **only after checking `CurrentSelectedOption == the model's chosen item`**.
  - Add this case to the [UNVERIFIED] list and the fake tree.

## (2) Does the model choose?

The split is right:
- index or exact or unique-substring resolution against the shown options only;
- `invalid_choice` lists them;
- no phrase table.

Four details:

**3. Stale options. MUST FIX.**
- "Resolve against the options **last returned**" is unsafe if the node changed since that reply. Causes include:
  - the server auto-advanced;
  - a reflex pressed Back (finding 8);
  - the conversation ended and a new one started.
- In those cases index 2 picks a different line than the one the model read.
- **Required:**
  - Each reply carries a node signature: `CurrentNode` handle (read as its fields, never built), plus speaker, line text and the option texts.
  - `choose` re-reads it before injecting. If it differs, the call fails `options_changed` and returns the new options, so the model chooses again. That is information, not a veto.

**4. `ServerOnly` entries and the numbers.**
- `EConversationChoiceType.ServerOnly = 0` entries are in `LastMessage.Options` but are not shown to a player.
- **Required:**
  - Exclude them from the model's list and from the index space.
  - Derive `n` from what the screen numbers: the item's `InputAction` position in `OptionSelectInputActions`, or the button's `NumberText`, not the array order. Then a wiki line like "choose option 2" and `choose: 2` mean the same thing.
  - Join panel items and payload entries **by text**, not by position.
  - Keep "AllOptions order = on-screen numbers" on the [UNVERIFIED] list, but stop depending on it.

**Minor (2a).** Auto-continue is acceptable: a no-choice node gives a player only Continue or Esc. But each collected line must be returned in order, with the speaker, so the model reads everything a player would have. If a quest change happens during auto-continue, stop and report it, since the model may want to react before more lines.

**Minor (2b).** `option_unavailable` (refusing to press a greyed option) is fine as truthful reporting. Keep the greyed option in the list with `available: false` so the model can tell the player why.

**Minor (2c).** Define argument combinations:
- `{target, choose}` together → `invalid_args`, unless the design means "start, then choose" (I recommend not);
- `{}` with a conversation open → re-read and return the current node (a cheap "what is on screen");
- `{}` with nothing open → `not_in_conversation`.

## (3) Verification from game state

**5. The verification signals give false negatives. MUST FIX.**
- **Start.** "Participant active *or* `LastMessage` changes" fails on a second talk to the same NPC: the entry node, line and options are identical to the stale `LastMessage`, which persists after a conversation ends. It also fails the other way: a `LastMessage` left over from an earlier conversation can look like this one.
- **Choose.** "`LastMessage` changes (node, line or options)" fails on hub nodes. "Tell me about…" often returns to the same hub with an identical line and options. The result would be a false `no_change`, and the model would retry and pick it twice.
- **Required:**
  - (a) Primary start and end signal: `ConversationsActive > 0` / `IsInActiveConversation()` (replicated, `OnRep_ConversationsActive`) **and** `ConversationComponent.CurrentNPC == target actor`. The note does not use `CurrentNPC` (l.29545); it proves he is talking to *that* NPC and not a neighbour the detector picked.
  - (b) An update counter. Add a count-only post-hook through `hookhub` on `UPlayerConversationComponent:HandleConversationUpdated` (or `ConversationMainPanel:HandleConversationUpdated`). It must not read the struct parameter in the hook; read `LastMessage` afterwards from the property. Every payload arrival counts as "advanced", even when the content is identical.
  - (c) Cross-check `pc.CurrentInputMode == DIM_ConversationUI`. The asset exists: `/Game/Gameplay/Inputs/Modes/DIM_ConversationUI`, object dump l.191079. This resolves the [UNVERIFIED] item "the dialogue switches the PC input mode" to a likely yes, to be confirmed in P1.

**6. `quests_changed` misses conversation side effects.**
- The dump has `UConversationTaskNodeModifyQuestInt` and `UConversationTaskNodeSetQuestBool` (l.17861-17875). Dialogue nodes change `QuestInts` / `QuestBools` without changing `State` or `CurrentObjective`.
- **Required:**
  - Diff `QuestInts` and `QuestBools` too, by name and value.
  - Take the baseline at conversation start and report cumulatively. Replication can land after the payload that caused it, so a per-call diff can split or miss a change.
  - Re-diff once on leave/end, and report it in the leave reply.

## (4) Modal hazards

**7. The gate cannot tell the dialogue from the spell modes, and `claim("mode", "talk")` does nothing. MUST FIX.**
- `input.modal()` reports any non-gameplay input mode as `{kind = "mode"}`. `spells.lua` injects with `opts.modal = "mode"` (l.570, 1183), so **a `cast` the model issues mid-dialogue passes the gate**: the arbiter is free, because `talk` releases it after each call. Q and the number keys would then land on the conversation panel. Number keys are the option keys, so this is effectively an unchosen answer.
- `sweep()` returns early for `kind == "mode"` (input.lua l.140), so `claim("mode", "talk")` changes nothing except `input_status`. It also shares one owner slot with any future "mode" owner.
- **Required:**
  - (a) In `input.modal()`, report `DIM_ConversationUI` as its own kind, `{kind = "conversation", npc = CurrentNPC}`. Spells' `modal = "mode"` then no longer bypasses it, and talk claims `"conversation"`.
  - (b) Talk's own presses go through `input.inject(action, nil, {modal = "conversation"})`, not `raw_inject`. With `raw_inject` a talk press lands on a container or build screen if one is open.
  - (c) An offline test: "conversation open + spells cast → refused with the conversation named".

**8. Combat's input-mode escape ends the dialogue silently.**
- `combat.lua` l.1825-1840 presses `IA_UI_GenericBack` (raw) whenever the mode is not `DIM_Gameplay` during a combat frame loop. That includes the self-defence reflex, which can start while the dialogue is open, because the arbiter is free between talk calls.
- Leaving a chat to fight is what a player does, so this behaviour is acceptable. But:
  - talk must notice that the conversation ended without its own Cancel;
  - the next talk reply (or an event) says "the conversation with X ended because I had to fight" (PRINCIPLES 7);
  - the stored options are invalidated (finding 3).
- Also record in input.lua's header that combat is a second party allowed to exit a non-gameplay mode. The header says "nothing here exits it", which is true only of input.lua itself.

**9. An orphan dialogue blocks all gameplay input forever.**
- If talk dies, the bridge restarts, or a job times out with the dialogue open, nobody exits it: `sweep` skips `"mode"`. Every gated module (gather, farm, fishing, agility, build, combat's `inject`) then refuses indefinitely, and only combat's escape would ever close it.
- **Required:** with finding 7(a), give `sweep` a `conversation` cleanup, the same pattern as `close_container`:
  - after `orphan_s`, press the panel's own `CancelInputAction`, at most `cfg.cancels` times, read back, and leave `stuck` reported;
  - **never** `Server_ClientRequestAbortAllConversations` (`UDomConversationParticipant`, l.19242), a Server_ RPC, or `HideConversationUI`.

**10. Pause and travel.**
- Under `DW_PAUSE` talk must make no game call at all, matching `input.lua` and `client_bridge` (pending actions fail `companion_down`).
- On `client_unpaused` / reconnect, clear talk's state: the stored node signature and options, the claim, and the quest baseline. The game tore the conversation down.
- Add a test: "pause mid-choose → no inject; unpause → `not_in_conversation`, no stale index accepted". §7 lists "pause" but not this case.

**11. The stay-fed reflex is not gated at all.** This predates the talk design but matters now.
- `inventory.lua` `R.tick` calls `M.use` → `hotbar:UseItemInSlot` and `M.press_interact` (collect) without `input.gate()`.
- input.lua's header claims "the stay-fed reflex… asks M.gate() first", but it does not.
- In a dialogue (and in build mode or a container screen) it can fire:
  - a hotbar use;
  - an interact press. If `IMC` for the conversation maps `IA_Interact` to Continue, that press advances the dialogue.
- **Required:**
  - gate both presses in `R.tick` (skip the tick and record `gated`). The safety floor can wait one turn, and the model can choose to `leave`;
  - fix the header;
  - add a regression test.

**12. Other tools should say "I'm in a conversation".**
- `move.go_to` does not consult the gate. In `DIM_ConversationUI` movement input is probably ignored, so a `go_to` would fail as `stuck`/`path_blocked`. That is a false reason (PRINCIPLES 7).
- **Required:**
  - the shared modal reason (`busy_on_modal`, from spells) names the conversation and the NPC;
  - move, the interact episode and the gated jobs return that reason while a conversation is open;
  - perception (`skills.state_extras` or the census) exposes `conversation = {npc, speaker, line, options}`. The model then knows it is mid-dialogue without calling a tool (honest perception, CLAUDE.md §0).

**13. The existing generic `interact` opens dialogues it cannot own.**
- The `interact` tool's own description says it "…opens, talks" (skills.lua l.1718), and the census lists NPCs with the action `interact`.
- Today `interact` on the Wise Old Man presses E. Its verify sees no inventory, prompt, sleep or container change, presses again (`cfg.presses`; the second E may be Continue), and then returns `verification_failed`. The dialogue is left open and unowned (finding 9).
- **Required:**
  - (a) Add `conversation` to `W.press_signals` (`ConversationsActive` / `CurrentNPC == thing`). A press that opens one returns `changed = "conversation"` with the first node (or hands over to talk's reader), and never presses again.
  - (b) **Reuse the episode for `talk {target}`.** §3 step 1 re-describes approach + face + detector + press using `move.go_to` / `interact_target` / `press_interact` directly. That would duplicate `new_episode`/`episode_poll`: interaction points, standing spots, the tighter approach, `too_far` / `not_interactable` sentences, and resting.
  - Simplest shape: `talk {target}` = the interact episode with an `accept`/signal for "conversation opened", then talk's reader. That also gives `talk` the arbiter and resume handling the episode already has (PRINCIPLES 4b: no second copy).

## (5) Crash risks

**14. Per-tick reads.** No struct building is planned, which is good: no `FAdvanceConversationRequest`, no `FConversationChoiceReference`, only the proven `InjectInputVectorForAction(sub, ia, {X,Y,Z}, {}, {})` pattern.
- The verify windows (3–4 s at 30 fps) as written imply reading `LastMessage` every tick. That struct is 0x68 bytes and contains `TArray<FClientConversationOptionEntry>` (FText, `FGameplayTagContainer`, a `FConversationChoiceReference`, a nested `TArray ExtraData`). The note also reads `AllOptions[]` UObjects.
- **Required:**
  - Poll only cheap scalars per tick: the hook counter (finding 5b), `ConversationsActive`, `CurrentInputMode`.
  - Read `Options` / `AllOptions` **once per detected change**, with the same `each(..., cap)` bounded iteration bench_probe uses.
  - Never iterate `ChoiceTags`, `ChoiceReference` or `ExtraData`. Only `ChoiceText` and `ChoiceType` are needed.

**15. Finding the panel.**
- `FindFirstOf("ConversationMainPanel")` can return the CDO or a widget pending kill. The HUD may re-create it between conversations, and UMG under NullRHI on the headless client has not been tested for this widget.
- **Required:**
  - use `find_all` with `skip_defaults`, `U.valid`, and `panel.DomConversationParticipant == pc.ConversationComponent.DomConversationParticipant`;
  - cache it and re-validate per call (input.lua's `cached` pattern; no find_all per tick);
  - P1 confirms that the panel exists and its `AllOptions` fill on the headless client.
- If the panel never builds headless, the fallback is **not** the Server_ RPC. Stop and report.

**16. Hook safety.** Register the finding-5 hook with `hookhub` (paused-aware, hot-reload-safe). Do the read-only offline test first, then confirm in P1 that registering the hook on the headless client is harmless (CLAUDE.md §0: pcall can't catch native crashes).

## (6) Is it generic?

**17.** Yes, by design:
- targets come from the census;
- options come from the game;
- quests come from `UQuestData`;
- reasons are generic.

The Wise Old Man, Shrimp Catcher and "option 2" appear only in the goal and live-test sections, which is fine. The code reviewer must confirm that no NPC, quest or option strings appear in `talk.lua` (fakes and tests are exempt), and that `test_principles.py` covers the new file.

## (7) Search record

**18. Adequate for the overall pattern, thin on the one risk that decides feasibility.**
- **Good:**
  - the UE CommonConversation API pages;
  - Yarn Spinner `RunOptions`;
  - the read → present → pick → verify pattern.
- **Weak:**
  - The Microbot link (`hdroller/Microbot-client`) is not the usual upstream (`chsami/Microbot`). Check it or replace it.
  - The RuneLite `DialogState` citation is a wiki *talk page*, not RuneLite docs or source.
  - The Fab listing describes nothing specific.
- **Missing:**
  - (a) **Whether Enhanced Input injection triggers CommonUI / UMG action bindings at all.** Epic's "Using CommonUI with Enhanced Input" says non-generic actions fire Enhanced Input events but *not* CommonUI action bindings, and generic actions (accept/back) bind to UI without firing EI events. Whether `InjectInputVectorForAction(OptionSelectInputActions[i])` reaches the panel therefore depends on how `WBP_Conversation_MainPanel` binds its keys. That is the note's first [UNVERIFIED] item, and the whole design rests on it.
  - Record this source, and write down the fallback order **before** P2, so that a failure live leads to a decision and not improvisation:
    1. the injected action;
    2. the option button's own click/selection handler (a UI handler, allowed by PRINCIPLES 1, like `CallOnBuildingItemSelected`), probed offline first;
    3. stop and ask Luis.
    - Never the advance RPC.
  - (b) UE CommonConversation behaviour for "Continue" on a node with only ServerOnly branches, and whether `LastMessage` is assigned client-side in `ClientUpdateConversation`. The Lyra / CommonConversation source or forum threads would settle the [UNVERIFIED] "LastMessage updates on the owning client".
  - (c) The Dragonwilds dialogue controls (wiki/guides): number keys, Space/E to continue, Esc. These confirm what a player presses.

## Smaller items

**19. A map opened mid-conversation.**
- `UPlayerConversationComponent` has `SetupEnterConversationOnMapClosed` / `EnterConversationOnMapClosed`. Some dialogue steps pause the conversation, open the world map, and resume when it closes.
- talk must recognise "the game opened another screen" (input mode ≠ `DIM_ConversationUI` while `ConversationsActive > 0`) and report it truthfully (`screen_open` with the mode named), rather than `no_change`. Closing it is the screen's own back key, a player's Esc.
- Add it to the fake tree.

**20. `bInShouldDisplayConversationUI`.** `ClientStartConversation` takes a show-UI flag, so some conversations run without the panel. Then there are no keys to press. Report `no_dialogue_ui` with the line, and do not press blindly.

**21. Ownership wording.** "The arbiter is held … only for the walk-and-press" is right for not blocking reflexes, but it means another `command`-level tool can start while the dialogue is open. Findings 7 and 12 make that tool fail truthfully. State this in the note's Ownership section.

**22. The live plan.** P3 ("choose the net option and see quest Given") changes the dev character's quest state permanently.
- Run it only on the dev character (ClaudeDev), never on Shockbyte.
- Record the before/after quest snapshot in `logs/bench/fixture_setup.jsonl`-style evidence.
- Run P1 (read-only) separately and first, with the hook registration in it.

---

### Must-fix before code or deployment
- 0: land the code and tests;
- 1, 2: Continue / selection semantics;
- 3: stale-option guard;
- 5: start/advance verification by `ConversationsActive` + `CurrentNPC` + an update counter;
- 7: a separate `conversation` modal kind, with talk injecting through the gate;
- 9: orphan cleanup by the panel's Cancel;
- 11: gate the fed reflex;
- 13: `interact` recognises a conversation, and `talk` reuses the episode;
- 18a: record the CommonUI injection risk and the fallback order.

### Should-fix
4, 6, 8, 10, 12, 14, 15, 19, 20.

Sources (web):
- [Using CommonUI with Enhanced Input in Unreal Engine (Epic docs)](https://dev.epicgames.com/documentation/en-us/unreal-engine/using-commonui-with-enhnaced-input-in-unreal-engine)
- [UE forum: CommonUI/EnhancedInput "Triggering Enhanced Input Action"](https://forums.unrealengine.com/t/contentexamples-ui-commonui-enhancedinput-triggering-enhanced-input-action-inputaction/2675277)
- [UE forum: CommonUI buttons triggering Enhanced Input Action](https://forums.unrealengine.com/t/any-way-for-commonui-buttons-triggering-enhanced-input-action-to-trigger-pressed-visuals/2800624)

---

# Re-review (v2), 2026-10-26

Reviewer: the same fresh-context agent, cold on the code (I did not write it).

**Read:**
- `client_mod/scripts/talk.lua` (all 783 lines), `client_mod/tests/test_talk.lua`, `docs/design/talk-primitive.md` rev 2 §8;
- the committed `input.lua` (conversation kind, `sweep`) and `skills.lua` (`press_signals`, `conversation_npc`, verify, `_new_episode`);
- `inventory.lua` / `combat.lua` gates, `sense.local_pc`, `client_bridge` (`api.now`, `MODULES`, `__dwc_bridge`), `hookhub.on`;
- DISCOVERIES l.254, 785, 1773;
- dump: `FConversationNodeHandle`, and `UConversationParticipantComponent` (no delegate properties).

**Ran:**
- `test_talk.lua`: 50/50 pass. `test_input.lua`: 19/19 pass.
- Two scratch repros, outside the repo:
  - `C:\Users\ADMINI~1\AppData\Local\Temp\claude\C--gameserver\e0d45239-de5c-445e-af07-0109fe4fa4e3\scratchpad\talk_probe.lua`;
  - `C:\Users\ADMINI~1\AppData\Local\Temp\claude\C--gameserver\e0d45239-de5c-445e-af07-0109fe4fa4e3\scratchpad\talk_recursion.lua` (the real `input.lua` + `talk.lua`).

## Verdict: CHANGES NEEDED. No-go for P2/P3. P1 only as a standalone read-only probe, with `talk.lua` NOT deployed.

- `client_bridge.MODULES` already lists `"talk"`, and the committed `input.lua` sweep already calls `talk.sweep_orphan`. Copying this `talk.lua` to the client therefore activates R2–R4 the moment any conversation opens on Claude's client.
- The offline suite passes because it fakes exactly the parts that fail:
  - `W.ui_press`, `W.read`, `W.scalars`, `W.claim`/`W.release` and the clock are all replaced;
  - the fakes are Lua tables, where `==` is identity.

## Must-fix status

| # | Status | Notes |
|---|---|---|
| 1 Continue | **Implemented** | `step_read` presses Continue only on a same-tick read with no user option with text, an empty `AllOptions` and a Continue key. One press per update (the counter or a signature change). Tested ("race"). The panel lookup is broken, though (R1). |
| 2 Two-step | **Implemented, unsafe without the hook** | Confirms only if `CurrentSelectedOption` text == the chosen text. See R6 and R7. |
| 3 Stale options | **Implemented, with a hole** | Signature re-read before injecting; `options_changed` returns the new options. Tested. But the signature's node part is always `"nil"` (R8), and a conversation talk did not open itself can never be answered (R4). |
| 5 Verification | **5a, 5c done; 5b unproven** | Opened = `ConversationsActive > 0` and `U.short(CurrentNPC) == target id`, checked before each `_episode_poll`. The mode is cross-checked. The counter's hook target may never fire (R6). |
| 9 Orphan | **Broken** | Recursion (R2), mixed clocks (R3), it cancels the model's own conversation (R4), and abandoned dialogues are never swept (R5). |
| 13 Episode reuse | **Done in skills.lua** | `press_signals.conversation`, `changed = "conversation"`, no second press while one is open, `_new_episode` exported. talk uses `_new_episode`/`_episode_poll`. The talk side misses adoption (R4). |
| 18a Fallback | **Done** | Order recorded; step 2 behind `ui_handler_fallback = false`; `input_not_reaching_ui` stops. The search record now cites Epic's CommonUI page and `chsami/Microbot`. |
| 11 Fed reflex | **Done** (inventory) | `R.tick` now gates. |

## Findings

**R1. BLOCKER: UObject wrappers are compared with `==`, so the panel is never found.**
- DISCOVERIES l.1773 (verified live): "Wrapper objects of one SkillData do not compare equal with `==`, so match on the short name."
- `W.panel` does this in both its cache check and its search:

  ```lua
  U.try(function() return p.DomConversationParticipant end) == part
  ```

  It is always false live, so `st.panel` is nil, and every talk returns `no_dialogue_ui`. `leave` returns "no dialogue window to close", and `sweep_orphan` returns `no_cancel_key`, so nothing can close the dialogue either.
- `W.read` matches `k.a == a` (the `InputAction` against `OptionSelectInputActions`). It is always false, so `n` silently falls back to `AllOptions` order: finding 4's numbering is not really implemented.
- **Fix:**
  - compare `U.short`/`U.fullname` (or the address, if UE4SS exposes one; unverified);
  - make the fakes return a fresh wrapper table per read, so a regression fails offline.

**R2. BLOCKER: `sweep_orphan` recurses through the gate, and one call injected Cancel 197 times.**
- The path: `sweep_orphan` → `W.ui_press(cancel)` → `input.inject(.., {modal = "conversation"})` → `gate` → `sweep` → the conversation is unowned → `talk.sweep_orphan` → …
- `o.cancels` and `o.last` are only set *after* the press, so every level passes the timing checks again.
- The C-stack overflow is swallowed by the `pcall` in `sweep`. Each level then returns and injects.
- With the real `input.lua` (`talk_recursion.lua`), one call produced **197 Cancel injections, 197 full payload+panel reads and `orphan_cancels = 197`**, all in one game-thread frame.
- **Fix:**
  - a re-entrancy guard;
  - set `o.cancels`/`o.last` before pressing;
  - press as the modal's owner (claim `"conversation"` around the press, then release). Do not route back through the sweep.
- Add an integration test that uses the real `input.lua`.

**R3. BLOCKER: two clocks.**
- The job uses `W.now(pawn)` (`GetRealTimeSeconds(pawn)`, game seconds). `sweep_orphan` calls `W.now()` with **no world context** (l.694), against DISCOVERIES l.785 ("use `GetRealTimeSeconds(pawn)`").
- Live there are two possible outcomes:
  - (a) it returns 0. Then `now - o.since` is always 0, and **an orphan is never cancelled**;
  - (b) the call errors. Then it falls back to `os.time()` (epoch seconds), which is compared against `cv.last_call` in game seconds. **Every recorded conversation then looks abandoned**: the first talk call between turns marks it `orphan_seen`, and the next call presses Cancel on the conversation the model is in the middle of.
- The tests set `K.clock`, so neither outcome is visible offline.
- **Fix:** one clock: `W.now(W.pawn(pc))` everywhere, or one module clock. Add a test where the clock has a non-zero offset.

**R4. BLOCKER: a conversation talk did not open is never adopted.** It cannot be answered, and talk's own sweep cancels it.
- `interact` now reports `changed = "conversation"`. The model's natural next step is `talk {}`.
- That read job never creates `C().conv`; only the start path and the `{target == current npc}` path do.
- The repro shows:
  - `talk {}` → ok with 4 options;
  - `choose 2` → `options_changed`, every time, because `cv` is nil and is never set;
  - and the `sweep_orphan` at the top of that choose call **pressed Cancel and closed the dialogue** (`orphan_cancels = 1`, active → false).
- **Fix:**
  - every successful read of an open conversation adopts it (`conv = {npc = sc.npc, base = quests now, pawn_id, last_call}`), and `finish` stores the signature into it;
  - add a test: "opened by interact → `{}` → choose by number".

**R5. MUST: an abandoned dialogue blocks gated input indefinitely.** Cleanup also leaks on pause.
- `finish` keeps `input.claim("conversation", "talk")` for as long as the conversation is open. `input.sweep` returns early for any owned kind (l.139), so the gate **never** calls `talk.sweep_orphan` while that claim stands.
- If the model walks away from a dialogue, only a later talk call can clean it up, after `abandon_s` = 300 s. Until then, gather, farm, fishing, agility and build refuse, and combat's `inject` is gated (only its raw GenericBack escape gets out).
- The pause branch of `frame` (l.445-452) clears `conv`. But it calls neither `W.release()` nor the arbiter release, both Lua-only and safe under pause. The stale claim then makes the *next* unowned conversation look owned.
- **Fix:**
  - for the `"conversation"` kind, let `input.sweep` always ask `talk.sweep_orphan` (talk alone decides ownership), or hold the input claim only while a talk job runs;
  - release on the pause path;
  - choose a shorter abandonment window, or one tied to brain turns, and record the choice in the design.

**R6. MUST before any choose: the counter's hook may never fire.**
- `UConversationParticipantComponent` has no delegate UPROPERTY in the dump. Compare `UQuestProgressComponent.OnQuestStateChangedDynamic`. So its update delegate is native, and Dominion's `HandleConversationUpdated` is probably invoked by a direct C++ call, which a UE4SS hook (ProcessEvent/Func path) does not see.
- **[Hypothesis]**, to settle in P1/P2.
- If the counter never moves:
  - identical hub payloads give "stopped moving on" and false `input_not_reaching_ui` (finding 5 regresses);
  - worse, the finding-2 confirm path can run after a pick that *worked* and returned an identical hub with the highlight still on that option. Continue is then pressed, and that may pick the option a second time.
- **Fix:**
  - count on `/Script/CommonConversationRuntime.ConversationParticipantComponent:ClientUpdateConversation` (an incoming client RPC, dispatched through ProcessEvent; hooked count-only, never called), or on `PlayerConversationComponent:BP_HandleConversationUpdated` (a BlueprintImplementableEvent);
  - P2's first step proves the counter rises on a real update;
  - until then, `cfg.hook_verified = false` disables the confirm path, and replies carry `hook_armed`/`hook_count`.

**R7. SHOULD: confirm only a highlight the key press caused.**
- If the list auto-highlights option 1 when it opens, `choose 1` with a deaf key is confirmed by Continue. The 18a failure is then hidden, and Continue's unverified semantics become the selection path without anyone knowing.
- **Fix:**
  - record `selected` before the press, and confirm only if it changed to the chosen text;
  - put `picked_via = "key" | "key+confirm"` in the reply, as P2 evidence.

**R8. SHOULD: the node part of the signature is empty.**
- `FConversationNodeHandle` has only `NodeGuid` (an FGuid). `U.str(struct)` has no `ToString` and returns nil, and `NodeIndex` does not exist. So `st.node` is always nil.
- **Fix:** read `NodeGuid.A/B/C/D` as numbers. Otherwise two different nodes with the same line and options are indistinguishable.

**R9. SHOULD: a FindAllOf per frame.**
- While an unowned conversation is open, `sweep_orphan` runs on every `input.gate` call (combat calls it every frame). Each call starts with `W.pc()` → `sense.local_pc()` → `FindAllOf("BP_PlayerController_C")`.
- `state_extras` does the same on every `get_state`.
- **Fix:** use `input.pc()` (cached and re-validated), per the build review's finding-10 rule.

**R10. MINOR.**
- The quest stop compares the *number* of changed quests, so a second change to an already-changed quest does not stop the auto-continue.
- The nested `each_cap = 16` truncates `QuestInts`/`QuestBools` silently.
- `W.quests` runs on every `step_read` and `finish` (bounded, per call, not per tick).

## Crash-risk check (CLAUDE.md)

- **Per-tick reads:** OK in the job. Per frame it reads `pc.Pawn` and `GetRealTimeSeconds`; at 10 Hz the scalars only. Payload and panel reads happen on change, bounded, with `ChoiceText`/`ChoiceType` only. The exceptions are R2 (about 200 full reads in one frame) and R9.
- **Struct building:** none. No advance RPC, no `Server_*` call, no `HideConversationUI`. Injection is the proven `InjectInputVectorForAction(sub, ia, {X,Y,Z}, {}, {})`, through `input.inject`.
- **DW_PAUSE:** no game call. `frame`, `start`, `sweep_orphan`, `scalars`, `read`, `quests`, `each` and `state_extras` all check pause. Only the Lua-side releases are missing (R5).
- **Hook:** goes through `hookhub` (paused-aware, idempotent); registered at the first talk call. Confirm it is harmless in P1 as planned, with R6's target.

## Before P2

1. Fix R1–R5. Add R6's `hook_verified` gate.
2. Add tests:
   - the real `input.lua` + `talk.lua` orphan path (no recursion, at most 1 Cancel per `orphan_s`);
   - fresh wrapper objects per read (R1);
   - a clock offset (R3);
   - interact-opened → `{}` → choose (R4);
   - an abandoned claim swept through `input.gate` (R5);
   - pause releases the claim (R5).
3. A cold look at the diff, then P1 (read-only, with the hook registration), then P2 with the counter proven.

Sources (web): [Using CommonUI with Enhanced Input (Epic docs)](https://dev.epicgames.com/documentation/en-us/unreal-engine/using-commonui-with-enhnaced-input-in-unreal-engine). A search for UE4SS UObject `==` semantics found no UE4SS documentation, so R1 rests on the repo's own live finding (DISCOVERIES l.1773).

---

# Re-review (v3), 2026-10-26

Reviewer: the same fresh-context agent, cold on the rev 3 code.

**Read:**
- the `talk.lua` diff `b13b1b8..3f319fa` (all of it);
- `test_talk.lua` and the new `test_talk_engine.lua`;
- design §9;
- the `input.lua` diff from `974faca` (re-entrancy guard, conversation in the bounded sweep) and the `client_bridge.lua` `DW_ENABLE_TALK` opt-in;
- `skills.lua` verify and press signals.

**Ran:**

| Test | Result |
|---|---|
| `test_talk.lua` | 52/52 |
| `test_talk_engine.lua` | 20/20, plus one `PENDING` line |
| `test_input.lua` | 22/22 |
| `test_skills.lua` | 44/44 |
| scratch `talk_recursion.lua` (real `input.lua` + `talk.lua`) | **1** Cancel injection, `orphan_cancels = 1`; was 197 |
| scratch `talk_probe.lua` | interact-opened → `{}` → `choose 2` now **ok**, with 0 Cancels from talk's own sweep; was `options_changed` and a Cancel. After 400 s idle, `claimed = false` (was true). |

The probe's last scenario now raises in *my* script: it reads `.data.why` on what is now a pending (successful) reply. That is not a talk bug.

## Verdict: GO for the standalone P1 probe and for P2. Dev world, ClaudeDev, `DW_ENABLE_TALK` opt-in only.

Conditions:
- **V2** (below) is fixed, or explicitly accepted, before the live companion's client next restarts with this `skills.lua` and `input.lua`. V2 is not a talk bug and does not block P1/P2 on dev.
- **V1** lands before talk is enabled by default.
- **P3** follows only after P2's evidence.

## R1–R10 verified in the code

| # | Verified |
|---|---|
| R1 | `same()` compares `U.short` names. Used for the panel's participant (cache and search) and the option key → on-screen number. The engine test uses fresh wrapper tables per property read, and a reversed panel list, so both a `==` regression and list-order numbering fail offline. ✓ |
| R2 | `c.in_sweep` guard. `o.cancels`/`o.last` are set before the press. `W.ui_press` claims `"conversation"` around its own press (so input's sweep returns early for an owned kind). `input.gate` has its own `s.sweeping` guard with an error catch. Repro: 1 Cancel. Engine test: ≤ 1 per `orphan_s`, ≤ 3 total, with 50 gate calls per "frame". ✓ |
| R3 | `W.now(ctx)` returns nil without a context and never falls back to `os.time()`. `sweep_orphan` uses `W.now(pawn)` and skips on nil. The engine test runs the real `W.now` against a fake `GetRealTimeSeconds` with a 5000 s offset (no `K.clock`). ✓ |
| R4 | `step_read` adopts any open conversation (new or different NPC). `finish` adopts and stores the signature/options. Engine test: opened by interact → `{}` → choose 2 → ok, `picked_via = "key"`, and no Cancel. ✓ |
| R5 | The claim is taken in `new_job` and released in every `finish`, and in the pause branch (Lua-only, with the arbiter release). No claim between turns (engine test). `abandon_s` = 120. **But the sweep bound in input.lua still defeats it: see V1.** |
| R6 | Hooks on `ConversationParticipantComponent:ClientUpdateConversation` and `PlayerConversationComponent:BP_HandleConversationUpdated`, count only. `hook_proven` is set only when the counter moved *and* the signature changed. The confirm path requires `hook_verified` or `hook_proven`. Unproven + unchanged node → `no_visible_change`, which says it cannot tell a hub from a deaf key. Tested. ✓ |
| R7 | `selected0` is recorded before the key. Confirm only if the highlight changed to the chosen text. `picked_via` is in the reply. ✓ |
| R8 | `NodeGuid.A-D` as numbers (`1-2-3-10` in the engine test). ✓ |
| R9 | `W.pc` uses the cached `input.pc()`, with sense as the fallback. ✓ |
| R10 | `diff_key` content key; quest-field cap 64. ✓ |
| — | `answer_pending` blocks a second choose on one node. ✓ |

**Crash-risk recheck:**
- No struct building. No `Server_*`, advance RPC or `HideConversationUI` (the test greps for them).
- No game call under `DW_PAUSE`.
- Per tick: `pc.Pawn`, `GetRealTimeSeconds(pawn)`, then scalars at 10 Hz.
- Payload and panel reads happen on change and are bounded.
- The orphan path is now one read and one press per `orphan_s`.
- One new path: `J.t` can be nil if the clock is unreadable. The frame then errors and ends `body_error` after 5 errors. That is safe.

## Remaining findings

**V1. SHOULD (before talk is on by default): input.lua's sweep bound still strands an abandoned dialogue.** This is the "remaining dependency".
- `input.sweep` handles the `"conversation"` kind with the same counters as build and container: one try per `orphan_s`, `cfg.cancels = 3`, then `s.stuck`. A try is counted whether or not talk pressed anything.
- So after the model's last talk call, input asks `talk.sweep_orphan` three times in about 3 s. Talk answers `owned` (inside `abandon_s`). Input then sets `stuck = "conversation"` and **never asks again** while the modal stays up: the tries reset only when the modal closes or someone claims it.
- When `abandon_s` expires, only a later talk call can close the dialogue. The engine test reproduces exactly this and prints `PENDING R5 via input.gate`.
- **Fix (input.lua owner):** for the conversation kind, count a try only when `sweep_orphan` returns `state == "cancel_pressed"`, or skip input's counters and let talk's own bound (≤ 3 Cancels) apply. Then turn the `PENDING` branch into a hard check.
- Not blocking P2: every P2 step ends with `leave` or a natural end, and the dev world has no other users.

**V2. MUST for the deployed body, not talk: with talk disabled, the generic `interact` strands Claude in a dialogue.**
- `skills.lua` now reports `changed = "conversation"` and never presses twice, which is correct.
- But with `DW_ENABLE_TALK` unset (the default), `input.sweep` returns without any cleanup for the conversation kind, and nothing else closes the dialogue. Combat's raw GenericBack escape runs only during a fight.
- The census lists NPCs (Wise Old Man, Doric) with the action `interact`, and the `interact` description says it "talks". So the live brain can open a dialogue and then find every gated action refused: gather, farm, fishing, agility, build, combat's inject, the fed reflex's presses, and spells (`busy_on_modal`).
- This predates rev 3; it is my original finding 13. It matters now because the files load straight from the repo (`DW_CLIENT_ROOT`).
- **Fix:** while talk is disabled, the interact episode that opened the conversation leaves it at once, with the panel's own `CancelInputAction`. It is the modal's opener, so this is a player's Esc and not the RPC. It then reports truthfully, e.g. "they started talking, but I can't hold a conversation yet, so I said goodbye".
- Alternatively, keep NPC interaction out of the `interact` description until talk ships.

**V3. MINOR: `same()` by short name.**
- An NPC's `DomConversationParticipant` component and the player's could share a short name. Only the panel's participant is compared, and there is one panel on this client, so this is harmless today.
- `U.fullname`/`U.path_of` would be exact, at the same cost.

**V4. MINOR: hot reload mid-job.**
- `_G.DWTalk.claimed` and input's `owners.conversation` survive a reload. If a job was running, `claimed` stays true: `ui_press` then skips its claim, and the gate never sweeps the conversation.
- Recursion is still impossible, thanks to the two guards.
- On module load with no live job: clear `claimed` and release `"conversation"`.

## Live plan

1. **P1 (standalone, read-only):**
   - read the components, `LastMessage`, quests and the panel's input actions;
   - register both hook paths through hookhub, and confirm the client stays healthy for a few minutes. These are hooks on an incoming client RPC and a BP event: count only, nothing sent;
   - check that `same(panel.DomConversationParticipant, ours)` is true live.
2. **P2 (`DW_ENABLE_TALK = true`, ClaudeDev):**
   - talk → read → confirm `hook_count` rose with a content change (`hook_proven`);
   - leave → confirm inactive, and no claim left;
   - then one harmless choose, recording `picked_via`.
   - If the option key does not reach the panel (`input_not_reaching_ui` / `no_visible_change`), stop: this is the 18a decision point.
3. **P3** only after P2's evidence, with the quest before/after snapshot logged.

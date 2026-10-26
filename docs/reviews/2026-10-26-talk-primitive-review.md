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

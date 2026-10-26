# Talk to NPCs: `talk {target?, choose?, leave?}` (design, for review)

Status: REV 2, 2026-10-26 (skills-coverage agent). Review docs/reviews/2026-10-26-talk-primitive-review.md (approve with changes) folded in, §8. Code: client_mod/scripts/talk.lua v2, awaiting a cold re-review. Build 26161880. Dev world only. Items marked **[UNVERIFIED]** come from the reflection dump and need the live probe in §7.

## 1. Goal (what Luis will see)
Claude walks up to an NPC (the Wise Old Man, Zanik, ...), talks to him, and reads the NPC's lines and the answer options. **He** picks an answer, the model does, from the option texts, and says what he chose and why. He sees the quest change that follows.

This is needed for:
- the skill-tutorial quests: Growing Pains (Farming), Shrimp Catcher (Fishing; the wiki says "choose option 2");
- M5: Rune Mysteries → Goblin Diplomacy;
- the M6 Brynmoor progression stages.

## 2. What the game has (dump 26161880)
- **NPCs.** `AInteractableNPC` (Dominion.hpp l.11256) has an `InteractionComponent`. The census already lists them as interactables, e.g. Wise Old Man, prompt "Talk" (DISCOVERIES R2 census). A talk is one interact press, as a player presses E.
- **Conversation state.** It lives on the player controller.
  - `ADominionPlayerController.ConversationComponent` (`UPlayerConversationComponent`, l.10226) has `.DomConversationParticipant`, a `UDomConversationParticipant : UConversationParticipantComponent` (CommonConversationRuntime.hpp l.215).
  - The participant has `ConversationsActive`, `IsInActiveConversation()`, and **`LastMessage`**, an `FClientConversationMessagePayload`:
    - `Message.ParticipantDisplayName` is the speaker;
    - `Message.Text` is the line;
    - `Options[]` are `FClientConversationOptionEntry {ChoiceText, ChoiceTags, ChoiceType (ServerOnly / UserChoiceAvailable / UserChoiceUnavailable), ChoiceReference}`;
    - `CurrentNode` is the node handle.
  - This is the replicated client copy the dialogue UI renders.
- **The dialogue screen.** `UConversationMainPanel` (l.17832, `WBP_Conversation_MainPanel_C`):
  - text: `Text_SpeakerName`, `Text_SpeakerLine`;
  - `AllOptions[]`, each a `UConversationAnswerItemData` (l.17823) with `DisplayName` (its text, from `UDomListItemData`) and **`InputAction`**, the key that picks it (number keys);
  - `OptionSelectInputActions[]`;
  - **`ContinueInputAction`** and **`CancelInputAction`**;
  - `OptionSelectMappingContext`.
  - Its handlers `HandleConversationUpdated/Started/Ended` are what the game calls when a payload arrives.
- **Quests.** `ADominionPlayerController.QuestProgressComponent.Quests[]` holds `FQuestProgress {Data (UQuestData: QuestName), State (EQuestState Ungiven/Given/Complete), CurrentObjective (FName), QuestInts, QuestBools}`, plus `GetCurrentObjectiveText(QuestData, out FText)`. The bench probe already reads `quests` (`client_mod/commands/bench_probe.lua`).
- **Rejected paths:**
  - `RequestServerAdvanceConversation` / `ServerAdvanceConversation(FAdvanceConversationRequest)` and `Server_StartConversation`. These are RPCs that take hand-built structs (`FConversationChoiceReference` with node handles), which CLAUDE.md §0 forbids.
  - `UAsyncAction_DomStartConversation`, which bypasses the player's interaction.

## 3. Approach: the player's own path
1. **Start:** `talk {target}`. Walk to the NPC (move.go_to), face him until the game's interact detector targets him (`inventory.interact_target`), then press interact once (`inventory.press_interact`). Verified when the participant becomes active, or `LastMessage` changes, within 4 s.
2. **Read:** speaker, line and options. Options come from the panel's `AllOptions` (what is on screen: text + its own input action), cross-checked with `LastMessage.Options` (text + available or unavailable). Each option is returned as `{n, text, available}`.
3. **Continue lines:** a node with no user choice shows only Continue. `talk` presses the panel's `ContinueInputAction` and collects each line until a real choice appears or the conversation ends, at most 8 lines. This is what a reader does; no decision is made.
4. **Choose:** `talk {choose: n | "<option text>"}`.
   - Resolve against the options **last returned**: an exact index, or an exact (case-insensitive) or unique-substring text match. Otherwise `invalid_args` with the options listed. The model's own words are matched only to the options it was shown; no phrase table.
   - Inject that option's own `InputAction` through `input.raw_inject`, since the dialogue owns the input mode.
   - Verified when `LastMessage` changes (node, line or options) or the conversation ends, within 3 s.
5. **Leave:** `talk {leave: true}` presses `CancelInputAction`. Verified inactive.
6. **Quests:** every reply carries `quests_changed: [{quest, from, to, objective}]`, diffed from `QuestProgressComponent.Quests` before and after. The M5/M6 predicates read the same field from the harness probe.

Ownership:
- The arbiter is held at level `command` only for the walk-and-press, released after each call.
- While the dialogue is open, `input.gate` already blocks other modules' gameplay presses (the input mode is not gameplay).
- `talk` claims `input.claim("mode", "talk")` while a conversation is open and releases it at the end.

Reasons (data.why + one truthful sentence):
- `unknown_target`;
- `not_talkable`: the detector never targets him; the sentence names what it does target;
- `no_conversation`: he pressed, but no dialogue opened;
- `not_in_conversation`: choose or leave while nothing is open;
- `invalid_choice`: lists the options;
- `option_unavailable`: the game greys it out;
- `no_change`: pressed, but nothing advanced;
- `screen_open`: another modal;
- `path_blocked`, `interrupted`, `companion_down`.

## 4. Precedent (sources listed at the end)
- **RuneLite / Microbot.** The dialogue widget's options are read as text, and the bot clicks the option by text. The idiomatic bot pattern is read state → present options → pick → verify the next state.
- **Yarn Spinner's `RunOptions`.** The view shows the options and calls back the selected index; the dialogue engine advances. Same split: the UI owns the choice input.
- **UE CommonConversation.** The client gets `FClientConversationOptionEntry` lists, and the UI turns the player's pick into the advance request. We let the game's own panel do that from the injected key, which is the player's path.

**Decision: adapt.** Read the payload and panel, inject the panel's own option and continue keys, and verify from the payload.

## 5. Generality check
No NPC, quest or option names in code. Talkable targets are any interactable the census lists. Options are whatever the game shows. The choice is the model's. Quest diffs come from game data, so the next NPC or quest needs nothing new.

## 6. Principles
- PRINCIPLES 1 (real paths): kept. Interact key, panel input actions, read-only state.
- PRINCIPLES 2: the model chooses; code resolves the index or text against the shown list only.
- PRINCIPLES 4b: `talk` is one primitive. Start, choose and leave are its modes, because the dialogue state couples them.
- PRINCIPLES 7: every failure carries a sentence.
- Nothing bent.

## 7. Acceptance
- **Offline:** `client_mod/tests/test_talk.lua`. A fake dialogue tree covers start, continue lines, choose by index and by text, an unavailable option, an invalid choice, leave, quest given/complete diffs, not talkable, pressed with no dialogue, modal open, pause and cancel.
- **Live (dev, slot):**
  - **P1, read-only:** `ConversationComponent`, `DomConversationParticipant`, `LastMessage` and `QuestProgressComponent.Quests` while idle; `FindFirstOf("ConversationMainPanel")` and its `ContinueInputAction` / `CancelInputAction` / `OptionSelectInputActions`.
  - **P2:** talk to the Wise Old Man, read the lines and options, leave.
  - **P3:** the Shrimp Catcher start (after he crafts a Coarse Net): choose the net option and see quest Given in `quests_changed`.
- **[UNVERIFIED]:**
  - injecting `AnswerItemData.InputAction` picks that option (vs a click-only list);
  - `Continue` advances lines;
  - `LastMessage` updates on the owning client;
  - the dialogue switches the PC input mode;
  - `AllOptions` order equals the on-screen numbers.

## 8. Rev 2: the review findings and how they are handled
| # | Finding | Rev 2 |
|---|---|---|
| 1 | Continue may confirm a highlighted option | Continue is pressed only when the **same-tick** full read shows no UserChoiceAvailable/Unavailable option with text **and** the panel's AllOptions is empty. One press per verified update (the hook counter). Test: "options appear between read and press → no Continue". Whether Continue confirms CurrentSelectedOption is **[UNVERIFIED]**, watched read-only in P2. |
| 2 | Number keys may only highlight | choose waits `highlight_wait_s`. If no payload update arrived and the panel's `CurrentSelectedOption` text **is the model's chosen option**, it presses confirm (Continue) once. Otherwise it never confirms. Fake tree: a two-step-selection panel. |
| 3 | Stale options | Every reply carries `node` (signature: node handle fields as read, speaker, line, option texts and types, panel texts). choose re-reads first; on any difference it fails `options_changed` with the new options and node. |
| 4 | ServerOnly / numbering | ServerOnly entries are excluded. `n` = the option key's position in `OptionSelectInputActions` (the on-screen number), falling back to list order. Panel rows and payload entries are joined by text. |
| 5 | False negatives on start/hubs | Opened = `ConversationsActive > 0` **and** `ConversationComponent.CurrentNPC == target`, checked each tick during the episode. Advance = a count-only hookhub post-hook on `PlayerConversationComponent:HandleConversationUpdated` (no parameter reads), so identical hub payloads still count. The DIM_ConversationUI input mode is cross-checked. |
| 6 | Quest side effects | The diff covers State, CurrentObjective, QuestInts and QuestBools. The baseline is taken at conversation start; the diff is cumulative and re-diffed on end. |
| 7 | Conversation modal kind | input.lua kind "conversation" (capability agent). Until then, talk accepts "mode" only when the mode name contains "Conversation". talk presses through `input.inject(act, nil, {modal = kind})`, never raw. |
| 8 | Combat's GenericBack ends dialogues | Combat agent owns the escape. talk notices a conversation that ended without its Cancel and says so in the next reply (`note`). |
| 9 | Orphan dialogue | `talk.sweep_orphan()`: ownerless = no talk conversation recorded, a different NPC, or no talk call for 300 s. After `orphan_s` it presses the panel's own Cancel, at most 3 times (read back between), then reports `stuck`. Called by input.lua's sweep (capability agent) and at every talk call. Never the abort RPC or HideConversationUI. |
| 10 | Pause / travel | Under DW_PAUSE there are no game calls, the job ends `companion_down`, and the conversation state is cleared. A pawn change clears it too. Test: "pause mid-choose → no inject; then not_in_conversation". |
| 11 | Stay-fed reflex not gated | inventory owner. |
| 12 | Other tools in a conversation | Perception: get_state `conversation = {npc, speaker, line, options}` (talk.state_extras, read once per update). The shared busy reason in move/episode belongs to its owners. |
| 13 | Reuse the interact episode | `talk {target}` = `skills._new_episode` + `skills._episode_poll` (the capability agent exports `_new_episode` and adds the "conversation" press signal). talk checks the opened signal every tick first, so the episode never presses a second time. |
| 14 | Per-tick reads | Per tick: the hook counter, ConversationsActive, CurrentNPC, CurrentInputMode. The payload and panel are read once per change, bounded (`each_cap`). Only ChoiceText/ChoiceType are read, never ChoiceTags, ChoiceReference or ExtraData. |
| 15 | Finding the panel | find_all + skip_defaults + valid + `panel.DomConversationParticipant == ours`; cached and re-validated. If the panel never builds headless: stop and report, never the RPC. |
| 16 | Hook safety | The hook goes through hookhub (paused-aware, never unregistered), count only. Its registration is confirmed harmless in P1 first. |
| 18a | CommonUI vs Enhanced Input | Epic's page says non-generic actions fire Enhanced Input events but not CommonUI action bindings. Whether the injected option key reaches the panel is therefore the first live question. **Fallback order, decided now:** (1) the injected action; (2) the option button's own UI handler (e.g. the list's selection call), behind `cfg.ui_handler_fallback = false` until probed offline and live; (3) stop and ask Luis (`input_not_reaching_ui`). **Never** the advance RPC. |
| 19 | Map opened mid-conversation | Active with a mode that is neither conversation nor gameplay → `screen_open`, naming the mode. |
| 20 | No dialogue UI | Active with no panel → `no_dialogue_ui` with the line; nothing pressed. |
| 2c | Argument combinations | target with choose or leave → `invalid_args` (mixed_args). `{}` with a conversation open → re-read. `{}` without one → `not_in_conversation`. |
| 22 | P3 changes quest state | P3 only on ClaudeDev; the before/after quest snapshot is logged. P1 (read-only, with the hook registration) runs first and separately. |

## Search record
- UE CommonConversationRuntime API, `FClientConversationOptionEntry` (choice_text, choice_type, choice_reference; extra_data is not sent back): https://docs.unrealengine.com/4.27/en-US/API/Plugins/CommonConversationRuntime/FClientConversationOptionEntry/index.html
- CommonConversationRuntime plugin index: https://docs.unrealengine.com/4.27/en-US/API/Plugins/CommonConversationRuntime/index.html
- Epic, "Using CommonUI with Enhanced Input": non-generic actions fire Enhanced Input events, not CommonUI action bindings; generic accept/back bind to UI. This is the 18a risk. https://dev.epicgames.com/documentation/en-us/unreal-engine/using-commonui-with-enhnaced-input-in-unreal-engine
- UE forum, CommonUI buttons and Enhanced Input actions: https://forums.unrealengine.com/t/any-way-for-commonui-buttons-triggering-enhanced-input-action-to-trigger-pressed-visuals/2800624
- Microbot upstream (RuneLite-based OSRS client; `Rs2*` util classes read dialogue widget options as text and select by text): https://github.com/chsami/Microbot
- RuneLite source, the client API that exposes dialogue widgets to plugins (widgets read as text and clicked through the client): https://github.com/runelite/runelite
- Yarn Spinner `DialogueViewBase.RunOptions` (the view presents options and calls back the chosen index): https://docs.yarnspinner.dev/api/csharp/yarn.unity/yarn.unity.dialogueviewbase/yarn.unity.dialogueviewbase.runoptions
- Wiki: "Shrimp Catcher" (craft a Coarse Net, talk to the Wise Old Man, choose option 2), "Growing Pains", "Rune Mysteries", "Goblin Diplomacy". https://dragonwilds.runescape.wiki/w/Shrimp_Catcher

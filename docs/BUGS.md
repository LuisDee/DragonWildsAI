# Live bug ledger

One row per bug seen live. Every fix lands with a regression test (PRINCIPLES #10). Status: open → assigned → fixed (test name) → verified live.
Evidence: `client_io/events/chat.jsonl`, `logs/brain-live-*.jsonl`, `logs/client/client.log` (UTC times).

## 2026-10-25 evening (Shockbyte, build 26161880)

| ID | Symptom (what Luis saw) | Root cause (from logs) | Owner | Fix / test | Status |
|---|---|---|---|---|---|
| L1 | "Axtral Projection didn't get selected" ×9 (20:54) | The spell has a game special requirement (`SpecialRequirementsText` "Logging Axe", strategy `BP_USSRS_RequiresLoggingAxe`); he had no axe, so the game ignored the wheel key. Our row said `castable:true` and the failure said only "not selected". | spells | Read each spell's `SpecialRequirementsStrategy` → `AreSpecialRequirementsMet(PC)` (the game's own check) into the row (`castable`/`reason:"requirement"`, `needs:"Logging Axe"`); failure says the game's requirement text. | assigned |
| L2 | Unresponsive about 3 min after "get out of the shelter" (20:58–21:01) | `go_to` while lying in bed: body timeout 46 s, then the executor retried; the bridge reload at 20:59 lost the in-flight command, so the brain waited the full 125 s bridge timeout, then retried again. Chat queued behind the blocking call the whole time. | broker + capability | (a) chat is never blocked behind a running tool (interrupt/queue); (b) a bridge restart fails in-flight commands at once (`body_restarted`); (c) no blind executor retries of timeouts — the result goes to the model; (d) movement while resting returns `resting` with "I'm in bed; I need to get up (interact) first". | assigned |
| L3 | Said "Done." after picking up 2 items when asked to pick up AND cast (21:01, 21:02) | Old brain: the canned "Done." template after the last action; no continuation turn, so the cast never happened. | broker | The agent loop (results back to the model up to 4 turns) + no canned "Done." — live since the 21:04 brain restart; verify. | fixed (test_event_hygiene), verify live |
| L4 | Raw codes said in chat: "not perceived within 80 m", "I couldn't go to: unknown_target." | Old fallback templates spoke the tool's raw detail/reason. | broker | Removed in the new brain (21:04); verify. | fixed, verify live |
| L5 | Says what he'll do, then doesn't do it (21:02:56 "I'll walk closer and cast it") | Old brain: speech-only turn, no action and no continuation. | broker | Agent loop (21:04); add a guard test: a turn whose text promises an action must contain the tool call (fake-model replay of 21:02:56). | assigned |
| L6 | Slow replies (2–4 s per step, minutes for chains) | Each turn: 3 redundant `get_state` round trips before one tool; ~13k-token prompt; follow-ups serial; Haiku latency. | broker | One state read per turn (cached ≤1 s); immediate short ack when an action starts; measure p50/p95 turn latency in the timeline. | assigned |
| L7 | `interact` on the Steel Logging Axe grabbed/targeted the Iron Pickaxe → `not_interactable` | The detector targets whatever is in front (nearest pile item), not the asked-for actor. | capability | Approach/face the asked-for actor until the detector names it; if another item blocks, say which. | assigned |
| L8 | `go_to` a tree id (`fol:...Tree_C_7:2`) → `unknown_target` ("target_not_visible") although `look` listed it | go_to doesn't resolve foliage-instance ids that look/gather produce. | capability | go_to resolves every id that look returns (foliage, interaction points). | assigned |
| L9 | Aimed cast → `too_far` without moving closer | Aimed spells have a reach; the brain didn't chain go_to, and go_to failed (L8). | spells + broker | Failure states reach and distance (done); the loop lets the model walk closer (L3/L8). | assigned |
| L10 | Slept in the wrong place / kept summoning new shelters beside an existing one; "painful" to get to sleep; stayed in bed after day | No perception of who owns a shelter; no house rules; no day/rest trigger to the model; interact aimed at the actor origin (roof). | capability + broker | Shelter owner in perception; house rules file (below); `situation_review` on day change while resting; interact uses the entrance collider (fixed 20:59, verified live: slept, got up). | assigned |
| L11 | Client crash 20:49:34 after the pause-menu Unstuck teleport | UE4SS `push_arrayproperty` on an actor the teleport replaced. | locomotion | Unstuck disabled (move.lua v15); per-frame array reads audit for sense/combat/traverse_learn. | fixed (disabled), audit open |
| L12 | Debug-channel actions pre-empted the brain's interact ("I couldn't interact: interrupted") | The debug channel shares the body's action slot. | capability | Debug channel refuses actions while a brain action owns the slot (unless `force`). | assigned |

## House rules (Luis's explicit rules → given to the model, not code vetoes)
Lives in `brain/house_rules.md`, loaded into the persona; Luis can add lines.
- Sleep in your own shelter. Don't use another player's shelter or bed unless that player asked you to.
- Get up and out of bed as soon as it's day.
- (PvP is off: never attack players.)

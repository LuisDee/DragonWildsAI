# Humanoid companion: clarified goal and routes (2026-10-25)

## Goal (Luis, verbatim intent)
The companion is a **humanoid that is basically another player**: it equips armour and weapons like a standard player, switches weapons, kills enemies, picks up loot, does tasks, and can be talked to, in real time, "as if you yourself were in the world and could operate like a standard player". **A creature that follows is not the goal.** It only proves the mechanism.

## What is proven (build 26161880)
- Server-spawned and server-controlled AI characters replicate correctly to a vanilla GFN client.
- `DominionAICharacter:Confuse(pawn, true)` makes a creature follow and keep up. `mod/scripts/companion.lua` re-acquires a follower on every join.
- Chat can be read server-side (`Server_SendChatMessage`). Speaking in chat is not tested yet.
- Player equipment is handled server-side: `DominionPlayerEquipment ... [DedicatedServer] UnequipHeldEquipmentActor / HandleHeldBunchedRepd`. Actions are server-authoritative: `DomNetActIntIds AUTH : Action Accepted`.

## Routes, in order of fidelity
1. **Player pawn driven by the server (Luis chose to try this first).** Spawn `/Game/Gameplay/Character/Player/BP_PlayerCharacter.BP_PlayerCharacter_C` and drive it with an AIController (optionally with a PlayerState, as UT and Lyra bots do).
   - Risks:
     - Inventory, skills and chat live on `DominionPlayerController`.
     - The character profile is streamed from the client on join, so a bot has none and its equipment must be granted server-side.
     - Attacks may run through a client-predicted action stream.
     - The server may crash (acceptable: throwaway world).
   - Experiments, in order (module `mod/scripts/puppet_test.lua`, run via `debug_run`):
     1. Spawn next to Luis.
     2. Possess (SpawnDefaultController, else AIController).
     3. MoveToLocation(Luis).
     4. Equip a weapon and armour server-side.
     5. Attack, via the action system or server-side damage.
     6. If the controller dependencies block us, try a PlayerController with no client.
2. **Friendly humanoid AI.** A Black Knight or goblin variant flipped to the player's side, using the game's own combat AI. It is not player-looking, its weapons are its own kit, and loot would be simulated. The template to study is how `BP_AI_KalphiteFriend_Character_C` is made friendly.
3. **A second real game client** on a GPU VM with its own licence, driven by a computer-use or VLM agent. A real player by definition, but costly and slow. Luis's call (CLAUDE.md Phase 4 kill criterion).

## Research in flight
- `docs/research/2026-10-25-humanoid-companion-dump.md` (dump analysis): player-pawn dependencies, the equipment and action system, factions, loot, and speech struct fields.
- `docs/research/2026-10-25-player-like-bots.md` (web): how UE games and mods build player-like bots, headless clients, Dragonwilds community knowledge.

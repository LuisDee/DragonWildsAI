# Traversal for Claude's client body: jumps, gaps, double jump, dash, Windstep (2026-10-25)

Scope: research and design only. No live control or restarts were done for this note.
Context: route R2 (`docs/design/real-player-remediation.md`). The locomotion service is
`client_mod/scripts/move.lua` (owned by the locomotion agent): per-frame `AddMovementInput`, `Jump()`, the
dev-server nav oracle, a stuck ladder and leader breadcrumbs. Luis wants Claude to cross technical terrain like
a skilled player. Verified dump facts are in DISCOVERIES "Traversal (R2)".

---

## 0. What the failing follow test tells us (client UE4SS.log, 2026-10-25 18:52-18:54 UTC)

The log has `move: stuck` lines from the follow test where Claude stayed stuck after Luis left a covered,
player-built area.
- Claude's capsule centre stayed at **(7158..7163, 186198..186203, Z -3460..-3468)** for over 90 s and moved 0-7 cm per window.
- The nav path was `partial`, ending at Z -3520 beside him. That is the navmesh at **his** level.
- The goal (Luis) was at Z -3134. Every breadcrumb he was aiming at (`aim=(7741,186373,-3126)`) was **about 3.3 m above him**.
- The trail index jumped from 2 to 21 within about 2 s (`trail=2/20` → `21/32`). The breadcrumb advance test is 2D (`d2`, "closer to the next one than this one is"). Crumbs on a floor 3.3 m higher counted as reached while he stood underneath them.
- The ladder (jump → double jump → strafe → backtrack) repeated every about 6 s. A single jump can't clear 3.3 m. A double jump probably isn't available either: Claude's character is Agility 1, and Double Jump unlocks at Agility 10 (section 2.2).

**Lessons the design must fix:**
1. **Advancement must be 3D.** A crumb or waypoint counts as reached only within a step height in Z. Otherwise the follower aims at a different floor.
2. **"Stuck" is not one thing.** The body has to *classify* the obstacle: a 3.3 m ledge-up beyond the envelope, a gap, or a wall. Then it picks a feasible move, or a different route, or reports. Jumping blindly at a 3.3 m wall is the Bloog-bot failure mode (no stuck handling) with extra steps.
3. **The breadcrumb recorder drops airborne samples** (`record_crumb` returns when `IsMovingOnGround()` is false). Those samples are exactly *where and how the leader jumped*. They should be kept as traversal events, not discarded (section 3.5).

---

## 1. Precedents and idiomatic techniques

### 1.1 Off-mesh links: the standard representation
| System | What it is | Notes for us | Source |
|---|---|---|---|
| **Recast/Detour off-mesh connections** | `dtOffMeshConnection`: a user-defined link with two endpoints (A must be on the mesh, B need not be), a radius, and poly flags/area. Pathfinding treats it as an edge. The path corridor reports when the agent reaches the link, and the game plays the move. | The canonical model: a link is **data (endpoints, type, cost)** plus a **move executor**. UE's Detour fork adds segment-to-segment links (`dtOffMeshLinkCreateParams`: vertsA0/A1, vertsB0/B1). | https://recastnav.com/structdtOffMeshConnection.html ; https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Navmesh/dtOffMeshLinkCreateParams |
| **UE `ANavLinkProxy`** | Simple links (`PointLinks`, `SegmentLinks`) are static edges with an area class. A **smart link** (`UNavLinkCustomComponent`) fires `OnSmartLinkReached` / `ReceiveSmartLinkReached(Agent, Destination)`. The game then performs the jump and calls `ResumePathFollowing()`. | Same split: the navmesh knows the edge, game code does the traversal. Present in the dump (AIModule.hpp `ANavLinkProxy`). The 4.26 content example warns that bidirectional links can make agents walk into walls. | https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/AIModule/ANavLinkProxy ; https://docs.unrealengine.com/4.26/en-US/Resources/ContentExamples/NavMesh/1_2 |
| **UE 5.5+ automatic nav link generation** (Experimental) | `RecastNavMesh.bGenerateNavLinks` plus `NavLinkJumpDownConfig` {JumpLength, JumpDistanceFromEdge, JumpMaxDepth, JumpHeight, JumpEndsHeightTolerance, SamplingSeparationFactor, FilterDistanceThreshold, Down/UpDirectionAreaClass, LinkProxyClass}. It runs during tile generation and samples trajectories off navmesh border edges. Cost grows with JumpLength and the number of border edges. | **Present in this build's dump** (NavigationSystem.hpp `FNavLinkGenerationJumpDownConfig`, `ARecastNavMesh.bGenerateNavLinks`). The docs describe **jump/fall-down** links only. Whether a cooked server can regenerate streamed tiles with it is not documented. | https://dev.epicgames.com/documentation/en-us/unreal-engine/automatic-navigation-link-generation |
| **Unity auto OffMesh links** | The bake walks NavMesh edges, tests whether a landing point is on the NavMesh and whether the trajectory is clear, then creates *drop-down* and *jump-across* links. Tip from the docs: jump distance is measured mesh-to-mesh, so **add 2 × agentRadius plus a margin**. | The edge-walk + landing-check + clear-arc recipe is what we can run against our oracle (section 3.6). | https://docs.unity3d.com/cn/2022.3/Manual/nav-BuildingOffMeshLinksAutomatically.html ; https://docs.unity.cn/Packages/com.unity.ai.navigation@2.0/manual/NavigationWindow.html |
| **A\* Pathfinding Project (Unity)** | Manual off-mesh links for jumps, climbs and doors, with one-way links for ledge drops. The forum confirms there is no automatic gap-link generation. | Even mature middleware falls back to hand-placed links, which supports learning links from demonstrations. | https://arongranberg.com/astar/docs/offmeshlinks2.html ; https://forum.arongranberg.com/t/jumping-gaps-in-richai/13002 |
| **Utrecht MSc thesis "Navigating Jumping Agents Through Virtual Environments"** | Automatic jump-link generation as a Recast extension on any triangle soup, reported to run in seconds on large scenes. | An algorithm reference, not reusable code (no public repo found). | https://studenttheses.uu.nl/handle/20.500.12932/22818 |

### 1.2 Traversal in shipped games and middleware
- **Havok Navigation for Unreal: "Automatic Traversal Analysis."** It marks the nav mesh for character-specific traversals (jump, duck, vault, climb up, drop down, balcony vault, custom). A GDC 2025 Game AI Summit talk explained that manual traversal annotation "grinds iterating on content to a halt". PC Gamer's coverage of Ben Sunshine-Hill's talk says candidates are checked along jump-arc trajectories. Commercial, so not reusable here, but it confirms the idiom: **per-character capability → generated links**.
  https://www.havok.com/havok-navigation-for-unreal/ ; https://www.havok.com/blog/havok-navigation-for-unreal-overview/ ; https://gdcvault.com/play/1035587/Game-AI-Summit-Navigating-Expansive ; https://www.pcgamer.com/how-to-teach-an-ai-parkour/
- **Brink's SMART (Splash Damage, GDC 2012, "Vault, Slide, Mantle").** It precomputes "every possible movement option" from world geometry, which avoids hand-placed hints. A lightweight runtime ledge detector then makes sure the character enters the right physics state. So the industry pairs a **precomputed link set with runtime ledge sensing**.
  https://gdcvault.com/play/1015813/Vault-Slide-Mantle-Building-Brink ; https://gamedeveloper.com/design/video-building-i-brink-i-s-smart-parkour-traversal-system
- **God of War Ragnarök companion traversal (GDC 2023, Salaar Kohari).** It uses the navmesh for character-specific traversal and companion pathing, with level-designer components for companion traversal. The abstract only is public; the jump-link details are behind the Vault.
  https://gdcvault.com/play/1029003/Companion-Traversal-in-God-of
- **Suicide Squad: KTJL (GDC 2024).** The AI path is annotated, broken into "featured patterns" and solved by an HTN-style planner into traversal plans. That is a layered planner over typed traversal segments, close to our router + executor split.
  https://schedule.gdconf.com/session/choreographing-superpowered-ai-movement-in-suicide-squad/902876
- **Game AI Pro 2, ch. 21 "Dynamic Obstacle Navigation in Fuse" (Jan Müller).** Traversal adds markup, programming and animation work, so most games restrict AI to the continuous walkable mesh.
  https://www.oreilly.com/library/view/game-ai-pro/9781482254792/K23980_C021.xhtml
- **Ubisoft La Forge, "Deep RL for Navigation in AAA Video Games" (IJCAI 2021, GDC 2021 ML Summit).** With abilities like double jumps, grappling hooks and jump pads the navmesh gets "so complex it becomes impractical". They trained RL agents instead, with ≥ 90 % success, including on a Hyper Scape map. That is out of scope for us (training infrastructure, no simulator), but it explains why the problem is hard.
  https://arxiv.org/abs/2011.04764
- **ARC Raiders (Embark, GDC 2026).** RL-learned physics-based locomotion (walk, jump, climb) under behaviour trees, trained offline and not on player data. Not applicable (a physics body, not a CharacterMovement player).
  https://schedule.gdconf.com/session/learning-to-move-physics-based-enemy-locomotion-in-arc-raiders/917319

### 1.3 Bot frameworks with a movement-capability model (the closest analogues to a player bot)
- **Baritone (Minecraft) `MovementParkour`** (source read). The bot's capability is explicit:
  - max gap 3 walking and 4 sprinting, landing block required, headroom checks, "ascend parkour" up one block when sprinting;
  - the cost is distance × sprint cost + `jumpPenalty`;
  - execution: sprint for long jumps, jump when the feet reach the edge block or as soon as airborne, back up to reposition if not aligned;
  - failure detection: feet below the start Y means `UNREACHABLE`;
  - it can only be cancelled on tick 0, because momentum isn't modelled.
  
  This is the template for our **move executor** (align, run up, take off at the edge, verify landing, classify failure).
  https://github.com/cabaletta/baritone/blob/master/src/main/java/baritone/pathing/movement/movements/MovementParkour.java
- **mineflayer-pathfinder `Movements`**: `allowParkour` (gaps over 1 block), `allowSprinting`, `maxDropDown` (default 4; it only counts drops with a landing block), and `infiniteLiquidDropdownDistance` (drops into water are safe). A known bug: with sprint off but parkour on, the bot sticks at 2-block gaps. That is a **capability envelope** as configuration, and a warning that the envelope must match the actual movement state.
  https://npmjs.org/package/mineflayer-pathfinder ; https://glama.ai/mcp/servers/@leo4life2/minecraft-mcp-http/blob/c7752ab161fe7615b229c22d1bc06123e4aa998c/mineflayer-pathfinder/readme.md
- **WoW "Bloog bot"** (already cited in client-side-botting.md): an offline Detour mesh, repath every update, **no stuck handling**. `wow-navmesh` on PyPI wraps Detour queries over WoW `.mmap` files. That is evidence that "export the mesh once, query locally" is a known bot pattern, but only where an extractor exists.
  https://drewkestell.us/Article/6/Chapter/20 ; https://pypi.org/project/wow-navmesh/

### 1.4 Ledge and gap detection with traces
- **The idiomatic UE recipe** (forum answers, Fab traversal plugins): a downward trace from a point *ahead* of the pawn. If nothing is hit within the step-down distance, there is a ledge. Forward traces at several heights find a wall. A downward sweep from above the wall top measures the ledge height. Sphere or capsule traces measure obstacle height and depth to choose hurdle/vault/mantle.
  https://answers.unrealengine.com/questions/834348/view.html ; https://www.fab.com/listings/bdd629ed-c035-4c87-bef2-46e13150bf66 ; https://auroradevs.gumroad.com/l/replicated-traversal-system
- **Engine helpers that are reflected in this build** (dump, DISCOVERIES Traversal):
  - `UCharacterMovementComponent:K2_FindFloor(CapsuleLocation, out FFindFloorResult)` and `K2_ComputeFloorDist(...)`: the CMC's *own* floor sweep, with the character's real capsule, at an arbitrary location. That is the best "is there walkable floor here" probe.
  - `UKismetSystemLibrary:LineTraceSingle / SphereTraceSingle / CapsuleTraceSingle` (bool return plus `out FHitResult`).
  - `UGameplayStatics:Blueprint_PredictProjectilePath_Advanced` (arc check; struct params, so R15 risk).
  - On the dev server: `NavigationSystemV1:NavigationRaycast(ctx, start, end, out HitLocation, …)`, which finds where the navmesh ends along a ray (flat `FVector` out, the same pattern as the proven `K2_ProjectPointToNavigation`).
- **No search result showed UE4SS Lua calling a trace and reading `FHitResult`.** The locomotion agent then **verified it (T1 passed)**:
  - `LineTraceSingle` works from Lua on the dev server and on the client, about 1 ms per trace.
  - The out table fills **nested**: `out.ImpactPoint.Z`, `out.ImpactNormal.Z`, `out.Distance`, `out.Time`.
  - `out.bStartPenetrating` is junk: it shares bitfield byte 0xAD with `bBlockingHit` and reads true on clean hits. Use `Distance == 0` for "started inside geometry".
  - `K2_ComputeFloorDist` works on the dev server (`bWalkableFloor`, `FloorDist`).

### 1.5 Capability envelopes (jump physics)
- UE: `GetMaxJumpHeight()` = JumpZ² / (2·|GravityZ|), ignoring hold time. `GetMaxJumpHeightWithJumpTime()` includes `JumpMaxHoldTime`. Both are reflected.
  https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/GetMaxJumpHeight ; https://answers.unrealengine.com/questions/100965/view.html
- Flat-ground airtime is t = 2·JumpZ/|g| and distance is d = v_h · t. That is first-order only: air control, hold time, `FallingLateralFriction` and Dominion's custom double-jump/dash curves all change it. **So the envelope is measured, not computed** (section 3.3). The formulas are only for sanity checks.
- **Measured live (locomotion agent, 2026-10-25, Claude's client):** JumpZ 807.9, GravityScale 1.85 (`GetGravityZ` −1813), `JumpMaxHoldTime` 0. So h = 807.9² / (2·1813) = **1.80 m**, which matches `GetMaxJumpHeight()` = 180 cm. Flat airtime is 2·807.9/1813 = 0.89 s, so the first-order sprint-jump distance is 0.89 × 6.8 ≈ **6.1 m** and the walk jump 0.89 × 4.5 ≈ 4.0 m. These are upper bounds; E2/E5 measure the real values.

### 1.6 Learning traversal from demonstrations
- **No source was found that turns recorded human jumps into navmesh links.** Searches for imitation/demonstration plus navmesh/off-mesh links came up empty.
- The nearest work is imitation of human navigation in Quake (Thurau et al. 2004, cited in the DCU thesis) and case-based agents from gameplay traces. Both are behaviour-cloning, not link extraction.
  https://doras.dcu.ie/2368/ ; https://doaj.org/article/4a63c99cffff4b30a1abcb84bdbee3e3
- So "action-annotated breadcrumbs → learned jump links" is **our own synthesis** of three standard pieces: breadcrumb following + off-mesh links + Voyager-style verify-then-commit skill library. It is cheap here because Claude's client sees Luis's replicated movement state (section 2.4).

### 1.7 Breadcrumb following as a fallback
- Breadcrumb AI (Unity asset): the leader drops footprints that followers use after losing line of sight. bugnet.io: repath as the leader moves, log where the path failed, and teleport the follower as a last resort.
  https://assetstore.unity.com/packages/slug/18364 ; https://bugnet.io/blog/how-to-fix-companion-or-follower-ai-getting-stuck
- move.lua already does this (`record_crumb`, `nearest_crumb`, `advance`). Section 0 shows the two gaps: the advance test is 2D, and airborne samples are dropped.

### 1.8 Decision (search-before-building)
- **Reuse:**
  - the game's own movement (`Jump`, sprint, double jump, dash and Windstep through the player's input actions);
  - the engine's floor sweep (`K2_FindFloor`) and traces;
  - the dev server's Detour (oracle) for all on-mesh routing;
  - networkx (BSD-3) or stdlib `heapq` for a small Dijkstra.
- **Adapt:**
  - the off-mesh-link model (Recast/UE NavLink: endpoints + type + cost + executor);
  - the Unity edge-walk/landing/arc link generator, run against our live oracle;
  - Baritone's parkour executor (align → run-up → take off at the edge → verify landing → classify failure);
  - mineflayer's capability options as the envelope.
- **Build (thin):**
  - a link *overlay* router above the oracle;
  - the demo recorder and link distiller;
  - the terrain classifier;
  - a per-kind move executor.
- **Don't build:** a navmesh exporter or our own Detour (no extractor exists for UE's Detour fork, which uses `dtReal` doubles and UE-specific tiles; ExportNavigation is an editor/debug geometry dump: https://forums.unrealengine.com/t/exporting-navmesh/439786); an RL agent.

---

## 2. Dominion specifics (dump of server build 26161880; Claude's client is 26162923 and not dumped)

### 2.1 Input actions relevant to traversal (`/Game/Gameplay/Inputs/Actions/...`)
| Action | Path | Use |
|---|---|---|
| `IA_Movement` | Basic/ | the move vector (we use `AddMovementInput`, which is what its handler ends in) |
| `IA_Player_Jump` | Basic/ | jump; `pawn.JumpInputAction`. `pawn:Jump()` / `StopJumping()` are verified |
| `IA_Player_Sprint` | Basic/ | sprint (verified via `InjectInputVectorForAction`; toggle mode `bPressToSprint` = true) |
| `IA_Player_Evade` | Basic/ | evade (dodge) in combat. `UPlayerEvadeAction.DashActionName` exists, so evade and dash share a family. **Hypothesis: Air Dash = evade pressed while airborne** (UNVERIFIED; read `PerkV2_Agility_AirDash.InputActionDisplay.InputAction` to confirm, section 2.2) |
| `IA_Spellcasting_QuickAccess0..7` | Spellcasting/ | cast the spell in a quick slot, the player's route to **Windstep** and **Phase Dash** |
| `IA_VerticalMovementUp/Down` | Basic/ | probably swim up/down (or free-roam camera). UNVERIFIED |
| `IA_Mount` | Basic/ | mounts (not traversal for now) |
| `IA_UnstuckCharacter_Held` | UI/ | **the game's own unstuck** (held). The pause menu has `ProgressButton_Unstuck` and `TeleportToStart()`. It teleports, so it's a last resort and only with Luis's OK |
| `IA_AgilityCourse_Banner_Primary/Secondary` | Agility/ | agility course banners (a future Agility XP source) |

There are **no mantle, ledge-grab, climb, vault or glide** classes or actions in the dump (0 hits for Mantle, Climb and Glide; "Vault" hits are the Vault Core item). Dominion traversal is **jump-based**: jump, double jump, air dash, phase dash, Windstep, breakfall, plus swimming and kebbit burrows.

### 2.2 The traversal moves and what gates them
| Move | Gate (perk / level, wiki or guide) | Engine/game fields (dump) | Trigger on the client |
|---|---|---|---|
| Jump | always | ACharacter `JumpMaxHoldTime`, `JumpMaxCount` (2 on Claude), CMC `JumpZVelocity` 808 (live), `AirControl`, `GravityScale`; Dominion `bJumpBlocked` (replicated), `JumpInhibitors`, `JumpBlockingTagQuery`, `IsJumpEnabled()`, stamina (Hopper perk lowers it) | `pawn:Jump()` + `StopJumping()` (verified) |
| Coyote time | always | `ADominionPlayerCharacter.LedgeForgivenessTime`, `IsInLedgeForgivenessTimeWindow()` | a jump shortly after walking off an edge still works. This makes "jump when we start falling at the edge" a robust takeoff trigger |
| **Double Jump** | `PerkV2_Agility_DoubleJump` (Agility **10**) | `pawn.DoubleJumpSkillPerk`, `GravityToMaxUpwardsVelocityForDoubleJumpCurve`; CMC `GravityToDoubleJumpVelocityCurve`, `MaxFallDistanceForDoubleJump` (no double jump after falling too far), `DoubleJumpBlockingTags`, `MinimumAccelerationForDirectionalDoubleJumpAndDash` (a **directional** double jump redirects toward the input), `UDoubleJumpStaminaCost`; event `OnDoubleJump` (BP) | a second `Jump()` while airborne. **`JumpMaxCount = 2` is not proof of the perk**: Claude is Agility 1, so check `SkillPerkComponent:IsPerkUnlocked(DoubleJump)` and measure |
| **Air Dash** | `PerkV2_Agility_AirDash` (Agility **32**) | CMC `DashDistance`, `DashDistanceToVelocityCurve`, `DashStaminaCost`, `DashCooldownDuration`, `MaxFallDistanceForDash`, `DashBlockingTags`, `DashMontage`, `DashPerkData`, `bWantsToDash`, `DoubleJumpMaxHorizontalSpeedDuringDash`, delegate `OnDash(bWasPhaseDash)`; `ADominionPlayerCharacter:DoDash()` (BlueprintCallable, **Exec**) | probably IA_Player_Evade while airborne (to confirm). `DoDash()` exists, but as an Exec/debug entry it may bypass the input path, so prefer the input |
| **Phase Dash** (2nd air dash, spell) | `PerkV2_Agility_Spell_PhaseDash` (Agility **44**); 20 Air + 10 Astral, 45 s cooldown | CMC `MaxPhaseDashCharges`, `PhaseDashEffectDuration`, `MaxPhaseDashesMidAir`, `EnablePhaseDashes()`, delegates `OnPhaseDashActivated/Deactivated`; spell `USD_PhaseDash` (ExpireAfterDuration 2 s) | cast from a quick slot, then dash in the air |
| **Windstep** (spell) | Agility **5** (wiki; moved from Runecrafting); 5 Air, **3 s cooldown**, `allow_while_falling = false`, `cast_type Instant` (data/spells) | GE `GE_Windstep` with child GEs `GE_ModifyJumpHeight`, `GE_ModifyGravityScale`, `GE_ModifyAirControl`, fall-damage modifiers; removed on landing (`BP_SpellGERemovalStrategy_Windstep`); module `InhibitJumpOnLanding`; CMC `OnLandedWindstepEvent`; anim `bIsWindStepActive`; `ADominionPlayerCharacter.WindstepTag`, `WindstepXPEvent` | cast on the ground (quick slot), **then jump**. Wiki: "jump up to 16 m, slow fall, reduced fall damage, 7 s to use it". It is a **super-jump and glide**, not a horizontal dash (correcting the brief). Wind Stomp (Agility 40) adds a landing stagger |
| Breakfall | `PerkV2_Agility_Breakfall` (35), Greater Breakfall (54) | CMC `MinFallDamageHeight`, `MaxFallDamageHeight`, `FallDamageBlockingTags`, `BreakfallMontage`, `Multicast_ApplyFallDamage(damage, bShouldPlayRollAnim)`, `SetFallDamageImmune`; GE `GE_Skills_Agility_Breakfall` (ModifyMinFallDamageHeight, ModifyFallDamageMultiplier) | passive. **The safe drop height depends on the perks**, so read it live |
| Recall / Reactive Recall | Agility 57 / 70 | spell | saves from fatal falls (later) |
| Swim | engine | CMC `IsSwimming()`, `DefaultWaterMovementMode`, `bCanWalkOnWater` | walk into water. Drops into water are probably safe (UNVERIFIED) |
| Kebbit burrows | Common Burrower (27) and others | `PerkV2_Agility_KebbitBurrows_*` | interact-type links (tunnels), later |

Agility levels are from the BisectHosting guide (https://www.bisecthosting.com/blog/runescape-dragonwilds-agility-skill-guide-how-to-level-all-courses-locations-rewards-more). Update 0.12.1 (29 July 2026) added the horizontal dash on the double jump, the secondary dash and Breakfall (https://www.gamedeveloper.com/press-release/runescape-dragonwilds-update-0-12-1-expands-agility-skill-and-more-now-available-to-play). Tower Climb uses Air Dash (https://dragonwilds.runescape.wiki/w/Tower_Climb).

**Measured (locomotion agent):** `IsPerkUnlocked(DoubleJumpSkillPerk)` = **false**. Claude's limits today: step 0.45 m, jump apex 1.80 m (planning value jump_up 1.65 m), fall damage starts at 15 m (`MinFallDamageHeight` 1500, `MaxFallDamageHeight` 2860; planning drop ≤ 10 m), walkable slope 45.5°, capsule half-height 88 cm.

**Consequence:** today Claude (Agility 1) has **jump plus sprint only**: no Windstep (5), no Double Jump (10), no Air Dash (32). The envelope must come from his perks, and learned links must record which moves they need (section 3.5).

### 2.3 What the client can read about its own movement
- `pawn.CharacterMovement` (DominionMovementComponent): `MovementMode` / `IsFalling()` / `IsMovingOnGround()` / `IsSwimming()`, `Velocity` / `GetLastUpdateVelocity()`, `CurrentFloor` (FFindFloorResult: bWalkableFloor, FloorDist), `GetMaxJumpHeight*()`, `GetGravityZ()`, `MaxStepHeight`, `WalkableFloorAngle`, `LedgeCheckThreshold`, `PerchRadiusThreshold`, `GetSprintingMaxSpeed()`, `IsJumpEnabled()`, `IsCharacterFrozen()`.
- `pawn.JumpCurrentCount`, `pawn.StaminaComponent:GetStamina()`, `pc.SkillPerkComponent:IsPerkUnlocked(perkData)`.
- Hookable for exact timing: `ACharacter:OnJumped`, `OnLanded(Hit)`, `K2_OnMovementModeChanged`, `OnWalkingOffLedge`, and `BP_PlayerCharacter_C:OnDoubleJump` / `OnLandedWindstep` / `BndEvt…OnDash`. UE4SS RegisterHook on BP events is proven in this project. The native ACharacter events are BlueprintImplementableEvents called through ProcessEvent, so they should be hookable (UNVERIFIED).

### 2.4 What the client can read about OTHER players (to record where and how Luis traversed)
Luis's pawn on Claude's client is a **simulated proxy** (present only within net relevancy, DISCOVERIES R2 perception).
| Signal | Field / event | Replication |
|---|---|---|
| position, velocity | `K2_GetActorLocation()`, `GetVelocity()` | ReplicatedMovement (net update rate, about 30 Hz on this server) |
| movement mode (walking/falling/swimming) | `CharacterMovement.MovementMode`, `IsFalling()`, `IsMovingOnGround()`, `IsSwimming()` | from `ACharacter.ReplicatedMovementMode` (simulated-only). move.lua already reads `IsMovingOnGround()` on the leader |
| **jump and double jump count** | `ADominionPlayerCharacter.ReplicatedJumpCurrentCount` (int8, `ReplicatedUsing=OnRep_ReplicatedJumpCurrentCount(PreviousJumpCount)`) | **replicated with a RepNotify, so it is the best jump signal**: 0→1 is a jump, 1→2 is a double jump. Poll it per frame, or post-hook the OnRep |
| jump force applied | `ACharacter.bProxyIsJumpForceApplied`, `ProxyJumpForceStartedTime` | engine, simulated-only |
| evade / dash | `UPlayerEvadeComponent:Multicast_StartEvade(MontageIndex, bSurge, Rotation)` | NetMulticast, so it reaches every client and is hookable. Whether the air dash goes through it or through the CMC `OnDash` delegate (local/server only?) is UNVERIFIED |
| Windstep, spell casts | `PlayerMagicComponent:Multicast_SendPayloadForSpellCasting(SpellNetId)` (spells research X2); `GameplayTagsComponent.ReplicatedGameplayTagStackContainer` (Replicated) holds tags such as `WindstepTag` while active | multicast + replicated tags |
| fall damage, breakfall | `UDominionMovementComponent:Multicast_ApplyFallDamage(FallDamage, bShouldPlayRollAnim)` | NetMulticast |
| sprint | infer from speed: above about 1.15 × MaxWalkSpeed (450 → 680 when sprinting) | `USprintComponent` has only `bMovementBlocked` replicated |
| agility course | `bIsRunningAgilityCourse` (ReplicatedUsing) | replicated |
| montage | `GetCurrentMontage()` on the proxy | UNVERIFIED on proxies |
| far away | `AGameplayObjectRegistry.PlayerCharacters[].Location` (the map's player list, ReplicatedUsing) | probably replicated to all clients regardless of relevancy (UNVERIFIED on the client); a coarse position only |

---

## 3. Design: move.lua v2 as layers

```
brain (Planner/Controller)            go_to / follow / "can you get up there?"
  |
L4 ROUTER (Python, tools/nav_oracle.py "route")   oracle paths + per-world link overlay (Dijkstra)
  |   returns typed segments: walk(points) | link(kind, from, to, heading, inputs) | trail(points)
L3 SEGMENT FOLLOWER (move.lua v2)     per-frame steering, 3D waypoint advance, repath, breadcrumbs
  |   on a link segment, or when L2 reports an obstacle
L2 TERRAIN SENSE (terrain.lua)        forward/down probes -> {step, ledge_up h, gap w, drop d, wall, water}
L1 MOVE EXECUTOR (traverse.lua)       one state machine per kind: align -> run-up -> takeoff -> air -> land -> verify
  |
L0 INPUT                              AddMovementInput / Jump / StopJumping / injected IA_* (sprint, evade, spell slot)
side: ENVELOPE (envelope.lua + data)  measured capabilities per character + perks + buffs
side: RECORDER (observe.lua)          Luis's action-annotated breadcrumbs -> client_io/events/traversal.jsonl
side: LINK STORE (brain/traversal.py) distil demos -> links; per world; feeds L4 and L1
```

**Ownership:** new files only, so move.lua stays the locomotion agent's: `client_mod/scripts/terrain.lua`, `traverse.lua`, `envelope.lua`, `observe.lua`; `brain/traversal.py`; extensions to `mod/experiments/nav_oracle.lua` and `tools/nav_oracle.py`. move.lua v2 calls into them through a narrow API (section 3.8). Small fixes needed **inside** move.lua (the 3D advance, keeping airborne samples) go to the locomotion agent as requests.

### 3.1 L4: route via the nav oracle plus jump links (an overlay graph, not navmesh surgery)
Why an overlay:
- Injecting links into the dev server's Detour, by spawning `ANavLinkProxy` and filling `PointLinks` (`TArray<FNavigationLink>`), means struct-array writes. That is the R15 crash class. It also needs nav re-registration on a cooked, streamed navmesh.
- It would still leave the client unable to tell which path segment is a link (the oracle returns bare `PathPoints`).
- The overlay is the "hierarchical / cluster graph" idiom: Detour for on-mesh legs, our graph for off-mesh edges. It also works later against a local planner or on Shockbyte without the dev server.

Algorithm (`route(from, to, envelope)` in tools/nav_oracle.py):
1. Ask the oracle for `from → to`. If it is `ok`, not partial, and the length is under 1.5 × straight + 20 m, return a single walk segment.
2. Otherwise, collect candidate links: those in the world store with `usable(envelope)` (required moves ⊆ capabilities, not disabled), and both endpoints within `max(150 m, 1.2 × straight)` of the corridor.
3. Nodes = {from, to} ∪ link endpoints. Edge costs come from **one batched oracle call**: extend `nav_oracle.lua` with `{"batch": [[a,b],...]}`, ≤ 64 pairs per call, 2-5 ms each on the server, so ≤ 0.3 s of game thread. Partial or failed paths count as infinite, unless the end of the partial path is within 1.5 m of the target node. Link edges cost `length + penalty(kind)` (Baritone's `jumpPenalty`; for example walk 1, jump +5 m, sprint-jump +8 m, double jump +10 m, Windstep +15 m + runes), scaled up by the link's failure rate.
4. Dijkstra (stdlib heapq; the graph has under 100 nodes). Emit the segment list. If no route exists, return `{ok=false, reason="no_route", nearest_reachable=...}` so the body can say why.
5. **Trail segments:** when the goal is a player standing on something the navmesh doesn't know (a player-built floor), and the recorder has a fresh grounded trail from a navmesh-reachable point to the leader, append a `trail` segment. These are Luis's own verified-walkable crumbs, in order, with 3D arrival.

Wire format (resp.lua stays a Lua table): `{id, ok, segments = {{kind="walk", points={...}}, {kind="link", link={id, move="sprint_jump", from, to, heading_deg, runup_m, inputs={{t=0,a="jump"}, ...}}}, ...}}`. The old `points` field stays for backward compatibility (walk-only routes).

### 3.2 L3: segment follower (move.lua v2 changes; locomotion agent)
- **3D advance (fixes section 0):** a point is reached only if `d2 < wp_radius` **and** `|dz| < max(MaxStepHeight + 20 cm, 60 cm)`. The "passed" rule likewise needs `|dz|` small. `nearest_crumb` should *exclude* crumbs more than 1 m above or below rather than just weighting them.
- **Level-mismatch detection:** if the aim point is more than `envelope.jump_up_m` above us and within 3 m horizontally, the target is on another level. Don't push into it: ask L2 to classify, or request a route.
- On a `link` segment: hand the pawn to L1 (`traverse.run(link)`), and resume the next segment on success. On failure, report it to L4 (`link_failed(id, reason)`) and request a reroute without that link.
- Keep the existing stuck detector, but route its trigger through L2's classifier instead of jumping blindly: `stuck → sense → (feasible move | backtrack | reroute | report)`.

### 3.3 Capability envelope: what to measure on the DEV server, and how
The envelope is per **character** (perks travel with the client-side save) plus active **buffs**. File: `data/envelopes/<character>.json` (git-tracked), recomputed when perks change. The live reads give hard limits, and measurements give the usable (conservative) values.

**E0: static reads (one read-only command, `trav_probe read`):**
- CMC: `JumpZVelocity`, `GetGravityZ()`, `GravityScale`, `GetMaxJumpHeight()`, `GetMaxJumpHeightWithJumpTime()`, `AirControl`, `AirControlBoostMultiplier/VelocityThreshold`, `FallingLateralFriction`, `BrakingDecelerationFalling`, `MaxWalkSpeed`, `GetSprintingMaxSpeed()`, `MaxStepHeight`, `WalkableFloorAngle`, `LedgeCheckThreshold`, `PerchRadiusThreshold`, `MinFallDamageHeight`, `MaxFallDamageHeight`, `MaxFallDistanceForDoubleJump`, `MaxFallDistanceForDash`, `DashDistance`, `DashCooldownDuration`, `DashStaminaCost`, `MinimumAccelerationForDirectionalDoubleJumpAndDash`, `DoubleJumpMaxHorizontalSpeedDuringDash`, `MaxPhaseDashCharges`.
- Pawn: `JumpMaxHoldTime`, `JumpMaxCount`, `LedgeForgivenessTime`, capsule radius and half-height.
- Perks: `IsPerkUnlocked` for DoubleJump, AirDash, Breakfall, GreaterBreakfall, Hopper and PhaseDash, and Windstep in the spell list.
- `PerkV2_Agility_AirDash.InputActionDisplay.InputAction` (which IA triggers the dash).
- Stamina max.
- On the dev server: RecastNavMesh `AgentRadius` (30), `AgentHeight` (150), `AgentMaxStepHeight`, `AgentMaxSlope`, `CellSize`, `TileSizeUU`, `bGenerateNavLinks`, `NavLinkJumpDownConfig.*`.

**E1-E6: dynamic measurements.** Claude's client on the dev server, flat open ground away from Luis, 100 Hz position log from the game-thread loop (`GetRealTimeSeconds` timestamps). Each trial logs per frame: t, pos, vel, MovementMode, JumpCurrentCount, stamina. Hooks on OnJumped/OnLanded mark exact takeoff and landing. Five trials per condition; keep the **min / p10** values.

| # | Measurement | Procedure | Output |
|---|---|---|---|
| E1 | standing jump apex and airtime | stand still; `Jump()` held 1 frame, then 0.25 s, then JumpMaxHoldTime | `apex_m[hold]`, `air_s`, compare to GetMaxJumpHeight* |
| E2 | running and sprinting jump distance | 12 m straight run-up (walk, then sprint confirmed via `IsSprinting()` and speed), jump at the 12 m mark; takeoff = first IsFalling frame, landing = first IsMovingOnGround frame | `dist_walk_m`, `dist_sprint_m`, `apex_run_m`, landing Δz on flat ground |
| E3 | double jump (only if the perk is unlocked) | as E2, with the second `Jump()` at delays 0.15..0.60 s in 0.05 s steps; also standing | `dj_apex_m`, `dj_dist_sprint_m`, `dj_best_delay_s`; directional redirect angle |
| E4 | air control | mid-air 90° input change | lateral correction (m) by time in the air |
| E5 | ledge-up and gap success (test course) | a stepped wall at 0.5/1.0/1.5/2.0/2.5/3.0 m and gaps of 2-7 m in 1 m steps, built once by Luis on the dev world (or natural terrain found by the generator, section 3.6); 5 tries each, standing/run/sprint/double | success-rate table per (move, height/width) |
| E6 | drops and fall damage | walk off 2/3/4/6/8 m edges; record `HealthComponent` delta and `Multicast_ApplyFallDamage` | `safe_drop_m` (no damage), `max_drop_m` (non-fatal) |
| E7 | Windstep (when unlocked + runes) | cast via the quick slot (needs the spell-slot input route), then jump; measure as E1/E2 | `ws_apex_m`, `ws_dist_m`, glide ratio, cooldown, rune cost |
| E8 | Air Dash (when unlocked) | the IA from E0 while airborne at different times | `dash_add_m`, cooldown, stamina |
| E9 | stamina | Δstamina per jump, double jump and dash; sprint drain/s | preconditions in the envelope |

Envelope values used for planning are **conservative**: for example `gap_sprint_m = p10(E5 success at ≥ 4/5) − 0.3 m`, `jump_up_m = min(E1 apex, E5 success) − 0.15 m`. Section 1.1 (Unity): jump distance is mesh-to-mesh, so subtract 2 × agent radius when comparing to navmesh gaps.

### 3.4 L2: forward/down sensing → obstacle class → move
**Alignment with the locomotion agent (2026-10-25):** the locomotion agent is building a client-side
**local grid planner**:
- about 30 × 30 m around Claude at 0.5-1 m;
- per cell, a downward trace gives floor height, plus wall traces;
- edges: walk / jump-up / double-jump / drop, typed by the envelope;
- A* toward the next nav waypoint or crumb, with a per-frame trace budget.

It adapts the A* Pathfinding Project GridGraph/LayerGridGraph scan and mineflayer move types. **That is L2 here.** The rules below become its *edge-typing* rules, plus gap edges, which a per-cell grid needs as "jump across N missing cells" (Baritone parkour). Its edges take their limits from `envelope.lua` (section 3.3). Its successful non-walk edges are recorded as `source: "self"` links (section 3.5).

Probes run every 0.1 s while moving (not every frame, to save cost) and on demand when stuck. Each is a top-level call with **scalar tables only** (R15).
- **Floor ahead:** `CMC:K2_FindFloor(capsule_at(p_i))` at p_i = 0.5, 1, 2, 3, ... up to `gap_max + 2 m` along the heading, starting `jump_up_m + 0.5 m` above current feet height. That gives `{walkable, floor_z}` per sample. Fallback if the out struct can't be read: bool-only `LineTraceSingle` downward, bisecting floor_z in about 6 traces (2-3 cm resolution).
- **Wall ahead:** forward traces at knee, chest and head height, 1.5 m long.
- **Classify from the floor profile** (Δz relative to current feet):
  - `flat/step`: |Δz| ≤ MaxStepHeight → walk.
  - `ledge_up h`: a wall hit, with floor on top at h. Pick the cheapest move with h ≤ its height: jump (standing/running), double jump, Windstep. Above that: infeasible.
  - `gap w`: floor missing for w, then floor again within ±jump height. Pick sprint-jump if w ≤ gap_sprint; double jump; dash.
  - `drop d`: floor lower by d. Walk off if d ≤ safe_drop; if d ≤ max_drop, allowed only when the route needs it (a cost penalty) and health is above 50 %; otherwise avoid.
  - `wall`: a hit at all heights with no reachable top → infeasible (reroute/backtrack).
  - `water`: `IsSwimming` after entry → swim mode (later).
- **Output:** `{class, h|w|d, takeoff_point, landing_point, move, confidence}`. Every classification and the move outcome is logged to `client_io/events/traversal.jsonl`, which gives training data for the envelope and the self-discovered links (section 3.5).
- **In the section 0 case:** the floor probe toward the aim would report `ledge_up 3.3 m`, which is infeasible at Agility 1. So the follower would walk the trail **backwards** to the last crumb at its own level (|Δz| ≤ 0.5 m), or reroute. If neither works, it says "I can't get up there: it's a 3.3 m ledge and I can't double jump yet. Is there a ramp or stairs?" That replaces 90 s of jumping at a wall.

### 3.5 Learned links: from Luis's demonstrations and Claude's own successes
**Recorder (observe.lua, client):**
- Runs while following, or on `watch_traversal on`. Per tracked player, sample the pawn every frame (net-rate data).
- Grounded crumbs as now (0.5 m spacing). In addition, open a **traversal event** when `IsFalling()` becomes true or `ReplicatedJumpCurrentCount` increases, and close it on landing (`IsMovingOnGround`).
- Event payload:
  - takeoff point and velocity, landing point, apex Z;
  - jump-count changes with timestamps (double jump at t, etc.);
  - evade multicasts and spell multicasts (Windstep/Phase Dash) seen during the event;
  - sprinting (speed), run-up distance (the straight grounded crumbs before takeoff), heading;
  - fall damage seen;
  - whether takeoff or landing is within 3 m of a player-built piece (actor family `BuildingPiece` or similar; `sense` census).
- Writes one JSON line to `client_io/events/traversal.jsonl`. No decisions are made in the recorder.

**Distiller (brain/traversal.py):**
- Classify the event:
  - `step` (dz < 0.6, horizontal < 1.5): ignore.
  - `jump_up` / `gap_jump` / `sprint_jump` / `double_jump` / `dash` / `windstep` / `drop`, from the jump count, the multicasts and the geometry.
- A link is worth keeping only if it **saves a route**. Ask the oracle for takeoff → landing: if the path is absent, partial, or more than 3 × the straight distance plus 10 m, keep it. A jump Luis made for fun on open ground is dropped.
- Merge near-duplicates: endpoints within 1.5 m and heading within 20° → `n_seen++`, averaged.
- Store:
  - **links:** `data/skills/<world_guid>/traversal_links.json`. Git-tracked, next to the learned skills (design section 19), so Luis can see "what Claude learned". It is listed by the existing "what have you learned?" command, and "forget the jump by the lake" disables a link.
  - **raw demos:** `logs/state/worlds/<world_guid>/traversal_events.jsonl` (gitignored, bulky). Use `brain/worlds.py prepare_state_dir` / `prepare_skills_dir`, so links never leak between worlds.

**Writers and readers (agreed with the locomotion agent):**
- **One writer per file.** The client never writes the links file. Both `observe.lua` (Luis's demos; owned by the traversal work, not move.lua) and move.lua/localplan (successful non-walk grid edges, `{"type":"self_edge", move, from, to, heading_deg, ...}`) append events to `client_io/events/traversal.jsonl`.
- `brain/traversal.py` is the only writer of `data/skills/<world_guid>/traversal_links.json`, because only the brain resolves the world guid (worlds.py).
- After each update it also writes the current world's links to **`client_io/nav/links.json`**. move.lua/localplan reads that copy, with dkjson, as extra A* edges.
- Status: move.lua already keeps airborne leader crumbs (`air=true`; reaching the first one of an airborne run triggers a jump) and advances breadcrumbs in 3D (fix (a), done by the locomotion agent).

**Link record:**
```json
{"id":"L7","v":1,"move":"sprint_jump","from":[71.6,1862.0,-35.2],"to":[75.9,1862.3,-34.9],
 "heading_deg":4.0,"runup_m":6.5,"needs":{"sprint":true,"perks":[],"runes":{},"stamina":10},
 "inputs":[{"t":0.0,"a":"jump"}],"gap_m":4.1,"dz_m":0.3,"structure":true,
 "source":"demo:Zezima","n_seen":2,"n_try":3,"n_ok":3,"last_ok":"2026-10-26T10:12Z",
 "disabled":false,"build":"26161880"}
```

**Rules:**
- `usable(envelope)` holds when the required moves are ⊆ Claude's capabilities. If a demo needs a perk Claude lacks, keep the link (`usable=false`, reason `needs:DoubleJump`) so the planner can explain itself.
- A link is **verified only after Claude crosses it himself** (Voyager: verify, then commit). Until then it carries `n_ok = 0` and a higher cost.
- Claude's own successful crossings found by L2 become links too (`source: "self"`).
- Links whose endpoints touch player-built pieces get re-validated by a floor probe before use, because players rebuild.

### 3.6 Offline jump-link generator: feasibility
| Option | What | Verdict |
|---|---|---|
| G1: UE built-in auto links on the dev server | Set `RecastNavMesh.bGenerateNavLinks = true` and the `NavLinkJumpDownConfig` scalars (property writes, no structs built), then dirty or rebuild the tiles around the anchor | **Cheap to try, uncertain.** Experimental; documented for jump/fall-*down* only; generation cost grows with JumpLength; unknown whether a cooked server's Dynamic runtime generation rebuilds the baked `NavigationDataChunkActor` tiles; no reflected "rebuild these tiles" except `K2_ReplaceAreaInTileBounds`. Paths would then cross links natively, but the client would still have to detect link segments (geometry). Run only as an announced dev-server experiment, after G2 |
| **G2: our generator against the live oracle (recommended)** | The Unity edge-walk recipe run against Detour via the oracle, in batched debug_run calls: (1) grid-sample a region (2 m) and project to the navmesh; (2) `NavigationRaycast` in 16 directions to find mesh border points; (3) for each border point and direction, project candidate landings at d = 1..gap_max m and Δz from −max_drop to +jump_up (tall query extent); (4) keep a candidate if the landing is on the mesh **and** the on-mesh path is absent or more than 3 × straight + 10 m; (5) check the arc is clear with bool `LineTraceSingle` segments along the predicted parabola from the envelope (no struct params); (6) dedupe (FilterDistanceThreshold-style). Output links with `source: "generated"`, `n_ok = 0` | **Feasible.** Every call is either already proven (`K2_ProjectPointToNavigation`, `FindPathToLocationSynchronously`) or flat-`FVector`-out (`NavigationRaycast`), apart from the trace marshalling test (T1). It works only for the static world on the dev server's map, not player builds on Shockbyte (which come from demos and self-discovery). Budget: about 10 k projections per 100 × 100 m region at 2-5 ms, so about 30-50 s of game thread split into ≤ 0.3 s batches |
| G3: export the navmesh and run Detour offline | Bloog-bot style | **Not feasible now.** No reflected access to tile polygons; ExportNavigation is an editor/debug geometry dump; UE's Detour fork (`dtReal` doubles, UE tile layout) isn't upstream-compatible; the Fab exporters are editor-only. A sampled heightfield from G2's projections could later feed a local grid planner (networkx) to remove the dev-server dependency. That ties to the client-navmesh test in client-side-botting.md (`bAllowClientSideNavigation`) |

### 3.7 L1: move executor (traverse.lua), one state machine per kind (adapted from Baritone)
Common phases for a jump-family link:
1. **Approach:** walk or sprint to `from − heading × runup_m`.
2. **Align:** yaw error under 5°, lateral offset from the takeoff line under 30 cm. If not aligned, back up (Baritone repositioning).
3. **Run-up:** hold input along the heading. Sprint if `needs.sprint`, and confirm `IsSprinting()` and speed at least 0.9 × the envelope speed before the edge. If speed is short, abort before takeoff, which is the only safe cancel point (Baritone: cancel only on tick 0).
4. **Takeoff:** `Jump()` when the 2D distance past `from` along the heading is at least 0 **or** `IsFalling()` became true without a jump (walked off the edge: the coyote window, `LedgeForgivenessTime`). Release after the hold time used in calibration.
5. **Air:** keep input toward `to`. Double jump at the `dj_best_delay_s` from E3, or when vertical speed ≤ 0 if the landing is above. Dash when the envelope says. Windstep: cast on the ground before takeoff (cooldown and runes checked).
6. **Land and verify:** `IsMovingOnGround()` and `|pos − to|₂D < 1.5 m` and `|Δz| < 0.6 m` → `ok`. Otherwise classify: `short` (landed below `to.z − 1 m`), `overshoot`, `bonk` (velocity zeroed mid-air by a wall), `fall_damage` (health dropped).

Other kinds:
- `drop`: walk off with input, verify the landing.
- `ledge_up`: like a jump, with a short run-up and a wall-contact takeoff.
- `trail`: hands back to L3.

While the executor runs, it **owns the pawn** (the control arbiter, hardening #2). Reflexes may only cancel during Approach and Align.

### 3.8 Failure handling (bounded, then report)
- **Per link, per trip:** 2 attempts, then the router drops it for this trip. Each failure updates `n_try`/`n_ok`. Three consecutive failures set `disabled: true`, with `reason` and timestamp (re-enabled by "try that jump again" or after a perk change).
- **Per goal:** at most 3 traversal failures or 2 reroutes. Then the fallback ladder:
  1. reroute without the failed links;
  2. the leader's trail at the same level (3D advance);
  3. our own trail backwards (existing backtrack);
  4. **report**: an event `traversal_blocked {class, h|w|d, needs, where}` → the brain says why and asks ("I need Double Jump for that gap", "wait for me, I'll go round", "can you build steps?");
  5. the game's own Unstuck (`IA_UnstuckCharacter_Held` / pause-menu Unstuck): a real player path, but it teleports, so only when Luis says so.
- **Falls:** if falling unexpectedly lasts longer than predicted airtime + 0.5 s, stop the air input (no flailing). On landing, re-sense and reroute from the new position. Report health loss.
- **Never retry a jump forever:** the ladder replaces the current blind jump/strafe loop that ran for over 90 s.

API move.lua v2 would call (proposed):
- `terrain.sense(pawn, heading_deg, opts) -> {class, ...}`
- `traverse.run(log, link|move, done_cb) -> handle`
- `traverse.status()`
- `traverse.cancel()` (only before takeoff)
- `envelope.get()`, `envelope.can(move, h|w|d)`

### 3.9 Test plan (dev server first, CLAUDE.md section 8 style)
Offline (no game):
- `client_mod/tests/test_terrain.lua`: a fake floor function (heightmap) → classifier cases (step, ledge 1/2/3.3 m, gaps 2/4/6 m, drop 3/8 m, wall, ambiguous).
- `test_traverse.lua`: a fake kinematic pawn (projectile model using envelope numbers, plus a coyote window) → executor phases, abort before takeoff, landing classification, retry caps.
- `tests/test_traversal_links.py`: distil recorded demo JSONL fixtures (including a fun jump on open ground that must be dropped) → links; merge; usable() by perks; per-world isolation via worlds.py.
- `tests/test_nav_route.py`: overlay Dijkstra with a mocked oracle (partial/failed/ok legs) → typed segments; `no_route` reason.
- The section 0 log as a regression fixture: the 3D advance must not skip crumbs 3.3 m above.

Live, dev server, in order (each go/no-go):
- **T0:** `trav_probe read` (read-only) on Claude's client → E0 values + perks. Record them in DISCOVERIES.
- **T1:** trace marshalling, **server side first**. Call it through debug_run on the dev server against a fixed point near the anchor; the same UE4SS commit, and a crash costs only the dev server (watchdog restarts; announce first).
  - `K2_FindFloor(vec, {})`, `LineTraceSingle(..., {}, {})` and `NavigationRaycast`. Read the bool and the out table.
  - Only after that, the same calls on the client.
- **T2:** envelope E1-E4 on flat ground (Claude alone).
- **T3:** test course E5/E6 (Luis builds the stepped wall and the gap ladder once on the dev world: about 10 min).
- **T4:** demo → link. Luis sprint-jumps a gap on the course with the recorder on → a link appears in `traversal_links.json` → Claude crosses it (`n_ok = 1`).
- **T5:** reproduce section 0 on the dev world: a covered build with a raised floor and a gap at the exit. Follow must either cross via a learned link or report `traversal_blocked` within 15 s.
- **T6:** follow Luis across the course and back. Pass if Claude crosses every link that is `usable` for his envelope and reports the rest.
- **T7:** failure injection (a link whose landing was removed): 2 tries, disable, reroute or report.
- Then Shockbyte, only for verified behaviour (hardening #3).

### 3.10 Build order and effort (agent-days, one agent, including tests)
| # | Item | Depends on | Effort |
|---|---|---|---|
| 1 | Request to the locomotion agent: 3D advance plus keep airborne samples as events (section 0) | none | 0.5 |
| 2 | `trav_probe read` (E0) + DISCOVERIES | none | 0.5 |
| 3 | T1 trace/floor marshalling experiment (dev server, then client) | none | 0.5 |
| 4 | `envelope.lua` + calibration commands + `tools/trav_calib.py` analysis (E1-E4) | 2, 3 | 1.0 |
| 5 | L2 = the locomotion agent's local grid planner, with these edge-typing rules + gap edges + test_terrain | 3, 4 | 1.5 (theirs) |
| 6 | `traverse.lua` executor (jump, sprint-jump, drop, ledge-up; double jump behind the perk) + test_traverse | 4, 5 | 2.0 |
| 7 | `observe.lua` recorder + `brain/traversal.py` distiller/store + tests | 1 | 1.5 |
| 8 | Overlay router in nav_oracle (batch query, Dijkstra, typed segments) + tests | 7 | 1.5 |
| 9 | Failure ladder + `traversal_blocked` event + brain speech reasons | 6, 8 | 0.75 |
| 10 | Test course T3-T7 with Luis (about 2 short sessions) | 6-9 | 1.0 |
| 11 | Windstep (needs the client spell-slot cast route) and Air Dash moves | perks, spells port | 1.0 each |
| 12 | G2 generator over the oracle | 3, 8 | 2.0 |
| 13 | G1 UE auto-links experiment (optional) | 8 | 0.5 |

Core (items 1-10) is **about 10.5 agent-days**. Items 1, 2, 3 and 7 can run in parallel; then items 4 → 5 → 6, and 8 → 9.

---

## 4. Open questions for Luis
1. **Claude's level.** At Agility 1 he has no Windstep (5), Double Jump (10) or Air Dash (32). Do we level him (the Agility courses give XP and are good link-training routes), or start him from a high-level character on the throwaway world, as the remediation doc proposed?
2. **The test course:** can you build a stepped wall (0.5-3 m) and a gap ladder (2-7 m) once on the dev world (about 10 min)? Natural terrain works too if you know a spot.
3. **The game's own Unstuck** (it teleports): may Claude use it as a last resort, or only when you say so?
4. **Demonstrations:** OK to record your jumps continuously while Claude follows you (only your position, movement mode, jump count and the spell/evade multicasts that already reach his client)? Learned links go into git (`data/skills/<world>/traversal_links.json`) so you can review or "forget" them.
5. **Windstep and dash spending:** may Claude spend Air runes on Windstep for traversal (5 Air, 3 s cooldown), or should runes be saved for combat?
6. **G1 experiment:** may we try UE's experimental auto-links on the dev server (it may spike CPU or need a restart, announced)?

## 5. Searches that found nothing
- No UE4SS example of calling a trace and reading `FHitResult` from Lua; no UE4SS docs on out-param struct conversion (docs.ue4ss.com UFunction page only).
- No source that turns recorded human jumps into navmesh links.
- No public code for the Utrecht thesis's Recast jump links.
- No official statement on whether UE 5.5+ generated nav links work with runtime/dynamic tile generation in a cooked build.
- Not checked: Baritone's MovementParkour cost constants beyond the source summary; the GDC Vault talks beyond their abstracts (paywalled).

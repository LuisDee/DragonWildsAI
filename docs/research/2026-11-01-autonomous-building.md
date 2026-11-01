# Autonomous building: what Claude "sees", how others do it, and a plan (2026-11-01)

Luis's question: "He claims to not be able to 'see' where he is placing things. Analyse what information he gets,
and web-search how people produce autonomous building agents... how could we get him to build a house? ... on top
of the church there is a chest ... you need to build a wooden foundation to jump on and then Windstep up to get it,
or just build stairs up there. If he can't 'see' where he is placing, how can we get him to do this?"

## The short answer

- Nobody's building agent "sees" pixels to place things. Neither the published ones nor the hobby ones do. The
  ones that work let the model **choose** (a piece, a blueprint, an attach point, an option), while **code turns
  that into exact positions** using the game's own grid or sockets. The code then **re-reads the world** and tells
  the model what is now there and what is still missing.
- Claude's body already reads a lot when it builds: ground traces, the game's preview colour and position, and the
  pieces around him. Almost none of that reaches the model, and what does reach it was misleading. Today's crate is
  the example: it was placed, but the reply looked like a failure (fixed today, section 1).
- To build a house or climb to the church-roof chest he needs three things, in this order:
  1. a **"build site" read**: ground heights, the pieces there and their free snap points, and how high the
     target is above him;
  2. **"attach to that piece's free socket"** as the placement primitive, which also unblocks snap-only pieces
     such as walls, floors and stairs;
  3. **blueprints as piece lists relative to an anchor**, built piece by piece with a check after each one. The
     game's own **ghost mode** can hold the plan.
- The church chest is real: `BP_LootChest_Prefab_Tier2_World_C` at (69.8, 1861.3, -16.8), **14.3 m above Claude**
  and about 15.3 m above the church floor (read live today). His measured reach is 1.64 m with a single jump and
  3.07 m with a double jump; Windstep is unmeasured. So it needs real building, planned from those numbers.

## 1. The crate (fixed today, root cause 6 of the co-play retro)

**What happened.** Both crates were built. The tool said `ok: true` (8 Ash Logs spent, +29 Construction XP), but
its reply also listed the preview spots it had tried first, as `valid: false, why: "not_valid (colour 1.0)"`, and
`structure: null`. Haiku read that as "keeps failing", built a second crate, and later said "the build call
reported failure".

**Why `structure` was null.** The search for the new piece in the world ran only when the game's completion
message had *not* arrived. That message always arrives, so the search never ran. The crate itself was in the
census 0.4 s later.

**Now (`client_mod/scripts/build.lua`).** The reply leads with one sentence, and the JSON key order puts it first:

> "Placed the Crate and it is built (8 Ash Logs, +29 Construction XP): it stands 2.3 m SW of me at
> [115.1, 1850.8, -32.2], facing E (BP_BaseBuilding_Crate_C_2147264051). Before that 1 preview spot was rejected
> and nothing was placed there; that's the normal search, not a failure."

- The new piece is found every time. It is the actor of that piece near the preview that wasn't there before the
  press, so an old crate next to it is never mistaken for the new one.
- The rejected spots are listed under `rejected_previews_before_placing`, with the `valid` flag dropped.
- `get_state.structures` re-reads at once.
- Tests: `client_mod/tests/test_build.lua` 56/56. Live, a crate built on dev at 12:06 UTC returned exactly the
  sentence above.

This was a reporting bug, not a perception bug. The rest of this note is about perception.

## 2. What Claude perceives when he builds today

### What the body reads (build.lua, placement.lua)

| Read | What it gives | Does the model see it? |
|---|---|---|
| `buildables` (ProgressComponent.BuildingsUnlocked) | name, category, cost, XP, what's missing | yes, as a tool |
| Spot search (`placement.spots`) | 3x3 downward line traces per candidate spot: height spread, ground normal, clearance above, line of sight | no |
| Preview colour (MPC `PlacingValidityStateIndex`) | 2 = Valid **or** NeedsSnapping; 1 = Overlapping / Floating / NeedsFoundation / Unstable / ...; 0 = wrong surface / none | only as the reject list |
| Preview position (MPC `CursorWorldPosition`) | where the ghost actually sits, which is often not where he aimed (today 3.2 m off) | only as the reject list |
| Validity hooks | never fire (C++ calls), so no exact state | — |
| Snap-only flag (placement profile `bCanOnlyBeSnapped`) | walls, floors, stairs and similar can only snap. Colour 2 can't tell "snapped" from "needs snapping", so **he refuses every snap-only piece** (`preview_ambiguous`) | as a failure |
| Completion telemetry, Construction XP, material spend | proof that something was built | yes (`evidence`) |
| Census of building actors (`get_state.structures`: id, name, piece, 3D position, distance, ghosted) | every building piece within 30 m | **no**: the situation digest skips `structures` (`brain/situation.py` COVERED_KEYS) |

### What the model sees in each call
- The tool list, and the build reply (now truthful).
- Usable things nearby, as "Base Building Crate x2 (2 m, id …, Open)". The name differs from buildables' "Crate",
  and the distance is flat. Foundations, walls and stairs have no "Open" or "Use", so they never show at all.
- `look` gives absolute positions, so a height exists only as a raw z the model would have to subtract.

### What is missing (the real "can't see")

1. **Heights.**
   - Nothing says "14 m above you".
   - Nothing describes the ground around a build spot: flat or sloped, at what height.
2. **His own pieces.** No list of what he has built, of how big each piece is (`BuildingPieceLocalBounds`, a
   reflected box), or of which faces or sockets are free (`BuildingSnapComponent.Plugs`, a reflected array of
   {PieceTag, PlugTag, transform}).
3. **Where the ghost really is.**
   - The preview's final transform: location is read, rotation is not, which is why `rotation_verified` is
     always false.
   - Whether it snapped, and to what.
   - The game's own height and distance offsets (OffsetZ / OffsetDistance inputs: up to 3 m and 3.5 m) are unused.
4. **His reach as numbers.**
   - move.lua knows a single jump is 1.64 m and a double jump is 3.07 m (DISCOVERIES).
   - The Windstep rise is unmeasured (localplan assumes at most 7 m).
   - These feed failure reasons ("above jump height"), but are never offered for planning.
5. **No blueprint and no ghost mode.**
   - He can place one piece "near me", and that is all.
   - The game has a ghost mode (F held: a free, stability-checked placeholder that is filled in later), which we
     haven't probed.

## 3. How others build with LLM agents

**The model is bad at raw 3D coordinates. Every benchmark says so.**
- MineAnyBuild: best model 41/100, mental rotation at most 26.7%.
- Collaborative building as code: GPT-4 F1 0.39, spatial prepositions right about 26% of the time, fails on
  "towards your right".
- Madge & Poesio: absolute coordinates 43% → 76.5% with chain of thought; relative addressing 82% → 95.8%.
  **Relative beats absolute**.
- Factorio Learning Environment (FLE): the main failures are "lack spatial reasoning" and placing things on top of
  each other.

**What works:**

- **The model picks, code places.**
  - GITM's LLM emits `build(blueprint)` and `place(object)`, and scripts execute them.
  - Sapienheim, a Valheim server companion run by Claude, builds from shared PlanBuild `.blueprint` files ("Claude
    decides what to say and do; the mod does the doing").
  - APT and T2BM have the LLM write a coarse layout (walls as start/end ranges, "floors before upper levels"). Code
    expands it into blocks.
- **Blueprints are piece lists relative to an anchor.**
  - PlanBuild: one line per piece, `name;category;posX;posY;posZ;rotX;rotY;rotZ;rotW`, with a center marker as the
    origin, and plan (ghost) pieces built later as materials arrive.
  - Factorio: `{name, position relative to the center, direction}`.
  - Baritone: a schematic with its origin at the player's feet, built in layers from the bottom.
- **Place relative to what is already there.**
  - FLE: `place_entity_next_to(proto, reference_position, direction, spacing)` and `nearest_buildable` (finds a
    free spot that fits the footprint).
  - Valheim pieces carry their own snap points (`Piece.GetSnapPoints`). This is the same idea as Dragonwilds' plugs.
- **Verify by diffing the world against the plan.**
  - MineCollab's `!checkBlueprint` returns the remaining fixes as text ("Place stone at X, Y, Z").
  - IGLU scores the grid difference; FLE has the agent assert results.
  - Agents that skip the re-read (Voyager's and Mindcraft's place skills) report success they didn't check.
    That is what our crate did in reverse.
- **Reaching a height is movement planning, not a building plan.**
  - Baritone's `MovementPillar` (jump + place a block under you) is one costed step inside its path search.
  - mineflayer-pathfinder has `allow1by1towers` and `scafoldingBlocks`.
  - In APT, the model came up with scaffolding without being prompted.
  - Mindcraft has no tower skill ("could be added").

## 4. A design for Dragonwilds

The rule throughout: **code informs, the model decides.** No phrase maps and no church-specific code. Every
failure carries the game's own reason.

### 4.1 Perception (reads only; no hand-built structs)

1. **Heights everywhere.**
   - Every thing in `look` and in the situation gets `up_m` (its height above his feet; negative means below).
   - The digest says "Loot Chest 46 m W, 14 m up".
   - This is cheap: the z is already read.
2. **Built pieces in his context.**
   - Render `get_state.structures` in the situation, using the same name buildables uses ("Crate", not "Base
     Building Crate"), with distance, `up_m` and `ghosted`.
   - Mark which ones he built this session (the build reply's id).
3. **A `site` read** (new tool, read-only): `site {at: id | [x,y,z] | "me", radius_m: 6}` returns
   - **ground**: a coarse height grid (about 2 m cells, the game's tile is 4 m) as heights relative to him, plus
     flatness per cell, reusing placement.spots' traces;
   - **pieces**: each with its size (from `BuildingPieceLocalBounds`), position and yaw;
   - **free snap points**: each plug's world position and its kind (PlugTag), minus the plugs that touch another
     piece. Named simply, e.g. `Square Foundation#2: top, north edge, east edge`;
   - **the target**, when `at` is a thing: its height above the ground and above the nearest roof or ledge under
     it (a downward trace from just above it);
   - **known blockers**: other players; a likely no-build radius around lodestones (Summon Shelter was blocked
     13–25 m from the dev lodestone, not confirmed in the data); protected areas when the game says so.
4. **His reach as numbers.** One line in the situation, e.g. "jump 1.6 m, double jump 3.1 m, Windstep ? m
   (unmeasured)". Measure Windstep once with move_calib.
5. **The ghost's final transform.**
   - Read the preview actor's rotation as well as its location (this verifies `rotation`).
   - Positive snap signal: the preview's transform equals a free plug's transform within a few cm.
   - That signal lets us press for snap-only pieces: colour 2 plus "sits exactly on a free plug" means Valid, not
     NeedsSnapping.

### 4.2 Actions

1. **`build {piece, on: "<piece id>:<snap point>"}`.** Attach to a free socket.
   - Code aims the camera at the plug's world point, using the game's height and distance offsets when the plug
     is out of the camera trace.
   - It presses only when the ghost sits on that plug, then verifies from the census (as today) and that the plug
     is now taken.
   - This is FLE's `place_entity_next_to` in Dragonwilds terms, and the model never computes a coordinate.
2. **Ghost mode as the blueprint layer** (probe first: hold `IA_Building_GhostPiece_Modifier` while placing).
   - Ghost pieces cost nothing, show up in the census with `bIsGhosted`, and the game runs its stability rules on
     them.
   - So a whole plan can be laid out and checked before any wood is spent, then each ghost filled in (the game's
     own "build it" input).
   - Luis can see the plan in his client and say "no, move it".
3. **Blueprints** (`data/blueprints/*.json`), PlanBuild-style. Each is a list of
   `{piece, cell: [i, j, k], yaw: 0|90|180|270, needs: <index of the piece it snaps to>}` on the game's grid
   (4 m tiles, 15° rotation steps), with an anchor and a footprint.
   - `build_blueprint {name, at, facing}` finds flat ground that fits the footprint (`site`). It then builds or
     ghosts in order (foundations → floor → walls → stairs → roof, as the wiki's stability advice says) and checks
     each piece.
   - It answers with a **diff**: built N of M, still missing [...] with the game's reason, materials short.
   - It stops on the first piece it can't place, and says why.
   - The brain can draft a new blueprint from a `site` read of something Luis built ("copy my hut"). PlanBuild
     does that, and CLAUDE.md principle 2 asks for it.
4. **`climb_to {target}`.** Reaching a height as a plan with options. Code computes the options, each with its
   cost and risk, and the model chooses and tells the player:
   - (a) jump / double jump / Windstep from what is already there, if the ledge is within reach;
   - (b) build a platform: foundation(s) or floor tiles until the remaining height is within a double jump or a
     Windstep;
   - (c) stairs: each 45° stair rises about 2 m (2.8 m long; two stairs span a 4 m floor), with a floor or wall
     every two stairs for support, within Ash's stability limit (about 5 pieces high, wiki);
   - (d) can't: the game says it's a protected area, or the materials are short. The reply says which, with the
     numbers.
   The move itself reuses move.lua's jump / double jump / Windstep edges, and the built pieces become normal
   walkable ground.

### 4.3 Verification (already the pattern, now for many pieces)
- Each piece: the census actor appears, the plug is taken, and the materials fell.
- Each blueprint or climb: the diff against the plan.
- Each climb: did his feet reach the ledge height (`up_m` near 0 at the target)? Then open the chest with
  `interact`, and the inventory gain proves it.

## 5. The church-roof chest, step by step (generic: the model plans from perception)

1. **Find it.**
   - `look about=chest` shows "Loot Chest 46 m W, **14.3 m up**, Open" (today: (69.8, 1861.3, -16.8)).
   - `inspect` or `site at=<chest>` tells him it sits on a roof 15.3 m above the church floor, and where the roof's
     lowest reachable edge is (the eave height, from traces around the building).
2. **Decide.** `climb_to <chest>` answers, for example:
   - "From the ground the lowest roof edge is 6.5 m up. Option A: two foundations on the east side (≈1 m) plus
     Windstep (unmeasured), 1 Ash Log each, risky.
   - Option B: 2 floors + 4 stairs up the north wall to the 6.5 m edge, then walk the roof slope to the chest:
     about 20 Ash Logs, I have 57.
   - Option C: nothing, if building here is blocked."
   - The model picks, and says it in chat ("I'll build stairs up the north side, about 20 logs").
3. **Place.**
   - The first piece is `build {piece: "Square Foundation", at: <site cell>}`; every later piece is
     `build {on: <previous>:<top or edge>}`, or one `build_blueprint`.
   - Each piece is verified and reported ("stairs 2 of 4 placed, 4 m up").
   - The game refuses with its own words ("Unstable", "Blocked", "Only the host can build here"), and that is what
     he tells Luis.
4. **Climb.** go_to the top piece, then jump, double jump or Windstep onto the roof. The landing height is
   verified. Falls are reported with the height, as move.lua already does.
5. **Open.** `interact <chest>`, and the inventory gain is the proof ("got the Educational Blade plan" or whatever
   it holds).
6. **Tell.** What he used (logs, which pieces he left standing), and offer to take them down later. Deconstruct is
   not a capability yet; that was another retro item.

## 6. Order of work (each step one quick change + one live test on dev)

1. `up_m` on look and situation things, and the built pieces in the situation digest under buildables' names.
   Live test: "is the chest up there?" → "14 m up".
2. Read pieces' bounds and plugs, plus the preview's rotation (read-only probe on the crate, then a foundation).
   Record them in DISCOVERIES.
3. The positive snap signal (preview on a free plug), then `build {on: ...}`. Live test: foundation, then a second
   foundation snapped to its edge, then a wall on top.
4. Measure Windstep's rise (move_calib), and add the reach line.
5. `site`, then `climb_to` with options. Live test: a 4–6 m ledge on dev, then the church chest.
6. Ghost-mode probe, then `build_blueprint` with one small blueprint (a 1-tile hut: foundation, 4 walls, roof).
   The diff reply.

## 7. Unverified, to check live first

- Foundation and floor heights, and the stair rise in the game. The wiki says tile and wall are 4 m and stairs
  about 2.8 m long; we need `BuildingPieceLocalBounds` read live.
- Whether `BuildingSnapComponent.Plugs` reads cleanly from Lua (a TArray of structs with FTransform). It is read
  only, never sent back.
- Whether a free plug can be told from a taken one by world position alone.
- Ghost mode via the F modifier from an injected input. Which input "fills" a ghost (the wiki says Ctrl).
- Whether the church roof is buildable near (protected area / blocked region), and where its eave really is.
- The Windstep rise, and whether Windstep can be cast from a freshly built piece.

## Sources

**Papers and agents**
- Voyager, https://arxiv.org/abs/2305.16291 (§3.5 at https://ar5iv.labs.arxiv.org/html/2305.16291); `placeItem`:
  https://raw.githubusercontent.com/MineDojo/Voyager/main/voyager/control_primitives/placeItem.js
- GITM, https://ar5iv.labs.arxiv.org/html/2305.17144
- MINDcraft / MineCollab, https://arxiv.org/html/2504.17950v1; skills:
  https://raw.githubusercontent.com/kolbytn/mindcraft/main/src/agent/library/skills.js; queries:
  https://raw.githubusercontent.com/kolbytn/mindcraft/main/src/agent/commands/queries.js
- APT, https://arxiv.org/html/2411.17255
- T2BM, https://arxiv.org/html/2406.08751v1
- MineAnyBuild, https://arxiv.org/html/2505.20148v3
- Collaborative building as code, https://ar5iv.labs.arxiv.org/html/2406.17553
- Madge & Poesio, https://arxiv.org/html/2407.12734v1
- IGLU, https://ar5iv.labs.arxiv.org/html/2205.13771
- Factorio Learning Environment, https://arxiv.org/html/2503.09617v1; tools (checked):
  https://jackhopkins.github.io/factorio-learning-environment/sphinx/build/html/tools/core_tools.html
- GSU, https://arxiv.org/abs/2603.17333
- VoxelCodeBench, https://arxiv.org/abs/2604.02580
- MineDojo observation space, https://docs.minedojo.org/sections/core_api/obs_space.html

**Building tools and mods**
- Baritone, https://github.com/cabaletta/baritone/blob/master/USAGE.md; MovementPillar:
  https://raw.githubusercontent.com/cabaletta/baritone/master/src/main/java/baritone/pathing/movement/movements/MovementPillar.java
- mineflayer-pathfinder, https://github.com/PrismarineJS/mineflayer-pathfinder
- mineflayer-builder (README: not yet usable), https://github.com/PrismarineJS/mineflayer-builder
- Sapienheim (Valheim + Claude; checked), https://thunderstore.io/c/valheim/p/sapiteam/Sapienheim/
- PlanBuild, https://github.com/sirskunkalot/PlanBuild; its line format:
  https://raw.githubusercontent.com/sirskunkalot/PlanBuild/master/PlanBuild/Blueprints/PieceEntry.cs
- Valheim snap points, https://thunderstore.io/c/valheim/p/Syloreon/SnappySigns/
- Factorio blueprint strings, https://wiki.factorio.com/Blueprint_string_format

**This project**
- Dragonwilds wiki mirror in `data/wiki`: "Buildings/Mechanics" (ghost mode, snapping, stability), "45° Stairs",
  "Square Foundation", "Chest (Brynmoor)".
- DISCOVERIES:
  - "Build probes P1a/P1b" and "P2–P5" (MPC, limits, inputs, hooks never fire);
  - jumps 1.64 / 3.07 m (move_calib 10-28).
- `dumps/26161880/CXXHeaderDump/Dominion.hpp`: `UBuildingSnapComponent.Plugs`, `FPlug`, `FPlugProfile`,
  `ABaseBuildingActor.BuildingPieceLocalBounds`, `UBuildPlacementComponent`.
- Live today (dev, 12:06–12:10 UTC): the crate build reply, and the `look` that found the church chest 14.3 m up.

**Searched and not found**
- Any LLM building bot for Enshrouded, Palworld or Fortnite.
- A paper named "Text2Build" (T2BM is the nearest).
- Snapping details for Infinity Hammer.
- The Rust CopyPaste file format.

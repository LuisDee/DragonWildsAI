# Traversal recovery

## Implementation status (2026-10-26)

Movement ownership plumbing is implemented and cold-reviewed: direct moves adopt implicit ownership, replacements rotate the implicit token, suspended/resumed moves receive the active token, and owner-controlled call sites pass their token explicitly. Movement, arbiter/combat and skills suites passed targeted verification. This wave provides ownership prerequisites only. The executor wave described below implements Windstep execution, borrowed-cast cancellation and uncached takeoff gates. Calibration integrity and fresh live measurements remain pending; the acceptance criteria below are not yet satisfied.

- **Goal:** use measured, currently available double jump or Windstep when a local path requires it, and expose truthful availability and failure reasons.
- **Approach:** reuse localplan's typed edges and move's existing jump sequencing. Recheck capability at takeoff. For Windstep, hold position while polling the existing borrowed `spells.cast_now` job using the movement owner token, jump only after successful cast, cancel on interruption, and let actual landing advance the edge. Never substitute a jump when a required move is unavailable. Public traversal status reports live gates and measured envelopes. Calibration must not label a failed/unavailable double jump as measured or overwrite unrelated prior measurements; Windstep remains unmeasured until separately measured by a safe explicit calibration.
- **Generality:** no entity or wording rules; capability gates and action profiles are data-driven. Uses player input and existing spell API, without changing outcomes. Measurements and cast results are evidence, not inferred success.
- **Acceptance:** fake-engine tests cover typed edge execution, cast pending/success/failure/cancellation, capability changes, strict landing, and unmeasured/missing perk/runes/cooldown. Existing Lua suites must pass. Live calibration and game verification remain future work; no height is guessed.

## Search record

Repository research `docs/research/2026-10-25-traversal.md` already records typed navigation links, player input and the game's Windstep gates; reuse those and the existing queue/spell code. Epic's smart links separate path selection from traversal execution; its character API describes jump and release. UE4SS documents game-thread execution. No reusable external Dragonwilds traversal executor for this codebase was found.

- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/AIModule/ANavLinkProxy
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/ACharacter/Jump
- https://dev.epicgames.com/documentation/unreal-engine/coder-03-configure-character-movement-with-cplusplus-in-unreal-engine
- https://docs.ue4ss.com/dev/lua-api/global-functions/executeingamethread.html

## Executor wave (2026-10-27)

- **Need and decision:** reuse the existing typed local-plan edge and borrowed spell job, rather than adding another input route. The executor checks live availability without the status cache, borrows the actual movement owner, holds movement during the cast, and jumps only on a successful cast. It cancels before a stop or replacement changes ownership. Grounded takeoff and observed airborne-to-grounded transition at the endpoint are required; failure and timeout preserve a specific result. Cast and landing failures currently end the move directly; retry and replan remain future work. No Windstep height is inferred or added.
- **Search and precedent:** searched the repository traversal research and discoveries and primary Epic and UE4SS documentation for smart navigation links and game-thread input. The existing design and spell job solve the relevant integration; no reusable external Dragonwilds executor was found. Sources: [Epic smart links](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/AIModule/ANavLinkProxy), [UE4SS game-thread execution](https://docs.ue4ss.com/dev/lua-api/global-functions/executeingamethread.html), and `docs/research/2026-10-25-traversal.md`.
- **Principles review:** real player input and observed results; generic typed edge and measured envelope; no interpretation or inventory changes; single arbiter owner. The independent reviewer approved this design with ownership and cancellation ordering checks. The timeout values are guards, not measured Windstep performance; live timing is unverified.
- **Acceptance:** focused fake-engine movement regressions cover cast pending/success/failure, fresh capability, owner loss, replacement/suspension, strict landing and unavailable ground read. Live calibration and a supervised dev-server check remain outstanding.

- **Cold review correction:** the active local path and endpoint identities are checked throughout casting and airborne traversal; replacement or removal fails explicitly before arrival. The waypoint advance barrier applies only to local-plan edges, preserving the existing memory-route behavior. Learned traversal links use their own `windstep` move type and remain outside this executor. Offline tests cover replacing and removing the path after casting and before landing.

- **Verification:** independent Terra re-review confirmed both corrections and found no further concrete defect in the bounded executor. Movement suite ALL OK; spell suites 166 and 5 passed. Combined full gate GREEN: 1061 passed, 1 skipped (379.17 s). No live traversal success is claimed.

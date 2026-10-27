# Traversal recovery

## Implementation status (2026-10-26)

Movement ownership plumbing is implemented and cold-reviewed: direct moves adopt implicit ownership, replacements rotate the implicit token, suspended/resumed moves receive the active token, and owner-controlled call sites pass their token explicitly. Movement, arbiter/combat and skills suites passed targeted verification. This wave provides ownership prerequisites only. Windstep execution, cancellation of borrowed casts, uncached takeoff gates, calibration integrity and fresh live measurements remain pending; the acceptance criteria below are not yet satisfied.

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

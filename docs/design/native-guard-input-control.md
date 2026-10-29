# Developer control: guard rejection versus ordinary player motion

## Goal

Determine whether one reproducibly rejected walking segment is physically
negotiable with normal game input. This is developer-assisted diagnosis, not an
autonomous pass. Keep the corrected200m temple trip, independent provisions and
original M1-M6/frozen judges intact; follow Accepted steer in autonomy-plan.md.

## Approach

Use the existing DEV client and exclusive root live slot; no brain/other action.
Reproduce a nearby go_to rejection. Require terminal detail beginning
`walking terrain:`. Before any new move or stop, read and copy raw DW_MOVE aim,
source, generation, terminal result, half-height plus fresh pawn pose, ground,
health and velocity when available. Recheck identity/generation/result/world.
move.lua:2666 records actual selected aim before the guard; finish retains it.
Do not reconstruct from route indices or use old aim after `route unavailable`.
Feet target uses exactly aim.Z for local/nav, otherwise aim.Z-half_h.

After verifying go_to released ownership, a PRIVATE developer harness requests
exclusive arbiter ownership and applies short low-scale AddMovementInput with
Force=false toward that exact horizontal aim. Use existing game-thread timer
and arbiter APIs; no native hooks, callback monkeypatch or production reload.
Input is bounded by2m/3s and a finite poll count; account for residual native
coast honestly. Stop on lost support, damage, no progress, pause/world/life/pawn/
generation/ownership change or timeout. No jump/sprint, teleport, physics/health/
inventory writes or direct Server_ implementations. Cleanup is idempotent,
cancels only its own timer and releases only its own arbiter token. Every exit
writes bounded primitive observations and a terminal reason; observer failure
must stop input, never mean clear space. Capture pre/post state and assistance.
Any DEV survival fixture required for admission is separately declared and is
not a survival success. Do not erase existing memory, task history or inventory.

## Precedent and search record

Fresh Astra reassessment of the latest actual trace/current code recommended this
same-segment control. Its actual primary-source review opened
[AddMovementInput](https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/Pawn/Input/AddMovementInput),
[MoveAlongFloor](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/MoveAlongFloor?application_version=5.5)
and [StepUp](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/StepUp?application_version=5.5).
Actual preceding queries and measured facts are in
../research/2026-10-29-player-grounding-native-controls.md. Native input, timers
and arbiter operations are already used by move/gather/combat here. Reuse them;
the docs are API precedent, not proof that the rejected segment is passable.

## Generality and principles

Use the captured rejected segment, not a temple route or named-object rule.
Character input and single ownership satisfy PRINCIPLES1/9; our continuous-floor
certificate/drift/reset choices are not frozen user requirements. The existing
straight-follow wall failure is a negative: do not simply remove collision
checks or assume this control solves routing. Developer actions remain labelled.

## Acceptance test

Offline harness checks: missing/stale binding, wrong terminal type, busy owner,
clock/deadline/poll bounds, loss of ground/health, no progress, preemption and
exact own cleanup. Then one reproducible guard rejection followed from the
stopped pose by this same-segment native control. Meaningful grounded progress
supports a false rejection; collision/fall/no progress does not. Retain raw
failure and control records. No gameplay acceptance or source behavior change
is inferred until subsequent reviewed repairs and full-agent validation.

## Fresh review

Terra native_input_control_review CLEAR with required implementation conditions:
idle mover AND empty current owner AND empty suspended stack; request at a
non-preempting level with replace_same=false, then recheck exact token before
each input. Release can resume suspended work, so stack emptiness is material.
Capture terminal result/aim/source/generation/pawn/world as one binding and record
coast before/after input. Progress proves only the short traversed portion;
missing observation/cleanup makes the control inconclusive. No production
telemetry patch or callback/upvalue mutation is needed.

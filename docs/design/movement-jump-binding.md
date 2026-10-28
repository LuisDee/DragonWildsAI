# Shared jump binding: implementation proposal

Scope is movement action ownership and truthful intent/observation only. No
floor classifier, geometry veto, physics write, new landing-success rule, or
second executor. Keep `ws_exec` and `link_exec` authoritative. This follows the
same ownership/support problem and reuses the actual Epic search recorded in
`r26-support-integration-design-20261028.md` and project arbiter precedent.

## Current failure and binding

`start_jump` 522-27 ignores pcall failure and unconditionally sets timers and
jump count; callers may already mark one-shot progress. Windstep may enter air
phase even when Jump failed. At 2012 the second Jump has no grounded/airborne or
ownership check. `M.stop` 2358-65 calls `finish` first: its cancellation and
implicit release can reenter or resume another owner before `StopJumping`.
`arbiter.lua` request 289-95 clears `s.owner` before `stop_rec` or
`suspend_rec`, both of which can call `move.stop`; therefore `owns_move(old)`
is correctly false during this transition. `owns_move` itself calls housekeep
and may run callbacks; `A.owner()` also housekeeps. Raw `_G.DWArbiter.owner`
is needed for transition-only comparison, without triggering housekeeping.

Capture binding `{state identity, generation, owner token, pawn identity,
controller identity, life sequence}` while old move is active. For *normal*
first/second Jump and timer StopJumping require nonpaused, same `_G.DW_MOVE`
and generation/nonidle mode, exact pawn still controlled, alive via existing
`life_check`, and `owns_move(token)` (non-nil); recheck all after that call
because housekeeping can reenter, and after the native pcall before committing
anything. A successful Lua pcall only means the native call returned without a
Lua exception; it does not establish a physical takeoff. If ownership/generation
changes during the native call, return superseded without state mutation, voice,
or any cleanup that could touch the new owner. Cannot undo a submitted call.

`start_jump` returns explicit accepted/busy/rejected/error/superseded and commits
its `jump_t`, release/double timers and `jumps` only after successful pcall and
postcheck. Busy means existing `jump_t`, not acceptance. Same-generation native
error or unknown life/owner is an explicit movement failure through existing
single `finish` result (`verification_failed` with a specific detail); a lost
owner or new generation returns quietly because its owner controls completion.
Caller-specific mutation occurs only after accepted: `lp_jumped`,
`mem_jumped`, `nav_jumped`, `trail_jumped` contiguous marks, associated
`link_jumps`/`trail_jumps`/`hops`, `stepoff_tried`/`stepoff`, and
`link_exec.phase/t_jump`. Windstep must transition `casting -> air` only after
accepted; handle failure via its existing specific fail/cancel path. This may
require checking before changing state in each caller; no direct dispatch table
or model-specific logic. If busy, do not consume a marker or claim a jump.

Second jump at 2012 additionally requires a protected `IsMovingOnGround` read
that is **exactly false**, after which binding/owner are revalidated before
Jump and again after. True or unavailable does not issue the second jump or
clear its timer as if successful; a bounded existing jump window resolves it
as an explicit failure, not infinite retries. Once accepted, set `jump_t2`,
clear `jump_double`, increment `double_jumps`. Timed StopJumping uses the same
normal binding and no native operation while paused; clear release flags only
after the call succeeds and binding remains. If the pawn already changed or
owner lost, no StopJumping is sent to either pawn.

## Explicit stop transition

`M.stop` snapshots old state/gen/token/pawn before any `mem_flush`, `finish`,
callback, generation increment or release. While unpaused, check raw arbiter
owner is exactly the old token, or nil only while the arbiter's exact scoped
stop context names the old stopped/suspended record and token; check the same `_G.DW_MOVE` state, same old
generation and nonidle mode, same old token still in state, and same controlled
pawn/life; do not call `A.owner` or `owns_move` in this transition check.
Then call `StopJumping` on the captured pawn before `finish` and revalidate
state/generation/token/raw owner/pawn after pcall. Nil owner is admitted only
for this cleanup transition with the same binding, never for a new Jump. If
another owner, move, pawn, pause or generation is observed, do not issue or
repeat native cleanup and do not finish/cancel/release the replacement. If the
call reenters and replacement starts, postcheck detects it and old `M.stop`
returns superseded without invoking `finish`. Preserve ordinary explicit-stop
return semantics when no active move; do not stop an unrelated pawn. Paused
stop must not touch native pawn; report/retain that cleanup was not confirmed.
After a stable old binding is cleaned, increment its generation and invoke
existing `finish` once; its callback/release may start a successor, so no native
call after `finish`. Address `mem_flush` reentrancy too: revalidate after it,
or move it under existing finish only after owned cleanup. Existing timer cleanup
in `finish` remains but must not act on a replacement if callbacks reenter.

## Phase output

Small read-only status fields from the binding: `intent` identifies requested
first or second jump, accepted/submitted indicates the native call returned,
and `airborne` is true/false/unknown only from a valid current ground read.
Timers or a pcall do not establish actual takeoff or landing. Do not change
landing, progression, learned-route success, or floor semantics in this wave.
Bind transient output to generation and owner so it cannot describe a later
move. Existing superjump/link executor phases remain authoritative; status
does not become an independent executor.

## Focused regression acceptance

Use actual move and arbiter modules with fake pawns/timers. Cover every first
jump caller, successful vs busy/error, no premature one-shot state changes,
double jump grounded/airborne/unknown, timed release, pause, dead/unknown life,
pawn replacement, owner loss during housekeeping and native call, and no calls
after supersession. Assert one native action at most and exact counters. Test
arbiter real same-level replace and higher-priority suspend where raw owner is
nil during `stop_rec`, plus foreign owner nonnil, callback reentry at
`StopJumping`, `mem_flush`, and `finish`/release: old cleanup never touches or
finishes successor. Verify normal explicit stop still stops the old pawn once,
and pause sends no native calls. Include Windstep async successful/failing job
and link state continuity; preserve existing route/landing behavior. No full
gate or live use until independent source review and root integration.

## Search record

Same movement-safety research: actual queries `site:dev.epicgames.com UCharacterMovementComponent CanWalkOffLedges CheckLedgeDirection`, `site:dev.epicgames.com UCharacterMovementComponent FindFloor IsWalkable ledge movement`, and `site:dev.epicgames.com unreal character movement braking deceleration stopping distance velocity`. Opened [Epic movement component](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent?application_version=5.5), [Epic FindFloor](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/FindFloor?lang=en-US), and [Epic CalcVelocity](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/CalcVelocity). These are conceptual movement references, not proof of this game's Lua ABI. Reuse the existing arbiter and move executor; adapt their ownership checks without a new controller. No floor thresholds or geometry decisions are added.

Additional actual query `site:learn.microsoft.com CancellationTokenSource Cancel callbacks synchronously`; opened [CancellationTokenSource.Cancel](https://learn.microsoft.com/en-us/dotnet/api/system.threading.cancellationtokensource.cancel). Synchronous callbacks may reenter code; this is conceptual precedent, not a game API. Adapt the existing arbiter with a scoped stop context, restoring a previous context only while still owning the exact context object.

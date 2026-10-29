# Give completed walking scans a usable control window

## Goal

Stop the measured stop/scan starvation. Keep Accepted steer in autonomy-plan.md,
the temple200m-from-lodestone acceptance and all original frozen judges.

## Evidence and approach

Published3ff9496 normal developer go_to moved about3.6m in68s, failed
coast_reset_limit2.32m short, health100.95samples included71sampling,
15refresh_required and8moving. Query count reached1598; these are sampled states,
not a complete wall-clock allocation. Evidence: private rfp-trial-a709.

Astra reviewed the actual trace and source. A multi-poll scan consumes the cache
TTL before completion: cache.started=scan.started, then the pre-input check uses
a later clock than the tick-start check. Coast resets accumulate for a command
even after successful scans. These policies are ours, not user requirements.

Separate scan acquisition time from completed-observation reuse. Keep the
existing2s acquisition limit, sampled geometry, shape sweeps, bindings, actual
pose, corridor, arrival, command deadline and cumulative query budget. Read a
fresh clock after polling and validation; complete the cache then, and reuse for
the existing0.35s TTL. Retain scan start as the oldest-observation timestamp;
this is bounded acquisition plus bounded reuse, not a claim that old samples
became fresh. Invalid/backwards clock or expired acquisition must fail honestly.
Production injects its native real-time clock; pure callers may use their
explicit supplied check timestamp for backwards compatibility.

Reset the consecutive coast-failure streak only after a fully accepted fresh
scan. Never reset it for cache hits or aim changes. Preserve total resets/spend.
Expose primitive scan duration, completion cache age, oldest-observation age,
consecutive/total resets and refresh cause in guard diagnostics. No new planner,
movement authority, time-limit widening, physics writes or large synchronous batch.

## Search record

Actual2026-10-29 queries: `site:docs.nav2.org regulated pure pursuit collision
checking control loop frequency maximum time collision horizon` and
`site:dev.epicgames.com UCharacterMovementComponent FindFloor bCanUseCachedLocation
PhysWalking MoveAlongFloor`.

Primary sources opened:
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/MoveAlongFloor?lang=en-US
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/FindFloor?lang=en-US
- https://docs.nav2.org/rolling/configuration_and_development/configuration_guide/controller_plugins/configuring_regulated_pp/
- https://github.com/ros-navigation/navigation2/blob/main/nav2_regulated_pure_pursuit_controller/src/collision_checker.cpp

The old Nav2 packages/configuring-regulated-pp URL404 was not relied upon.
Nav2 bounds forward checking by a temporal/distance horizon. UE documents native
floor-based movement and optional cached floor reuse. Decision: adapt timing and
retry accounting in our existing guard; do not transplant a robot controller or
claim these references prove this game's native compatibility.

## Review and generality

Fresh Astra design reassessment supports this minimum patch. It applies to any
guarded path, with no temple code or intermediate hints. PRINCIPLES1/2/3/4/5/6/9
remain intact. Nested native lifecycle checks may still be costly; measure after
this fix rather than adding an unmeasured optimization or another framework.

## Acceptance test

Real sampler with fake time advancing across polls and inside callbacks:0.6s
stationary acquisition succeeds inside2s and immediate pre-input recheck passes;
reuse expires from completion; slow acquisition still fails. Interleaved
successful scans allow more than four lifetime coast events, while consecutive
failed acquisitions remain bounded. Budgets, malformed clocks, cleanup,
preemption, unsupported floor and wrong-floor tests remain.

Offline preflight includes the actual mover's grounded integration; fresh cold
review and required gate, then ordinary developer nearby go_to plus reverse or
changed destination. Record arrival, speed, grounding, health, ownership and
scan/hold timings. A few metres taking tens of seconds fails the practical
performance objective. Only then attempt complete Sonnet+Haiku autonomously;
no autonomous pass is claimed here.

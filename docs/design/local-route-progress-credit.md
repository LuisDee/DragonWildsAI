# Preserve physical progress across guarded waypoint handoffs

## Goal and observed evidence

Follow [Accepted steer](autonomy-plan.md#accepted-steer--luis-2026-10-28) and
the [independent reset review](../research/2026-10-29-astra-independent-reset-review.md).
Preserve original M1-M6, frozen judges, world/task memory and complete Sonnet
Director + Haiku Controller acceptance. No temple rules, supplied routes or
hidden intermediate goals. Root owns live cleanup, integration and deployment.

Published `1ba76d5` passed its release gate and the developer return a818
(42.109 seconds, health 100, observed `waypoint_crossed`, no guarded stall).
The subsequent complete Sonnet/Haiku trial `nct-full-a811` left the temple,
recovered earlier failures, reached the lodestone's 150 m landmark and peaked
at 189.41 m. It ended at the 24-call cap (12 calls each), without reaching 200 m
and returning. Temple streak remains 0/3. The active task/history are preserved.

The new defect is in the later local-route attempts, generations 10, 11 and 12.
Private evidence under `C:/gameserver/logs/recovery/nct-full-a811/`:
`actual-native-route.jsonl`, `actual-body-results.jsonl` and
`full-agent-result.json`. Their observed start-to-terminal displacements were
12.20 m, 13.36 m and 12.98 m. Each retained its command-start `prog_pos` throughout
movement, despite advancing many local waypoints. Generations 11 and 12 also
completed a local prefix and admitted another window. All failed with
`verification_failed: local route unavailable`, while a ten-point local path
still appeared in the terminal trace.

Selected exact observations (native game time, centimetre state):

| Generation | Event | Time | Time minus progress baseline | Local index |
| --- | --- | --- | --- | --- |
| 10 | first local selection | 698.475449 | 0 | 2/10 |
| 10 | terminal failure | 709.177977 | 2.632917 | 10/10 |
| 11 | waypoint crossing | 727.516621 | 4.483218 | 9/10 |
| 11 | next local window selected | 733.965073 | 4.978158 | 2/10 |
| 11 | terminal failure | 734.564286 | 2.610661 | 2/10 |
| 12 | next-window waypoint crossing | 759.478364 | 5.025748 | 2/10 |
| 12 | terminal failure | 759.986209 | 2.655820 | 3/10 |

**Directly observed:** physical movement and waypoint/prefix advancement did not
update the physical progress-position baseline; the selected local authority
later failed its source invariant. The terminal trace copies `st.source` before
the attempted source is assigned, so its `source=local` does not identify the
source that tried to take control.

**Source-backed mechanism:** waypoint advancement calls `novel_progress`, which
immediately consumes the pose in its novelty history. The final progress-clock
update occurs much later. The real guard returns `pending: target_changed`
when an advanced waypoint changes its aim; this returns from the tick before
the clock update. Prefix completion also returns before that update. Local
grid legs are usually 100 or 141 cm, shorter than the unchanged 150 cm segment
progress threshold, so segment high-water credit cannot reliably compensate.

**Strong inference, not source-stamped live evidence:** expiry enters the generic
self-stuck backtrack branch even though the pawn moved. Guarded walking does
not update the older unguarded `move_acc` counter. That branch sets
`prog_t=t-give_up_s+2.5`; all three terminal offsets match its next-tick
signature. Backtrack then selects a source other than `local` while local
authority remains, triggering the invariant. The exact attempted source was
not captured; do not report it as directly observed.

## Approach and review

Selectively adapt the preserved unpublished feedback-loop candidate's early
physical-waypoint credit and local-authority no-progress ownership. Do not copy
its whole file, partial-native/original-goal selection changes or broad guarded
recovery telemetry. The earlier candidate was reviewed/offline-tested, not
established as the cause of the older ramp failure; this new trace supplies the
relevant physical-credit evidence.

Commit accepted physical progress at its observation boundary, before a guard
hold, prefix handoff or another early return can consume the tick. Only an
actual novel observed pose under the current selected route and unchanged
owner/world/life/goal may renew the baseline. Replans, new route tables, index
changes alone, stationary input and revisits earn no credit. Retain current
waypoint/crossing/floor semantics, the 150 cm novelty history, five-second
no-progress budget, original command deadline and cumulative sensing budget.
Apply the same sequencing to currently selected guarded local, memory and
native waypoint progress; inactive proposals cannot grant progress.

The new early-credit sequencing is limited to fixed coordinate goals. Actor
targets retain their prior `idx_progress`/late-credit behavior, including its
existing guard-hold limitation. Re-reading a moving actor after the final pose
callback can itself stale that pose; this wave does not add a broad native
transaction framework or claim dynamic-target repair. A final primitive world
identity comparison rejects a world change made by the pose callback. If a
natural actor-target attempt exposes the remaining gap, measure it separately.

An admitted local route owns its no-progress decision. If genuine no-novel
expiry occurs, report a specific bounded local-route failure (or persistent
follow unreachable state) after owned cleanup. Do not let ordinary backtrack,
memory retry or Bug2 implicitly take over while local authority remains. This
is an execution ownership boundary, not a navigation avoidance rule.

At the existing local-source invariant, capture a small primitive diagnostic
before finish: attempted source, local-authority boolean, backtrack deadline,
backtrack-test time and `move_acc`. Reuse existing bounded trace storage, cached
pose/time and generation; no native sensing, logging callback or per-frame disk
flood. This makes the next live attribution honest even if another source
conflict survives. Preserve the existing specific failure and cleanup behavior.

Sol owns `client_mod/scripts/move.lua`, `client_mod/tests/test_move.lua` and this
note in navigation-cause. Hold code until fresh design review. Root integrates
and owns the single DEV operator. No live/model/server actions by this worker.

## Search record

Repository search: actual published mover/guard and new trial evidence; preserved
feedback-loop `move.lua`/`test_move.lua` diff; `docs/design/active-guard-progress.md`;
the independent reset review and original navigation review. The preserved
candidate has targeted novel/revisited waypoint, guard hold, prefix handoff,
callback preemption and owned local-expiry tests worth adapting. No unpublished
candidate is treated as live-proven.

Fresh actual queries:

- `site.recastnav.com dtPathCorridor movePosition findCorners local path progress pruning`
- `site.docs.nav2.org progress checker path following route backtracking progress toward goal`

Opened primary sources:

- https://recastnav.com/classdtPathCorridor.html describes feeding actual movement
  back into the selected corridor and keeping local movement/corridor adjustment
  coupled. Conceptual precedent only; no Detour API is newly available in-game.
- https://docs.nav2.org/rolling/configuration_and_development/configuration_guide/core_servers/controller_server/
  separates path handling, controller execution, progress checks and goal checks.
  This supports keeping execution credit distinct from final-goal arrival.
- https://raw.githubusercontent.com/ros-navigation/navigation2/main/nav2_controller/plugins/simple_progress_checker.cpp
  renews its baseline immediately when observed pose movement is accepted.
  Adapt that observation/credit sequencing, retaining our stricter novelty,
  route binding and no-synthetic-progress policy. No source code is copied.

Decision: **adapt** the known progress-checking/selected-corridor pattern and
reuse the relevant existing candidate tests. No framework, dependency, new
native API or alternative physical controller is needed. Put the direct primary
URL beside code adapting the sequencing. Documentation is conceptual precedent;
actual game evidence remains the recorded trial.

## Generality and principles

This fixes generic executor bookkeeping across physical route handoffs. The
models retain intent and destinations. The body uses real player inputs and
truthful observed outcomes. It preserves PRINCIPLES 1-6, novelty/loop protection,
floor checks, one client and one live operator. It does not establish unfamiliar
discovery, self-provisioning or an autonomous round trip, and changes no judges.

## Acceptance test

Bounded focused actual-mover regression: use the real sampled guard, ordinary
short local grid legs and several local windows. Capture actual physical
movement, waypoint advancement, guard target-change holds, progress position,
prefix transitions and terminal outcome. The published baseline must reproduce
lost credit/route-source failure; the candidate must preserve the real progress
baseline across holds/handoffs and continue to actual arrival. Do not substitute
a test that only invokes the new helper or sets a successful result.

Reuse/adapt the earlier focused cases for novel and revisited waypoint poses,
prefix-final progress, selected native/memory progress, stationary/oscillating
motion, genuine local no-novel expiry, cleanup and callback preemption. New
route/index labels alone must not renew the timer. Check actual attempted-source
telemetry at a forced invariant and its bounded primitive-only retention.

Run focused cases and the design-note precheck. Do not run another whole mover
immediately before the release gate; root runs the final whole suite once inside
the exact-byte gate after cold source review. Then developer ordinary real
controls, followed promptly by complete Sonnet/Haiku if developer execution is
positive. Disclose assistance and retained route/task provenance. A local test,
review or developer success cannot count as the required autonomous pass.

## Focused offline result

The actual mover, real local planner and real sampled guard reproduced the
published baseline failure on a 40 m flat-world request: terminal X=22.80 m,
two completed prefixes, ten observed novel waypoint poses lost and zero retained
waypoint credits; terminal detail `local route unavailable`. This is a causal
offline discriminator, not an autonomous result or new game mechanic.

The candidate reaches X=39.60 m (within the requested 0.50 m tolerance), completes
four local prefixes, retains seventeen observed credits across guard holds and
loses zero. Focused cases also cover selected native/memory routes, prefix-final
credit, revisit rejection, callback successor/path/goal/pose/world/authority
changes, final pose-callback world change, inactive/stale native proposals,
preserved actor-target late behavior, genuine local expiry in go_to/follow and
the primitive attempted-source stamp. No model calls or live inputs were used.

Private offline evidence in the navigation-cause tree:
`logs/recovery/lpc-baseline-a1-output.txt` and
`logs/recovery/lpc-focused-a4-output.txt`. Final full-suite certification is
reserved for root's exact-byte release gate after source review; no separate
whole mover was run for this wave. Developer controls and complete-agent
measurements remain outstanding on this candidate.

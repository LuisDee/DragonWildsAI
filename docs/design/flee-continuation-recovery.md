# Flee continuation recovery

- **Goal:** keep the companion moving to safety when its escape destination is reached but observed attackers remain nearby, and report an escape failure truthfully.
- **Evidence:** the dev trace shows flee movement arrived at 07:42:53, while combat stayed in flee until death at 07:42:59. `begin_flee` requests one destination; `step_flee` monitors threats and timeout but does not renew a finished movement. The fatal attacker differed from the selected target; its detection timing and the cause of death are not established by this evidence.
- **Approach:** reuse `M.pack` and existing attacker and telegraph observations, movement status, arbiter token, and `go_to`. When an escape move becomes idle or fails while observed threats remain, retry at bounded cadence using current threat geometry, subject to the existing total flee timeout. Preserve the existing player-protect follow selection. Report unresolved destination or repeated movement failure specifically; do not silently report safety. Threat observation and safety checks must agree, including recent telegraphs. Zero-length geometry is an explicit unresolved failure, not an invented direction. No attack or defense policy changes.
- **Generality and principles:** works on observed attackers independent of species, phrases and water. Uses real client movement and existing ownership; does not claim an outcome without state evidence or override language interpretation. Single owner and bounded retries; no principle exception.
- **Acceptance:** fake-engine regressions cover arrival with tracked chaser, new attacker or recent telegraph, truthful failure for unresolved geometry/movement, no false safety, no repeated requests per frame, token ownership, overall timeout, and unchanged protect-follow behavior. Run focused combat suite, then main handles full gate and supervised dev measurement.

## Search record

Searched repository combat code, `docs/research` and existing defense design for flee, pack, threat tracking and movement. The repository already has pack centroid, arbiter and movement mechanisms; no replacement library is required. Reuse them and adapt the established event-driven condition-reassessment pattern. Epic documents observer aborts on changed conditions, path status, and replacement of an active move; these are conceptual precedents, not claims that this client uses AIController navigation.

- https://dev.epicgames.com/documentation/en-us/unreal-engine/behavior-tree-in-unreal-engine---quick-start-guide
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/AIModule/EPathFollowingStatus__Type
- https://dev.epicgames.com/documentation/unreal-engine/BlueprintAPI/AI/Navigation/MovetoLocation

## Review

Pending independent design review before implementation.

## Implementation review and verification

Independent design review approved with current observed threats for both safety and escape, actual arbiter ownership checks around reentrant calls, bounded attempts, and explicit unresolved geometry. The implementation uses fresh actor census, recent attacker/telegraph evidence and currently fighting target state; stale target positions are not used. It retains an active protect follow, bounds idle-move retries and total flee duration, and reports rejected moves or unresolved direction. Focused fake-engine combat/arbiter suite: 388 passed. No live survival outcome is claimed. Cold code review is pending.

Cold-review corrections: failed escape now emits outcome `failed` with the specific detail and still-chased state; a start event no longer claims flight completed. Repeated accepted moves that end in failure count toward the retry bound and preserve their movement reason. Recent tracked threats absent from the census make safety unresolved until observed or expired; unreadable target combat state also remains unresolved. Regression cases cover failed movement outcomes, unseen and expired threats, failed census, missing position or combat state, and reentrant ownership loss. Focused combat/arbiter suite: 395 passed. No live survival improvement is claimed.

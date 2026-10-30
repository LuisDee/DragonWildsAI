# Director ownership during ordinary situation reviews

Reviewed design and bounded implementation, 2026-10-30. Accepted steer: [autonomy-plan.md](autonomy-plan.md), adopted Astra review, original M1–M6 and frozen judges unchanged. The root agent owns live operations. Complete Sonnet Director + Haiku Controller acceptance remains 0/3 temple round trips.

## Goal and demonstrated cause

An ordinary proactive review must not create a second autonomous decision stream while the Director is deciding the board's next transition. Human interrupts, actual urgent body situations and native self-care/defense must retain their current paths. Models keep deciding tools and routes.

Private evidence: `C:/gameserver/logs/recovery/full-agent-a873/perception-feedback-audit.md`, published `6cade13`. Haiku call 7 retries the exact failed temple go_to while Sonnet replan calls 6/11/12 run; the body really executes the duplicate (generation 7). Later a hydration review, calls 30/31, autonomously pauses the board during replan 28/29/32. Session `brain-live-20261030-021349-14184.jsonl:342` records pause_board; row 350 correctly discards paid replan 32 as stale/paused. Trial terminal result is paused, 33 wrapper responses (17 Haiku, 16 Sonnet), no autonomous pass.

`Agent._review_tick` checks `director.running`, which means only `_in_run`; worker `_future` and the board's `awaiting_decision` do not count. `flush_situations` has no planning-ownership guard either. The Director already serializes its own transitions and correctly checks stale plan keys. Those mechanisms should be reused, not replaced.

Both models received the exact native navigation_observation through ordinary and first_call paths. Surfaces explicitly have unknown connectivity and capsule clearance. This repair does not invent a floor label, path, waypoint or movement permission.

## Approach and ownership contract

Proposed production files: `brain/director.py` and `brain/agent.py`; one focused new regression file. Preserve `running` semantics for existing callers. Add a separate read-only Director property expressing ownership of an active board transition: `_in_run`, an outstanding `_future` (including a finished future whose result has not yet been collected/applied), or a current task's matching `awaiting_decision` while that task can still run. A paused/parked/ended board with no outstanding future must not hold ownership forever. Do not include unrelated skill-learning futures. The property reads current state only; it starts/cancels no worker and makes no game request.

Use this property in ordinary review admission before `broker.review_due`, so a pending review stays in the broker instead of consuming its review/cooldown bookkeeping. Also check it at `flush_situations` before `take_situations` empties the queue: retain only blocked `type='situation_review'` entries, and continue processing any other pending body situations. Do not return early for a mixed queue and accidentally block `vitals_low`, attacked/held-action failures or player events. A completed-but-uncollected planner still owns the transition because Agent checks reviews before Director.tick collects it.

Deferred ordinary reviews must be checked against a new state after ownership ends. Do not assume `broker.still_valid` already does this: its current implementation rechecks unreachable/items/vitals but passes situation_review unchanged. In Agent, use a small pure revalidation helper for this existing event type: use the broker's existing survival-stat/band helpers and reported current time-of-day/bag/player facts to retain only changes still true; refresh current facts in the event; discard an empty obsolete review with a bounded reason log. Preserve the original event/previous-review chronology rather than stamping old changes newly observed. This is observation validity, not a tool-selection rule. No new severity thresholds or language matching. Tests must cover recovery of the triggering stat while planning was pending. If a change cannot be checked because current state is unavailable, keep it explicitly historical/unknown or defer it; do not present it as freshly verified. Implementation should choose the smaller truthful representation during review rather than expand into a broker rewrite.

No blanket block of Controller calls, board tools or model pauses. Genuine player chat/stop/pause continues through the existing command/interrupt path. Native self-care/defense and non-review body situations are unchanged. Day/night currently shares the situation_review event type; it is deferred for this bounded planning interval too, not reclassified by new heuristics. Existing decision timeouts/budget/park transitions remain responsible for ending that interval, after which review is possible. A waiting-budget task should not suppress ordinary reviews indefinitely: the ownership predicate must distinguish an active decision transition from a parked/waiting-budget state with no future.

The worker retains its immutable snapshot. Do not inject mid-request review results or weaken `plan_key` stale checks. No new provider retry, cancellation framework, budget policy, persistent migration or actor scheduler is required.

## Separate provenance issue (deferred from this implementation)

`Director._handle_tool('pause_board')` labels every invocation `player:{player}`. An autonomous review uses addressed player Luis despite empty command text, so a873's model self-pause persisted as player:Luis. Correct attribution requires explicit initiating-context information at the tool-dispatch boundary; changing a string inside Director cannot prove that context. Keep this separate unless review identifies an existing unambiguous origin already available. Do not expand the ownership fix to revoke model tool permissions or special-case refusal wording. Do not report the observed pause as a human request.

## Principles and generality

Reuse one owner per resource/transition and ordinary event deferral. There are no place, entity, recipe or phrase rules, no tool/argument rewriting, and no change to observed game outcomes or frozen judges. The same scheduling contract applies to any board job. Failure context and source freshness remain truthful. Pauses caused by real human requests remain authoritative. No principle exception is requested.

## Acceptance and limits

Focused offline regressions must drive the actual Agent admission/flush methods with a real Director state and controlled Future, not just assert the new property's value:

- Pending replan plus ordinary review produces no Controller/provider call, duplicate body action or board pause. Cover a done-but-uncollected Future and awaiting-decision before dispatch.
- Prequeued ordinary review is retained during ownership; a mixed urgent/non-review event still reaches its existing handling. After release, a recovered stat drops the obsolete review; a still-valid change reaches the Controller once with current facts and historical provenance.
- A paused/parked/waiting-budget board without a Future releases ordinary review admission. Learning alone does not acquire this ownership.
- Genuine human command/pause and attacked/vitals paths still work. Human pause still makes an in-flight decision stale; the existing discard remains intact. No assertion should force a specific model route or claim model self-pause is forbidden.

Run only targeted Agent/Director/broker regressions and `tests/test_design_notes.py` with a unique new runtime basetemp. Root owns the full gate, developer real-control check and complete Sonnet/Haiku trial. Live acceptance must show ordinary reviews do not race a board replan, relevant failure evidence still reaches both actual inputs, human/urgent interruption still works, and actual navigation outcomes—not model explanations—determine progress. This scheduler fix does not itself prove temple connectivity or any autonomous round trip.

## Implementation and verification

After fresh design review cleared the note, root authorized the bounded implementation in `brain/agent.py`, `brain/director.py`, and `tests/test_director_review_ownership.py`. The new pure `owns_transition` property leaves `running` unchanged. Agent uses it before broker review bookkeeping and at the shared `take_situations` boundary, so ordinary queued reviews also stay out of human-chat merging while the board transition owns the decision. Legacy test/port adapters without the new property retain their existing `running` contract.

The shared take boundary revalidates all emitted reviews, including formerly pending broker changes, with the existing stat bands, bag-full and near-player/idle constants. It preserves original change records and previous-review chronology, labels changes historical, refreshes current facts, and explicitly marks missing/unavailable facts unknown. It does not rewrite a selected tool or add a provider call. Unknown state is not presented as recovery or fresh evidence. Non-review situations remain eligible in a mixed queue. The separate player-origin attribution issue remains deferred.

Focused verification covers pending/done/cancelled Futures, matching runnable awaiting decisions, inactive/budget-wait release, learning exclusion, real mixed urgent review dispatch, native defense, recovered pending/queued review filtering, fact refresh without source mutation, human-chat merging, genuine human pause with stale-plan discard, and unavailable/nonfinite facts. Existing Agent/event-hygiene, M1 live-fix, Director, retained-feedback and design-note regressions are included. These are scripted offline diagnostics; no API/game calls or autonomous passes are claimed. Root owns cold review, full gate and live stages.

The initial focused checkpoint passed 178 tests. Cold review then demonstrated a precision defect: real broker hydration 29.6→14.6 emits rounded 30→15, and recovery to 20 cannot prove which original triggering band remains true from those rounded fields alone. The narrow correction considers each historical integer's half-unit rounding interval, enumerates existing bands compatible with an actual downward crossing, and compares the current unrounded band with every possible triggering band. All satisfied means current; none satisfied means obsolete; mixed evidence is retained with explicit `current_validity=unknown`. No broker schema, thresholds or historical precision are invented. New regressions generate this event with the real broker and test current/unknown/obsolete outcomes through both pending and queued admission paths.

Final focused command used runtime Python with `tests/test_director_review_ownership.py tests/test_event_hygiene.py tests/test_m1_live_fixes.py tests/test_director.py tests/test_attempt_feedback_retention.py tests/test_design_notes.py -q --basetemp C:/gameserver/logs/recovery/review-ownership-a874-20261030-sol-rounding-1`: **184 passed in 7.63 s**. No live/API/full-gate validation is claimed.

## Search record

Repository searches: `director.running`, `_future`, `awaiting_decision`, `situation_review`, `review_due`, `still_valid`, `flush_situations`; inspected Agent pump/review/flush, Director transition/dispatch/collection, broker review bookkeeping and the actual a873 requests/results. Existing broker busy admission already defers unissued reviews; reuse it. Existing queued-review validation has the explicit limitation described above.

Actual fresh web queries for the audit/design:

- `site.anthropic.com engineering effective context engineering agents tool responses context`
- `site.w3.org TR scxml run to completion external events macrostep`
- `site.docs.python.org 3 concurrent futures Future running cancel`
- `site.docs.python.org 3 library functions round nearest integer ties even`

Opened primary sources and decisions:

- https://www.w3.org/TR/scxml/ — conceptual precedent for completing an owned transition before admitting another ordinary external event. Adapt the scheduling principle only; do not adopt SCXML or apply its semantics to urgent/human interrupts wholesale.
- https://docs.python.org/3/library/concurrent.futures.html — verified Future distinction: done/running/cancelled are different states, and running work cannot simply be canceled. Keep ownership until collection; no attempt to kill or retry a paid request. Documentation currently serves a newer Python version; only the long-established Future state contract is used.
- https://www.anthropic.com/research/effective-context-engineering-for-ai-agents — conceptual precedent for bounded relevant execution context and avoiding stale context. It does not establish this game's scheduler behavior or select a successful route.
- https://docs.python.org/3/library/functions.html#round — verified nearest-integer rounding and ties-to-even behavior. The half-unit interval describes lost numeric precision; it is not a new survival threshold. Only existing broker bands and the reported downward-crossing provenance constrain the possible triggers.

Decision: reuse existing board/Future ownership and broker event classification; adapt two review admission boundaries and minimal observation revalidation. Build no broader framework. Put these direct URLs next to any later informed production changes. No production implementation is authorized by this note alone; fresh design review precedes it.

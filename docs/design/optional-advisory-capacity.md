# Preserve validated decisions when optional refinement has no capacity

## Goal and evidence

Follow [Accepted steer](autonomy-plan.md), original M1–M6 and frozen judges.
Live a914 waited 407 seconds before its first move. Its first five-call planning
decision lost a repaired valid plan when an optional already-true-start advisory
attempted a sixth request. See the [failure audit](../research/2026-10-30-second-roundtrip-failure.md).

## Approach

Add an optional, read-only `can_advise` callback to `json_decision`. Default
behavior stays unchanged. Only after successful validation, when an advisory
would otherwise request another round, check this callback. If false, return
that exact validated model value and record `advisory_skipped=capacity` in info.
Do not consume another request or alter predicates, actions or the model choice.
Director supplies `lambda: dec.requests < MAX_REQUESTS`. No daily/hourly budget
increase, reservation reset, fallback on invalid output or caught cancellation.
The ordinary `before_request` remains the authority for every actual model call.
No fallback to an older candidate after a newer advisory response was received.

Files: brain/llm_json.py, brain/director.py and focused regression tests. Native
movement, ownership and frozen scoring code are untouched. This does not repair
the separate long memory-prefix detour or prove a live roundtrip.

## Generality and principles

This boundary applies to any valid structured decision with optional refinement.
It never scripts a game task. It preserves the model's own validated choice;
unknown observations remain unknown and hard validation remains mandatory.
Expose the skipped advisory in the Director decision diagnostic so a trace can
distinguish accepted output from additional refinement. Root owns integration.

## Acceptance

Offline: reproduce two research rounds, an empty response repair, an invalid
ordered-loop repair and the final valid advisory-bearing response at call five.
Check that the same final model decision is applied with five calls. Check
advisory execution when capacity exists, rejection of invalid/truncated output,
and unchanged hard budget rejection before any valid answer. Use actual Director
and shared JSON loop paths where possible, with no API calls. Fresh design and
cold reviews, targeted regressions, then full gate on the frozen candidate.
Developer real controls precede complete Sonnet/Haiku remeasurement; no offline
result counts as a gameplay pass. Preserve a914 task and world histories.

## Search record

Reuse the searches opened for the same a914 problem on 2026-10-30, recorded in
the failure audit and private planning-delay-audit.md. Queries included
`site.anthropic.com engineering building effective agents evaluator optimizer
stopping criteria latency` and `site.aiolimiter.readthedocs.io varying capacity
requests has_capacity`.

- https://claude.com/resources/articles/common-workflow-patterns-for-ai-agents-and-when-to-use-them
  supports bounded, justified refinement rather than repeated optional cycles.
- https://aiolimiter.readthedocs.io/en/stable/#varying-capacity-requests
  distinguishes capacity checks by operation weight; our own limiter is retained.
- https://www.anthropic.com/research/writing-tools-for-agents
  supports exposing actionable, bounded diagnostic context to agents/evaluators.

Decision: adapt the existing decision loop; no new framework or dependency.
These are conceptual precedents, not verified Dragonwilds APIs. Put the relevant
source beside the changed code. No gameplay or judge threshold is relaxed.

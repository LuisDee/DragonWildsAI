# Second full-agent roundtrip: failed repeat

Accepted steer: [autonomy plan](../design/autonomy-plan.md). Original M1–M6 and
frozen judges unchanged. This is evidence, not a new gameplay capability.

## Live outcome

Private evidence: `C:/gameserver/logs/recovery/temple-repeat-a914/`.
Complete Sonnet Director + Haiku Controller on runtime `3b7d61e`, behavior
`f63d809`, companion `a19d5534c84d008f`. No operator intervention during the
900-second episode. Existing demonstrated routes and supplied provisions were
retained and disclosed. There were 17 Haiku and 16 Sonnet calls, 608 native
samples, minimum health 100, maximum horizontal lodestone distance 150.397 m.
Final return error was 0.246 m horizontal and 0.051 m vertical, grounded.
Task `070540ab` ended `waiting_budget`; cleanup stop succeeded. No 200 m crossing
occurred. **Consecutive roundtrips: 0/3.** a907 remains one historical success.
Candidate `694fb84` was not deployed and is not validated by either episode.

## Demonstrated failures and limits

- First movement request arrived 407.211 seconds after the running marker.
  Planning consumed eight Sonnet calls, then preparation waited for the unchanged
  20/hour allowance. This was a local limiter, not provider exhaustion.
- The first decision repaired empty output and illegal checkpoint loops. Its
  fifth response was valid in a bounded offline replay but generated an optional
  already-true-start advisory. `llm_json.json_decision` loops for that advisory;
  the next `before_request` rejects the sixth call and loses the valid candidate.
  The replay uses boot state and omits capability argument checks; see
  `planning-advisory-replay.json`, not an exact snapshot replay. Source and the
  actual request sequence support this cause. No repair has been implemented.
- The outside landmark was reached after sweep failure and a busy refusal.
  The next ordinary `go_to([250,1790,-28])` selected an 89-point memory prefix
  from approximately `[182.84,1815.67,-28.97]`. Its sampled travel was 123.31 m;
  it timed out at `[136.68,1869.76,-30.49]`, farther from the goal. Native trace
  explicitly marks this as a prefix. `navmem.lua` currently selects reachable
  prefix endpoints by least remaining horizontal distance, using path cost only
  to break equal-distance ties. This is a concrete candidate for replay and
  comparison, not proof that changing the scoring alone solves traversal.
- Haiku interpreted later busy refusals as needing movement reset. a907 proved
  transient consumable contention can cause that message; do not infer a leaked
  owner in a914 without correlating its exact native ownership events.

## Search record and next experiment

Queries: `site.anthropic.com engineering building effective agents evaluator
optimizer stopping criteria latency`; `site.aiolimiter.readthedocs.io varying
capacity requests has_capacity`; `site.docs.nav2.org route server route graph
path planning start goal connectors`; `site.anthropic.com engineering writing
tools for agents error messages actionable feedback`.

Opened primary sources:

- https://claude.com/resources/articles/common-workflow-patterns-for-ai-agents-and-when-to-use-them
  — optional refinement must justify its latency and have stopping criteria.
- https://aiolimiter.readthedocs.io/en/stable/#varying-capacity-requests
  — weighted admission differs from availability for one call. Retain our
  existing limiter and budgets; no new dependency.
- https://docs.nav2.org/rolling/getting_started/nav2_behavior_trees/trees/navigate_on_route_graph_w_recovery/
  — graph routing is combined with local feasible connectors and path validation.
  Conceptual precedent, not an API verified in Dragonwilds.
- https://www.anthropic.com/research/writing-tools-for-agents
  — actionable tool errors and bounded high-signal results help model recovery.

Decision: do not repeat unchanged. First reproduce the valid-decision/advisory
boundary with exact inputs and preserve validated choices when optional
refinement cannot run, subject to fresh review; never accept invalid output or
weaken ordered predicates. Independently inspect the captured generation-3
route selection and compare complete route cost and feasible connections before
another walking change. Preserve all world history. The pre-existing recovery
dispatch candidate still needs developer real controls before full-agent proof.

## Follow-up: deterministic memory-growth comparison

After the a922 candidate was frozen, root replayed the unchanged pure Lua
`navmem.forward_walk` against the private pre-a914 snapshot, then added only
route `r152`, learned during the successful outward landmark leg. `r153`, learned
on the later return, was excluded. Water cells were the only other changed
existing memory field; before/after water states produced identical paths.
No game input, model call or live memory edit was made.

At the exact generation-3 source and goal, pre-a914 memory returned
`no_connection`. Adding r152 returned the same 89-point prefix seen live:
231.550 m polyline length, 239.009 m weighted cost, starting 71.906 m from the
goal and ending 45.859 m from it. All 110 sampled remembered-point observations,
covering 45 waypoint indices, match replay coordinates exactly (0 cm error).
Artifacts: `replay-gen3.lua`, `gen3-selector-replay.json`,
`gen3-replay-binding.json`, `gen3-replay-analysis.md` in the private a914 folder.

This isolates newly available graph connectivity as the trigger for the long
prefix selection, not a water-cost change. It does not prove a shorter physical
path. In a907, local `route_observation` plans toward the same destination crossed
200 m; different start/memory conditions prevent treating that as a controlled
live comparison. Next examine arbitration between an incomplete remembered
proposal and local feasible progress. Preserve complete-route authority and
away-first discovery; do not erase learned routes or blacklist route IDs.
The Nav2 source above supplies conceptual precedent. No navigation patch yet.

The independent planning repair is checkpoint `aabdd66`, with a922 full gate
1,388 passed/1 skipped/600.27 s GREEN, 635 source and 53 memory files verified.
It is not deployed and has no new developer or autonomous gameplay proof.

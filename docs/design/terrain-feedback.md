# Terrain failure evidence delivered to both models

## Goal

When movement fails, both developer and complete Sonnet/Haiku agent can inspect
what was sampled, what blocked the candidate and what remains unknown. Preserve
[Accepted steer](autonomy-plan.md), frozen judges and model-selected intent.
This does not implement a global map or claim a successful temple route.

## Evidence and approach

Published developer far walk ended at a native partial endpoint; the local
candidate failed across real vertical collision. The tool returned native route
error but not local sampling geometry. Director `_last_results` additionally
drops all action data. Current research and private controls are linked in
[the grounding record](../research/2026-10-29-player-grounding-native-controls.md).

Reuse `localplan`, `move`, bridge action results and existing Controller/Director
loops. Before discarding a failed observation planner, copy a bounded primitive
snapshot: sampled window, units/floor convention, resolution, cell/sample counts,
explicit unknown coverage, at most24 candidate surface positions and8 individual
horizontal-ray hit positions. Mark near-pawn substituted feet separately from
line-hit surfaces. Preserve counts/truncation and the two-layer sampling limit.
Candidate surfaces are not capsule-clear or reachable; ray hits are not complete
walls; missing data is not a gap. Do not issue additional native queries.

Bind snapshot to command generation, exact goal, owner, pawn, life and world.
Only forward evidence whose binding remains valid at terminal result production
and bridge delivery. Include sample time/age and failure stage/reason. A failure
snapshot remains historical evidence, never movement authority. Initial scope
is existing local observation planning, not every perception/UI family and not
a new tool. Do not retain native objects in serialized data or clear world state.

Director should retain useful bounded action data in its actual continuation
and replan inputs, including this packet and existing native route feedback.
Use bounded primitive JSON with explicit truncation, preserve at least original
tool/ok/reason for the last8 records and prioritize newest evidence under the
aggregate context budget. Do not silently cut JSON strings or mutate source
action records. Controller already sends results; verify that with the new
packet. No phrase/intent rules, chosen intermediate waypoints or scripted detour.

Root owns localplan/move/client_bridge and their Lua tests. One bounded Terra
worker may own Director and its tests after design review. Keep source URLs next
to informed code. Runtime stays on the last tested deployment during development.

## Principles and acceptance

Generic evidence, existing real controls, model choice preserved, no judge edits,
no outcome emulation. Model claims remain separate from state. Unknown evidence
cannot authorize motion. The body packet needs no game-model calls.

Offline: different layers, self-foot substitution, unknown/empty window,
truncation/counts, real hit points, failed sampling/verification with/without
native route metadata; no false reachable/clear labels. Reject stale owner,
world, life, goal, pawn and generation. Bound serialization and preserve exact
useful fields through bridge, Controller and Director model-request captures;
check task success predicates and model choice are unchanged.

Then full gate and developer real-control route using a frozen deployment,
capturing actual motion and packet delivery. Only after that positive control,
run complete Sonnet Director+Haiku Controller unaided, with actual models,
Director state, spend and outcome recorded. A developer-reproduced failure with
richer evidence proves observability only, not navigation acceptance. Original
three200m temple round trips plus generality remain required.

## Search record

Actual queries: `site:anthropic.com engineering tool results context feedback
agent tools clear observations` and `site:platform.claude.com docs tool_result
content tool use agent feedback`.
Opened primary sources:

- https://www.anthropic.com/research/building-effective-agents
  Environmental results inform the next agent step. Framework guidance is
  historical, not a proposal to migrate our harness.
- https://www.anthropic.com/research/effective-context-engineering-for-ai-agents
  Curate useful context and retain critical task evidence under finite budgets.
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls
  Client results are associated with their actual tool calls; errors remain
  results, and external content is untrusted evidence.

Decision: reuse existing transport and model loops, adapt bounded source-aware
feedback. No new runtime library, model service, map backend or perception claim.
Native terrain sources are already opened and recorded in the grounding note.

## Live measurement on fd9fa13

Fresh full gate1264/1skip GREEN, followed by developer real controls: the actual
failure packet returned24/338surface candidates and8/12recorded barrier samples,
with9m coverage and underlying unreachable_in_window, health100. The route
itself failed. This validates body observability, not successful navigation.

Complete Sonnet5.5/Haiku5.5 then independently completed a34.23m return step to
the lodestone but prematurely marked the compound job done before its outbound
leg. No new terrain packet was present in live model requests during that
successful step. Thus live complete-agent use of failure geometry remains
unproven despite the offline request-capture checks. Preserve this distinction
and repair the separate completion contract before the next full trip trial.

Before selecting that complete-agent trial, root inspected the developer failure
and searched `site:docs.nav2.org local planner global path obstacles detour` and
`site:github.com/mindcraft-bots/mindcraft pathfinder no path navigate`. No directly
applicable UE implementation was established from those results. Opened the
Anthropic effective-agents primary source again for grounded result/replan
feedback. Decision: measure the full agent on the original objective with no
operator route hints; do not repeat the unchanged failed eastward command or
silently substitute a Minecraft movement fix.

# Observability and DBOS/Postgres assessment

Luis asked during the independent Astra review whether DBOS-backed agent-turn
state in Postgres is worthwhile, how to add observability and how to use the
findings to achieve the goal. This is a researched recommendation, not an
implementation or permission to resume the PAUSED development Goal.

Read [Accepted steer](../design/autonomy-plan.md) and the
[independent Astra report](2026-10-29-astra-independent-reset-review.md).
Original M1-M6, frozen judges and full Sonnet Director + Haiku Controller live
acceptance remain unchanged. Logging/database/review work is not gameplay gain.

## Recommendation

Build a causally linked, append-only execution/evidence record. Postgres is a
reasonable query store if available, but a database migration is not a prerequisite
for the next decisive live test. Existing JSONL can be indexed through one writer
and preserved as raw evidence. Do not introduce two competing task/state stores.

DBOS is durable execution, not merely a turn database. Evaluate it later for
high-level jobs, model turns, bounded research and durable action intents. Keep
frame-level movement, native game ownership and collision/control loops outside
database workflow steps. Do not make game-frame input depend on a database round
trip. The first meaningful test of a store is whether it answers the missing
causal question in the same failed live case, with acceptable measured overhead.

Current official Python docs support SQLite (default) and Postgres. Therefore
DBOS evaluation does not inherently require installing a Postgres server on the
game machine. Production/multi-host needs and operational resources should decide
the backend; no deployment/resource benchmark has been performed here.

## Recovery semantics that must be respected

Official DBOS workflow/architecture docs say completed steps are checkpointed,
incomplete steps can execute at least once, workflow code must be deterministic,
and retried external operations should be idempotent. Database transactions can
commit exactly once; this is not an exactly-once guarantee for the game world.

Example: the game consumed an item, then the Python process died before recording
completion. Blind step recovery may consume another item. The same ambiguity
applies to crafting, transfers, movement and paid model calls. Persist a command
ID, task/turn/attempt, world/character/life/owner epoch, intent and preconditions
before dispatch. On uncertain completion, reacquire the one live operator and
read current world state before deciding whether to mark complete, continue,
cancel or issue a new command. The game does not participate in our SQL transaction.
This application-level reconciliation requires design and crash-boundary tests;
no DBOS API integration has been verified in this repository.

DBOS also documents possible concurrent/zombie executions during recovery.
Checkpoint ownership protects DBOS writes, but cannot retract game inputs already
sent. Preserve the existing live arbiter and use body-enforced execution epochs;
one external executor must not continue controlling the character after losing
ownership. Never catch a workflow conflict and keep issuing actions.

Recovered checkpointed observations are historical. They cannot become fresh
perception simply because a workflow resumes. Verify world, pawn/life, operator,
task and current state before any new effect. Preserve original goal and verified
history without carrying an obsolete "return already done" condition into a new
acceptance episode. Do not reset world memory to obtain clean task history.

## Proposed evidence model

Use one correlation chain across independent records:
`run -> task/goal -> model turn -> command/action attempt -> selected route version
-> native observation/transition -> tool result -> next model input -> goal check`.
These are proposed application fields, not claims about current DBOS tables or
stable OpenTelemetry attribute names.

| Record | Required evidence |
|---|---|
| Run | Source/deployed/loaded module identity where measurable, build, driver, world, character, scenario, assistance, start/end and termination reason |
| Model turn | Role/model, exact sanitized serialized messages and tool definitions or immutable artifact references/hashes, actual output configuration/max tokens, provider/request ID, response, stop/finish reason, usage/cache/cost, parse/schema result, latency |
| Observation | Source, native/normalized units and frame, capsule centre versus support point, identity/support layer, observed-at time, coverage, known/partial/unknown, raw artifact reference |
| Action | Original intent, args, command ID and attempt, before/after observations, ownership/generation/life/world, actual game evidence, specific result and interruption/reconciliation state |
| Route | Proposed and selected source/path/version, original goal versus waypoint, completeness/projection, typed segments/support layers, provenance, invalidation/switch reason |
| Recovery | Trigger, old/new source, pose/velocity/input, waypoint/corridor, guard-held versus admitted-input time, progress baseline, thresholds, query budget, stale evidence and cleanup result |
| Task/checkpoint | Objective and acceptance version, ordered observed events, interrupted job/resume reason, no model-claim-only completion |
| Evaluation | Frozen criterion, current source/build, driver, assistance, independently observed result, evidence references; diagnostic and autonomous outcomes separate |

Use UTC plus monotonic/boot/session context for elapsed time and game/frame time
for native scheduling. Do not sum different clocks. Use stable event IDs and
idempotent inserts; retain original logs and checksums. Large payloads can stay
in private compressed artifacts with indexed references. Keep credentials out of
records/Git and restrict prompt/log access; record task-relevant decisions and
results, not invented reasoning. DBOS system tables are not our application schema.

## Highest-value observability before another broad platform change

1. Exact model boundary: the real launcher currently uses 1024/2048 output limits,
   unlike its convenience factories. Preserve actual settings and finish reasons;
   distinguish truncated output, malformed JSON and unsupported research tools.
2. Route transition event: why a747 discarded memory, not merely the final
   sensor_unavailable. Capture selected and inactive proposals and stale-state
   disposition at every switch, using existing values where possible.
3. Motion/control timeline: actual position/elevation, velocity/input, active aim,
   support/waypoint, query holds and time spent able to move. Retain a bounded
   high-rate pre/post-failure ring buffer; emit lower-rate steady summaries and
   explicit dropped-event counts. Measure observer overhead before trusting it.
4. Actual next model requests after the failure: did both models receive the
   relevant result, and did their subsequent action use it? A diagnostic that
   stops immediately after failure cannot answer this question.
5. Goal view: three trip counters remain zero until ordered actual game events
   satisfy the criteria. Include live attempts/passes, completion time, assistance,
   survival, failure category and active/blocked/idle time. No commit/test counters
   presented as capability improvement.

A useful read-only viewer should link a conversation/turn timeline to selected
route changes and a map/elevation replay. It should answer "what did the agent
know, what did it choose, what actually happened, why did it switch, and what did
it do next?" Queries should expose truncated turns, rejected callable names,
repeated failed commands and where real time was spent. Do not build a large
dashboard before demonstrating that the necessary events answer a live failure.

## Adoption order and stop conditions

- First retain a small compatible event envelope in the existing recorder and
  capture the decisive live replay after explicit resume. Add an asynchronous
  query-store writer if it materially shortens causal reconstruction.
- Repair the measured model/route contracts, validate through developer controls,
  then promptly run full-agent walking acceptance and held-out discovery.
- Evaluate DBOS only at a high-level boundary, without replacing the motion layer:
  one durable task/turn/action-intent workflow, one live operator, fresh recovery
  reconciliation and preserved world memory.
- Test crashes before dispatch, after game effect but before receipt, and after
  receipt; test stale owner/life/world and duplicate delivery. Require no duplicate
  game effects, no stale observation treated as fresh, preserved unmet objectives,
  correct spend accounting and bounded measured overhead.
- If storage work does not expose the missing cause or improve recovery of the
  same measured job, stop expanding it. No new platform is an excuse to defer the
  temple/held-out live outcome indefinitely.

## Search record — 2026-10-29

Actual queries: `site:docs.dbos.dev Python workflows steps external side effects
idempotency exactly once recovery agents`; `site:docs.dbos.dev observability
OpenTelemetry traces PostgreSQL agent workflows`; `site:docs.dbos.dev
OpenTelemetry observability tracing`; `site:docs.dbos.dev SQLite PostgreSQL system
database Python`; `site:docs.dbos.dev "OpenTelemetry"`;
`site:opentelemetry.io "gen_ai.response.finish_reasons"`.

Primary pages searched/opened:
- https://docs.dbos.dev/architecture
- https://docs.dbos.dev/python/tutorials/workflow-tutorial
- https://docs.dbos.dev/python/examples/outbox
- https://docs.dbos.dev/explanations/concurrent-executions
- https://docs.dbos.dev/python/tutorials/database-connection
- https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/
- https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/

The DBOS database-connection open redirected to a page with no readable lines;
the official search result explicitly documents SQLite/default and Postgres.
The older OTel GenAI URL is marked moved/deprecated; follow current repository
links and pin an instrumentation convention version before implementation. OTel's
official 2026 GenAI article also describes chat/tool spans, model/usage/finish
reasons and opt-in content capture:
https://opentelemetry.io/blog/2026/genai-observability/

Findings: established durable execution and trace conventions fit high-level
audit/recovery needs, but do not prove game-side exactly-once control or map
understanding. No direct DBOS/OpenTelemetry integration capability was verified;
do not assume automatic DBOS GenAI tracing from these searches. Decision: adapt
the causal record/trace conventions first, evaluate optional workflow adoption
against a real recovery defect, reuse existing native control and memory.

# Dispatch goal and skill recovery decisions after failure

2026-10-30. Root approved this narrow repair. Accepted steer: [autonomy-plan.md](autonomy-plan.md), PRINCIPLES, original M1–M6/frozen judges unchanged. Root recorded1/3 full Sonnet/Haiku round trips on f63d809 with declared taught memory; offline checks here are diagnostics only.

## Goal and measured cause

Preserve the model's chosen recovery when an action fails and the next response contains only a learned skill or a new goal. In a907, Haiku17/21 selected run_skill after a transient go_to busy result. Controller correctly placed it in Decision.skill; Agent's postfailure empty-response check only considered actions/speech/refusals and broke before the existing skill queue could run. No skill request reached the body. Private evidence: `C:/gameserver/logs/recovery/model-choice-full-a907/movement-owner-audit.md`.

## Approach and principles

Only `brain/agent.py`, new `tests/test_recovery_decision_dispatch.py` and this note are owned. Include d.goal and d.skill in that existing nonempty recovery check. Let the next ordinary loop iteration dispatch via _run_turn/_queue_skill or the existing pending-goal path. Preserve expansion/precondition validation, action sequencing, player interrupts, deadlines/budgets and truthful fallback for an actually empty decision. Do not execute a goal twice or repeat the preceding failed action automatically.

Source distinction: a goal-only response was already assigned to pending_goal after the old break, but the old guard could narrate the previous failure before dispatch. Its regression protects that existing pending path and removes stale speech without double execution. The learned-skill response was actually dropped before _queue_skill; this is the execution loss demonstrated by a907.

This repairs dispatch of existing typed Decision fields. It adds no route, phrase, skill template, retry rule, model prompt or tool rewrite. Native arbiter/body/runtime ownership remains untouched: the a907 busy windows protected consumable verification and later cleared normally. Completion narration and missing checkpoint report context are separate work. No principle exception is required.

## Acceptance and limits

Drive real Agent+Controller+Executor with a mock first action failure followed by run_skill-only recovery: verify one queue/expansion/execution, no extra Planner call and no stale failure speech replacing recovery. Cover goal-only pending dispatch/one execution and genuinely empty response retaining the truthful original failure. Run relevant existing skill, controller-loop and continuation timing/interrupt/budget tests with a new runtime basetemp; root owns cold review, full gate, publication and live validation. No test here proves another autonomous pass or changes the accepted physical outcome.

## Focused verification

Root reviewed the production condition and three real-Agent regressions as clear. Runtime Python ran the new tests, existing controller-loop/skills/continuation/event-hygiene suites, the Director failure-narration cases and design-note checks: **156 passed in17.82s**, unique basetemp `C:/gameserver/logs/recovery/recovery-dispatch-a913-sol-3`. No full gate, provider/game calls, runtime edits or publication were performed. Root owns cold review/integration and any later developer/full-agent acceptance; the declared1/3 physical outcome is unchanged.

## Search record

Repository: traced Controller._collect_skill, Agent._command_run/_run_turn/_queue_skill/run_directed and existing skills/continuation tests. Actual fresh query for this dispatch problem: `site.platform.claude.com docs handle tool calls is_error continue conversation error result next tool`. Opened the primary pages below before selecting the repair; earlier lock/arbitration sources inform only the separate ownership audit, not this Python change.

- https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls — return correlated failures and let the model continue. Adapt this continuation contract; the local typed Decision dispatch is our existing implementation, not copied SDK code.
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/how-tool-use-works — the client runs model-selected tools/results in a loop. Reuse the existing loop rather than replacing model intent with a fallback.
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/parallel-tool-use — side-effecting calls can run sequentially and results remain correlated. Preserve the present sequencing and stop-on-failure behavior; do not add parallel execution.

Decision: reuse existing typed decisions, learned-skill validation/queue and pending-goal executor; adapt one incomplete empty-decision predicate. Build no new workflow or recovery framework.

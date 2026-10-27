# Planner continuation recovery

- **Goal:** after accepting a task, the Controller can respond from its actual board result without waiting for the Director's plan or speaking a canned acknowledgement.
- **Evidence:** Director already dispatches one worker future and Agent handles chat before ticking it. Pending Sonnet planning has not been established as a live blocking cause. A concrete source defect is independent: successful board tools return results but no body `ran` entry, so a silent add_task skips continuation and can produce the generic misunderstanding fallback.
- **Approach:** reuse Controller.next_turn for a user command with completed non-body tool results and no spoken line. Count those results as activity for the fallback, but leave body-action `ran_all` unchanged: passing add_task to on_player_command would preempt its own task. Preserve existing behavior for already-spoken replies, standing body actions, body-initiated report_step and ordinary body preemption. Existing turn and player-interruption limits still bound continuation.
- **Generality:** normal tool-result handling; no phrase rules, forced text, task-specific plan or duplicated worker. The model chooses its reply and next action from truthful results.
- **Acceptance:** real Agent and Director with a manually unresolved executor future; silent add_task gets its actual result back to the Controller, whose chosen reply occurs before the plan completes. Subsequent player chat is serviced while the same future remains pending. The task stays active and planning dispatches once. Cover text and explicit-say channels; retain existing stale-future/cancellation tests. No live speed improvement is claimed by fake-model tests.

## Search record

Repository research already recommends a fast Controller and slower planning worker: docs/design/director.md and docs/research/2026-10-25-scalable-agent-frameworks.md. Reuse that architecture and the existing ManualExecutor tests; no new concurrency layer is needed. Primary precedents describe asynchronous futures, co-playable character planning and returning tool results to the model.

- https://docs.python.org/3/library/concurrent.futures.html
- https://developer.nvidia.com/blog/how-krafton-built-pubg-ally-a-co-playable-character-powered-by-nvidia-ace/
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls

## Review

Independent Terra design review approved the scoped approach, with two requirements now reflected in code: only successful results count as activity, and cumulative actual speech suppresses another acknowledgement. Body action bookkeeping remains unchanged. Live latency attribution remains open until measured.

Fresh Terra cold review found no concrete defect. Five focused integration cases passed, followed by 158 tests covering Director, speech, controller loop, scenarios, event hygiene and design notes. The real Agent/Director regression covers both speech channels and failure explanations with an unresolved single worker future. A fresh full gate and live measurement remain pending.

The combined traversal/planner full gate is GREEN: 1061 passed, 1 skipped (379.17 s). Live latency measurement remains pending.

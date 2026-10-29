# Planner input and repair overhead before real movement

## Actual evidence

On published a9f5782 (fresh CHECK_ALL: GREEN, 1276 passed / 1 skipped), the
developer normal return control passed in 8.81s, ending at
[52.69,1888.79,-35.36], health100. This was assisted starting setup.

The subsequent complete Sonnet5.5 Director + Haiku5.5 Controller trial received
only Luis's corrected task: outside the temple, at least200m FROM the spawn
lodestone, then back to the same lodestone on its floor. No route hints.
Task3fccd0b3 chose ordered_steps with outbound and return checkpoints. Both IDs
are present in actual Sonnet and Haiku requests. Both remain pending, zero
attempts, actual position unchanged; there was no movement request. A successful
active board-step delivery of terrain feedback is therefore still unproven.

It spent15Sonnet and5Haiku requests ($0.3322 incremental; day total28calls,
$0.4584 of shared$10 cap) on planning, repairs, preparation and budget notices.
The existing per-world hourly Director allowance was exhausted:20requests,
including5earlier Sonnet calls. This is not provider/account exhaustion or the
daily dollar cap. Brain exited and cleanup stopped input; no orphan brain.
Board status is waiting_budget, not done. Raw inputs/outputs/body results,
assessment.json and spend-after.json are private in oc-trial-83a2. Preserve this
task and its history. No autonomous200m or M1-M6 pass.

Measured prompt/response friction:

- Actual Director system prompt lists explore argument names and a description,
  but not its numeric bound. The planner proposed leg_m100 twice; runtime
  validation correctly rejected it because maximum is80. The correction is
  information that should have been supplied before planning.
- The generic already-true task_success advisory was still issued for an
  ordered job. It caused extra JSON revisions and the model added elapsed45s to
  its final predicate, despite the checkpoints already carrying required progress.
  This final state later became true; the task did not falsely finish.
- After the research phase ended, tools stayed offered and the model made a
  late research call during a required JSON advisory response. The refused call
  consumed repair/request allowance and planning restarted. This is observed
  overhead; do not silently stop counting its real API usage.
- The plan was followed by a separate risk preparation decision before any body
  action. The retained old20/hour policy can exhaust during one compound job.
- The planner explicitly expressed uncertainty about position units and floors.
  Readable geometry conventions and current observations need actual delivery,
  rather than requiring wiki research about our own tool interface.

## Search record

Actual queries after this failed experiment:
`site:platform.claude.com docs tool use input_schema descriptions parameters constraints`,
`site:behaviortree.dev sequence success all children`,
`site:platform.claude.com tool_choice none tools disable tool use response final answer`.
Opened [Anthropic Define tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools)
and [BehaviorTree.CPP Sequence](https://www.behaviortree.dev/docs/3.8/nodes-library/SequenceNode/).
The former documents explicit parameter schemas and auto/none tool choice; the
latter distinguishes overall sequence success from the current final condition.
These are interface/execution precedents, not game APIs or evidence of walking.

## Decision and next bounded experiment

Adapt the existing manifest as the single source of parameter constraints in
Director input; retain runtime validation. Explain ordered completion accurately
without an unnecessary already-true repair round. Investigate final-answer
tool_choice:none through the existing model adapter while preserving tool-result
history and billing; do not remove offered tools blindly (llm_json documents a
historical LiteLLM dummy-tool issue). Review the existing configurable hourly
allowance against one bounded whole-job trial and the unchanged shared$10/day
cap; never erase its persisted spend/window history to hide exhaustion.

The ramp remains the deliverable. Time-box these generic input repairs and then
return to the measured guard/coast failure and native route evidence, using
offline -> developer real controls -> complete Sonnet/Haiku. Do not replace the
task with repeated easy demonstrations, a scripted temple route or another
unchanged failed model run. Any implementation still requires fresh design/cold
review and source URLs beside informed code. No new implementation is selected
by this research note alone. Follow Accepted steer in docs/design/autonomy-plan.md.

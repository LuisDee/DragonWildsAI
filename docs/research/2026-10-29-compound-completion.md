# Compound completion: final state can recur before the task is done

Follow [Accepted steer](../design/autonomy-plan.md) and the original frozen
M1-M6 judges. This is a measured failure and proposed next repair, not a changed
judge or proof that the walking goal passed.

## Actual evidence

Complete Sonnet5.5 Director+Haiku5.5 Controller, sourcefd9fa13, existing
DEVbrain worlddev_director and native navigation worlddev. Operator gave only
the original round-trip objective; no intermediate route coordinates or steps.
Sonnet chose three steps: reach the temple lodestone, walk210m out, return to it.
Its global task_success was near(lodestone,4m), identical to its first step.

Actual body go_to reached[51.69,1889.51,-35.09] from
[82.32,1874.23,-31.27],34.23m horizontally/3.82m down, first-step duration13.7s,
health100. Persisted taskbbeea17b records first step done and both outbound and
return pending with zero attempts. Director `_step_done` evaluates global
task_success after a step and finishes the task on true, without ordered-step
evidence. Haiku reported the whole trip complete. The external assessment is
FAIL. Raw evidence remains private underg-obs-f92e3f08 actual-model/body JSONLs,
full-agent-result-recovered.json and the unchanged historical task record.

The first live commentary misread a truncated tail as no movement; full-trace
inspection corrected this immediately. Do not repeat that claim or infer whole
task completion from the valid return subgoal. No new M1-M6/round-trip pass.

The wrapper also called a nonexistent StateStore.flush after stop/final-read.
Bookkeeping was corrected to flush the Director board store; retained results
were reconstructed without repeating model calls.8calls (5Sonnet,3Haiku),
$0.1262 UTCday. Processes and native state verified no brain, action or follow;
ClaudeDev remains at the lodestone, health100.

## Candidate design and risks

Adapt explicit model-declared completion semantics: state-only versus an ordered
sequence plus a final state predicate. Keep legacy state-only behavior where
appropriate; do not detect task wording or add a temple workflow. The model
still chooses goals, route, decomposition and alternatives.

Do not simply require every pending step for every task. A state-only resource
goal may already be met; loops are auto-requeued before the global check.
Replanning can replace pending steps, so current step order alone is not a
durable milestone contract. Decide how model-authored required milestones and
their verified evidence survive substitutions/restarts, and expose remaining
obligations and rejected completion in both actual model inputs. Frozen
predicates and judge paths remain unchanged. Implementation needs a fresh design
review; this note does not select an unreviewed schema or weaken acceptance.

Regressions: same first/final state with required intermediate progress;
false/unknown final state; already-true state-only goal; loop completion;
failure/replan/restart; no premature completion speech; model-request capture
of remaining obligations. Then developer real controls and unassisted complete
agent, with actual spatial/temporal evidence and original acceptance intact.
Luis clarified the test on 2026-10-29: at least 200m FROM the spawn lodestone,
and outside the temple, then return. It does not require 200m beyond the temple
edge. Distance, being outside, and the final floor need observed evidence.

## Selected bounded repair (fresh review clear)

- **Goal:** a recurring final state cannot complete an ordered job before its
  model-declared intermediate outcomes have been observed.
- **Approach:** optional `completion_mode: ordered_steps` with explicitly required
  checkpoint steps, default legacy `state`. Pin only required checkpoint IDs and
  predicates on the initial plan. Reuse existing Step activation, segments and
  accumulated evidence rather than adding a second predicate evaluator. Methods,
  hints and unrequired preparation steps remain editable. Replans must include
  every unfinished checkpoint exactly once in order with its unchanged predicate;
  reject omissions or changes truthfully before mutating the board. Failed
  checkpoints resume the same Step, removing the old list occurrence first.
  Required checkpoints cannot be loop members in this minimal version; ordinary
  loops and state-only goals retain their existing behavior. This version limits
  ordered contracts to specific jobs; open-ended jobs retain choice-based ending.
  Set contract and
  initial steps atomically, include progress in plan_key, and show remaining
  checkpoints in actual Director and Controller inputs. Global success is still
  required after the checkpoint sequence; false/unknown never completes the job.
- **Precedent:** adapt the Sequence distinction in the primary source below;
  use the existing board/predicate engine, no dependency or scripted route.
- **Generality check:** no place, item, task-word or recipe selection in code;
  Sonnet declares outcome checkpoints and chooses methods.
- **Principles:** real controls and frozen judges unchanged; observed outcomes
  enforce the model's declared contract rather than rewriting its intent.
- **Acceptance:** recurring initial/final state, unknown/false final tests,
  failed retry/replan/restart evidence, rejected omission/reorder, legacy state
  and loops, actual model-input capture and no premature whole-job speech;
  offline then developer real controls then the complete autonomous agent.
- **Review:** fresh Terra `ordered_contract_review` accepted this bounded variant
  before implementation, requiring atomic persistence, no duplicate resumed
  Steps, immutable checkpoint predicates, active/prepare/review validation and
  exclusion of required checkpoints from loop groups.

Cold review found and the candidate repaired initial help losing the completion
mode, lost capability gaps on help, application failure counters being reset too
early, checkpoint reuse by an identically titled preparation step, and open-job
choice bypass. The final bounded recheck was CLEAR. A direct Director execution
regression also covers starting at home, actually moving away, and returning;
it is a simulation, not gameplay evidence.

## Search record

After the failed complete-agent trial, root actually searched
`site:btcpp.dev postcondition sequence fallback goal already true tasks` and
`site:arxiv.org agent evaluation state goal temporal order task completion`.
Opened [AgentEval abstract](https://arxiv.org/abs/2610.21177), submitted
2026-10-15: it distinguishes subgoal outcomes, broader obligations and supporting
evidence. Only the abstract was reviewed; it is conceptual precedent, not a
runtime component or evidence about this companion.

The first BehaviorTree URL returned404 and is not relied on. A bounded Terra
audit and root opened the actual [BehaviorTree.CPP3.8 Sequence documentation](https://www.behaviortree.dev/docs/3.8/nodes-library/SequenceNode/).
Sequence succeeds only after its ordered children succeed; SequenceWithMemory
retains completed siblings during later execution. Adapt that execution-contract
distinction, not the C++ runtime or a hand-written trip sequence. No new package,
model service or judge change is selected. Put these URLs beside informed code
if the reviewed design is implemented.

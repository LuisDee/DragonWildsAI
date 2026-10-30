# a907 movement ownership and recovery audit — 2026-10-30

Read-only bounded audit of f63d809. Accepted steer `docs/design/autonomy-plan.md`, original M1–M6/frozen judges and DEV-only sole operator root apply. No source edits, tests, process/game/model operations were performed. Root's terminal measurement now verifies task45d55b1a done, one unassisted complete Sonnet/Haiku round trip (1/3), maximum200.65mXY, correct-floor return approximately4cm from the preserved start anchor, H100;23 Haiku/17 Sonnet responses. Use `measured-outcome.json`, not model claims, for that result.

## Verdict

There is **no demonstrated leaked movement token or broken bridge** in these failures. The mover releases its implicit owner on terminal timeout/failure. An independent consumable-reflex verification then temporarily owns the arbiter, and ordinary tokenless go_to is deliberately rejected. The error text exposes an internal token requirement without identifying that transient owner, which allowed a mistaken reset diagnosis. Separately, a proven Python continuation defect discards the model's run_skill recovery before dispatch.

## Ownership evidence

Files under this directory are JSONL; row numbers below are one-based physical lines. Session log: `C:/gameserver/logs/brain-live-20261030-052411-8628.jsonl`. Additional existing evidence: `C:/gameserver/logs/client/client.log` and `C:/gameserver/client_io/events/vitals.jsonl`.

|Boundary|Observed sequence|
|---|---|
|First outbound timeout|Body result55 at1793334447.684: go_to→timeout, movement deadline reached. Client.log42230–42231 at04:27:27 explicitly fails and releases move:go_to. Native row138 at1793334448.055 is idle/gen2/owner=nil.|
|New transient owner|Vitals1050: successful food reflex use at1793334448;1051 verifies stat rise and releases at1793334452. Native139 at1793334449.312 shows new owner10 while move remains idle/gen2;142 at1793334453.582 is owner=nil.|
|First rejection/recovery|Haiku16 go_to becomes body result60 at1793334451.331: busy/token required, inside that food verification interval. Haiku17 chooses run_skill. Haiku18 later chooses go_to again, after release: native144 starts gen3/token11; body68 at1793334469.579 arrives successfully at the second lodestone.|
|Outbound terrain failure|Body82 at1793334555.773 fails sweep_blocking at[226.05,1790,-34.38]. Client.log42352–42353 at04:29:15 fails and releases move:go_to. Native214 at1793334556.253 is idle/gen4/owner=nil.|
|Second transient owner|Vitals1056: Clean Water reflex use at1793334556;1057 verifies/release at1793334560. Native215 shows new owner13 at1793334557.514,218 is owner=nil at1793334561.865. Return first_call body86 and Haiku20/body91 get busy at1793334557.014/1793334560.182, in this interval.|
|Return recovery|Haiku21 chooses run_skill but it is dropped as described below. Haiku22 go_to starts native221 gen5/token14 at1793334566.140 and physically returns much of the route. Body109 at1793334685.653 eventually times out at[80.00,1859.11,-31.25].|
|Third transient owner|Client.log42501–42502 releases move at04:31:25. Native306 at1793334687.353 is idle/gen5/owner=nil,307 later shows new owner15,310 owner=nil at1793334693.263. Vitals1062/1063 shows another food use at1793334687 and verification at1793334691. Body112 at1793334687.944 again gets busy while that transaction is active.|
|No reset required|After that owner clears, native328 starts gen6/token16 for Haiku30's ordinary go_to. Body125 at1793334757.492 succeeds at[51.80,1889.43,-35.12]. No operator intervention/reset occurred.|

The observer records raw owner tokens but not owner names; mapping tokens10/13/15 to the exact food/drink records is a source-and-timing inference. The independently recorded reflex use/verify events, new token intervals and synchronous source path establish transient consumable ownership, rather than retention of the old move owner. Do not describe an owner name as directly sampled when the observer only captured its token.

## Source boundary: intentional protection, incomplete reason

`move.lua:1273–1278` clears the mover's implicit token and calls arbiter.release_implicit; finish at1429–1435 stores its terminal result, makes mode idle and releases. `arbiter.lua:323–337` releases the matching owner and resumes any suspended owner; implicit cleanup also exists at209–231.

`inventory.lua:1051–1079` independently obtains a `fed:<kind>` arbiter owner, uses the real hotbar path and retains the token in R.pending until verification. It deliberately marks uses_move=false but still owns that single arbiter slot. `inventory.lua:1108–1116` verifies the stat then calls reflex_release; release at1035–1039 releases that exact token. The four-second verify interval is the observed duration here, not a proposed sleep/retry constant.

`client_bridge.lua:564` invokes ordinary move.go_to with tolerance and no parent token. `move.lua:3637–3647` accepts an explicit valid movement owner, or the exact existing implicit movement owner, but rejects another owner with busy/token-required. This is a deliberate no-bypass guard. It runs before input and does not mean the brain should fetch/pass someone else's token. A learned Python skill expands the same bridge primitives; it is not a new arbiter parent that forgot to forward a Lua token.

Do not remove the guard, clear the arbiter, steal a consumable token, preempt verification arbitrarily or restart the client based on these results. The smallest body-side follow-up, if reviewed later, is observational: return the already-known owner name/level/since/transaction state with a truthful transient-busy explanation. Preserve the current refusal and resource lifecycle; no speculative automatic waiting or retry policy is required by this audit.

## Proven lost recovery decision

Haiku outputs17 and21 both contain run_skill(walk_to_location, params); they are valid choices of an already-present learned skill. The retained skill record contains stop then coordinate go_to and no preconditions. `Controller._collect` routes run_skill separately and `_collect_skill` (`controller.py:1006–1012`) sets d.skill, not d.actions.

After each failed go_to, `Agent._command_run` logs `chain_turn` at session232/333 with actions=[]/speech=None. At `brain/agent.py:721` it treats `not(d.actions or d.speech or d.refusals)` as “nothing to do,” reports the previous token error (session233/334), and breaks. The check omits d.skill and d.goal. Thus the next loop never calls `_run_turn` (`:590`) for that response; `_run_turn`'s d.skill→_queue_skill path (`:815–821`) is never reached. There are no corresponding skill_queued, stop or go_to body requests for17/21, and board_run240/340 records only the prior failed go_to attempts. These run_skill choices did not themselves fail ownership: they were never dispatched.

Smallest proposed Python condition, pending explicit implementation authorization:

`if t['failure'] and not (d.actions or d.goal or d.skill or d.speech or d.refusals):`

This aligns the existing surrounding decision predicates, preserves a silent-response failure report, and allows the model's chosen recovery through the existing queue/validation/executor path. It adds no phrase/route policy and does not guarantee the learned skill succeeds.

Proposed focused regression: actual Agent+Controller+Executor with a mock first go_to busy failure, then a scripted run_skill-only recovery; verify the selected skill is queued/expanded/executed once, with no stale fallback replacing it. Cover a goal-only response at the same boundary, a genuinely empty response still reporting the old failure, and existing turn-budget/player-interrupt behavior. Relevant existing coverage: `tests/test_skills_worlds.py:test_run_skill_next_time_needs_no_planner`, `:test_run_skill_checks_params_and_preconditions`; `tests/test_event_hygiene.py:test_chain_is_bounded_and_yields_to_a_new_chat_line`; `tests/test_controller_loop.py:test_failed_pickup_result_goes_back_to_the_model`; `tests/test_director.py:test_failed_board_result_is_explained_without_claiming_success`. These tests were only read, not run here.

## Call38 false40m chat: bounded snapshot finding

Sonnet inputs35/37 include cp_out=done and cp_far=done, cp_back=pending with the body already near the lodestone. Output37 explicitly acknowledges those earlier checkpoints. Haiku38 receives a task_report notice after completion, but facts contain only job text, the final1.4m near-result and collected=None; completed outbound checkpoint evidence is omitted. `Director._finish_task` at1809–1813 constructs exactly that sparse notice and removes the finished task from the live board. The Controller board context has only two unrelated parked tasks, not a false cp_far status.

Haiku38's “only40m out” statement is therefore a model claim inconsistent with measured completion, not a hidden failed outbound predicate or a board field saying40m. Its digest retains a prior return timeout43m short and busy failures; an old state:body_link note also claims restarting. Those are plausible confusing historical inputs, not proof of its internal reasoning. A report lacking checkpoint evidence is a verified projection limit; correcting completion narration should later carry verified completed outcomes, not hard-code a success line. No broader snapshot/perception repair was selected here.

## Search record: reuse > adapt > build

Actually searched before selecting follow-up proposals:

- `site.docs.python.org threading Lock acquire blocking False release RuntimeError ownership`
- `site.docs.unity3d.com behavior observer abort higher priority lower priority actions`

Opened primary sources:

- https://docs.python.org/3.12/library/threading.html#lock-objects — conceptual precedent: nonblocking acquisition may report contention; release/acquire state must remain paired. This Lua arbiter is not a Python lock and Python's primitive Lock ownership semantics are not imported here.
- https://docs.unity3d.com/Packages/com.unity.behavior@1.0/manual/observer-abort-mechanics.html — priority interruption/continuation precedent already cited by arbiter; not a game API or proof of this trace.
- https://discussions.unity.com/t/behavior-package-1-0-15-released/1707046 — first-party clarification separating priority interruption from conditional execution. Context only; no Unity implementation is embedded.

Decision: reuse current owned cleanup, consumable verification and model-selected recovery machinery. Adapt the single missing d.skill/d.goal continuation condition after review; optionally improve existing busy metadata separately. Build no new ownership scheduler, token propagation workaround, retry loop or task script. Root alone owns subsequent live operations and acceptance counting.

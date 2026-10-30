# Exhausted research requests use tool_choice=none

2026-10-30. **Root-reviewed request-scoped compatibility design and implementation.** The earlier wrapper expansion touched frozen `evals/bench/agents.py`; that worker hunk has been manually removed and the file matches HEAD. Accepted steer: [autonomy-plan.md](autonomy-plan.md), PRINCIPLES, original M1–M6 and frozen judges unchanged. Full Sonnet Director + Haiku Controller acceptance remains0/3. No strict-schema migration, pre-limit prompt work or physical-navigation changes belong here.

## Goal and demonstrated defect

Private a891 audit: `C:/gameserver/logs/recovery/terrain-full-a891/planner-tool-contract-review.md`. Sonnet inspect9 and stop28 occurred after the research-over notice because the request still offered tools with auto. Existing refusal prevented execution but required another response. Pre-limit unsupported go_to2/8 remains open. Retain the actual definitions/history after exhaustion, but explicitly request none. Do not increase rounds, retries or progress budgets.

## Interface and wrapper inventory

Seven concrete repository clients were inspected: LiteLLMClient, FakeLLM, two dry-run leaves, and three synchronous forwarding wrappers (`brain/mock/sim_session.Latency`, `evals/bench/agents.CountingLLM`, `tools/director_cassettes.Capped`). Five additional test clients/hooks have narrow signatures; two other hooks emulate the provider rather than an LLMClient. Current private a891 Counted also has a narrow complete signature. No forwarding wrapper currently offloads the call to a separate worker.

Frozen CountingLLM cannot gain a keyword. Reuse its exact synchronous forwarding call and add one small request-scoped ContextVar in `brain/llm.py`, entered by a context manager only around json_decision's existing on_request+complete boundary. Set none after the existing tool-round limit; use an unset/None scope before that limit so ordinary research stays unchanged. Admission runs before scope entry. Restore the token in finally, including logging/provider exceptions. on_response/validation remain after restoration. No shared client kwargs mutation, unwrapping, cloning or generic request-options framework.

Priority: explicit non-None tool_choice on the real client/serializer, then scoped choice, then existing defaults. Preserve the optional explicit interface in llm.py so root's private a907 adapter remains compatible. JSON decision passes no new keyword through fixed-signature wrappers/callbacks. request_log_fields resolves the same effective choice inside scope, including the custom-wrapper llm.complete boundary; LiteLLM request_payload and private runner inner traces resolve it identically. These are effective scoped settings, not captured HTTP serialization.

All inventoried forwarding wrappers call inner.complete synchronously in the same thread. Scope entry occurs inside Director worker's json_decision, after the worker already exists; no cross-thread inheritance is assumed. A future wrapper offloading serialization would require explicit copy_context().run, as PEP567 describes, plus a compatibility test. Separate concurrent threads have separate scopes.

Final intended changed files: `brain/llm.py`, `brain/llm_json.py`, new `tests/test_exhausted_research_choice.py`, this note. Manually remove only this worker's obsolete Director, dry-run, Latency, Capped and existing model-interface test-hook changes. Frozen judge files stay unchanged. Root owns private runner/preflight changes.

## Request and safety contract

Count research rounds, not arbitrary response counts. First research requests preserve auto and the same tools. The exhausted request and any existing JSON repair retain tools/history and use none. No-research clients/callers retain their current arguments/defaults. Keep the correlated refusal fallback if a scripted/violating provider nevertheless returns tools after exhaustion; do not execute them. Admission remains before every request; response count/usage logging remains once before validation. A denied request makes no provider call. Never claim strict mode is enabled.

Generality: this is the existing research admission boundary for any task/tool, not a route, phrase or outcome policy. It preserves model choice within permitted research and asks for the already-required JSON decision afterward. No principle exception or parent-goal award is involved.

## Verification and limits

Focused offline tests drive real json_decision through unchanged frozen CountingLLM into real LiteLLM adapter input and a fake provider: two batched research rounds, none at the limit, exact definitions/history/logs, JSON repairs, provider-violation refusal, response accounting and denied admission. Exercise other unchanged forwarding wrappers through the scope; prove caps/effort/settings intact, reset after provider/log-callback exceptions and nested scopes, and two genuinely concurrent threads with distinct auto/none requests. No scope survives denied admission. Root runs cold review/full gate and private Counted preflight. No game/API/live or autonomous pass is claimed.

## Implementation verification

The previous explicit-wrapper candidate is superseded because frozen judges must remain unchanged. The approved revised implementation passed **146 focused tests in21.02s**, including actual json_decision through unchanged CountingLLM, all other existing forwarding wrappers, generic-boundary scoped logging, exception/nesting/concurrency isolation, admission/counting/refusal, existing Director/run-live/model/terrain/accounting suites and design-note checks. Runtime Python used unique basetemp `C:/gameserver/logs/recovery/exhausted-choice-a908-sol-context-2`. These are fake-provider offline diagnostics, not autonomous acceptance. Pre-limit unsupported research names and strict-schema migration remain outside scope. No game/model API, runtime source, ledger, full gate, commit or publication changes were performed by this worker.

## Search record

Reused actual fresh research from the same a891 problem. Queries: `site.platform.claude.com docs strict tool use JSON schema limitations tool names additionalProperties`; `site.docs.litellm.ai anthropic strict tool use strict true supported`. Inspected installed LiteLLM1.106.4 mapping plus all repository complete methods and the current private Counted. A read-only method probe verified none maps to native type=none; no provider call occurred.

For this revised compatibility problem, actually searched `site.peps.python.org pep 567 context variables ThreadPoolExecutor copy_context run` and `site.docs.python.org 3.12 contextvars reset token finally thread context`, then opened Python3.12 docs and PEP567.

- https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools#controlling-claudes-output — none prevents tool use; keep auto before exhaustion. This is provider behavior, not a navigation policy.
- https://docs.litellm.ai/docs/completion/input — explicit tool_choice is a per-request SDK input. Reuse its existing mapping, preserve default callers.
- https://github.com/BerriAI/litellm/blob/v1.106.4/litellm/llms/anthropic/chat/transformation.py — installed-version precedent: none maps directly; omitting definitions with historical tool blocks injects a dummy tool. Keep definitions rather than removing them.
- https://platform.claude.com/docs/en/build-with-claude/structured-outputs#json-schema-limitations — existing schemas exceed strict subset, so strict conversion is deferred. No constraints are silently weakened.
- https://docs.python.org/3.12/library/contextvars.html — context-local request state and token reset in finally. Use Python3.12 set/reset, not the token context-manager feature added later.
- https://peps.python.org/pep-0567/#offloading-execution-to-other-threads — offloaded work needs copy_context().run; present synchronous forwarding wrappers require no signature changes. Do not assume arbitrary pool propagation.

Decision: reuse existing round counter, definitions/history, validators, frozen wrappers, quotas, logs and SDK mapping; adapt a single scoped serialization setting because explicit forwarding cannot cross the frozen interface. Build no broader framework.

# Speech-channel continuation recovery

- **Goal:** keep the explicit chat channel valid through the existing talk-only continuation, so the model can attach an action to its own line instead of a provider rejecting the conversation.
- **Approach:** reuse `Controller._answer_says` immediately before the say-only follow-up enters `_talk_only_check`. The line is still held, so its existing held-result description remains truthful. No new speech logic or provider adapter is needed.
- **Generality:** every say call receives its own result; this depends on response shape, not words, items or benchmark tasks. Legacy text-channel behavior remains the same.
- **Principles:** one voice, truthful results, real tool protocol; no judge changes. Fresh-context reviewer `recovery_review` approved this repair and asked for action/empty/error-path coverage.
- **Acceptance:** a strict fake provider rejects any pending tool ID at the next request boundary; the say-only follow-up must pass that validation, choose its next action, and retain valid history through a subsequent continuation. Empty and failed check calls must preserve the held line without an unmatched tool call.

## Search record

- **Need:** an assistant tool call in history must be answered before the next model request.
- **Searched:** existing `Controller._answer_says` and read-loop handling; Anthropic's tool-result ordering and missing-result troubleshooting; the Python SDK message examples.
- **Found:** the provider requires a matching result for each tool-use block. This code already has the required held-result helper; the talk-only branch omitted it.
- **Decision:** reuse the existing helper at the missing branch, with strict protocol tests rather than another tool runner.
- **Sources:**
  - https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls
  - https://platform.claude.com/docs/en/agents-and-tools/tool-use/troubleshooting-tool-use
  - https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/resources/messages/messages.py

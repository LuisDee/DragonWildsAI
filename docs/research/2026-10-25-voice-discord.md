# Voice chat with the companion via Discord (research, 2026-10-25)

Luis asked how hard it would be to have the companion talk in a Discord voice channel as an extra user, and how people build live conversational AI.

**Verdict:** feasible and largely solved by existing open source; about a day to assemble once the body works. It is not on the critical path, so do it after the humanoid body (task P4.H).

## Two patterns for live voice AI
1. **Speech-to-speech models.** Audio is streamed in and audio comes back. About 0.3–1 s to first audio, and all of them support tool/function calling.
   - OpenAI Realtime API (gpt-realtime-2.x)
   - xAI Grok Voice Agent API (Grok Voice 3.0, 2026-10-14)
   - Google Gemini Live
2. **A cascade:** speech-to-text, then any LLM, then text-to-speech. About 0.3–0.8 s slower. It allows any LLM (Claude, GPT, Grok) and keeps our Controller as is.
   - Standard OSS framework: **Pipecat** (BSD-2, also supports the realtime models). LiveKit Agents is the alternative.

## Costs (third-party figures; verify on provider pricing pages before budgeting)
- Grok Voice: about **$0.08 per audio minute** (about $4.80/h), plus some extras such as tool calls. [evalgent](https://www.evalgent.com/blog/xai-grok-voice-agent), [kie.ai](https://kie.ai/blog/grok-voice-3-0-pricing)
- OpenAI gpt-realtime-2.1 is priced per token: audio $32 per 1M input, $64 per 1M output, which works out to about $0.06–0.11/min. The mini model: $10/$20 per 1M, about $0.02–0.05/min. [OpenAI pricing](https://developers.openai.com/api/docs/pricing?web=1), [forasoft analysis](https://www.forasoft.com/article/openai-realtime-api-pricing)
- Billing is by audio actually sent, so use voice-activity detection to send audio only while someone speaks.

## Discord bot as an extra voice user
- Existing OSS bots:
  - [VoiceCordAI](https://github.com/Monoese/VoiceCordAI): OpenAI Realtime or Gemini Live in a Discord voice channel. The closest base.
  - [discord-voice-ai](https://github.com/m0nk111/discord-voice-ai): STT, LLM (GPT or Claude), TTS.
  - [speech-to-speech-discord-bot](https://github.com/dazchi/speech-to-speech-discord-bot)
  - Framework: [Pipecat](https://github.com/pipecat-ai/pipecat)
- **Catch:** Discord made DAVE end-to-end encryption mandatory for voice ([Discord blog](https://discord.com/blog/every-voice-and-video-call-on-discord-is-now-end-to-end-encrypted)). A bot must support DAVE to receive audio.
  - `@discordjs/voice` documents DAVE ([docs](https://tessl.io/registry/tessl/npm-discordjs--voice/files/docs/dave-encryption.md)).
  - Python (py-cord and similar) receive support under DAVE is unverified.
  - Likely choice: a Node.js Discord component.

## How it fits the architecture
- The Discord bot is another input channel into the brain, alongside the in-game chat hook (`command_received`).
- **Single-voice rule (CLAUDE.md principle 6):** the companion must not say one thing while doing another. Two ways to keep it:
  - (a) The realtime voice model *is* the Controller and acts only through our game tools.
  - (b) The Controller decides, then speaks through TTS.
- Decision for Luis later: the provider (OpenAI, xAI or Google), as a cost-versus-quality trade-off.

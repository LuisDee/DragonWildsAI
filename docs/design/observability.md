# Observability: episode traces, metrics, anomaly detectors, spend

Status: **built offline** (2026-10-25, observability agent). Files: `tools/obs.py`, `tools/spend.py`, `data/model_prices.json`, `tools/lnav/dw_anomalies.json`, `tests/test_obs.py`, `tests/fixtures/obs_2026-10-25_2054/`, `tests/fixtures/obs_metrics_sample.json`.
It is read-only over the existing logs. Nothing in `brain/` or `client_mod/` changed. Main commits.

## Goal (what main and Luis get)
Claude's client runs `-nullrhi`, so the logs are our only eyes. Until now, "read the chat" meant writing new ad-hoc Python over five log formats every time.
- **One command per question:**
  - `obs episode` gives one compact trace per player request, body decision or goal: what Luis said, what the model decided and why, what the body did, how long each step took, and what Claude said.
  - `obs metrics` gives latency percentiles, failure rates and counts.
  - `obs anomalies` lists the failure modes Luis has complained about, found automatically.
  - `obs spend` shows dollars against the $10/day cap.
- **Standard traces when wanted:** `obs otel` writes the same episodes as OTLP/JSON spans with GenAI and OpenInference attributes. Any OTel backend (Phoenix, Langfuse, Jaeger) can show them later, with no lock-in.

## Commands
```
.venv\Scripts\python.exe -m tools.obs episode --last 5                     # default window: the last 6 h
.venv\Scripts\python.exe -m tools.obs episode --since 20:54 --until 21:18 [--kind chat,body,goal] [-v]
.venv\Scripts\python.exe -m tools.obs metrics --since 20:54 --until 21:18 [--json]   # --json: dw_obs_metrics/1 for tools/goal_check.py
.venv\Scripts\python.exe -m tools.obs anomalies --since 20:54 --until 21:18           # also appends new ones to logs/anomalies.jsonl
.venv\Scripts\python.exe -m tools.obs anomalies --follow [--interval 5 --window 900]  # live tail; re-scans, prints each new anomaly once
.venv\Scripts\python.exe -m tools.obs spend [--today | --day 2026-10-25] [--json]     # dw_obs_spend/1
.venv\Scripts\python.exe -m tools.obs otel --since 20:54 --out logs\traces.otlp.json [--push http://127.0.0.1:6006/v1/traces]
```
- **Benchmark and eval sessions:** `--brain-log <path|glob>[,...]` (repeatable) on every subcommand reads those brain JSONL files instead of the live scan, e.g. `obs episode --brain-log logs/evals/<date>/<run>/work/<case>/brain.jsonl -v`. Chat then comes from that log's own `chat_heard` events; the live chat, body, vitals and watchdog files are not read. The default scan is only `logs/brain-live-*.jsonl` at the top of `logs/`, so nothing under `logs/evals/` ever counts toward live latency, exposure or anomaly targets. Spend still counts those files, because the cap is global.
- Times are UTC, like `tools/timeline.py` (`--local` switches to local time, `--date` sets the day for bare HH:MM).
- Python API:
  - `from tools.obs import spend_today, spent_today_usd` (used by the brain's budget guard and the eval runners).
  - `tools.obs.analyse(root, since, until)` returns `(corpus, episodes, anomalies)`.
- lnav: `lnav -i tools\lnav\dw_anomalies.json` once, then `lnav logs\anomalies.jsonl`. **[UNVERIFIED]**: lnav isn't on this VM's PATH right now, so the format file has not been loaded yet.

## How an episode is rebuilt (no IDs in the logs, so it's reconstructed)
- **Decision start.** A controller `prompt` whose last message is the context JSON with a `command` key opens a decision. A non-empty `command.text` makes it a **chat** episode; an empty one makes it a **body** episode (the context's `body_event`). The second decide after `speech_redecided` stays in the same episode.
- **Trigger lines.** `chat_heard` events are held as pending lines with the said time (game clock, `event.ts`) and the heard time (log ts). The decide prompt's `command.text` (the burst, joined by " / ") claims the matching pending lines. Lines that are rate-capped with no model call become **ignored** episodes; a ping becomes a **ping** episode. Lines that are never decided appear as "never decided".
- **Body triggers.** `situation_review` and `event_triage` logged just before a body decision move into that episode.
- **Steps.**
  - Every model call is paired with its prompt: latency = response ts − prompt ts, plus tokens from `usage`.
  - Read-only tool calls are `read`.
  - Executor tool calls are `do`. Retries are joined by `task_id`. The bridge message id comes from the next `bridge_send` of the same tool.
  - The body's own `client_action_start/end` in `logs/client/mod_*.jsonl` carry **the same id as the bridge message**, so each action also shows when the body really started and ended (1 s resolution).
  - Speech, chain turns, bridge timeouts and restarts, and body events attach to the episode that owns the last record.
- **Goals.** `logs/state/worlds/*/progress.jsonl` "goal started … goal done/stuck/interrupted" bound a goal episode; a planner prompt also opens one. Inside a goal window, an executor call that the current chat episode's model did not plan belongs to the goal. This works because each llm_response's tool calls are consumed one by one.
- **Episode id:** `HHMMSSk`, the UTC start plus the kind's first letter (e.g. `211320c`).

## Metrics (`obs metrics`)
- **Latency:**
  - chat → first response (speech or body action), the L6 definition of `tools/turn_latency.py`;
  - chat → first body action;
  - chat → heard by the brain (blocked loops show here);
  - model latency per component/model;
  - bridge round trip per read tool.
- **Tools:** per tool, n, failed, fail rate, reasons and p50/p90 duration; failures by reason; retries (attempt > 1).
- **Model:** prompt tokens and cache share; state reads per action.
- **Speech:** talk-only replies; promises without action.
- **`--json`** gives the contract for the eval agent's `tools/goal_check.py`: `schema dw_obs_metrics/1`, window, source live|dev|mixed, hours_observed, latency, exposure, companion, anomalies_per_hour, stability, deaths, voice (always null here) and `detail`. A sample is in `tests/fixtures/obs_metrics_sample.json`. A null or n=0 value means no data.
- **First action** (`chat_to_first_action_s`) is the first body action that changes something. `stop`, `say`, `remember` and `forget_skill` don't count.
- **`chat_to_first_action_of_passing_plan_s`:** a plan is the action set of one model call. It passes when every task in it succeeded (by its last attempt). The figure is the time to the first action of the first passing plan; episodes with no passing plan are left out (n says how many).
- **Exposure** (so an idle client can't score "0 anomalies/h"):
  - `active_hours` is the observed time in UTC clock hours that hold both ≥ 1 world-changing action and ≥ 1 real player chat line;
  - plus `tool_calls_per_hour`, `world_changing_tool_calls`, `player_chat_lines` and `sessions`.
- **Companion sha** per brain session: taken from `session_start` (`companion_sha`/`git_sha`/`sha` + `dirty`) when the brain logs it. Otherwise it is **inferred** as the last commit before the session started (`sha_source: git_log_before_start`, `dirty: null`). The brain doesn't log it yet, and live sessions run uncommitted working trees, so the inferred sha is approximate.
  - `--companion-sha <prefix>[,<prefix>...]` (every subcommand) keeps only sessions at any of those commits, plus the chat, body, vitals and watchdog rows inside them.
- **Deaths:** classified from `client_io/events/vitals.jsonl`.
  - A death row with sustenance at 0 is starvation; hydration at 0 is dehydration.
  - Otherwise, a game `fatal` row within 5 s with a non-self killer is combat.
  - Anything else is other.

## Anomaly detectors (`logs/anomalies.jsonl`, deduplicated by `key`)
| kind | Rule (data only) | Seen live (BUGS.md) |
|---|---|---|
| stall | A player line waited > 15 s (`--stall`) for the first speech or action. The text names what the brain was blocked on: the other episode's body task with all its attempts, or the open bridge command or model call. A chat.jsonl line the brain never logged as heard after 20 s is flagged too, including "no brain session running". In follow mode a line still waiting counts. | L2 (103 s behind `go_to ×3`) |
| promise_without_action | A spoken sentence with first-person future intent ("I'll", "heading to", "on my way", "let me"). It is not an offer or question ("if you", "want me to", "?") and not a non-deed ("I'll wait/stop/stay"). No body action started after it in the episode, and the model call that produced it asked for no action that ran. | L5 (21:02:56, 21:15:01) |
| repeated_failure | ≥ 3 failures of the same (tool, reason) with gaps ≤ 180 s, across episodes. | L1 (cast verification_failed ×9), L15 (timeout ×6) |
| raw_code_spoken | Speech contains a reason code. The vocabulary is `brain.interface.Reason` plus every reason/why seen in the logs: as a snake_case token, in spaced form at the start of the line, or after "I couldn't X:". Engine ids (`BP_`, `ITEM_`, `fol:`, `table: 0x…`) count too. | L4 |
| stat_narration | Unprompted numbers (`N%`, `N m from/away`, `HP N`) in a body-initiated line, or in a reply to a line without "?". | "I'm standing still 14 m from you…", "food is at 15%" |
| contradictory_speech | Any of four rules: (a) claimed success while every action so far failed; (b) "Done" while actions the model itself planned never ran; (c) said a spell failed, then the body reported `cast_late_success` within 90 s; (d) said "won't/stop/no more X", then ran tool X within 5 min (info level if the player asked again in between). | L3 "Done." ×2, L13 |
| tool_timeout | An executor result with reason timeout, grouped per task (all attempts). | go_to 46/125 s, Splinter 22 s ×3 |
| bridge_restart_in_flight | The brain's own `bridge_restart_detected` / `bridge_command_lost`, or a mod-log `client_bridge_started/stopped` while a brain command was unanswered. Sends are resolved by a reply, a `bridge_timeout` or the end of their brain session, and are only counted when < 200 s old. | L2(b) 20:59:39, go_to lost |
| spend_warn / spend_cap | Cumulative daily spend crossed 80 % / 100 % of the cap, stamped at the call that crossed it. `spend_unknown` means the price table or logs were unreadable. | - |

These detectors **only report**. Nothing feeds back into the brain, so there is no veto and no phrase→tool mapping (PRINCIPLES #2). The regexes grade Claude's own output after the fact, like the voice eval's patterns. The brain never sees them.

## Spend (`obs spend`, `tools/spend.py`)
- **Price table:** `data/model_prices.json`, shared with the eval agent's preflight. It was filled from the official pricing page on 2026-10-25 (USD per million tokens):

  | model | input | 5m cache write | cache read | output |
  |---|---|---|---|---|
  | `claude-haiku-5-5` (prompt ≤ 100K) | 0.10 | 0.125 | 0.01 | 0.50 |
  | `claude-haiku-5-5` (prompt > 100K) | 0.50 | 0.625 | 0.05 | 2.50 |
  | `claude-sonnet-5-5` | 2.00 | 2.50 | 0.10 | 10.00 |

  The skill's cached model table said Sonnet 5.5 cache reads cost $0.20. The live page says $0.10 (0.05× input, footnote 2), and the live page wins.
- **Usage semantics:** `brain/llm.py` stores LiteLLM's `prompt_tokens`. LiteLLM's Anthropic transform adds `cache_creation_input_tokens + cache_read_input_tokens` into it (checked in `.venv/Lib/site-packages/litellm/llms/anthropic/chat/transformation.py`). So uncached = prompt − cached − cache_write. Writes are priced at the 5-minute TTL, because the brain uses ephemeral breakpoints.
- **Sources:**
  - every `logs/brain-*.jsonl`, by component: controller → live_controller; planner/director → director_planner; skill_learner → generators;
  - `logs/evals-*.jsonl`, `logs/voice-eval-*.jsonl` and `logs/evals/**` → evals (`gen_*` → generators);
  - a ledger `logs/spend/<source>*.jsonl` for anything else.
  - Dry-run sessions cost nothing.
- **Unpriced rows:** a usage row with no known model is priced at the **dearest** rate and counted in `unpriced_calls`, so the cap is never under-counted. Today's voice-eval logs have 108 such rows and only log the last call of each case. That's a fix for the voice eval's owner, and the eval agent has passed it to main.
- **Day = UTC.** Cap: `DW_SPEND_CAP_USD`, then `DW_DAILY_CAP_USD`, default 10.
- **Cost of a call:** `spent_today_usd()` reads incrementally (a byte offset per file; only complete new lines are parsed; prompt lines are regex-skipped). The first call takes ~0.2 s and later calls ~7 ms, so the brain's guard can call it every 30 s. It never raises (0.0 on error).
- **Agreed contracts:**
  - the brain's guard (event-hygiene agent) uses `spent_today_usd()` (float) or `spend_today()` (dict);
  - the eval preflight fails closed if the command fails, if state=cap, or if spent + worst case > cap.

## Precedent and decision (reuse > adapt > build)
- **Reused:**
  - the OpenTelemetry GenAI semantic conventions (`invoke_agent` / `chat` / `execute_tool` spans, `gen_ai.usage.*`, `error.type`) and OpenInference attributes (`openinference.span.kind`, `llm.token_count.*`), as the span schema of `obs otel`;
  - OTLP/JSON as the file format (the Collector's `otlpjsonfile` receiver reads it);
  - `tools/timeline.py` (time parsing, JSONL reading, redaction);
  - lnav (formats) for interactive browsing;
  - the logs as they are: no new instrumentation in the brain.
- **Adapted:** an offline converter from our JSONL to OTLP spans, instead of instrumenting the live brain with OpenLLMetry or Phoenix auto-instrumentation. The brain is owned by other agents, and its logs already have everything.
- **Not adopted:**
  - **Langfuse self-hosted:** v3 needs ClickHouse + Postgres + Redis + blob storage; the official minimums add up to ~20 GiB RAM.
  - **Arize Phoenix:** 1 GB minimum, 2–4 GB recommended, and memory-hungry on large span queries.
  - The VM has 8 GB with ~0.7 GB free while the client runs (watchdog `memory_low` at 21:02–21:39). Both stay optional, off the VM or with the client stopped.
- **Built** (no library knows our semantics):
  - episode segmentation (the brain logs no trace ids);
  - the domain detectors: promises, raw codes, stat narration, contradictions, in-flight bridge restarts;
  - the spend table and reader.
- **Optional Phoenix:** `phoenix serve` (pip `arize-phoenix`) when there is RAM to spare, then `obs otel --push http://127.0.0.1:6006/v1/traces`. **[UNVERIFIED]**: Phoenix's docs and a Cloudflare guide disagree on whether `/v1/traces` takes OTLP **JSON** or only protobuf. If the push is rejected, run an OTel Collector with an `otlpjsonfile` receiver on `logs/traces.otlp.json` and an `otlphttp` exporter. Not run here (no RAM).

## Generality check
- No item, creature, spell or place names in the code. Reason codes come from `brain.interface.Reason` plus whatever the logs contain. Tool names come from the logs. Speech patterns are generic English intent and number patterns.
- A new tool, reason, spell or world needs no change. A new log kind falls through as a `note` step.

## Principles touched
- None bent. Observability is read-only (PRINCIPLES #9: it owns only its own files) and never steers the model (#2).
- Every live bug in the fixture window is now a regression test (#10).

## Tests (`tests/test_obs.py`, 30 tests, offline)
- **Fixture:** `tests/fixtures/obs_2026-10-25_2054/` is the real 20:50–21:19 UTC session, trimmed: prompts reduced to `command`/`body_event`, big tool payloads dropped. It is stored flat (`logs__client__mod_….jsonl`) because `.gitignore` ignores every `logs/` and `client_io/` directory. `make_fixture.py` rebuilds it and refuses to write if a server password or key-like string would land in it; `test_fixture_has_no_secrets` checks again.
- **Coverage:**
  - segmentation (29 chat + 6 body);
  - one full trace (21:13:20: interact ok, Splinter timeout ×3, body times);
  - burst merging;
  - every detector against the bugs it should catch, plus non-flags ("On my way." when go_to ran, offers, "I'll wait");
  - follow mode;
  - unheard lines;
  - a synthetic goal episode;
  - metrics and the goal_check contract;
  - deaths;
  - OTLP well-formedness;
  - spend tiers, totals, warn/cap and incremental reads.

## Example (real logs, 2026-10-25 20:54–21:18 UTC)
```
#27 [211320c] CHAT 21:13:20  Zezima: "grab these nature runs then splinter that tree"
    78.7 s total, 1 model calls, 4 body actions (3 failed), 15 state reads, decision: addressed (model: meant for me)
    latency: heard +0.5 s, first model reply +5.9 s, first action +6.7 s, first speech +77.1 s
    +   3.0 think   controller claude-haiku-5-5 [0] 2.8 s 13564+496 tok, cached 9099 -> interact({"target":"BP_RuntimeSpawnedWorldItem_C_2147452848"}); cast({"spell":"Splinter"})
    +   6.7 do      interact(...) -> ok 2.9 s  [body 21:13:27-21:13:29]
   !+  10.8 do      cast({"spell":"Splinter"}) -> FAIL timeout 22.2 s "Casting Splinter took too long, so I stopped."
   !+  33.4 do      cast({"spell":"Splinter"}) try 2 -> FAIL timeout 21.7 s ...
   !+  55.6 do      cast({"spell":"Splinter"}) try 3 -> FAIL timeout 21.6 s ...
   !+  77.1 note    chain_stopped {"turns":0,"why":"the player spoke"}
    +  77.1 SAY     "Casting Splinter took too long, so I stopped."
   !! anomaly tool_timeout: cast timed out 3x after 22/22/22 s ("Casting Splinter took too long, so I stopped.")
```
Metrics for the window:
- chat → first response p50 7.4 s, p90 47 s (n=29);
- chat → first body action p50 7.7 s, p90 72.6 s;
- Haiku p50 1.93 s, p90 2.77 s (60 calls, cache share 0.64);
- cast failed 21 of 22 times;
- 13 retries;
- 27 anomalies: 5 stalls, 6 promises without action, 3 raw codes, 3 stat narrations, 3 contradictions, 2 repeated failures, 3 timeouts, 2 bridge-restart-in-flight.

## Search record
- OpenTelemetry GenAI semantic conventions: span names and attributes. https://opentelemetry.io/blog/2026/genai-observability/ ; https://greptime.com/blogs/2026-05-09-opentelemetry-genai-semantic-conventions (conventions still in Development; v1.41 changed invoke_agent span kinds) ; https://openobserve.ai/blog/opentelemetry-genai-semantic-conventions/
- OpenInference span kinds and token attributes: https://arize.com/docs/ax/concepts/tracing/semantic-conventions ; https://www.arize.com/docs/ax/concepts/otel-openinference/span-kinds
- Arize Phoenix sizing: 1 GB minimum, 2–4 GB recommended, memory grows with span queries. https://railway.com/deploy/arize-phoenix ; https://community.arize.com/x/phoenix-support/5b5uwoj3d0mw/recommended-specs-for-self-hosting-ecs-with-postgr
- Phoenix importing saved traces (TraceDataset / launch_app) and its OTLP endpoint: https://arize.com/docs/phoenix/tracing/how-to-tracing/importing-and-exporting-traces/importing-existing-traces ; https://arize.com/docs/phoenix/tracing/concepts-tracing/otel-openinference/exporter ; JSON vs protobuf conflict: https://arize.com/docs/phoenix/integrations/llm-providers/cloudflare-ai-gateway/cloudflare-ai-gateway-tracing
- Langfuse v3 self-hosting requirements (ClickHouse 8 GiB, web + worker 4 GiB each, Postgres 4 GiB, Redis 1.5 GiB): https://langfuse.com/self-hosting/scaling ; https://langfuse.com/docs/deployment/v3/overview
- OTLP JSON files and the Collector file receiver: https://opentelemetry.io/docs/languages/python/exporters/ ; https://packages.nuget.org/packages/Essential.OpenTelemetry.Exporter.OtlpFile/
- lnav JSON formats and SQL: https://docs.lnav.org/en/latest/_sources/formats.rst.txt ; https://lnav.readthedocs.io/en/latest/sqlext.html
- Anthropic list prices (spend): https://platform.claude.com/docs/en/about-claude/pricing (fetched 2026-10-25; Haiku 5.5 long-prompt tier, Sonnet 5.5 cache reads 0.05×).
- Decision: reuse the conventions, file format and viewers; build the segmentation and detectors. A heavy server (Langfuse) does not fit the VM's RAM. Phoenix is optional, off the VM.

## Open / next
- The brain should log `companion_sha` (git rev-parse HEAD) and `dirty` in `session_start`. `obs` reads them as soon as they appear, so the inference above is only a fallback.
- The brain could log one `episode_id` (and `task_id` on `bridge_send`). Segmentation would then be exact instead of reconstructed. Small change, broker agent's file. Ask main.
- Voice-eval usage rows need `model` and every call (voice agent).
- Verify the lnav format once lnav is on PATH. Verify a Phoenix push off-VM.

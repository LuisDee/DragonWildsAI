# Telemetry for live runs: what to log, where to keep it, and the DBOS + Postgres question (2026-11-01)

Luis's ask after the first co-play session (docs/RETRO-2026-11-01-coplay.md): for any test run, be able to see:
1. the time to complete each task, from the moment he gave it, at every step;
2. where Claude idled for 10-20 s, and why;
3. the exact context the model saw when it chose a wrong tool call;
4. pickup attempts in detail (tries, misses, adjustments, moves);

all correlated across brain, client and server. He suggested "DBOS with Postgres to log his turn calls", and asked
us to question that. Constraint added the same day: **open source only, nothing paid**. The live behaviour on the
client is the real eval, so the report must make idle time and fumbling visible from real runs.

Builds on docs/research/2026-10-29-observability-durable-execution.md, which reached the same DBOS verdict.

## Verdict

- **What we need is tracing over an event log, not durable execution.** The questions are causal and temporal:
  which chat line led to which model call, which tool call, which body action, which trips and presses, and where
  the time went. That is a trace, or a set of "wide events" correlated by ids.
- **DBOS** is a durable-workflow library. It checkpoints workflow inputs and step outputs so a crashed process
  resumes from the last completed step. That solves a different problem (crash-resume of long jobs), and it does not
  detect idle time at all: idle is the absence of steps.
- **Postgres** is not needed. One hour of play is a 30 MB brain JSONL plus about 1 MB of client files. DuckDB (MIT,
  in-process, no server) queried today's raw brain log in about 0.5 s (measured below).
- **Recommendation (all OSS, nothing new running during play):**
  - Keep JSONL files as the system of record. The Lua mod can only write files anyway.
  - Stamp a few correlation ids and add three small event streams (below).
  - Query the files with DuckDB when SQL helps.
  - Use `tools/session_report.py` (built today, stdlib only) as the per-run report.
  - Name fields after the OpenTelemetry GenAI conventions, so an offline JSONL-to-OTLP export to Arize Phoenix or
    Langfuse stays possible later. Do it only if the Markdown report stops being enough.

## The prototype: tools/session_report.py on today's session

Usage:
```
.venv\Scripts\python.exe -m tools.session_report logs\brain-live-20261101-115554-7128.jsonl --ue4ss logs\reports\UE4SS-client-20261101-0013local.log
.venv\Scripts\python.exe -m tools.session_report <log> --why <bridge id | task id | Lnnn>
```

- It runs in about 3 s.
- It merges four sources:
  - the brain log;
  - the client's UE4SS.log `[DWClient]` lines (local-time stamps converted to UTC);
  - `logs/client/mod_*.jsonl` action start/end, plus `client_io/events/{trips,gather,vitals}.jsonl`;
  - the dedicated server log.
- It writes three files:
  - `logs/reports/session-<stem>.md`: the summary;
  - `.steps.md`: a step timeline for every request, plus every pickup;
  - `.tables.jsonl`: one row per request, tool call, model call, body action, idle gap and pickup, for DuckDB.
- `--why` rebuilds the **full model request** the controller sent for a given call: system prompt, all 47 tool
  definitions and the whole message chain. Controller prompt rows after a request's first call log only the added
  messages (`messages_from`, brain/llm.py `request_log_fields`), and the tool replays them. So question 3 is already
  answerable from today's logs.

UE4SS.log is overwritten on every client launch. The copy at `logs/reports/UE4SS-client-20261101-0013local.log`
preserves today's evidence. `logs/` is gitignored, so commit-worthy outputs need copying or force-adding.

### Today's numbers (10:55-11:52 UTC)

| question | answer from the report |
|---|---|
| time to complete | 80 requests (non-note chat episodes), 61 with body actions. Median **17.3 s** to done for the 35 whose last action ended ok (max 135 s); median 18.8 s to done-or-failure; p90 70 s. First speech median 4.1 s, first action median 3.6 s. Model: 269 calls, median 1.30 s, p95 2.29 s, 376 s total. |
| idle | **1083 s idle = 53 % of the 2045 s a request was open**, in 77 gaps over 5 s (24 of 10-20 s, 15 over 20 s; median gap 10 s). By cause: movement and pathing 613 s, model/brain 176 s, pickup fumbling 167 s, other skills 128 s. |
| worst gaps | 54 s and 44 s (11:36:48, 11:34:06): `go_to` the player or "the temple" fails `target_not_visible` and is re-issued (retro causes 3 and 10). 42 s (11:18:01): explore at the cliff edge, local planner `unreachable_in_window` x8, just before the 29 m fall. 40 s (11:05:37): interact with a bush from on top of the tent, planner `no_progress_possible`, 20 s standing while planning. 36 s (11:24:12): grave `go_to` stuck. |
| why (exact context) | Every tool call row names the prompt line it came from (`ctx Lnnn`); `--why` prints the rebuilt request. |
| pickups | 56 pickup actions: 31 ok, 7 refused (`not_interactable`, 158 s), 2 path-blocked, 2 unknown target, 14 cut by chat. 78 interact presses for 42 picks. 18 misses: the 7 refusals plus 11 targets given up inside gathers ("detector never targeted it"). 75 re-aim nudges under 3 m. 236 s in refused or blocked attempts, 621 s in pickups overall. |

Side findings:
- The retro's "28 interacts failed with not_interactable" was a raw string count. The string repeats in results,
  task rows and prompts; the real figure is 7 refusals.
- Luis's 14 all-`note:` bursts cost 35 model calls.
- In 11 requests Luis was missing from `get_state.players`, i.e. outside net relevancy. The report shows "not seen":
  direct evidence for retro cause 3.

### How the prototype correlates, and its limits

Chain: `chat_heard.episode_id` -> `prompt`/`llm_response` (same episode, FIFO per component) -> `tool_call` -> the
next `bridge_send` of the same tool.
- That send's `msg.id` is the **body action id** used by `mod_*.jsonl`, `trips.jsonl` (go_to only),
  `gather.jsonl task_id` and the late `bridge_unmatched`/`event_dropped` results.
- Later same-tool sends before the call's result are counted as extra **legs**. Example: the bridge client resolves
  "the lodestone by Wise Old Man" to coordinates and re-sends `go_to` under a new id.
- UE4SS lines are attributed by time window, since the arbiter runs one body skill at a time.

All 200 tool calls today linked to a body or read reply. The limits:
- **Order and window inference.** Reflexes (stay-fed `consume`, `combat:reflex`) can run inside another action's
  window and be mis-attributed.
- **Whole-second stamps.** The mod, trips, gather, vitals and chat files stamp whole seconds. Only UE4SS.log and the
  brain log have ms resolution.
- **What counts as productive.** It means one of three things:
  - a move sample with `spd` of at least 1 m/s;
  - a trip of at least 2 m at 0.8 m/s or more;
  - a world change: item picked or gained, eaten, crafted, built, a combat hit or phase line.

  Standing still while fumbling and standing still idle look the same outside moves.
- **Request is not the same as task.** A request is one chat episode. A task Luis gave once and then steered across
  ten lines (the stone club took about 12 min) is reported as ten requests.
- **"Done" means the last body action returned ok.** It is not semantic success. The crate was done; the berry
  saga was "done" only after 135 s.

## DBOS + Postgres, honestly

What DBOS is:
- DBOS Transact (MIT) is "a library for durable workflows built on top of Postgres", with no separate server.
- It records workflow inputs at start, each step's output when the step completes, and the final outcome.
- Recovery re-runs a workflow from its inputs and skips steps that already have a checkpoint.
- Workflows must be deterministic, and steps must be safe to retry: an interrupted step runs again.
- Python can use SQLite as the system database; it is the default when no URL is given.
- With `dbos[otel]` and `enable_otlp`, it "automatically constructs OpenTelemetry spans for every workflow and
  step". Dashboards live in the separate Conductor control plane.

What it would give us: a durable record of each workflow and step, and spans, but only around code restructured
into `@workflow`/`@step` functions.

Why it does not fit our problem now:
1. **It records the steps that ran, not the time between them.** Luis's worst pain was idle time: body standing,
   planner computing, the same go_to re-issued after `target_not_visible`. That lives in the body's motion and in
   the gaps between steps, which no workflow checkpoint captures.
2. **The body is outside the transaction.** Game actions are not idempotent. A recovered `consume`, `craft` or
   `drop` step can eat or drop twice (2026-10-29 note, "Recovery semantics"). The 70-90 % of evidence that matters
   is on the client, which writes files from Lua and cannot speak SQL or OTLP.
3. **Cost.** Every model call and body command would become a checkpointed DB write in the brain's hot path. Its
   inputs and outputs are pickled. Postgres would be another service on an 8 GB VM whose wall is commit charge.
4. **Its useful kernel we already have.** "Log every turn call to a queryable store" is the brain's prompt,
   llm_response and tool rows, already exact (`--why`), plus DuckDB over the files.

When to revisit: crash-resume of long autonomous jobs (Rung 3+: "gather 20 logs and build a hut" surviving a brain
restart). Even then it should run at job level with the SQLite backend, with the live arbiter kept and
fresh-state reconciliation before any resumed effect.

## Tool survey (late 2026), against our constraints

Constraints: OSS only; 8 GB VM already running the game server and client, commit-charge wall about 12.5 GB;
Windows, no Docker; the Lua mod writes files only; low ops burden.

| option | what it is | licence | fits? | verdict |
|---|---|---|---|---|
| **OTel GenAI semconv** | Span and attribute names for `invoke_agent`, `chat`, `execute_tool`, `create_agent`; attributes like `gen_ai.operation.name`, `gen_ai.agent.name`, `gen_ai.conversation.id` (only when the app has a real id), `error.type`. Content attributes (`gen_ai.input.messages`, `gen_ai.tool.definitions`) are opt-in. | Apache-2.0 | yes (it is a naming scheme) | **Adopt the names**, not an SDK. Status is still **Development**, and the spec moved to its own repo (`open-telemetry/semantic-conventions-genai`), so pin a version if we ever export. |
| **DuckDB** | In-process SQL over JSONL/Parquet: `read_ndjson`, globbing, `union_by_name`, `ignore_errors`, a `filename` column. | MIT | yes: no server, RAM only while a query runs | **Adopt** as the query layer. Verified today with 2.0.0 on our files. |
| **Arize Phoenix** | Trace UI and collector (OTLP) on SQLite by default (`PHOENIX_WORKING_DIR`), or Postgres; `pip install arize-phoenix`, port 6006. | **Elastic 2.0** (source-available, free self-host, not OSI) | maybe, offline only: RAM not documented and not measured here | **Optional later**, only after a session from converted spans, never during play. Licence caveat for Luis. |
| **Langfuse OSS** | Trace and eval platform; OTLP/HTTP ingest at `/api/public/otel`. | MIT core (`/ee` licensed) | **no**: needs web, worker, Postgres, Redis, ClickHouse and S3/MinIO; official minimums add up to about 21.5 GiB | Reject on this VM. Fine on a separate box later. |
| **Pydantic Logfire** | OTel-based SaaS with SQL (DataFusion); 10M spans/month free. | SDK MIT; platform closed | **no**: SaaS; self-host is Enterprise (Kubernetes, Postgres 16, private images) | Reject (Luis: OSS only). |
| **LangSmith** | LangChain's tracing SaaS. Only third-party pricing pages were found (about 5k traces/month free; self-host Enterprise only). | closed | no | Reject. |
| **W&B Weave** | `weave.init` plus `@weave.op` tracing SaaS; self-managed needs an enterprise licence. | SDK OSS; server closed | no | Reject. |
| **Traceloop OpenLLMetry** | OTel auto-instrumentation for LLM SDKs; Traceloop was bought by ServiceNow (2026) and says OpenLLMetry stays OSS. | Apache-2.0 | yes, but redundant | Skip. We already log every request and response ourselves, more completely (rebuildable prompts). |
| **LiteLLM callbacks** | `litellm.callbacks=["otel"]` (console exporter by default; `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental` gives current GenAI names); `CustomLogger.log_success_event(kwargs, response_obj, start_time, end_time)`; built-ins for Langfuse, Arize and others. | MIT | yes | **Use only for gaps.** A tiny `CustomLogger` (or reading `response.id` and cost in brain/llm.py) can stamp the provider request id, exact start/end and cost on our own `llm_response` row. No exporter needed. |
| **OTel Python SDK + file exporter** | `opentelemetry.exporter.otlp.json.file` (`FileSpanExporter`) writes spans to a file. | Apache-2.0 | yes | Not now. Our JSONL rows are already the spans; convert offline if a UI is wanted. |
| **DBOS (+ Postgres)** | Durable workflows; SQLite or Postgres; auto OTel spans for workflows and steps. | MIT | SQLite yes, Postgres costs RAM | **Not now** (above). |

### How game and embodied-agent projects log and replay
- **Voyager (MineDojo):** a run is resumable from `ckpt_dir`; "new events will still be recorded to ckpt_dir".
  Evidence is files per run (events, curriculum, skill library). No trace store and no replay viewer found.
- **Mindcraft / MineCollab:** the paper says agents get feedback through execution logs. Neither the repo README nor
  the search found a documented log format or replay tool. Nothing found beyond that.
- **PUBG Ally (KRAFTON + NVIDIA ACE):** public material covers the on-device architecture and "more predictable
  response times" from a local 2B model. Nothing found on their telemetry or evaluation pipeline.
- **Project Sid (Altera):** the paper and repo describe PIANO. Nothing found on their per-agent logging pipeline.
- **General idiom:** production LLM agents use OTel GenAI spans in a trace store. For one developer and one game
  agent, the established low-ops pattern is "wide events": one rich structured row per unit of work, queried at read
  time (Honeycomb, "observability 2.0"). That is what `.tables.jsonl` is, and DuckDB is the read-time engine.

## What telemetry is missing, and where to emit it (minimal cost)

All proposals are for the owners of brain/ and client_mod/ (not edited here). Each is small, file-based and
event-driven, with no new process.

### Correlation envelope (every row, every source)

`ts` in ms, plus the ids known at that point:

| field | meaning | semconv analogue |
|---|---|---|
| `run` | brain session id (the brain-live file stem); the client stamps it from the first bridge cmd | `gen_ai.conversation.id` (session) |
| `ep` | episode id (`chat-0026-db25`): one chat burst or self-started review | trace id of an `invoke_agent` span |
| `llm` | one id per model call, on `prompt` and `llm_response` (today they pair by order only) | `chat {model}` span |
| `call` | the model's `tool_use` id (`toolu_...`) on `tool_call`/`tool_result` | `gen_ai.tool.call.id` (verify in the pinned registry) |
| `act` | body action id = bridge `msg.id`, on every client row written while that action runs | child span `dw.body.action` |
| `leg` | position of `act` among the call's legs (re-sends) | span link |

Emission points:

| # | missing | emit where | cost |
|---|---|---|---|
| 1 | **ids on the bridge command** | brain/protocol.py `cmd()`: add `ep` and `call` (and `run` on the first command) beside `id`. brain/bridge_client.py: log `bridge_ids` on the `tool_call` row as legs are sent. | about 40 bytes per command |
| 2 | **action id on every client line and event** | client_bridge.lua, at `client_action_start`/`end` (L1376/L218): set a module-level `current = {act, ep, kind}` and echo `ep`/`call` in both rows. main.lua `log()`: prefix `[a=<act>]` while an action runs. move.lua already takes `opts.cmd_id` for trips (L3285): pass the parent action id from gather.lua and skills.lua interact moves. Today 148 of 173 trips have `id = null`. | a few bytes per line |
| 3 | **1 Hz body sample** | a new bridge service beside vitals, writing `client_io/events/body.jsonl` once a second, or on change (moved > 0.3 m, owner/action changed). Fields: `ts_ms, act, owner` (arbiter), `pos, yaw, speed, on_ground, in_water, move_src, d_goal_m`, `prompt_target` (the interact detector's actor, item and prompt), `hp, endurance`. Today position comes only when the brain calls `get_state` (p95 gap 10 s, max 100 s while a request is open) or from move lines (52 % of open time), so standing still and fumbling outside moves are indistinguishable. | about 200 B/s, under 1 MB/h; one property read per second (move.lua already reads these per frame) |
| 4 | **pickup attempt events** | gather.lua (per target) and the interact skill (per spot): one row per attempt in `client_io/events/pickup.jsonl` with `act`, target id/class/item, ms timestamps for each phase (approach, aim, press), `detector` at press time (actor, item, prompt), distance, spot number, and outcome (`picked` / `given_up: why` / `refused: game targets X`). Today this exists only as unstructured UE4SS text without action ids, and the interact spot loop logs only generic move lines. | one row per press/spot |
| 5 | **ms timestamps in Lua events** | the mod's event writer: anchor `os.clock()` to `os.time()` at load and write `ts` with 3 decimals. mod, trips, gather, vitals and chat rows are whole seconds today; only UE4SS.log has ms. | none |
| 6 | **archive UE4SS.log per client boot** | tools/client_boot.ps1, before launch: copy the previous `ue4ss\UE4SS.log` to `logs/client/ue4ss-<boot ts>.log`. Today it is overwritten on every launch and kept only on crash. | 1 MB per boot |
| 7 | **model call timing and identity** | brain/controller.py `_complete` (L741): log `latency_ms`, the provider `response.id` and cost on `llm_response` (from the LiteLLM response, or a 10-line LiteLLM `CustomLogger`). | none |
| 8 | **request lifecycle** | brain/run_live.py and executor: one `request_state` row when an episode's chain ends: `ended: done / failed(reason) / talk_only / budget / parked / superseded_by <ep>`. Plus `running` with the body action still in flight when a chat line takes the floor (retro cause 2). Today "done" is inferred from the last body result. | one row per episode |
| 9 | **task thread across episodes** | Tasks Luis steers over many lines need a `job` id. No keyword mapping: stamp the id of the episode that started the body work an action continues (the controller already shows "doing go_to" in the situation). Alternatively, group requests into tasks after the session with one offline cheap-model call over the request list. | one field |
| 10 | **`note:` lines as annotations** | brain/run_live.py `_heard`: a line from the player starting `note:` is logged as `annotation` and not sent to the model. This is a logging convention agreed with Luis, not intent inference. Today's notes cost 35 model calls in 14 episodes. | saves calls |
| 11 | **server side** | The dev server is vanilla (and Shockbyte is too). Its default log has nothing on Claude's actions: joins, saves, spell validation and ServerMove corrections only. For the dev server only, raising chosen categories in `Engine.ini` `[Core.Log]` is possible, but the client's replicated view is the useful truth. Lowest priority; `session_report` already reads the server log for joins and corrections. | none |

With 1-5 in place, the report's correlation becomes exact (no order or window inference), idle classification works
outside moves, and pickup fumbling is counted per press instead of per text pattern.

## Migration path

1. **Now (done):** `tools/session_report.py` over the existing logs. Run it after every live session and paste the
   headline into PROGRESS. The `.tables.jsonl` files are the cross-run dataset:
   ```sql
   -- duckdb (pip install duckdb, or the CLI); reports from every run at once
   SELECT run, cause_kind, count(*) n, round(sum(s)) s
   FROM read_ndjson('logs/reports/*.tables.jsonl', union_by_name=true, sample_size=-1)
   WHERE "table" = 'gap' GROUP BY ALL ORDER BY s DESC;
   ```
   Querying the raw brain log needs explicit columns (heterogeneous rows collapse into a single `json` column
   otherwise; seen with DuckDB 2.0.0):
   `read_ndjson('logs/brain-live-*.jsonl', columns={'ts':'DOUBLE','kind':'VARCHAR','episode_id':'VARCHAR','tool':'VARCHAR'}, ignore_errors=true, maximum_object_size=67108864)`.
2. **Next (cheap, owners of brain/ and client_mod/):** items 1-6 and 10 above, then re-run the report on the next
   live session and check that every idle gap has an exact `act` and a sampled cause. Measure the overhead of the
   1 Hz sampler (frame time, file size) before trusting it.
3. **Then:** add a `duckdb` dependency only if saved SQL views (`tools/sql/telemetry.sql`) earn their keep over the
   stdlib report. Add an HTML timeline view (tools/timeline.py `--html` exists) linked from the report rows.
4. **Optional, only if Markdown stops being enough:** an offline converter from the JSONL rows to OTLP spans named
   by GenAI semconv (`invoke_agent` per episode, `chat` per model call, `execute_tool` per tool call, `dw.body.action`
   and `dw.pickup` children). Load into Arize Phoenix after a session (note ELv2), or Langfuse on another machine.
   Never run a collector during play on this VM.
5. **Stop rule:** if a report cannot answer "why was he idle" for a real failure, add the missing event. Do not add
   a platform.

## Search record

Queries (WebSearch and WebFetch; Tavily was unavailable, with an upstream auth error):
- OTel GenAI agent spans and status 2026;
- Langfuse self-host requirements, licence and OTel endpoint;
- Arize Phoenix self-host, SQLite, licence and architecture;
- DBOS: what it is, SQLite system database, OTel tracing, licence;
- Pydantic Logfire pricing and self-host; LangSmith pricing and self-host; W&B Weave self-host;
- Traceloop/OpenLLMetry 2026 status;
- LiteLLM callbacks, custom callback and OTel integration;
- DuckDB JSON loading and licence; the OTel Python file exporter;
- Mindcraft logging; Voyager ckpt; Project Sid logging; PUBG Ally telemetry;
- wide events / observability 2.0.

Nothing found:
- Mindcraft's log format;
- PUBG Ally's or Project Sid's telemetry pipelines;
- Phoenix's RAM requirements;
- a primary LangSmith pricing page.

Unverified:
- the exact `gen_ai.tool.call.id` name: the page was truncated before `execute_tool` (pin and check the registry
  before exporting);
- the semconv repo move date (v1.42.0, June 2026; secondary source only).

Sources:
- OTel GenAI agent spans (Development status, conversation.id rule, opt-in content): https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-agent-spans.md ; moved notice: https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/ ; repo move (secondary): https://greptime.com/blogs/2026-05-09-opentelemetry-genai-semantic-conventions
- Langfuse scaling minimums: https://langfuse.com/self-hosting/scaling ; licence: https://langfuse.com/docs/open-source ; OTel ingest: https://langfuse.com/docs/opentelemetry/get-started
- Arize Phoenix architecture (SQLite default, Postgres for production): https://arize.com/docs/phoenix/self-hosting/architecture ; licence (ELv2): https://arize.com/docs/phoenix/self-hosting/license
- Logfire pricing: https://pydantic.dev/pricing ; self-hosted (Enterprise, Kubernetes): https://logfire.pydantic.dev/docs/reference/self-hosted/overview
- LangSmith (third-party only): https://costbench.com/software/ai-observability/langsmith/free-plan/
- W&B pricing: https://wandb.ai/pricing
- Traceloop acquisition: https://www.calcalistech.com/ctechnews/article/sjghwiqf11e
- LiteLLM custom callbacks: https://docs.litellm.ai/docs/observability/custom_callback ; OTel: https://docs.litellm.ai/docs/observability/opentelemetry_integration
- DBOS architecture: https://docs.dbos.dev/architecture ; tracing: https://docs.dbos.dev/python/tutorials/logging-and-tracing ; config (SQLite default): https://docs.dbos.dev/python/reference/configuration ; licence: https://github.com/dbos-inc/dbos-transact-py
- DuckDB JSON: https://duckdb.org/docs/stable/data/json/loading_json ; licence: https://github.com/duckdb/duckdb-python
- OTel Python file exporter: https://opentelemetry-python.readthedocs.io/en/stable/_modules/opentelemetry/exporter/otlp/json/file/trace_exporter.html
- Wide events: https://honeycomb.io/blog/time-to-version-observability-signs-point-to-yes
- Voyager: https://github.com/MineDojo/Voyager ; MineCollab: https://arxiv.org/html/2504.17950v1 ; Mindcraft: https://github.com/mindcraft-bots/mindcraft ; Project Sid: https://arxiv.org/abs/2411.00114 ; PUBG Ally: https://developer.nvidia.com/blog/how-krafton-built-pubg-ally-a-co-playable-character-powered-by-nvidia-ace/

### Decision record (search-before-building)
- Need: per-run telemetry answering time-to-complete, idle-and-why, exact model context and pickup detail across
  brain, client and server.
- Searched: the list above.
- Found: OTel GenAI semconv (names), DuckDB (query engine), Phoenix and Langfuse (UIs, too heavy or ELv2 for live
  use here), DBOS (durable execution, a different problem), LiteLLM callbacks (redundant with our logging).
- Decision: **adapt + reuse.** Reuse tools/timeline.py's readers and the existing JSONL; adopt DuckDB and the
  semconv names; build only the thin per-run analysis (`tools/session_report.py`). No commercial component; no new
  service on the VM.

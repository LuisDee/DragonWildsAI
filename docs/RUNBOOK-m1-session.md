# Runbook: the first observed M1 session on the dev world (~2 h)

Goal: one fresh window at the current companion hash that `tools/goal_check.py` can score for the M1 obs rows (exposure, chat → first action latency, anomalies per hour, stability, starvation), plus the addressed-effort A/B (`DW_CONTROLLER_EFFORT_ADDRESSED` off vs `medium`) judged on real chat → first action latency. Driver: `tools/m1_session.py` (plan / mark / chat / report). Nothing here touches Shockbyte.

## 0. What the rows need (facts, 2026-10-26)
- **Exposure** (`tools/obs.py exposure()`): an observed UTC hour counts as *active* only if, in that hour:
  - a brain-live session ran;
  - at least one world-changing body action started;
  - **a non-self chat line appears in `client_io/events/chat.jsonl`**.
- **goal_check:**
  - `obs_exposure` needs ≥ 2 active hours and ≥ 20 world-changing tool calls per hour, at the current companion hash, from a window under 24 h old.
  - With 0 active hours, every obs row is NO_DATA. The latency rows count chat → action episodes instead.
- **Benchmark chat is not real chat.** The benchmark's chat (`evals/bench/devrun.py` `agent.heard(...)`) never reaches chat.jsonl, and logs/evals sessions are excluded. It can't make an hour active.
  - `docs/goal_targets.json` says "harness test-player chat on dev counts", but no code reads that key. A judge-file mismatch for main or Luis.
- **No second player account exists.** The only accounts are Claude's (bootymaxer) and Luis's. `spawn_tester` in mod/bench is unverified.
- **The one candidate chat channel is the dev server mod's on-demand chat** (`mod/body/speech.lua send_direct`, `debug_run speech_direct`).
  - It sends `Server_SendChatMessage` with the bot character GUID under the display name `DW_COMPANION_NAME`. Its default is "Claude", so for this session start the server with `DW_COMPANION_NAME=Tester`.
  - It refuses to send until `action=prove` has passed in that server run.
  - It is marked client-affecting and needs Luis's go-ahead before its first use. Malformed chat structs froze a client before (DISCOVERIES "Client_* RPC" note); v2 guards that shape.
  - Untested on dev: whether Claude's client logs it as non-self from "Tester" and the brain hears it.

## 1. Decisions needed before running
| # | Decision | Who |
|---|---|---|
| D1 | Go-ahead for `speech_direct` test-player chat on the dev server (server-side harness fixture, dev only). Without it there is no chat, so 0 active hours and the speed/voice/exposure rows stay NO_DATA. The only alternative is Luis typing in the session. | Luis |
| D2 | Does harness test-player chat on dev count for `obs_exposure` (goal_targets says yes, obs/goal_check don't read it)? With D1 the lines do land in chat.jsonl as non-self, so obs counts them. Confirm that's intended. | main / Luis (judge files) |
| D3 | The client hold: `logs/client.hold` says "steam logged out 2026-10-26; awaiting Luis RDP login". | Luis |

## 2. Preflight (no model calls)
1. Holds clear (D3). `.venv\Scripts\python.exe -m tools.obs spend --today` gives today's spend. The session must stay ≤ $3 and today's total under the $10 cap.
2. Dev server: start it with `DW_COMPANION_NAME=Tester` and the speech module loaded:
   - `$env:DW_COMPANION_NAME='Tester'; tools\start_server.ps1`, or the watchdog's nav-only server (`DW_NO_BODY=1` still loads speech, main.lua:210);
   - then `tools\start_watchdog.ps1`.
3. Claude's client: `tools\client_boot.ps1 -Target dev`, then `tools\start_client_watchdog.ps1` (interactive session).
4. Server bridge alive: `.venv\Scripts\python.exe -m tools.bridge_cmd ping --body server`.
5. Chat channel proof (D1, once per server run, with the brain already running):
   - a. Run `debug_run speech_direct {action:"prove"}`. It is read-only, and it must pass.
   - b. `.venv\Scripts\python.exe -m tools.m1_session proof --confirm` sends ONE line that says it is a test ("claude this is a test line from the Tester account, please ignore"), then watches Claude's client for 60 s. It passes only if every check holds:
     - the line is in chat.jsonl;
     - `from == "Tester"` exactly, and never a real player's name (Zezima/Luis) or Claude's;
     - `self == false`;
     - the brain logged a `chat_decision` from Tester;
     - Claude's client answered a bridge ping every 10 s for 60 s;
     - the client mod log was written in the last 30 s;
     - the client watchdog logged no hang, crash or restart.
   - c. `chat --sender speech_direct` refuses to run unless the session log holds a passed proof.
   - d. Any failed check, or any client hang, means stop and report. Never use `say_test.lua`.
6. Survival: the stay-fed reflex service is running, and the hotbar has food and drink. A dev fixture grant is allowed on the dev world if needed, since the Clean Water reflex failure is known (DISCOVERIES 1833). Record what was granted.
7. Board jobs (self-directed, no deliveries to a player), e.g. via `tools.board add "<job>" --world dev_director`:
   - "chop ash logs and keep them in your bag";
   - "mine some stone";
   - "keep yourself fed and watered";
   - an `--open` "level Woodcutting".

## 3. Run (2 h, ABAB in 30 min blocks to spread drift)
The brain is (re)started per block. Each start pays a warm-up; the companion hash stays the same.
```
$env:DW_DIRECTOR='1'; $env:DW_DIRECTOR_CALLS_PER_HOUR='10'; $env:DW_PLAYER_NAME='Tester'
$env:DW_SPEND_CAP_USD = <today's spend + 3>     # brain/budget.py hard stop for the brain itself
# block A1 (0-30 min): addressed effort OFF
Remove-Item Env:DW_CONTROLLER_EFFORT_ADDRESSED -ErrorAction SilentlyContinue
tools\start_brain.ps1 -Body client -World dev_director
.venv\Scripts\python.exe -m tools.m1_session mark A1 --note "addressed effort off"
.venv\Scripts\python.exe -m tools.m1_session chat --sender speech_direct --confirm --per-hour 30 --minutes 30
# block B1 (30-60): stop the brain, then
$env:DW_CONTROLLER_EFFORT_ADDRESSED='medium'; tools\start_brain.ps1 -Body client -World dev_director
.venv\Scripts\python.exe -m tools.m1_session mark B1 --note "addressed effort medium"
# ... chat 30 min; then A2 (off) and B2 (medium) the same way
```
- **Drivers of the ≥ 20 calls/h:**
  - the Director's board jobs. The dev smoke ran ~200 world-changing calls/h, so this is ample;
  - 30 test-player lines/h (`tools/m1_session.py LINES`): generic co-play requests, questions and small talk, all prefixed "claude". None are taken from eval or benchmark cases.
  - 15 lines per block, so 30 per A/B half, the n for p50/p90.
- **Stop rules:**
  - the driver stops chat when the session spend passes $3 (the baseline is recorded at the first mark);
  - the brain stops itself at `DW_SPEND_CAP_USD`;
  - any client hang or crash: let the watchdog handle it and note the time. Two crashes means stop and report.

## 4. Report
- `.venv\Scripts\python.exe -m tools.m1_session report --json` gives:
  - the session's exposure, latency, anomalies per hour, stability and deaths;
  - each block's chat → first action p50/p90;
  - the A halves vs the B halves.
- `.venv\Scripts\python.exe -m tools.goal_check` gives the M1 rows. `tools.obs anomalies --since <first mark>` lists them, for the bug ledger.
- **A/B keep rule:** keep `DW_CONTROLLER_EFFORT_ADDRESSED=medium` only if B's chat → first action stays within budget (p50 ≤ 2.5 s, p90 ≤ 4 s) and the voice A/B (already measured: human 3.72 → 3.89) holds.

## 5. Budget (≤ $3)
`tools.m1_session plan`: about 780 Controller calls (Director work ~300/h plus 3 per chat line) and about 20 Director requests in 2 h. That's about $1.1, from measured rates of $0.0008 per Haiku call and $0.016 per Sonnet Director request, plus 30 % for the medium halves. The driver limit and `DW_SPEND_CAP_USD` both stop at $3.

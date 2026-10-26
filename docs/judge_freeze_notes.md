# Judge-file changes since 899c88f, for Luis's sign-off at the judge tag

## Open decisions for Luis at the freeze
- **tools/obs.py is a judge input but not frozen:** goal_check reads `tools.obs metrics --json` for the anomaly, exposure and speed rows, but obs.py isn't in JUDGE_PATHS or the judge_guard list. Proposal: add it at the tag.
- **Voice gate sample size:** today's k=3 has a per-sample sd of 0.063, so the 95% band is ±0.07, which can't tell 0.78 from 0.8.
  - Proposal: k=17 for the GOAL measurement only (±0.03 band, ~700 calls, ≈ $1.6), with MET meaning the k-mean ≥ 0.8.
  - Stricter option: the 95% lower bound ≥ 0.8.
  - k=3 (≈ $0.29) stays for A/B screening.
  - Separately, the case set (n=25) could grow by ~15 real cases from live chat once the client is back.

Main keeps this list. Each change made to a judge file before the `goal-judge-YYYYMMDD` tag gets one line here, so Luis can review all of them in one place when he freezes the tag.

| Commit | File | Change | Why |
|---|---|---|---|
| (earlier, Luis-approved) | docs/goal_targets.json | decision rules, the frozen list of 12 skills, 5 negative controls, long tasks redefined | Luis's answers on 2026-10-26 |
| c6819a7 | tools/goal_check.py | `variant == "quick"` cases never count | Luis: quick grants are for testing only |
| c6819a7 | evals/bench/cases, the suite_v1 manifest | Axtral uses a standing-trees scene; Enchant uses a one-handed sword | the setups were wrong for those spells |
| 3d15c71 | mod/bench/fixtures.lua, bench_probe.lua | a set_time fixture (forward only); the probe reads game_hour | the farm and timing cases need it |
| ab98850 | evals/bench/snapshot.py | snapshot/restore tool (route B) | starting points for the capstone chains |
| b4d3c82 | brain/predicates.py | `structure` and `stored` predicates | the home-chest and farm long tasks |
| pending | evals/bench/goal_cases/long_tasks.json, evals/bench/devtarget.py | remove the stale `body:build_tool` gap; add `built` to REFEREE_SUPPORTS | build is live; needs a live referee `built` proof first |
| 63c9a19 | evals/bench/dev_places.json | the standing-trees spot | Axtral case (T0 PASS live) |
| 63c9a19 | mod/bench/fixtures.lua, evals/bench/spawn_classes.json, devtarget.py | the spawn fixture loads the class via LoadAsset; raise_skills uses an adaptive step and per-skill XP rows | the M1 combat cases could not spawn a runt; Mining overshot; 3 skills got no XP |
| 5c8e057 | evals/voice_eval.py, tools/goal_check.py | voice score = min(checks_pass_rate, judge human/5, silence/5, match/5) on the live persona's full judged run; voice_eval appends the `kind: voice` scoreboard row (log sha256, companion and judge hash); goal_check counts a row only if its log exists with that sha and re-scores to it | voice_score_min had no writer (NO DATA); a row must not be fakeable |
| pending | evals/voice_eval.py, evals/voice_fixtures.py, evals/voice_cases.jsonl | k=3 samples per case: the score is the k-mean, and the spread is reported; every sample is scored on what the live loop says (PROMISE_NOTE continuation on turn 0, TALK_ONLY_NOTE on follow-ups), with first-reply metrics kept as a diagnostic; 25 truncated-bag cases re-rendered by the current perception from the last logged get_state, with a full inventory read; fresh held-out split (seed 20261026, h4/h5 excluded as read); a GOAL row needs k >= 3 | the voice agent's findings: the eval could not tell a persona change from noise, scored a reply the live loop would have continued, and hid the h5 pickaxe |
| pending | evals/voice_eval.py | the default cap is now 120; a sample whose live continuation is cut by the cap is flagged (`continuation_skipped`), and the run then writes no GOAL row; on a follow-up turn the continuation's corrected line is used, as live does | the voice agent: the 90-call cap starved samples 1 and 2 (0.73 vs 0.806); live now uses the corrected line |
| pending | evals/voice_eval.py, tools/goal_check.py | the judge digest carries the Need line and names each call's target (ids resolved from the situation); decide() mirrors the live Controller._final_pass (reads "not run", FINAL_PASS_NOTE, acting tools only); default cap 150; `--persona-ref` (default HEAD) measures the COMMITTED persona and records persona_ref and persona_sha256 in the log and row; goal_check counts only persona_ref == HEAD rows | the voice agent: v24/v25 were penalised blind, and live now has the final pass; main: A/B edits in the working tree must not be measured as the baseline |
| pending | evals/voice_fixtures.py, evals/voice_cases.jsonl | the h1–h6 contexts (made before the broker existed) get body_status and recent_activity by replaying the logged get_state and tool calls through brain.broker.EventBroker; recent_activity is empty in that log (no body activity episodes were logged then), so those cases carry `fixture_gaps: ["recent_activity"]` rather than invented data | small-talk cases had no body status, so Claude invented what he had been doing and the judge marked it down |
| pending | evals/voice_eval.py, tools/goal_check.py | a HEAD run re-executes inside `git worktree add --detach logs/tmp/voice-<sha>` of the ref, so the whole companion (brain/, evals/, persona) is imported from the commit; logs and the scoreboard row go to the real checkout (DW_VOICE_HOME); the row records `measured_commit` and the measured tree's companion hash; goal_check counts only rows with `measured_commit`; `worktree` mode never writes a GOAL row | main: `--persona-ref HEAD` pinned only persona.md while brain/controller.py had an uncommitted A/B edit |
| (this commit) | tools/obs.py | a chat episode left open when its session ended is capped at the session end; short ones read `session_ended`, not a stall | 40-63 ks fake stalls from sessions that died; a real long silence before the end stays a stall |

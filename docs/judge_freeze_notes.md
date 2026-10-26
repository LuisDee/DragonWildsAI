# Judge-file changes since 899c88f, for Luis's sign-off at the judge tag

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

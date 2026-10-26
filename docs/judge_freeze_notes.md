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
| pending | evals/bench/dev_places.json | the standing-trees spot | Axtral case |

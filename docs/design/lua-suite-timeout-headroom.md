# Lua suite launcher timeout headroom

## Goal and evidence

Keep the offline regression gate reliable without changing gameplay or its
acceptance criteria. Full gate rd-g-a915 failed only because the unchanged
test_move.lua process exceeded the launcher's180s wall timeout;1380 other tests
passed and1skipped. The same movement suite then passed in isolation in177.17s
with the original180s limit (rd-g-a915/move-isolated.log, rd-m-a917 temp root).
The new candidate changes only Python decision dispatch; its Lua body and Lua
assertions are unchanged. These observations establish very little timeout
headroom, not a measured gameplay regression or proof of a specific OS cause.

## Approach and principles

Propose raising only the generic external Lua-suite subprocess ceiling in
tests/test_lua_client_suites.py from180s to240s. Keep every suite, assertion,
simulation frame count, in-game action deadline and frozen judge byte unchanged.
This launcher ceiling prevents hanging unit-test processes; it is not a gameplay
speed target. Keep a finite ceiling and subprocess.run's existing kill/wait
cleanup. No skip, xfail, retry-until-green, plugin or production optimization.
The failed gate stays RED. Root will run a fresh complete gate, recording actual
durations. This does not claim faster gameplay or another autonomous pass.

## Acceptance and review

Fresh review must confirm this file is outside JUDGE_PATHS, no simulated/game
deadlines or assertions change, and the extra minute remains a bounded hang
guard. Root inspects the entire diff, freezes it, then runs check_all once in a
new directory with one heavy workload. If that also fails, inspect its evidence;
do not keep increasing the ceiling. Runtime remains the version of the1/3 live
round trip until a deliberate tested integration. No principle exception needed.

## Search record

Queries: `site.docs.python.org 3.12 subprocess run TimeoutExpired child process
killed wait timeout`; `site.github.com/pytest-dev/pytest-timeout README slow tests
timeout long running tests`; `site.docs.pytest.org flaky tests system state timing
timeout`. Opened primary sources:

- https://docs.python.org/3.12/library/subprocess.html#subprocess.run — run kills
  and waits for its child on timeout before re-raising; reuse existing cleanup.
- https://docs.pytest.org/en/stable/explanation/flaky.html — timing/system state
  can make test failures intermittent. This is a possible mechanism, not a
  diagnosis of this machine's particular scheduling behavior.
- https://github.com/pytest-dev/pytest-timeout/blob/main/README.rst — distinguishes
  hang protection from precise performance testing. Adapt the distinction to our
  existing subprocess ceiling; do not install the plugin or copy its code.

Decision: reuse the existing subprocess launcher and all functional tests;
adjust its finite hang ceiling to provide headroom over the observed177.17s run.

# The long-job harness: `tools/job_run.py` (2026-11-17)

Built offline for `docs/GOAL-2026-11-17-long-jobs.md` section 1. Nothing was run against the server, client or brain.
No model calls. Files: `tools/job_run.py`, `data/jobs.json`, `tests/test_job_run.py` (35 tests, all fakes), this doc.
No existing file was edited: the wiring is written as diffs below, for the main session.

## What was built

```
.venv\Scripts\python.exe -m tools.job_run trial --confirm --job L1 -k 3
.venv\Scripts\python.exe -m tools.job_run interrupt --confirm --step I3 --job L2 -k 5
.venv\Scripts\python.exe -m tools.job_run trial --confirm --job L2 -k 1 --until first_step --save-as job_l2_mid
.venv\Scripts\python.exe -m tools.job_run rates
.venv\Scripts\python.exe -m tools.job_run show RUN [--read-trace]
```

- **One window, K trials on forks.** It is `quest_run step`'s window, reused by import: `clone_window` (the live
  lock, never released off ClaudeDev), `quest_clone.fork` per trial, `to_start`, `clock_on` after each trial (regrow),
  `park`, `refuse_dirty`, `preflight`. Records: `logs/evals/job_runs.jsonl` (one per trial) and
  `logs/evals/job_windows.jsonl` (one per window).
- **A trial.** The brain is started by `chat_ladder.start_brain` (the spend cap is today's spend plus `--usd`). The
  player's line is sent once by `m1_session.send_speech_direct`. Every 3 s the brain log is read
  (`quest_run.timeline`, `chat_ladder.model_calls`). Every 15 s `get_state` is read and the end predicate checked. It
  ends at: the job done, `--until first_step`, the step resumed plus 60 s, no resumption within the step's limit, the
  Haiku cap, the deadline, or quiet (40 s, `quest_run.QUIET_S`).
- **`--holder default|board`** sets `DW_GATE_DIRECTOR` for the brain it starts, so the goal's first decision (which
  holder carries the ask, by I3 and I5 trials on each) is one flag.
- **`--save-as`** keeps the next save of the first trial that ends done or at its first step (rule 8). A mid-job
  checkpoint is made by `trial --until first_step --save-as job_l2_mid`. `interrupt` then starts from it on its own.
  Until it exists, `interrupt` starts from the job's start and puts the interruption in after his first verified step.
- **Pure functions, tested:** `done(job, state_start, state_end)`, `bar_s(job)`, `misses(calls, work_s,
  interruption)`, `resumed(calls, interruption, work_tools, lines)`, `first_step`, `trigger_due`, `verdict`, `rates`,
  `trace_allowed`, `apply_interruption` (with a fake body), `run_job` (whole L2, I5 resumed, I5 not resumed, a
  first-step probe, all on a fake body).
- **Misses:** quest_run's rule, by calling `quest_run.verdict` (a failed world action; never `interrupted`, never a
  read). Each miss has its kind (the reason), time, tool, arguments and detail. Also misses per 5 minutes of work
  (active time less stands) and the split before / during / after the interruption.
- **The verdict.** A whole job: quest_run's bars (done, at most 1.5x `human_bar` of his own successful steps, at most
  1 miss, no stand over 5 s), counted by the job's own rule. An interruption step: it took, he took the job up again
  (the first work call that started after it cleared), no new line from the player, within the step's limit.
- **Held-out guard.** `show RUN` prints the scores only. A held-out job's trace opens only with `--read-trace` and
  once 3 trials of that job are scored (void runs left out). Any other job's trace also waits for 3 scored trials,
  unless `--read-trace`. `rates` prints the tuned and the untuned (held-out) pass rate side by side. A held-out window
  prints scores only.

## The jobs (`data/jobs.json`)

| job | line | end predicate | bar (floor, s) | start |
|---|---|---|---|---|
| L1 | claude, make yourself a full set of leather armour and put it on | `worn_made_in_run` Head, Body, Legs (Leather, Hard or Studded) | 457 (no walking) | fork of ClaudeDev; mid: `job_l1_mid` |
| L2 | claude, we need thirty copper ore in the chest at your base | `in_own_chest` Copper Ore 30 | 29.4 (no walking) | fork of ClaudeDev; mid: `job_l2_mid` |
| L3 | claude, gear up for the vault | `gear_target` (gear_plan at the start) and `consumables_carried` food 5, drink 5 | null: `gear_up_t_h` per run | fork of ClaudeDev; mid: `job_l3_mid` |
| H1 | claude, make a bow and forty arrows, then bring back five hides | `made_in_run` a bow 1, arrows 40; `carried_gain` hides 5; `near_start_m` 25 | 74 (no walking) | fork of ClaudeDev |
| H2 | claude, cook ten meals and boil ten waters for the trip and put them in your chest | `in_own_chest` cooked food 10 (not burnt), Clean Water 10 | null: batch cooking never timed | fork of ClaudeDev |
| H3 | claude, get yourself the next tools up from the ones you carry | `next_tier_tools` pickaxe, logging axe, watering can | null: depends on what he carries | fork of ClaudeDev |

- The bar floor is composed from Luis's windows (`data/baselines/luis-2026-11-01.json`), each part with its reason in
  the file. The verdict uses `quest_run.human_bar` per run (his own path and steps), as quest runs do. The floor is
  printed beside it.
- L1 is not counted when he starts with hides, leather or leather armour ("from a character with no hides"). If
  ClaudeDev's bag holds hides, the first L1 trials are recorded "not counted" until a start without them is made by
  a run (rule 8: he stores them, and that save is kept).
- L1 needs Coarse Thread from a spinning wheel, which works only under a roof (parked item 5). L1 may stop there
  before any interruption matters.
- L3's 5 food and 5 drink is not in the goal. It is chosen here and open to change.

## What the harness can read today

No item instance carries a crafted-by or a run-time mark: `inventory.describe_item` reads name, item, count,
durability, masterwork, enchanted and consumable kind only. "Made in this run" is read as: a craft of that item the
body confirmed in the run (`craft` result `data.item`), and more of it on him at the end than at the start.

| predicate | jobs | read from | readable today |
|---|---|---|---|
| `worn_made_in_run` | L1 | `get_state.gear` and the loadout rows (worn); `craft` results (made); bag at start and end | yes. Limit: a piece bought or picked up in the same run as a craft of it would pass |
| `in_own_chest` | L2, H2 | his own `store` / `take` / `inspect` results (the body's read of the game's open container screen: `inside_now`, `contents`); `get_state.structures` `mine` (the client's ledger of what he built) | partly. Only as of his last open of that chest in the run. No independent read at the end: see "Missing reads" |
| `carried_gain` | H1 | `get_state` bag at start and end | yes |
| `made_in_run` | H1 | `craft` results and the bag delta | yes, same limit as L1 |
| `near_start_m` | H1 | `get_state.position` | yes. "Bring back" is read as back where he was asked: the dev sender (speech_direct) has no pawn to come back to |
| `consumables_carried` | L3 | `inventory_items` `consumable` kind (by class, `inventory.consumable_kind`) | yes |
| `gear_target` | L3 | `rung4_gate.gear_target(get_state, stash)` at the start; worn and held PL at the end (item catalog) | partly. The target is the best full set he can reach, from `gear_plan.plan`, which looks at enemies in sight, not at a vault's. A vault's enemies come with the lookup (goal section 3) |
| `next_tier_tools` | H3 | bag at start and end; tier from the item id's last word | yes. Bone's place in the order is a guess |

### Missing reads

1. **A chest's contents at the end, read by the harness.** `inspect` on a built crate returns no contents:
   `client_bridge.contents_of` asks `GetInventory` and the `InventoryComponent` property, both nil on
   `BP_BaseBuilding_Crate_C` (`inventory.lua` says so at `owned_inventory`). The referee sees moves into containers
   (`container_change`), never what a container holds. Two fixes, diffs below:
   - client: `contents_of` falls back to `inventory.owned_inventory`. Unknown: whether a closed container's slots
     replicate to a client that has not opened it (`skills.lua`: "contents may replicate on open").
   - server: a read-only `contents` action in `mod/bench/fixtures.lua`, beside `beds`. Authoritative. Server actor
     ids differ from the client's, so the harness matches by position to a `mine` structure. Native-crash risk (a
     TArray read on the server, the same pattern as `live_empty_tags` and the referee): review and an offline first
     call before a window.
2. **A vault's enemies for L3's target.** Comes with the lookup of goal section 3.

## The interruptions on the dev world

Every fixture is `DevTarget.setup` (`evals/bench/devtarget.py` to `mod/bench/fixtures.lua`): dev server only, the
fork's guid, refused while any other player is on. All verbs used below are in `fixtures.VERIFIED`.

| step | how it is put in | verified live | clears when | resume limit | can it be caused today |
|---|---|---|---|---|---|
| I1 hunger, thirst | `set_stat` sustenance and hydration to 10 % of max (`pct`) | yes (rung1 gate, quest_run `clock_on`) | at once | 90 s | yes. But his stay-fed reflex eats and drinks from the bag with no tool call: a bag with food makes I1 nearly free. A real I1 needs a start whose bag holds no food or water, made by a run |
| I2 a fight | `spawn` Goblin Runt 8 m from him | yes (rung1 `fight_back`, 6 m) | the body's `combat_end` event | 90 s | yes. No fight within 40 s: "did not take" (harness, void). "Led past a creature's spot" is not possible: no data of where creatures live is wired to a route |
| I3 death, grave | `set_health` 0, then wait for the respawn more than 20 m away | yes (rung1 `grave`) | the respawn | 180 s | yes. Each I3 trial leaves a grave in the world for the rest of the window (rule 9): run I3 last, restore the named world after |
| I4 full bag | `grant` Coarse Net (weight 1, stack of 1), one per empty slot, to HIS bag; empty slots re-read, up to 3 rounds | `grant` yes; one grant of N unstackable items filling N slots: no | at once | 120 s | yes, with that unknown. "Just before a gather" cannot be timed: it is put in after his first verified step, so his next gather meets it |
| I5 brain restart | the harness's own brain process stopped (`stop_brain`, taskkill /T) and started again on the same world store after 5 s | the start and stop are quest_run's, used every trial | the new brain is ready (its warm-up is logged) | 120 s | yes. Today the ask is lost on restart (the board is off), so I5 should fail until the ask is on disk. Only the harness's own brain is restarted, never the one `tools/start_brain.ps1` runs (preflight refuses while one runs) |

**When it is put in:** `--trigger first_step` (default: after his first work call the body reported ok),
`share:0.3` (at that share of the job's bar floor), or `at:SECONDS`. A trial from a mid-job checkpoint uses the same
trigger, which then fires at his first step after resuming from the checkpoint.

**Took the job up again:** the first call that started after the interruption cleared and is one of the job's
`work_tools` (gather, craft, store, attack ...). `go_to` is left out on purpose: after a death it may be the walk to
the grave. `resumed` also records the seconds, the call, and whether a player line came in between.

## Wiring diffs (for the main session)

### 1. `tools/failure_ledger.py`: find job runs (needed)

`scan` reads only `quest_run.OUT` and writes `item = "quest: ..."`. A job record carries `run`, `item`
(`job: L2 / I3`), `character`, `checkpoint`, `done`, `ended`, `wall_s`, `idle_over_5s`, `tool_calls`, and its own
`verdict` and `not_counted`, so `first_wrong` works unchanged (tested: `test_failure_ledger_scan_finds_a_failed_job_run`).

```diff
@@ def scan(recs: list[dict], verdict, not_counted, since: str = "", path: Path | None = None) -> list[dict]:
-        new.append({"run": rec["run"], "item": f"quest: {rec.get('quest')}", "character": rec.get("character"),
+        new.append({"run": rec["run"], "item": rec.get("item") or f"quest: {rec.get('quest')}", "character": rec.get("character"),
@@ def tag(runs, cls, cause, void, fix, path=None, recs=None) -> int:
-            rs.append({"run": rec["run"], "item": f"quest: {rec.get('quest')}", "character": rec.get("character"),
+            rs.append({"run": rec["run"], "item": rec.get("item") or f"quest: {rec.get('quest')}", "character": rec.get("character"),
@@ def counts(rs: list[dict]) -> list[dict]:
-        g["items"][re.sub(r"^quest: ", "", str(r.get("item")))] += 1
+        g["items"][re.sub(r"^(quest|job): ", "", str(r.get("item")))] += 1
@@ def main(argv: list[str] | None = None) -> int:
     if a.cmd == "scan":
         from tools import quest_run as q
+        from tools import job_run as jr
         recs = [json.loads(line) for line in q.OUT.read_text(encoding="utf-8").splitlines() if line.strip()]
         new = scan(recs, q.verdict, q.not_counted, a.since)
+        new += scan(jr.all_runs(), jr.verdict, jr.not_counted, a.since)
@@
     elif a.cmd == "tag":
         from tools import quest_run as q
+        from tools import job_run as jr
         recs = [json.loads(line) for line in q.OUT.read_text(encoding="utf-8").splitlines() if line.strip()]
-        print(f"tagged {tag(a.runs, a.cls, a.cause, a.void, a.fix, recs=recs)} row(s)")
+        print(f"tagged {tag(a.runs, a.cls, a.cause, a.void, a.fix, recs=recs + jr.all_runs())} row(s)")
```

Run ids are `YYYYMMDD-HHMMSS-<job>[-<step>]`: they sort with quest run ids, so `--since 20261117` works, and they
never collide (one lock).

### 2. `CLAUDE.md` section 1 step 2: one more read at the start of a session

```diff
-2. **Where it stands:** the last entries of `docs/PROGRESS.md`, then `.venv\Scripts\python.exe -m tools.quest_run rates`, `-m tools.failure_ledger report` and `-m tools.unseen report`.
+2. **Where it stands:** the last entries of `docs/PROGRESS.md`, then `.venv\Scripts\python.exe -m tools.quest_run rates`, `-m tools.job_run rates`, `-m tools.failure_ledger report` and `-m tools.unseen report`.
```

### 3. `tools/quest_run.py`: the busy test as a function (optional)

`cmd_run`'s watch loop is quest-specific (it reads the quest log every poll) and is not importable. `job_run.run_job`
has its own loop and repeats four lines of it (open prompt, open tool, quiet). The smallest refactor, so both use one:

```diff
+def brain_busy(rows: list[dict], tl: dict, t0: float, now: float) -> tuple[bool, bool, float]:
+    """(a model call is open, a tool or the body's own work is open, seconds since the last activity)."""
+    busy = [r for r in rows if r.get("kind") in ("prompt", "llm_response", "tool_call", "tool_result", "say")]
+    open_prompt = bool(busy) and busy[-1].get("kind") == "prompt"
+    open_tool = any(c.get("dur_s") is None for c in tl["calls"]) or bool(tl["body_busy"])
+    return open_prompt, open_tool, now - max(tl["last_busy"], float(busy[-1]["ts"]) if busy else t0)
@@ def cmd_run(a) -> int:
-                busy = [r for r in rows if r.get("kind") in ("prompt", "llm_response", "tool_call", "tool_result", "say")]
-                open_prompt = bool(busy) and busy[-1].get("kind") == "prompt"
-                open_tool = any(c.get("dur_s") is None for c in tl["calls"]) or bool(tl["body_busy"])
-                quiet = now - max(tl["last_busy"], float(busy[-1]["ts"]) if busy else t0)
+                open_prompt, open_tool, quiet = brain_busy(rows, tl, t0, now)
```

and the same four lines in `job_run.run_job` become `open_prompt, open_tool, quiet = q.brain_busy(rows, tl, t0, now)`.

### 4. `client_mod/scripts/client_bridge.lua`: `inspect` reads a built crate (missing read 1, client)

```diff
 local function contents_of(a, U)
     if rawget(_G, "DW_PAUSE") == true or not U.valid(a) then return nil end
     local inv = U.try(function() return a:GetInventory() end) or U.prop(a, "InventoryComponent") -- R17: by-name reads via U.prop
+    if not U.valid(inv) then -- a BUILT crate: both are nil there (inventory.owned_inventory, live 2026-11-01 18:58Z)
+        local own = fn_of("inventory", "owned_inventory")
+        inv = own and own(a) or nil
+    end
     local desc = fn_of("inventory", "describe_item")
```

Then `job_run` would call `inspect` on each `mine` container in sight at the end (a read; `NOT_DRIVING` covers it).
First check offline whether a closed crate's slots are there on the client at all.

### 5. `mod/bench/fixtures.lua`: a server read of containers (missing read 1, server; native-crash review first)

A read-only action beside `beds` (not a verb: `M.VERBS`, which `tests/test_bench_lua.py` freezes, is unchanged).

```diff
+    if args.action == "contents" then  -- read-only: every container within radius_m of the target, with its items
+        local why, target = guard(args)
+        if why then return { ok = false, error = why, detail = target } end
+        local here, out, r = U.loc(target), {}, (tonumber(args.radius_m) or 60) * 100
+        for _, inv in ipairs(U.find_all("InventoryComponent", { skip_defaults = true })) do
+            local o = U.try(function() return inv:GetOwner() end)
+            local q = U.valid(o) and U.loc(o) or nil
+            local cls = U.valid(o) and (U.class_word(o) or "") or ""
+            if q and here and U.dist(q, here) <= r and not cls:find("Player", 1, true) then
+                local items = {}
+                pcall(function()
+                    inv.ItemSlots:ForEach(function(_, e)
+                        local it = U.try(function() return e:get() end) or e
+                        local id = U.valid(it) and U.short(U.try(function() return it.ItemData end)) or nil
+                        if id then items[id] = (items[id] or 0) + (tonumber(U.try(function() return it.Count end)) or 1) end
+                    end)
+                end)
+                out[#out + 1] = { id = U.short(o), class = cls, position = { q.X / 100, q.Y / 100, q.Z / 100 }, items = items }
+            end
+        end
+        return { ok = true, containers = out }
+    end
```

`job_run` would read it at the end through `server_debug({"part": "fixtures", "action": "contents", ...})` and match
each container to a `mine` structure within 1.5 m. That is a small later change to `p_in_own_chest`.

## A first window: I1 to I5 once each on L2

`interrupt` takes one step per window, so this is five windows of one trial each (or one per step in a row).

| part | seconds | source |
|---|---|---|
| fork, switch to it | 60 to 70 | `quest_run.SWITCH_S`, `quest_fresh.jsonl` |
| walk to the start's place | about 25 | `quest_steps.jsonl` 17 Nov: 23 to 28 s |
| brain start and warm-up | 10 to 30 | `chat_ladder.start_brain` |
| ask to his first verified step (walk to copper, one gather) | 60 to 180 | not measured for L2; his first act is 7 to 20 s after an ask |
| the interruption until it clears | I1 0, I2 10 to 40, I3 10 to 30, I4 about 5, I5 15 to 30 | fixtures; respawn; warm-up |
| until he resumes, then 60 s more (or the limit) | 70 to 240 | limits in `data/jobs.json` |
| stop, regrow clock | 10 to 20 | `clock_on` |
| switch back to ClaudeDev | about 70 to 120 | `quest_steps.jsonl`: a 1-trial window took 367 s for a 251 s trial |

- **One trial:** about 6 to 10 minutes. **Five windows:** about 40 to 60 minutes of the body.
- **Spend:** quest trials since 16 Nov had a median of $0.01 and a max of $0.12 (229 runs; Haiku median 9 calls,
  max 34; Sonnet 0 to 3). A job trial is longer: about $0.02 to $0.15 each, under $1 for the five. The cap is `--usd`
  0.6 a trial on top of today's spend, and the $10/day guard stays.
- **Order inside the session:** I1, I2, I4, I5, then I3 last (its grave stays in the world). Restore the named world
  after the I3 window (rule 9).
- **Before it:** a world snapshot with his chest in it (`world_snapshot keep base`); L2 needs his chest to exist.
  For a real I1, a start without food and water in the bag.

## Not built, not tested

- Nothing here has run live. Every live piece (`Live`, `cmd_window`) is reused code wired together; its first
  window is a trial of the harness, not of him. A fault found there voids the trial (rule 3).
- The chest end read is his body's last read in the run, not an independent one (missing read 1).
- L3's target ignores the vault (missing read 2).
- "Side effects repeated after I5" (goal measure 7) is not counted yet. The record holds every call, so it can be
  read from the records later.
- The planner and actor measures (seconds to his first act, seconds standing while a plan is composed, Planner calls
  per job) are in the record as raw rows and `first_step_s`, `sonnet`, `idle_over_5s`, not scored on their own yet.

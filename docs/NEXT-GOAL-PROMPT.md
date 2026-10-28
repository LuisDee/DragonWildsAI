# Goal prompt: traversal, perception and sustained autonomy (Luis, 2026-10-29)

Complete the original Dragonwilds autonomous companion objective in docs/GOAL.md
and docs/goal_targets.json, preserving M1–M6 and every frozen judge. Follow
AGENTS.md and the Accepted steer in docs/design/autonomy-plan.md. The following
is the immediate priority and overrides older recovery/setup task order.

First deliver a reliable, generally capable movement and interaction foundation.
The first acceptance test is: starting at the temple lodestone on DEV, autonomously
walk out of the temple, travel at least 200 metres beyond it, and return to the
lodestone on the correct floor. Pass three consecutive round trips without
operator steering, intermediate waypoint hints, teleportation or temple-specific
code. Use generic navigation, legitimate unlocked movement abilities and learned
per-world data. Verify actual position, elevation, progress, survival and arrival;
a model saying "here" is not evidence. Check another slope/doorway and a changed
destination to expose overfitting. These are additional diagnostic acceptance
tests, not edits to the original milestone judges.

Diagnose the recorded ramp failure before selecting a fix: coordinate units and
axes, capsule centre versus feet, wrong-floor projection, actual movement agent
and NavData selection, loaded navigation coverage, collision/step/slope limits,
waypoint authority and stale or moving targets. Determine whether apparent jumps
were issued jump inputs, automatic stepping or falling. A partial path means the
current planner failed; do not portray it as proof no walkable route exists.

Audit what the headless agent actually observes and can act upon. Provide truthful,
fresh, compact terrain/traversal, entity interaction, map/landmark, container,
station and menu state with stable identities, available actions and observed
outcomes. Distinguish detected from visible, unknown from empty, and unsearched
from exhausted. Reuse game-native controls and existing adapters. Research modern
game agents, accessibility/UI trees, computer-use and visual parsing tools; adopt
only demonstrated improvements compatible with this packaged game, hardware and
headless runtime. Evaluate a rendered fallback if native observations cannot
close a measured gap; do not assume an MCP plugin supplies missing perception.

Next prove purposeful exploration and sustained work using the complete Sonnet
Director plus Haiku Controller. It must choose destinations from task needs,
research, discoveries and visited/unknown coverage; recover from failures; retain
task progress; and verify results. Progress from a gather-and-return/deposit job
to repeated resource runs, station use and crafting, rune essence and useful
unlocked spells, then quest progression, in the original milestone order.
New tasks should require knowledge and model plans, not scripted recipes.

For every failed live experiment, stop blind repetition, inspect its trace,
web-search the specific failure and open primary documentation/source before
choosing the next experiment. Record queries, links, findings, hypotheses and
reuse/adapt/build decisions durably. Time-box investigations; if a block produces
no discriminating evidence, reassess the method rather than expanding scope.

Validate offline, then through developer-driven real client controls, then without
assistance through the complete Sonnet/Haiku agent. Label diagnostics and assistance;
never count them as autonomous passes. Maintain one live operator/client/server,
one heavy workload, bounded Terra delegation within account allowance, separate
per-world memories and the shared $10 UTC-day game-model cap. DEV and ClaudeDev
only; preserve friend-server state and never reconnect there without instruction.

Persist the research and this priority in startup/recovery documentation. Commit
and push coherent tested checkpoints. Give hourly evidence-based updates, stating
what newly passed autonomously or explicitly that nothing did. Continue working
until the objective is achieved, explicitly paused or blocked by missing access
or exhausted usage; save a recoverable handoff before stopping. Final completion
still requires the unchanged original targets, current-code GOAL MET and
CHECK_ALL: GREEN, followed by Luis's sign-off.

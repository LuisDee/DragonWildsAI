# Survival: carried consumption versus independent replenishment

## User decision

Luis,2026-10-29: reliably get out of the spawn temple and become self-sufficient
in food/water. Do not depend on players supplying them. This reinforces the
existing autonomous goal and is persisted in Accepted steer; it does not change
the frozen M1-M6 judges or displace the urgent corrected200m traversal test.

## Current code evidence

- client_mod/scripts/inventory.lua has native carried-item consumption reflexes
  and model-adjustable vitals policy. This is not a resource acquisition planner.
- client_mod/scripts/client_bridge.lua emits vitals_low when a survival stat is
  below policy and no usable item for it is on the hotbar; bag/unusable details
  are attached. Low-vitals event handling alone is not proof of early reserve
  planning or replenishment across a long job.
- brain/broker.py routes a current low-vitals event to a model decision; its
  fallback_line explicitly asks a player to bring food/drink. That is verified
  source behavior, not a demonstrated sole cause of yesterday's observed failure.
- brain/controller.py describes the low-vitals event and instructs the model to
  use available tools where possible. Acquisition, interruptions and return to
  the original plan need end-to-end evidence; changing a complaint alone would
  not implement survival.

No code was changed on this audit. Before a distinct survival implementation,
perform actual web search/open primary sources, record the reuse/adapt/build
decision, obtain a fresh design review and link informed sources beside code.
Do not count this code/doc inspection as a completed external research step.

## Historical live evidence and its limits

PROGRESS records a Haiku-only diagnostic on5d2f662 in which it drank, collected
two pond waters, found no station nearby, inspected buildables, built a Campfire
and crafted two Clean Water. Native records showed Construction+12,Cooking+2,
Stone32->26, netCleanWater+1, health100 and clean terminal ownership/UI. It used
seven Haiku calls/no Sonnet; no intervention during that episode, but its starting
stock included previously granted materials/food/runes and prior developer setup.
It is a useful ingredients-assisted component diagnostic, not complete-agent
from-scratch survival. Evidence location: privatefeedback-loop-20261028/
verified-water-chain.json and no-axe-pilot-20261028-171029-c117f4b6.json.

[Earlier water evidence](r28-clean-water-chain-20261028.md) documents a model-chosen
collection/processing/reserve chain and real developer berry harvesting, while
retaining the failed terminal cleanup and supplied initial station/ingredients.
These must not be flattened into a claim of dependable independent survival.

On2026-10-29, the idle developer-controlled client reached health0.5/hydration0.
Operator fixtures and real consumption restored it for navigation diagnostics.
This is a failed self-sufficiency condition and assisted setup, not an autonomous
survival pass; there was no active brain at that idle moment. Separate inability
to act, missing active model service, reserve planning, blocked movement and
resource availability in the diagnosis.

## Required measurement

With declared normal tools/unlocks and no donated prepared reserves or supplied
station ingredients counted as self-acquisition, the complete agent must find
attainable food and water, obtain/process them through gameplay, consume and
retain a practical reserve, then resume the original task. Measure repeated
replenishment, not one successful drink. Verify actual input data to both models,
specific failed-tool feedback, interruption ownership, persisted progress and
fresh game-state outcomes. Preserve all existing per-world state and histories.

The urgent navigation proof remains first; inaccessible supplies behind a broken
ramp are not repaired by begging for food or hard-coding a survival route.

## External precedent inspected while the traversal gate runs

Actual2026-10-29 queries: `site:github.com mindcraft survival hunger eat food goal
interrupt task resume agent`, `site:github.com/PrismarineJS/mineflayer collect food
auto eat inventory hunger`, and `mindcraft github survival self preservation
modes hunger auto eat resource gathering`. Opened primary sources:

- https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md
- https://raw.githubusercontent.com/mindcraft-bots/mindcraft/stable/src/agent/modes.js
- https://raw.githubusercontent.com/mindcraft-bots/mindcraft/stable/src/agent/self_prompter.js
- https://raw.githubusercontent.com/PrismarineJS/mineflayer-collectblock/master/src/CollectBlock.ts

Mineflayer exposes food/health events, inventory and real consumption separately.
Mindcraft implements priority interrupts and continuation after modes; its
self-prompt loop retains a goal and bounds commandless turns. This supports our
existing reflex/model-plan separation; it does not demonstrate dependable supply
acquisition in Dragonwilds. The inspected modes.js has no food-acquisition mode.

CollectBlock separates pathfinding, tool selection, harvesting and pickup queues;
it confirms event-based collection but its entity-disappearance wait alone is
not an inventory-gain proof. Keep our observed inventory/vitals verification.
Decision: adapt interruption/resumption and composable primitive patterns within
the existing architecture when a trace demonstrates the missing link. Do not
port Minecraft block/name rules, unknown-as-air assumptions, bypass commands or
cheats, and do not add a scripted food route. No survival implementation or new
live acceptance was performed during this source inspection.

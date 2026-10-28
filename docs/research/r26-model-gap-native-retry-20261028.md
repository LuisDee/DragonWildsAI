# Model read view and crafting prerequisite diagnosis, 2026-10-28

## Deployed checkpoint and native read control

Source `9cacd96` is pushed and deployed in C:/gameserver. Companion
`23ce2b4dae31e309`, body `023b06997f5e31de`, approved judge hash
`b5057d95be92c264`. The full gate finished with 1,197 passed, 1 skipped,
417.84 seconds and CHECK_ALL: GREEN; all eight saved source/test/design hashes
matched before and after. Gate archive: `logs/recovery/cf-a529e3d4/` in the
isolated development tree. Publication was Python-only, with no client restart.

The developer then sent a fresh native inventory result through actual
Controller._read and into the next FakeLLM input. It preserved raw diagnostics,
enriched inventory, positive observations, uncertainty and the ToolCall ID.
The enriched result measured 12,963 UTF-8 bytes; the model view measured 1,724.
This used zero provider calls and establishes the deployed presentation path,
not improved autonomous behavior or provider token savings. Private evidence:
`R/logs/recovery/model-gap-publication-ea5b0d34/native-inventory-model-view.json`.
R means C:/gameserver throughout this report.

## Natural model trial

Trial `tree_gap_7c819a7c6b68` used the unchanged natural request,
`Can you cut down a tree?`, with no method, recipe, ingredient or destination
supplied. Current DEV identity/target and the existing world memory were
admitted independently. Both controller and planner were Haiku5.5 under a
shared six-attempt ceiling and independent 150-second cooperative watchdog.
Six controller calls and zero planner calls completed in 21.375 seconds,
costing $0.005. UTC-day total became $0.0259 from 23 priced Haiku calls,
zero Sonnet/planner/unpriced calls. There was no inventory tool call in this
trial, so it did not exercise the new summary in that tool path and cannot
establish a behavioral effect from that change. It is not a controlled A/B.

Observed sequence: explicit chop returned wrong_tool; craft_plan returned the
recipe graph; three remembered grave moves returned no_path; final chat asked
for an axe or materials. There was no craft, build, ingredient acquisition or
planner invocation. Position stayed approximately [66.507,1858.408,-34.724],
HP100 and Woodcutting level6/XP219. No axe/tree or milestone pass occurred.

Strict initial axe absence remains unverified: incomplete native inventory and
hand reads cannot prove absence. Two Bread and four Clean Water were declared
DEV nutrition support before this trial, bringing R26 totals to 44 Bread and
67 Water. No crafting material, station, axe or outcome was supplied. Existing
brain namespace dev_director and native navigation namespace dev were retained.

The original driver result remains exit1/terminal_idle=false because it
required an explicit empty arbiter-owner key that the actual response omits.
Root independently verified both driver processes terminal, the correct living
avatar, raw arbiter/bridge/movement idle and no waiters, then released its own
reservation. The result was not rewritten and no absent/foreign action stopped.
Private archive: `R/logs/recovery/no-axe-tree_gap_7c819a7c6b68/`; original trace
`R/logs/brain-live-20261028-074016-13076.jsonl`.

## Craft-plan defect exposed by the trial

The actual response says the axe recipe requires six Stone and eight Ash Logs
at the observed Crafting Table. For those ingredients it expands catalog
recipes at Beartach, then flattens 18 plus 24 Garou Chit, station finding and
craft steps into apparently mandatory prerequisites. Gather alternatives appear
only as nested gather_instead hints. A fresh developer read on the same source
reproduced this response while positive nearby loose Stone and Ash Logs were
visible. The table was observed about 33m away; visibility does not prove a
safe reachable route or usable station.

This is a generic acquisition-alternative defect, not evidence that currency
or a merchant is actually necessary. Catalog station kind=crafting alone and
recipe names do not verify vendor behavior or that the ordinary craft handler
can execute that acquisition. A separate count defect drops carried read-status
before planning and reports missing observations as exact zero. Proposed fix:
expose OR acquisition alternatives with AND recipe ingredients, branch-local
accounting and same-snapshot inventory uncertainty. Preserve model choice and
native execution gates. Design review precedes implementation and cold review
precedes publication; no target-specific plan or judge changes are justified.

## Developer loose-resource control on the tested deployment

While the candidate remained isolated, the sole client ran one queued
developer-directed loose_stones pickup, count1/radius15/mode=pickup. Run
`20261028-075354`, check `crafting_loose_stone_control_20261028`, took 13.9s
including an eight-second nutrition-settle step. Two Bread/four Water were
declared support (R26 totals46/71); no material grants or health writes.

Gather itself finished after 2.9s with path_blocked, three unreachable target
attempts, gathered0/targets0/swings0. Native position moved about 5.2m to
[70.7631,1861.4225,-35.0345]; HP stayed100 and observed carried counts were
identical. Read completeness stayed partial/lower_bound. This is a failed
acquisition control, despite the queue's observe-only verdict. It neither
proves resource absence nor a completed pickup. The fresh actor census put
the nearest loose resources about 3m above the character's starting Z;
the reason for the failed approach needs trace/navigation diagnosis.

The subsequent trace audit found three actual partial routes (two points each,
lengths6.04/1.48/1.24m), rather than no_path or helper failure. The final saved
v2 response matched its request identity; its endpoint remained far from the
original goal. The mover followed admitted segments, then failed verification
without continuing straight beyond route authority. Detailed per-target move
failure text was not retained, so endpoint exhaustion is supported by source
and route evidence rather than a direct saved detail for each target.

A separately reviewed stationary discriminator then used the same live helper,
one fresh epoch/nonce request at a time and no movement input. Both the resource
stand-XY/current-Z query and the same XY/target-derived-Z query returned the
same partial two-point1.23m path. Thus a height-only change does not resolve the
observed connectivity failure. The nearby2m contrast returned partial=false,
but its endpoint was still about1.28m from the original requested point: neither
projection success nor partial=false proves arrival at the original goal.
Position was unchanged to0.01m, HP1 before/after from unattended needs depletion,
no model calls,3.359s native-query interval. Raw evidence:
`R/logs/recovery/stationary-nav-height-comparison-20261028.json`.
Existing server oracle anchor/link/streaming effects remain possible; these
queries are no-pawn-input diagnostics, not a claim of zero world-side effects.

Queue process was observed terminal, final ping had no action/waiters and the
actual reservation was free. Its private registration was archived and removed
from tools/live_checks to prevent unintended repeat drains. Native source,
world memory, server, Steam and client were retained. No provider calls; day
spend still $0.0259/23 Haiku. Raw queue evidence is in
`R/logs/live_queue/2026-10-28.jsonl`; the pre-control read is
`R/logs/recovery/crafting-native-baseline-20261028.json`.

## Search record

Before the next source gate, a developer terrain scan identified one visible
local slope. An ordinary go_to reached its short goal within the stated1.5m
tolerance. A second upper-slope goal moved/climbed but returned
route_ended_before_goal; post-action positions differed while settling, so no
independent grounded landing or successful upper arrival is claimed. A new
one-stone pickup from the changed start also failed after three approaches,
gathered0, with unchanged observed inventory and HP100. Latest position was
approximately[81.7451,1872.1527,-34.8831]. Existing guards stayed enabled.
Six Bread/six Water were declared support, R26 totals52/77, with ordinary
reflex consumption recovering HP1->47.5 in the first20s and later100; no health
or crafting outcome writes. No model calls. Private evidence: R/logs/recovery/
local-slope-walk-20261028.json, local-slope-upper-walk-20261028.json,
loose-stone-after-ascent-20261028.json and local-terrain-nutrition-20261028.json.

The acquisition source's later full gate was1197passed/1skipped428.81s GREEN,
with all10 saved hashes unchanged. The CHECK_ALL marker was observed in the
terminal host stream; Tee-Object captured pytest output but not Write-Host.
verified-after.json records that log limitation and exit0 separately. Publication
and native current-code validation remain necessary; neither tests nor the
developer short walk prove a new autonomous task capability.

Reuse the actual searches and opened primary sources recorded in
`docs/design/model-read-gap-summary.md` and the crafting acquisition design.
The context change adapts Anthropic's documented tool-result/context handling;
it does not infer game decisions from message size. Acquisition research
queried Mineflayer recipesAll/recipesFor, Prismarine recipe alternatives,
Mindcraft and collection plugins, and opened the primary repositories:
[Mineflayer API](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md),
[Prismarine recipe](https://github.com/PrismarineJS/prismarine-recipe), and
[collectblock](https://github.com/PrismarineJS/mineflayer-collectblock).
They support the conceptual separation of acquisition options and recipe
requirements, not Dragonwilds trading mechanics. Reuse existing catalogs,
profiles, inventory snapshot and native actions; adapt their information
contract rather than build a new planner or script the solution.

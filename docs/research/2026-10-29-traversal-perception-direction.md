# Traversal, perception and sustained autonomy: evidence and tooling survey

Date: 2026-10-29, Europe/Berlin. Owner: root/Sol. This records the source survey
and accepted priority, not implemented improvements or a live acceptance pass.
Read [Accepted steer](../design/autonomy-plan.md) and [active Goal prompt](../NEXT-GOAL-PROMPT.md).
The original M1-M6 targets and frozen judges remain authoritative.

## Immediate evidence and falsifiable explanations

The private friend-trial recording contains 122 paired registry samples at about
two-second intervals, 23:06:36-23:10:36 UTC on 2026-10-28. On the repeat, the player
walked from roughly `[64.49,1877.43,-35.42]` via `[73.95,1867.26,-31.26]` to
`[85.52,1855.15,-31.39]` and waited. ClaudeGuest went from
`[63.23,1877.64,-35.45]` to `[71.25,1862.12,-34.67]` and remained there: 16.22 m
away and 3.28 m below. Three named `go_to` calls returned the same
`route_ended_before_goal`. `look(ramp)` and `look(ramp stairs path up)` returned
`matched=false` and nearby objects, not a traversable geometric description.

Earlier real operator inputs climbed `[69.35,1867.33,-32.70]` ->
`[76.49,1867.33,-31.13]`; Luis confirmed the top was reached but the doorway
remained a problem. One movement snapshot had a waypoint about four metres below
the character. These support wrong-floor/projection/route-authority investigation,
not a confirmed axis swap, nav-agent error or need to jump. A jump seen by Luis
needs correlation with actual jump input, movement mode and height over time.
The local planner already handles two floor layers and slopes; do not pretend
those capabilities are wholly absent.

The earlier statement that he was 29 m away exactly when saying "here" was too
strong: the closest 23:06:51.836 UTC sample was 15.09 m away; 28.9 m was measured
two seconds later. Astra's source/trace review found that named-player `go_to`
updates the target while moving and verifies the live position at arrival. A
sample at 23:06:49.564 UTC corroborates arrival about one metre from the player;
the player then moved before the later chat reply. This is a completed one-shot
action versus persistent following/speech freshness distinction, not a proved
start-snapshot defect. The separate model-chosen intermediate-coordinate false
completion remains distinct evidence.

Private evidence remains outside Git under
`C:/gameserver/logs/recovery/friend-trial-20261028/`, especially
`route-compare-20261028-230635/{positions.jsonl,analysis.json}` and
`live-observations.jsonl`. Do not publish raw player data or secrets.

## Existing code: retain foundations, test missing contracts

- `client_mod/scripts/sense.lua:646-747`: a capped loaded-actor radius census,
  not guaranteed camera visibility, occlusion or complete area coverage. Absence
  is not proof the area is empty. Interaction points can differ from actor origin
  (`sense.lua:429-443`, `skills.lua:255-297`).
- `skills.lua:672-700`: the native detector selects the actual interaction target;
  verify its identity against the selected object before interpreting UI success.
- `skills.lua:478-501,758-775`: scoped screen/owner reads already exist. Unsupported
  UI families remain unknown; do not treat them as closed or add a second owner.
- `skills.lua:1850-1969`: generic store/take, actual transfers, both-inventory
  verification and cleanup exist. Their presence is not an autonomous chest pass.
- `skills.lua:1756-1843`: exploration uses eight directions and visited cells;
  it is not a geometric observed-free/unknown frontier representation.
- `brain/places.py`, `brain/map_memory.py`, Director task history and Controller
  result messages already supply places, memory and feedback. Audit delivery,
  freshness, selection and recovery before claiming any is wholly missing.

These line references are audit locations on the current candidate, not permanent
API identifiers. Independent source reviews are being recorded separately by
Astra (navigation) and Sol (headless interaction).

## Search record

Actual query families used by root (including weaker initial searches):

- `site.dev.epicgames.com Unreal Engine navigation walkable slope agent height step height Z up coordinate system`
  (malformed domain qualifier; repeated correctly below).
- `site:dev.epicgames.com coordinate system Z up Unreal Engine`
- `site:dev.epicgames.com navigation mesh settings agent max slope step height`
- `site:github.com microsoft OmniParser screen parsing GUI agent`
- `site:github.com NVIDIA NitroGen generalist gaming agent`
- `"NitroGen" NVIDIA game agent github`
- `site:github.com mindcraft bot navigation goals explore minecraft`
- `site:github.com baidu UI-TARS desktop screenshot agent`
- `site:github.com "Cradle" "general computer control"`
- `site:github.com microsoft "Magentic-UI"`
- `site:dev.epicgames.com Unreal Engine accessibility UMG screen reader UI automation headless nullrhi`
- `site:dev.epicgames.com "NullRHI" rendering`
- `site:github.com/ros-navigation/navigation2 "frontier" exploration`
- `site:arxiv.org "Beyond the Map" "Frontier" language navigation exploration`
- `site:docs.anthropic.com computer use screenshots tool results feedback`
- `Unreal Engine MCP packaged game runtime navigation widget agent unreal-mcp`
- `site:github.com unreal-mcp editor Python plugin runtime packaged`
- `site:github.com "m-explore-ros2" "frontier"`

Primary pages/source actually opened, findings and decisions:

| Source | What it establishes | Reuse/adapt/build decision and limits |
| --- | --- | --- |
| [Epic coordinates](https://dev.epicgames.com/documentation/en-us/unreal-engine/coordinate-system-and-spaces-in-unreal-engine) | Unreal world coordinates are Z-up. | Reuse conventions; audit every conversion rather than swapping axes speculatively. |
| [Epic native path context](https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/AI/Navigation/FindPathtoLocationSynchronously) | Pawn, Controller or NavData can supply query context. | Adapt only after measured default/explicit context discrimination; reflection availability is separate. |
| [Epic navmesh settings](https://dev.epicgames.com/documentation/en-us/unreal-engine/navigation-mesh-settings-in-the-unreal-engine-project-settings) | Agent dimensions, slope and step settings affect traversability. | Compare actual player and selected mesh; do not assume a baked mesh matches a player. |
| [Epic traces](https://dev.epicgames.com/documentation/en-us/unreal-engine/traces-in-unreal-engine---overview) | Collision traces can observe geometry; profile and hit interpretation matter. | Reuse existing traces/detector; no generic line-trace result is automatically player reachability. |
| [Epic render availability](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Core/FApp/CanEverRender) | NullRHI can disable rendering paths. | Screenshot tools need a rendered source; they do not recover pixels absent from this runtime. |
| [Epic UMG screen readers](https://dev.epicgames.com/documentation/unreal-engine/supporting-screen-readers-in-unreal-engine?lang=en-US) | Standard widgets can expose accessibility; build/config support can be absent. | Investigate coverage, not assume Windows UIA works in this shipping headless game. |
| [Microsoft UI tree](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-treeoverview), [control patterns](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-controlpatternsoverview) | UI identity, structure, state and supported actions are separate contracts. | Adapt this observation pattern to existing game-native readers and UI handlers. |
| [OmniParser source](https://raw.githubusercontent.com/microsoft/OmniParser/master/README.md) | Parses UI screenshots; July 2026 detector update is recorded upstream. | Candidate rendered UI fallback only; not 3D navigation, map knowledge or a headless adapter. Model/weight licences differ. |
| [Microsoft UFO configuration](https://raw.githubusercontent.com/microsoft/UFO/main/documents/docs/configuration/system/system_config.md) | Uses UIA by default with optional visual detection. | Reuse layered structured-first/visual-fallback principle, subject to actual game coverage. |
| [UI-TARS operator SDK](https://github.com/bytedance/UI-TARS-desktop/blob/main/docs/sdk.md) | Custom operators provide screenshots and action execution. | Potential adapter precedent; it still requires a meaningful observation/action backend. |
| [Cradle source](https://raw.githubusercontent.com/BAAI-Agents/Cradle/main/README.md) | Game/computer control through screenshots and keyboard/mouse. | Useful comparative architecture; no evidence of Dragonwilds compatibility or benefit over current native controls. |
| [NitroGen source](https://raw.githubusercontent.com/MineDojo/NitroGen/main/README.md) | Pixel-to-gamepad foundation model. Upstream explicitly limits current last-frame policy's long-horizon/end-to-end ability. | Research motor-control alternative, not a replacement for Sonnet task planning or a proven unseen-game solution. |
| [Mindcraft](https://github.com/mindcraft-bots/mindcraft), [Mineflayer pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder) | Existing game-agent composition; explicit partial/path reset/moving-goal states and interaction-adjacent goals. | Adapt goal/result semantics and recovery contracts; Minecraft coordinates/API cannot be copied into Unreal. |
| [Frontier source](https://raw.githubusercontent.com/robo-friends/m-explore-ros2/main/explore/src/frontier_search.cpp), [newer frontier project](https://github.com/mertgulerx/frontier_exploration_ros2) | Exploration separates known free space from unknown boundaries and scores candidates. | Adapt concepts after observation coverage is valid; do not install a robotics stack as a game fix. |
| [Epic Unreal MCP](https://dev.epicgames.com/documentation/unreal-engine/unreal-mcp-in-unreal-editor), [community MCP FAQ](https://github.com/ChiR24/Unreal_mcp/wiki/FAQ) | These integrations drive the editor; the community FAQ explicitly excludes packaged games. | Not a drop-in shipping-game control layer. Protocol exposure alone supplies no new perception. |
| [Magentic-UI releases](https://github.com/microsoft/magentic-ui/releases) | Recent small-model orchestration/browser work exists. | Conceptual orchestration precedent; browser/file automation does not expose game widgets or terrain. |

No search established an existing drop-in Dragonwilds headless agent that solves
the measured ramp, close-container selection and long-horizon failures. This is
a bounded survey, not a claim every published tool has been exhausted. Recent
upstream status is time-sensitive; record actual versions before adoption.

## Decision and validation order

Reuse the current two-speed architecture, real input paths, native detector,
UI readers and world memories. Adapt only gaps demonstrated in a complete trace.
Compare structured observations with a rendered fallback if an observed gap
cannot be closed natively; measure success, latency, RAM/GPU and API cost before
choosing. Do not migrate frameworks just because they are newer.

The next measurement is a bounded DEV navigation discrimination, not another
unchanged autonomous round-trip failure. Review the candidate probe, verify
target/identity, preserve memory, measure selected context and projection/floor
against the physically traversable route. Offline checks precede changed-layer
developer validation, then full Sonnet/Haiku autonomous repetitions and a second
location. No new model calls or autonomous task passed during this survey.

## Controlled DEV measurements after resumption

Root adopted the existing DEV server/client/oracle; no duplicate brain or game
process was started. Selected ClaudeDev, joined 127.0.0.1:7777, native world
override `dev`; Shockbyte remains forbidden. The one client slot is held by
`root-dev-navigation`. Offline design-record/probe tests: **6 passed**. This is
not a full gate or a movement acceptance pass.

The probe was copied to the actual server mod's experiments directory after an
initial bridge resolve refusal revealed the repository copy was not the loaded
mod location. Its SHA256 was
`232753c41153d94d2f8f3085b72684163754cdbbc9e358dfa07ee95701fc725a`.
No production movement file was deployed. Indexed native PathPoints reads worked.

| Query | Result | Implication / limit |
| --- | --- | --- |
| Actual repeat start/goal, nil context | Six points, partial, ends `[71.68,1862.08,-35.2]`, length 18.614 m. | Reproduces the friend endpoint without the mover. |
| Same query, explicit Default | Identical points/projections/partial result. | Simply selecting Default is insufficient; nil identity is still not directly observed. |
| Same query, explicit Gigantic | Partial, ends `[70.4,1874.24,-34.2]`, length 8.183 m. | Switching to the larger mesh is not a solution. |
| Physically climbed short segment, tight +/-1.5 m projection | Both endpoints off-navmesh; path query not issued. | Coverage/projection differs from player walkability. Expected feet are already inside this vertical window; widening alone could select another floor. |

These are serialized server queries; the client position/pawn/health remained
unchanged before and after. Private results are
`C:/gameserver/logs/recovery/nav-dev-20261029/context{0,1,2}-native.json` and
`manual-climb-segment-native.json`.

One developer-driven baseline using the existing normal `go_to` also failed:
`[82.33,1874.22,-31.27]` -> requested `[76.8,1867.8,-31.13]`, ending
`[80.45,1873.82,-34.81]`, `jump landing missed`, health 100 throughout. Before
the experiment the approved DEV harness supplied five Bread/five Clean Water;
the existing survival reflex consumed supplies and recovered health. This is
recorded setup and not autonomous survival or traversal credit; no model calls.

The movement log explains a different immediate cause: trap `t7` was selected,
its first saved exit point was over three metres below the upper floor, and
stuck recovery called this "perched" and stepped off. The controller subsequently
used a local `[walk,walk,drop]` path and failed landing verification. Stored
`n_ok=58` is not proof that its connector is safe now. Preserve the memory and
repair generic floor/connector validation; do not delete the trap to hide the
failure or patch temple coordinates. This does not establish the same trap
caused the friend-world long-route failure.

After that failed baseline root searched `UCharacterMovementComponent FindFloor
bStartPenetrating FloorDist walkable slope capsule navigation mesh player` and
`Unreal Engine navigation links jump CharacterMovement NavWalking Walking floor`.
Opened Epic FFindFloorResult and FindFloor documentation; the initial legacy
FindFloor URL returned no content, so the working current URL is:
https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/FindFloor?lang=en-US
It describes a capsule floor sweep; cross-version API documentation does not
validate a reflected call or prove a particular sampled surface is traversable.

Root also measured current hardware through Windows inventory: 8,186 MB visible
RAM, about 754 MB free with the existing client/server, Microsoft Basic Display
Adapter reporting zero adapter RAM and a Microsoft Remote Display Adapter.
This does not prove every rendering path impossible; it establishes no currently
reported hardware GPU capacity for a local vision stack. Raw snapshot:
`logs/recovery/nav-dev-20261029/hardware.json`. A rendered fallback still requires
an admitted performance/coverage experiment, not speculative installation.

Astra's floor-reader followup found the verified native typed-reader source
unchanged but no ready one-query wrapper for a hypothetical upper point: archived
callers use obsolete paths or multiple queries within a 150 cm offset bound.
Do not widen that to the 327 cm connector casually. Preserve healthy hook ownership
and exact retained factory/lease closures; a closed marker is not transferable.
Use a reviewed finite caller after the integration window, not another unbounded
callback replay. Cached CurrentFloor is current-pawn evidence only and unknown
bitfields/distances must not become invented penetration or clearance facts.

To discriminate actual missing geometry from navigation projection, root reused
the existing synchronous Visibility-line call pattern for two finite samples at
the previously physically climbed endpoints. Both hit: at XY `[69.35,1867.33]`
the surface was Z `-33.674904`, and at `[76.49,1867.33]` it was `-32.028516`.
They are consistent with the recorded actor centres minus 0.88 m half-height.
Both surfaces lie inside the tight projection boxes that failed on explicit
Default. The pawn identity/position stayed unchanged; no hooks or delayed
callbacks were registered. These are line samples, not full capsule clearance,
penetration or proof of the intervening route. They strengthen the missing
player-walkable nav-coverage hypothesis relative to a simple height-origin bug.
Private source/results: `logs/recovery/nav-dev-20261029/ramp_floor_lines.lua`
and `ramp-floor-lines.json`.

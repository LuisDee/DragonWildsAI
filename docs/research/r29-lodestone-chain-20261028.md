# Materials-assisted Lodestone chain — 2026-10-28

## Request, scope and acceptance

Luis explicitly authorized fixture materials for a trial: Haiku travels a
couple hundred metres away, builds a Lodestone, and uses it. Vault clearing
and resource acquisition are excluded. Root alone operates the existing DEV
client and dedicated ClaudeDev character. No other players, server, saves or
Shockbyte are touched. Existing judges and original goal targets stay frozen.

Acceptance is real travel, native construction/material consumption and a
Lodestone network entry, followed by the actual map/UI teleport selection,
native success signal, independently observed destination and rune change,
and strict movement/owner/UI terminal checks. Developer controls are separate
from the model trial. Any in-episode operator assistance is disclosed; an
orphan or unconfirmed cleanup keeps the overall episode failed.

## Setup and observations

- Runtime began at97fcf1e (Python9516fc3; tested Lua e9200ff), local
  127.0.0.1:7777. Reused server7016/Steam3284; restarted only held client,
  new PID8708/pawn BP_PlayerCharacter_C_2147473105. No other brain/tester.
- UTC API preflight $0.0546/52 Haiku calls, zero planner/unpriced; $10 cap.
- Copied22 preserved state/save files before fixtures, with recorded source,
  copy hashes and stability checks; not a crash-consistent snapshot claim.
- Explicit assisted grants:64 Stone,40 Rune Essence,2 Vault Core,24 Bread,
  24 Clean Water. Existing1610 Law Runes retained. No levels or health reset.
  Normal feeding restored1HP to100. Grants are not acquisition evidence.
- Before materials, buildables returned no Lodestone. After receipt it
  returned BUILDPIECE_Lodestone; unlock count58->60. Native cost32 Stone,
  20 Rune Essence,1 Vault Core matches the reference recipe. One immediate
  post-grant read preceded final essence replication; later read was complete.
- Developer build through ordinary build menu succeeded at approximately
  [181.68,1797.16,-28.75]. Native Construction XP48->128 and materials fell
  by32/20/1; reported build completion telemetry, strict movement idle.
  Its published estimate750XP differed from actual80; do not treat estimate
  as observed progress. Remaining32 Stone/20 Essence/1 Core are for Haiku.
- Registry now contains developer stone D0DF985D47FE386406A380AC564506CB
  and Temple stone5E74232B4126EDE0BAEFF9856FFD03C6 at[50.65,1890.26,-34.88].
  Native reachability/affordability true; quoted cost2 Law Runes.
- Old teleport returned too_far while nearest stone3m away. Source required
  a static nonempty prompt, but sensed entity has kind=lodestone and an
  interact affordance without that field. Preserve actual detector verification.
- Old generic interact tried six stand points then returned too_far at0.915m.
  Immediately afterward native detector identified the exact requested actor
  with Teleport prompt. This supports a synthetic-waypoint mismatch hypothesis;
  it does not prove the detector was available throughout the failed action.
- At that same position, the existing inv_interact command pressed the real
  IA_Interact input. Existing Lodestone map getter changed false->true. Normal
  generic stray-screen sweep did not close it; existing Lodestone close-map
  path changed true->false. No menu state, inventory or position was fabricated.

## Native control adapter and publication plan

Reuse existing module getters/action functions; thin private command adapters
add no scheduler or native API. map-status.lua calls existing W.map_open;
map-close.lua closes only the manually opened unowned map and refuses a
foreign screen owner. A proposed click adapter must require verified DEV,
ClaudeDev/pawn, reservation, no foreign owner/action and an actually open map;
read live registry GUIDs, native CanTeleport and affordability; arm the existing
success hook, capture its baseline sequence and call existing W.try_teleport.
Independently compare position/runes and success sequence afterward. No direct
server RPC implementation or position write. Fresh review precedes that action.

Teleport remains hidden from Haiku until native proof. Offline candidate
ownership/sensing fixes must receive cold review, GREEN gate and controlled
publication. The full compound tool must pass developer validation before
the materials-assisted natural Haiku request. No benchmark criterion changes.
Actual source publication and final trial results will be appended below.

## Research and reuse decision

Actual queries: `site:dragonwilds.runescape.wiki Lodestone build materials teleport
law runes`; `site:dragonwilds.runescape.com lodestones teleport vault core`;
`site:dev.epicgames.com Lyra interaction system interaction options text ability`.
The [Lodestone reference](https://dragonwilds.runescape.wiki/w/Lodestone) was
available in indexed search/local mirror; direct web fetch was robots blocked.
It describes32 Stone/20 Essence/1 Core, Law Rune travel and Temple activation.
Those are hypotheses until the native observations above, not fetched primary
game API documentation. [Official October14 patch notes](https://dragonwilds.runescape.com/news/eye-on-ashenfall-1-0-1)
mention fixes for keyboard freezes after teleport and UI/building issues; that
is context, not proof of this installed runtime's behavior.

Opened [Epic Lyra interaction documentation](https://dev.epicgames.com/documentation/en-us/unreal-engine/lyra-sample-game-interaction-system-in-unreal-engine):
target affordances, focus and input drive interaction; static display text is
not a general availability contract. This is conceptual precedent, not a
Dragonwilds API. Existing source/dumps supply exact component signatures;
native probes supply current behavior. Reuse existing build, sense, interaction,
Lodestone, arbiter and UI functions; adapt their ownership and sensing contracts.
No task-specific language maps, forced model plan or replacement game system.

## Private evidence

R/logs/recovery/lodestone-20261028/: backup-manifest.json, grants.json,
before.json, after-grants.json, developer-build-{before,result,after,idle}.json,
developer-network-after-build.json, developer-teleport-{before,result,after,idle}.json,
developer-lodestone-look.json, developer-interact-*.json, developer-detector.json,
developer-map-press.json and developer-map-owned-close.json. Raw data stays
outside Git and per-world memory remains intact.


## Native teleport and UI follow-up

Two developer controls invoked the exact existing local component route,
`L.W.try_teleport` -> `LodestoneTeleportationComponent:TryTeleport(from.guid,to.guid)`.
Both independently confirmed the native success sequence, destination arrival
and two Law Runes spent (1610->1608->1606). No RPC implementation, position,
inventory or health write was used. The first left the map blocking input;
the second, on fresh client13000 with root-menu transition duration configured
zero before opening, completed proper MainMenuUIAPI NavigateBack and actual
Map13/TopBar29 removal plus Gameplay input. These are developer controls,
not a compound-tool or Haiku pass.

A subsequent restored0.4-second open/back control passed once, but the next
normal0.4 run failed BEFORE teleport: API current menu was new parent2156,
while Root MainMenuStack active widget remained old parent6110. Actual
Map13/29 and map input mode remained present despite MapUIAPI false. Bounded
readiness polling did not reconcile them; no TryTeleport was issued. Thus
normal0.4 cleanup is NOT established as repeatable and the underlying CommonUI
lifecycle cause remains open. Old enum drift, foreign PC and simple playing
UMG animation hypotheses were not supported by native reads. After-the-fact
close variants are not a fix and will not be repeated.

The source candidate uses truthful tri-state actual screen census, exact local
menu/MapPanel/active-stack identity readiness, one game-owned NavigateBack,
and observed screen/mode closure before claim release. It preserves issued
teleport state across suspension. Independent Sol cold review approved the
frozen candidate; 31 Lodestone tests, real shared-mover suspension controls,
skills73/73 and crafting203/203 passed. Model exposure remains disabled.
The full regression is running client-off; server7016/Steam3284 and per-world
state stay intact. Native compound control is still required. No Haiku calls
were made in this wave.

Additional actual searches: `Unreal CommonActivatableWidgetStack nullrhi
headless transition stuck animation Slate tick`; `UCommonActivatableWidgetContainerBase
GetActiveWidget transition duration zero headless CommonUI`. Opened Epic
[stack](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Plugins/CommonUI/UCommonActivatableWidgetStack)
and [container](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Plugins/CommonUI/UCommonActivatableWidgetContaine-)
API documentation: container owns pooled widgets/active state and exposes
GetActiveWidget/GetTransitionDuration/SetTransitionDuration. This supports
public API diagnostics, not direct child-list or state writes. No official
source found in this pass proves the exact current NullRHI causal defect.
A paired repeated zero-duration control is proposed; production configuration
and any autonomous success remain unclaimed until measured.


## Reviewed next headless discriminator

Independent Sol review approved a fresh-client two-cycle test with public
root-stack duration0 configured before any map and kept fixed across both
teleports and MenuAPI Back calls. Capture original0.4 and exact stack identity;
restore only after all UI is confirmed closed on that same stack/world.
If both pass, this declared fixed pre-episode presentation setup may support
full compound developer and bounded Haiku diagnostics. It remains a temporary
compatibility guard, not a root-cause fix or broad stability claim. No secret
mid-episode UI repair, generated callbacks, raw memory or outcome writes.

Actual further reviewer searches included `Unreal CommonUI nullrhi
AnimatedSwitcher transition GetActiveWidget stale transition duration headless`,
`site:issues.unrealengine.com CommonUI transition stack active widget animation tick`,
`site:github.com SCommonAnimatedSwitcher TransitionDuration`, and
`site:dev.epicgames.com Slate active timers widget tick paint sleep active timers`.
Opened primary [SCommonAnimatedSwitcher](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Plugins/CommonUI/SCommonAnimatedSwitcher),
[Slate active timers](https://dev.epicgames.com/documentation/unreal-engine/slate-ui-sleeping-and-active-timers-in-unreal-engine),
[UE-250234](https://issues.unrealengine.com/issue/UE-250234),
and [CanEverRender](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Core/FApp/CanEverRender).
Pending active-widget installation uses transitions and Slate timers; NullRHI
affects rendering paths. UE-250234 is a different5.5/5.6 flicker issue and does
not diagnose this game. Epic staff also explicitly states AutomationDriver
lacks NullRHI support in [this March2026 response](https://forums.unrealengine.com/t/automationdriver-in-spec-test-with-nullrhi-on-a-build-machine-cant-click-a-button-because-hover-isnt-working/2716514),
which concerns cursor/geometry rather than our reflected menu handler. Together
these support investigating headless UI parity, not assuming exact causation.
A rendered low-resolution normal-transition baseline remains a stronger later
discriminator; do not run a second client to obtain it.

Full candidate gate bfed7f2c completed:1241 passed,1 known cassette skip,453.10s, CHECK_ALL: GREEN. All9 frozen file hashes unchanged after gate; teleport remains llmfalse pending deployed compound proof.

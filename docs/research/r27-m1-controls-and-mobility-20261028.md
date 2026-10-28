# M1 native controls and mobility observations, 2026-10-28

## Tested deployment

Commit a43c429 adds the diagnostic runner outside frozen judge paths. Full
gate cf-8b3396c6: 1230 passed, one skipped, 410.18 seconds, GREEN. All three
reviewed file hashes matched afterward. Publication
R/logs/recovery/dev-controls-publication-2c6a664a retained the existing game
processes; no client, Steam or server restart. Companion 7f54b5fea959c273,
body f04cf05ebc5ee552, judge b5057d95be92c264, judge diff empty.

The runner validates an actual copied-file backup manifest and checks
admission immediately at action/speech dispatch, including after the
observer's reentrant pre-action probe. It preserves raw evidence, unsupported
controls and unknown outcomes. It does not write official validity records.

## Actual frozen-judge controls

The existing t0_cast_windstep case and unchanged judge_dev produced:

- Positive control: pass, observed_expected, 50 seconds, zero model calls.
- Claims-only negative: fail / not_achieved, observed_expected, 38.047 seconds,
  zero model calls. The native spell predicate rejected speech without a cast.

Raw R/logs/recovery/windstep-control-oracle-20261028.json and
windstep-control-claims-only-20261028.json link the complete journals. Both
started from independently judged not-achieved baselines. Controls used the
case's declared unlock/rune fixtures, not crafting inputs or tool grants.
The scripted fixture log records every individual grant, including partial
setup from interrupted attempts; they are not autonomous acquisition.

Original failures remain: a 180-second admission could not cover the case's
300-second window, one retry lost root's expired advisory reservation, and
native food/drink reflexes interrupted final observations. The runner retained
the slot and marked those runs blocked. Root waited for actual idle and stopped
only its owned referee. It did not disable the reflexes or relax the guard.
Do-nothing and wrong-action controls remain unrun; this is not full validity.
The strict idle requirement during passive observation will need attention
before a full 300-second ambient control can span recurring food/drink work.

## Independent deployment-model cast

After the developer control, Haiku alone answered the natural Windstep
request with two controller calls, no planner, 12.422 seconds / $0.0028.
Independent native before/after confirmed Player.Spell.WindStep and
DominionStatusEffect newly present, health 100, terminal idle. No ledge-solving
or tactical selection is claimed. Raw
R/logs/recovery/no-axe-pilot-20261028-114914-c1fdfcc8.json.

## Phase Dash remains unproven

Old air_dash_test.lua injected evade once without movement direction. It
measured zero horizontal displacement both plain and after casting. A private
reviewed helper then used the production movement-plus-four-evade-pump order,
checked airborne state and yaw each pump, observed landing and one second of
settling, and verified exact timer/owner cleanup under an external watchdog.

Directional arm without a fresh cast retained 1.2173 m from start to settled;
the same input arm after a fresh Phase Dash cast retained 1.0414 m. Both had
four evade submissions, grounded landing, health 100 and final idle. Neither
proves an air dash or Phase Dash benefit. Cast activation timing and charge
state remain unknown. The helper field retained_displacement_cm measures
landing-to-settled drift; the totals above were computed from baseline and
settled positions. StopJumping acceptance is explicitly unknown; submission
and observed landing are separate facts.

Raw R/logs/recovery/phase-directional-dir_affc64fb46/evidence.json and
phase-directional-castdir_7b3fc3b15a/evidence.json. The private helper/fakes
remain under ignored logs/recovery; 35 fake assertions passed before cold
approval and live use. No production movement code was changed.

## Prerequisite and catalog findings

The knowledge index and wiki identify Air Dash at Agility 32 and describe
Phase Dash as an additional air dash. ClaudeDev is level 22. A fresh read-only
native spell dump shows DoubleJump and Hopper active, with no Air Dash in
active_perks; the harness has separately unlocked 39 utility spells. Missing
base Air Dash is a likely prerequisite gap, not yet a proved causal explanation.
No skills were raised or reset to conceal it. Actual Phase Dash module data
still includes ExpireAfterDuration=2.0; that actor module alone does not prove
the lifetime of the movement ability it grants.

The native dump contains the same 52 loaded spell IDs as the older catalog.
For Windstep and Phase Dash, paths, rune costs, cooldowns, cast type and
allow_while_falling agree. Loaded-object agreement is not full build
certification. The dump tool's hard-coded build field is 26161880; the actual
client is 26162923. Raw native data is saved privately as
R/logs/recovery/phase-native-catalog-20261028.json, not relabelled or committed.
Official promotion stays disabled pending correct build provenance and all
required controls/full measurements.

## Research and next measurement

Actual web queries included `site:docs.ue4ss.com CancelDelayedAction return
boolean`, `site:github.com/UE4SS-RE/RE-UE4SS "CancelDelayedAction" "bool"`,
`site:dragonwilds.runescape.wiki "Air Dash" "Agility" level`, and
`site:dragonwilds.runescape.wiki "Phase Dash" three times`. Opened the pinned
[UE4SS timer source](https://github.com/UE4SS-RE/RE-UE4SS/blob/83330635/UE4SS/src/Mod/LuaMod.cpp#L5114-L5158)
and primary documentation linked in the private design, including
[Epic Enhanced Input](https://dev.epicgames.com/documentation/en-us/unreal-engine/enhanced-input-in-unreal-engine),
[UE4SS delayed actions](https://docs.ue4ss.com/dev/lua-api/global-functions/delayedactions.html)
and [Python monotonic time](https://docs.python.org/3/library/time.html#time.monotonic).
The pinned cancellation Boolean means a same-mod timer was found/marked for
removal, not preemption of a running callback. Wiki pages
[Air Dash](https://dragonwilds.runescape.wiki/w/Air_Dash) and
[Phase Dash](https://dragonwilds.runescape.wiki/w/Phase_Dash) were available
through indexed results and the local mirror; direct web opens were blocked.
Wiki facts remain community evidence; the native snapshot establishes the
actual character's observed active perks.

Reuse the existing input/observer/judge, adapt a private directional diagnostic,
build no companion policy or task-specific action mapping. Next M1 work should
verify the native passive prerequisite and plan legitimate skill progression
or a separately declared valid diagnostic setup; also complete missing native
controls and stable-current-code exposure. Do not repeat identical cast-only
Phase Dash tests or count partial runs as a milestone.

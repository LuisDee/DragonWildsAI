# Unaided tree request and native cross-check, 2026-10-28

## Result and limits

On tested runtime `3e95e40` (companion `e3f9a092f12fa582`, body
`9c45ee68cf63c8ed`, judges `b5057d95be92c264`), Haiku answered the sole request
"Can you cut down a tree?" by checking inventory, retrieving its verified own
grave, equipping the recovered Stone Logging Axe, felling an ash tree, splitting
wood and collecting five additional ash logs. Four controller Haiku 5.5 calls,
zero planner calls, 42.234 seconds, incremental model cost $0.0043.

Independent native probes showed Woodcutting XP 219 to 239, axe count zero to
one, and ash logs zero to 13. The grave supplied eight logs and the axe; only
the subsequent five logs count as new harvesting. The standing ash tree at
[108.39, 1894.78, -31.25] became a native stump at that position. Health stayed
100. The original own-grave observation identified verified ownership, a
distance of 5.31 m and contents of one axe plus eight logs.

This is an unaided recovery/equip/woodcutting/collection chain, NOT a crafted
axe, crafting-from-scratch result, station-build result or complete milestone.
The developer first used the existing measured standing_trees DEV test-scene
teleport after recording the unresolved church-route failure. Developer berry
control collected three redberries; no axe ingredients, tools or stations were
granted. Declared R26 support totals: 68 bread, 99 water, one health restoration
to 100. Existing
per-world state/memory preserved. Thus this is not autonomous survival or an
unaided route out of the church. All inputs during the model episode came
from the ordinary model/body flow; no recipe,route or actionsequence supplied.

The private pilot reported a terminal-idle verification failure because its
old schema expected an explicit empty arbiter owner. Original report retained.
Root independently verified pilot child 8196 terminal, body/mover/arbiter
idle, no pending waiters and correct DEV identity; the independent watch ended
without expiry. No foreign stop/restart or usage retry was performed.

## Evidence and measurement

Runtime R=C:/gameserver, all raw evidence remains private under logs/recovery:
- no-axe-pilot-20261028-100116-7866eb47.json
- haiku-chain-chain_41e1e1623f/parent.json
- haiku-chain-independent-after-20261028.json
- haiku-chain-admission-20261028.json
- r26-standing-trees-scene-20261028.json
- developer-redberry-control-20261028.json
- brain log: logs/brain-live-20261028-110030-8856.jsonl

Tool timing: inventory0.084s; graveinteraction2.045s; equip0.361s;
gather25.953s. Gravecompletion->equipstart2.337s;
equipcompletion->gatherstart0.315s. Firstphysicaltoolstart7.528s after received
request, which does not meet the full speed target on this cold request.
These are oneepisodeobservations, not a speed/stability/voice benchmark.
UTC APIledger afterrun$0.0302/27Haikucalls,0planner/0unpriced.
11:15verdict available11:05; first chain succeeded, intendedcraftchain unproven.

## Memory explanation

The current client state exposed the verified own grave and live contents;
brain/situation.py renders this into the model's situation. Separately,
client_mod/scripts/skills.lua persists up to12deathrecords with time/position/
last-known lostitems in client_io/state/last_death.json and marks recovered
graves. Brain notes/maps/tasks and learned navigation/combat data are stored
perworld; recent tool/conversation context is supplied on subsequent model
calls. No model-weight learning is implied. Removing a carried axe alone is
not a crafting test when graves,existinggear or spell alternatives remain.

A following bounded natural request is explicitly to make a NEWaxe and cut a
tree, recording existing progress rather than clearing memory/equipment or
claiming an empty baseline. Results belong to their own episode and report.

## Search record

No new production behavior was implemented in this measurement. Reuse the
reviewed nativecontrol/source contracts and prior actualsearch records in
r26-short-local-planner-20261028.md. For null-wrapper interpretation root
searched `site:docs.ue4ss.com UObject GetAddress IsValid nullptr Lua` and
`site:github.com/UE4SS-RE/RE-UE4SS GetAddress UObject IsValid`, then opened
[installed-commit UObject source](https://github.com/UE4SS-RE/RE-UE4SS/blob/83330635/UE4SS/include/LuaType/LuaUObject.hpp),
[UObject API](https://docs.ue4ss.com/lua-api/classes/uobject.html),
[CreateInvalidObject](https://docs.ue4ss.com/dev/lua-api/global-functions/createinvalidobject.html)
and [Property API](https://docs.ue4ss.com/lua-api/classes/property.html).
Actual client log pins UE4SS83330635. Four metadata-verified hand getters
returnedwrapperaddress0/IsValidfalse under samepc/pawn/equipment/idle guards,
matching explicitnullcontrol; knownvalidpawncontrol wasnonnull. ParameterCPF
flags are unavailable in supported PropertyAPI, and this does not certify
replication completeness or all object lifetimes. Reuse supportedwrapperreads;
no VM_READ permission changes, binary patches or invalidslotdereference helper.

## Explicit new-axe follow-up: failed craft objective

A separate exactrequest "Can you make yourself a new axe, then cut down a tree?"
used record_only baseline preservingtheexistingaxe/progress. FourHaiku calls,
38.922seconds, incremental$0.0051. It searchedrecipes, pickedlockedBronze,
reportedmissingbars/bench, thenchopped4morewoodwiththeoldstoneaxe. Axe1->1,
wood13->17; no crafttoolcall or newstation. This doesnotfulfilthecompoundgoal.

The actualrecipequery requestedlimit25 andmatched24items,but returnedonly15
alphabeticalambiguitycandidates,total24/truncatedtrue. StoneLoggingAxe wasnot
included. recipes_tool hardcodes15forambiguitywhileits normalpubliclimit
accepts1..50/default25. Rootsearched `site:google.aip.dev 158 pagination
page_size maximum default` and `site:learn.microsoft.com azure search
search-query-odata-select top skip count sort relevance`,opened
[Google pagination](https://google.aip.dev/158),
[Azure query shaping](https://learn.microsoft.com/en-us/azure/search/search-query-create),
and [OData top/skip](https://learn.microsoft.com/en-us/odata/concepts/queryoptions-overview).
Reuseboundedcallerresultsize/total/truncationandtruthfulmetadata; adaptread
candidatevisibilitywithoutchoosingarecipe,semanticrankingorbenchmarklogic.
These areAPIprecedents; runtime/codeevidenceestablishestheactualdefect.

RawfollowupR/logs/recovery/no-axe-pilot-20261028-102045-f1df2a56.json and
haiku-newaxe-newaxe_3225e5b7a2/parent.json. Terminalidletrue,parentwatchterminal
without expiry, no otherbrain. UTCledger$0.0353/31Haiku,0planner/unpriced.

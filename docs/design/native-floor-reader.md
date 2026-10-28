# Opt-in native floor observations

Goal: provide a reusable, truthful observation for a later steering design. This
standalone utility is not loaded by startup and does not change movement. Its
caller must explicitly enable it, supply a validated current component and
world/pawn lifecycle check, and budget one synchronous query. No result is a
support or safety verdict, and legitimate jumps and drops are unaffected.

Reuse hookhub's single native post-hook and its pause protection. Copy only
primitive fields from the typed post-hook parameter during the callback. Check
the exact component address, query location, active token, single callback,
subscriber and hub identity, and caller lifecycle both before and after the
native call. Unknown or partial observations are explicit. Never retry an
ambiguous registration or query; a call budget cannot preempt native code.
Existing subscribers stay intact and the native hook is never unregistered.
`new(hub)` returns a query function and an explicit cleanup function. Cleanup
refuses an active query, pause, or changed hub/record/subscriber identity, removes
only this reader's subscriber, and permanently closes that reader for the
process. A pending or ambiguous hub record remains untouched: the reader does
not flush it or retry registration, and another owner must decide its lifecycle.
Hook and reflected-struct behavior was observed only on the current game/UE4SS
build; a Lua `pcall` does not catch a native access violation. This utility is
not yet approved for live use and requires a caller-specific lifecycle audit.

## Search record

Queries: `site:dev.epicgames.com UCharacterMovementComponent FindFloor floor sweep result FFindFloorResult`, `site:docs.ue4ss.com Lua RegisterHook callback parameters remote object UScriptStruct`, and `site:docs.ue4ss.com lua RemoteUnrealParam get UScriptStruct bitfields`.

* [Epic FindFloor](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/FindFloor?application_version=5.5): conceptual floor-query precedent, not proof of this build's binding.
* [UE4SS RegisterHook](https://docs.ue4ss.com/lua-api/global-functions/registerhook.html): hook callback parameters and hook lifetime; reuse the project's hookhub.
* [UE4SS UScriptStruct](https://docs.ue4ss.com/lua-api/classes/uscriptstruct.html): typed reflected fields and validity methods.
* [UE4SS LuaUObject source](https://github.com/UE4SS-RE/RE-UE4SS/blob/83330635/UE4SS/src/LuaType/LuaUObject.cpp) and [LuaUScriptStruct source](https://github.com/UE4SS-RE/RE-UE4SS/blob/83330635/UE4SS/src/LuaType/LuaUScriptStruct.cpp): implementation context for typed fields. Copied out-table packed booleans were observed wrong and are never read.

Reuse/adapt/build: adapt the existing typed diagnostic and hub, build only a
small opt-in reader. Principles: observational, generic, no input or model
override, verified primitives only, one hook owner and no memory reset. Offline
acceptance uses the real hub with fake engine parameters, including lifecycle,
ambiguous callbacks, registration collision and preservation of other handlers.
Live ABI and real geometry remain separate future acceptance work.


## Measured checkpoint

The disabled source passed33 actual-hub fake assertions and the full gate:
1158 passed,1 skipped, CHECK_ALL: GREEN (382.51s). A separately reviewed,
explicit current-position DEV smoke then reused the existing native hook,
returned one correlated observation with known typed fields, preserved native
identities/position/HP100 and removed its own subscriber. Native registration
count stayed15. This proves that caller's single stationary observation on this
build, not general ABI safety, terrain support or steering behavior. The smoke
permanently closed its reader process marker; future integration must respect
that lifecycle rather than resetting it. Raw evidence is private
`r26-source-reader-stationary-result-20261028.json`.

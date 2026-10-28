# Navigation route authority

The failed natural tree pilot exhausted local segments and received no-path replies, then continued straight toward the raw goal and died in KillZ. Long trips that require the existing oracle must hold movement until an owned route is available. Missing, pending, failed or exhausted route evidence must produce a bounded truthful outcome rather than authorize direct steering. This is generic route admission; it does not interpret the player's request, choose a destination, add an entity exception or change approved judges.

The oracle reports projection and partial-path evidence as typed true, false, or unknown; a failed native call is not a negative result. Projection tries the existing tight then wide extent: any verified success is true, two verified failures are false, and an error or non-boolean without later success is unknown. Path points must be finite three-dimensional numbers both before and after conversion to centimetres; invalid or interrupted native extraction and malformed transport payloads fail explicitly rather than returning a usable path.

Acceptance: actual server module with fake native calls covers both projection attempts and partial getter errors, followed by Python serialization and Lua loading of known false versus absent metadata. Invalid shapes and non-finite coordinates fail closed. Integration requires fresh review, offline checks and separately scheduled live validation.

## Movement contract and acceptance

Reuse the existing primary-route boundary: navigation enabled and XY distance
above `oracle_primary_cm`, or the existing upward jump-height criterion. Missing
service is unavailable authority. `nav=false` remains an explicit direct opt-out;
`local_plan=false` changes only local planning. Nearby optional oracle routing
and existing direct/local, wade and verified traversal behavior remain available.

Bind requests and admitted routes to the movement generation, arbiter token,
actual pawn, resolved world and original requested three-dimensional goal. A
stopped/replaced owner, changed pawn/world or meaningfully moved goal invalidates
the binding. A fresh helper epoch and one-use nonce distinguish old files even
when numeric request IDs repeat. Check binding before consuming the result and
again before native input. Unit tests exercise actual module input calls and
clock/learning state, not just a returned status string.

While required route evidence is unavailable or pending, release movement input
and pause progress/stuck clocks. A bounded go_to attempt fails with a truthful
specific detail. Follow remains persistent, reports one unreachable episode and
retries under its existing bounded retry contract; a newly admitted complete
route can resume it. The 40-second client wait covers the helper's 25-second
loading window plus its potentially outstanding 10-second bridge call. Local
timeout or goal supersession does not cancel that server operation or free the
helper's single-flight slot.

Admitted partial or unknown-partial paths own only their waypoints. Exhaustion
cannot authorize raw-goal steering; arrival still uses the original 3D goal.
Negative planning alone must not create trap, route or traversal-link learning.
Actual-module regressions must retain positive routes, stale epoch/nonce,
replacement/stop and pawn/world changes, missing service, pending/negative
input holds, paused clocks, partial/local exhaustion, persistent follow,
nearby/direct movement and the existing verified jump/link paths. Explicit
direct-mode fixtures preserve their original local-mechanic assertions, with
separate default-routed negative/positive coverage.

After review and the full regression gate, use a reserved developer-driven live
check: stationary sameXY+50mZ negative and the previously measured nearby2m
positive. A temporary100cm `oracle_primary_cm` setting can exercise required
route admission on that small measured corridor, only with protected exact-value
restoration and a clear configuration-assisted label. This does not establish
default long-distance coverage. Capture source/process identities, request and
response identity, owned move state, position/health and terminal cleanup. No
displacement is not proof of zero native input calls; report that distinction.
Only after these controls should another capped unaided model task be attempted.

## Search record

Repository research: `docs/DISCOVERIES.md` nav oracle, `docs/research/2026-10-25-traversal.md`, `mod/experiments/nav_oracle.lua`, `tools/nav_oracle.py`, and reviewed `logs/recovery/navigation-route-authority-design-20261028.md`. Actual queries: `site:dev.epicgames.com UNavigationPath IsPartial path unreal`; `site:dev.epicgames.com K2_ProjectPointToNavigation returns bool`; `site:docs.python.org math isfinite validate float nan infinity`. Opened [Epic UNavigationPath](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/NavigationSystem/UNavigationPath?lang=en-US), [Epic partial paths](https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/AI/Navigation/HasPartialPath), [Python isfinite](https://docs.python.org/3.12/library/math.html#math.isfinite) and [Detour source](https://github.com/recastnavigation/recastnavigation/blob/main/Detour/Source/DetourNavMeshQuery.cpp). The targeted Epic projection page returned no details; the prior reviewed design's Epic ProjectPoint reference supplies the general projection precedent, not proof of this runtime's ABI. Reuse existing native calls and transport; adapt their typed error reporting and validate at the boundary. No new service or navigation framework. These sources document concepts, not proof that a particular game call succeeded.


## Helper lifecycle (v2)

Wire identities use Python's canonical `str(uuid.uuid4())`: 36 characters with
hyphens, matching the actual Lua consumer. Cold review caught that the original
producer's `.hex` representation had 32 characters while the consumer required
36. A producer-to-consumer regression must use an actual Authority offer rather
than independent hand-built UUID fixtures. Actual query:
`site:docs.python.org 3.12 uuid UUID hex str hyphens`; opened
[Python UUID documentation](https://docs.python.org/3.12/library/uuid.html).
Reuse the documented string representation; retain identity and one-use rules.

A helper epoch and one-use nonce bind each request and response; an offered nonce is consumed and busy status published before any bridge write. An unanswered bridge operation remains unresolved. An independent heartbeat republishes the synchronized actual state; it does not establish server idleness. Startup recovery is a separate, fail-closed proof: the old helper writers must be independently terminal, the server and bridge log/append streams must retain identity and continuity, and a matching FIFO ping must complete after the prior synchronous calls. A local helper lock does not prove an old non-locking writer or remote operation ended. Deployment must coordinate the consumer because the v2 heartbeat is not the legacy numeric value.

Additional actual queries: `site:learn.microsoft.com LockFileEx process terminates exclusive lock released`; `site:lua.org/pil/21.3.lua file buffering flush io`; `site:docs.python.org 3.12 threading Event wait synchronization lock`. Opened [Microsoft LockFileEx](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex), [Lua I/O buffering](https://www.lua.org/pil/21.3.html), and [Python threading](https://docs.python.org/3.12/library/threading.html#event-objects). Lock release establishes only ownership of the lock, not completion of a prior server operation. Reuse the repository's `live_queue.single_instance`, server JSONL poll and synchronous debug dispatch; adapt with an atomically published state and bounded per-epoch nonce. Process identity and same-channel barrier requirements remain subject to the independently reviewed startup evidence contract.

`NAV_DIR/recovery_policy.json` is operator-created; it has `version: 1`, `server: {pid, creation_filetime, image}`, `bridge_log` absolute path, `bridge_started: {ts, offset, dir}`, nonempty `retired_writers: [{pid, creation_filetime}]`, and `operator_confirms: {no_other_nav_writers: true, no_bridge_reload: true}`. FILETIME is the decimal Win32 creation timestamp and image is the full executable path. The operator captures known legacy writers before stopping them and verifies terminality; the helper independently queries process identities without privilege mutation. Missing/denied process evidence, absent policy, incomplete JSONL, mismatched start or changed file prefixes is unavailable. The policy covers only that server/bridge lifetime; server restart requires a newly reviewed policy, so unattended server rebootstrap is not implemented. Both `serve` and `query` hold the same `oracle.lock` for their full lifetime. The operator must prevent unrelated oracle writers and bridge reload throughout the admitted lifetime, as process locks cannot cover old nonparticipating writers.

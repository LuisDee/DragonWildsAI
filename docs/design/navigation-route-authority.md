# Navigation route authority

The failed natural tree pilot exhausted local segments and received no-path replies, then continued straight toward the raw goal and died in KillZ. Long trips that require the existing oracle must hold movement until an owned route is available. Missing, pending, failed or exhausted route evidence must produce a bounded truthful outcome rather than authorize direct steering. This is generic route admission; it does not interpret the player's request, choose a destination, add an entity exception or change approved judges.

The oracle reports projection and partial-path evidence as typed true, false, or unknown; a failed native call is not a negative result. Projection tries the existing tight then wide extent: any verified success is true, two verified failures are false, and an error or non-boolean without later success is unknown. Path points must be finite three-dimensional numbers both before and after conversion to centimetres; invalid or interrupted native extraction and malformed transport payloads fail explicitly rather than returning a usable path.

Acceptance: actual server module with fake native calls covers both projection attempts and partial getter errors, followed by Python serialization and Lua loading of known false versus absent metadata. Invalid shapes and non-finite coordinates fail closed. Integration requires fresh review, offline checks and separately scheduled live validation.

## Movement contract (simplified 2026-10-31, cleanup-20261031)

Long trips (XY above `oracle_primary_cm`, or a goal above jump height) ask the
oracle first and steer only along an admitted route's waypoints while one exists.
When there is no route (oracle absent, `no_path`, invalid/partial/ended route,
local replan limit) the move is **not** refused any more: `route_fallback()` hands
it back to the baseline sources (local planner on real collision, leader trail,
navmem, stuck ladder). With no oracle running it falls back at once instead of
holding 40 s. The one guard kept from this rule: straight steering in fallback
mode traces the floor 1.5 m ahead every frame, and a drop (no floor within 4 m
below, or > 2.5 m down) hands the frame to the local planner; when that cannot
help the go_to fails with "no route (...) and a drop ahead". The 2026-10-28 KillZ
death was exactly that beeline. A bare (token-less) command is refused only while
a reflex owns the pawn or the owner's own move runs; a finished skill's leftover
owner is released.

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

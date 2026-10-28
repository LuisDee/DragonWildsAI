# Explicit floor-reader lease lifecycle

The opt-in typed floor reader needs a logical owner that can close and later
reacquire its subscriber on the same known native hook. No startup, bridge or
movement code enables it, and no observation is a support verdict. The native
hook remains process-wide after close; neither close nor reacquisition calls
`UnregisterHook` or `flush`.

`new(hub)` returns query and close functions plus an explicit acquire function.
Acquire requires `enabled=true`, `continuity_verified=true`, and a caller lifecycle predicate which must
remain false permanently once that lease's process/world/pawn/operation becomes
invalid, including any pause or rejoin missed between calls. The reader cannot
infer that continuity from namespace, addresses, movement generation or the
pause boolean. If the caller lacks a reliable invalidation source it must not
reacquire across that unverified boundary. Each acquire issues an opaque lease;
query and close require that exact lease. One factory owns a versioned
process-local ledger; foreign factories and all legacy markers, including a
legacy closed marker, fail closed. There is no migration or marker reset.

The first opt-in acquire records an attempted marker before `hub.on`; failure,
pending, reentry or ambiguity is retained without retry. Once a close removes
only the exact owned subscriber, its ledger remains `closed` and preserves the
exact hub and native record. The same factory may reacquire only when the
original healthy record remains native, not pending/errored, the own key is
absent and the new lifecycle predicate is valid. No native calls or yields
occur between the final exact identity check and `hub.on`; callback ownership
is checked again afterward. A foreign key must never be overwritten. A close
while the query is active returns busy; close while paused invalidates the
lease and remains pending until exact owned cleanup is safe after unpause.
No new owner can acquire while cleanup is pending. Reentry or state replacement
fails closed, preserves other subscribers and never unregisters a native hook.

Each query retains one scoped token, correlated context/location and exactly
one typed callback, while checking the lease, lifecycle and subscriber before
and after the call. A logical token cannot attribute a truly late identical
native callback to its native invocation; fake reentry/cardinality tests do not
prove native callback origin. Lua cannot catch a native access violation before
the callback. Rejoin and process restart require separately verified caller
lifecycle; no automatic rearm or legacy migration is introduced.

Acceptance uses the actual hook hub with fake native callbacks: opt-in,
first-registration once, same-record close/reacquire without another native
registration, false lifecycle across rejoin, stale and foreign lease/query,
active-query close, paused deferred cleanup, native record replacement,
pending/error/registration failure, legacy markers, post-callback changes,
duplicate/foreign/missing callbacks, typed primitives, preserved unrelated
subscribers, and never native unregister. Full gate and any separately approved
live lifecycle observation remain main's responsibility. This respects the
single owner and truthful uncertainty without a new service or game action.

## Search record

Reuse actual searches recorded in `logs/recovery/r26-reader-lifecycle-design-20261028.md`:
`site:docs.ue4ss.com RegisterHook UnregisterHook UFunction callback lifetime`;
`site:github.com UE4SS UnregisterHook crash disconnect hooks 484`;
`site:dev.epicgames.com Unreal delegates remove handle object lifetime`;
`site:lua.org manual closures table identity module reload global state`.
Opened [UE4SS RegisterHook](https://github.com/UE4SS-RE/RE-UE4SS/blob/main/docs/lua-api/global-functions/registerhook.md),
[UnregisterHook](https://docs.ue4ss.com/lua-api/global-functions/unregisterhook.html),
[Epic FDelegateHandle](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Core/FDelegateHandle),
and UE4SS issue reports [#1351](https://github.com/UE4SS-RE/RE-UE4SS/issues/1351)
and [#1445](https://github.com/UE4SS-RE/RE-UE4SS/issues/1445). These support
ownership and lifecycle caution, not proof of this runtime's exact native ABI.
Reuse the existing reader and hub; adapt exact logical lease ownership; build no
new hook service or automatic rejoin mechanism. PRINCIPLES: read-only, generic,
verified fields, no player-state writes, one owner and explicit unknowns.

# Service adoption recovery

- **Goal:** when a bridge starts, its already-running services use the current module handlers without duplicating loops or discarding policy.
- **Evidence:** a fresh bridge module cache still left the old fed-reflex handler active because initial `st.loads` is nil and a healthy global loop skips `start`. Explicit fresh module starts changed handler identities; subsequent dev vitals showed two verified drinks. This observation does not establish the cause of unrelated survival failures.
- **Approach:** on the first supervision of each successfully loaded module, call its existing idempotent start once, even if the global service is healthy. Existing load-change, retry, backoff, pause, and bridge idle safeguards remain. Inventory and combat starts reuse their global loop handles and rebind handlers; global vitals policy and combat orders persist. Inventory's documented start resets transient bad/pending/strike state.
- **Generality and principles:** shared lifecycle, no item rules or outcome fabrication; game-thread services and existing owners remain in control. No principle exception.
- **Acceptance:** start a fresh bridge over a healthy prior service with old callback; verify callback becomes current, loop handle/count and policy survive, subsequent checks do not restart healthy service, and existing unhealthy retry/reload tests remain green. Live validation is separately supervised.

## Search record

Searched the bridge supervisor and existing service lifecycle: these start methods already implement idempotent handler adoption, so reuse them; no new lifecycle library. UE4SS documents game-thread invocation, Python documents the general retained-reference hazard on reload, and Epic describes delegate binding. These are conceptual precedents; Python/Epic APIs are not substituted for Lua behavior.

- https://docs.ue4ss.com/dev/lua-api/global-functions/executeingamethread.html
- https://docs.python.org/3/library/importlib.html#importlib.reload
- https://dev.epicgames.com/documentation/en-us/unreal-engine/delegates-and-lambda-functions-in-unreal-engine

## Review

Design sent to main before implementation; cold review follows.

## Independent review and service contracts

Review approved first adoption with pending state: exceptions, explicit `ok=false`, or unhealthy results remain pending and retry with the existing three-attempt / 60-second backoff. Observed module load is recorded separately, so pending retries do not masquerade as a new reload. Success requires both a successful start and healthy status.

All six start contracts were inspected: chat.start reuses registered hooks; sense.vitals_start reuses its global loop and hook registrations; combat.guard_start reuses the global guard loop and rebinds guard_fn; inventory.reflex_start reuses the global loop and rebinds tick_fn; tickguard.start applies only missing tick intervals; fxguard.start empties only nonempty guarded maps. The first four preserve existing loops or hooks; the last two are idempotent guard applications, not loop creation. Runtime policy and orders remain global; transient fed-reflex bad/pending/strike state is reset by its existing start.

Focused bridge suite: 11 passed, including an already healthy old callback, an explicit failed adoption with bounded backoff and subsequent successful rebind, stable handle/policy, and no repeated start after success. Live service adoption remains independently verified only by the earlier manual refresh, not by this code change.

Cold review found that bare boolean false also needed rejection; corrected with the same retry/rebind regression. Full gate GREEN: 1067 passed, 1 skipped (386.40 s). The initial one-line edit preceded independent review; the pending/backoff revision followed the review conditions, and the final failure contract was checked by cold review. Automatic adoption still needs native remeasurement.

## Native deployment, 2026-10-27 15:59 Berlin

Current bridge deployed at an idle maintenance boundary using its normal start API, without restarting the game or Steam. All six services reported running, loads=1, starts=1 and adopt_pending=false. Fed loop ID 4 and guard loop ID 163 were unchanged across adoption; policy and orders identity were preserved. No bridge action or waiters remained. Private evidence: logs/recovery/automatic-adoption-20261027.json. This verifies automatic service adoption; it does not establish autonomous survival or the broader M1 targets.

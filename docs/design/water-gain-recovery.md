# Water gain attribution recovery

- **Goal:** report the item actually collected from a source, without counting unrelated inventory changes as water.
- **Evidence:** the 2026-10-27 diagnostic returned Goblin Pack x2 for collect_water. skills.lua snapshots all counts before approach, then selects the largest positive gain because the episode has no expected item. The origin of the unrelated gain is not established. This is not evidence for the cause of the separately recorded combat death.
- **Approach:** first inspect reflected source/interaction properties with a bounded read-only generic property probe, reusing the existing shelter_probe.lua reflection pattern. It issues no input or property writes. Resolve output identity from game data or source-associated evidence before implementing attribution; never add a named-item mapping. Reuse the episode's expected-item filter if a reliable identity is available. Unknown identity or ambiguous evidence must be reported truthfully rather than guessed, with no false water-spot learning. Baseline timing and causality need explicit regression coverage.
- **Generality:** reflected actor properties and matching item identities, independent of phrasing, location and named loot. Only fixture/diagnostic arguments select the actor class.
- **Acceptance:** an unrelated gain cannot count or teach water collection; a verified expected gain alongside larger unrelated loot counts only the expected item; unknown identity stays unverified. Fresh dev observation must validate the source identity. No water behavior or live result has been fixed by this design note alone.

## Search record

Repository skills.lua already supports want_item; mod/experiments/shelter_probe.lua already enumerates Blueprint properties loaded after the static dump. Static native headers/object dump did not expose the water Blueprint's output. Reuse read-only reflection rather than infer output from inventory magnitude or a drink category. UE4SS documents property enumeration/indexing; Epic documents reflected Blueprint variables.

- https://docs.ue4ss.com/dev/lua-api/classes/ustruct.html
- https://docs.ue4ss.com/dev/lua-api/classes/uobject.html
- https://dev.epicgames.com/documentation/unreal-engine/reflection-system-in-unreal-engine

## Review

Fresh Terra review approved the bounded read-only discovery step. The private probe limits actors, class depth, properties and strings; guards invalid/default objects and class cycles; distinguishes failed, unsupported and null reads; and does not walk references recursively. A discovered property remains a hypothesis until source-associated evidence confirms the output. Production attribution design depends on those findings.

Native read-only evidence found `WaterItemData` on two live volumes' Blueprint parent, referring to the game's drink item asset. Production design independently reviewed: use that canonical output identity, validate the actual detected actor, capture a readable inventory baseline immediately before each accepted press, count only matching post-press gains, bind learned spots to the actual source, and preserve truthful partial counts. Ordinary interact is unchanged. This corroborates identity and a state change after the interaction; an independent simultaneous gain of the same item remains indistinguishable without a dedicated source event.

Implemented in skills.lua. Focused capability suite: 58/58 passed, including unrelated loot, larger unrelated gains, matching gains during approach, unknown/mismatched source output, unavailable inventory and partial output-data loss. Fresh cold review and live verification remain pending.

Cold review found aggregate and timeout paths still named the selected source after an alternate actor was pressed. Corrected the shared verification source and per-source aggregate/partial records; added alternate-source, multiple-source and stopped-target regressions. Final focused suite: 60/60 passed. Independent final cold review found no further critical defect. Full gate and native live validation remain pending.

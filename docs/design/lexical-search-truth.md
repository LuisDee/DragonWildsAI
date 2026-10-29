# Lexical search must not invent a found object

## Goal and measured defect

Keep Accepted steer in autonomy-plan.md. The complete7ccecf6 trial asked explore
for a door/gate/stairs/opening and received already_in_sight Ash Logs twice.
The query word `the` matched the substring inside the action verb `gather`.
This is a generic matcher defect, not evidence of a door or exit. Private proof:
rfp-trial-a709/actual-body-results.jsonl. No autonomous200m pass occurred.

## Approach and review scope

Repair the shared lexical score with meaningful whole-token matching instead of
arbitrary substring hits. Normalize identifier separators/camel case and retain
simple plural matching. Omit grammatical function words as matching evidence;
do not add game-object/location/recipe lists or semantic command maps. Preserve
the numeric ranking API and inspect all consumers, including item resolution,
look and exploration. Existing exact-id/name resolver tiers stay unchanged.

Describe matches honestly as lexical evidence, not full interpretation of an
arbitrary geometric request. Literal resources remain searchable; descriptive
synonyms or compound names may require the model to select a name from observed
candidates. Do not solve ambiguity with a new language parser or scripted route.
If a broader semantic-admission change is required by tests, stop and review it
rather than silently weakening matching behavior.

## Search record

Actual queries2026-10-29: `site:github.com/PrismarineJS/mineflayer pathfinder
findBlock matching function exact block name search target` and
`site:dev.epicgames.com EQS query test filter score item match navigation path`.
Opened primary references:
- https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md
- https://dev.epicgames.com/documentation/unreal-engine/eqs-node-reference-tests-in-unreal-engine?lang=en-US
- https://www.lua.org/manual/5.4/manual.html#6.4.1

Mineflayer filters candidate blocks by predicate before distance ordering; Epic
EQS separates filtering from ranking. Lua documents frontier/token pattern
facilities. Decision: adapt these lexical filtering principles in the existing
small matcher; neither external game API is claimed compatible with Dragonwilds.

## Generality and principles

The repair applies to any query/object and preserves model intent. It adds no
temple handling, secret waypoints or task workflow. PRINCIPLES2/3/5/6 remain
intact. Root owns integration; a fresh reviewer must inspect this design before
implementation and cold-review code afterward. Frozen judges stay unchanged.

## Acceptance test

Regress both exact recorded queries against the recorded Ash Logs row; `the`
alone cannot match gather or a name containing only function words. Retain
literal/plural resource and meaningful action-keyword cases, identifier token
boundaries, numeric score behavior and exact-name/id resolver tiers. Run shared
matcher/look/explore/resolver suites and design checks before the required gate.
Then developer look/explore observations followed by complete-agent acceptance;
offline success is not a gameplay pass.

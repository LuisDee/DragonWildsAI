# Planner input contract: fewer avoidable repair rounds

## Goal

Get the complete agent into real gameplay with correct interface information,
rather than spending its planning allowance guessing arguments or revising a
legitimate ordered final state. The deliverable remains the corrected200m
temple trip and subsequent independent provisions; this patch is not a pass.
Follow Accepted steer in autonomy-plan.md and PRINCIPLES.md.

## Approach

- Director input renders the existing body's argument JSON schemas for the
  tools it actually exposes, including bounds/defaults/enums/nested structure.
  Keep validation authoritative and missing schemas explicitly unknown; no
  duplicate handwritten argument limits or silently truncated constraints.
- For a validated ordered_steps plan, retain the truthful final-state trivial
  flag but do not issue the generic already-true-global advisory that requests
  another model answer. Explain that required checkpoints and the final state
  jointly establish completion. Other warnings, state-only behavior, checkpoint
  validation and frozen predicates are unchanged.
- Share concise wire-coordinate documentation between Director and Controller
  using existing geom.py: [x,y,z] in metres, XY horizontal, positiveZ up; own
  client position is capsule centre, object origins/interaction points can differ.
  Three-component near distances include height but do not prove a labelled floor
  or connected path. This documents current conversions, not a new geometry API.
- Scope: brain/director.py, brain/controller.py, brain/geom.py and focused tests.
  Do not alter selection of actions, risk preparation, request accounting,
  llm_json/provider adapters or default budgets in this code wave. A bounded
  diagnostic may explicitly set the existing hourly allowance higher while
  retaining real usage/window history and the shared$10UTC-day cap.

## Precedent and search record

Reuse the actual body manifest and existing schema validation. Actual prior
queries/evidence are in ../research/2026-10-29-planner-input-friction.md; reopened
[Anthropic Define tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools)
and [BehaviorTree Sequence](https://www.behaviortree.dev/docs/3.8/nodes-library/SequenceNode/).
The former documents explicit parameter schemas; the latter separates sequence
progress from a current condition. No library or forced game plan is adopted.

For units actually searched `site:dev.epicgames.com Unreal Engine coordinate
system Z up centimeters units`; opened
[Epic coordinates](https://dev.epicgames.com/documentation/unreal-engine/coordinate-system-and-spaces-in-unreal-engine)
and [Epic units](https://dev.epicgames.com/documentation/unreal-engine/units-of-measurement-in-unreal-engine?lang=en-US).
UE raw centimetres/Z-up are API context; our METRE wire conversion is verified
in client_mod/scripts/sense.lua and mod/body/util.lua. Link sources beside
informed code and avoid equating raw UE units with wire units.

## Generality and principles

Every tool derives constraints from the same manifest, with no place, item,
recipe or phrase mapping. Models still choose outcomes and methods. Preserve
all world state and frozen judges. No real input or inventory manipulation is
introduced; honest observability is the change.

## Acceptance test

Capture actual Director requests with changed arbitrary tool bounds, nested
schemas and unavailable schema; ensure model input agrees with validation.
Check valid ordered initial=final plans need no redundant global advisory, while
state-only trivial and unknown/invalid checkpoint feedback remains intact.
Capture actual Controller and Director coordinate documentation without claiming
an actual floor sensor. Targeted regressions, cold review, full gate, developer
real controls, then a bounded complete agent run on the original job. Retain
actual calls, prep timing, native movement, feedback delivery and all failures.

## Review and focused evidence

Fresh Terra design review CLEAR; it required intact manifest args rather than
the existing description-capping function_schema helper. Fresh cold review CLEAR
on the implementation; no current runtime capability-refresh path was found that
would establish a new asynchronous snapshot regression.86focused tests passed;
main's ordered-contract/input/design preflight passed20tests. No new autonomous
gameplay pass is implied. Source URLs accompany informed code.

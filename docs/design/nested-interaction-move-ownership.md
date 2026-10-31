# Nested interaction movement ownership (trimmed 2026-10-31)

## Problem (observed 2026-10-28, build 26161880)
A Clean Water craft finished, but a movement generation with no owner token stayed live
(stationary, ticks rising) after the action ended. Two source defects were confirmed:
1. `crafting.lua` called `skills._episode_poll(api, job.ep, t)` without the craft token, so the
   child `move.go_to` started unowned (the arbiter refuses implicit adoption while a parent owns it).
2. The episode's near → face transition set `e.moving=false` without stopping its live child
   generation, and terminal `finish` released the parent without stopping it either.

## Contract kept
- Every episode-driven child move carries the parent's arbiter token (`crafting`, `talk`, `lodestone`
  all pass it to `_episode_poll`).
- Before an episode leaves approach (face, another spot, success, failure, cancel) it stops only its own
  still-active child, checked by generation + token. A foreign or successor generation is never stopped.
- A bare (tokenless) move is refused only when something actually owns movement; an ordinary direct
  move with an idle arbiter still adopts implicitly (simplified 2026-10-31, see code_audit.md §4 step 2).
- The bridge deadline (`client_bridge.lua` action timeout) cancels under `pcall` and finishes with
  timeout regardless, so cleanup cannot retain a pending action: report cleanup honestly, never fake idle.

## Lodestone map close (native controls 2026-10-28)
- `MapUIAPI:IsShowingMap()` can be false while the Map (13) / TopBar (29) widgets and
  `DIM_FullScreenUIMap` remain; use `input.observe_screens` (widget 13 present / absent / unknown).
- `CloseMap`, UI Back and a map toggle left the widgets open; `MainMenuUIAPI:NavigateBack(parent)` on the
  current map parent (once the root stack's active widget equals that parent) cleared 13 and 29 and
  returned input to Gameplay.
- `CanTeleport` is dynamic: for the same source/destination it read false ~19 m from the source and true
  ~1 m away, so a distant false is not proof of "not unlocked". Never replay `TryTeleport` after suspension.

# Benchmark state snapshots (design §7.3, goal-cases review C5)

A snapshot is the **starting state** of a case, in two parts:

1. **Brain state.** Notes, places, the learned-skill library, map memory and goals. It is always a fresh, empty `DW_STATE_DIR` per case, unless the manifest lists `brain_seed` files.
2. **The dev character.** What ClaudeDev carries, wears and knows at the start. The harness establishes it with fixture verbs (`setup`) and then checks it with the probe (`requires`, which are predicates). If the check fails, the case is a `skip: precondition`, never a run from a different start.

`manifest.json` is hashed into every case's `case_hash` (`evals/bench/spec.py snapshot_digest`). Editing a snapshot therefore re-opens validity and needs a new pin.

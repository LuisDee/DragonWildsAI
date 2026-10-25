"""Capability benchmark (docs/design/eval-benchmark.md): chat-phrased cases scored from independently observed game
state, with validity controls, frozen manifests and a sha-bound goal check (tools/goal_check.py).

Every case file carries the canary below (BIG-bench practice) so leaked case text can be found anywhere."""

CANARY = "DWBENCH-CANARY 6f1e9a2c-benchmark-data-do-not-train-or-copy-into-companion-code"

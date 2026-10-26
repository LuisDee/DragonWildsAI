#!/bin/sh
# Run one DWClient command on Claude's game client (client_mod/scripts/main.lua's runner).
# Protocol (L28, docs/design/client-runner-queue.md): write client_io/cmd/<name>.lua (via a rename, so
# the runner never sees a half-written file), THEN append "<name>" to client_io/cmd/queue.txt; the
# runner reads the queue file (no directory listing, no process on the game thread).
# Usage: tools/client_cmd.sh client_mod/commands/<name>.lua [timeout_s]
cd "$(dirname "$0")/.." || exit 1
n=$(basename "$1" .lua); rm -f "client_io/out/$n.json"
cp "$1" "client_io/cmd/$n.tmp" && mv -f "client_io/cmd/$n.tmp" "client_io/cmd/$n.lua" && printf '%s\n' "$n" >> client_io/cmd/queue.txt
for i in $(seq 1 "${2:-30}"); do [ -f "client_io/out/$n.json" ] && { cat "client_io/out/$n.json"; echo; exit 0; }; sleep 1; done
echo "timeout"; exit 1

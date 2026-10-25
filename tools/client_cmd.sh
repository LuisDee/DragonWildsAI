#!/bin/sh
# Run one DWClient command on Claude's game client (client_mod/scripts/main.lua polls client_io/cmd).
# Usage: tools/client_cmd.sh client_mod/commands/<name>.lua [timeout_s]
cd "$(dirname "$0")/.." || exit 1
n=$(basename "$1" .lua); rm -f "client_io/out/$n.json"; cp "$1" "client_io/cmd/$n.lua"
for i in $(seq 1 "${2:-30}"); do [ -f "client_io/out/$n.json" ] && { cat "client_io/out/$n.json"; echo; exit 0; }; sleep 1; done
echo "timeout"; exit 1

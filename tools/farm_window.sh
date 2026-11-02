#!/bin/sh
# One short read-only farming window on the live body (farming agent, 2026-11-01): the game's farming data
# (client_mod/commands/farm_data_probe.lua) and farm.lua's farm_plots read of every plot in range (Luis's plots
# included: a read, never a tend). Run under the live lock:
#   .venv/Scripts/python.exe -m tools.live_lock run rung3 --no-clean -- sh tools/farm_window.sh
cd "$(dirname "$0")/.." || exit 1
mkdir -p logs/farm
ts=$(date -u +%Y%m%dT%H%M%SZ)
sh tools/client_cmd.sh client_mod/commands/farm_data_probe.lua 90 > "logs/farm/farm_data_probe-$ts.json"
echo "probe exit $? -> logs/farm/farm_data_probe-$ts.json ($(wc -c < "logs/farm/farm_data_probe-$ts.json") bytes)"
sh tools/client_cmd.sh client_mod/commands/farm_plot_probe.lua 60 > "logs/farm/farm_plot_probe-$ts.json"
echo "plot probe exit $?"
.venv/Scripts/python.exe -m tools.bridge_cmd farm_plots '{"radius": 120}' > "logs/farm/farm_plots-$ts.json" 2>&1
echo "farm_plots exit $? -> logs/farm/farm_plots-$ts.json"
.venv/Scripts/python.exe -m tools.bridge_cmd get_state '{}' > "logs/farm/state-$ts.json" 2>&1
echo "get_state exit $?"
.venv/Scripts/python.exe -m tools.bridge_cmd recipes '{"item": "Wooden Spade"}' > "logs/farm/recipes_spade-$ts.json" 2>&1
.venv/Scripts/python.exe -m tools.bridge_cmd recipes '{"item": "Wooden Watering Can"}' > "logs/farm/recipes_can-$ts.json" 2>&1
sh tools/client_cmd.sh client_mod/commands/farm_time_probe.lua 30 > "logs/farm/farm_time_probe-$ts.json"
echo "time probe exit $?"

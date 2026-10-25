-- debug_run entry for the benchmark's DEV-server parts (debug_run resolves names in scripts/ and experiments/ only).
--   debug_run {"module":"bench","args":{"part":"referee","action":"start","watch":"Claude"}}
--   debug_run {"module":"bench","args":{"part":"fixtures","verb":"spawn","character_guid":"...","class":"..."}}
-- Both parts refuse unless DW_SERVER_ROLE=dev (docs/design/eval-benchmark.md §7.2). Owned by the Eval agent.
local M = {}

function M.run(log, args)
    args = args or {}
    -- the DEPLOYED mod root: this file's own path (<root>/scripts/bench.lua), else DW_MOD_ROOT
    local src = debug.getinfo(1, "S").source
    local root = (src:match("^@(.*)[/\\][Ss]cripts[/\\]bench%.lua$") or os.getenv("DW_MOD_ROOT") or "."):gsub("\\", "/")
    rawset(_G, "__dw_bench_root", root)
    local part = tostring(args.part or "")
    if part ~= "referee" and part ~= "fixtures" then return { ok = false, error = "part must be referee or fixtures" } end
    local mod = assert(loadfile(root .. "/bench/" .. part .. ".lua"))()
    return mod.run(log, args)
end

return M

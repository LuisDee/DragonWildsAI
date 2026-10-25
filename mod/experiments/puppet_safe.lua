-- Debug entry point for the verified safe removal (the logic lives in body/removal.lua).
-- debug_run {module="puppet_safe", args={unpossess=true, orphans=false}} removes every puppet
-- (each alive BP_PlayerCharacter_C that is not possessed by a PlayerController).
-- Verified on build 26161880: docs/DISCOVERIES.md "Unpossess crash: fix bisect".
local removal = require("body.removal")

local M = {}

M.safe_remove = removal.safe_remove -- kept for callers of the old scripts/puppet_safe.lua
M.alive = removal.alive

function M.run(log, args)
    return removal.remove_all(log, args or {})
end

return M

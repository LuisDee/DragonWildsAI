-- Eval agent experiment (dev server only): do the UDominionCheatManager dom* functions DO anything in this shipping
-- server build? Calls ONE whitelisted cheat on the target's constructed CheatManager and reports a server-side read
-- before/after. Not a fixture: used once per function to decide whether fixtures.lua may rely on it.
--   debug_run {"module":"bench_cheat_probe","args":{"character_guid":"...","fn":"domModifySustenance","args":[10]}}
local M = {}
local WHITELIST = { domModifySustenance = true, domModifyHydration = true, domSetTime = true, domAddItem = true,
                    domAddSkillXp = true, domUnlockSpell = true }

function M.run(log, args)
    args = args or {}
    if os.getenv("DW_SERVER_ROLE") ~= "dev" then return { ok = false, error = "not_dev_server" } end
    if not WHITELIST[tostring(args.fn)] then return { ok = false, error = "fn not whitelisted" } end
    local src = debug.getinfo(1, "S").source
    local root = (src:match("^@(.*)[/\\][Ee]xperiments[/\\]bench_cheat_probe%.lua$") or "."):gsub("\\", "/")
    local U = assert(loadfile(root .. "/body/util.lua"))()
    local target
    for _, p in ipairs(U.find_all("BP_PlayerCharacter_C", { skip_defaults = true })) do
        local ps = U.try(function() return p.PlayerState end)
        if ps and U.try(function() return U.guid_hex(ps.OwnerGuid.CharacterGuid.InnerGuid) end) == args.character_guid then target = p end
    end
    if not target then return { ok = false, error = "character_not_found" } end
    local pc = U.controller_of(target)
    local cm = U.try(function() return pc.CheatManager end)
    if not U.valid(cm) then return { ok = false, error = "no_cheat_manager (run fixtures action=cheats mode=construct first)" } end
    local function read()
        local sc = U.try(function() return target.SustenanceComponent end)
        local hc = U.try(function() return target.HydrationComponent end)
        local inv = U.try(function() return pc.InventoryComponent end)
        return { sustenance = sc and U.try(function() return sc:GetCurrentSustenance() end),
                 hydration = hc and U.try(function() return hc:GetCurrentHydration() end),
                 items = inv and U.try(function() return inv:GetNumFilledSlots() end) }
    end
    local before = read()
    local a = args.args or {}
    local ok, err = pcall(function() return cm[args.fn](cm, table.unpack(a)) end)
    local after = read()
    return { ok = ok, error = (not ok) and tostring(err) or nil, fn = args.fn, before = before, after = after }
end

return M

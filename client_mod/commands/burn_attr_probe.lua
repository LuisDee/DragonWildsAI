-- Read-only: the game's own chance to burn food at each power level for HIS pawn (Dominion float attributes
-- ChanceToBurnFoodLevel1..6, read through UAttributeFunctionLibrary.BP_TryGetFloatAttributeValue). No writes, no RPCs.
-- Output: client_io/out/burn_attr_probe.json (via the runner's return value).
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()
local function dump(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[tostring(k)] = (type(v) == "userdata" or type(v) == "table") and tostring(v) or v end
    return o
end
return function(log)
    local pc
    local okp, pcs = pcall(FindAllOf, "BP_PlayerController_C")
    for _, c in ipairs(okp and pcs or {}) do if U.try(function() return c:IsLocalController() end) then pc = c end end
    local pawn = U.valid(pc) and U.try(function() return pc.Pawn end) or nil
    local lib = U.try(StaticFindObject, "/Script/Dominion.Default__AttributeFunctionLibrary")
    local out = { pawn = pawn and U.short(pawn), lib = U.valid(lib), levels = {} }
    if not (U.valid(lib) and pawn) then return out end
    for n = 1, 6 do
        local row = { level = n }
        local cls = U.try(StaticFindObject, "/Script/Dominion.ChanceToBurnFoodLevel" .. n)
        row.class = U.valid(cls)
        if U.valid(cls) then
            local v, f = {}, {}
            local ok, ret = pcall(function() return lib:BP_TryGetFloatAttributeValue(pawn, cls, -1.0, v, f) end)
            row.ok, row.ret, row.err = ok, (type(ret) ~= "userdata") and ret or tostring(ret), (not ok) and tostring(ret) or nil
            row.v, row.f = dump(v), dump(f)
        end
        out.levels[#out.levels + 1] = row
    end
    return out
end

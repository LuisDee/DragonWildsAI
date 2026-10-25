-- Canary for physics traces from UE4SS Lua (DEV server only, read-only), before the client-side
-- local planner (client_mod/scripts/move.lua) uses them on Claude's live client.
--   debug_run {"module":"trace_probe","args":{"at":[x,y,z],"fn":"line"}}     KismetSystemLibrary:LineTraceSingle
--   debug_run {"module":"trace_probe","fn":"floor","args":{"at":[x,y,z]}}    CharacterMovement:K2_ComputeFloorDist
--   debug_run {"module":"trace_probe","fn":"bench","args":{"at":[x,y,z],"n":200}}   cost per trace
-- Question being answered: does UE4SS fill an FHitResult / FFindFloorResult out param passed as an
-- empty Lua table (as it fills a flat FVector table for K2_ProjectPointToNavigation), without the
-- struct-in-table crash (R15)? Only plain scalar tables are passed in.
local U = require("body.util")
local M = {}

local function ctx()
    for _, a in ipairs(U.find_all("GameStateBase", { skip_defaults = true })) do return a end
end
local function cm(t) return { X = t[1] * 100, Y = t[2] * 100, Z = t[3] * 100 } end

local function dump(t, depth)
    depth = depth or 0
    if type(t) ~= "table" or depth > 2 then
        if type(t) == "userdata" then
            local ok, v = pcall(function() return { t.X, t.Y, t.Z } end)
            return ok and v or tostring(t)
        end
        return t
    end
    local out = {}
    for k, v in pairs(t) do out[tostring(k)] = dump(v, depth + 1) end
    return out
end

local KSL
local function line(a, b, out)
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    -- (ctx, Start, End, TraceTypeQuery1=Visibility(0), bTraceComplex, ActorsToIgnore, DrawDebug None,
    --  OutHit, bIgnoreSelf, TraceColor, TraceHitColor, DrawTime)
    return KSL:LineTraceSingle(ctx(), a, b, 0, false, {}, 0, out, true,
        { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0.0)
end

function M.run(log, args)
    local p = cm(args.at)
    local a, b = { X = p.X, Y = p.Y, Z = p.Z + 500 }, { X = p.X, Y = p.Y, Z = p.Z - 2000 }
    local out = {}
    U.crumb(log, "trace_probe.LineTraceSingle", { at = args.at })
    local r = table.pack(pcall(line, a, b, out))
    local res = { pcall_ok = r[1], ret = tostring(r[2]), n = r.n, out = dump(out) }
    return res
end

function M.floor(log, args)
    local mc
    for _, c in ipairs(U.find_all("CharacterMovementComponent", { skip_defaults = true })) do
        local o = U.try(function() return c:GetOwner() end)
        if o and U.fullname(o):find("BP_PlayerCharacter_C") then mc = c; break end
    end
    if not mc then return { ok = false, reason = "no player-character movement component on this server" } end
    local p = cm(args.at)
    local out = {}
    U.crumb(log, "trace_probe.K2_ComputeFloorDist", { at = args.at })
    local r = table.pack(pcall(function() return mc:K2_ComputeFloorDist(p, 2000, 2000, 30, out) end))
    return { pcall_ok = r[1], ret = tostring(r[2]), out = dump(out), mc = U.short(mc) }
end

function M.bench(log, args)
    local p = cm(args.at)
    local n = args.n or 100
    local t0 = os.clock()
    local hits = 0
    for i = 1, n do
        local out = {}
        local x, y = p.X + (i % 10) * 50, p.Y + math.floor(i / 10) * 50
        if line({ X = x, Y = y, Z = p.Z + 500 }, { X = x, Y = y, Z = p.Z - 2000 }, out) then hits = hits + 1 end
    end
    return { n = n, hits = hits, cpu_ms = math.floor((os.clock() - t0) * 1000 * 100) / 100 }
end

return M

-- Opt-in only. Loading this file does not register hooks or query the engine.
-- A Lua pcall cannot contain a native crash; this ABI is not yet live-approved.
local M = {}
local PATH = "/Script/Engine.CharacterMovementComponent:K2_FindFloor"
local KEY = "floor_read:typed"
local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function primitive(fn, kind)
    local ok, v = pcall(fn)
    if not ok or type(v) ~= kind or (kind == "number" and not finite(v)) then return nil end
    return v
end
local function vector(v)
    if not v then return nil end
    local x = primitive(function() return v.X end, "number")
    local y = primitive(function() return v.Y end, "number")
    local z = primitive(function() return v.Z end, "number")
    if x == nil or y == nil or z == nil then return nil end
    return { X=x, Y=y, Z=z }
end
local function same(a,b) return a and b and a.X == b.X and a.Y == b.Y and a.Z == b.Z end
local function address(o)
    if not o or primitive(function() return o:IsValid() end, "boolean") ~= true then return nil end
    local n = primitive(function() return o:GetAddress() end, "number")
    if n and n ~= 0 then return n end
end
local function factory(hub, type_of)
    local owner = {}
    local function wrapped(p, expected)
        if type_of(p) ~= "userdata" or primitive(function() return p:type() end, "string") ~= expected then return nil end
        local ok, v = pcall(function() return p:get() end)
        if ok then return v end
    end
    local function typed(s)
        if type_of(s) ~= "userdata" or primitive(function() return s:type() end, "string") ~= "UScriptStruct" or
            primitive(function() return s:IsValid() end, "boolean") ~= true then return false end
        local n = primitive(function() return s:GetStructAddress() end, "number")
        return n ~= nil and n ~= 0
    end
    local function fields(s)
        if not typed(s) then return nil end
        local out = {}
        for _, k in ipairs({"bBlockingHit", "bWalkableFloor", "bLineTrace", "FloorDist", "LineDist"}) do
            local kind = k:sub(1,1) == "b" and "boolean" or "number"
            local v = primitive(function() return s[k] end, kind)
            out[k] = {known = v ~= nil, value = v}
        end
        local ok, hit = pcall(function() return s.HitResult end)
        if ok and typed(hit) then
            out.hit = {}
            for _, k in ipairs({"bBlockingHit", "bStartPenetrating", "Distance"}) do
                local kind = k:sub(1,1) == "b" and "boolean" or "number"
                local v = primitive(function() return hit[k] end, kind)
                out.hit[k] = {known = v ~= nil, value = v}
            end
            for _, k in ipairs({"ImpactPoint", "ImpactNormal"}) do
                local v = vector((function() local good, x = pcall(function() return hit[k] end); if good then return x end end)())
                out.hit[k] = {known = v ~= nil, value = v}
            end
        else out.hit = {known = false} end
        return out
    end
    local function live(s)
        if rawget(_G,"DW_PAUSE") == true then return false end
        local ok, v = pcall(s.lifecycle)
        return ok and v == true and rawget(_G,"DW_PAUSE") ~= true
    end
    local function registry(s)
        return rawget(_G,"DWHookHub") == s.hubstate and s.hubstate.paths[PATH] == s.record and
            s.record and s.record.native == true and not s.record.pending and not s.record.error and not s.record.last_error and
            s.record.subs[KEY] == s.callback
    end
    local function init(opt)
        if type(opt) ~= "table" or opt.enabled ~= true or type(opt.lifecycle) ~= "function" then return nil, "not_enabled_or_lifecycle_missing" end
        if rawget(_G,"DW_PAUSE") == true then return nil, "paused" end
        local s = rawget(_G,"DWFloorReader")
        if s then
            if s.status ~= "ready" or s.hub ~= hub or s.owner ~= owner or not registry(s) then return nil, "registration_unavailable" end
            return s
        end
        s = {status="attempted", hub=hub, owner=owner, lifecycle=opt.lifecycle}
        _G.DWFloorReader = s
        if not live(s) then return nil, "lifecycle_unknown" end
        local h = hub._state(); local rec = h and h.paths and h.paths[PATH]
        if rawget(_G,"DWHookHub") ~= h or (rec and (type(rec.subs) ~= "table" or rec.subs[KEY] ~= nil or rec.pending or rec.error or rec.last_error)) then return nil, "hub_ambiguous" end
        -- Existing unregistered records are ambiguous; never cause a second native registration.
        if rec and rec.native ~= true then return nil, "hub_ambiguous" end
        s.hubstate = h
        s.callback = function(ctx, loc, result)
            local q = s.query
            if not q or not q.active then return end
            q.count = q.count + 1
            if q.busy or q.count ~= 1 then q.invalid = "callback_cardinality"; return end
            q.busy = true
            local ok, err = pcall(function()
                if not live(s) or not registry(s) or s.query ~= q then error("ownership_changed") end
                local object = wrapped(ctx,"RemoteUnrealParam")
                local location = wrapped(loc,"LocalUnrealParam")
                local output = wrapped(result,"LocalUnrealParam")
                if address(object) ~= q.component or not typed(location) or not same(vector(location),q.location) then error("correlation") end
                q.fields = fields(output)
                if not q.fields then error("typed_result_unknown") end
            end)
            q.busy = false
            if not ok then q.invalid = tostring(err) end
        end
        -- No native calls or yields between this identity check and on().
        if rawget(_G,"DW_PAUSE") == true or rawget(_G,"DWHookHub") ~= h or h.paths[PATH] ~= rec or (rec and rec.subs[KEY] ~= nil) then return nil, "hub_changed" end
        local ok, registered = pcall(hub.on, PATH, KEY, s.callback)
        local installed = h.paths[PATH]
        s.record = installed
        if not ok or not registered or not registry(s) then
            if rawget(_G,"DWHookHub") == h and h.paths[PATH] == installed and installed and installed.subs and installed.subs[KEY] == s.callback then
                hub.off(PATH,KEY)
            end
            return nil, "registration_failed_or_ambiguous"
        end
        s.status = "ready"
        return s
    end
    local function query(opt, component, location, remaining)
        if not finite(remaining) or remaining < 1 then return {status="unknown", reason="budget", consumed=0} end
        local loc = vector(location)
        if not loc then return {status="unknown", reason="location", consumed=0} end
        local s, why = init(opt)
        if not s then return {status="unknown",reason=why,consumed=0} end
        -- Each caller's lifecycle must be checked, including after module reload.
        if s.query then return {status="unknown",reason="busy_or_lifecycle",consumed=0} end
        s.lifecycle = opt.lifecycle
        if not live(s) or not registry(s) then return {status="unknown",reason="busy_or_lifecycle",consumed=0} end
        local id = address(component)
        if not id or not live(s) or not registry(s) then return {status="unknown",reason="component_or_lifecycle",consumed=0} end
        local q = {active=true, count=0, component=id, location=loc}
        s.query = q
        local ok = pcall(function() component:K2_FindFloor({X=loc.X,Y=loc.Y,Z=loc.Z},{}) end)
        q.active = false
        local valid = ok and q.count == 1 and not q.invalid and q.fields and s.query == q and live(s) and registry(s) and address(component) == id
        if s.query == q then s.query = nil end
        if not valid then return {status="unknown", reason=q.invalid or "query_or_lifecycle", consumed=1, callbacks=q.count} end
        return {status="observed", fields=q.fields, location=loc, consumed=1, callbacks=1}
    end
    local function cleanup()
        local s = rawget(_G,"DWFloorReader")
        if not s or s.hub ~= hub or s.owner ~= owner then return false, "owner_unknown" end
        if s.query then return false, "query_active" end
        if rawget(_G,"DW_PAUSE") == true then return false, "paused" end
        if rawget(_G,"DWHookHub") ~= s.hubstate or not s.record or
            s.hubstate.paths[PATH] ~= s.record or not s.record.subs or
            s.record.subs[KEY] ~= s.callback then return false, "ownership_changed" end
        hub.off(PATH, KEY)
        s.status = "closed"
        return true
    end
    return query, cleanup
end
function M.new(hub) return factory(hub, type) end
-- Offline fake parameters only; production callers use new().
function M._new_for_test(hub, type_of) return factory(hub, type_of) end
return M

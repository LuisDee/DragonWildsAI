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
    -- The caller must permanently invalidate its predicate after any unverified
    -- world/pawn/operation boundary; pause alone is not a lifecycle epoch.
    local function live(s)
        if rawget(_G,"DW_PAUSE") == true then return false end
        local ok, v = pcall(s.lifecycle)
        return ok and v == true and rawget(_G,"DW_PAUSE") ~= true
    end
    local function registry(s)
        return type(s.hubstate) == "table" and type(s.hubstate.paths) == "table" and rawget(_G,"DWFloorReader") == s and rawget(_G,"DWHookHub") == s.hubstate and
            s.hubstate.paths[PATH] == s.record and s.record and s.record.native == true and
            not s.record.pending and not s.record.error and not s.record.last_error and
            type(s.record.subs) == "table" and s.record.subs[KEY] == s.callback
    end
    local function acquire(opt)
        if type(opt) ~= "table" or opt.enabled ~= true or opt.continuity_verified ~= true or type(opt.lifecycle) ~= "function" then
            return nil, "not_enabled_or_lifecycle_missing"
        end
        if rawget(_G,"DW_PAUSE") == true then return nil, "paused" end
        local s = rawget(_G,"DWFloorReader")
        local rec, h
        if s then
            if type(s) ~= "table" or s.version ~= 2 or s.owner ~= owner or s.hub ~= hub or s.status ~= "closed" or s.query then
                return nil, "registration_unavailable"
            end
            h, rec = s.hubstate, s.record
            if type(h) ~= "table" or type(h.paths) ~= "table" or rawget(_G,"DWHookHub") ~= h or h.paths[PATH] ~= rec or not rec or rec.native ~= true or
                rec.pending or rec.error or rec.last_error or type(rec.subs) ~= "table" or rec.subs[KEY] ~= nil then
                return nil, "hub_ambiguous"
            end
            s.status = "acquiring"
        else
            s = {version=2, status="attempted", hub=hub, owner=owner}
            _G.DWFloorReader = s -- durable before any attempt or reentrant lifecycle predicate
            h = hub._state(); rec = type(h) == "table" and type(h.paths) == "table" and h.paths[PATH] or nil
            if type(h) ~= "table" or type(h.paths) ~= "table" or rawget(_G,"DWHookHub") ~= h or (rec and (type(rec.subs) ~= "table" or rec.subs[KEY] ~= nil or rec.pending or rec.error or rec.last_error or rec.native ~= true)) then
                return nil, "hub_ambiguous"
            end
            s.hubstate = h
            s.status = "acquiring"
        end
        local lease = {}
        s.lease, s.lifecycle = lease, opt.lifecycle
        if not live(s) or rawget(_G,"DWFloorReader") ~= s or s.status ~= "acquiring" or s.lease ~= lease then
            s.status = "failed"; return nil, "lifecycle_unknown"
        end
        local callback
        callback = function(ctx, loc, result)
            local q = s.query
            if not q or not q.active then return end
            q.count = q.count + 1
            if q.busy or q.count ~= 1 then q.invalid = "callback_cardinality"; return end
            q.busy = true
            local ok, err = pcall(function()
                if s.status ~= "ready" or s.lease ~= lease or not registry(s) or not live(s) or not registry(s) or s.query ~= q or q.lease ~= lease then error("ownership_changed") end
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
        s.callback = callback
        -- No native call or yield between the final exact record check and on.
        if rawget(_G,"DW_PAUSE") == true or rawget(_G,"DWFloorReader") ~= s or s.status ~= "acquiring" or s.lease ~= lease or
            rawget(_G,"DWHookHub") ~= h or h.paths[PATH] ~= rec or (rec and (rec.native ~= true or rec.pending or rec.error or rec.last_error or type(rec.subs) ~= "table" or rec.subs[KEY] ~= nil)) then
            s.status = "failed"; return nil, "hub_changed"
        end
        local ok, registered = pcall(hub.on, PATH, KEY, callback)
        local installed = h.paths[PATH]
        s.record = installed
        if not ok or not registered or s.status ~= "acquiring" or s.lease ~= lease or not registry(s) or
            not live(s) or s.status ~= "acquiring" or s.lease ~= lease or not registry(s) then
            if rawget(_G,"DW_PAUSE") ~= true and rawget(_G,"DWHookHub") == h and h.paths[PATH] == installed and
                installed and installed.subs and installed.subs[KEY] == callback then hub.off(PATH,KEY) end
            s.status = "failed"
            return nil, "registration_failed_or_ambiguous"
        end
        s.status = "ready"
        return lease
    end
    local function query(opt, component, location, remaining)
        if not finite(remaining) or remaining < 1 then return {status="unknown", reason="budget", consumed=0} end
        local loc = vector(location)
        if not loc then return {status="unknown", reason="location", consumed=0} end
        local s = rawget(_G,"DWFloorReader")
        local lease = type(opt) == "table" and opt.lease or nil
        if type(s) ~= "table" or s.version ~= 2 or s.owner ~= owner or s.hub ~= hub or s.status ~= "ready" or not lease or s.lease ~= lease then
            return {status="unknown",reason="lease_unavailable",consumed=0}
        end
        if s.query then return {status="unknown",reason="busy_or_lifecycle",consumed=0} end
        if not registry(s) then return {status="unknown",reason="busy_or_lifecycle",consumed=0} end
        if not live(s) then if s.status == "ready" and s.lease == lease then s.status="closing" end; return {status="unknown",reason="busy_or_lifecycle",consumed=0} end
        if s.status ~= "ready" or s.lease ~= lease or not registry(s) then return {status="unknown",reason="busy_or_lifecycle",consumed=0} end
        local id = address(component)
        if s.status ~= "ready" or s.lease ~= lease or not registry(s) then return {status="unknown",reason="component_or_lifecycle",consumed=0} end
        local still_live = live(s)
        if not id or not still_live then
            if not still_live and s.status == "ready" then s.status="closing" end
            return {status="unknown",reason="component_or_lifecycle",consumed=0}
        end
        if s.status ~= "ready" or s.lease ~= lease or not registry(s) then return {status="unknown",reason="component_or_lifecycle",consumed=0} end
        local q = {active=true, count=0, component=id, location=loc, lease=lease}
        s.query = q
        local ok = pcall(function() component:K2_FindFloor({X=loc.X,Y=loc.Y,Z=loc.Z},{}) end)
        q.active = false
        local valid = ok and q.count == 1 and not q.invalid and q.fields and s.query == q and s.status == "ready" and s.lease == lease and registry(s) and live(s) and registry(s) and address(component) == id
        valid = valid and q.count == 1 and not q.invalid and s.query == q and q.active == false and s.status == "ready" and s.lease == lease and registry(s) and live(s) and registry(s) and
            s.query == q and s.status == "ready" and s.lease == lease and q.count == 1 and not q.invalid
        if s.query == q then s.query = nil end
        if not valid then
            if s.status == "ready" and s.lease == lease and registry(s) and not live(s) and s.status == "ready" and s.lease == lease and registry(s) then s.status="closing" end
            return {status="unknown", reason=q.invalid or "query_or_lifecycle", consumed=1, callbacks=q.count}
        end
        return {status="observed", fields=q.fields, location=loc, consumed=1, callbacks=1}
    end
    local function cleanup(lease)
        local s = rawget(_G,"DWFloorReader")
        if type(s) ~= "table" or s.version ~= 2 or s.hub ~= hub or s.owner ~= owner or not lease or s.lease ~= lease then return false, "owner_unknown" end
        if s.query then return false, "query_active" end
        if s.status ~= "ready" and s.status ~= "closing" then return false, "registration_unavailable" end
        s.status = "closing" -- invalidate before any cleanup, even when paused
        if rawget(_G,"DW_PAUSE") == true then return false, "paused" end
        if rawget(_G,"DWHookHub") ~= s.hubstate or not s.record or s.hubstate.paths[PATH] ~= s.record or
            s.record.native ~= true or s.record.pending or s.record.error or s.record.last_error or
            type(s.record.subs) ~= "table" or s.record.subs[KEY] ~= s.callback then return false, "ownership_changed" end
        hub.off(PATH, KEY)
        if rawget(_G,"DWFloorReader") ~= s or rawget(_G,"DWHookHub") ~= s.hubstate or s.hubstate.paths[PATH] ~= s.record or
            s.record.subs[KEY] ~= nil or s.status ~= "closing" or s.lease ~= lease then return false, "ownership_changed" end
        s.lease, s.lifecycle, s.callback = nil, nil, nil
        s.status = "closed"
        return true
    end
    return query, cleanup, acquire
end
function M.new(hub) return factory(hub, type) end
-- Offline fake parameters only; production callers use new().
function M._new_for_test(hub, type_of) return factory(hub, type_of) end
return M

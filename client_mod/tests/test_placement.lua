-- Offline tests for client_mod/scripts/placement.lua (the shared placement loop, build review finding 13).
-- Run: lua client_mod/tests/test_placement.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
local P = assert(loadfile(root .. "/client_mod/scripts/placement.lua"))()

-- a flat world at z = 0, with an optional pit (no ground) and a roof
local function env(opts)
    opts = opts or {}
    local e = { aims = {}, me_cm = opts.me or { X = 0, Y = 0, Z = 0 }, plist = opts.players or {} }
    e.trace = function(a, b)
        if b.Z > a.Z then -- upward clearance / line of sight: blocked under the roof
            if opts.roof and math.abs(a.X - opts.roof[1] * 100) < 100 and math.abs(a.Y - opts.roof[2] * 100) < 100 then return true, {} end
            return false, {}
        end
        if opts.pit and math.abs(a.X - opts.pit[1] * 100) < 400 and math.abs(a.Y - opts.pit[2] * 100) < 400 then return false, {} end
        return true, { ImpactPoint = { Z = 0 }, ImpactNormal = { Z = 1 } }
    end
    e.me = function() return e.me_cm end
    e.players = function() return e.plist end
    e.aim = function(p) e.aims[#e.aims + 1] = p; e.aimed = p; e.aim_n = (e.aim_n or 0) + 1; return 3 end
    e.read = function() return opts.read and opts.read(e) or nil end
    return e
end
local function run(c, t0, n, dt)
    local t = t0 or 0
    for _ = 1, n or 200 do
        t = t + (dt or 0.1)
        local r = c:step(t)
        if r then return r, t end
    end
end

-- 1. spots around a centre: the exact point first, ring points, footprint spacing used for the 3x3
local e = env()
local sp = P.spots(e, { 5, 0, 0 }, {})
check("spots: exact centre first, 1 + 2 rings of 8", #sp == 17 and sp[1].exact == true and sp[1].position[1] == 5, #sp)
-- a player standing on the centre: skipped as OUR reason (never the game's Overlapping)
e = env({ players = { { name = "Luis", position = { 5, 0, 0 } } } })
local sp2, skipped = P.spots(e, { 5, 0, 0 }, {})
check("player in spot: skipped with why=player_in_spot", skipped[1] and skipped[1].why == "player_in_spot" and skipped[1].exact and sp2[1] and not sp2[1].exact)
-- standoff: spots that would contain ME are skipped
e = env()
local sp3, sk3 = P.spots(e, { 0.5, 0, 0 }, { standoff_m = 3 })
check("standoff: my own spot skipped as i_am_in_spot", sk3[1] and sk3[1].why == "i_am_in_spot")
-- a pit: no ground under the 3x3 -> dropped; a roof over the point -> exact skipped as covered
e = env({ roof = { 5, 0 } })
local sp4, sk4 = P.spots(e, { 5, 0, 0 }, {})
check("roof over the asked point: skipped as covered", sk4[1] and sk4[1].why == "covered" and not sp4[1].exact)

-- 2. checker: press only when the game says valid, on target, fresh
e = env({ read = function(ev)
    local s = (ev.aim_n or 0) <= 2 and "Overlapping" or "Valid"
    return { valid = s == "Valid", why = s ~= "Valid" and s or nil, position = ev.aimed, fresh = true }
end })
local c = P.checker(e, P.spots(e, { 5, 0, 0 }, {}), {})
local r = run(c)
check("first spot rejected twice (Overlapping) -> second spot pressed", r and r.press and not r.spot.exact and #r.rejects == 1 and r.rejects[1].why == "Overlapping",
    r and (r.press and "press" or r.why))

-- off target: valid preview far from the spot is never pressed
e = env({ read = function(ev) return { valid = true, position = { ev.aimed[1] + 4, ev.aimed[2], 0 }, fresh = true } end })
c = P.checker(e, { { position = { 5, 0, 0 } } }, {})
r = run(c)
check("valid but off target -> no press, reject preview_off_target", r.give_up and r.rejects[1].why == "preview_off_target", r.why)

-- stale: a Valid read not newer than the latest aim never authorises a press
e = env({ read = function(ev) return { valid = true, position = ev.aimed, fresh = false } end })
c = P.checker(e, { { position = { 5, 0, 0 } } }, {})
r = run(c)
check("stale valid (older than the aim) -> no press", r.give_up and not r.press)

-- unreadable: build's rule = no press ever; spells' old rule = press once
e = env({ read = function() return nil end })
c = P.checker(e, { { position = { 5, 0, 0 } }, { position = { 6, 0, 0 } } }, {})
r = run(c)
check("unreadable preview (build): never pressed, gives up preview_unreadable", r.give_up and r.why == "preview_unreadable" and not r.press, r.why)
c = P.checker(e, { { position = { 5, 0, 0 } } }, { on_unreadable = "press_once" })
r = run(c)
check("unreadable preview (spells' rule): presses once", r.press and r.preview == "unreadable")

-- every spot refused -> give_up with the game's reasons; common_reason names the commonest
e = env({ read = function(ev) return { valid = false, why = "NeedsFoundation", position = ev.aimed, fresh = true } end })
c = P.checker(e, P.spots(e, { 5, 0, 0 }, { around_m = { 2 }, around_n = 4 }), {})
r = run(c, 0, 500)
local why, n = P.common_reason(r.rejects)
check("all refused -> give_up all_rejected; commonest game reason", r.give_up and r.why == "all_rejected" and why == "NeedsFoundation" and n == 5, tostring(r.why) .. " " .. tostring(n))

-- budget
c = P.checker(e, P.spots(e, { 5, 0, 0 }, {}), { budget_s = 1 })
r = run(c, 0, 500)
check("budget bounds the search", r.give_up and r.why == "budget")

-- on_reject hook can add spots (spells' ground spots)
local added = false
e = env({ read = function(ev) if ev.aimed[1] == 9 then return { valid = true, position = ev.aimed, fresh = true } end
    return { valid = false, why = "GroundNotFlat", position = ev.aimed, fresh = true } end })
c = P.checker(e, { { position = { 5, 0, 0 } } }, { on_reject = function(rej, ch)
    if not added then added = true; ch.spots[#ch.spots + 1] = { position = { 9, 0, 0 } } end end })
r = run(c)
check("on_reject may add spots", r.press and r.spot.position[1] == 9)

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)

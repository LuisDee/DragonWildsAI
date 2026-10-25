-- Calibrate melee hit shapes against a real target (the coordinator's plan, 2026-10-25): teleport the
-- puppet to a grid of distances and yaw offsets around a target, swing ONE attack, record contact.
-- Contact sensors: the tool-gate hooks (ModifyDamage fires on contact even when the gate zeroes the
-- damage) and the server's damage cache (Multicast_SendDamageCacheData). No emulated damage, so a
-- standing tree stays intact and can be reused. Read-only apart from teleport/rotate/swing.
--   debug_run {module="reach_calib", args={action="start", kind="chop"|"overhead"|"mine",
--              target_class="FellableTree", match="Tree_", dists={80,110,140,170}, deltas={-75,-45,-15,15,45,75}}}
--   {action="status"} -> results so far;  {action="stop"}
-- delta = pawn yaw minus the bearing to the target (UE yaw, + = clockwise seen from above).
local U = require("body.util")
local M = {}

local G = rawget(_G, "__dw_reach_calib") or {}
rawset(_G, "__dw_reach_calib", G)

local SETS = {
    chop = { "/Game/Gameplay/Character/Player/Attacks/Axe/BP_Player_Axe_Woodcut1.BP_Player_Axe_Woodcut1_C",
             "/Game/Gameplay/Character/Player/Attacks/Axe/PA_Attack_Hatchet.Default__PA_Attack_Hatchet_C", 1400 },
    overhead = { "/Game/Gameplay/Character/Player/Attacks/Axe/BP_Player_Axe_Woodcut2.BP_Player_Axe_Woodcut2_C",
                 "/Game/Gameplay/Character/Player/Attacks/Axe/PA_Attack_Hatchet_Special.Default__PA_Attack_Hatchet_Special_C", 1700 },
    mine = { "/Game/Gameplay/Character/Player/Attacks/Pickaxe/BP_Player_Pickaxe_Mine1.BP_Player_Pickaxe_Mine1_C",
             "/Game/Gameplay/Character/Player/Attacks/Pickaxe/PA_Attack_Pickaxe.Default__PA_Attack_Pickaxe_C", 1700 },
}

local function root()
    local dc = package.loaded["debug_cmds"]
    local d = dc and dc.dirs and dc.dirs[1]
    return d and d:gsub("[/\\]scripts$", "") or nil
end

local function load_body(name)
    local chunk = assert(loadfile(root() .. "/body/" .. name .. ".lua"))
    local m = chunk()
    package.loaded["body." .. name] = m
    return m
end

function M.stop()
    if G.loop then pcall(CancelDelayedAction, G.loop) end
    G.loop = nil
    return { stopped = true, n = G.results and #G.results or 0 }
end

function M.status()
    local rows = {}
    for _, r in ipairs(G.results or {}) do
        rows[#rows + 1] = string.format("d=%d delta=%+d -> %s (dist %.0f yawerr %.0f cache %d)", r.d, r.delta,
            r.contact and "HIT" or "miss", r.dist or -1, r.yaw_err or -1, r.cache or 0)
    end
    return { running = G.loop ~= nil, kind = G.kind, target = G.target_id, rows = rows }
end

function M.start(log, args)
    M.stop()
    local sense = load_body("sense")
    local hitcheck = load_body("hitcheck")
    hitcheck.arm(log)
    local puppet = require("body.puppet")
    local p = puppet.get()
    if not p then return { ok = false, err = "no puppet" } end
    local kind = args.kind or "chop"
    local set = SETS[kind]
    local atk, act = U.find_object(set[1]), U.find_object(set[2])
    if not (atk and act) then return { ok = false, err = "attack set not loaded" } end
    local spec = { class = args.target_class or "FellableTree", match = args.match or "Tree_", filter = args.filter or "standing" }
    local here = U.loc(p)
    if spec.class == "FellableTree" then sense.convert_foliage(log, p, here, (args.radius_m or 15) * 100) end
    local e
    if args.target then
        for _, x in ipairs(sense.census(spec, { origin = here, radius_cm = 5000 })) do if x.id == args.target then e = x end end
    else
        e = sense.nearest(spec, { origin = here, radius_cm = (args.radius_m or 15) * 100 })
    end
    if not e then return { ok = false, err = "no target" } end
    local c = U.controller_of(p)
    if c then U.call(log, "reach_calib.K2_ClearFocus", {}, function() c:K2_ClearFocus() end) end
    local tloc = e.loc
    if args.aim then tloc = sense.aim(e.actor, here) or e.loc end -- logs: nearest point of the axis
    local base = math.deg(math.atan(here.Y - tloc.Y, here.X - tloc.X)) -- side of the target we test on
    local z = here.Z
    local grid = {}
    for _, d in ipairs(args.dists or { 80, 110, 140, 170 }) do
        for _, dl in ipairs(args.deltas or { -75, -45, -15, 15, 45, 75 }) do grid[#grid + 1] = { d = d, delta = dl } end
    end
    G.results, G.kind, G.target_id, G.i, G.phase, G.t = {}, kind, e.id, 1, "place", 0
    local target = e.actor
    local cur
    G.loop = LoopInGameThreadWithDelay(250, function()
        G.t = G.t + 250
        if G.i > #grid then
            log.event("reach_calib_done", M.status())
            pcall(CancelDelayedAction, G.loop); G.loop = nil
            return
        end
        if not U.alive(target) then -- reverted to foliage: find it again at the same spot
            local r = sense.relocate(log, p, spec, tloc, 200, spec.class == "FellableTree")
            if r then target = r.actor end
        end
        local g = grid[G.i]
        if G.phase == "place" then
            local pos = { X = tloc.X + math.cos(math.rad(base)) * g.d, Y = tloc.Y + math.sin(math.rad(base)) * g.d, Z = z }
            local yaw = (base + 180) + g.delta -- facing the target is base+180
            U.call(log, "reach_calib.K2_TeleportTo", { d = g.d, delta = g.delta }, function()
                p:K2_TeleportTo(pos, { Pitch = 0, Yaw = yaw, Roll = 0 })
            end)
            cur = { yaw = yaw, placed = G.t }
            G.phase = "swing"
        elseif G.phase == "swing" and G.t - cur.placed >= 750 then
            U.call(log, "reach_calib.K2_SetActorRotation", { yaw = cur.yaw }, function()
                p:K2_SetActorRotation({ Pitch = 0, Yaw = cur.yaw, Roll = 0 }, false)
            end)
            local pl = U.loc(p)
            local f = U.forward(p)
            local bearing = math.deg(math.atan(tloc.Y - pl.Y, tloc.X - pl.X))
            cur.dist = U.dist2d(pl, tloc)
            cur.yaw_err = (math.deg(math.atan(f.Y, f.X)) - bearing + 540) % 360 - 180
            cur.seq = hitcheck.seq()
            cur.swung = G.t
            U.call(log, "reach_calib.BP_PerformAttack", { d = g.d, delta = g.delta }, function()
                p.PlayerMeleeAttackComponent:BP_PerformAttack(atk, { Data = act, PlayerOwner = p, EquipmentHand = 1,
                                                                    ActionInputType = 0, DesiredActionTarget = target })
            end)
            G.phase = "read"
        elseif G.phase == "read" and G.t - cur.swung >= set[3] then
            local evs = hitcheck.since(U.short(p), cur.seq)
            local mod = false
            for _, ev in ipairs(evs) do if ev.fn == "ModifyDamage" then mod = true end end
            local cache = hitcheck.cache_hits(U.short(p), cur.seq)
            local r = { d = g.d, delta = g.delta, dist = cur.dist, yaw_err = cur.yaw_err, contact = mod or #cache > 0,
                        gate = mod, cache = #cache, cache_first = cache[1] }
            G.results[#G.results + 1] = r
            log.event("reach_calib", r)
            G.i, G.phase = G.i + 1, "place"
        end
    end)
    return { ok = true, kind = kind, target = e.id, target_loc = U.to_wire(tloc), origin = U.to_wire(e.loc), points = #grid,
             cache_hook = hitcheck.cache_armed() }
end

function M.run(log, args)
    args = args or {}
    if args.action == "start" then return M.start(log, args) end
    if args.action == "stop" then return M.stop() end
    return M.status()
end

return M

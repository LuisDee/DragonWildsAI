-- fishing: FISHING on Claude's own client (M3 every-skill coverage; design docs/design/every-skill-coverage.md §4),
-- through the game's own client paths only:
--
--   spots   the game's fishing nodes (C++ class AFishingNodeV2, found by class family, never by name): position,
--           DisplayNameText, CompatibleToolCategory (gameplay tag, e.g. "...Fishing.Net" / "...Fishing.Rod"),
--           PowerLevel, depleted / blocked / in use (the node's own IsDepleted/IsBlocked/IsInUse).
--   tool    a carried item whose item Category tag IS the node's CompatibleToolCategory (data, not names);
--           equipped through inventory.equip (the hotbar key or the inventory UI's use), verified held.
--   net     stand inside the node (the game's StandingInFishingNode requirement) and HOLD the held item's
--           primary input ("Trawl (Hold)", PA_CastNet); verified by the bag gaining items (fish or junk), the
--           stamina spent (10 per trawl) and the XP rows changing.
--   rod     stand on the bank a few metres from the node, face it, HOLD primary to charge (PA_Cast_Fishing) and
--           release; the charge is solved from the component's own Settings (TimeToFullyChargeRod,
--           RodCastLaunchAngle, RodChargeFractionToProjectileSpeed) and corrected from where the bob really
--           landed (InternalState.HitLocation), learned per rod. Then wait for the bite and FIGHT: read the
--           replicated FightingFishInternalState.FishSwimmingState every frame and hold the component's own
--           input actions (Settings.RodFishingInputActions: PullRodLeft/PullRodRight opposite to the swim,
--           Reel while it rests). The verdict is the replicated InternalState.FishingResult +
--           AwardedItemData, confirmed by the bag delta.
--   Never a server RPC (the component sends its own Server_Notify* from our inputs), never a state write.
--
-- Precedent (search record in the design note): mineflayer bot.fish (equip rod, look at water, activate, wait
-- for the bobber event, verify the collected item); the Dragonwilds wiki/guides for the controls (A/D against
-- the fish, hold LMB to reel; nets hold LMB inside a net spot); Palworld UE4SS fishing mods (which skip the
-- minigame by calling the success RPC; rejected here: real inputs only).
--
-- The MODEL decides when and where to fish; `fish` only runs the frame-coupled loop (approach, aim, charge,
-- fight) that the model cannot do at tick speed (PRINCIPLES 4b), and reports every failure with one truthful
-- sentence (data.detail) and a why code.
-- W = the engine touches (tests replace them). Hot-reload safe: live state in _G.DWFishing.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.cfg = {
    radius_m = 60, max_radius_m = 120,
    node_class = "FishingNodeV2",      -- C++ base class of every fishing spot (dump l.10840; live: BP_FishingNodeV2_Net/Rod_*)
    net_tol_m = 1.0,                    -- net: stand within this of the node centre (inside its collider)
    rod_min_m = 6, rod_max_m = 18,      -- rod: cast from this far (the live curve throws ~6-29 m; min distance [UNVERIFIED])
    rod_pref_m = 10,
    stand_points = 8,                   -- candidate bank spots on the circle around a rod node
    stand_tol_m = 1.5,
    approach_timeout_s = 60,
    equip_wait_s = 4, equip_repress_s = 1.5,
    trawl_hold_s = 2.5,                 -- net: hold the trawl this long
    trawl_wait_s = 5,                   -- then wait this long for the catch to land in the bag
    trawl_stamina = 12,                 -- a trawl costs 10 stamina (wiki): wait below this
    stamina_wait_s = 20,
    charge_full_s = 3.0,                -- fallback for Settings.TimeToFullyChargeRod (live dev 2026-10-26: 3.0)
    launch_deg = 30,                    -- fallback for Settings.RodCastLaunchAngle (live: 30)
    gravity_cm = 980,
    speed_min_cm = 800, speed_max_cm = 1800, -- fallback charge->speed line (live curve: 800 / 1460 @0.5 / 1800)
    water_drop_cm = 120,                -- the water surface is about this far below the hands (until learned)
    cast_wait_s = 6,                    -- after release: the cast result must arrive within this
    misses_per_stand = 3,               -- then try another bank spot
    bite_wait_s = 45,
    fight_max_s = 90,
    swap_check_s = 2.0,                 -- pull-direction self-check window
    result_wait_s = 6,
    lease_s = 5,
    decide_s = 0.1,
    timeout_base_s = 180, timeout_per_catch_s = 120, timeout_max_s = 1700,
    max_count = 50,
    spot_rows = 6,
    extras_ttl_s = 5,
}

-- enums (Dominion_enums.hpp 26161880)
M.ACTIVITY = { [0] = "none", [1] = "casting", [2] = "waiting_for_bite", [3] = "fighting" } -- EFishingComponentInternalActivity
M.CAST = { [0] = "missed_nothing", [1] = "missed_land", [2] = "missed_water", [3] = "hit_node", [4] = "none" } -- EFishingRodCastResult
M.RESULT = { [0] = "escaped", [1] = "junk", [2] = "fish", [3] = "none" } -- ECatchableFishResult
M.SWIM = { [0] = "resting", [1] = "left", [2] = "right" } -- ECatchableFishSwimmingState

-- ------------------------------------------------------------------ state + helpers
local function C()
    local c = rawget(_G, "DWFishing")
    if not c then
        c = { gen = 0, learned = {}, counts = { jobs = 0, casts = 0, catches = 0, junk = 0, escaped = 0, trawls = 0 }, lines = {} }
        _G.DWFishing = c
    end
    return c
end
M._state = C

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function say(log, msg)
    if log then pcall(log, "fishing: " .. msg) end
    local c = C()
    c.lines[#c.lines + 1] = os.date("!%H:%M:%S ") .. msg
    if #c.lines > 40 then table.remove(c.lines, 1) end
end
local function r1(x) return type(x) == "number" and math.floor(x * 10 + 0.5) / 10 or nil end
local function d2(a, b) if not (a and b) then return math.huge end return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function text(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end
local function num(v) return type(v) == "number" and v or nil end

M.mods = {}
function M.set_modules(t) for k, v in pairs(t) do M.mods[k] = v end end
local function mod(name)
    if not M.mods[name] then
        local ok, m = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/" .. name .. ".lua"))() end)
        if ok then M.mods[name] = m end
    end
    return M.mods[name]
end
local function mcall(name, fn, ...)
    local m = mod(name)
    if not (m and m[fn]) then return nil, "no " .. name .. "." .. fn end
    local ok, r = pcall(m[fn], ...)
    if not ok then return nil, tostring(r) end
    return r
end

-- ------------------------------------------------------------------ pure: data -> decisions
-- The fishing method of a node or tool, from its gameplay tag's last segment ("Item.Equipment.Tool.Fishing.Net"
-- -> "net"). Data-derived: a new tool family shows up as its own method word.
function M.method_of(tag)
    if type(tag) ~= "string" or tag == "" then return nil end
    return (tag:match("([%w_]+)$") or tag):lower()
end

-- Does an item category tag fit a node's compatible-tool tag? Equal, or one is a child tag of the other.
function M.tag_fits(item_tag, node_tag)
    if type(item_tag) ~= "string" or type(node_tag) ~= "string" or item_tag == "" or node_tag == "" then return false end
    if item_tag == node_tag then return true end
    return item_tag:sub(1, #node_tag + 1) == node_tag .. "." or node_tag:sub(1, #item_tag + 1) == item_tag .. "."
end

-- Rows -> spots near `me` (cm), nearest first, with the facts the model needs. rows: {id, pos, name, tag, level,
-- depleted, blocked, in_use}. opts: {radius_cm, method, include_unusable}.
function M.spots(rows, me, opts)
    opts = opts or {}
    local out = {}
    for _, r in ipairs(rows or {}) do
        local d = d2(me, r.pos)
        if d <= (opts.radius_cm or math.huge) then
            local s = { id = r.id, name = r.name, method = M.method_of(r.tag), tool_tag = r.tag, level = r.level,
                        depleted = r.depleted or nil, blocked = r.blocked or nil, in_use = r.in_use or nil,
                        distance_m = r1(d / 100), pos = r.pos }
            if (not opts.method or s.method == opts.method) and (opts.include_unusable or not (s.depleted or s.blocked)) then
                out[#out + 1] = s
            end
        end
    end
    table.sort(out, function(a, b) return (a.distance_m or 0) < (b.distance_m or 0) end)
    return out
end

-- The best carried tool for a node tag: highest power level from the item catalog (tools = weapons_data.items),
-- skipping broken ones. list = inventory.list. -> {entry, where, name, pl} | nil
function M.pick_tool(list, node_tag, tools)
    local best
    for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            if M.tag_fits(e.category, node_tag) and not e.broken then
                local p = tools and e.item and tools[e.item] or {}
                local pl = num(p.pl) or 0
                if not best or pl > best.pl then best = { entry = e, where = where, name = e.name or p.name or e.item, pl = pl } end
            end
        end
    end
    return best
end

-- Every carried tool of every fishing method (for "what can I fish with"). -> {method = name}
function M.tools_by_method(list, tags)
    local out = {}
    for _, tag in ipairs(tags or {}) do
        local m = M.method_of(tag)
        for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
            for _, e in ipairs((list or {})[where] or {}) do
                if m and not out[m] and M.tag_fits(e.category, tag) and not e.broken then out[m] = e.name or e.item end
            end
        end
    end
    return out
end

-- Horizontal range (cm) of a cast at launch speed v (cm/s), angle deg, landing dz below the launch point.
function M.range_of(v, deg, dz, g)
    g = g or M.cfg.gravity_cm
    local th = math.rad(deg)
    local vx, vz = v * math.cos(th), v * math.sin(th)
    local disc = vz * vz + 2 * g * math.max(dz or 0, -vz * vz / (2 * g))
    local t = (vz + math.sqrt(math.max(disc, 0))) / g
    return vx * t
end

-- Charge fraction (0..1] that throws the bob `dist_cm` away. P = {speed = fn(frac) -> cm/s, deg, dz, k} where k
-- is the learned correction (landed/predicted). Monotonic in the fraction: bisection. -> frac, predicted_cm
function M.charge_for(dist_cm, P)
    P = P or {}
    local cfg = M.cfg
    local speed = P.speed or function(f) return cfg.speed_min_cm + (cfg.speed_max_cm - cfg.speed_min_cm) * f end
    local deg, dz, k = P.deg or cfg.launch_deg, P.dz or cfg.water_drop_cm, P.k or 1
    local function rng(f) return M.range_of(speed(f), deg, dz) * k end
    local lo, hi = 0.05, 1.0
    if rng(hi) <= dist_cm then return hi, rng(hi) end
    if rng(lo) >= dist_cm then return lo, rng(lo) end
    for _ = 1, 30 do
        local mid = (lo + hi) / 2
        if rng(mid) < dist_cm then lo = mid else hi = mid end
    end
    local f = (lo + hi) / 2
    return f, rng(f)
end

-- Learn the per-rod correction from one cast: wanted distance vs where the bob landed. Bounded, smoothed.
function M.learn_cast(L, predicted_cm, landed_cm)
    L = L or { k = 1, n = 0 }
    if type(predicted_cm) ~= "number" or type(landed_cm) ~= "number" or predicted_cm <= 0 or landed_cm <= 0 then return L end
    local ratio = landed_cm / (predicted_cm / (L.k or 1)) -- the true multiplier this cast showed
    ratio = math.max(0.3, math.min(3.0, ratio))
    local w = (L.n or 0) == 0 and 1 or 0.5
    L.k = (L.k or 1) * (1 - w) + ratio * w
    L.n = (L.n or 0) + 1
    return L
end

-- Which fight input to hold for the observed swim state. swap = the learned "my left is the game's right".
-- -> "left" | "right" | "reel"
function M.fight_input(swim, swap)
    local s = M.SWIM[swim] or swim
    if s == "left" then return swap and "left" or "right" end
    if s == "right" then return swap and "right" or "left" end
    return "reel"
end

-- A stand point on the bank for a rod node: the circle of radius r around the node, the candidate i of n,
-- starting from the side facing `me`. -> {X, Y, Z}
function M.stand_point(node, me, r_cm, i, n)
    local base = math.atan(me.Y - node.Y, me.X - node.X)
    local k = i - 1
    local step = (2 * math.pi) / n
    local off = (k % 2 == 0 and 1 or -1) * math.floor((k + 1) / 2) * step -- 0, +1, -1, +2, -2 ...
    local a = base + off
    return { X = node.X + math.cos(a) * r_cm, Y = node.Y + math.sin(a) * r_cm, Z = me.Z }
end

-- Items gained between two count maps. -> {item = n}, total
function M.gains(c0, c1)
    local g, n = {}, 0
    for k, v in pairs(c1 or {}) do
        local d = v - ((c0 or {})[k] or 0)
        if d > 0 then g[k] = d; n = n + d end
    end
    return g, n
end

-- XP changes between two sense.me skill lists ({skill, level, xp}). -> {skill = {xp = +n, level = new?}}
function M.xp_delta(s0, s1)
    local by = {}
    for _, r in ipairs(s0 or {}) do if r.skill then by[r.skill] = r end end
    local out
    for _, r in ipairs(s1 or {}) do
        local a = r.skill and by[r.skill]
        if a and type(r.xp) == "number" and type(a.xp) == "number" and r.xp > a.xp then
            out = out or {}
            out[r.skill] = { xp = r1(r.xp - a.xp), level = (r.level ~= a.level) and r.level or nil }
        end
    end
    return out
end

-- ------------------------------------------------------------------ engine touches
local W = {}
M.W = W
local GS
function W.now(ctx)
    if M.clock then return M.clock() end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function() return GS:GetRealTimeSeconds(ctx) end)
    return ok and t or os.time()
end
function W.pc() return mcall("sense", "local_pc") end
function W.pawn(pc)
    if not U.valid(pc) then return nil end
    local p = U.try(function() return pc.Pawn end)
    return U.alive(p) and p or nil
end
function W.loc(a) return U.loc(a) end
function W.dead(pawn) return U.try(function() return pawn.HealthComponent:IsDead() end) == true end
function W.stamina(pawn) return num(U.try(function() return pawn.StaminaComponent:GetStamina() end)) end
-- The fishing nodes the client knows about, as plain rows (no UObjects leave this function except `actor`).
function W.nodes()
    local out = {}
    for _, a in ipairs(U.find_all(M.cfg.node_class, { skip_defaults = true }) or {}) do
        if U.alive(a) then
            local function b(fn, prop)
                local v = U.try(function() return a[fn](a) end)
                if v == nil then v = U.try(function() return a.NodeState[prop] end) end
                return v == true
            end
            out[#out + 1] = { id = U.short(a), actor = a, pos = U.loc(a), name = text(U.try(function() return a.DisplayNameText end)),
                tag = text(U.try(function() return a.CompatibleToolCategory.TagName end)),
                level = num(U.try(function() return a.PowerLevel end)),
                depleted = b("IsDepleted", "bDepleted"), blocked = b("IsBlocked", "bBlocked"),
                in_use = U.try(function() return a:IsInUse() end) == true }
        end
    end
    return out
end
function W.counts()
    local l = mcall("inventory", "list")
    if type(l) ~= "table" or l.ok == false then return nil, l end
    local c = {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs(l[where] or {}) do if e.item then c[e.item] = (c[e.item] or 0) + (e.count or 1) end end
    end
    return c, l
end
function W.skills() local me = mcall("sense", "me"); return type(me) == "table" and me.skills or nil end
function W.held_item(pawn)
    local inv = mod("inventory")
    local h = (inv and inv.held and U.try(inv.held, pawn)) or {}
    return h.right_item, h.left_item
end
function W.equip(log, item) return mcall("inventory", "equip", log, item) end
function W.tools() return (mcall("combat", "weapons") or {}).items or {} end
function W.actions(pawn) return mcall("combat", "actions", pawn) or {} end
-- The modal gate (input.lua): while build mode, a container screen or a non-gameplay input mode is open, the
-- use click places / casts / acts on that screen, so nothing is injected. -> nil | modal
function W.gate()
    local inp = mod("input")
    if not (inp and inp.gate) then return nil end
    local ok, m = pcall(inp.gate)
    return ok and m or nil
end
function W.inject(action)
    local inp = mod("input")
    if inp and inp.raw_inject then return inp.raw_inject(action) == true end
    local cb = mod("combat")
    local f = cb and (cb.inject or cb._inject)
    return f and f(action) or false
end
function W.face(pc, yaw, pitch) pcall(function() pc:SetControlRotation({ Pitch = pitch or 0, Yaw = yaw, Roll = 0 }) end) end
function W.go_to(log, pos_cm, tol_m, timeout_s)
    return mcall("move", "go_to", log, { pos_cm.X / 100, pos_cm.Y / 100, pos_cm.Z / 100 }, { tolerance_m = tol_m, timeout_s = timeout_s })
end
function W.move_status() return mcall("move", "status") or {} end
function W.move_stop(log) return mcall("move", "stop", log) end
-- The fishing component's replicated state + its own settings (read only).
function W.comp(pawn) local c = U.try(function() return pawn.FishingComponent end); return U.valid(c) and c or nil end
function W.fstate(comp)
    if not comp then return nil end
    local s = {
        activity = num(U.try(function() return comp.InternalState.CurrentActivity end)),
        session = num(U.try(function() return comp.InternalState.SessionId end)),
        changed_t = num(U.try(function() return comp.InternalState.TimeOfLastActivityChange end)),
        cast = num(U.try(function() return comp.InternalState.CastResult end)),
        result = num(U.try(function() return comp.InternalState.FishingResult end)),
        swim = num(U.try(function() return comp.FightingFishInternalState.FishSwimmingState end)),
        reel = num(U.try(function() return comp.FightingFishInternalState.ReelProgressFraction end)),
        my_stamina = num(U.try(function() return comp.FightingFishInternalState.PlayerStaminaFraction end)),
        fish_stamina = num(U.try(function() return comp.ReplicatedFishStaminaFraction end)),
    }
    local hit = U.try(function() return comp.InternalState.HitLocation end)
    if hit then s.hit = { X = num(U.try(function() return hit.X end)), Y = num(U.try(function() return hit.Y end)),
                          Z = num(U.try(function() return hit.Z end)) } end
    if s.hit and not (s.hit.X and s.hit.Y) then s.hit = nil end
    local award = U.try(function() return comp.InternalState.AwardedItemData end)
    if U.valid(award) then s.award = text(U.try(function() return award.Name end)) or U.short(award) end
    return s
end
function W.settings(comp)
    if not comp then return {} end
    local st = {}
    st.full_s = num(U.try(function() return comp.Settings.TimeToFullyChargeRod end))
    st.deg = num(U.try(function() return comp.Settings.RodCastLaunchAngle end))
    local curve = U.try(function() return comp.Settings.RodChargeFractionToProjectileSpeed end)
    if U.valid(curve) then
        local probe = num(U.try(function() return curve:GetFloatValue(1.0) end))
        if probe and probe > 0 then
            st.speed = function(f) return num(U.try(function() return curve:GetFloatValue(f) end)) or probe * f end
        end
    end
    local ia = U.try(function() return comp.Settings.RodFishingInputActions end)
    local function get(k) local a = ia and U.try(function() return ia[k] end); return U.valid(a) and a or nil end
    st.inputs = { left = get("PullRodLeftInputAction"), right = get("PullRodRightInputAction"), reel = get("ReelInputAction"),
                  cancel = get("CancelInputAction") }
    return st
end
function W.held_level(pawn)
    return num(U.try(function() return pawn.PlayerEquipmentComponent:GetHeldEquipmentDataRight().PowerLevel end))
end

-- ------------------------------------------------------------------ the job
local function result_of(J, ok, reason, data)
    data = data or {}
    data.method, data.spot, data.spot_name = J.method, J.spot and J.spot.id, J.spot and J.spot.name
    data.tool = J.tool and J.tool.name
    data.caught, data.junk, data.escaped, data.casts, data.trawls = J.caught, J.junk, J.escaped, J.casts, J.trawls
    data.want = J.want
    local gained = M.gains(J.inv0, J.inv_now or J.inv0)
    if next(gained) then data.gained = gained end
    data.xp = J.xp
    data.seconds = J.t and J.t0 and r1(J.t - J.t0) or nil
    return { ok = ok == true, reason = reason, data = data }
end

local function release_inputs(J) J.hold = nil end

local function finish(J, res)
    if J.done then return end
    J.done = true
    local c = C()
    if J.handle then pcall(CancelDelayedAction, J.handle) end
    J.handle = nil
    release_inputs(J)
    if not paused() then
        if J.moving then pcall(W.move_stop, J.log); J.moving = false end
        local s1 = W.skills()
        J.xp = M.xp_delta(J.skills0, s1) or J.xp
        if res and res.data then res.data.xp = J.xp end
    end
    J.result = res
    c.last = { result = res, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.job == J then c.job = nil end
    local arb = mod("arbiter")
    if arb and J.token and not J.released then J.released = true; pcall(arb.release, J.log, J.token, res.ok and "done" or res.reason) end
    say(J.log, string.format("done %s %s: %s", tostring(res.ok), tostring(res.reason or ""), tostring(res.data and res.data.detail or "")))
end

local function fail(J, reason, why, detail, extra)
    local d = extra or {}
    d.why, d.detail = why, detail
    return finish(J, result_of(J, false, reason, d))
end

local function set_phase(J, ph, note)
    J.phase, J.phase_t = ph, J.t
    J.phase_log[#J.phase_log + 1] = string.format("%.1f %s%s", (J.t or 0) - (J.t0 or 0), ph, note and (" " .. note) or "")
    if #J.phase_log > 30 then table.remove(J.phase_log, 1) end
    say(J.log, "phase " .. ph .. (note and (" " .. note) or ""))
end

local function catches(J) return (J.caught or 0) + (J.junk or 0) end

local function refresh_inv(J)
    local c = W.counts()
    if c then J.inv_now = c end
    return J.inv_now
end

-- the node row of our spot, fresh
local function spot_now(J)
    for _, r in ipairs(W.nodes()) do if r.id == J.spot.id then return r end end
    return nil
end

local function step_equip(J, pawn)
    local want = J.tool.entry.item
    local r, l = W.held_item(pawn)
    if r == want or l == want then return true end
    if J.t - J.phase_t > M.cfg.equip_wait_s then
        fail(J, "wrong_tool", "equip_failed", string.format("I tried to take out my %s but it didn't come out.", tostring(J.tool.name)))
        return false
    end
    if not J.equip_sent or J.t - J.equip_sent > M.cfg.equip_repress_s then
        J.equip_sent = J.t
        local res = W.equip(J.log, want)
        say(J.log, "equip " .. tostring(want) .. " -> " .. tostring(res and (res.via or res.reason)))
    end
    return false
end

local function start_move(J, pos, tol_m)
    J.goal, J.goal_tol = pos, tol_m
    local r = W.go_to(J.log, pos, tol_m, M.cfg.approach_timeout_s)
    J.moving, J.move_t = true, J.t
    return r and r.ok ~= false
end

-- -> "arrived" | "failed" | nil (still going)
local function move_done(J, me)
    if me and J.goal and d2(me, J.goal) <= (J.goal_tol or 1) * 100 + 30 then
        if J.moving then W.move_stop(J.log); J.moving = false end
        return "arrived"
    end
    local st = W.move_status() or {}
    local res = st.result or {}
    if st.mode == "idle" or st.status == "idle" or res.status then
        if res.status == "arrived" then J.moving = false; return "arrived" end
        if res.status == "failed" or res.status == "stopped" or (J.t - (J.move_t or J.t) > 2 and st.mode == "idle") then
            J.moving = false
            J.move_why = res.reason
            return "failed"
        end
    end
    if J.t - (J.move_t or J.t) > M.cfg.approach_timeout_s then J.moving = false; return "failed" end
    return nil
end

local function face_spot(J, pc, me)
    local p = J.spot.pos
    local yaw = math.deg(math.atan(p.Y - me.Y, p.X - me.X))
    W.face(pc, yaw, J.pitch or 0)
end

-- the node's state blocks fishing? -> reason, why, detail
local function spot_blocked(J)
    local r = spot_now(J)
    if not r then return "unknown_target", "spot_gone", string.format("The fishing spot (%s) is gone.", tostring(J.spot.name or "the spot")) end
    if r.depleted then return "nothing_in_range", "depleted", string.format("The %s is fished out for now.", tostring(r.name or "spot")) end
    if r.blocked then return "path_blocked", "blocked", string.format("Something is blocking the %s.", tostring(r.name or "spot")) end
    return nil
end

-- --- net: stand in the node, hold the trawl, count what lands in the bag
local function step_net(J, pawn, pc, me)
    if J.sub == "approach" then
        if not J.moving then start_move(J, J.spot.pos, M.cfg.net_tol_m) end
        local m = move_done(J, me)
        if m == "arrived" then J.sub = "trawl"; J.hold_until = nil
        elseif m == "failed" then
            -- walked as close as the ground allows: try from there (nets work only INSIDE the spot)
            if d2(me, J.spot.pos) <= 300 then J.sub = "trawl"; J.hold_until = nil
            else
                return fail(J, "path_blocked", "cant_reach_spot", string.format("I can't get into the %s; it's %.0f m away and I can't walk there.",
                    tostring(J.spot.name or "fishing spot"), d2(me, J.spot.pos) / 100))
            end
        end
        return
    end
    if J.sub == "trawl" then
        if J.hold_until == nil then
            local st = W.stamina(pawn)
            if st and st < M.cfg.trawl_stamina then
                if not J.rest_t then J.rest_t = J.t; say(J.log, "stamina low, resting") end
                if J.t - J.rest_t > M.cfg.stamina_wait_s then
                    return fail(J, "not_enough_resources", "no_stamina", "I'm out of stamina for trawling.")
                end
                return
            end
            J.rest_t = nil
            local b, why, detail = spot_blocked(J)
            if b then
                if catches(J) > 0 then return finish(J, result_of(J, true, nil, { why = why, detail = detail .. string.format(" I caught %d first.", catches(J)) })) end
                return fail(J, b, why, detail)
            end
            J.st0, J.c0 = st, refresh_inv(J)
            J.hold_until = J.t + M.cfg.trawl_hold_s
            J.hold, J.hold_stop = { J.acts.primary }, J.hold_until
            J.trawls = (J.trawls or 0) + 1
            C().counts.trawls = C().counts.trawls + 1
        end
        face_spot(J, pc, me)
        if J.t < J.hold_until then J.hold, J.hold_stop = { J.acts.primary }, J.hold_until; return end
        J.hold = nil
        J.sub, J.wait_t = "net_wait", J.t
        return
    end
    if J.sub == "net_wait" then
        local c1 = refresh_inv(J)
        local g, n = M.gains(J.c0, c1)
        if n > 0 then
            J.caught = (J.caught or 0) + n
            J.empty_trawls = 0
            local names = {}
            for k, v in pairs(g) do names[#names + 1] = k .. " x" .. v end
            say(J.log, "trawl caught " .. table.concat(names, ", "))
            J.sub, J.hold_until = "trawl", nil
            return
        end
        if J.t - J.wait_t < M.cfg.trawl_wait_s then return end
        local st = W.stamina(pawn)
        local spent = J.st0 and st and st < J.st0 - 3
        J.empty_trawls = (J.empty_trawls or 0) + 1
        say(J.log, string.format("trawl %d: nothing (stamina spent %s)", J.trawls, tostring(spent)))
        if not spent and J.empty_trawls >= 2 then
            -- the game didn't run the trawl at all: not inside the spot (its StandingInFishingNode requirement)
            if not J.walked_in then
                J.walked_in = true
                J.sub = "approach"
                start_move(J, J.spot.pos, 0.4)
                return
            end
            return fail(J, "verification_failed", "trawl_not_running",
                string.format("I hold my %s but nothing happens; I may not be standing inside the %s.", tostring(J.tool.name), tostring(J.spot.name or "spot")))
        end
        if J.empty_trawls >= 6 then
            return fail(J, "verification_failed", "nothing_caught", string.format("Six trawls in the %s brought nothing up.", tostring(J.spot.name or "spot")))
        end
        J.sub, J.hold_until = "trawl", nil
    end
end

-- --- rod: bank spot, charge, cast, wait, fight
local function rod_params(J)
    local L = C().learned[J.tool.entry.item] or { k = 1, n = 0 }
    return { speed = J.set.speed, deg = J.set.deg, dz = L.dz, k = L.k }, L
end

local function next_stand(J, me)
    J.stand_i = (J.stand_i or 0) + 1
    if J.stand_i > M.cfg.stand_points then return nil end
    return M.stand_point(J.spot.pos, J.origin or me, (J.rod_m or M.cfg.rod_pref_m) * 100, J.stand_i, M.cfg.stand_points)
end

local function step_rod(J, pawn, pc, me)
    local fs = W.fstate(J.comp) or {}
    local act = M.ACTIVITY[fs.activity or 0]
    if J.sub == "approach" then
        if not J.moving then
            local d = d2(me, J.spot.pos)
            if not J.stand_i and d >= M.cfg.rod_min_m * 100 and d <= M.cfg.rod_max_m * 100 then J.sub = "aim"; return end
            local p = next_stand(J, me)
            if not p then
                return fail(J, "path_blocked", "no_bank_spot", string.format("I can't find a spot on the bank %d m from the %s to cast from.",
                    J.rod_m or M.cfg.rod_pref_m, tostring(J.spot.name or "fishing spot")))
            end
            start_move(J, p, M.cfg.stand_tol_m)
        end
        local m = move_done(J, me)
        if m == "arrived" then J.sub = "aim"
        elseif m == "failed" then
            local d = d2(me, J.spot.pos)
            if d >= M.cfg.rod_min_m * 100 and d <= M.cfg.rod_max_m * 100 then J.sub = "aim" end -- close enough: try from here
        end
        return
    end
    if J.sub == "aim" then
        local b, why, detail = spot_blocked(J)
        if b then
            if catches(J) > 0 then return finish(J, result_of(J, true, nil, { why = why, detail = detail .. string.format(" I caught %d first.", catches(J)) })) end
            return fail(J, b, why, detail)
        end
        face_spot(J, pc, me)
        local P, L = rod_params(J)
        local dist = d2(me, J.spot.pos)
        local frac, pred = M.charge_for(dist, P)
        J.cast = { frac = frac, predicted = pred, want = dist, from = { X = me.X, Y = me.Y, Z = me.Z }, L = L }
        J.hold_until = J.t + frac * (J.set.full_s or M.cfg.charge_full_s)
        J.hold, J.hold_stop = { J.acts.primary }, J.hold_until -- starts on the next frame, ends on the exact frame
        J.casts = (J.casts or 0) + 1
        C().counts.casts = C().counts.casts + 1
        J.session0, J.changed0, J.saw_casting = fs.session, fs.changed_t, false
        J.sub = "charge"
        say(J.log, string.format("cast %d: %.1f m -> charge %.2f (k %.2f)", J.casts, dist / 100, frac, P.k or 1))
        return
    end
    if J.sub == "charge" then
        face_spot(J, pc, me)
        if J.t < J.hold_until then J.hold, J.hold_stop = { J.acts.primary }, J.hold_until; return end
        J.hold = nil
        J.sub, J.wait_t = "cast_wait", J.t
        return
    end
    if J.sub == "cast_wait" then
        if act == "waiting_for_bite" or act == "fighting" then
            J.misses = 0
            if fs.hit then J.cast.landed = d2(J.cast.from, fs.hit) end
            C().learned[J.tool.entry.item] = M.learn_cast(J.cast.L, J.cast.predicted, J.cast.landed)
            J.sub, J.wait_t = "bite", J.t
            return
        end
        if act == "casting" then J.saw_casting = true end
        local res = M.CAST[fs.cast or 4]
        -- a resolved cast: the activity went through casting, or its change time / session moved since the aim
        local resolved = J.saw_casting or (fs.changed_t and fs.changed_t ~= J.changed0) or (fs.session and fs.session ~= J.session0)
        if resolved then J.cast_went = true end
        if resolved and J.t - J.wait_t > 0.3 and res and res ~= "none" and res ~= "hit_node" and act == "none" then
            -- a miss: learn from where it landed (short or long), then cast again
            J.misses = (J.misses or 0) + 1
            local landed = fs.hit and d2(J.cast.from, fs.hit)
            if landed then C().learned[J.tool.entry.item] = M.learn_cast(J.cast.L, J.cast.predicted, landed) end
            J.last_miss = { result = res, landed_m = landed and r1(landed / 100), want_m = r1(J.cast.want / 100) }
            say(J.log, string.format("miss (%s) landed %s m, wanted %.1f m", res, tostring(landed and r1(landed / 100)), J.cast.want / 100))
            if J.misses >= M.cfg.misses_per_stand then J.misses = 0; J.sub = "approach"; J.stand_i = J.stand_i or 0; return end
            J.sub = "aim"
            return
        end
        if J.t - J.wait_t > M.cfg.cast_wait_s then
            J.misses = (J.misses or 0) + 1
            if not J.cast_went and J.misses >= M.cfg.misses_per_stand then
                return fail(J, "verification_failed", "cast_not_running", string.format(
                    "I swing my %s but no cast goes out (tried %d times).", tostring(J.tool.name), J.casts or 0), { last_miss = J.last_miss })
            end
            if J.misses >= M.cfg.misses_per_stand then J.misses = 0; J.sub = "approach"; J.stand_i = J.stand_i or 0; return end
            J.sub = "aim"
        end
        return
    end
    if J.sub == "bite" then
        if act == "fighting" then J.sub, J.fight_t, J.swap_t, J.reel0 = "fight", J.t, J.t, fs.reel; set_phase(J, "fight"); return end
        if act == "none" then J.sub = "result"; J.wait_t = J.t; return end
        if J.t - J.wait_t > M.cfg.bite_wait_s then
            J.no_bites = (J.no_bites or 0) + 1
            if J.set.inputs.cancel then J.hold = { J.set.inputs.cancel }; J.cancel_frames = 3 end
            if J.no_bites >= 3 then
                return fail(J, "nothing_in_range", "no_bite", string.format("Nothing is biting at the %s.", tostring(J.spot.name or "spot")))
            end
            J.sub = "aim"
        end
        return
    end
    if J.sub == "fight" then
        if act ~= "fighting" then J.hold = nil; J.sub, J.wait_t = "result", J.t; return end
        local which = M.fight_input(fs.swim, J.swap)
        local ia = J.set.inputs[which]
        J.hold = ia and { ia } or nil
        J.held_which = which
        -- self-check the pull direction once: while pulling, the reel progress must not fall
        if which ~= "reel" and J.t - J.swap_t >= M.cfg.swap_check_s and not J.swap_checked then
            if type(fs.reel) == "number" and type(J.reel0) == "number" and fs.reel < J.reel0 - 0.05 then
                J.swap = not J.swap
                say(J.log, "pull direction looked wrong (reel fell); swapping")
            end
            J.swap_checked = true
        end
        if J.t - J.fight_t > M.cfg.fight_max_s then
            J.hold = nil
            return fail(J, "timeout", "fight_too_long", "The fish fought me for too long and I lost track of it.")
        end
        return
    end
    if J.sub == "result" then
        local res = M.RESULT[fs.result or 3]
        local c1 = refresh_inv(J)
        local g, n = M.gains(J.c_cast or J.inv0, c1)
        if res == "fish" or res == "junk" or n > 0 or J.t - J.wait_t > M.cfg.result_wait_s then
            if res == "fish" or (res ~= "junk" and n > 0) then
                J.caught = (J.caught or 0) + 1; C().counts.catches = C().counts.catches + 1
                say(J.log, "caught " .. tostring(fs.award or next(g) or "a fish"))
            elseif res == "junk" then
                J.junk = (J.junk or 0) + 1; C().counts.junk = C().counts.junk + 1
                say(J.log, "junk " .. tostring(fs.award or ""))
            elseif res == "escaped" then
                J.escaped = (J.escaped or 0) + 1; C().counts.escaped = C().counts.escaped + 1
                J.last_escape = { my_stamina = fs.my_stamina }
                say(J.log, "the fish escaped")
                if (J.escaped or 0) >= 3 and catches(J) == 0 then
                    return fail(J, "verification_failed", "fish_escaped", "Three fish got away from me; I keep losing the fight.")
                end
            end
            J.c_cast = c1
            J.sub = "aim"
        end
    end
end

local function frame(J)
    local c = C()
    if J.gen ~= c.gen or J.done then return end
    if paused() then
        J.done = true
        if J.handle then pcall(CancelDelayedAction, J.handle) end
        J.result = result_of(J, false, "interrupted", { why = "world_teardown", detail = "The world is reloading." })
        if c.job == J then c.job = nil end
        local arb = mod("arbiter")
        if arb and J.token then J.released = true; pcall(arb.release, nil, J.token, "paused") end
        return
    end
    local pc = J.pc
    local pawn = W.pawn(pc)
    if not pawn then return finish(J, result_of(J, false, "companion_down", { why = "no_pawn" })) end
    J.t = W.now(pawn)
    if J.suspended then return end
    -- per frame: hold the chosen inputs (Enhanced Input injection lasts one frame)
    -- a timed hold (charge, trawl) ends on the exact frame, not at the next decision tick
    if J.hold and J.hold_stop and J.t >= J.hold_stop then J.hold, J.hold_stop = nil, nil end
    if J.hold then
        local modal = W.gate()
        if modal then
            J.gated = (J.gated or 0) + 1
            J.hold, J.hold_stop = nil, nil -- a held trawl / charge is dropped and re-run once the screen closes
            if J.sub == "trawl" and J.hold_until then J.hold_until = nil; J.trawls = math.max((J.trawls or 1) - 1, 0)
            elseif J.sub == "charge" then J.sub = "aim"; J.casts = math.max((J.casts or 1) - 1, 0) end
            if J.gated == 1 then say(J.log, "input gated by " .. tostring(modal.kind)) end
            if J.gated > 300 then
                return fail(J, "interrupted", "screen_open", string.format("A %s screen is open, so I can't use my %s.",
                    tostring(modal.kind), tostring(J.tool and J.tool.name or "tool")))
            end
            return
        else
            J.gated = nil
            for _, ia in ipairs(J.hold) do if ia then W.inject(ia) end end
        end
    end
    if J.cancel_frames then J.cancel_frames = J.cancel_frames - 1; if J.cancel_frames <= 0 then J.cancel_frames = nil; J.hold = nil end end
    if J.t - (J.dec_t or -1) < M.cfg.decide_s then return end
    J.dec_t = J.t
    local arb = mod("arbiter")
    if arb and J.token then
        if not arb.holds(J.token) then
            if arb.is_suspended and arb.is_suspended(J.token) then J.suspended = true; J.hold = nil; return end
            return finish(J, result_of(J, false, "interrupted", { why = "preempted", detail = "Something else took over, so I stopped fishing." }))
        end
        arb.renew(J.token)
    end
    if W.dead(pawn) then return finish(J, result_of(J, false, "companion_down", { why = "died", detail = "I died while fishing." })) end
    if J.t - J.t0 > J.timeout_s then
        return fail(J, "timeout", "timeout", string.format("I've fished for %d minutes and caught %d of %d.",
            math.floor(J.timeout_s / 60), catches(J), J.want))
    end
    if catches(J) >= J.want then
        return finish(J, result_of(J, true, nil, { detail = string.format("Caught %d at the %s.", catches(J), tostring(J.spot.name or "fishing spot")) }))
    end
    local me = W.loc(pawn)
    if not me then return end
    J.acts = J.acts or W.actions(pawn)
    if J.phase == "equip" then
        if step_equip(J, pawn) then
            local lvl = W.held_level(pawn)
            if J.method == "rod" and lvl and J.spot.level and lvl < J.spot.level then
                J.under_levelled = { rod = lvl, spot = J.spot.level }
            end
            J.acts = W.actions(pawn)
            if not (J.acts and J.acts.primary) then return fail(J, "body_error", "no_input", "I can't find my use-item input.") end
            set_phase(J, "fish", J.method)
            J.sub = "approach"
        end
        return
    end
    if J.method == "rod" then step_rod(J, pawn, pc, me) else step_net(J, pawn, pc, me) end
end
M._frame = frame

-- ------------------------------------------------------------------ start / stop / status
local function known_tags(rows)
    local seen, out = {}, {}
    for _, r in ipairs(rows or {}) do if r.tag and not seen[r.tag] then seen[r.tag] = true; out[#out + 1] = r.tag end end
    return out
end

-- Choose the spot: the asked id, else the nearest usable one he has a tool for. -> spot, tool | nil, failure
function M.choose(rows, me, list, tools, args)
    local all = M.spots(rows, me, { radius_cm = (args.radius_m or M.cfg.radius_m) * 100, include_unusable = true })
    if args.spot then
        for _, s in ipairs(M.spots(rows, me, { include_unusable = true })) do
            if s.id == args.spot then
                local tool = M.pick_tool(list, s.tool_tag, tools)
                if not tool then
                    return nil, nil, { reason = "wrong_tool", why = "no_tool", detail = string.format(
                        "The %s needs a fishing %s and I don't carry one.", tostring(s.name or "spot"), tostring(s.method)), need = s.method, tool_tag = s.tool_tag }
                end
                if s.depleted then return nil, nil, { reason = "nothing_in_range", why = "depleted", detail = string.format("The %s is fished out for now.", tostring(s.name or "spot")) } end
                return s, tool
            end
        end
        return nil, nil, { reason = "unknown_target", why = "unknown_spot", detail = "I can't see that fishing spot any more." }
    end
    if #all == 0 then
        return nil, nil, { reason = "nothing_in_range", why = "no_spot", detail = string.format("I can't see a fishing spot within %d m.", args.radius_m or M.cfg.radius_m) }
    end
    local need, usable_without_tool = {}, 0
    for _, s in ipairs(all) do
        if not (s.depleted or s.blocked) and (not args.method or s.method == args.method) then
            usable_without_tool = usable_without_tool + 1
            local tool = M.pick_tool(list, s.tool_tag, tools)
            if tool then return s, tool end
            need[s.method or "?"] = s.name or s.method
        end
    end
    if usable_without_tool == 0 then
        return nil, nil, { reason = "nothing_in_range", why = "all_depleted", detail = string.format(
            "The %d fishing spot(s) near me are fished out or blocked.", #all) }
    end
    local words = {}
    for m in pairs(need) do words[#words + 1] = m end
    table.sort(words)
    return nil, nil, { reason = "wrong_tool", why = "no_tool", need = words, detail = string.format(
        "The fishing spots here need a fishing %s and I don't carry one.", table.concat(words, " or ")) }
end

function M.start(log, args, ctx)
    args = args or {}
    if paused() then return { ok = false, reason = "companion_down", data = { why = "paused", detail = "The world is loading." } } end
    local want = math.floor(tonumber(args.count) or 1)
    if want < 1 then return { ok = false, reason = "invalid_args", data = { detail = "count must be 1 or more" } } end
    want = math.min(want, M.cfg.max_count)
    local pc = W.pc()
    local pawn = W.pawn(pc)
    if not pawn then return { ok = false, reason = "companion_down", data = { why = "no_pawn" } } end
    local me = W.loc(pawn)
    local inv0, list = W.counts()
    if not inv0 then return { ok = false, reason = "body_error", data = { detail = "inventory unreadable" } } end
    if list.empty_slots == 0 then
        return { ok = false, reason = "inventory_full", data = { why = "inventory_full", detail = "My bags are full; I need to drop something first." } }
    end
    local rows = W.nodes()
    local radius_m = math.min(tonumber(args.radius) or M.cfg.radius_m, M.cfg.max_radius_m)
    local spot, tool, bad = M.choose(rows, me, list, W.tools(), { spot = args.spot, method = args.method, radius_m = radius_m })
    if not spot then
        bad.spots = M.spots(rows, me, { radius_cm = radius_m * 100, include_unusable = true })
        for _, s in ipairs(bad.spots) do s.pos = nil end
        local r = bad.reason; bad.reason = nil
        return { ok = false, reason = r, data = bad }
    end
    local comp = W.comp(pawn)
    if spot.method == "rod" and not comp then
        return { ok = false, reason = "not_implemented", data = { why = "no_fishing_component", detail = "I can't find my fishing controls (no fishing component)." } }
    end
    local c = C()
    if c.job then finish(c.job, result_of(c.job, false, "interrupted", { why = "new_fishing", detail = "A new fishing job started." })) end
    local J
    local arb = mod("arbiter")
    local token
    if arb then
        local r = arb.request(log, { name = "fish", level = "task", resumable = true, uses_move = true, lease_s = M.cfg.lease_s,
            on_suspend = function() if J then J.suspended = true; J.susp_at = J.t; J.hold = nil; J.moving = false end end,
            on_resume = function()
                if not J or J.done then return false end
                J.suspended = false
                if J.susp_at then J.t0 = J.t0 + math.max((J.t or J.susp_at) - J.susp_at, 0); J.susp_at = nil end
                J.acts, J.moving = nil, false
                set_phase(J, "equip", "resumed")
                return true
            end,
            on_stop = function(_, _, why) if J and not J.done then J.released = true; finish(J, result_of(J, false, "interrupted", { why = tostring(why), detail = "I was told to do something else, so I stopped fishing." })) end end })
        if not r.ok then
            return { ok = false, reason = "interrupted", data = { why = "pawn_busy", owner = r.owner, detail = "I'm busy with something else." } }
        end
        token = r.token
    end
    c.gen = c.gen + 1
    c.counts.jobs = c.counts.jobs + 1
    local t = W.now(pawn)
    J = { gen = c.gen, log = log, pc = pc, spot = spot, tool = tool, method = spot.method, want = want, token = token,
          task_id = ctx and ctx.id, inv0 = inv0, inv_now = inv0, skills0 = W.skills(), t0 = t, t = t, phase_t = t,
          caught = 0, junk = 0, escaped = 0, casts = 0, trawls = 0, phase_log = {}, origin = me, comp = comp,
          set = W.settings(comp), rod_m = M.cfg.rod_pref_m,
          timeout_s = math.min(M.cfg.timeout_base_s + M.cfg.timeout_per_catch_s * want, M.cfg.timeout_max_s) }
    J.set.inputs = J.set.inputs or {}
    c.job = J
    set_phase(J, "equip", string.format("%s at %s (%s) x%d with %s", tostring(spot.method), tostring(spot.name), tostring(spot.id), want, tostring(tool.name)))
    W.move_stop(log)
    J.handle = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(frame, J)
        if not ok then
            say(log, "frame error " .. tostring(err))
            J.errors = (J.errors or 0) + 1
            if J.errors >= 5 then finish(J, result_of(J, false, "body_error", { why = "frame_error", detail = tostring(err) })) end
        end
    end)
    return { ok = true, data = { spot = spot.id, spot_name = spot.name, method = spot.method, tool = tool.name, want = want,
             distance_m = spot.distance_m, timeout_s = J.timeout_s } }
end

function M.stop(log, why)
    local J = C().job
    if J and not J.done then finish(J, result_of(J, false, "interrupted", { why = why or "stopped", detail = "I stopped fishing." })) end
    return { ok = true }
end

function M.status()
    local c = C()
    local J = c.job
    local js
    if J then
        js = { phase = J.phase, sub = J.sub, method = J.method, spot = J.spot and J.spot.id, caught = J.caught, junk = J.junk,
               escaped = J.escaped, casts = J.casts, trawls = J.trawls, want = J.want, swap = J.swap, held = J.held_which,
               phase_log = J.phase_log, age_s = J.t and r1(J.t - J.t0) }
    end
    return { ok = true, job = js, last = c.last, counts = c.counts, learned = c.learned, lines = c.lines }
end

-- ------------------------------------------------------------------ read tool + perception
local function spots_tool(log, args)
    if paused() then return { ok = false, reason = "companion_down", data = { detail = "I'm not in the world right now." } } end
    local pawn = W.pawn(W.pc())
    if not pawn then return { ok = false, reason = "companion_down" } end
    local me = W.loc(pawn)
    local _, list = W.counts()
    local rows = W.nodes()
    local radius_m = math.min(tonumber(args and args.radius) or M.cfg.radius_m, M.cfg.max_radius_m)
    local spots = M.spots(rows, me, { radius_cm = radius_m * 100, include_unusable = true })
    local tools = W.tools()
    local out = {}
    for i, s in ipairs(spots) do
        if i > M.cfg.spot_rows then break end
        local tool = M.pick_tool(list, s.tool_tag, tools)
        out[#out + 1] = { id = s.id, name = s.name, method = s.method, level = s.level, distance_m = s.distance_m,
                          depleted = s.depleted, blocked = s.blocked, in_use = s.in_use, my_tool = tool and tool.name or nil }
    end
    return { ok = true, data = { spots = out, total = #spots, radius_m = radius_m,
             my_tools = M.tools_by_method(list, known_tags(rows)) } }
end
M._spots_tool = spots_tool

-- get_state extras: fishing_spots_nearby (max 3), cached.
function M.state_extras(api)
    local c = C()
    local now = (api and api.now and api.now()) or os.time()
    if c.extras and c.extras_at and now - c.extras_at >= 0 and now - c.extras_at < M.cfg.extras_ttl_s then return c.extras end
    local ok, r = pcall(spots_tool, nil, { radius = M.cfg.radius_m })
    local rows = {}
    if ok and r and r.ok then for i, s in ipairs(r.data.spots) do if i <= 3 then rows[#rows + 1] = s end end end
    c.extras, c.extras_at = (#rows > 0) and { fishing_spots_nearby = rows } or {}, now
    return c.extras
end

-- ------------------------------------------------------------------ bridge handlers + contract
M.HANDLERS = {
    fish = function(log, args, ctx)
        args = args or {}
        if args.count ~= nil and (tonumber(args.count) or 0) < 1 then
            return { ok = false, reason = "invalid_args", data = { detail = "count must be 1 or more" } }
        end
        local r = M.start(log, args, ctx)
        if not r.ok then return r end
        local J = C().job
        local a = { kind = "fish", id = ctx and ctx.id, timeout_s = (J and J.timeout_s or 600) + 15 }
        a.cancel = function() M.stop(log, "cancelled by the brain") end
        a.poll = function()
            local j = C().job
            if j and j == J then return nil end
            return (J and J.result) or { ok = false, reason = "body_error", data = { detail = "fishing job vanished" } }
        end
        return { pending = a }
    end,
    fishing_spots = function(log, args) return spots_tool(log, args or {}) end,
    fishing_status = function() return M.status() end,
}

M.NEEDS = {
    fish = { { "sense", "local_pc" }, { "inventory", "list" }, { "inventory", "equip" }, { "move", "go_to" }, { "move", "status" },
             { "combat", "actions" } },
    fishing_spots = { { "sense", "local_pc" }, { "inventory", "list" } },
}

do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    M.MANIFEST = {
        fish = { kind = "action", llm = true, moves = true, priority = "task", duration_s = 60, timeout_s = 1800,
            detail_is_speech = true,
            description = "Fish at a fishing spot (ripples in the water) until you catch count more: walks there, takes out "
                .. "the net or rod that spot needs, trawls (net) or casts and fights the fish (rod). Trains Fishing. "
                .. "Needs a carried net or rod that fits the spot (see fishing_spots).",
            args = { type = "object", properties = obj({
                count = { type = "integer", minimum = 1, maximum = M.cfg.max_count, default = 5, description = "Catches to make (fish or junk)." },
                spot = { type = "string", description = "A fishing spot id from fishing_spots (default: the nearest one you have a tool for)." },
                method = { type = "string", description = "Only spots of this method, e.g. net or rod (from fishing_spots)." },
                radius = { type = "number", minimum = 5, maximum = M.cfg.max_radius_m, description = "Search radius, m (default 60)." } }) },
            preconditions = { "a fishing spot within the radius", "a carried net or rod that fits it" },
            reasons = { "nothing_in_range", "wrong_tool", "path_blocked", "inventory_full", "unknown_target", "not_enough_resources",
                        "verification_failed", "interrupted", "timeout", "companion_down", "invalid_args" } },
        fishing_spots = { kind = "read", llm = true, moves = false, duration_s = 0.3, timeout_s = 10,
            description = "Fishing spots near you: method (net/rod), level, distance, fished out or not, and which of your "
                .. "tools fits each. Read only.",
            args = { type = "object", properties = obj({
                radius = { type = "number", minimum = 5, maximum = M.cfg.max_radius_m, default = 60, description = "Metres." } }) },
            reasons = { "companion_down" } },
        fishing_status = { kind = "probe", llm = false, moves = false, timeout_s = 5,
            args = { type = "object", properties = obj(), additionalProperties = false }, description = "Fishing job state (debug)." },
    }
end

return M

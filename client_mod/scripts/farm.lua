-- farm: TENDING FARM PLOTS on Claude's own client (M3 every-skill coverage; design
-- docs/design/every-skill-coverage.md §5), through the game's own client paths only:
--
--   plots   every UFarmSlotComponent the client knows (by class family): where it is, and the game's own pure
--           reads of it: GetSoilState (weeds / clear), CanHarvest, CanHealDisease, IsFullyWatered,
--           IsFullyFertilized, AreWeedsFullyGrown, plus its interaction prompt text. No stage->item table: the
--           MODEL picks what to use from the plot state and its items' actions (held_actions / inventory).
--   tend    walk to the plot, then either
--             * item given: equip it (inventory.equip, verified held), face the plot, press the held item's
--               primary (what the player's click does: Dig / Scatter Seeds / Pour / Fertilize, from the item's
--               own PrimaryActionClass), through input.gate (never while a build/container screen is open);
--             * no item: face it until the game's interact detector targets the plot, ONE interact press
--               (harvest / cure, the plot's own Interact).
--           Verified by the plot's reads changing, or the bag changing (a seed spent, a crop gained); repeated
--           up to `times` presses while nothing changed yet (e.g. weeds need several digs).
--   Never UFarmCommandComponent's server RPCs, never a state write.
-- W = the engine touches (tests replace them). Live state in _G.DWFarm.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.cfg = {
    radius_m = 40, max_radius_m = 120, slot_class = "FarmSlotComponent",
    stand_tol_m = 1.2, reach_m = 2.5, face_s = 3.0,
    equip_wait_s = 4, equip_repress_s = 1.5,
    tap_frames = 3, verify_s = 3.0, max_times = 10,
    approach_timeout_s = 60, lease_s = 5, decide_s = 0.1, rows = 8,
}

local function C()
    local c = rawget(_G, "DWFarm")
    if not c then c = { gen = 0, counts = { jobs = 0, presses = 0, changed = 0 }, lines = {} }; _G.DWFarm = c end
    return c
end
M._state = C
local function paused() return rawget(_G, "DW_PAUSE") == true end
local function say(log, msg)
    if log then pcall(log, "farm: " .. msg) end
    local c = C()
    c.lines[#c.lines + 1] = os.date("!%H:%M:%S ") .. msg
    if #c.lines > 40 then table.remove(c.lines, 1) end
end
local function r1(x) return type(x) == "number" and math.floor(x * 10 + 0.5) / 10 or nil end
local function d2(a, b) if not (a and b) then return math.huge end return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function text(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end

local L = U.loader(ROOT) -- the shared sibling-module loader (mod/body/util.lua)
M.mods, M.set_modules = L.mods, L.set_modules
local mod, mcall = L.mod, L.mcall

-- ------------------------------------------------------------------ pure
M.SOIL = { [0] = "weeds", [1] = "clear" } -- EFarmSlotSoilState

-- A comparable signature of a plot's state (what tend verifies against).
function M.signature(p)
    if not p then return "gone" end
    return table.concat({ tostring(p.soil), tostring(p.harvestable), tostring(p.diseased), tostring(p.watered),
                          tostring(p.fertilized), tostring(p.weeds_grown), tostring(p.prompt) }, "|")
end

-- What changed between two plot rows, as words for the result. -> {field = {from, to}} | nil
function M.changes(a, b)
    local out
    for _, k in ipairs({ "soil", "harvestable", "diseased", "watered", "fertilized", "weeds_grown", "prompt" }) do
        local x, y = a and a[k], b and b[k]
        if x ~= y then out = out or {}; out[k] = { from = x, to = y } end
    end
    return out
end

function M.plots(rows, me, radius_cm)
    local out = {}
    for _, r in ipairs(rows or {}) do
        local d = d2(me, r.pos)
        if d <= (radius_cm or math.huge) then
            local p = {}
            for k, v in pairs(r) do if k ~= "comp" and k ~= "owner" then p[k] = v end end
            p.distance_m = r1(d / 100)
            out[#out + 1] = p
        end
    end
    table.sort(out, function(a, b) return (a.distance_m or 0) < (b.distance_m or 0) end)
    return out
end

local function gains(c0, c1)
    local g, n = {}, 0
    for k, v in pairs(c1 or {}) do local d = v - ((c0 or {})[k] or 0); if d ~= 0 then g[k] = d; n = n + math.abs(d) end end
    for k, v in pairs(c0 or {}) do if (c1 or {})[k] == nil and v ~= 0 then g[k] = -v; n = n + v end end
    return g, n
end
M.inv_changes = gains

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
function W.skills() local me = mcall("sense", "me"); return type(me) == "table" and me.skills or nil end
function W.slots()
    local out = {}
    for _, c in ipairs(U.find_all(M.cfg.slot_class, { skip_defaults = true }) or {}) do
        local owner = U.try(function() return c:GetOwner() end)
        if U.alive(owner) then
            local v = U.try(function() return c:K2_GetComponentLocation() end)
            local idx = U.try(function() return c.SlotIndex end)
            local ic = U.try(function() return c.InteractionComponent end)
            local function b(fn) local x = U.try(function() return c[fn](c) end); if x == nil then return nil end; return x == true end
            out[#out + 1] = { id = tostring(U.short(owner)) .. "#" .. tostring(idx or 0), owner_id = U.short(owner),
                pos = v and { X = v.X, Y = v.Y, Z = v.Z } or U.loc(owner),
                soil = M.SOIL[U.try(function() return c:GetSoilState() end) or -1],
                harvestable = b("CanHarvest"), diseased = b("CanHealDisease"), watered = b("IsFullyWatered"),
                fertilized = b("IsFullyFertilized"), weeds_grown = b("AreWeedsFullyGrown"),
                prompt = U.valid(ic) and text(U.try(function() return ic.InteractionPrompt end)) or nil,
                status = U.valid(ic) and text(U.try(function() return ic.PlotStatusDisplayText end)) or nil }
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
function W.find_item(list, what) return mcall("inventory", "find", list, what) end
function W.held_item(pawn)
    local inv = mod("inventory")
    local h = (inv and inv.held and U.try(inv.held, pawn)) or {}
    return h.right_item, h.left_item
end
function W.equip(log, item) return mcall("inventory", "equip", log, item) end
function W.actions(pawn) return mcall("combat", "actions", pawn) or {} end
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
function W.target(pawn) return mcall("inventory", "interact_target", pawn) end
function W.press(log) return mcall("inventory", "press_interact", log) end
function W.face(pc, yaw, pitch) pcall(function() pc:SetControlRotation({ Pitch = pitch or -20, Yaw = yaw, Roll = 0 }) end) end
function W.go_to(log, p, tol_m, timeout_s)
    return mcall("move", "go_to", log, { p.X / 100, p.Y / 100, p.Z / 100 }, { tolerance_m = tol_m, timeout_s = timeout_s })
end
function W.move_status() return mcall("move", "status") or {} end
function W.move_stop(log) return mcall("move", "stop", log) end

-- ------------------------------------------------------------------ the job
local function plot_now(J)
    for _, r in ipairs(W.slots()) do if r.id == J.plot.id then return r end end
    return nil
end

local function xp_delta(s0, s1)
    local by = {}
    for _, r in ipairs(s0 or {}) do if r.skill then by[r.skill] = r end end
    local out
    for _, r in ipairs(s1 or {}) do
        local a = r.skill and by[r.skill]
        if a and type(r.xp) == "number" and type(a.xp) == "number" and r.xp > a.xp then
            out = out or {}; out[r.skill] = { xp = r1(r.xp - a.xp), level = (r.level ~= a.level) and r.level or nil }
        end
    end
    return out
end

local function result_of(J, ok, reason, data)
    data = data or {}
    data.plot, data.item, data.presses = J.plot.id, J.item_name, J.presses
    data.before, data.after = J.before, J.after
    data.changed = M.changes(J.before, J.after)
    local g, n = gains(J.inv0, J.inv1 or J.inv0)
    if n > 0 then data.inventory = g end
    data.xp = J.xp
    return { ok = ok == true, reason = reason, data = data }
end

local function finish(J, res)
    if J.done then return end
    J.done = true
    local c = C()
    if J.handle then pcall(CancelDelayedAction, J.handle) end
    J.handle, J.tap = nil, nil
    if not paused() then
        if J.moving then pcall(W.move_stop, J.log); J.moving = false end
        J.xp = xp_delta(J.skills0, W.skills())
        res.data.xp = J.xp
    end
    J.result = res
    c.last = { result = res, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.job == J then c.job = nil end
    local arb = mod("arbiter")
    if arb and J.token and not J.released then J.released = true; pcall(arb.release, J.log, J.token, res.ok and "done" or res.reason) end
    say(J.log, string.format("done %s %s: %s", tostring(res.ok), tostring(res.reason or ""), tostring(res.data.detail or "")))
end
local function fail(J, reason, why, detail)
    return finish(J, result_of(J, false, reason, { why = why, detail = detail }))
end
local function set_phase(J, ph, note) J.phase, J.phase_t = ph, J.t; say(J.log, "phase " .. ph .. (note and (" " .. note) or "")) end

local function frame(J)
    local c = C()
    if J.gen ~= c.gen or J.done then return end
    if paused() then
        J.done = true
        if J.handle then pcall(CancelDelayedAction, J.handle) end
        J.result = result_of(J, false, "interrupted", { why = "world_teardown", detail = "The world is reloading." })
        if c.job == J then c.job = nil end
        return
    end
    local pawn = W.pawn(J.pc)
    if not pawn then return finish(J, result_of(J, false, "companion_down", { why = "no_pawn" })) end
    J.t = W.now(pawn)
    if J.suspended then return end
    local me = W.loc(pawn)
    if J.tap and me then
        local yaw = math.deg(math.atan(J.plot.pos.Y - me.Y, J.plot.pos.X - me.X))
        W.face(J.pc, yaw)
        local modal = W.gate()
        if modal then J.tap = nil; J.gated = modal.kind
        else W.inject(J.tap.act); J.tap.frames = J.tap.frames - 1; if J.tap.frames <= 0 then J.tap = nil end end
    end
    if J.t - (J.dec_t or -1) < M.cfg.decide_s then return end
    J.dec_t = J.t
    local arb = mod("arbiter")
    if arb and J.token then
        if not arb.holds(J.token) then
            if arb.is_suspended and arb.is_suspended(J.token) then J.suspended = true; return end
            return finish(J, result_of(J, false, "interrupted", { why = "preempted", detail = "Something else took over, so I stopped tending the plot." }))
        end
        arb.renew(J.token)
    end
    if W.dead(pawn) then return fail(J, "companion_down", "died", "I died at the farm plot.") end
    if not me then return end
    if J.gated then
        return fail(J, "interrupted", "screen_open", string.format("A %s screen is open, so I can't use my %s on the plot.", tostring(J.gated), tostring(J.item_name or "hands")))
    end
    local ph = J.phase
    if ph == "approach" then
        if d2(me, J.plot.pos) <= M.cfg.reach_m * 100 then if J.moving then W.move_stop(J.log); J.moving = false end; return set_phase(J, J.item and "equip" or "face") end
        if not J.moving then W.go_to(J.log, J.plot.pos, M.cfg.stand_tol_m, M.cfg.approach_timeout_s); J.moving, J.move_t = true, J.t end
        local st = W.move_status() or {}
        local res = st.result or {}
        if res.status == "failed" or res.status == "stopped" or J.t - J.move_t > M.cfg.approach_timeout_s then
            J.moving = false
            return fail(J, "path_blocked", "cant_reach_plot", string.format("I can't get to the plot; it's %.0f m away.", d2(me, J.plot.pos) / 100))
        end
        if res.status == "arrived" then J.moving = false end
        return
    end
    if ph == "equip" then
        local r, l = W.held_item(pawn)
        if r == J.item or l == J.item then J.acts = W.actions(pawn); return set_phase(J, "press") end
        if J.t - J.phase_t > M.cfg.equip_wait_s then
            return fail(J, "wrong_tool", "equip_failed", string.format("I tried to take out my %s but it didn't come out.", tostring(J.item_name)))
        end
        if not J.equip_sent or J.t - J.equip_sent > M.cfg.equip_repress_s then J.equip_sent = J.t; W.equip(J.log, J.item) end
        return
    end
    if ph == "face" then
        local yaw = math.deg(math.atan(J.plot.pos.Y - me.Y, J.plot.pos.X - me.X))
        W.face(J.pc, yaw)
        local tg = W.target(pawn)
        if tg and tg.actor == J.plot.owner_id then return set_phase(J, "press") end
        if J.t - J.phase_t > M.cfg.face_s then
            return fail(J, "not_interactable", "not_targeted", string.format("I'm at the plot but the game won't let me use it%s.",
                tg and tg.actor and (" (it targets " .. tostring(tg.name or tg.prompt or tg.actor) .. ")") or ""))
        end
        return
    end
    if ph == "press" then
        J.presses = (J.presses or 0) + 1
        C().counts.presses = C().counts.presses + 1
        J.sig0, J.c0 = M.signature(plot_now(J)), W.counts()
        if J.item then
            local act = J.acts and J.acts.primary
            if not act then return fail(J, "body_error", "no_input", "I can't find my use-item input.") end
            J.tap = { act = act, frames = M.cfg.tap_frames }
        else
            if W.gate() then J.gated = W.gate().kind; return end
            W.press(J.log)
        end
        return set_phase(J, "verify")
    end
    if ph == "verify" then
        local p = plot_now(J)
        local c1 = W.counts()
        local _, n = gains(J.c0, c1)
        if M.signature(p) ~= J.sig0 or n > 0 then
            J.after, J.inv1 = p, c1
            C().counts.changed = C().counts.changed + 1
            local ch = M.changes(J.before, p)
            local words = {}
            for k, v in pairs(ch or {}) do words[#words + 1] = string.format("%s %s -> %s", k, tostring(v.from), tostring(v.to)) end
            table.sort(words)
            return finish(J, result_of(J, true, nil, { detail = string.format("Done after %d press%s%s.", J.presses, J.presses == 1 and "" or "es",
                #words > 0 and (": " .. table.concat(words, ", ")) or " (my bag changed)") }))
        end
        if J.t - J.phase_t >= M.cfg.verify_s then
            if J.presses < J.times then return set_phase(J, J.item and "press" or "face", "again") end
            J.after, J.inv1 = p, c1
            return fail(J, "verification_failed", "no_change", string.format("I used %s on the plot %d time%s but nothing changed%s.",
                J.item_name and ("my " .. J.item_name) or "my hands", J.presses, J.presses == 1 and "" or "s",
                p and p.prompt and (" (the plot says: " .. p.prompt .. ")") or ""))
        end
    end
end
M._frame = frame

function M.start(log, args, ctx)
    args = args or {}
    if paused() then return { ok = false, reason = "companion_down", data = { why = "paused", detail = "The world is loading." } } end
    local pc = W.pc()
    local pawn = W.pawn(pc)
    if not pawn then return { ok = false, reason = "companion_down", data = { why = "no_pawn" } } end
    local me = W.loc(pawn)
    local rows = M.plots(W.slots(), me, M.cfg.max_radius_m * 100)
    local plot
    for _, p in ipairs(rows) do if (args.plot and (p.id == args.plot or p.owner_id == args.plot)) or (not args.plot) then plot = p; break end end
    if not plot then
        if args.plot then return { ok = false, reason = "unknown_target", data = { why = "unknown_plot", detail = "I can't see that farm plot." } } end
        return { ok = false, reason = "nothing_in_range", data = { why = "no_plot", detail = "I can't see a farm plot near me." } }
    end
    local inv0, list = W.counts()
    if not inv0 then return { ok = false, reason = "body_error", data = { detail = "inventory unreadable" } } end
    local item, item_name
    if type(args.item) == "string" and args.item ~= "" then
        local e = W.find_item(list, args.item)
        if not e then
            return { ok = false, reason = "not_in_inventory", data = { why = "no_item", detail = string.format("I don't have %s.", args.item) } }
        end
        item, item_name = e.item, e.name or e.item
    end
    local c = C()
    if c.job then finish(c.job, result_of(c.job, false, "interrupted", { why = "new_tend", detail = "A new plot job started." })) end
    local J
    local arb = mod("arbiter")
    local token
    if arb then
        local r = arb.request(log, { name = "tend", level = "command", resumable = true, uses_move = true, lease_s = M.cfg.lease_s,
            on_suspend = function() if J then J.suspended = true; J.tap = nil; J.moving = false end end,
            on_resume = function() if J and not J.done then J.suspended = false; J.moving = false; set_phase(J, "approach", "resumed"); return true end return false end,
            on_stop = function(_, _, why) if J and not J.done then J.released = true; finish(J, result_of(J, false, "interrupted", { why = tostring(why), detail = "I was told to do something else." })) end end })
        if not r.ok then return { ok = false, reason = "interrupted", data = { why = "pawn_busy", owner = r.owner, detail = "I'm busy with something else." } } end
        token = r.token
    end
    c.gen = c.gen + 1
    c.counts.jobs = c.counts.jobs + 1
    local t = W.now(pawn)
    J = { gen = c.gen, log = log, pc = pc, plot = plot, item = item, item_name = item_name, token = token, t0 = t, t = t, phase_t = t,
          presses = 0, times = math.max(1, math.min(math.floor(tonumber(args.times) or 1), M.cfg.max_times)),
          before = plot, inv0 = inv0, skills0 = W.skills() }
    c.job = J
    set_phase(J, "approach", tostring(plot.id) .. " with " .. tostring(item_name or "hands"))
    J.handle = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(frame, J)
        if not ok then
            say(log, "frame error " .. tostring(err))
            J.errors = (J.errors or 0) + 1
            if J.errors >= 5 then finish(J, result_of(J, false, "body_error", { why = "frame_error", detail = tostring(err) })) end
        end
    end)
    return { ok = true, data = { plot = plot.id, item = item_name } }
end

function M.stop(log, why)
    local J = C().job
    if J and not J.done then finish(J, result_of(J, false, "interrupted", { why = why or "stopped", detail = "I stopped tending the plot." })) end
    return { ok = true }
end

function M.status()
    local c = C()
    local J = c.job
    return { ok = true, job = J and { phase = J.phase, plot = J.plot.id, presses = J.presses } or nil, last = c.last, counts = c.counts, lines = c.lines }
end

local function plots_tool(log, args)
    if paused() then return { ok = false, reason = "companion_down" } end
    local pawn = W.pawn(W.pc())
    if not pawn then return { ok = false, reason = "companion_down" } end
    local radius = math.min(tonumber(args and args.radius) or M.cfg.radius_m, M.cfg.max_radius_m)
    local list = M.plots(W.slots(), W.loc(pawn), radius * 100)
    local out = {}
    for i, p in ipairs(list) do if i <= M.cfg.rows then p.pos = nil; out[#out + 1] = p end end
    return { ok = true, data = { plots = out, total = #list, radius_m = radius } }
end

M.HANDLERS = {
    tend = function(log, args, ctx)
        args = args or {}
        if args.times ~= nil and (tonumber(args.times) or 0) < 1 then return { ok = false, reason = "invalid_args", data = { detail = "times must be 1 or more" } } end
        local r = M.start(log, args, ctx)
        if not r.ok then return r end
        local J = C().job
        local a = { kind = "tend", id = ctx and ctx.id, timeout_s = 120 + (J and J.times or 1) * 8 }
        a.cancel = function() M.stop(log, "cancelled by the brain") end
        a.poll = function()
            local j = C().job
            if j and j == J then return nil end
            return (J and J.result) or { ok = false, reason = "body_error", data = { detail = "plot job vanished" } }
        end
        return { pending = a }
    end,
    farm_plots = function(log, args) return plots_tool(log, args or {}) end,
    farm_status = function() return M.status() end,
}

M.NEEDS = {
    tend = { { "sense", "local_pc" }, { "inventory", "list" }, { "inventory", "find" }, { "inventory", "equip" },
             { "inventory", "interact_target" }, { "inventory", "press_interact" }, { "move", "go_to" }, { "move", "status" } },
    farm_plots = { { "sense", "local_pc" } },
}

do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    M.MANIFEST = {
        tend = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 8, timeout_s = 200,
            detail_is_speech = true,
            description = "Work a farm plot once: walk to it and use a carried item on it (its main action, e.g. a spade's "
                .. "dig, seeds' scatter, a watering can's pour, compost), or with no item press use on it (harvest, cure). "
                .. "Checks the plot changed. Trains Farming. See farm_plots for each plot's state.",
            args = { type = "object", properties = obj({
                plot = { type = "string", description = "A plot id from farm_plots (default: the nearest)." },
                item = { type = "string", description = "A carried item to use on the plot (name or id); omit to press use." },
                times = { type = "integer", minimum = 1, maximum = M.cfg.max_times, default = 1, description = "Presses at most, until the plot changes." } }) },
            preconditions = { "a farm plot within 120 m", "the item is carried" },
            reasons = { "nothing_in_range", "unknown_target", "not_in_inventory", "wrong_tool", "path_blocked", "not_interactable",
                        "verification_failed", "interrupted", "companion_down", "invalid_args" } },
        farm_plots = { kind = "read", llm = true, moves = false, duration_s = 0.3, timeout_s = 10,
            description = "Farm plots near you with the game's own state: soil (weeds/clear), harvestable, diseased, watered, "
                .. "fertilized, and the plot's prompt. Read only.",
            args = { type = "object", properties = obj({
                radius = { type = "number", minimum = 5, maximum = M.cfg.max_radius_m, default = 40, description = "Metres." } }) },
            reasons = { "companion_down" } },
        farm_status = { kind = "probe", llm = false, moves = false, timeout_s = 5,
            args = { type = "object", properties = obj(), additionalProperties = false }, description = "Plot job state (debug)." },
    }
end

return M

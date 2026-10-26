-- Offline tests for client_mod/scripts/spells.lua (R2.20): listing from game data, spell resolution
-- (never substitutes), the safety floor, and whole casts as waiters against a fake game (input modes
-- Gameplay -> RadialMenu -> SpellPlacementMode, runes, cooldown map, GE instances, own spell actors,
-- the server's cooldown RPC), with the REAL arbiter (follow suspended + resumed, reflex fight -> busy).
-- Run:  lua client_mod/tests/test_spells.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local ROOT = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
function StaticFindObject() return nil end
function FindAllOf() return {} end
function FindFirstOf() return nil end

local T = 0
local A = assert(loadfile(ROOT .. "/client_mod/scripts/arbiter.lua"))()
A.clock = function() return T end
local fake_move = { stops = 0, restored = 0, mode = "idle" }
function fake_move.stop() fake_move.stops = fake_move.stops + 1; fake_move.mode = "idle"; return { ok = true } end
function fake_move.status() return { mode = fake_move.mode } end
A.set_move(fake_move)

local SRC = os.getenv("DW_SPELLS_SRC") or (ROOT .. "/client_mod/scripts/spells.lua")
local SP = assert(loadfile(SRC))()
local W = SP.W
SP.wall = function() return T end

-- ---------------------------------------------------------------- fake game
local G
local AIR, AST, EARTH = "ITEM_Rune_Air", "ITEM_Rune_Astral", "ITEM_Rune_Earth"
local function spell(t)
    t.cost = t.cost or {}
    t.cooldown_s = t.cooldown_s or 3
    t.cast_type = t.cast_type or 0
    t.icon = t.icon or ("T_" .. t.asset)
    return t
end
local WINDSTEP = spell({ asset = "USD_Windstep", name = "Windstep", desc = "Summons the power of Air Magic to Jump higher and Descend slower.",
                         cost = { { item = AIR, name = "Air Rune", count = 5 } }, perk = { level = 5, skill = "SKILL_Agility", skill_name = "Agility" } })
local SHELTER = spell({ asset = "USD_SummonShelter", name = "Summon Shelter", desc = "Summon a shelter with a bed.", cast_type = 1, cooldown_s = 15,
                        cost = { { item = EARTH, name = "Earth Rune", count = 10 }, { item = AST, name = "Astral Rune", count = 10 } },
                        perk = { level = 20, skill = "SKILL_Construction", skill_name = "Construction" } })
local BLAST = spell({ asset = "USD_TestBlast", name = "Rock Blast", desc = "Hurls rocks at a spot.", cast_type = 1, harmful = true,
                      cost = { { item = EARTH, name = "Earth Rune", count = 5 } }, perk = { level = 3, skill = "SKILL_Mining", skill_name = "Mining" } })
local AXTRAL = spell({ asset = "USD_TestAxe", name = "Astral Axe", desc = "Throws an axe forward, felling trees in its path.", cast_type = 2,
                       special_req = "Logging Axe", cost = { { item = AIR, name = "Air Rune", count = 10 } },
                       perk = { level = 3, skill = "SKILL_Woodcutting", skill_name = "Woodcutting" } })
local ENCHANT = spell({ asset = "USD_TestEnchant", name = "Enchant Weapon: Air", desc = "Adds air damage to your weapon.", cast_type = 0, harmful = true,
                        cost = { { item = AIR, name = "Air Rune", count = 15 } }, perk = { level = 3, skill = "SKILL_Attack", skill_name = "Attack" } })

local function reset(o)
    o = o or {}
    T = 0
    _G.DWSpells, _G.DW_PAUSE = nil, nil
    SP.mem().roles = o.roles or {}
    A.reset()
    fake_move.stops, fake_move.mode = 0, "idle"
    G = { mode = "DIM_Gameplay", items = o.items or { [AIR] = 821, [AST] = 500, [EARTH] = 500 },
          unlocked = o.unlocked or { WINDSTEP }, wheel = o.wheel or { "USD_Windstep" }, last_cast = {}, ge = {}, tags = {}, actors = {},
          skills = { SKILL_Agility = 5, SKILL_Construction = 1, SKILL_Mining = 3, SKILL_Attack = 5 },
          presses = {}, sched = {}, pos = { 0, 0, 0 }, players = o.players or {}, falling = false, server_time = 1000,
          wheel_broken = o.wheel_broken, quick_no_select = o.quick_no_select, no_effect = o.no_effect, land_offset = o.land_offset,
          server_cooldown = o.server_cooldown, highlight_wrong = o.highlight_wrong, delayed = o.delayed, preview_off = o.preview_off, invalid_spots = o.invalid_spots, not_flat = o.not_flat, slow_cast = o.slow_cast, req = o.req, foliage = o.foliage,
          aim_valid_after = o.aim_valid_after, cooldown_then_spend = o.cooldown_then_spend, no_preview = o.no_preview, no_spots = o.no_spots, all = o.all or { WINDSTEP, SHELTER }, page = o.page or 0, shown_page = o.page or 0, no_icons = o.no_icons, slow_pages = o.slow_pages }
end
local function at(dt, fn) G.sched[#G.sched + 1] = { t = T + dt, fn = fn } end
local function tick()
    local keep = {}
    for _, s in ipairs(G.sched) do if T >= s.t then s.fn() else keep[#keep + 1] = s end end
    G.sched = keep
end
local function spell_by(id) for _, s in ipairs(G.all) do if s.asset == id then return s end end
    for _, s in ipairs(G.unlocked) do if s.asset == id then return s end end end
local function effect(s, landed)
    if G.no_effect then return end
    local dl = G.delayed -- replication lag per signal (L25): {runes = s, cooldown = s (false = never)}
    local function runes() for _, c in ipairs(s.cost) do G.items[c.item] = (G.items[c.item] or 0) - c.count end end
    local function cd() G.last_cast[s.asset] = G.server_time end
    if dl then
        if dl.runes then at(dl.runes, runes) end
        if dl.cooldown then at(dl.cooldown, cd) end
    else
        runes(); cd()
    end
    if s.cast_type == 0 then G.ge[#G.ge + 1] = "GE_" .. s.asset .. "_Instance" else
        G.actors["BP_" .. s.asset .. "_1"] = { class = "BP_" .. s.asset .. "_C", position = landed } end
end

W.pc = function() return {} end
W.clock = function() return nil end
W.thing_center = function(_, t) return G and G.centers and G.centers[t.id] or nil end
W.pawn = function() return {} end
W.static = function(o) return o end
W.all_spells = function() return G.all end
W.hooks_start = function() end
W.snapshot = function()
    local s = { wheel = {}, unlocked = {}, objects = {}, items = {}, last_cast = {}, ge = {}, tags = {}, actors = {}, skills = G.skills,
                per_radial = 12, radials = 4, place_max_m = 15, server_time = G.server_time, input_mode = G.mode, falling = G.falling,
                position = G.pos, casting = G.casting }
    for i = 1, 48 do s.wheel[i] = G.wheel[i] or false end
    for _, sp in ipairs(G.unlocked) do s.unlocked[sp.asset] = true; s.objects[sp.asset] = sp end
    for k, v in pairs(G.items) do s.items[k] = v end
    for k, v in pairs(G.last_cast) do s.last_cast[k] = v end
    for _, x in ipairs(G.ge) do s.ge[#s.ge + 1] = x end
    for k, v in pairs(G.actors) do s.actors[k] = v end
    return s
end
local ACTS = { menu = { n = "menu" }, place = { n = "place" }, cancel = { n = "cancel" }, next_page = { n = "next_page" }, prev_page = { n = "prev_page" },
               accept = { n = "accept" }, quick = {} }
for i = 0, 7 do ACTS.quick[i + 1] = { n = "quick" .. i } end
W.actions = function() return ACTS end
W.shown_icons = function()
    if G.no_icons then return nil end
    local out = {}
    for i = 1, 12 do local s = spell_by(G.wheel[G.shown_page * 12 + i]); out[i] = s and s.icon or false end
    return out
end
W.selected = function() return G.selected end
W.highlight = function(_, slot)
    G.highlighted = slot
    local sp = spell_by(G.wheel[G.shown_page * 12 + slot + 1])
    return { section = slot, name = G.highlight_wrong or (sp and sp.name) or "" }
end
W.aim = function(_, pos) G.aimed = pos; G.aims = (G.aims or 0) + 1; return math.sqrt(pos[1] ^ 2 + pos[2] ^ 2 + 9) end
W.players = function() return G.players end
W.requirement = function(_, st) return G.req and G.req[st.asset] or nil end
W.foliage_thing = function(_, id) return G.foliage and G.foliage[id] or nil end
local function key2(p) return string.format("%d,%d", math.floor(p[1] + 0.5), math.floor(p[2] + 0.5)) end
W.spots = function(_, center)
    if G.no_spots then return {} end
    if center then return { { position = center, spread_m = 0.1, exact = true }, { position = { center[1] + 2, center[2], center[3] or 0 }, spread_m = 0.2 } } end
    return { { position = { 4, 0, 0 }, spread_m = 0.1 }, { position = { 0, 4, 0 }, spread_m = 0.2 }, { position = { -4, 0, 0 }, spread_m = 0.3 } }
end
W.preview = function()
    if G.no_preview or G.mode ~= "DIM_SpellPlacementMode" then return nil end
    local a = G.aimed or { 3, 0, 0 }
    if G.aim_valid_after then -- aimed: valid only once the camera has been aimed this many times
        local ok = (G.aims or 0) >= G.aim_valid_after
        return { valid = ok, tag = not ok and "UI.Notification.SpellPlacement.NoTarget" or nil, position = { a[1], a[2], (a[3] or 0) - 1.2 } }
    end
    local bad = G.invalid_spots and (G.invalid_spots[key2(a)] or G.invalid_spots.all)
    if G.preview_off then return { valid = true, position = { a[1], a[2] + G.preview_off, a[3] or 0 } } end
    return { valid = not bad, tag = bad and (G.not_flat and "UI.Notification.SpellPlacement.GroundNotFlatEnough" or "Spell.Placement.Invalid.Slope") or nil,
             position = { a[1], a[2], a[3] or 0 } }
end
W.inject = function(_, a)
    G.presses[#G.presses + 1] = a.n
    if a.n == "menu" or a.n == "close_previous" then
        if G.mode == "DIM_RadialMenu" then G.mode = "DIM_Gameplay"
        elseif G.mode == "DIM_Gameplay" and not G.wheel_broken then at(0.15, function() G.mode = "DIM_RadialMenu" end) end
    elseif a.n == "next_page" or a.n == "prev_page" then
        if G.mode == "DIM_RadialMenu" then
            G.page = (G.page + (a.n == "prev_page" and -1 or 1)) % 4
            local p = G.page
            if G.slow_pages then at(G.slow_pages, function() G.shown_page = p end) else G.shown_page = p end
        end
    elseif a.n:match("^quick") or a.n == "accept" then
        if G.mode ~= "DIM_RadialMenu" then return true end
        if G.quick_no_select then return true end
        local slot = a.n == "accept" and G.highlighted or tonumber(a.n:match("%d+"))
        local s = spell_by(G.wheel[G.page * 12 + slot + 1])
        G.selected = s and s.asset
        if not s then G.mode = "DIM_Gameplay"; return true end
        if s.cast_type == 0 and G.stay_in_mode then
            G.mode = "DIM_SpellcastingMode" -- e.g. a camera mode the spell keeps open
            at(0.4, function() effect(s) end)
        elseif s.cast_type == 0 then
            G.mode = "DIM_Gameplay"
            if G.cooldown_then_spend then
                at(0.2, function() local m = SP.mem(); m.events[#m.events + 1] = { ev = "on_cooldown" } end)
                at(1.2, function() effect(s) end)
            elseif G.server_cooldown then at(0.2, function() local m = SP.mem(); m.events[#m.events + 1] = { ev = "on_cooldown" } end)
            else at(0.4, function() effect(s) end) end
        else
            G.mode, G.placing = "DIM_SpellPlacementMode", s
        end
    elseif a.n == "place" then
        if G.mode == "DIM_SpellPlacementMode" then
            local s, aim = G.placing, G.aimed or { 3, 0, 0 }
            local off = G.land_offset or 0
            if G.slow_cast then
                G.mode = "DIM_SpellcastingMode" -- the cast animation (live: runes spent after > 4 s)
                at(G.slow_cast, function() G.mode = "DIM_Gameplay"; effect(s, { aim[1] + off, aim[2], aim[3] or 0 }) end)
            elseif G.cast_mode_after then
                G.mode = "DIM_SpellcastingMode" -- the actor appears, the mode lingers a moment (live Splinter)
                at(0.5, function() effect(s, { aim[1] + off, aim[2], aim[3] or 0 }) end)
                at(G.cast_mode_after, function() G.mode = "DIM_Gameplay" end)
            else
                G.mode = "DIM_Gameplay"
                at(0.5, function() effect(s, { aim[1] + off, aim[2], aim[3] or 0 }) end)
            end
        end
    elseif a.n == "cancel" or a.n == "close_previous_cancel" then
        if G.mode ~= "DIM_RadialMenu" then
            if G.cooldown_on_leave and G.mode == "DIM_SpellcastingMode" then
                for k in pairs(G.unlocked_set or {}) do G.last_cast[k] = G.server_time end
                at(0.5, function() G.last_cast["USD_Windstep"] = G.server_time end)
            end
            G.mode = "DIM_Gameplay"
        end
    end
    return true
end

local api = {
    module = function(n) if n == "arbiter" then return A end end,
    fail = function(reason, data) return { ok = false, reason = reason, data = data or {} } end,
    now = function() return T end,
    log = function() end,
    my_position = function() return G.pos end,
    aim_at = function() end,
    census_things = function() return G.players end,
    find_thing = function(id)
        if id == "BP_Log_1" then return { id = id, name = "Oak Log", position = { 6, 0, 0 } } end
        return nil, { ok = false, reason = "unknown_target", data = { target = id } }
    end,
}
local ctx = { api = api }

local function run_cast(args, opts)
    opts = opts or {}
    local r = SP.HANDLERS.cast(nil, args, ctx)
    if not r.wait then return r, 0 end
    local w, deadline, steps = r.wait, T + r.wait_s, 0
    while true do
        T = T + 0.1; steps = steps + 1
        if opts.during then opts.during(steps) end
        tick()
        local res = w.poll(w)
        if not res and T >= deadline then res = w.expire(w) end
        if res then return res, steps end
        if steps > 400 then return { ok = false, reason = "test_hang" }, steps end
    end
end
local function presses() return table.concat(G.presses, ",") end

-- ---------------------------------------------------------------- pure: resolve
do
    local rows = { { id = "USD_Windstep", name = "Windstep" }, { id = "USD_FireBolt", name = "Fire Bolt" }, { id = "USD_FireBold", name = "Fire Bold" } }
    check("resolve exact name", (SP.resolve(rows, "windstep") or {}).id == "USD_Windstep")
    check("resolve exact asset", (SP.resolve(rows, "USD_Windstep") or {}).id == "USD_Windstep")
    local r, _, d = SP.resolve(rows, "Windstpe")
    check("resolve unique typo", r and r.id == "USD_Windstep" and d.matched == "typo")
    local r2, why2, d2 = SP.resolve(rows, "Wind")
    check("resolve never substitutes a partial name", r2 == nil and why2 == "unknown_target" and #d2.candidates == 3, why2)
    local r3, why3, d3 = SP.resolve(rows, "Fire Bolx")
    check("resolve ambiguous typo -> candidates", r3 == nil and why3 == "ambiguous_target" and #d3.candidates == 2, why3)
    local r4, why4, d4 = SP.resolve({}, "Windstep")
    check("resolve with no spells says so", r4 == nil and why4 == "unknown_target" and d4.detail:find("haven't unlocked", 1, true))
end

-- ---------------------------------------------------------------- pure: harm floor
do
    local luis2 = { { name = "Zezima", position = { 2, 0, 0 } } }
    check("self enchant (damage module, no area) with Luis at 2 m is allowed",
        SP.harm_check({ name = "Enchant", harmful = true, cast_type = 0 }, nil, { 0, 0, 0 }, luis2) == nil)
    local h = SP.harm_check({ name = "Rock Blast", harmful = true, cast_type = 1 }, nil, { 2.5, 0, 0 }, luis2)
    check("damaging placed spell at Luis's feet is unsafe", h and h.unsafe and h.player == "Zezima" and h.radius_m == 5)
    check("damaging placed spell far from Luis is fine", SP.harm_check({ name = "Rock Blast", harmful = true, cast_type = 1 }, nil, { 20, 0, 0 }, luis2) == nil)
    local h2 = SP.harm_check({ name = "Confuse", role = "combat_cc", cast_type = 2 }, "Zezima", nil, luis2)
    check("hostile role never targets a player", h2 and h2.unsafe)
    local h3 = SP.harm_check({ name = "Blast", harmful = true, has_shape = true, radius_m = 3, cast_type = 0 }, nil, { 0, 0, 0 }, luis2)
    check("self-centred blast (damage + shape) near Luis is unsafe", h3 and h3.radius_m == 3)
    check("shelter (no damage) next to Luis is fine", SP.harm_check({ name = "Summon Shelter", cast_type = 1 }, nil, { 2, 0, 0 }, luis2) == nil)
    check("windstep (combat_cc role, instant, no damage module) next to Luis is fine",
        SP.harm_check({ name = "Windstep", role = "combat_cc", cast_type = 0 }, nil, { 0, 0, 0 }, luis2) == nil)
end

-- ---------------------------------------------------------------- listing
reset()
do
    local r = SP.HANDLERS.spells(nil, {}, ctx)
    local w = r.ok and r.data.spells[1]
    check("spells: one unlocked row", r.ok and #r.data.spells == 1 and r.data.unlocked_n == 1)
    check("spells: SpellBook shape", w and w.id == "USD_Windstep" and w.name == "Windstep" and w.role == "instant"
        and w.use_when:find("Jump higher", 1, true) and w.castable == true and w.reason == nil and w.remaining_s == 0)
    check("spells: cost vs carried", w and w.cost[1].count == 5 and w.cost[1].have == 821 and w.wheel_slot == 0)
    local ra = SP.HANDLERS.spells(nil, { all = true }, ctx)
    local sh
    for _, x in ipairs(ra.data.spells) do if x.id == "USD_SummonShelter" then sh = x end end
    check("spells all: locked row with level reason", sh and sh.reason == "not_unlocked" and sh.needs.level == 20 and sh.needs.have == 1
        and sh.detail:find("Construction level 20", 1, true) and sh.castable == false, sh and sh.detail)
    check("spells all: unlocked first", ra.data.spells[1].id == "USD_Windstep" and ra.data.locked_listed == 1)
end

-- ---------------------------------------------------------------- cast: instant happy path
reset()
do
    local res = run_cast({ spell = "windstep" })
    check("cast instant ok", res.ok, res.reason)
    local d = res.data or {}
    check("cast instant presses Q then key 1", presses() == "menu,quick0", presses())
    check("cast instant verified runes + cooldown", d.verified and d.runes_spent[AIR] == 5 and d.cooldown_started)
    check("cast instant effect evidence", d.effect_verified == true and d.effects.ge[1] == "GE_USD_Windstep_Instance")
    check("cast instant names the spell", d.spell == "Windstep")
    check("cast instant releases the pawn", A.owner() == nil)
    check("cast instant leaves gameplay mode", G.mode == "DIM_Gameplay" and d.cancelled_mode == nil)
    -- immediately again: the local cooldown record is a pre-check only; the game decides
    local res2 = run_cast({ spell = "Windstep" })
    check("second cast within cooldown still attempted (precheck reported)", res2.data.precheck == "on_cooldown", res2.data.precheck)
end

-- ---------------------------------------------------------------- cast: gates
reset({ items = { [AIR] = 3 } })
do
    local res = run_cast({ spell = "Windstep" })
    check("no runes -> not_enough_resources, no presses", res.reason == "not_enough_resources" and #G.presses == 0)
    check("no runes detail is truthful", (res.data.detail or ""):find("needs 5 Air Rune and I only have 3", 1, true), res.data.detail)
end
reset({ wheel = {} })
do
    local res = run_cast({ spell = "Windstep" })
    check("not on wheel", res.reason == "not_on_wheel" and #G.presses == 0, res.reason)
end
reset({ wheel = { false, false, false, false, false, false, false, false, "USD_Windstep" } })
do
    local res = run_cast({ spell = "Windstep" })
    check("slot 9 (no number key): highlight, check the name, accept", res.ok and presses() == "menu,accept" and res.data.picked == "pointer", presses())
end
reset({ wheel = { false, false, false, false, false, false, false, false, "USD_Windstep" }, highlight_wrong = "Fire Spirit" })
do
    local res = run_cast({ spell = "Windstep" })
    check("highlight shows another spell -> nothing accepted", res.reason == "verification_failed" and res.data.why == "highlight_mismatch"
        and not presses():find("accept", 1, true) and (res.data.detail or ""):find("Fire Spirit", 1, true), presses())
end
reset()
do
    local res = run_cast({ spell = "Summon Shelter" })
    check("locked spell named exactly -> not_unlocked + needs", res.reason == "not_unlocked" and res.data.needs.level == 20, res.reason)
    local r2 = run_cast({ spell = "Fireball" })
    check("unknown spell -> unknown_target + candidates", r2.reason == "unknown_target" and r2.data.candidates[1] == "Windstep")
end
reset()
do
    G.falling = true
    local res = run_cast({ spell = "Windstep" })
    check("mid-air -> busy", res.reason == "busy" and (res.data.detail or ""):find("mid-air", 1, true))
end

-- ---------------------------------------------------------------- cast: game verdicts and failures
reset({ server_cooldown = true })
do
    local res = run_cast({ spell = "Windstep" })
    check("server cooldown RPC -> on_cooldown", res.reason == "on_cooldown", res.reason)
end
reset({ wheel_broken = true })
do
    local res = run_cast({ spell = "Windstep" })
    check("wheel never opens -> verification_failed after 2 tries", res.reason == "verification_failed" and res.data.why == "wheel_not_opened"
        and presses() == "menu,menu", presses())
    check("wheel failure releases the pawn", A.owner() == nil)
end
reset({ quick_no_select = true })
do
    local res = run_cast({ spell = "Windstep" })
    check("quick key ignored -> not_selected (never confirms an unknown slice)", res.reason == "verification_failed"
        and res.data.why == "not_selected" and presses() == "menu,quick0,menu", presses())
end
-- wheel pages: a spell on page 3 (slot 27 = page 3, key 4); the wheel opens on page 1
local page3 = {}
for i = 1, 48 do page3[i] = false end
page3[28] = "USD_Windstep"
reset({ wheel = page3 })
do
    local res = run_cast({ spell = "Windstep" })
    check("page 3 spell: flips pages until the slice shows it, then key 4", res.ok and presses() == "menu,next_page,next_page,quick3", presses())
    local r = SP.HANDLERS.spells(nil, {}, ctx)
    check("row carries page and key", r.data.spells[1].wheel_page == 3 and r.data.spells[1].wheel_key == 4)
end
reset({ wheel = page3, slow_pages = 0.8 })
do
    local res = run_cast({ spell = "Windstep" })
    check("slow slice refresh (0.8 s, live was ~0.4 s): waits for each page, no overshoot", res.ok and presses() == "menu,next_page,next_page,quick3", presses())
end
reset({ page = 2 })
do
    local res = run_cast({ spell = "Windstep" })
    check("wheel opens on another page: wraps round to page 1", res.ok and presses() == "menu,next_page,next_page,quick0", presses())
end
reset({ no_icons = true })
do
    local res = run_cast({ spell = "Windstep" })
    check("unreadable wheel -> no key pressed", res.reason == "verification_failed" and res.data.why == "wheel_unreadable"
        and not presses():find("quick", 1, true), presses())
end
reset({ unlocked = { WINDSTEP, SHELTER }, wheel = { "USD_Windstep", "USD_SummonShelter" } })
do
    local real = W.selected
    W.selected = function() return "USD_Windstep" end
    local res = run_cast({ spell = "Summon Shelter", target = { 4, 0, 0 } })
    W.selected = real
    check("placement mode for another spell -> cancel, wrong_spell", res.reason == "verification_failed" and res.data.why == "wrong_spell"
        and presses() == "menu,quick1,cancel", presses())
end
reset({ no_effect = true })
do
    local res = run_cast({ spell = "Windstep" })
    check("no rune/cooldown change -> verification_failed no_effect", res.reason == "verification_failed" and res.data.why == "no_effect", res.reason)
end

-- ---------------------------------------------------------------- cast: placed
reset({ unlocked = { WINDSTEP, SHELTER }, wheel = { "USD_Windstep", "USD_SummonShelter" }, skills = {} })
do
    local res = run_cast({ spell = "Summon Shelter", target = { 6, 2, 0 } })
    check("placed ok", res.ok, res.reason)
    check("placed presses Q, key 2, LMB", presses() == "menu,quick1,place", presses())
    check("placed aims at the target", G.aimed and G.aimed[1] == 6 and G.aimed[2] == 2)
    check("placed reports landed_at + distance", res.data.landed_at and res.data.landed_dist_m == 0 and res.data.spell_actor ~= nil)
    check("placed spent both runes", res.data.runes_spent[EARTH] == 10 and res.data.runes_spent[AST] == 10)
end
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, land_offset = 9 })
do
    local res = run_cast({ spell = "Summon Shelter", target = "BP_Log_1" })
    check("placed landed elsewhere -> verification_failed with distance", res.reason == "verification_failed" and res.data.why == "landed_elsewhere"
        and (res.data.detail or ""):find("landed 9 m", 1, true), res.data.detail)
end
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" } })
do
    local res = run_cast({ spell = "Summon Shelter" })
    check("placed without target casts in front", res.ok and res.data.target == nil and res.data.landed_dist_m == nil, res.reason)
end

-- ---------------------------------------------------------------- cast: placed, spot chosen by Claude + the game's preview
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, invalid_spots = { ["3,0"] = true, ["4,0"] = true } })
do
    local res = run_cast({ spell = "Summon Shelter" })
    check("no target: straight ahead refused (ground tag) -> flat spots; first red, second green -> placed there",
        res.ok and res.data.spot and res.data.spot[2] == 4 and presses() == "menu,quick0,place", presses())
    check("auto spot: the game's reason for the rejected spot is kept", res.data.rejected and res.data.rejected[1].game == "Spell.Placement.Invalid.Slope")
    check("auto spot: landed_at reported", res.data.landed_at ~= nil)
end
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, invalid_spots = { all = true } })
do
    local res = run_cast({ spell = "Summon Shelter" })
    check("no spot accepted -> nothing_in_range no_valid_spot + cancel", res.reason == "nothing_in_range" and res.data.why == "no_valid_spot"
        and presses() == "menu,quick0,cancel" and #res.data.rejected == 4 and (res.data.detail or ""):find("the game says: slope", 1, true)
        and res.data.flat_spot ~= nil and (res.data.detail or ""):find("walk there", 1, true), (res.data.detail or "") .. " " .. presses())
    check("no runes spent when nothing placed", G.items[EARTH] == 500)
end
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, no_spots = true, invalid_spots = { ["3,0"] = true } })
do
    local res = run_cast({ spell = "Summon Shelter" })
    check("no flat ground at all -> nothing_in_range no_valid_spot, cancelled", res.reason == "nothing_in_range" and res.data.why == "no_valid_spot"
        and presses() == "menu,quick0,cancel", res.reason .. " " .. presses())
end
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, no_preview = true })
do
    local res = run_cast({ spell = "Summon Shelter" })
    check("preview unreadable -> places straight ahead, says so", res.ok and res.data.preview == "unreadable", res.reason)
end
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, invalid_spots = { ["6,2"] = true } })
do
    local res = run_cast({ spell = "Summon Shelter", target = { 6, 2, 0 } })
    check("named target red -> placed just beside it (within tolerance, ok)", res.ok and res.data.spot[1] == 8 and res.data.landed_dist_m == 2, res.reason)
end

reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, slow_cast = 6 })
do
    local res = run_cast({ spell = "Summon Shelter" })
    check("slow cast animation (6 s, live > 4 s): waits, no Esc, verified", res.ok and presses() == "menu,quick0,place" and res.data.runes_spent[EARTH] == 10, presses())
end
-- late success: the game finishes the cast after the answer (live 20:44: shelter stood, result said failed)
do
    local loops = {}
    _G.LoopInGameThreadWithDelay = function(ms, fn) loops[#loops + 1] = fn; return #loops end
    _G.CancelDelayedAction = function() end
    local tmp = os.tmpname()
    SP.LATE_EVENT_PATH = tmp
    reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, slow_cast = 16 })
    local res = run_cast({ spell = "Summon Shelter" })
    check("very slow cast -> answer is a failure first", res.ok == false, res.reason)
    local done
    for _ = 1, 20 do T = T + 1; tick(); for _, fn in ipairs(loops) do if fn() then done = true end end; if done then break end end
    local f = io.open(tmp, "rb"); local txt = f and f:read("a") or ""; if f then f:close() end
    check("late success -> activity event cast_late_success", done and txt:find("cast_late_success", 1, true) and txt:find("did go off after all", 1, true), txt)
    os.remove(tmp)
    _G.LoopInGameThreadWithDelay, _G.CancelDelayedAction = nil, nil
end
-- a wheel left open by an earlier attempt is closed first ("a previous cast was still in progress")
reset()
do
    G.mode = "DIM_RadialMenu"
    local res = run_cast({ spell = "Windstep" })
    check("leftover wheel closed, then cast", res.ok and res.data.closed_previous == "DIM_RadialMenu" and presses() == "menu,menu,quick0", presses())
end
-- L1: the game's own special requirement (Logging Axe) is reported and blocks the cast
reset({ unlocked = { AXTRAL }, wheel = { "USD_TestAxe" }, req = { USD_TestAxe = "UI.ConsumeItem.RequiresLoggingAxe" } })
do
    local r = SP.HANDLERS.spells(nil, {}, ctx).data.spells[1]
    check("requirement row: castable false, reason requirement, needs the game's text", r.castable == false and r.reason == "requirement"
        and r.needs == "Logging Axe" and (r.detail or ""):find("needs Logging Axe", 1, true), r.detail)
    local res = run_cast({ spell = "Astral Axe", target = { 6, 0, 0 } })
    check("requirement blocks before any key press", res.reason == "requirement" and #G.presses == 0, res.reason)
end
reset({ unlocked = { AXTRAL }, wheel = { "USD_TestAxe" }, quick_no_select = true })
do
    local res = run_cast({ spell = "Astral Axe" })
    check("not_selected names the game's requirement", (res.data.detail or ""):find("the game says it needs: Logging Axe", 1, true), res.data.detail)
end
-- L14: an aimed spell with a preview: aim at the trunk, re-aim until the preview turns valid, then release
reset({ unlocked = { AXTRAL }, wheel = { "USD_TestAxe" }, aim_valid_after = 2,
        foliage = { ["fol:Tree_7:2"] = { id = "fol:Tree_7:2", name = "Oak Tree", position = { 6, 0, 0 } } } })
do
    local res = run_cast({ spell = "Astral Axe", target = "fol:Tree_7:2" })
    check("aimed: foliage target resolved, re-aimed until valid, then released", res.ok and presses() == "menu,quick0,place"
        and G.aims >= 2, tostring(res.reason) .. " " .. presses() .. " aims=" .. tostring(G.aims))
    check("aimed: aims at the body (1.2 m up), not the base", res.data.aim_height_m == 1.2 and G.aimed[3] == 1.2)
    check("aimed: target state reported", res.data.target_after ~= nil)
end
reset({ unlocked = { AXTRAL }, wheel = { "USD_TestAxe" }, aim_valid_after = 99 })
do
    local res = run_cast({ spell = "Astral Axe", target = { 6, 0, 0 } })
    check("aimed never valid -> no_valid_aim with the game's words, nothing thrown", res.reason == "verification_failed" and res.data.why == "no_valid_aim"
        and not presses():find("place", 1, true) and (res.data.detail or ""):find("no target", 1, true), (res.data.detail or "") .. " " .. presses())
end
reset({ cooldown_then_spend = true })
do
    local res = run_cast({ spell = "Windstep" })
    check("L13: a cooldown notice followed by the rune spend is a success", res.ok and res.data.runes_spent[AIR] == 5, res.reason)
end
reset({ unlocked = { AXTRAL }, wheel = { "USD_TestAxe" } })
do
    local res = run_cast({ spell = "Astral Axe", target = "fol:Gone_1:1" })
    check("foliage target gone -> unknown_target says felled or picked", res.reason == "unknown_target"
        and (res.data.detail or ""):find("felled or picked", 1, true), res.data.detail)
end
-- L15: a placed spell aimed at an OBJECT (Splinter on a log): aim at the object, never flat-ground spots
local SPLINTER = spell({ asset = "USD_TestSplinter", name = "Wood Splitter", desc = "Splits a log.", cast_type = 1,
                         cost = { { item = EARTH, name = "Earth Rune", count = 10 } }, perk = { level = 3, skill = "SKILL_Woodcutting", skill_name = "Woodcutting" } })
reset({ unlocked = { SPLINTER }, wheel = { "USD_TestSplinter" }, aim_valid_after = 1,
        foliage = {} })
do
    local res = run_cast({ spell = "Wood Splitter", target = "BP_Log_1" })
    check("L15: placed spell on a log: aims low at the log (an actor), valid, LMB", res.ok and presses() == "menu,quick0,place" and res.data.aim_height_m == 0.3,
        tostring(res.reason) .. " " .. presses())
end
reset({ unlocked = { SPLINTER }, wheel = { "USD_TestSplinter" }, aim_valid_after = 1 })
do
    G.centers = { BP_Log_1 = { 7.5, 1, 0 } }
    local res = run_cast({ spell = "Wood Splitter", target = "BP_Log_1" })
    check("L15: a log is aimed at its real centre (game midpoint), not the stale origin", res.ok and G.aimed[1] == 7.5 and G.aimed[2] == 1, presses())
end
reset({ unlocked = { SPLINTER }, wheel = { "USD_TestSplinter" }, aim_valid_after = 99 })
do
    local t0 = T
    local res = run_cast({ spell = "Wood Splitter", target = "BP_Log_1" })
    check("L15: never valid on the log -> no_valid_aim, cancelled before casting, no ground search", res.reason == "verification_failed"
        and res.data.why == "no_valid_aim" and presses() == "menu,quick0,cancel" and not res.data.flat_spot, presses())
    check("L15: fails fast (about 6 s, not 22)", T - t0 <= 7, T - t0)
    check("L15: says it cancelled, with the game's words", (res.data.detail or ""):find("cancelled the spell", 1, true)
        and (res.data.detail or ""):find("no target", 1, true), res.data.detail)
end
-- success while the game is still in its cast mode: no Esc into the animation, full evidence after
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" } })
do
    G.cast_mode_after = 1.5
    local res = run_cast({ spell = "Summon Shelter" })
    check("success in cast mode: waits for the game to leave it, no Esc", res.ok and not presses():find("cancel", 1, true)
        and res.data.cancelled_mode == nil, presses() .. " " .. tostring(res.data.cancelled_mode))
end
-- the game's "not flat" verdict teaches the spread limit: equally uneven spots are skipped
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, invalid_spots = { ["3,0"] = true, ["4,0"] = true }, not_flat = true })
do
    local res = run_cast({ spell = "Summon Shelter" })
    check("learned flatness: after a 0.1 m spot is 'not flat', rougher spots are skipped", res.reason == "nothing_in_range"
        and #res.data.rejected == 2 and SP.mem().bad_spread == 0.1, tostring(res.reason) .. " " .. tostring(res.data.rejected and #res.data.rejected))
    check("tag in words", SP.tag_words("UI.Notification.SpellPlacement.GroundNotFlatEnough") == "ground not flat enough")
end

-- ---------------------------------------------------------------- cast: safety floor
reset({ unlocked = { BLAST }, wheel = { "USD_TestBlast" }, players = { { name = "Zezima", id = "BP_PlayerCharacter_C_1", position = { 4, 0, 0 } } } })
do
    local res = run_cast({ spell = "Rock Blast", target = { 4.5, 0, 0 } })
    check("damaging placed spell near Luis -> unsafe, no presses", res.reason == "unsafe" and #G.presses == 0 and res.data.player == "Zezima", res.reason)
    local r2 = run_cast({ spell = "Rock Blast", target = "Zezima" })
    check("damaging spell at a player -> unsafe", r2.reason == "unsafe" and (r2.data.detail or ""):find("won't cast", 1, true), r2.reason)
end
reset({ unlocked = { ENCHANT }, wheel = { "USD_TestEnchant" }, players = { { name = "Zezima", id = "p1", position = { 2, 0, 0 } } } })
do
    local res = run_cast({ spell = "Enchant Weapon: Air" })
    check("self enchant with Luis at 2 m is cast", res.ok, res.reason)
end

-- ---------------------------------------------------------------- cast: arbiter
reset()
do
    local resumed = false
    fake_move.mode = "follow"
    local f = A.request(nil, { name = "follow", level = "command", resumable = true, uses_move = true,
                               on_resume = function() resumed = true; return true end })
    check("follow owns the pawn", f.ok)
    local res = run_cast({ spell = "Windstep" })
    check("cast suspends then resumes follow", res.ok and res.data.preempted == "follow" and res.data.resumed == "follow" and resumed,
        tostring(res.data.preempted) .. "/" .. tostring(res.data.resumed))
    check("follow owns the pawn again", A.owner() and A.owner().name == "follow")
end
reset()
do
    A.request(nil, { name = "combat:guard", level = "reflex", resumable = false, uses_move = false })
    local res = run_cast({ spell = "Windstep" })
    check("reflex fight -> busy, says fighting", res.reason == "busy" and res.data.detail == "I can't cast while I'm fighting yet." and #G.presses == 0,
        res.data.detail)
end
reset()
do
    local res = run_cast({ spell = "Windstep" }, { during = function(n) if n == 2 then _G.DW_PAUSE = true end end })
    check("pause mid-cast -> companion_down", res.reason == "companion_down", res.reason)
    check("no presses after the pause", presses() == "menu", presses())
end
reset()
_G.DW_PAUSE = true
do
    local r = SP.HANDLERS.spells(nil, {}, ctx)
    check("spells while paused -> companion_down", r.reason == "companion_down")
end

-- ---------------------------------------------------------------- combat contract (defense-abilities.md section 4)
reset()
do
    local st = SP.ability_status("USD_Windstep", api)
    check("ability_status: available, route, latency estimate", st.available == true and st.runes_ok == true and st.route.page == 1
        and st.route.key == 1 and type(st.latency_s) == "number" and st.latency_s > 0, st.why)
    local st2 = SP.ability_status("USD_SummonShelter", api)
    check("ability_status: not unlocked", st2.available == false and st2.why == "not_unlocked")
end
reset()
do
    -- live bug: cast records (wall clock) compared with another api's clock gave a 1.79e9 s cooldown
    local wall = SP.wall
    SP.wall = function() return 1.79e9 end
    SP.mem().cast_at["USD_Windstep"] = 1.79e9 - 10
    local other = setmetatable({ now = function() return 100 end }, { __index = api })
    local st = SP.ability_status("USD_Windstep", other)
    SP.wall = wall
    check("cooldown uses one wall clock whatever the api's clock", st.available == true and st.cooldown_s == 0, tostring(st.cooldown_s))
end
reset({ items = { [AIR] = 2 } })
do
    local st = SP.ability_status("USD_Windstep", api)
    check("ability_status: no runes -> runes_ok false", st.available == false and st.runes_ok == false and st.why == "not_enough_resources")
end
reset()
do
    local f = A.request(nil, { name = "combat:fight", level = "reflex", resumable = false, uses_move = true })
    local job = SP.cast_now(nil, "USD_Windstep", { owner_token = f.token, api = api })
    local res
    for _ = 1, 100 do T = T + 0.1; tick(); res = job.poll(); if res then break end end
    check("cast_now under combat's reflex token: cast, cast_t, no 'fighting' refusal", res and res.ok and res.cast_t ~= nil
        and presses() == "menu,quick0", res and (tostring(res.reason) .. " " .. presses()))
    check("cast_now never releases combat's token", A.owner() and A.owner().name == "combat:fight" and A.holds(f.token))
    local st = SP.ability_status("USD_Windstep", api)
    check("cast_now measures the latency for ability_status", st.latency_measured == true and st.latency_s == res.latency_s, tostring(st.latency_s))
    check("a repeat poll returns the same result", job.poll() == res)
end
reset()
do
    SP.mem().cast_at["USD_Windstep"] = T -- just cast: still recharging
    local job = SP.cast_now(nil, "USD_Windstep", { api = api })
    local res = job.poll()
    check("cast_now on cooldown: answered at once, no key pressed", res.ok == false and res.reason == "on_cooldown" and #G.presses == 0, res.reason)
end

-- ---------------------------------------------------------------- L25: delayed replication
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, delayed = { runes = 3.0, cooldown = 5.0 } })
do
    local res = run_cast({ spell = "Summon Shelter" })
    check("L25: actor first, runes at 3 s, cooldown at 5 s -> one reply with all three", res.ok and res.data.settled == true
        and res.data.runes_spent[EARTH] == 10 and res.data.cooldown_started == true and res.data.spell_actor ~= nil,
        tostring(res.data.settled) .. " " .. tostring(res.data.cooldown_started))
end
reset({ delayed = { runes = 0.4, cooldown = false } })
do
    local t0 = T
    local res = run_cast({ spell = "Windstep" })
    check("L25: cooldown never replicates -> ok, settled=false, the gap named, bounded", res.ok and res.data.settled == false
        and res.data.unsettled[1] == "cooldown_started" and T - t0 <= SP.cfg.settle_s + 3, tostring(T - t0))
end
reset({ unlocked = { SHELTER }, wheel = { "USD_SummonShelter" }, preview_off = 3.2 })
do
    local res = run_cast({ spell = "Summon Shelter", target = { 6, 2, 0 } })
    check("L25: a valid ground preview 3.2 m off the asked point is accepted (the shelter centres itself)", res.ok, res.reason)
end
-- L25: a spell that keeps its own mode open records its cooldown only when the mode ends (Eye of Oculus)
reset()
do
    G.cooldown_on_leave = true
    G.delayed = { runes = 0.4, cooldown = false }
    G.stay_in_mode = true
    local res = run_cast({ spell = "Windstep" })
    check("L25: own-mode spell: leaves the mode after the settle wait, the cooldown lands, settled", res.ok and res.data.settled == true
        and res.data.left_mode == "DIM_SpellcastingMode" and res.data.cooldown_started == true, tostring(res.data.settled) .. " " .. presses())
end
-- L27: page turns the short way, timing breakdown
local p3 = {}
for i = 1, 48 do p3[i] = false end
p3[1] = "USD_Windstep"
p3[13] = "USD_SummonShelter"
reset({ unlocked = { WINDSTEP, SHELTER }, wheel = p3, page = 1 })
do
    local res = run_cast({ spell = "Windstep" })
    check("L27: wheel open on page 2, spell on page 1 -> one page back, not three forward", res.ok and presses() == "menu,prev_page,quick0", presses())
    local tm = res.data.timing or {}
    check("L27: timing breakdown reported", type(tm.total_s) == "number" and tm.page_turns == 1 and type(tm.open_s) == "number", tostring(tm.total_s))
end
do
    local icon_of = { A = "ia", B = "ib" }
    local wheel = {}
    for i = 1, 24 do wheel[i] = false end
    wheel[1], wheel[13] = "A", "B"
    check("page_of: finds the shown page from icons", SP.page_of({ "ib" }, wheel, 12, icon_of) == 1 and SP.page_of({ "ia" }, wheel, 12, icon_of) == 0
        and SP.page_of({ "zz" }, wheel, 12, icon_of) == nil)
end
-- L26: no raw ids in speech
reset({ unlocked = { AXTRAL }, wheel = { "USD_TestAxe" } })
do
    local res = run_cast({ spell = "Astral Axe", target = "fol:Gone_1:1" })
    check("L26: the detail never speaks a raw id", not (res.data.detail or ""):find("fol:", 1, true) and res.data.target == "fol:Gone_1:1", res.data.detail)
end

-- ---------------------------------------------------------------- manifest / contract
do
    check("handlers", type(SP.HANDLERS.cast) == "function" and type(SP.HANDLERS.spells) == "function")
    local c, s = SP.MANIFEST.cast, SP.MANIFEST.spells
    check("manifest cast is an llm waiter", c.llm == true and c.kind == "waiter" and c.moves == false and c.args.required[1] == "spell")
    check("manifest spells is an llm read", s.llm == true and s.kind == "read")
    check("needs listed", SP.NEEDS.cast and SP.NEEDS.spells)
    -- no spell names in code (generality): the module source never names a game spell
    local f = assert(io.open(SRC, "rb")); local src = f:read("a"); f:close()
    local named = {}
    for _, n in ipairs({ "Windstep", "Shelter", "Tempest", "Mending", "Fire Spirit", "USD_" }) do
        for line in src:gmatch("[^\n]+") do
            if line:find(n, 1, true) and not line:match("^%s*%-%-") and not line:find("gsub(\"^USD_\"", 1, true) then named[#named + 1] = n .. ": " .. line end
        end
    end
    check("no spell names in code", #named == 0, named[1])
end

print(string.format("test_spells: %d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)

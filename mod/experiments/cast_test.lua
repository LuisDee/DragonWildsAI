-- Stand-still cast test: prove the `self_effect` route (body/spells.lua) end to end on the PUPPET with
-- the safest harmless self spell, Fire Spirit (USD_FireSpirit: GE_FireSpirit on SpellOwner, a light
-- sprite that follows the caster; no damage, no effect on anyone else; instance
-- UFireSpiritGameplayEffectInstance spawns an AFireSpirit bound to the target character).
-- Why this route: GameplayEffectsComponent:InstantiateGameplayEffect(class, nil, false) takes plain
-- args and skips the spell module graph, so no SpellModule_CostItems (the null-PlayerController
-- inventory read, R8) and no montage/targeting modules. Tempest Shield is NOT used: its MaxHealth
-- needs the caster's Attack level, which lives on a PlayerController the puppet lacks.
--   debug_run {"module":"cast_test"}                                       read-only check
--   {"action":"cast","confirm":true}                                        cast on the puppet; refuses
--        unless every player is >= min_player_m (10) from it. load=true allows LoadAsset of the GE class.
--   {"action":"remove","confirm":true}                                      Remove() the Fire Spirit instance
local U = require("body.util")

local M = {}

M.SPELL = "USD_FireSpirit"
M.MIN_PLAYER_M = 10

local function puppet()
    local players, puppets = U.split_pawns()
    return puppets[1], players
end

local function instances(p)
    local out = {}
    local gec = U.try(function() return p.GameplayEffectsComponent end)
    if not U.valid(gec) then return out, nil end
    for _, field in ipairs({ "ReplicatedInstances", "NonReplicatedInstances" }) do
        local arr = U.try(function() return gec[field] end)
        if arr then
            pcall(function()
                arr:ForEach(function(_, e)
                    local g = U.try(function() return e:get() end) or e
                    out[#out + 1] = { obj = g, cls = U.class_word(g) or "?", field = field }
                end)
            end)
        end
    end
    return out, gec
end

local function names(list)
    local n = {}
    for _, i in ipairs(list) do n[#n + 1] = i.cls end
    return n
end

local function effect_path(spells)
    local meta = spells.META[M.SPELL] or {}
    if meta.effect then return meta.effect end
    local c = spells.catalog and spells.catalog() or nil
    local rec = c and c.spells and c.spells[M.SPELL]
    for _, m in ipairs(rec and rec.modules or {}) do
        if m.kind == "SpellModule_GameplayEffect" and m.target == "SpellOwner" then return m.effect end
    end
    return "/Game/Gameplay/UtilityMagic/PerkSpells/FireSpirit/GE_FireSpirit.GE_FireSpirit_C"
end

local function sprites()
    local n = 0
    for _ in ipairs(U.find_all("FireSpirit")) do n = n + 1 end
    return n
end

function M.check(log)
    local spells = require("body.spells")
    local p, players = puppet()
    local path = effect_path(spells)
    local res = { ok = true, spell = M.SPELL, route = spells.route(M.SPELL), effect = path,
                  effect_loaded = U.valid(U.try(StaticFindObject, path)), puppet = p and U.short(p) or nil,
                  fire_spirit_actors = sprites() }
    if p then
        local inst = instances(p)
        res.instances = names(inst)
        res.players = {}
        for _, pl in ipairs(players) do res.players[#res.players + 1] = { name = U.player_name(pl), d_m = U.cm_to_m(U.actor_dist(p, pl)) } end
    end
    U.event(log, "cast_test_check", res)
    return res
end

function M.cast(log, args)
    if args.confirm ~= true then return { ok = false, error = "refused: pass confirm=true (casts Fire Spirit on the puppet)" } end
    local spells = require("body.spells")
    local p, players = puppet()
    if not p then return { ok = false, error = "no puppet (spawn it near Luis first: body_spawn)" } end
    local min_m = tonumber(args.min_player_m) or M.MIN_PLAYER_M
    for _, pl in ipairs(players) do
        local d = U.actor_dist(p, pl) / 100
        if d < min_m then return { ok = false, error = ("refused: %s is %.1f m from the puppet (needs >= %d m)"):format(U.player_name(pl) or "a player", d, min_m) } end
    end
    local path = effect_path(spells)
    if not U.valid(U.try(StaticFindObject, path)) then
        if args.load ~= true then return { ok = false, error = "effect class not loaded; pass load=true to LoadAsset it", effect = path } end
        U.call(log, "cast_test.LoadAsset", { path = path }, function() LoadAsset(path) end)
    end
    local before = instances(p)
    local sp_before = sprites()
    local r = spells._ROUTE_FN.self_effect(p, M.SPELL, nil, {})
    local after = instances(p)
    local res = { ok = r.ok, reason = r.reason, route_data = r.data, instances_before = names(before),
                  instances_after = names(after), fire_spirit_actors_before = sp_before, fire_spirit_actors_after = sprites() }
    U.event(log, "cast_test_cast", res)
    return res
end

function M.remove(log, args)
    if args.confirm ~= true then return { ok = false, error = "refused: pass confirm=true" } end
    local p = puppet()
    if not p then return { ok = false, error = "no puppet" } end
    local removed = 0
    for _, i in ipairs(instances(p)) do
        if i.cls:find("FireSpirit", 1, true) then
            local ok = U.call(log, "cast_test.Remove", { cls = i.cls }, function() i.obj:Remove() end)
            if ok then removed = removed + 1 end
        end
    end
    return { ok = true, removed = removed, instances_after = names(instances(p)), fire_spirit_actors = sprites() }
end

function M.run(log, args)
    args = args or {}
    local fn = ({ check = M.check, cast = M.cast, remove = M.remove })[args.action or "check"]
    if not fn then return { ok = false, error = "action is check, cast or remove" } end
    local ok, res = pcall(fn, log, args)
    if not ok then return { ok = false, error = tostring(res) } end
    return res
end

return M

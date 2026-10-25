-- Spawn a Summon Shelter for the bot (mechanically what the spell produces: a BP_Magic_SummonShelter_C
-- world actor) using the class of an existing live shelter, 3 m in front of the bot. The bot then
-- sleeps in it through the real bed path (sleep handler, mode=bed, target=<id>). UNVERIFIED route.
-- debug_run {module="shelter_spawn", args={confirm=true}}
local U = require("body.util")
local M = {}

function M.run(log, args)
    if not args.confirm then return { ok = false, error = "pass confirm=true" } end
    local _, puppets = U.split_pawns()
    local bot = puppets[1]
    if not U.alive(bot) then return { ok = false, error = "no bot" } end
    local template
    for _, a in ipairs(U.find_all("BP_Magic_SummonShelter_C")) do
        if U.alive(a) then template = a; break end
    end
    if not template then return { ok = false, error = "no live shelter to copy the class from" } end
    local cls = U.try(function() return template:GetClass() end)
    local at = U.in_front(bot, 300, 0)
    local yaw = U.try(function() return bot:K2_GetActorRotation().Yaw end) or 0
    local ok, shelter = U.call(log, "shelter_spawn.SpawnActor", { cls = U.fullname(cls), at = at }, function()
        return bot:GetWorld():SpawnActor(cls, at, { Pitch = 0, Yaw = yaw + 180, Roll = 0 })
    end)
    if not ok or not U.valid(shelter) then return { ok = false, error = tostring(shelter) } end
    -- The caster (shown as the shelter's owner in game) is the actor Owner/Instigator: a real cast sets
    -- both to the casting character (verified on Luis's shelter), so mirror that for the bot.
    U.call(log, "shelter_spawn.SetOwner", {}, function() shelter:SetOwner(bot) end)
    U.call(log, "shelter_spawn.Instigator", {}, function() shelter.Instigator = bot end)
    return { ok = true, shelter = U.short(shelter), class = U.fullname(cls), at = at,
             caster = U.fullname(U.try(function() return shelter:GetCaster() end)) }
end

return M

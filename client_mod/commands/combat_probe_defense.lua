-- READ-ONLY: what Claude's defence options are (combat.lua dodge/parry work): the block actions of
-- his shield/weapons (can he parry? which perk? costs), perk unlock state, the evade action, his
-- current montage, ping. No input, no movement.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local out = {}
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local spc = U.try(function() return pc.SkillPerkComponent end)
    local function perk(p)
        if not U.valid(p) then return nil end
        return { perk = U.short(p), unlocked = U.valid(spc) and U.try(function() return spc:IsPerkUnlocked(p) end) or nil }
    end
    out.block_actions = {}
    for _, path in ipairs({
        "/Game/Gameplay/Character/Player/Abilities/Block/PA_Block_Shield_Kite_Iron.Default__PA_Block_Shield_Kite_Iron_C",
        "/Game/Gameplay/Character/Player/Abilities/Block/PA_Block_Dagger.Default__PA_Block_Dagger_C",
        "/Game/Gameplay/Character/Player/Abilities/Block/PA_Block_PickAxe.Default__PA_Block_PickAxe_C" }) do
        local cdo = U.find_object(path)
        local d = { path = path:match("Default__([%w_]+)"), found = cdo ~= nil }
        if cdo then
            d.can_parry = U.try(function() return cdo.bCanParry end)
            d.parry_perk = perk(U.try(function() return cdo.SkillPerkRequiredToParry end))
            d.required_perk = perk(U.try(function() return cdo.RequiredPerk end))
            d.block_cost = U.try(function() return cdo.BlockStaminaCost end)
            d.parry_cost = U.try(function() return cdo.ParryStaminaCost end)
            d.parry_refund = U.try(function() return cdo.ParryRefundMultiplier end)
            d.can_special_parry = U.try(function() return cdo.bCanSpecialParry end)
            d.requires_holding = U.try(function() return cdo.bRequiresHolding end)
        end
        out.block_actions[#out.block_actions + 1] = d
    end
    -- the action performer: default evade action and its CDO
    for _, c in ipairs(U.find_all("PlayerActionPerformer", { skip_defaults = true })) do
        local o = U.try(function() return c:GetOwner() end)
        if U.valid(o) and U.short(o) == U.short(pawn) then
            local cls = U.try(function() return c.DefaultEvadeAction end)
            out.evade_action = U.valid(cls) and U.short(cls) or tostring(cls)
            local cdo = U.valid(cls) and U.try(function() return cls:GetCDO() end)
            if U.valid(cdo) then out.evade_required_perk = perk(U.try(function() return cdo.RequiredPerk end)) end
        end
    end
    local bl
    for _, c in ipairs(U.find_all("PlayerBlockingComponent", { skip_defaults = true })) do
        local o = U.try(function() return c:GetOwner() end)
        if U.valid(o) and U.short(o) == U.short(pawn) then bl = c end
    end
    if bl then out.blocking = { parry_window = U.try(function() return bl.ParryWindowLength end),
        mitigation = U.try(function() return bl.ParryDamageMitigationPercentage end),
        min_block = U.try(function() return bl.MinimumBlockDuration end), anims = U.short(U.try(function() return bl.ParryAnims end)) } end
    local ai = U.try(function() return pawn.Mesh:GetAnimInstance() end)
    out.montage = U.valid(ai) and U.short(U.try(function() return ai:GetCurrentActiveMontage() end)) or nil
    local ps = U.try(function() return pc.PlayerState end)
    out.ping_ms = U.valid(ps) and (U.try(function() return ps:GetPingInMilliseconds() end) or U.try(function() return ps.CompressedPing * 4 end)) or nil
    out.ping_exact = U.valid(ps) and U.try(function() return ps.ExactPing end) or nil
    out.special_charge = U.try(function() return pawn.SpecialChargeComponent:GetSpecialCharge() end)
    return out
end

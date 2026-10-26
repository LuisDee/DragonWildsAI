-- READ-ONLY skills probe P1 (docs/design/every-skill-coverage.md §4, §6): fishing nodes, the pawn's fishing
-- component settings, agility course actors, anima vents, rune altars, farm slots, and the category tags of
-- carried fishing tools. Property reads and pure getters only: never presses, never moves, never a UI handler.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local B = inst.module
    local s = B.API.module("sense")
    local U = s and s.U
    if not U then return { ok = false, reason = "no sense" } end
    local function str(x) local v = U.str(x); if v and v ~= "" then return v end end
    local function num(f) local ok, x = pcall(f); if ok and type(x) == "number" then return x end end
    local function bool(f) local ok, x = pcall(f); if ok then return x == true end end
    local pc = s.local_pc()
    local pawn = s.local_pawn(pc)
    local me = pawn and U.loc(pawn)
    local function dist(a) local p = U.loc(a); return (p and me) and math.floor(U.dist2d(p, me)) / 100 or nil end
    local out = { ok = true, me = me }
    local function list(cls, fn, max)
        local rows = {}
        for _, a in ipairs(U.find_all(cls, { skip_defaults = true }) or {}) do
            if U.alive(a) then
                local r = { id = U.short(a), class = U.class_word(a), d = dist(a), pos = U.loc(a) }
                if fn then pcall(fn, a, r) end
                rows[#rows + 1] = r
            end
        end
        table.sort(rows, function(x, y) return (x.d or 1e9) < (y.d or 1e9) end)
        local cut = {}
        for i = 1, math.min(#rows, max or 8) do cut[i] = rows[i] end
        return { n = #rows, nearest = cut }
    end
    out.fishing_nodes = list("FishingNodeV2", function(a, r)
        r.name = str(U.try(function() return a.DisplayNameText end))
        r.tag = str(U.try(function() return a.CompatibleToolCategory.TagName end))
        r.level = num(function() return a.PowerLevel end)
        r.depleted = bool(function() return a:IsDepleted() end)
        r.blocked = bool(function() return a:IsBlocked() end)
        r.in_use = bool(function() return a:IsInUse() end)
        r.depleted_prop = bool(function() return a.NodeState.bDepleted end)
    end, 10)
    local comp = pawn and U.try(function() return pawn.FishingComponent end)
    if U.valid(comp) then
        local st = {
            class = U.class_word(comp),
            full_s = num(function() return comp.Settings.TimeToFullyChargeRod end),
            launch_deg = num(function() return comp.Settings.RodCastLaunchAngle end),
            activity = num(function() return comp.InternalState.CurrentActivity end),
            cast = num(function() return comp.InternalState.CastResult end),
            result = num(function() return comp.InternalState.FishingResult end),
            session = num(function() return comp.InternalState.SessionId end),
            changed_t = num(function() return comp.InternalState.TimeOfLastActivityChange end),
            swim = num(function() return comp.FightingFishInternalState.FishSwimmingState end),
        }
        local curve = U.try(function() return comp.Settings.RodChargeFractionToProjectileSpeed end)
        st.curve = U.short(curve)
        if U.valid(curve) then
            st.speed = { num(function() return curve:GetFloatValue(0.0) end), num(function() return curve:GetFloatValue(0.5) end),
                         num(function() return curve:GetFloatValue(1.0) end) }
        end
        local ia = U.try(function() return comp.Settings.RodFishingInputActions end)
        st.inputs = {}
        for _, k in ipairs({ "PullRodLeftInputAction", "PullRodRightInputAction", "ReelInputAction", "CancelInputAction" }) do
            st.inputs[k] = U.short(ia and U.try(function() return ia[k] end))
        end
        out.fishing_component = st
    else
        out.fishing_component = "missing"
    end
    out.primary_action = pawn and U.short(U.try(function() return pawn.PlayerInputBufferInputActions.PrimaryAction end))
    out.input_mode = pc and U.short(U.try(function() return pc.CurrentInputMode end))
    -- carried items' category tags (to confirm tag == node tag)
    local inv = B.API.module("inventory")
    local l = inv and inv.list and inv.list()
    out.carried = {}
    for _, where in ipairs({ "hotbar", "bag", "loadout" }) do
        for _, e in ipairs((l and l[where]) or {}) do
            out.carried[#out.carried + 1] = { item = e.item, name = e.name, category = e.category, where = where }
        end
    end
    out.agility_starters = list("AgilityCourseStarter", function(a, r)
        r.interaction = U.short(U.try(function() return a.InteractionComponent end))
    end, 5)
    out.agility_managers = list("AgilityCourseManager", function(a, r)
        r.next_orb = U.short(U.try(function() return a.NextOrbInSequence end))
    end, 5)
    out.agility_orbs = list("AgilityOrb", nil, 3)
    out.running_course = pawn and bool(function() return pawn:IsRunningAgilityCourse() end)
    out.anima_vents = list("AnimaVent", function(a, r)
        r.charges = bool(function() return a:HasAvailableCharges() end)
        r.concentrated = bool(function() return a:IsConcentrated() end)
    end, 5)
    out.rune_essence_geysers = list("RuneEssenceGeyser", nil, 3)
    out.kebbit_burrows = list("KebbitBurrow", nil, 3)
    out.farm_slots = list("FarmSlotComponent", nil, 3)
    out.agility_walk = (function()
        local cdo = U.find_object and U.find_object("/Script/Dominion.Default__AgilitySettings")
        if not U.valid(cdo) then return "no cdo" end
        return { trigger_cm = num(function() return cdo.WalkingXPEventTriggerDistance end), event = str(U.try(function() return cdo.WalkingXPEventName end)) }
    end)()
    return out
end

-- DATA (not logic): the traversal moves move.lua / localplan.lua can plan with beyond a plain jump, and
-- what gates each one. Availability is read LIVE (the perk via SkillPerkComponent:IsPerkUnlocked, the
-- spell via spells.ability_status: unlocked, on the wheel, runes, cooldown); heights come ONLY from the
-- measured envelope data/envelopes/Claude.json (client_mod/commands/move_calib.lua). A move without a
-- measured height is never planned; it only appears in an honest "could, but" reason.
-- Sources: DISCOVERIES "Traversal (R2)" (Perks, "Windstep is a super-jump", leader double jumps 2.6-3.3 m),
-- data/spells_26161880.json (USD_Windstep: Instant, 5 Air, 3 s cooldown, allow_while_falling=false,
-- GE_Windstep removed on landing), data/spell_mechanics.json (wiki: ~7 s to use it after casting).
return {
    double_jump = {
        label = "a double jump",            -- words: "<label> could get me up there"
        name = "double jump",               -- words: "I'd need double jump (Agility 10)"
        key = "DoubleJump",                 -- reason token: needs:DoubleJump:<lack>[:info]
        perk_field = "DoubleJumpSkillPerk", -- pawn property holding the USkillPerkData (PerkV2_Agility_DoubleJump)
        unlock = "Agility 10",              -- fallback only; the perk's PerkUnlockInfo is read live when it can be
        envelope_key = "dj_up_m",
        expect_up_m = 3.3,                  -- "could" claims only up to this (Luis's measured double jumps 2.7-3.3 m)
        cost = 4,                           -- local planner edge cost (cells)
    },
    windstep = {
        label = "Windstep",
        name = "Windstep",
        key = "Windstep",
        spell_asset = "USD_Windstep",       -- UtilitySpellData asset id (spells.lua rows use it as the id)
        unlock = "Agility 5",               -- fallback only; spells.ability_status' detail names the live level
        envelope_key = "windstep_up_m",
        expect_up_m = nil,                  -- unknown until measured: "could" claims only within claim_max_m
        claim_max_m = 7,                    -- the local planner samples floors up to 7 m above (localplan hi_off)
        cast_window_s = 6,                  -- jump within this after the cast (wiki ~7 s; GE removed on landing)
        max_casts_per_edge = 2,             -- a missed super-jump is retried once, then the edge is dropped
        cost = 8,
    },
}

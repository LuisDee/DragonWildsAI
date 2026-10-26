-- DATA (not logic): what an AI ACTION (UDominionAIAction, started by UDominionAIActionsComponent:
-- Multicast_StartAIAction) means for a fight, matched by tokens of its class name, never by creature.
-- Source: class dump 26161880 (DAA_DragonVelgar_*, DAA_DragonLesser_*, DAA_Shared_*), docs/design/velgar.md §1.
-- Timings are PRIORS (unverified: Blueprint defaults are readable only live, velgar.md S3); combat learns them.
--   kind      breath_cone | ground_spikes | meteor | reposition | cinematic | idle
--   threat    true: answer it like a telegraphed attack (defence plan); false: information only
--   airborne  the creature is off the ground while it runs (boss flight: hold, don't chase)
--   impact_s  prior seconds from the action start to the first damage (learned per class once seen)
--   unblockable / aoe  hints for the defence plan (an Anti-Dragon Shield blocks a breath: `blocked_by_shield_tag`)
--   reach_m   how far it reaches from the creature (prior); jumpable = false: not answered with a jump
--   hazards   hazard_profiles names it leaves on the ground: combat takes the hazard census only after such an action
return {
    -- (BUGS L39: "Breathe" is a creature's idle breathing animation, DAA_Kebbit_Breathe_01_C / DAA_Deer_Breathe_01_C;
    -- it must win over "Breath" or every idle Kebbit reads as a breath attack)
    order = { "PoisonBreath", "Breathe", "Breath", "EarthSpikes", "Spikes", "MeteorStrike", "Meteor", "Reposition", "Intro", "Death", "Idle" },
    PoisonBreath = { kind = "breath_cone", threat = true, impact_s = 1.2, aoe = true, unblockable = true, reach_m = 18, jumpable = false,
                     blocked_by_shield_tag = "AntiDragon", status = "Poison",
                     hazards = { "ground_projectile", "poison_cloud" } },
    Breath       = { kind = "breath_cone", threat = true, impact_s = 1.2, aoe = true, unblockable = true, reach_m = 18, jumpable = false,
                     blocked_by_shield_tag = "AntiDragon", hazards = { "ground_projectile" } },
    EarthSpikes  = { kind = "ground_spikes", threat = true, impact_s = 1.0, aoe = true, unblockable = true, reach_m = 25, jumpable = false,
                     hazards = { "ground_projectile" } },
    Spikes       = { kind = "ground_spikes", threat = true, impact_s = 1.0, aoe = true, unblockable = true, reach_m = 25, jumpable = false,
                     hazards = { "ground_projectile" } },
    MeteorStrike = { kind = "meteor", threat = false, airborne = true, status = "Poison", hazards = { "meteor", "poison_cloud" } },
    Meteor       = { kind = "meteor", threat = false, airborne = true, hazards = { "meteor" } },
    Reposition   = { kind = "reposition", threat = false, airborne = true, hazards = { "delayed_damage" } }, -- the landing
    Intro        = { kind = "cinematic", threat = false },
    Death        = { kind = "cinematic", threat = false },
    Idle         = { kind = "idle", threat = false },
    Breathe      = { kind = "idle", threat = false },
    sides = { Front = "front", Left = "left", Right = "right" },
}

-- DATA (not logic): defensive abilities defense.lua may answer an attack with, besides the plain
-- inputs (parry / block / dodge / jump / retreat). Each entry says how the ability is used and what
-- game data gates it; availability (unlocked, runes, cooldown) is read live from the spells module.
-- Sources: data/spells_26161880.json (game data: cast type, modules, cooldown, runes, owning perk),
-- DISCOVERIES "Traversal (R2)" / "Spells", docs/design/defense-abilities.md. No creature appears here.
return {
    phase_dash = {
        spell_asset = "USD_PhaseDash",   -- Instant; its Blueprint module enables phase dashes, ExpireAfterDuration 2 s
        then_input = "evade",            -- the dash itself is the evade input while the spell is active
        window_s = 2.0,                  -- from the spell's ExpireAfterDuration module
        avoids = { "melee", "lunge", "aoe", "unblockable" },
        note = "dash through the attack",
    },
    windstep = {
        spell_asset = "USD_Windstep",    -- Instant super-jump (GE_Windstep); the stomp needs the upgrade perk
        stomp_perk = "PerkV2_Agility_Spell_Windstep_Upgrade",
        stomp_radius_cm = 700,           -- BP_WindstepExplosion_C template: sphere 700 cm, force 1000
        avoids = { "low", "aoe", "melee" },
        note = "jump out of reach; landing stomp staggers nearby mobs (with the upgrade)",
    },
    tempest_shield = {
        spell_asset = "USD_TempestShield", -- Instant self GE (GE_TempestShield: shield health 50 + 7.5 x Attack level)
        then_input = "block",            -- guides: the shield prevents damage while blocking
        avoids = { "melee", "lunge", "aoe", "unparryable" },
        lasts_s = 60,
        note = "absorb a big hit; keep blocking",
    },
}

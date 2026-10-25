-- DATA (not logic): provisional damage-type weaknesses/resistances by creature name substring, for
-- combat.lua's weapon choice before anything is learned. Live DamageTypeAffinities (empty on the client
-- for Kebbits) and learned hit outcomes (TypeDamagesOutcome) override these.
-- Source: docs/research/2026-10-25-spells-and-weaknesses.md section 2 (wiki / gamever / metaforge,
-- MEDIUM confidence; the in-game journal is the authority once read). Extend freely; keys are lowercase.
return {
    goblin = { weak = { ["DamageType.Magical.Fire"] = true } },
    kalphite = { resist = { ["DamageType.Physical.Crush"] = true, ["DamageType.Physical.Slash"] = true,
                            ["DamageType.Physical.Stab"] = true, ["DamageType.Ranged"] = true,
                            ["DamageType.Magical.Air"] = true, ["DamageType.Magical.Water"] = true } },
}

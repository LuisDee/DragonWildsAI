-- DATA (not logic): long boss fight priors for combat.boss_prepared (docs/design/velgar.md gap 5), per creature
-- (lower-case name) with a `default`. Every number is a PRIOR, named in the estimate's result; live fights refine them.
--   windows      melee windows (the arena's PhaseData count replaces it when seen); flights = windows - 1
--   flight_s     seconds per flight (no damage dealt by him)
--   meteor_dps   damage per second he takes in a flight (meteors assumed mostly dodged)
--   poison_dps   poison damage per second while poisoned; poison_uptime: share of the melee windows poisoned
--   breath_share share of the boss's melee-window damage that is breath (what a breath-blocking shield reduces)
return {
    default = { windows = 4, flight_s = 20, meteor_dps = 2, poison_dps = 4, poison_uptime = 0.5, breath_share = 0.3,
                source = "generic dragon-boss prior" },
    velgar = { windows = 4, flight_s = 20, meteor_dps = 2, poison_dps = 4, poison_uptime = 0.5, breath_share = 0.3,
               source = "wiki Velgar/Strategies (2026-10-13): flight at each ~25%, poison ~4 HP/s until cured" },
}

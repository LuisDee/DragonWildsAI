-- DATA (not logic): item traits the game's held-item data does not carry in this build, per lower-case display
-- name, each with its source. combat.loadout_capability reads it (never a name match in code).
--   blocks_breath  share of a dragon's breath damage a shield blocks
return {
    ["anti-dragon shield"] = { blocks_breath = 0.7,
        source = "wiki Anti-Dragon Shield: partial protection from dragonbreath, blocks dragon fire without stagger (0.7 = prior)" },
    ["dragonfire shield"] = { blocks_breath = 0.8, source = "wiki: crafted from the anti-dragon shield (prior)" },
}

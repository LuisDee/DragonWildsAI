-- Fake of client_mod/scripts/sense.lua (same API and result shapes: flat {ok, ...}, metres).
local M = {}
_G.FAKE = _G.FAKE or {}
function M.me(log)
    local F = _G.FAKE
    if F.no_pawn then return { ok = true, name = "Claude" } end -- controller but no pawn (menu, loading)
    local p = (F.move and F.move.position) or F.me_pos or { 1, 2, 3 }
    return { ok = true, name = "Claude", pawn = "BP_PlayerCharacter_C_1", position = p, health = 90, max_health = 100,
             stamina = 50, skills = { { skill = "Woodcutting", level = 3 } }, total_level = 12 }
end
function M.census(log, opts)
    return { ok = true, origin = { 1, 2, 3 }, radius_m = opts and opts.radius_m, ms = 3,
             players = { { id = "BP_PlayerCharacter_C_2", name = "Luis", position = { 3, 4, 3 }, distance = 2.8, health = 100 } },
             creatures = { { id = "wolf_2", name = "Wolf", position = { 11, 2, 3 }, distance = 10, health = 0, dead = true,
                             attitude = "hostile" },
                           { id = "deer_1", name = "Deer", position = { 20, 2, 3 }, distance = 19, health = 30,
                             attitude = "passive" } },
             items = { { id = "wi_1", name = "Oak Logs", item = "ITEM_Resources_Wood_Oak", count = 2, position = { 1, 2, 3 },
                         distance = 0 } },
             resources = { { id = "oak_1", name = "Oak Tree", kind = "destructible", verb = "chop", position = { 5, 5, 3 },
                             distance = 5 } },
             interactables = { { id = "bench_1", name = "Workbench", kind = "crafting_station", position = { 6, 2, 3 },
                                 distance = 5 } },
             players_online = { "Claude", "Luis" } }
end
return M

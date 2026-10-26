-- The body's own fight odds for an eval case (evals/prep_eval.py): combat.fight_odds + known_affinities' shape
-- + combat.prepared_odds, outside the game (no engine object is touched: the inputs are plain tables).
-- usage: lua evals/prep_odds.lua <case.json>   -> prints {id = {verdict, kill_s, die_s, pl_gap, known, prepared}}
-- case.json = {me = {hp, max_hp, pl}, held = "ITEM_...", entities = [...], list = {hotbar, bag, loadout}, cast = {...},
--              known = {entity_id = {tag = {v, src}}}, attack = n}
function StaticFindObject() return nil end
function FindAllOf() return {} end
function FindFirstOf() return nil end
function RegisterHook() return 1, 2 end
function LoopInGameThreadWithDelay() return 1 end
local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local Cm = assert(loadfile(root .. "/client_mod/scripts/combat.lua"))()
Cm.cfg.memory_enabled = false
local J = assert(loadfile(root .. "/client_mod/scripts/dkjson.lua"))()
local f = assert(io.open(arg[1], "rb")); local c = J.decode(f:read("a")); f:close()
local items = Cm.weapons().items
local w = c.held and items[c.held]
local dps = (w and w.role == "weapon" and Cm.dps(w)) or 12
local odds = Cm.fight_odds(c.me, dps, c.entities)
for _, e in ipairs(c.entities) do
    local o = odds[e.id]
    if o then
        o.known = (c.known or {})[e.id]
        if o.verdict ~= "likely_win" then
            local cast = c.cast or {}
            cast.enchant = cast.enchant or {}
            o.prepared = Cm.prepared_odds(c.me, e, c.list, cast, o.known, c.attack or 1)
        end
    end
end
io.write(J.encode(odds))

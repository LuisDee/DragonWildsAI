-- Fake of client_mod/scripts/sense.lua (same API and result shapes: flat {ok, ...}, metres), over a
-- small mutable world in _G.FAKE.world (the fake inventory's press_interact removes what it takes).
-- Also the parts of sense the bridge uses directly: U (find_all/short/loc/...), local_pc, local_pawn.
local M = {}
_G.FAKE = _G.FAKE or {}
local F = _G.FAKE

local function default_world()
    return {
        players = { { id = "BP_PlayerCharacter_C_2", class = "BP_PlayerCharacter_C", name = "Luis", position = { 3, 4, 3 }, health = 100 } },
        creatures = { { id = "wolf_2", class = "BP_AI_Wolf_C", name = "Wolf", position = { 11, 2, 3 }, health = 0, dead = true,
                        attitude = "hostile" },
                      { id = "deer_1", class = "BP_AI_Deer_C", name = "Deer", position = { 20, 2, 3 }, health = 30, max_health = 60,
                        attitude = "passive" } },
        items = { { id = "wi_1", class = "BP_WorldItem_C", name = "Oak Logs", item = "ITEM_Resources_Wood_Oak", count = 2,
                    position = { 1, 2, 3 } } },
        resources = { { id = "oak_1", class = "BP_Tree_Oak_C", name = "Oak Tree", kind = "destructible", verb = "chop",
                        health = 220, max_health = 220, tool = "Hatchet", tool_tier = 1, drops = "Oak Logs",
                        position = { 5, 5, 3 } },
                      { id = "stick_1", class = "BP_Spawner_Stick_C", name = "Stick", kind = "gatherable", verb = "gather",
                        item = "ITEM_Stick", position = { 2, 3, 3 } } },
        interactables = { { id = "bench_1", class = "BP_Workbench_C", name = "Workbench", kind = "crafting_station",
                            prompt = "Craft", position = { 6, 2, 3 } },
                          { id = "grave_1", class = "BP_Gravestone_C", name = "Gravestone", kind = "interactable",
                            prompt = "Take All", position = { 1, 30, 3 },
                            contents = { { item = "ITEM_Pickaxe_Mithril", name = "Mithril Pickaxe", count = 1 } },
                            GetInventory = function(self)
                                local slots = self.contents
                                return { ItemSlots = setmetatable({ GetArrayNum = function() return #slots end },
                                                                  { __index = function(_, i) return slots[i] end }) }
                            end } },
    }
end
F.world = F.world or default_world()
M.default_world = default_world

local function here() return (F.move and F.move.position) or F.me_pos or { 1, 2, 3 } end
local function d(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2) end

-- util stand-in: actors are the world rows themselves (and a pawn row for Claude)
local U = {}
function U.try(f, ...) local ok, v = pcall(f, ...); if ok then return v end return nil end
function U.valid(o) return o ~= nil end
function U.str(v) return v ~= nil and tostring(v) or nil end
function U.short(a) return a and a.id end
function U.loc(a) local p = a.position; return { X = p[1] * 100, Y = p[2] * 100, Z = p[3] * 100 } end
function U.find_all(class)
    local out = {}
    for _, rows in pairs(F.world) do for _, r in ipairs(rows) do if r.class == class then out[#out + 1] = r end end end
    return out
end
M.U = U

local PAWN = { id = "BP_PlayerCharacter_C_1", class = "BP_PlayerCharacter_C" }
function PAWN:GetFullName()
    return F.frontend and "BP_PlayerCharacter_C /Game/Maps/L_FrontEnd.L_FrontEnd:PersistentLevel.BP_PlayerCharacter_C_1"
        or "BP_PlayerCharacter_C /Game/Maps/World/L_World.L_World:PersistentLevel.BP_PlayerCharacter_C_1"
end
local PC = {}
function PC:SetControlRotation(r) F.aims = (F.aims or 0) + 1; F.last_aim = r end
function M.local_pc() return PC end
function M.local_pawn()
    if F.no_pawn then return nil end
    PAWN.position = here()
    return PAWN
end

function M.me(log)
    if F.no_pawn then return { ok = true, name = "Claude" } end -- controller but no pawn (menu, loading)
    return { ok = true, name = "Claude", pawn = PAWN.id, position = here(), health = 90, max_health = 100,
             stamina = 50, skills = { { skill = "Woodcutting", level = 3 } }, total_level = 12,
             survival = F.survival or { sustenance = { 80, 100 }, hydration = { 70, 100 }, endurance = { 40, 100 } } }
end

M.VITALS_HOOKS = { {}, {}, {}, {} }
function M.vitals_start(log)
    F.vitals_starts = (F.vitals_starts or 0) + 1
    F.vitals = { running = true, hooks = F.hooks_fail and 1 or 4 }
    return { ok = true }
end
function M.vitals_status() return F.vitals or { running = false, hooks = 0 } end

function M.census(log, opts)
    local r = (opts and opts.radius_m) or 30
    local origin = here()
    local out = { ok = true, origin = origin, radius_m = r, ms = 3, players_online = { "Claude", "Luis" } }
    for cat, rows in pairs(F.world) do
        local list = {}
        for _, row in ipairs(rows) do
            local dist = d(origin, row.position)
            if dist <= r then
                local c = {}
                for k, v in pairs(row) do if k ~= "contents" and type(v) ~= "function" then c[k] = v end end
                c.distance = math.floor(dist * 10 + 0.5) / 10
                list[#list + 1] = c
            end
        end
        table.sort(list, function(a, b) return a.distance < b.distance end)
        out[cat] = list
    end
    return out
end
return M

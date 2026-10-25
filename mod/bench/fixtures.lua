-- Benchmark FIXTURES on the DEV server (docs/design/eval-benchmark.md §7.2; Luis approved option B, broadened,
-- 2026-10-25: grant items/runes, unlock perks, set time, spawn creatures, reset, server mods - DEV SERVER ONLY).
-- OWNED BY THE EVAL AGENT; a judge file; FROZEN: tests/test_bench_lua.py lists the verbs (finding 13f), so deleting
-- legacy mod/ code can't silently remove or widen them.
--
-- The companion never calls this: it is the test rig, run by the harness BEFORE a case starts, logged as `setup` in
-- the trace. Claude's own play still uses only real client paths (PRINCIPLES #1).
--
-- Guards (finding 13): DW_SERVER_ROLE=dev on this server process (the harness additionally checks the client's
-- joined address != Shockbyte's before every call); the target is addressed by character GUID, never by name; refuse
-- when any OTHER player is connected.
--
-- Status v0: only `spawn` uses a verified primitive (World:SpawnActor, DISCOVERIES "Route 1"); every other verb
-- answers {ok=false, error="unverified"} until its route is probed read-only and verified on dev, one at a time,
-- with main's go-ahead. Unverified verbs make the case `skip: precondition`, never a fake pass.
local M = { VERSION = 0 }
M.VERBS = { "grant", "grant_runes", "unlock", "set_time", "spawn", "reset_skills", "teleport", "clear_area" }
M.VERIFIED = { spawn = true }

local root = (rawget(_G, "__dw_bench_root") or os.getenv("DW_MOD_ROOT") or "."):gsub("\\", "/")
local U = assert(loadfile(root .. "/body/util.lua"))()

local function guard(args)
    if os.getenv("DW_SERVER_ROLE") ~= "dev" then return "not_dev_server" end
    local guid = tostring(args.character_guid or "")
    if guid == "" then return "no_character_guid" end
    local target, others = nil, {}
    for _, p in ipairs(U.find_all("BP_PlayerCharacter_C", { skip_defaults = true })) do
        local ps = U.try(function() return p.PlayerState end)
        local g = ps and U.guid_hex and U.try(function() return U.guid_hex(ps.OwnerGuid.CharacterGuid) end)
        if g == guid then target = p else others[#others + 1] = U.player_name(p) end
    end
    if #others > 0 then return "other_players_connected", others end
    if not target then return "character_not_found" end
    return nil, target
end

local function spawn(target, args)
    local cls = U.find_object(tostring(args.class or ""))
    if not U.valid(cls) then return { ok = false, error = "unknown_class", class = args.class } end
    local here = U.loc(target)
    local off = args.offset_m or { 5, 0, 0 }
    local at = { X = here.X + off[1] * 100, Y = here.Y + off[2] * 100, Z = here.Z + off[3] * 100 }
    local world = U.try(function() return target:GetWorld() end)
    local a = world and U.try(function() return world:SpawnActor(cls, at, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not U.valid(a) then return { ok = false, error = "spawn_failed" } end
    return { ok = true, id = U.short(a), class = U.class_word(a) }
end

function M.run(log, args)
    args = args or {}
    local verb = tostring(args.verb or "")
    local known = false
    for _, v in ipairs(M.VERBS) do if v == verb then known = true end end
    if not known then return { ok = false, error = "unknown_verb", verbs = M.VERBS } end
    local why, target = guard(args)
    if why then return { ok = false, error = why, detail = target } end
    if not M.VERIFIED[verb] then return { ok = false, error = "unverified", verb = verb } end
    if verb == "spawn" then return spawn(target, args) end
    return { ok = false, error = "unverified", verb = verb }
end

return M

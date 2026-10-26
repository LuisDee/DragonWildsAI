-- READ-ONLY live probe for the ambient hazard + cure service (combat.lua; docs/design/velgar.md §3b), run
-- before enabling it (cfg.ambient / DW_COMBAT_AMBIENT=1). Reads only, presses nothing, sends no zones:
--   * his tracked statuses (property reads: TrackedStatusEffectInstances), next to what the HUD shows;
--   * every hazard class in hazard_profiles near him (radius / telegraph / target reads), all kinds at once;
--   * the AI actions the hook recorded (class -> profile), the hazard watch, the arena phase actor;
--   * the cure he would pick for each harmful status, from the wiki data.
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    local pc = C.local_pc(); local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, reason = "no pawn" } end
    local c = C._state()
    local statuses = C.read_statuses(pawn)
    local list = I.list(log)
    local cures = {}
    for name, e in pairs(statuses or {}) do
        if e.harmful then
            local item, info, how = C.best_cure(list, name)
            cures[name] = item and { item = item.name, how = how, from = info and info.url } or { item = false }
        end
    end
    local all = {}
    for _, hp in ipairs(C.hazard_profiles()) do all[hp.name] = true end
    local F = { t = C.now(pawn), log = log }
    local zones, land = C.hazard_census(F, C.read_me(pawn, pc), all)
    local actions = {}
    for id, r in pairs(c.ai_actions or {}) do
        actions[#actions + 1] = { creature = r.name or id, cls = r.cls, kind = r.profile and r.profile.kind, running = r.running, age_s = r.t and (F.t - r.t) }
    end
    local arena = C.U.find_first(C.BOSS_ARENA_CLASS)
    return { ok = true, statuses = statuses, cures = cures, zones = zones, zone_info = land, ai_actions = actions,
             hazard_watch = c.hazard_watch, arena = arena and C.U.short(arena) or nil, ambient_enabled = C.ambient_enabled() }
end

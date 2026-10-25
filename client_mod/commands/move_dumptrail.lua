-- Read-only: save the current follow's leader breadcrumbs (and Claude's own trail) to
-- client_io/nav/trail_<unix>.json (metres; air=true for airborne samples). For seeding navmem traps.
return function(log)
    local st = rawget(_G, "DW_MOVE")
    if not st then return { error = "no move state" } end
    local function list(c)
        local out = {}
        for _, p in ipairs(c or {}) do
            out[#out + 1] = string.format('[%.2f,%.2f,%.2f%s]', p.X / 100, p.Y / 100, p.Z / 100, p.air and ',"air"' or (p.gap and ',"gap"' or ""))
        end
        return "[" .. table.concat(out, ",") .. "]"
    end
    local path = "C:/gameserver/client_io/nav/trail_" .. os.time() .. ".json"
    local f = io.open(path, "w")
    if not f then return { error = "cannot write" } end
    f:write('{"target":"' .. tostring(st.target_name) .. '","leader":' .. list(st.crumbs) .. ',"self":' .. list(st.self_crumbs) .. '}')
    f:close()
    return { path = path, leader = #(st.crumbs or {}), self = #(st.self_crumbs or {}), mode = st.mode, status = st.status }
end

-- Scenario suite (tools/scenario_run.py, "fetch_consume"): eat or drink ONE item Claude carries, by the same
-- path the stay-fed reflex uses: inventory.use with the consumable-class check on the exact slot, HOTBAR ONLY
-- (a bag use preceded the 18:27 hang; DISCOVERIES "Client combat"). Fallback used only while the bridge has no
-- `consume` tool (streamline plan step 2).
-- Runner args (`local ARGS = {...}` prefixed): item = item id or display name. Returns {ok, kind, name, use} or
-- {ok=false, error = not_in_inventory | not_consumable | bag_only | paused | <use reason>}. The runner verifies the
-- stat rose from get_state afterwards.
return function(log)
    local A = (type(ARGS) == "table" and ARGS) or {}
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, error = "paused" } end
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local I = assert(loadfile(root .. "/client_mod/scripts/inventory.lua"))()
    local l = I.list(log)
    if not l.ok then return { ok = false, error = l.reason or "inventory_list_failed" } end
    local want = tostring(A.item or "")
    local row, where
    for _, w in ipairs({ "hotbar", "bag" }) do
        for _, d in ipairs(l[w] or {}) do
            if not row and (d.item == want or d.name == want) then row, where = d, w end
        end
    end
    if not row then return { ok = false, error = "not_in_inventory", item = want } end
    if not row.consumable then return { ok = false, error = "not_consumable", item = row.item, name = row.name } end
    if where ~= "hotbar" then return { ok = false, error = "bag_only", item = row.item, name = row.name } end
    local r = I.use(log, row.item, { require = row.consumable, hotbar_only = true })
    return { ok = r.ok ~= false, error = r.reason, kind = row.consumable, name = row.name, item = row.item, via = r.via }
end

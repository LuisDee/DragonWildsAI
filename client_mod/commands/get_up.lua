-- get_up: if he is lying in a bed or shelter, get up the way a player does. The game ends a rest on a plain
-- interact press, not Back (skills.lua interact's own get-up path; combat.lua's DIM_Resting exit; live 2026-11-01
-- 19:56Z). ARGS.press = false: only report. Read: PlayerRestComponent.CurrentRestingAreaActor (skills.W.resting_in).
-- -> {ok, resting_in = id | nil, pressed?, press?}. The caller verifies with a second, press = false call.
-- Used by tools/rung1_gate.py after its rest item (main 2026-11-01: a rung1 rest left him in bed for the next agent).
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    local B = inst and inst.module
    if not (B and type(B.module) == "function") then return { ok = false, reason = "no_bridge" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local sk = B.module("skills")
    local W = sk and sk.W
    if not (W and type(W.resting_in) == "function") then return { ok = false, reason = "no skills.W.resting_in" } end
    local okr, bed = pcall(W.resting_in, B.API)
    local out = { ok = true, resting_in = okr and bed or nil }
    if not okr then out.ok, out.reason = false, tostring(bed) end
    if out.resting_in and not (type(ARGS) == "table" and ARGS.press == false) then
        local inv = B.module("inventory")
        if not (inv and type(inv.press_interact) == "function") then return { ok = false, reason = "no inventory.press_interact", resting_in = out.resting_in } end
        local okp, r = pcall(inv.press_interact, log)
        out.pressed = okp and type(r) == "table" and r.ok ~= false
        out.press = okp and r or tostring(r)
    end
    return out
end

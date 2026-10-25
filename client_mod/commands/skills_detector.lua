-- Read-only: what the game's interaction detector targets now, where Claude stands and faces, and the
-- interaction point / forward vector of an actor (ARGS.target = a census id). No input, no movement.
return function(log)
    local ROOT = "C:/gameserver"
    local S = assert(loadfile(ROOT .. "/client_mod/scripts/sense.lua"))()
    local I = assert(loadfile(ROOT .. "/client_mod/scripts/inventory.lua"))()
    local U = S.U
    local pawn, pc = S.local_pawn(), S.local_pc()
    local out = { detector = I.interact_target(pawn), me = pawn and U.to_wire(U.loc(pawn)) }
    local rot = pc and U.try(function() return pc:GetControlRotation() end)
    out.control_yaw = rot and U.try(function() return rot.Yaw end)
    out.control_pitch = rot and U.try(function() return rot.Pitch end)
    local ar = pawn and U.try(function() return pawn:K2_GetActorRotation() end)
    out.pawn_yaw = ar and U.try(function() return ar.Yaw end)
    local det = pawn and U.try(function() return pawn.InteractionDetector end)
    if U.valid(det) then
        out.detector_range = U.try(function() return det.DetectionRange end)
        out.trace_distance = U.try(function() return det.CharacterTraceDistance end)
    end
    local id = rawget(_G, "ARGS") and ARGS.target
    if id then
        for _, a in ipairs(U.find_all("Actor", { skip_defaults = true }) or {}) do
            if U.short(a) == id then
                out.actor = U.to_wire(U.loc(a))
                local f = U.try(function() return a:GetActorForwardVector() end)
                out.forward = f and { U.try(function() return f.X end), U.try(function() return f.Y end) }
                for _, prop in ipairs({ "InteractionComponent", "Interaction", "InteractionCollider", "BedComponent", "Bed" }) do
                    local c = U.try(function() return a[prop] end)
                    if U.valid(c) then
                        local v = U.try(function() return c:K2_GetComponentLocation() end)
                        out[prop] = v and U.to_wire(v) or "valid (no location)"
                    end
                end
                break
            end
        end
    end
    return out
end

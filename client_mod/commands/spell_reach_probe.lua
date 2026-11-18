-- READ-ONLY probe (2026-11-18, Bark to Bones Oak case: the preview stopped 2.9 m short of a tree ~10.5 m away; the
-- cast's reach was 15 m and never read the spell's own camera trace). For Bark to Bones (USD_Treequipment) and every
-- placed or aimed spell he has unlocked or the game has loaded, it reads the spell data's reach and trace properties
-- (UUtilitySpellData, dump 26574459 Dominion.hpp:37001-37013), the same on any spell module that carries them
-- (SpellModule_Movement / SpellModule_Transform: CameraTraceDistance, CameraTraceIgnoreDistance), and the spellcasting
-- component's own limits, then logs one line per spell to the mod log and returns all of it.
-- What the cast skill makes of it: SP.reach (reach_m, src) per spell, with the W.static read (trace_m / trace_read).
-- Class defaults (UHT dump, NOT the asset values): CameraTraceDistance 0, CameraTraceIgnoreDistance 400 cm,
-- MaxPlacementDistanceFromCamera 1500 cm (used only with bOverrideMaxPlacementDistanceFromCamera); component
-- MinDistanceFromCameraToPlaceSpell 500 cm, MaxDistanceFromCameraToPlaceSpell 2000 cm (live read: 1500).
-- Calls: property reads on native-class objects, FindAllOf, StaticFindObject (never loads), the soft-pointer
-- GetObjectID():GetAssetPathName() W.static already uses. No input, no RPC, no struct built, nothing written in game.
-- Run (from C:\gameserver, dev client in game; result in client_io\out\spell_reach_probe.json, lines in client.log):
--   . tools\client_lib.ps1; $r = Invoke-ClientCmd -Path client_mod\commands\spell_reach_probe.lua -TimeoutS 20; if ($r) { $r.component; $r.spells | Format-Table asset, cast_type, trace_cm, trace_ignore_cm, override, max_place_cm, reach_m, reach_src } else { Clear-ClientCmd spell_reach_probe; 'no answer' }
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local BARK = "/Game/Gameplay/UtilityMagic/PerkSpells/Treequipment/USD_Treequipment.USD_Treequipment"
local WANT = { [1] = "placed", [2] = "aimed" } -- EUtilitySpellCastType (Dominion_enums.hpp)
return function(log)
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local SP = assert(loadfile(ROOT .. "/client_mod/scripts/spells.lua"))()
    local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()
    local function say(msg) pcall(log, "[spell_reach_probe] " .. msg) end
    local function num(o, k) local v = U.try(function() return o[k] end); return type(v) == "number" and v or nil end
    local function flag(o, k) local v = U.try(function() return o[k] end); if type(v) == "boolean" then return v end; return nil end
    local out = { ok = true, probe = "spell_reach_probe", version = 1, spells = {}, unread = {} }
    local api = SP.default_api()
    local okS, snap = pcall(SP.W.snapshot, api)
    if not okS or type(snap) ~= "table" then snap = nil; out.unread[#out.unread + 1] = "snapshot" end
    -- the spellcasting component's limits (cm)
    local pc = SP.W.pc(api)
    local sc = U.valid(pc) and U.try(function() return pc.SpellcastingComponent end) or nil
    if U.valid(sc) then
        out.component = {}
        for _, k in ipairs({ "MinDistanceFromCameraToPlaceSpell", "MaxDistanceFromCameraToPlaceSpell",
                             "TraceDistanceToClampSpellToSurface", "AdjustSpellDistanceIncrement" }) do
            out.component[k] = num(sc, k)
            if out.component[k] == nil then out.unread[#out.unread + 1] = "component." .. k end
        end
        say(string.format("component min %s max %s clamp %s step %s (cm)", tostring(out.component.MinDistanceFromCameraToPlaceSpell),
            tostring(out.component.MaxDistanceFromCameraToPlaceSpell), tostring(out.component.TraceDistanceToClampSpellToSurface),
            tostring(out.component.AdjustSpellDistanceIncrement)))
    else
        out.unread[#out.unread + 1] = "component"
    end
    -- the spells: Bark to Bones by path, then unlocked, then loaded
    local seen, list = {}, {}
    local function add(o) if U.valid(o) then local id = U.short(o); if id and not seen[id] then seen[id] = true; list[#list + 1] = o end end end
    add(U.try(StaticFindObject, BARK))
    for _, o in pairs((snap and snap.objects) or {}) do add(o) end
    for _, o in ipairs(SP.W.all_spells()) do add(o) end
    out.bark_found = seen.USD_Treequipment == true
    if not out.bark_found then say("USD_Treequipment not loaded (not unlocked and not found by path)") end
    for _, o in ipairs(list) do
        local id = U.short(o)
        local ct = num(o, "CastType")
        if WANT[ct] or id == "USD_Treequipment" then
            local r = { asset = id, cast_type = WANT[ct] or ct, unlocked = snap and snap.unlocked and snap.unlocked[id] == true or false,
                        trace_cm = num(o, "CameraTraceDistance"), trace_ignore_cm = num(o, "CameraTraceIgnoreDistance"),
                        override = flag(o, "bOverrideMaxPlacementDistanceFromCamera"), max_place_cm = num(o, "MaxPlacementDistanceFromCamera"),
                        above_ground_cm = num(o, "DistanceAboveGroundToPlaceSpell"), on_surface = flag(o, "bAlwaysTryToPlaceOnSurface"),
                        center_on_caster = flag(o, "bCenterOnCaster"), custom_trace = flag(o, "bUseCustomLineTraceForPlacement"),
                        adjust_type = num(o, "PlacementAdjustmentType"), min_scale = num(o, "MinScale"), max_scale = num(o, "MaxScale"),
                        modules = {} }
            r.override_perk = U.short(U.try(function() return o.RequiredPerkForMaxPlacementDistanceOverride end))
            r.trace_profile = U.str(U.try(function() return o.TraceProfile.Name end))
            r.visualizer = U.str(U.try(function() return o.PlacementActorClass:GetObjectID():GetAssetPathName() end))
                or U.str(U.try(function() return o.PlacementActorClass:GetAssetPathName() end))
            if r.trace_cm == nil then out.unread[#out.unread + 1] = id .. ".CameraTraceDistance" end
            local c = U.try(function() return o.Modules end)
            U.each(c and U.try(function() return c.Modules end), function(w)
                local m = U.try(function() return w.Module end)
                if not U.valid(m) then return end
                local t, ig = num(m, "CameraTraceDistance"), num(m, "CameraTraceIgnoreDistance")
                if t or ig then r.modules[#r.modules + 1] = { kind = U.class_word(m), trace_cm = t, trace_ignore_cm = ig } end
            end, 64)
            -- what the cast skill makes of it (the same read and rule the cast uses)
            local okst, st = pcall(SP.W.static, o)
            if okst and type(st) == "table" then
                r.reach_m, r.reach_src = SP.reach(st, snap)
                r.static_trace_m, r.static_trace_read = st.trace_m, st.trace_read
            end
            out.spells[#out.spells + 1] = r
            local mods = {}
            for _, m in ipairs(r.modules) do mods[#mods + 1] = string.format("%s %s/%s", tostring(m.kind), tostring(m.trace_cm), tostring(m.trace_ignore_cm)) end
            say(string.format("%s (%s%s): CameraTraceDistance %s cm, CameraTraceIgnoreDistance %s cm, override %s max %s cm (perk %s), "
                .. "above ground %s, surface %s, custom trace %s, profile %s, visualizer %s; modules [%s]; cast reach %s m (%s)",
                id, tostring(r.cast_type), r.unlocked and ", unlocked" or "", tostring(r.trace_cm), tostring(r.trace_ignore_cm),
                tostring(r.override), tostring(r.max_place_cm), tostring(r.override_perk), tostring(r.above_ground_cm),
                tostring(r.on_surface), tostring(r.custom_trace), tostring(r.trace_profile), tostring(r.visualizer),
                table.concat(mods, "; "), tostring(r.reach_m), tostring(r.reach_src)))
        end
    end
    table.sort(out.spells, function(a, b) return tostring(a.asset) < tostring(b.asset) end)
    out.count = #out.spells
    if #out.unread > 0 then say("unread: " .. table.concat(out.unread, ", ")) end
    return out
end

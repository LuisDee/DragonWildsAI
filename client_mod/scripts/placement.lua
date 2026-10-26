-- placement: the shared "put something where the game's own placement preview says it can go" loop
-- (build review 2026-10-26, finding 13). Extracted from spells.lua's place_check so build.lua and spells
-- share ONE implementation; the spells agent migrates spells.lua to it in its own commit.
--
-- Pure logic over an injected environment (no UE calls here, so it is testable offline and never touches
-- the game under DW_PAUSE by itself):
--   env.trace(a_cm, b_cm) -> hit, out{ImpactPoint, ImpactNormal}  (the line trace move.lua / spells use)
--   env.me()              -> {X, Y, Z} cm (my pawn)
--   env.players()         -> {{name, position = metres}} (other players)
--   env.aim(pos_m)        -> distance camera->point in metres (sets the control rotation)
--   env.read()            -> nil (no readable preview) | {valid = true|false|nil, why = game reason/tag,
--                            position = metres, fresh = bool (read after the latest aim)}
--
-- P.spots(env, center_m, opts)  candidate spots, best first (3x3 downward traces at footprint spacing:
--                               height spread, centre normal, clearance above, line of sight)
-- P.checker(env, spots, opts)   :step(t) -> nil (working) | {press = true, spot, preview, rejects}
--                               | {give_up = true, rejects, why}
local P = {}

P.cfg = {
    wait_s = 0.35,          -- after aiming: let the preview follow the camera
    checks = 2,             -- re-aim + re-read this many times per spot
    match_m = 2.5,          -- the preview must sit this close to the spot
    budget_s = 25,          -- the whole search
    max_spread_m = 1.5,     -- 3x3 height spread a spot may have (traces only rank / drop hopeless spots)
    min_normal_z = 0.75,
    clear_players_m = 2.5,  -- never a spot this close to another player
    rings_m = { 3, 5 },     -- around me when no centre is given
    ring_n = 12,
    around_m = { 2, 3.5 },  -- around a given centre
    around_n = 8,
}

local function d2(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end
local function d3(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + ((a[3] or 0) - (b[3] or 0)) ^ 2) end
P._d2, P._d3 = d2, d3

-- opts: footprint_m (grid spacing for the 3x3, default 1.5), around_m / around_n, rings_m / ring_n,
-- standoff_m (skip spots closer than this to ME: I'd stand inside the piece), clear_players_m,
-- max_spread_m, min_normal_z, los (default true), cfg (overrides)
function P.spots(env, center, opts)
    opts = opts or {}
    local cfg = setmetatable(opts.cfg or {}, { __index = P.cfg })
    local me = env.me()
    if not me then return {}, {} end
    local players = env.players and env.players() or {}
    local step_cm = math.max(1.5, opts.footprint_m or 1.5) * 100
    local pts, skipped = {}, {}
    if center then
        local cz = (center[3] or me.Z / 100) * 100
        pts[1] = { center[1] * 100, center[2] * 100, cz, exact = true }
        for _, r in ipairs(opts.around_m or cfg.around_m) do
            local n = opts.around_n or cfg.around_n
            for i = 0, n - 1 do
                local a = math.rad(i * 360 / n)
                pts[#pts + 1] = { center[1] * 100 + r * 100 * math.cos(a), center[2] * 100 + r * 100 * math.sin(a), cz }
            end
        end
    else
        for _, r in ipairs(opts.rings_m or cfg.rings_m) do
            local n = opts.ring_n or cfg.ring_n
            for i = 0, n - 1 do
                local a = math.rad(i * 360 / n)
                pts[#pts + 1] = { me.X + r * 100 * math.cos(a), me.Y + r * 100 * math.sin(a), me.Z }
            end
        end
    end
    local out = {}
    for _, p in ipairs(pts) do
        local why
        for _, pl in ipairs(players) do
            local pp = pl.position
            if pp and math.sqrt((pp[1] * 100 - p[1]) ^ 2 + (pp[2] * 100 - p[2]) ^ 2) < (opts.clear_players_m or cfg.clear_players_m) * 100 then
                why = "player_in_spot"
            end
        end
        if not why and opts.standoff_m and math.sqrt((me.X - p[1]) ^ 2 + (me.Y - p[2]) ^ 2) < opts.standoff_m * 100 then
            why = "i_am_in_spot"
        end
        if why then
            skipped[#skipped + 1] = { spot = { p[1] / 100, p[2] / 100, p[3] / 100 }, why = why, exact = p.exact }
        else
            local zs, zc, nz = {}, nil, nil
            for dx = -1, 1 do for dy = -1, 1 do
                local hit, o = env.trace({ X = p[1] + dx * step_cm, Y = p[2] + dy * step_cm, Z = p[3] + 400 },
                                         { X = p[1] + dx * step_cm, Y = p[2] + dy * step_cm, Z = p[3] - 600 })
                local z = hit and o and o.ImpactPoint and o.ImpactPoint.Z or nil
                if z then zs[#zs + 1] = z end
                if dx == 0 and dy == 0 then zc, nz = z, hit and o and o.ImpactNormal and o.ImpactNormal.Z or nil end
            end end
            if zc and #zs == 9 then
                local lo, hi = math.huge, -math.huge
                for _, z in ipairs(zs) do lo = math.min(lo, z); hi = math.max(hi, z) end
                local spread = (hi - lo) / 100
                local up = env.trace({ X = p[1], Y = p[2], Z = zc + 50 }, { X = p[1], Y = p[2], Z = zc + 350 })
                local los = opts.los ~= false and env.trace({ X = me.X, Y = me.Y, Z = me.Z + 50 }, { X = p[1], Y = p[2], Z = zc + 80 }) or false
                if not up and not los and spread <= (opts.max_spread_m or cfg.max_spread_m) and (nz or 0) >= (opts.min_normal_z or cfg.min_normal_z) then
                    out[#out + 1] = { position = { p[1] / 100, p[2] / 100, zc / 100 }, spread_m = math.floor(spread * 100) / 100,
                                      normal_z = nz and math.floor(nz * 1000) / 1000, exact = p.exact }
                elseif p.exact then
                    skipped[#skipped + 1] = { spot = { p[1] / 100, p[2] / 100, zc / 100 }, why = up and "covered" or (los and "no_line_of_sight") or "uneven",
                                              spread_m = math.floor(spread * 100) / 100, exact = true }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.exact == true) ~= (b.exact == true) then return a.exact == true end
        return a.spread_m < b.spread_m
    end)
    return out, skipped
end

-- The commonest game reason among rejects (for "every spot I tried here needs a foundation").
function P.common_reason(rejects)
    local n, best, bn = {}, nil, 0
    for _, r in ipairs(rejects or {}) do
        local w = r.why or "unknown"
        n[w] = (n[w] or 0) + 1
        if n[w] > bn then best, bn = w, n[w] end
    end
    return best, bn
end

-- opts: match_m (number or fn(spot) -> m), checks, wait_s, budget_s, compare = "3d" | "2d",
--   on_unreadable = "skip" (default: no readable preview = no press; build) | "press_once" (spells' old rule),
--   on_reject(rej, checker) (may add/filter checker.spots; spells' ground spots / flatness learning)
function P.checker(env, spots, opts)
    opts = opts or {}
    local c = { spots = spots or {}, i = 0, rejects = {}, unreadable = 0, next = true, checks = 0 }
    local wait_s = opts.wait_s or P.cfg.wait_s
    local checks = opts.checks or P.cfg.checks
    local function match_m(sp) return type(opts.match_m) == "function" and opts.match_m(sp) or opts.match_m or P.cfg.match_m end
    function c:step(t)
        self.deadline = self.deadline or (t + (opts.budget_s or P.cfg.budget_s))
        if t >= self.deadline then return { give_up = true, rejects = self.rejects, why = "budget" } end
        if self.next then
            self.next = false
            self.i = self.i + 1
            local sp = self.spots[self.i]
            if not sp then
                return { give_up = true, rejects = self.rejects,
                         why = (#self.rejects == 0 and self.unreadable > 0) and "preview_unreadable" or (#self.spots == 0 and "no_spots" or "all_rejected") }
            end
            env.aim(sp.position)
            self.t_read, self.checks = t + wait_s, 0
            return nil
        end
        if t < self.t_read then return nil end
        local sp = self.spots[self.i]
        local vis = env.read()
        if not vis or vis.valid == nil then
            if opts.on_unreadable == "press_once" and not self.pressed_blind then
                self.pressed_blind = true
                return { press = true, spot = sp, preview = "unreadable", rejects = self.rejects }
            end
            self.checks = self.checks + 1
            if self.checks < checks then env.aim(sp.position); self.t_read = t + wait_s; return nil end
            self.unreadable = self.unreadable + 1
            self.next = true
            return nil
        end
        local near
        if vis.position and sp.position then near = (opts.compare == "2d" or sp.aim) and d2(vis.position, sp.position) or d3(vis.position, sp.position) end
        local match = sp.here or not near or near <= match_m(sp)
        if vis.valid == true and match and vis.fresh ~= false then
            return { press = true, spot = sp, preview = vis, rejects = self.rejects }
        end
        self.checks = self.checks + 1
        if self.checks < checks then env.aim(sp.position); self.t_read = t + wait_s; return nil end
        local rej = { spot = sp.position, valid = vis.valid, why = (vis.valid == true and not match) and "preview_off_target" or vis.why,
                      preview_at = vis.position, spread_m = sp.spread_m, off_m = near and math.floor(near * 10 + 0.5) / 10 or nil }
        self.rejects[#self.rejects + 1] = rej
        if opts.on_reject then opts.on_reject(rej, self) end
        self.next = true
        return nil
    end
    return c
end

return P

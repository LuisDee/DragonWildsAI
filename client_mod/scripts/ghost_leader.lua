-- ghost_leader.lua: a moving follow target for the movement ladder (tools/travel_ladder.py, follow legs).
-- A recorded human track (the dev server recorder's 5 Hz player positions, mod/experiments/player_recorder.lua) is
-- replayed as a stand-in leader: a plain Lua table with the methods move.lua reads from a target (IsValid,
-- K2_GetActorLocation, GetFullName, CharacterMovement:IsMovingOnGround for the airborne crumbs where the human
-- jumped). It never touches the engine except through the clock and position readers it is given. Each read of its
-- position also logs one sample (its own position and Claude's, on one clock), so the harness scores the follow
-- from frame-accurate data instead of 2 s polls.
--   G.new(track, opts) -> ghost      track = { {t_s, x_cm, y_cm, z_cm, air(0/1)}, ... } (t from 0, increasing)
--     opts.clock()  -> seconds (GameplayStatics:GetRealTimeSeconds)   opts.me() -> Claude's capsule {X,Y,Z} or nil
--     opts.delay_s  the ghost stands at its first point this long before it starts walking (default 2)
--     opts.hold_s   it stands at its last point this long after the track ends (catch-up window, default 8)
--     opts.every_s  sample spacing (default 0.1)
--   ghost:phase() -> "waiting" | "moving" | "holding" | "done"       ghost:samples(from_i) -> rows, n
local G = {}

local function lerp(a, b, u) return a + (b - a) * u end

function G.new(track, opts)
    opts = opts or {}
    assert(type(track) == "table" and #track >= 2, "ghost: a track needs 2+ points")
    local clock, me = assert(opts.clock, "ghost: clock"), opts.me
    local g = { track = track, delay_s = opts.delay_s or 2, hold_s = opts.hold_s or 8, every_s = opts.every_s or 0.1,
                rows = {}, i = 1, t0 = nil, last_sample = -1, dw_ghost = true }
    local dur = track[#track][1]
    g.duration_s = dur
    -- airborne runs that land more than 2 m above their take-off were double jumps: their second half reads
    -- ReplicatedJumpCurrentCount = 2 (move.lua's leader watch reads that field on a real player)
    local dbl, k = {}, 1
    while k <= #track do
        if track[k][5] == 1 then
            local j = k
            while j < #track and track[j + 1][5] == 1 do j = j + 1 end
            local z0 = (track[k - 1] or track[k])[4]
            local land = track[j + 1] or track[j]
            if land[4] - z0 > 200 then for q = math.floor((k + j) / 2), j do dbl[q] = true end end
            k = j + 1
        else k = k + 1 end
    end

    -- track time now (nil before the first read: the first read starts the clock)
    local function track_t()
        local c = clock()
        if not g.t0 then g.t0 = c end
        return c - g.t0 - g.delay_s, c - g.t0
    end
    function g:phase()
        if not self.t0 then return "waiting" end
        local tt = clock() - self.t0 - self.delay_s
        if tt < 0 then return "waiting" elseif tt <= dur then return "moving"
        elseif tt <= dur + self.hold_s then return "holding" else return "done" end
    end
    -- position at track time tt (clamped), and whether that stretch is airborne
    local function at(tt)
        if tt <= 0 then local p = track[1]; return p[2], p[3], p[4], false end
        if tt >= dur then local p = track[#track]; return p[2], p[3], p[4], false end
        local k = g.i
        if track[k][1] > tt then k = 1 end
        while k < #track and track[k + 1][1] < tt do k = k + 1 end
        g.i = k
        local a, b = track[k], track[k + 1]
        local u = (b[1] > a[1]) and (tt - a[1]) / (b[1] - a[1]) or 0
        return lerp(a[2], b[2], u), lerp(a[3], b[3], u), lerp(a[4], b[4], u), (a[5] == 1 or b[5] == 1), dbl[k] or dbl[k + 1]
    end
    g.air, g.ReplicatedJumpCurrentCount = false, 0
    function g:IsValid() return self:phase() ~= "done" end
    function g:GetFullName() return "GhostLeader ladder" end
    function g:K2_GetActorLocation()
        local tt, el = track_t()
        local x, y, z, air, two = at(tt)
        self.air = air
        self.ReplicatedJumpCurrentCount = (air and two) and 2 or (air and 1 or 0)
        if el - self.last_sample >= self.every_s then
            self.last_sample = el
            local mx, my, mz = 0, 0, 0
            if me then
                local ok, p = pcall(me)
                if ok and p then mx, my, mz = p.X, p.Y, p.Z end
            end
            local st = rawget(_G, "DW_MOVE")
            self.rows[#self.rows + 1] = { math.floor(el * 100) / 100, math.floor(x), math.floor(y), math.floor(z),
                math.floor(mx), math.floor(my), math.floor(mz), st and tostring(st.status or "?") or "?",
                st and tostring(st.source or "-") or "-" }
        end
        return { X = x, Y = y, Z = z }
    end
    -- move.lua's leader crumbs read the target's movement component: the ghost is airborne where the human jumped
    g.CharacterMovement = { IsValid = function() return true end, IsMovingOnGround = function() return not g.air end }
    function g:samples(from_i)
        local out, n = {}, #self.rows
        for k = (from_i or 1), n do out[#out + 1] = self.rows[k] end
        return out, n
    end
    return g
end

return G

-- ranged: aiming crossbows, bows and projectile spells like a player (route R2, client side).
-- Design: docs/design/ranged-aim.md. Used by combat.lua (ranged engage) and by spell casting.
--
--   * PARAMETERS from game data, read live (reflection): the equipped ammo's URangedAmmoData.ProjectileData
--     {LaunchSpeed, OverrideGravityZ, TimeWithoutGravity, MaxSimulationTime} via
--     PlayerRangedAttackComponent:GetEquippedRangedAmmoDataForCurrentWeapon(), the attack collection's
--     LaunchSpeedCurve / OverrideGravityZCurve (by charge), accuracy (BaseInaccuracy, TimeBeforeFullAccuracy);
--     for a projectile spell, its ADominionSpellProjectile CDO's ProjectileMovement {InitialSpeed,
--     ProjectileGravityScale}. Then corrected from what real shots did (system identification below).
--   * BALLISTIC SOLUTION with lead: find the flight time tau where the projectile (straight for t0, then
--     falling with gz) meets the target's predicted position T + V*tau:  |T + V*tau - M - G(tau)| = s*tau,
--     G(tau) = (0, 0, gz/2 * max(0, tau - t0)^2). A 1-D bracketed root search on tau: the smallest root is
--     the low (direct) arc, a larger one the high arc; no root within max time = out of range (reported
--     with the max-range estimate). Chosen over the closed-form quartic (Forrest Smith, "Solving Ballistic
--     Trajectories": fragile, no straight segment) and over UGameplayStatics:SuggestProjectileVelocity*
--     (reflected, but no straight segment and no lead with our speed model). See the design doc.
--   * AIM through the real input path: the camera (control rotation) is pointed so its ray passes through
--     muzzle + dir * aim_distance, because the game launches from the weapon's socket toward the point
--     under the crosshair (PlayerRangedAttackComponent AimOffset trace). Nothing is spawned or emulated.
--   * LEARNING: the fired projectile actor (ADominionProjectile, new in the world, sampled every frame) is
--     fitted for its real speed, gravity and straight time, and the closest approach to the target gives
--     the miss (vertical / lateral). Per-launcher profiles are blended toward the measurements; a small
--     residual pitch/yaw bias is kept for what the model can't explain (muzzle offset, camera trace).
--   * METRICS: shots and hits by distance bucket and target speed bucket.
-- Pure functions take plain tables {X,Y,Z} in centimetres and seconds; offline-tested.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local okU, U = pcall(function() return assert(loadfile(ROOT .. "/mod/body/util.lua"))() end)
if not okU then U = nil end

local R = { U = U }

R.cfg = {
    default_speed = 4000,     -- cm/s, when nothing is readable (bolts/arrows are a few thousand cm/s)
    default_gz = -980,        -- cm/s^2 (UE default world gravity)
    max_time = 4.0,           -- longest flight considered, s
    scan_steps = 80,          -- bracket scan resolution over (0, max_time]
    aim_distance = 5000,      -- cm: the camera ray is aimed through muzzle + dir * this
    blend = 0.35,             -- learning rate toward measured parameters
    bias_blend = 0.3,
    max_bias_deg = 3.0,
    dist_buckets = { 10, 20, 35, 60 },   -- m
    speed_buckets = { 0.5, 3, 7 },       -- m/s (still, slow, fast, very fast)
}

local function v(x, y, z) return { X = x or 0, Y = y or 0, Z = z or 0 } end
local function add(a, b) return v(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
local function sub(a, b) return v(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
local function mul(a, k) return v(a.X * k, a.Y * k, a.Z * k) end
local function len(a) return math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z) end
local function norm(a) local l = len(a); if l < 1e-9 then return v(1, 0, 0) end return mul(a, 1 / l) end
R.vec = { v = v, add = add, sub = sub, mul = mul, len = len, norm = norm }

local function S()
    _G.DWRanged = _G.DWRanged or { profiles = {}, metrics = {}, shots = {} }
    return _G.DWRanged
end
R._state = S

-- ------------------------------------------------------------------ ballistics (pure)
-- Gravity drop at time t: straight for t0, then falling.
local function drop(p, t)
    local tg = math.max(0, t - (p.t0 or 0))
    return 0.5 * (p.gz or R.cfg.default_gz) * tg * tg
end
R.drop = drop

-- Projectile position at time t for launch direction dir from muzzle m.
function R.position(m, dir, p, t)
    local s = p.speed or R.cfg.default_speed
    local d = norm(dir)
    return v(m.X + d.X * s * t, m.Y + d.Y * s * t, m.Z + d.Z * s * t + drop(p, t))
end

-- Solve the launch direction. m = muzzle, tpos = target point now, tvel = target velocity (cm/s),
-- p = {speed, gz, t0}. opts.arc = "low" (default) | "high". -> sol {dir, tau, aim_point, pitch, yaw, arc}
-- or nil, why ("out_of_range"), info {max_range_cm}
function R.solve(m, tpos, tvel, p, opts)
    opts = opts or {}
    local cfg = R.cfg
    tvel = tvel or v()
    local s = p.speed or cfg.default_speed
    local function D(tau)
        local t = add(tpos, mul(tvel, tau))
        return v(t.X - m.X, t.Y - m.Y, t.Z - m.Z - drop(p, tau))
    end
    local function f(tau) return len(D(tau)) - s * tau end
    local roots = {}
    local n = cfg.scan_steps
    local tmax = opts.max_time or cfg.max_time
    local prev_t, prev_f = 1e-4, f(1e-4)
    for i = 1, n do
        local t = tmax * i / n
        local ft = f(t)
        if (prev_f > 0) ~= (ft > 0) then
            local a, b, fa = prev_t, t, prev_f
            for _ = 1, 50 do
                local mid = (a + b) / 2
                local fm = f(mid)
                if (fa > 0) == (fm > 0) then a, fa = mid, fm else b = mid end
            end
            roots[#roots + 1] = (a + b) / 2
        end
        prev_t, prev_f = t, ft
    end
    if #roots == 0 then
        -- max range on flat ground (no straight segment term): s^2/|g|, plus the straight part
        local g = math.abs(p.gz or cfg.default_gz)
        local maxr = (g > 0 and (s * s / g) or math.huge) + s * (p.t0 or 0)
        return nil, "out_of_range", { max_range_cm = maxr, dist_cm = len(sub(tpos, m)) }
    end
    local tau = (opts.arc == "high") and roots[#roots] or roots[1]
    local dvec = D(tau)
    local dir = norm(dvec)
    local sol = { dir = dir, tau = tau, arc = (opts.arc == "high" and #roots > 1) and "high" or "low", roots = #roots }
    sol.aim_point = add(tpos, mul(tvel, tau)) -- where the target will be
    sol.yaw = math.deg(math.atan(dir.Y, dir.X))
    sol.pitch = math.deg(math.asin(math.max(-1, math.min(1, dir.Z))))
    return sol
end

-- Camera rotation whose forward ray passes through muzzle + dir * aim_distance (the game shoots from the
-- muzzle toward the point under the crosshair). cam = camera location.
function R.camera_rotation(cam, m, dir, aim_dist)
    local p = add(m, mul(norm(dir), aim_dist or R.cfg.aim_distance))
    local d = sub(p, cam)
    local yaw = math.deg(math.atan(d.Y, d.X))
    local pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y)))
    return { Pitch = pitch, Yaw = yaw, Roll = 0 }, p
end

-- ------------------------------------------------------------------ learning (pure)
-- Fit a projectile's real speed, gravity and straight time from samples {t (s since launch), pos}.
-- Uses horizontal speed (unaffected by gravity) for s_h, the vertical second differences for gz, and
-- the time where the vertical drop starts for t0. Needs >= 4 samples.
function R.fit(samples)
    if #samples < 4 then return nil end
    local a, z = samples[1], samples[#samples]
    local dt = z.t - a.t
    if dt <= 0 then return nil end
    -- initial velocity from the first two samples
    local b = samples[2]
    local v0 = mul(sub(b.pos, a.pos), 1 / math.max(b.t - a.t, 1e-6))
    local speed = len(v0)
    local vh = math.sqrt(v0.X * v0.X + v0.Y * v0.Y)
    -- vertical acceleration: least squares on z(t) = z0 + vz t + gz/2 (t - t0)^2 is non-linear in t0;
    -- estimate gz from the second half (gravity certainly on), then t0 from where the drop departs
    -- from the straight line.
    local h = math.floor(#samples / 2)
    local function zacc(i)
        local p0, p1, p2 = samples[i - 1], samples[i], samples[i + 1]
        local d1 = (p1.pos.Z - p0.pos.Z) / math.max(p1.t - p0.t, 1e-6)
        local d2 = (p2.pos.Z - p1.pos.Z) / math.max(p2.t - p1.t, 1e-6)
        return (d2 - d1) / math.max((p2.t - p0.t) / 2, 1e-6)
    end
    local acc, n = 0, 0
    for i = math.max(2, h), #samples - 1 do acc = acc + zacc(i); n = n + 1 end
    local gz = n > 0 and acc / n or nil
    local t0 = 0
    if gz and gz < -1 then
        for i = 2, #samples - 1 do
            if zacc(i) < gz * 0.5 then t0 = math.max(0, samples[i - 1].t - a.t); break end
        end
    end
    return { speed = speed, speed_h = vh, gz = gz, t0 = t0, v0 = v0, n = #samples }
end

-- Closest approach between the projectile samples and the target track {t, pos} (same clock).
-- -> {dist_cm, t, vertical_cm (+ = above), lateral_cm (+ = right of the shot line), along_cm}
function R.closest_approach(samples, track)
    if #samples == 0 or #track == 0 then return nil end
    local best
    for _, s in ipairs(samples) do
        -- target position at the sample's time (nearest track point)
        local tp, bd = track[1].pos, math.huge
        for _, q in ipairs(track) do
            local d = math.abs(q.t - s.t)
            if d < bd then tp, bd = q.pos, d end
        end
        local dv = sub(s.pos, tp)
        local d = len(dv)
        if not best or d < best.dist_cm then best = { dist_cm = d, t = s.t, delta = dv, at = s.pos, target = tp } end
    end
    -- decompose in the shot frame: forward = horizontal direction of travel
    local f = norm(v(samples[#samples].pos.X - samples[1].pos.X, samples[#samples].pos.Y - samples[1].pos.Y, 0))
    local right = v(-f.Y, f.X, 0) -- UE: X forward, Y right, Z up (left-handed)
    best.vertical_cm = best.delta.Z
    best.lateral_cm = best.delta.X * right.X + best.delta.Y * right.Y
    best.along_cm = best.delta.X * f.X + best.delta.Y * f.Y
    return best
end

-- Profile for a launcher key (e.g. "ITEM_Crossbow_Adamant|ITEM_Ammo_Bolts_Bone" or a spell id),
-- seeded from game data; learned values blend in.
function R.profile(key, seed)
    local st = S()
    local p = st.profiles[key]
    if not p then
        p = { key = key, speed = (seed and seed.speed) or R.cfg.default_speed, gz = (seed and seed.gz) or R.cfg.default_gz,
              t0 = (seed and seed.t0) or 0, n = 0, pitch_bias = 0, yaw_bias = 0, source = seed and seed.source or "default" }
        st.profiles[key] = p
    elseif seed and p.n == 0 then
        for k, x in pairs(seed) do p[k] = x end
    end
    return p
end

-- Persistence (combat.lua owns the file): the learned profiles and metrics, plain data.
function R.export() local st = S(); return { profiles = st.profiles, metrics = st.metrics } end
-- A saved profile replaces one with fewer fitted shots (n); metrics only fill keys not seen this session.
function R.import(t)
    if type(t) ~= "table" then return 0 end
    local st, n = S(), 0
    for k, p in pairs(type(t.profiles) == "table" and t.profiles or {}) do
        local cur = st.profiles[k]
        if type(p) == "table" and (not cur or (cur.n or 0) < (p.n or 0)) then st.profiles[k] = p; n = n + 1 end
    end
    for k, m in pairs(type(t.metrics) == "table" and t.metrics or {}) do
        if type(m) == "table" and not st.metrics[k] then st.metrics[k] = m end
    end
    return n
end

-- Blend a fitted shot into the profile, then keep a residual angular bias from the miss.
function R.learn(key, fit, miss, shot)
    local p = R.profile(key)
    local k = R.cfg.blend
    if fit then
        if fit.speed and fit.speed > 100 then p.speed = p.speed + k * (fit.speed - p.speed) end
        if fit.gz and fit.gz < 0 and fit.gz > -10000 then p.gz = p.gz + k * (fit.gz - p.gz) end
        if fit.t0 then p.t0 = p.t0 + k * (fit.t0 - p.t0) end
        p.source = "learned"
    end
    if miss and shot and shot.range_cm and shot.range_cm > 100 then
        local kb = R.cfg.bias_blend
        local dp = -math.deg(math.atan(miss.vertical_cm or 0, shot.range_cm))
        local dy = -math.deg(math.atan(miss.lateral_cm or 0, shot.range_cm)) -- a miss to the right -> aim left (yaw -)
        local mb = R.cfg.max_bias_deg
        p.pitch_bias = math.max(-mb, math.min(mb, p.pitch_bias + kb * dp))
        p.yaw_bias = math.max(-mb, math.min(mb, p.yaw_bias + kb * dy))
    end
    p.n = p.n + 1
    return p
end

-- ------------------------------------------------------------------ metrics (pure)
local function bucket(x, edges)
    for i, e in ipairs(edges) do if x < e then return i end end
    return #edges + 1
end
local function bucket_name(i, edges, unit)
    local lo = i == 1 and 0 or edges[i - 1]
    local hi = edges[i]
    return hi and string.format("%g-%g%s", lo, hi, unit) or string.format("%g+%s", lo, unit)
end

-- shot = {key, dist_m, target_speed_ms, hit (bool), miss_cm}
function R.record(shot)
    local st = S()
    local m = st.metrics[shot.key or "?"] or { shots = 0, hits = 0, by_dist = {}, by_speed = {} }
    st.metrics[shot.key or "?"] = m
    m.shots = m.shots + 1
    if shot.hit then m.hits = m.hits + 1 end
    local function inc(t, name)
        local e = t[name] or { shots = 0, hits = 0 }
        t[name] = e
        e.shots = e.shots + 1
        if shot.hit then e.hits = e.hits + 1 end
        e.rate = e.hits / e.shots
    end
    inc(m.by_dist, bucket_name(bucket(shot.dist_m or 0, R.cfg.dist_buckets), R.cfg.dist_buckets, "m"))
    inc(m.by_speed, bucket_name(bucket(shot.target_speed_ms or 0, R.cfg.speed_buckets), R.cfg.speed_buckets, "m/s"))
    m.rate = m.hits / m.shots
    st.shots[#st.shots + 1] = shot
    if #st.shots > 50 then table.remove(st.shots, 1) end
    return m
end

function R.metrics() return S().metrics end

-- ------------------------------------------------------------------ aimer (shared by combat and spells)
-- One aimer per engagement: feed it the target's position each tick (velocity is estimated from the
-- track), ask it for the camera rotation to shoot with. Pure apart from what the caller passes in.
local Aimer = {}
Aimer.__index = Aimer

function R.new_aimer(key, seed)
    local a = setmetatable({ key = key, track = {}, vel = v() }, Aimer)
    a.p = R.profile(key, seed)
    return a
end

-- t = seconds (any monotonic clock), pos = target position (cm)
function Aimer:observe(t, pos)
    local tr = self.track
    tr[#tr + 1] = { t = t, pos = v(pos.X, pos.Y, pos.Z) }
    while #tr > 2 and tr[#tr].t - tr[1].t > 1.0 do table.remove(tr, 1) end
    if #tr >= 2 then
        local a, b = tr[1], tr[#tr]
        local dt = b.t - a.t
        if dt > 0.05 then
            local nv = mul(sub(b.pos, a.pos), 1 / dt)
            nv.Z = 0 -- creatures walk; vertical jitter is not lead
            self.vel = nv
        end
    end
    self.pos = tr[#tr].pos
end

function Aimer:speed_ms() return len(self.vel) / 100 end

-- -> rotation {Pitch, Yaw, Roll}, sol | nil, why, info.  aim_z = height on the target to aim at (cm).
function Aimer:solve(muzzle, cam, opts)
    opts = opts or {}
    if not (self.pos and muzzle) then return nil, "no_target" end
    local tp = v(self.pos.X, self.pos.Y, self.pos.Z + (opts.aim_z or 0))
    local sol, why, info = R.solve(muzzle, tp, self.vel, self.p, opts)
    if not sol then return nil, why, info end
    local rot = R.camera_rotation(cam or muzzle, muzzle, sol.dir, opts.aim_distance)
    rot.Pitch = rot.Pitch + (self.p.pitch_bias or 0)
    rot.Yaw = rot.Yaw + (self.p.yaw_bias or 0)
    sol.range_cm = len(sub(tp, muzzle))
    return rot, sol
end

-- A shot was fired: start recording the projectile and the target.
function Aimer:fired(t, sol, ids_before, muzzle)
    self.shot = { t = t, sol = sol, ids_before = ids_before or {}, samples = {}, target_track = {}, muzzle = muzzle,
                  range_cm = sol and sol.range_cm, dist_m = sol and sol.range_cm and sol.range_cm / 100, tspeed = self:speed_ms() }
    return self.shot
end

-- Per frame while a shot flies: proj_pos (or nil when it is gone), target pos. -> true when finished.
function Aimer:sample(t, proj_pos, target_pos)
    local s = self.shot
    if not s then return true end
    local rel = t - s.t
    if target_pos then s.target_track[#s.target_track + 1] = { t = rel, pos = v(target_pos.X, target_pos.Y, target_pos.Z) } end
    if proj_pos then
        s.samples[#s.samples + 1] = { t = rel, pos = v(proj_pos.X, proj_pos.Y, proj_pos.Z) }
        s.seen = true
    end
    return (s.seen and not proj_pos) or rel > (R.cfg.max_time + 0.5)
end

-- Close the shot: fit, miss, learn, metrics. hit = the game's verdict (our damage on the target).
function Aimer:finish(hit)
    local s = self.shot
    self.shot = nil
    if not s then return nil end
    local fit = R.fit(s.samples)
    local miss = R.closest_approach(s.samples, s.target_track)
    local was = { speed = self.p.speed, gz = self.p.gz, t0 = self.p.t0 }
    R.learn(self.key, fit, (not hit) and miss or nil, s)
    local m = R.record({ key = self.key, dist_m = s.dist_m, target_speed_ms = s.tspeed, hit = hit == true,
                         miss_cm = miss and miss.dist_cm })
    return { hit = hit == true, fit = fit, miss = miss, profile_before = was, profile = self.p, metrics = m, samples = #s.samples }
end

-- ------------------------------------------------------------------ live reads (game glue)
local function num(x) return type(x) == "number" and x or nil end

-- The pawn's ranged component (PlayerRangedAttackComponent).
function R.ranged_component(pawn)
    if not U then return nil end
    local id = U.short(pawn)
    for _, c in ipairs(U.find_all("PlayerRangedAttackComponent", { skip_defaults = true })) do
        local o = U.try(function() return c:GetOwner() end)
        if U.valid(o) and U.short(o) == id then return c end
    end
end

-- Seed parameters for the held ranged weapon + equipped ammo from game data.
-- -> {speed, gz, t0, max_time, source, key, inaccuracy, full_accuracy_s, ...} or nil, why
function R.read_weapon_params(pawn, charge)
    if not U then return nil, "no util" end
    local comp = R.ranged_component(pawn)
    if not comp then return nil, "no_ranged_component" end
    local out = { source = "game_data" }
    local ammo = U.try(function() return comp:GetEquippedRangedAmmoDataForCurrentWeapon() end)
    if U.valid(ammo) then
        out.ammo = (U.path_of(ammo) or ""):match("%.([%w_]+)$")
        local pd = U.try(function() return ammo.ProjectileData end)
        if pd then
            out.speed = num(U.try(function() return pd.LaunchSpeed end))
            local gz = num(U.try(function() return pd.OverrideGravityZ end))
            if gz and gz ~= 0 then out.gz = gz end
            out.t0 = num(U.try(function() return pd.TimeWithoutGravity end))
            out.max_time = num(U.try(function() return pd.MaxSimulationTime end))
        end
    end
    local coll = U.try(function() return comp.CachedRangedAttackCollection end)
    if U.valid(coll) then
        local c = charge or 1
        local sc = U.try(function() return coll.LaunchSpeedCurve end)
        local gc = U.try(function() return coll.OverrideGravityZCurve end)
        out.speed_curve = U.valid(sc) and num(U.try(function() return sc:GetFloatValue(c) end)) or nil
        out.gz_curve = U.valid(gc) and num(U.try(function() return gc:GetFloatValue(c) end)) or nil
        out.full_accuracy_s = num(U.try(function() return coll.TimeBeforeFullAccuracy end))
        out.max_charge_s = num(U.try(function() return coll.MaxChargeUpDuration end))
    end
    -- curves (by charge) override the ammo's base values when present and plausible
    if out.speed_curve and out.speed_curve > 100 then out.speed = out.speed_curve end
    if out.gz_curve and out.gz_curve < 0 then out.gz = out.gz_curve end
    out.inaccuracy = num(U.try(function() return comp:GetCurrentArrowInaccuracy() end))
    out.base_inaccuracy = num(U.try(function() return comp.BaseInaccuracy end))
    out.aim_active = U.try(function() return comp:IsAimModeActive() end) == true
    out.full_accuracy = U.try(function() return comp.HasReachedFullAccuracy end) == true
    out.has_ammo = U.try(function() return comp:HasRequiredAmmoEquipped() end)
    return out
end

-- Seed parameters for a projectile spell from its projectile class CDO (ADominionSpellProjectile).
function R.read_spell_params(projectile_class)
    if not U or not U.valid(projectile_class) then return nil, "no_class" end
    local cdo = U.try(function() return projectile_class:GetCDO() end)
    local pm = U.valid(cdo) and U.try(function() return cdo.ProjectileMovement end)
    if not U.valid(pm) then return nil, "no_projectile_movement" end
    local speed = num(U.try(function() return pm.InitialSpeed end))
    local scale = num(U.try(function() return pm.ProjectileGravityScale end)) or 1
    return { speed = speed, gz = R.cfg.default_gz * scale, t0 = 0, source = "spell_class" }
end

-- Muzzle estimate: the ranged weapon actor's location (its projectile socket when readable), else
-- the pawn's location raised to shoulder height.
function R.muzzle(pawn, comp)
    if not U then return nil end
    local wa = comp and U.try(function() return comp.RangedWeaponActor end)
    if U.valid(wa) then
        local sock = U.try(function() return wa.ProjectileSocketName end)
        local mesh = U.try(function() return wa:GetComponentByClass(StaticFindObject("/Script/Engine.MeshComponent")) end)
        local p = (U.valid(mesh) and sock) and U.try(function() return mesh:GetSocketLocation(sock) end)
        if p then return v(p.X, p.Y, p.Z), "socket" end
        local l = U.loc(wa)
        if l then return v(l.X, l.Y, l.Z), "weapon" end
    end
    local l = U.loc(pawn)
    return l and v(l.X, l.Y, l.Z + 60) or nil, "pawn"
end

function R.camera_location(pc)
    if not U then return nil end
    local cm = U.try(function() return pc.PlayerCameraManager end)
    local p = U.valid(cm) and U.try(function() return cm:GetCameraLocation() end)
    return p and v(p.X, p.Y, p.Z) or nil
end

-- Projectiles in the world now (ADominionProjectile + spell projectiles): set of ids.
function R.projectile_ids()
    local out = {}
    if not U then return out end
    for _, cls in ipairs({ "DominionProjectile", "DominionSpellProjectile" }) do
        for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do out[U.short(a)] = a end
    end
    return out
end

return R

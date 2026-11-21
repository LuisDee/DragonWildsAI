-- DATA (not logic): game actors that put damage on the ground, how to read their area and timing, by class
-- (dump 26161880; docs/design/velgar.md §1/§3c). combat.lua turns each live one into a move.lua avoid zone.
-- Every read is a PROPERTY read on the actor (or its component); defaults are priors when a field is absent.
--   class        FindAllOf class (native base class: every subclass is found)
--   radius       property names tried in order (cm); radius_default (cm) when none reads
--   extent       FVector property names tried in order (cm: the half extent of a box component), read before
--                radius; the zone is the circle round the box's half-diagonal (it covers the box at any yaw)
--   telegraph    property with the seconds from activation to damage (ttl of the zone); ttl_default (s)
--   target       a vector property with the landing point (else the actor's own location)
--   component    the radius lives on this component property of the actor (emitter spheres)
--   persistent   the zone lives as long as the actor (clouds, trails): refreshed while seen
--   standing     looked for WITHOUT a trigger (ground_hazards.lua): the sense census lists it on the Hazards line
--                and every go_to / follow plans round it (move.lua avoid-zone layer "ground"). A cloud that stays put.
--   words        what a player calls it (the Hazards line);  effect  what it does to him, in words
--   dps          HP a second it takes from him, MEASURED (vitals.jsonl damage rows; the source is named beside it).
--                move.lua holds a walk outside one with no way round only while his HP covers dps x the wait
--                (avoidzones.verdict); a zone with no rate uses the highest rate named here.
--   life         property names, on the OWNER actor, with its lifetime in seconds (0 = forever = unknown), tried in
--                order: when it ends = first seen + that (ground_hazards.lua; first seen is no earlier than its spawn,
--                so the end is never guessed too soon). None reads: its end is unknown, and a walk never waits on it.
return {
    { name = "ground_projectile", class = "AIGroundProjectile", radius = { "ExplosionTriggerRadius" }, radius_default = 250,
      telegraph = "TelegraphTime", ttl_default = 1.0, target = "TargetLocation" },
    { name = "meteor", class = "AIMeteorProjectile", radius = { "Radius" }, radius_default = 400,
      telegraph = "TelegraphTime", ttl_default = 2.0 },
    { name = "delayed_damage", class = "DelayedDamage", radius = { "Radius", "DamageRadius" }, radius_default = 500,
      telegraph = "TelegraphTime", ttl_default = 1.5 },
    { name = "poison_cloud", class = "PoisonEmitterSphere", component_is_hazard = true, radius = { "NetworkedRadius", "SphereRadius" },
      radius_default = 400, persistent = true, ttl_default = 1.0, standing = true, words = "poison cloud",
      effect = "poisons you while you stand in it (damage over time)",
      -- owners seen live: BP_DEDA_MeteorPoisonCloud_C (dump 26670300: BP_DragonVelgar_MeteorStrike_PoisonCloud_C,
      -- Initialize(Radius, Duration), no Duration property, so only AActor.InitialLifeSpan can name its end). Rate:
      -- vitals.jsonl 2026-11-21T00:41:13-29Z (trial 20261121-003451-L3, a field of them), 4.0 HP per row about
      -- once a second, status poison, 67 -> 0 HP; DISCOVERIES "Environmental poison" (the box kind, 4 HP/s).
      dps = 4, life = { "Duration", "InitialLifeSpan" } },
    -- the clouds that killed him 4 times in the L3 trials of 2026-11-20: a UPoisonEmitterBox component (Dominion; dump
    -- 26670300: UEffectEmitterBox.NetworkedExtent, UBoxComponent.BoxExtent) owned by BP_DEDA_PoisonBreath_PoisonCloud_C
    -- (BP_DragonVelgar_PoisonBreath_PoisonCloud_C in the dump). Its damage rows: 4 HP a second, status poison
    -- (vitals.jsonl source.class PoisonEmitterBox; DISCOVERIES "Environmental poison"). Size: its own extent, else 4 m.
    { name = "poison_cloud_box", class = "PoisonEmitterBox", component_is_hazard = true, extent = { "NetworkedExtent", "BoxExtent" },
      radius_default = 400, persistent = true, ttl_default = 1.0, standing = true, words = "poison cloud",
      effect = "poisons you while you stand in it (damage over time, about 4 HP a second)",
      -- rate: DISCOVERIES "Environmental poison" (100 -> 0 HP in 25 s, 4 HP/s). Life: the owner's own Duration
      -- (dump 26670300: BP_DragonVelgar_PoisonBreath_PoisonCloud_C.Duration, a double), else AActor.InitialLifeSpan.
      dps = 4, life = { "Duration", "InitialLifeSpan" } },
}

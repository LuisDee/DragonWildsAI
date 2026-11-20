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
return {
    { name = "ground_projectile", class = "AIGroundProjectile", radius = { "ExplosionTriggerRadius" }, radius_default = 250,
      telegraph = "TelegraphTime", ttl_default = 1.0, target = "TargetLocation" },
    { name = "meteor", class = "AIMeteorProjectile", radius = { "Radius" }, radius_default = 400,
      telegraph = "TelegraphTime", ttl_default = 2.0 },
    { name = "delayed_damage", class = "DelayedDamage", radius = { "Radius", "DamageRadius" }, radius_default = 500,
      telegraph = "TelegraphTime", ttl_default = 1.5 },
    { name = "poison_cloud", class = "PoisonEmitterSphere", component_is_hazard = true, radius = { "NetworkedRadius", "SphereRadius" },
      radius_default = 400, persistent = true, ttl_default = 1.0, standing = true, words = "poison cloud",
      effect = "poisons you while you stand in it (damage over time)" },
    -- the clouds that killed him 4 times in the L3 trials of 2026-11-20: a UPoisonEmitterBox component (Dominion; dump
    -- 26670300: UEffectEmitterBox.NetworkedExtent, UBoxComponent.BoxExtent) owned by BP_DEDA_PoisonBreath_PoisonCloud_C
    -- (BP_DragonVelgar_PoisonBreath_PoisonCloud_C in the dump). Its damage rows: 4 HP a second, status poison
    -- (vitals.jsonl source.class PoisonEmitterBox; DISCOVERIES "Environmental poison"). Size: its own extent, else 4 m.
    { name = "poison_cloud_box", class = "PoisonEmitterBox", component_is_hazard = true, extent = { "NetworkedExtent", "BoxExtent" },
      radius_default = 400, persistent = true, ttl_default = 1.0, standing = true, words = "poison cloud",
      effect = "poisons you while you stand in it (damage over time, about 4 HP a second)" },
}

-- DATA (not logic): game actors that put damage on the ground, how to read their area and timing, by class
-- (dump 26161880; docs/design/velgar.md §1/§3c). combat.lua turns each live one into a move.lua avoid zone.
-- Every read is a PROPERTY read on the actor (or its component); defaults are priors when a field is absent.
--   class        FindAllOf class (native base class: every subclass is found)
--   radius       property names tried in order (cm); radius_default (cm) when none reads
--   telegraph    property with the seconds from activation to damage (ttl of the zone); ttl_default (s)
--   target       a vector property with the landing point (else the actor's own location)
--   component    the radius lives on this component property of the actor (emitter spheres)
--   persistent   the zone lives as long as the actor (clouds, trails): refreshed while seen
return {
    { name = "ground_projectile", class = "AIGroundProjectile", radius = { "ExplosionTriggerRadius" }, radius_default = 250,
      telegraph = "TelegraphTime", ttl_default = 1.0, target = "TargetLocation" },
    { name = "meteor", class = "AIMeteorProjectile", radius = { "Radius" }, radius_default = 400,
      telegraph = "TelegraphTime", ttl_default = 2.0 },
    { name = "delayed_damage", class = "DelayedDamage", radius = { "Radius", "DamageRadius" }, radius_default = 500,
      telegraph = "TelegraphTime", ttl_default = 1.5 },
    { name = "poison_cloud", class = "PoisonEmitterSphere", component_is_hazard = true, radius = { "NetworkedRadius", "SphereRadius" },
      radius_default = 400, persistent = true, ttl_default = 1.0 },
}

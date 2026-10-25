"""Benchmark predicate leaves (design §4.2), registered into the shared brain/predicates.py (Director-owned).

Every leaf judges on OBSERVER evidence (ctx["observations"]: probe before/after each world-changing call, the
harness's own reads; ctx["referee"]: server-side events on dev, BenchWorld's on the mock). A skill's reply is only
cross-checked: when it claims what the probe doesn't show (or hides what it does), the leaf records a
`sensor_mismatch` in ctx["mismatches"] and fails - the runner turns that into result "error" (review finding 1).

Evidence is attribution-windowed: it must come from the observation of the action the leaf is about (finding 4).
Generic evidence (a base GE class, a tag or class that several spells share) is never accepted for a spell.
"""
from __future__ import annotations

import json
import math
from collections import Counter
from functools import lru_cache
from pathlib import Path
from typing import Any

from brain import predicates as P
from brain.predicates import PredicateError, Result

ROOT = Path(__file__).resolve().parents[2]
RUNE_PREFIX = "ITEM_Rune_"
# Base classes every GE derives from: matching them proves nothing about WHICH spell (review finding 4).
GENERIC_GE = frozenset({"GameplayEffect", "DominionGameplayEffect", "DominionStatusEffect", "GE_"})
UNOBSERVABLE = frozenset({"held_item_effect", "world_module", "needs_live_observation"})
TRAVEL_MAX_S = 15.0  # a travel/dash displacement must happen within the cast call (with the cast animation)
TELEPORT_MIN_M = 300.0


@lru_cache(maxsize=2)
def default_spells() -> dict:
    p = ROOT / "data" / "spell_effects.json"
    return json.loads(p.read_text(encoding="utf-8")).get("spells") or {} if p.exists() else {}


def rune_item(name: str) -> str:
    return name if name.startswith("ITEM_") else RUNE_PREFIX + name


def _spells(ctx: dict) -> dict:
    return ctx.get("spells") or default_spells()


def _key(e: dict) -> str | None:
    if e.get("kind") == "tag_added":
        return "tag:" + str(e.get("tag"))
    if e.get("kind") == "ge_added":
        return "ge:" + str(e.get("class") or e.get("class_contains"))
    if e.get("kind") == "spell_actor":
        return "actor:" + str(e.get("class"))
    return None


def specific_effects(sid: str, spells: dict) -> tuple[list[dict], list[dict]]:
    """(specific, rejected) effect entries for a spell: a GE/tag/actor class that is a base class, or that another
    spell's proof also uses, is rejected (it can't tell which spell went off)."""
    use = Counter(k for s in spells.values() for e in (s.get("proof") or {}).get("effect") or [] if (k := _key(e)))
    good, bad = [], []
    for e in (spells.get(sid, {}).get("proof") or {}).get("effect") or []:
        k = _key(e)
        cls = str(e.get("class") or e.get("class_contains") or "")
        generic = e.get("kind") == "ge_added" and (cls in GENERIC_GE or any(cls == g or cls.startswith(g) and len(cls) <= len(g) + 1
                                                                           for g in GENERIC_GE))
        (bad if generic or (k and use[k] > 1) else good).append(e)
    return good, bad


def _validate_spell(a: dict, items) -> dict:
    sid = a.get("spell")
    if not isinstance(sid, str) or not sid:
        raise PredicateError("spell_effect needs spell (the spell's asset id)")
    spells = default_spells()
    if spells and sid not in spells:
        raise PredicateError(f"unknown spell {sid!r}", [s for s in spells if sid.lower() in s.lower()][:6])
    return dict(a)


# ------------------------------------------------------------------ probe helpers


def _inv(p: dict | None) -> dict:
    return (p or {}).get("inventory") or {}


def _new(after: list, before: list, key=lambda x: x.get("id")) -> list:
    seen = {key(x) for x in before or []}
    return [x for x in after or [] if key(x) not in seen]


def _cast_evidence(sid: str, sp: dict, o) -> tuple[bool, bool]:
    """(runes spent exactly the cost, cooldown entry changed) from the probes around one observation."""
    cost = {rune_item(r): int(n) for r, n in (sp.get("cost") or {}).items()}
    b, a = _inv(o.before), _inv(o.after)
    runes = bool(cost) and all(b.get(i, 0) - a.get(i, 0) == n for i, n in cost.items())
    cb, ca = (o.before.get("cooldowns") or {}).get(sid), (o.after.get("cooldowns") or {}).get(sid)
    return runes, ca is not None and ca != cb


def _effect(e: dict, o, target: Any) -> bool | None:
    k = e.get("kind")
    if k in UNOBSERVABLE or e.get("observable") is False:
        return None
    b, a = o.before, o.after
    if k == "tag_added":
        return e.get("tag") in (a.get("tags") or []) and e.get("tag") not in (b.get("tags") or [])
    if k == "ge_added":
        want = e.get("class")
        part = e.get("class_contains")
        new = [g for g in a.get("ge") or [] if g not in (b.get("ge") or [])]
        return any(g == want if want else (part and part in g) for g in new)
    if k == "spell_actor":
        return any(x.get("class") == e.get("class") for x in _new(a.get("actors"), b.get("actors")))
    if k == "jump_apex_gain_m":
        ba, aa = b.get("jump_apex_m"), a.get("jump_apex_m")
        return None if ba is None or aa is None else aa - ba >= float(e.get("min", 1.0))
    if k in ("air_dash_m", "moved_m"):
        d = math.dist(b.get("position") or [0, 0, 0], a.get("position") or [0, 0, 0])
        return d >= float(e.get("min", 3.0)) and (o.t1 - o.t0) <= TRAVEL_MAX_S
    if k == "target_gone":
        ids = {t.get("id") for t in (b.get("things") or []) + (b.get("creatures") or [])}
        after_ids = {t.get("id") for t in (a.get("things") or [])} | {c.get("id") for c in a.get("creatures") or [] if c.get("alive", True)}
        return isinstance(target, str) and target in ids and target not in after_ids
    if k == "target_health_drop":
        hb = {c["id"]: c.get("hp") for c in b.get("creatures") or []}
        ha = {c["id"]: c.get("hp") for c in a.get("creatures") or []}
        if not isinstance(target, str) or target not in hb:
            return False
        return (hb[target] or 0) - (ha.get(target) or 0) >= float(e.get("min", 1))
    if k == "drops_spawned":
        part = str(e.get("item_contains") or "")
        return any(part.lower() in str(g.get("item", "")).lower() for g in _new(a.get("ground"), b.get("ground")))
    return None


def _reply_mismatch(o, runes: bool, cd: bool) -> str | None:
    d = (o.reply or {}).get("data") or {}
    if not (o.reply or {}).get("ok"):
        return "the reply says failed but the probe shows the cast went off" if (runes and cd) else None
    claims_runes = bool(d.get("runes_spent"))
    if claims_runes != runes:
        return f"reply runes_spent={claims_runes} but probe runes_spent={runes}"
    if bool(d.get("cooldown_started")) != cd:
        return f"reply cooldown_started={bool(d.get('cooldown_started'))} but probe shows {cd}"
    tags = set((d.get("effects") or {}).get("tags") or [])
    seen = set(o.after.get("tags") or [])
    if tags - seen:
        return f"reply claims tags {sorted(tags - seen)} the probe doesn't see"
    return None


def cast_record(sid: str, ctx: dict) -> dict:
    """Every cast observation and what the probe says about THIS spell in it."""
    sp = _spells(ctx).get(sid) or {}
    out = []
    for o in ctx.get("observations") or []:
        if o.tool != "cast":
            continue
        runes, cd = _cast_evidence(sid, sp, o)
        d = (o.reply or {}).get("data") or {}
        claims_this = d.get("id") == sid
        if not (runes or cd or claims_this):
            continue
        out.append({"obs": o, "runes": runes, "cd": cd, "mismatch": _reply_mismatch(o, runes, cd) if (claims_this or runes or cd) else None})
    return {"spell": sp, "casts": out}


def _spell_effect(a, state, ctx, cat):
    sid = a["spell"]
    rec = cast_record(sid, ctx)
    sp = rec["spell"]
    name = sp.get("name") or sid
    if not rec["casts"]:
        return Result(False, f"{name}: not cast (no rune spend or cooldown for it seen by the probe)", 0.0)
    good, rejected = specific_effects(sid, _spells(ctx))
    best: Result | None = None
    for c in rec["casts"]:
        if c["mismatch"]:
            ctx.setdefault("mismatches", []).append({"leaf": "spell_effect", "spell": sid, "why": c["mismatch"],
                                                     "seq": c["obs"].seq})
            return Result(False, f"{name}: sensor_mismatch ({c['mismatch']})", 0.0)
        if not (c["runes"] and c["cd"]):
            r = Result(False, f"{name}: runes {'spent' if c['runes'] else 'not spent'}, cooldown "
                              f"{'started' if c['cd'] else 'not started'}", 0.3)
            best = best or r
            continue
        target = (c["obs"].args or {}).get("target")
        vals = [(_effect(e, c["obs"], target), e) for e in good]
        hit = next((e for v, e in vals if v is True), None)
        if hit:
            what = f"{hit.get('kind')} {hit.get('tag') or hit.get('class') or hit.get('class_contains') or ''}".strip()
            return Result(True, f"{name}: cast with its effect ({what})",
                          1.0, measures={f"cast:{sid}": 1.0})
        if any(v is None for v, _ in vals) or not good:
            why = "only generic evidence in the proof" if not good and rejected else "its effect is not observable yet"
            best = Result(None, f"{name}: cast (runes + cooldown) but {why}", 0.7, [f"effect:{sid}"])
        elif best is None or best.passed is False:
            best = Result(False, f"{name}: cast but none of its effects was observed", 0.6)
    return best or Result(False, f"{name}: no successful cast", 0.0)


def _validate_purpose(a: dict, items) -> dict:
    a = _validate_spell(a, items)
    if not isinstance(a.get("success"), dict):
        raise PredicateError("purpose needs success (a predicate: what the spell achieves)")
    a["success"] = P.validate(a["success"], items)
    return a


def _purpose(a, state, ctx, cat):
    """The purpose achieved AND the purpose's spell actually cast in the case (finding: USE, not just cast)."""
    sid = a["spell"]
    rec = cast_record(sid, ctx)
    cast_ok = any(c["runes"] and c["cd"] and not c["mismatch"] for c in rec["casts"])
    for c in rec["casts"]:
        if c["mismatch"]:
            ctx.setdefault("mismatches", []).append({"leaf": "purpose", "spell": sid, "why": c["mismatch"]})
            return Result(False, f"sensor_mismatch ({c['mismatch']})", 0.0)
    inner = P.evaluate(a["success"], state, ctx, cat)
    if not cast_ok:
        return Result(False if inner.passed is not None else None,
                      f"{rec['spell'].get('name') or sid} not used; goal: {inner.detail}", 0.5 * inner.progress, inner.missing)
    return Result(inner.passed, f"used {rec['spell'].get('name') or sid}; {inner.detail}", inner.progress, inner.missing,
                  inner.measures)


# ------------------------------------------------------------------ referee-based leaves


def _ref(ctx: dict, kind: str) -> list[dict] | None:
    sup = ctx.get("referee_supports")
    if sup is not None and kind not in sup:
        return None
    return [e for e in ctx.get("referee") or [] if e.get("kind") == kind]


def _no_event(a, state, ctx, cat):
    ev = _ref(ctx, a["kind"])
    if ev is None:
        return Result(None, f"no referee for {a['kind']} events", 0.0, [f"referee:{a['kind']}"])
    who = a.get("who")
    hits = [e for e in ev if who is None or e.get("who") == who or e.get("target") == who]
    return Result(not hits, f"{len(hits)} {a['kind']} event(s)", 1.0 if not hits else 0.0)


def _damage_type_dealt(a, state, ctx, cat):
    ev = _ref(ctx, "damage")
    if ev is None:
        return Result(None, "no referee damage events", 0.0, ["referee:damage"])
    want = set(a.get("types") or [])
    mine = [e for e in ev if e.get("by") == "self" and (not a.get("target_kind_id") or e.get("kind_id") == a["target_kind_id"])]
    good = [e for e in mine if any(str(e.get("damage_type", "")).startswith(t) for t in want)]
    return Result(bool(good), f"{len(good)}/{len(mine)} hits with {sorted(want)}", 1.0 if good else 0.0)


def _defended(a, state, ctx, cat):
    ev = _ref(ctx, "defended")
    if ev is None:
        return Result(None, "no referee defence events", 0.0, ["referee:defended"])
    ok = [e for e in ev if e.get("how") == a["kind"] and e.get("outcome") in ("parried", "dodged", "missed", "negated")
          and (a.get("against") != "telegraph" or e.get("telegraphed"))]
    n = int(a.get("at_least", 1))
    return Result(len(ok) >= n, f"{len(ok)}/{n} {a['kind']}s against {a.get('against', 'any')} attacks", P._ratio(len(ok), n))


def _hit_rate(a, state, ctx, cat):
    ev = _ref(ctx, "projectile")
    if ev is None:
        return Result(None, "no referee projectile events", 0.0, ["referee:projectile"])
    shots = [e for e in ev if e.get("by") == "self"
             and (a.get("range_m") is None or abs(float(e.get("range_m", 0)) - float(a["range_m"])) <= 3)
             and (not a.get("target_moving") or float(e.get("target_speed", 0)) > 0.5)]
    hits = sum(1 for e in shots if e.get("hit"))
    if len(shots) < int(a.get("min_shots", 10)):
        return Result(None, f"only {len(shots)} shots (need {a.get('min_shots', 10)})", 0.0, ["shots"])
    pct = 100.0 * hits / len(shots)
    return Result(pct >= float(a["min_pct"]), f"{hits}/{len(shots)} hits ({pct:.0f}%)", min(1.0, pct / float(a["min_pct"])),
                  measures={"shots": float(len(shots)), "hits": float(hits)})


def _teleported(a, state, ctx, cat):
    n = 0
    for o in ctx.get("observations") or []:
        d = math.dist((o.before or {}).get("position") or [0, 0, 0], (o.after or {}).get("position") or [0, 0, 0])
        if d >= TELEPORT_MIN_M and (o.t1 - o.t0) <= 60:
            n += 1
    ev = _ref(ctx, "teleport")
    if ev is not None:
        via = a.get("via")
        n = min(n, len([e for e in ev if via is None or e.get("via") == via])) if n else 0
    elif a.get("via"):
        return Result(None if n else False, f"{n} long jump(s) in position; no referee to say how", 0.0,
                      ["referee:teleport"] if n else [])
    want = int(a.get("at_least", 1))
    return Result(n >= want, f"{n}/{want} teleports", P._ratio(n, want))


def _trips(a, state, ctx, cat):
    ev = _ref(ctx, "deposit")
    if ev is None:
        return Result(None, "no referee deposit events", 0.0, ["referee:deposit"])
    want = int(a.get("deposits_at_least", 2))
    return Result(len(ev) >= want, f"{len(ev)}/{want} deposits", P._ratio(len(ev), want))


def _delivered(a, state, ctx, cat):
    """Items left HIS bag (probe) and arrived with the player: in the player's inventory (probe/referee) or on the
    ground within 3 m of the player. 'In his bag' is never a delivery (review finding 10d)."""
    p0, p1 = ctx.get("probe0") or {}, ctx.get("probe1") or {}
    ids = a.get("ids") or (a["item"],)
    who = a.get("to")
    lost = sum(_inv(p0).get(i, 0) - _inv(p1).get(i, 0) for i in ids)
    pl0 = next((p for p in p0.get("players") or [] if p.get("name") == who), None)
    pl1 = next((p for p in p1.get("players") or [] if p.get("name") == who), None)
    if pl1 is None:
        return Result(None, f"{who} not observed", 0.0, ["players"])
    got = sum((pl1.get("inventory") or {}).get(i, 0) - ((pl0 or {}).get("inventory") or {}).get(i, 0) for i in ids)
    near = sum(g.get("count", 1) for g in _new(p1.get("ground"), p0.get("ground"))
               if g.get("item") in ids and math.dist(g.get("position") or [0, 0, 0], pl1.get("position") or [0, 0, 0]) <= 3.0)
    arrived = min(lost, got + near)
    want = float(a.get("at_least", 1))
    return Result(arrived >= want, f"{arrived:g}/{want:g} {a['item']} delivered to {who}", P._ratio(arrived, want),
                  measures={f"delivered:{ids[0]}": float(arrived)})


def _validate_items(a: dict, items) -> dict:
    a = dict(a)
    if a.get("item"):
        a["ids"] = list(items.resolve(a["item"]))
    return a


def _prepared(a, state, ctx, cat):
    """Before the first hit of the fight, at least one preparation from `any` held (finding 11)."""
    ev = _ref(ctx, "damage")
    if ev is None:
        return Result(None, "no referee damage events", 0.0, ["referee:damage"])
    if not ev:
        return Result(False, "no fight happened", 0.0)
    t_hit = min(e.get("t", 0) for e in ev)
    snap = None
    for o in ctx.get("observations") or []:
        if o.before.get("t", 0) <= t_hit:
            snap = o.before if o.after.get("t", 0) > t_hit else o.after
    snap = snap or ctx.get("probe0") or {}
    have = []
    for opt in a.get("any") or []:
        if "tag" in opt and opt["tag"] in (snap.get("tags") or []):
            have.append(opt)
        elif "enchant_type" in opt and opt["enchant_type"] in ((snap.get("held") or {}).get("effects") or []):
            have.append(opt)
        elif "item" in opt and _inv(snap).get(opt["item"], 0) >= int(opt.get("at_least", 1)):
            have.append(opt)
    return Result(bool(have), f"prepared: {have or 'nothing'} before the first hit", 1.0 if have else 0.0)


def _disengaged(a, state, ctx, cat):
    """He left the fight (distance > aggro_m), recovered (health or a vital rose), and, if asked, re-engaged."""
    target = a.get("target")
    obs = ctx.get("observations") or []
    stage, t_left = 0, None
    for o in obs:
        cr = {c["id"]: c for c in o.after.get("creatures") or []}
        if stage == 0 and target in cr:
            d = math.dist(o.after.get("position") or [0, 0, 0], cr[target].get("position") or [0, 0, 0])
            if d > float(a.get("aggro_m", 15)):
                stage, t_left = 1, o.t1
        elif stage == 1:
            rose = (o.after.get("health", 0) > o.before.get("health", 0)) or any(
                (o.after.get("vitals") or {}).get(k, 0) > (o.before.get("vitals") or {}).get(k, 0) for k in ("sustenance", "hydration"))
            if rose:
                stage = 2
        elif stage == 2 and o.tool == "attack" and (o.args or {}).get("target") == target:
            stage = 3
    need = 3 if a.get("reengaged", True) else 2
    return Result(stage >= need, ["fought", "disengaged", "recovered", "re-engaged"][min(stage, 3)], stage / need)


def _station_used(a, state, ctx, cat):
    ev = _ref(ctx, "craft")
    if ev is None:
        return Result(None, "no referee craft events", 0.0, ["referee:craft"])
    ok = [e for e in ev if (not a.get("recipe") or e.get("recipe") == a["recipe"])
          and (not a.get("station_kind") or e.get("station_kind") == a["station_kind"])]
    return Result(bool(ok), f"{len(ok)} craft(s) of {a.get('recipe') or 'any recipe'} at {a.get('station_kind') or 'any station'}",
                  1.0 if ok else 0.0)


def _xp_gained(a, state, ctx, cat):
    """XP of one skill rose by at least `at_least` between the first and last HARNESS probe (M3, every_skill)."""
    p0, p1 = (ctx.get("probe0") or {}).get("skills"), (ctx.get("probe1") or {}).get("skills")
    if not isinstance(p0, dict) or not isinstance(p1, dict):
        return Result(None, "skills not probed", 0.0, ["probe.skills"])
    key = next((k for k in p1 if k.lower() == str(a["skill"]).lower()), None)
    if key is None or (p1[key] or {}).get("xp") is None or (p0.get(key) or {}).get("xp") is None:
        return Result(None, f"no XP reading for {a['skill']}", 0.0, [f"probe.skills.{a['skill']}.xp"])
    d = float(p1[key]["xp"]) - float(p0[key]["xp"])
    want = float(a.get("at_least", 1))
    return Result(d >= want, f"{a['skill']} +{d:g} xp (want {want:g})", P._ratio(d, want), measures={f"xp:{key}": float(p1[key]["xp"])})


def _casts(a, state, ctx, cat):
    """At least n verified casts of the spell (probe: exact runes + a cooldown change; no sensor mismatch)."""
    rec = cast_record(a["spell"], ctx)
    for c in rec["casts"]:
        if c["mismatch"]:
            ctx.setdefault("mismatches", []).append({"leaf": "casts", "spell": a["spell"], "why": c["mismatch"]})
            return Result(False, f"sensor_mismatch ({c['mismatch']})", 0.0)
    n = sum(1 for c in rec["casts"] if c["runes"] and c["cd"])
    want = int(a.get("at_least", 1))
    return Result(n >= want, f"{rec['spell'].get('name') or a['spell']}: {n}/{want} verified casts", P._ratio(n, want))


def _need(*keys: str, any_of: bool = False):
    """A validator: the leaf's required argument(s) must be present (an empty leaf is a mistake, not 'anything')."""
    def check(a: dict, items) -> dict:
        have = [k for k in keys if a.get(k) not in (None, "", [], {})]
        if (any_of and not have) or (not any_of and len(have) < len(keys)):
            raise PredicateError(f"needs {' or '.join(keys) if any_of else ', '.join(keys)}")
        return dict(a)
    return check


LEAVES = {
    "casts": (_casts, _validate_spell),
    "xp_gained": (_xp_gained, _need("skill")),
    "spell_effect": (_spell_effect, _validate_spell),
    "purpose": (_purpose, _validate_purpose),
    "no_event": (_no_event, _need("kind")),
    "damage_type_dealt": (_damage_type_dealt, _need("types")),
    "defended": (_defended, _need("kind")),
    "hit_rate": (_hit_rate, _need("min_pct")),
    "teleports": (_teleported, _need("at_least")),
    "trips": (_trips, _need("deposits_at_least")),
    "delivered": (_delivered, _validate_items),
    "prepared": (_prepared, _need("any")),
    "disengaged": (_disengaged, _need("target")),
    "station_used": (_station_used, _need("recipe", "station_kind", any_of=True)),
}


def register() -> None:
    """Idempotent: add the benchmark leaves to brain/predicates.LEAVES."""
    for name, (fn, val) in LEAVES.items():
        if name not in P.LEAVES:
            P.register(name, fn, val)


register()

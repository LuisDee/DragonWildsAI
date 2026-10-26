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
UNOBSERVABLE = frozenset({"world_module", "needs_live_observation"})
TRAVEL_MAX_S = 15.0  # a travel/dash displacement must happen within the cast call (with the cast animation)
TELEPORT_MIN_M = 300.0


@lru_cache(maxsize=2)
def default_spells() -> dict:
    p = ROOT / "data" / "spell_effects.json"
    spells = json.loads(p.read_text(encoding="utf-8")).get("spells") or {} if p.exists() else {}
    return with_hypotheses(spells)


def with_hypotheses(spells: dict, path: Path | None = None) -> dict:
    """Merge evals/bench/spell_observables.json (dump-derived HYPOTHESES, confidence "hypothesis") into the proof of
    each spell whose proof has no observable effect yet (only needs_live_observation / observable false). A
    hypothesis that fires is evidence; one that does not reads null, never fail (_effect)."""
    f = path or (ROOT / "evals" / "bench" / "spell_observables.json")
    try:
        hyp = json.loads(f.read_text(encoding="utf-8")).get("spells") or {}
    except (OSError, ValueError):
        return spells
    out = dict(spells)
    for sid, h in hyp.items():
        sp = out.get(sid)
        if not isinstance(sp, dict):
            continue
        proof = dict(sp.get("proof") or {})
        eff = [e for e in proof.get("effect") or [] if e.get("kind") != "needs_live_observation"]
        if any(e.get("observable") not in (False, None) for e in eff) and sid != "USD_PhaseDash":
            continue  # it already has a real proof
        add = [{**e, "confidence": e.get("confidence") or "hypothesis"} for e in h.get("effects") or []]
        proof["effect"] = eff + [e for e in add if e not in eff]
        out[sid] = {**sp, "proof": proof}
    return out


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
        return "actor:" + str(e.get("class") or e.get("class_contains"))
    if e.get("kind") == "target_effect":
        return "teffect:" + str(e.get("effect"))
    if e.get("kind") == "view_target":
        return "view:" + str(e.get("class"))
    if e.get("kind") == "spell_state":
        return "state:" + str(e.get("state"))
    if e.get("kind") == "held_item_effect":
        return "held:" + str(e.get("effect") or e.get("damage_types"))
    if e.get("kind") == "input_mode":
        return "mode:" + str(e.get("contains") or e.get("mode"))
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


def _effect(e: dict, o, target: Any, ctx: dict | None = None) -> bool | None:
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
    hyp = e.get("confidence") == "hypothesis"  # a dump-derived observable not yet seen live: absence is "can't tell"
    if k == "spell_actor":
        want, part, excl = e.get("class"), e.get("class_contains"), set(e.get("exclude") or [])

        def hit(c):
            c = str(c or "")
            return c not in excl and (c == want if want else bool(part) and part in c)
        if any(hit(x.get("class")) for x in _new(a.get("actors"), b.get("actors"))):
            return True
        # short-lived actors (projectiles): the dev referee reports each new instance; it must appear during this cast
        seen = [x for x in (ctx or {}).get("referee") or [] if x.get("kind") == "spell_actor" and hit(x.get("class"))
                and o.wall0 - 1 <= float(x.get("t", 0)) <= o.wall1 + 3]
        return True if seen else (None if hyp else False)
    if k == "target_effect":  # a status on the creature it was cast at (referee polls creature effects, v1.5)
        seen = [x for x in (ctx or {}).get("referee") or [] if x.get("kind") == "target_effect"
                and x.get("effect") == e.get("effect") and o.wall0 - 1 <= float(x.get("t", 0)) <= o.wall1 + 8]
        return True if seen else None
    if k == "phase_dash":  # the server's OnDash(bWasPhaseDash) for him inside the spell's window (referee v1.5)
        seen = [x for x in (ctx or {}).get("referee") or [] if x.get("kind") == "dash" and x.get("phase")
                and x.get("who") == "self" and float(x.get("t", 0)) >= o.wall0 - 1]
        return True if seen else (None if hyp else False)  # verified live 2026-10-26: absence now counts
    if k == "recall_return":  # beacon at `start` (setup cast), walked to `mid`; HIS cast must bring him back to the beacon
        h = (a.get("harness") or {}).get("after_cast_move")
        if not isinstance(h, dict) or not h.get("start") or not h.get("mid") or not a.get("position"):
            return None
        walked = math.dist(h["start"], h["mid"]) >= 3.0
        back = math.dist(h["start"], a["position"]) <= float(e.get("within_m", 3.0))
        if walked and back:
            return True
        # live 2026-10-26 17:28-17:40 (skills agent): the two-cast reading did not return him; the mechanic is
        # unproven, so while the proof is a hypothesis a non-return is "can't tell", never his fail
        return None if hyp else False
    if k == "view_target":  # the camera switched to the spell's view actor (probe: pc:GetViewTarget())
        if a.get("view_target") == e.get("class") and b.get("view_target") != e.get("class"):
            return True
        # Oculus leaves its view inside the cast (~3-5 s, spells L29): the dev referee polls the view actor's class
        seen = [x for x in (ctx or {}).get("referee") or [] if x.get("kind") == "spell_actor" and x.get("class") == e.get("class")
                and o.wall0 - 1 <= float(x.get("t", 0)) <= o.wall1 + 3]
        if seen:
            return True
        return None  # transient (the view returns inside the cast): absence after the cast proves nothing
    if k == "input_mode":  # generic (every spell wheel enters it): specific_effects rejects it when shared
        if "input_mode" not in a:
            return None
        want = str(e.get("contains") or e.get("mode") or "")
        if want and want in str(a.get("input_mode") or "") and want not in str(b.get("input_mode") or ""):
            return True
        return None  # transient (screens close / modes end within ~1 s): absence proves nothing
    if k == "spell_state":  # a server-visible state the spell enters (dev referee v1.4: OculusActive, PersonalInventorySpell)
        ev = [x for x in (ctx or {}).get("referee") or [] if x.get("kind") == "spell_state"]
        if not ev and "spell_state" not in ((ctx or {}).get("referee_supports") or ()):
            return None
        return any(x.get("who") == "self" and x.get("state") == e.get("state") and o.wall0 - 1 <= float(x.get("t", 0)) <= o.wall1 + 3
                   for x in ev) or None  # missed by a 250 ms poll is "can't tell", never a fail
    if k == "held_item_effect":  # the held weapon's effect data asset (probe v2: Held*Actor.*HeldEquipmentEffectInfo)
        ha, hb = a.get("held"), b.get("held") or {}
        if not isinstance(ha, dict) or "held_effects" in (a.get("gaps") or []):
            return None
        want = e.get("effect")
        if want:
            return want in (ha.get("effects") or []) and want not in (hb.get("effects") or [])
        return None
    if k == "jump_apex_gain_m":
        ba, aa = b.get("jump_apex_m"), a.get("jump_apex_m")
        return None if ba is None or aa is None else aa - ba >= float(e.get("min", 1.0))
    if k == "air_dash_m":  # the dash happens on a LATER evade inside the spell's window: a harness effect probe
        v = a.get("air_dash_m")  # (air_dash_test.lua) must have measured it; the cast's own displacement proves nothing
        return None if v is None else float(v) >= float(e.get("min", 3.0))
    if k == "moved_m":
        d = math.dist(b.get("position") or [0, 0, 0], a.get("position") or [0, 0, 0])
        ok = d >= float(e.get("min", 3.0)) and (o.t1 - o.t0) <= TRAVEL_MAX_S
        return True if ok else (None if hyp else False)
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
        vals = [(_effect(e, c["obs"], target, ctx), e) for e in good]
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


# ------------------------------------------------------------------ referee-based leaves (v2, goal-cases review 2026-10-26)
#
# Evidence rules (review C2): a leaf whose evidence the target can't produce returns None and names it in `missing`
# (a perception gap: never a pass, never a capability failure). Kills and damage count for HIM only when the referee
# attributes them (`by == "self"`, C3). Delivery is gross outflow paired with the receiver's inflow (C1), never the
# difference between his start and end bags.

PAIR_S = 5.0  # a self -item and a receiver +item within this many seconds are one hand-over


def _ref(ctx: dict, kind: str) -> list[dict] | None:
    """Referee events of a kind, or None when the target's referee doesn't produce that kind."""
    sup = ctx.get("referee_supports")
    if sup is not None and kind not in sup:
        return None
    return [e for e in ctx.get("referee") or [] if e.get("kind") == kind]


def _gap(what: str, detail: str) -> Result:
    return Result(None, detail, 0.0, [what])


def _no_event(a, state, ctx, cat):
    ev = _ref(ctx, a["kind"])
    if ev is None:
        return _gap(f"referee:{a['kind']}", f"no referee for {a['kind']} events")
    who = a.get("who")
    hits = [e for e in ev if who is None or e.get("who") == who or e.get("target") == who]
    return Result(not hits, f"{len(hits)} {a['kind']} event(s)", 1.0 if not hits else 0.0)


def _mine(ev: list[dict], target_kind_id: str | None) -> list[dict] | None:
    """His damage events on the target kind; None when the referee doesn't attribute damage (no `by`)."""
    if ev and not any("by" in e for e in ev):
        return None
    return [e for e in ev if e.get("by") == "self" and (not target_kind_id or e.get("kind_id") == target_kind_id)]


def _damage_type_dealt(a, state, ctx, cat):
    """His damage to the target kind carries the wanted damage type; with min_share, that type is at least that share
    of his damage amount to it (review L-7: one fire hit in a farm of 20 kills is not 'the right weapon')."""
    ev = _ref(ctx, "damage")
    if ev is None:
        return _gap("referee:damage", "no referee damage events")
    mine = _mine(ev, a.get("target_kind_id"))
    if mine is None:
        return _gap("referee:damage.by", "the referee does not attribute damage yet")
    if mine and not any("damage_type" in e for e in mine):
        return _gap("referee:damage.damage_type", "the referee does not report damage types yet")
    want = tuple(a.get("types") or [])
    total = sum(float(e.get("amount", 1)) for e in mine)
    typed = sum(float(e.get("amount", 1)) for e in mine if str(e.get("damage_type", "")).startswith(want))
    if not mine:
        return Result(False, "he dealt no damage to it", 0.0)
    share = typed / total if total else 0.0
    need = float(a.get("min_share", 0.0))
    ok = typed > 0 and share >= need
    return Result(ok, f"{share:.0%} of his damage was {list(want)} (want >= {need:.0%})", min(1.0, share / need) if need else float(ok))


def _defended(a, state, ctx, cat):
    """Telegraphed attacks resolved by HIS defence (review B-2): a dodge counts only as outcome 'dodged' with an ok
    direction, a parry only as 'parried'; min_rate guards against spamming (successes / telegraphed attacks)."""
    ev = _ref(ctx, "defended")
    if ev is None:
        return _gap("referee:defended", "no referee defence events")
    if ev and not any(e.get("how") for e in ev):
        return _gap("referee:defended.how", "the referee sees avoided attacks but not yet HOW (dodge/parry/block)")
    how = a["kind"]
    want_outcome = {"dodge": "dodged", "parry": "parried", "block": "blocked", "shield": "negated"}.get(how, how)
    ok = [e for e in ev if e.get("how") == how and e.get("outcome") == want_outcome
          and (a.get("against") != "telegraph" or e.get("telegraphed"))
          and (how != "dodge" or e.get("direction_ok", False))
          and (not a.get("attack_id") or e.get("attack_id") == a["attack_id"])]
    n = int(a.get("at_least", 1))
    detail = f"{len(ok)}/{n} {how}s"
    if a.get("min_rate") is not None:
        tele = _ref(ctx, "telegraph")
        if tele is None:
            return _gap("referee:telegraph", "no referee telegraph events to rate against")
        tele = [e for e in tele if e.get("target") == "self" and (not a.get("attack_id") or e.get("attack_id") == a["attack_id"])]
        rate = len(ok) / len(tele) if tele else 0.0
        detail += f", {rate:.0%} of {len(tele)} telegraphed attacks"
        return Result(len(ok) >= n and rate >= float(a["min_rate"]), detail, P._ratio(len(ok), n))
    return Result(len(ok) >= n, detail, P._ratio(len(ok), n))


def _hit_rate(a, state, ctx, cat):
    ev = _ref(ctx, "projectile")
    if ev is None:
        return _gap("referee:projectile", "no referee projectile events")
    shots = [e for e in ev if e.get("by") == "self"
             and (a.get("range_m") is None or abs(float(e.get("range_m", 0)) - float(a["range_m"])) <= 3)
             and (not a.get("target_moving") or float(e.get("target_speed", 0)) > 0.5)]
    hits = sum(1 for e in shots if e.get("hit"))
    if len(shots) < int(a.get("min_shots", 10)):
        return _gap("shots", f"only {len(shots)} shots (need {a.get('min_shots', 10)})")
    pct = 100.0 * hits / len(shots)
    return Result(pct >= float(a["min_pct"]), f"{hits}/{len(shots)} hits ({pct:.0f}%)", min(1.0, pct / float(a["min_pct"])),
                  measures={"shots": float(len(shots)), "hits": float(hits)})


def _teleported(a, state, ctx, cat):
    """Teleports by the given means. A jump that coincides with his death (respawn) never counts (review L-4)."""
    deaths = [e.get("t", 0) for e in ctx.get("referee") or [] if e.get("kind") == "death" and e.get("who") == "self"]
    ev = _ref(ctx, "teleport")
    if ev is not None:
        ev = [e for e in ev if e.get("who", "self") == "self" and not any(abs(e.get("t", 0) - d) <= 30 for d in deaths)]
        via = a.get("via")
        if via and ev and not any("via" in e for e in ev):
            return _gap("referee:teleport.via", "the referee does not say how he teleported yet")
        n = len([e for e in ev if not via or e.get("via") == via])
    else:
        if a.get("via"):
            return _gap("referee:teleport", "no referee teleport events (needed to tell how)")
        n = 0
        for o in ctx.get("observations") or []:
            d = math.dist((o.before or {}).get("position") or [0, 0, 0], (o.after or {}).get("position") or [0, 0, 0])
            if d >= TELEPORT_MIN_M and (o.t1 - o.t0) <= 60:
                n += 1
    want = int(a.get("at_least", 1))
    return Result(n >= want, f"{n}/{want} teleports", P._ratio(n, want))


def handovers(ctx: dict, items: tuple[str, ...], to: str) -> list[dict] | None:
    """His hand-overs of the items to `to`: referee item_change self -n paired (within PAIR_S) with `to` +m, counting
    min(n, m); None when the referee can't see the receiver. On targets without a referee item stream (the mock),
    per-observation probes give the same pairing: his outflow in one action vs the receiver's inflow or new ground
    items next to the receiver in that action."""
    ev = _ref(ctx, "item_change")
    if ev is not None and any(e.get("who") == to for e in ev):
        outs = [e for e in ev if e.get("who") == "self" and e.get("item") in items and e.get("delta", 0) < 0]
        ins = [dict(e) for e in ev if e.get("who") == to and e.get("item") in items and e.get("delta", 0) > 0]
        out = []
        for o in outs:
            n = -float(o["delta"])
            for i in ins:
                if n <= 0:
                    break
                if abs(i.get("t", 0) - o.get("t", 0)) <= PAIR_S and i["delta"] > 0:
                    m = min(n, float(i["delta"]))
                    i["delta"] -= m
                    n -= m
                    out.append({"t": o.get("t", 0), "count": m})
        return out
    obs = ctx.get("observations") or []
    if not any(any(p.get("name") == to for p in (o.after or {}).get("players") or []) for o in obs):
        return None
    out = []
    for o in obs:
        b, af = o.before or {}, o.after or {}
        n = sum(max(0, _inv(b).get(i, 0) - _inv(af).get(i, 0)) for i in items)
        if n <= 0:
            continue
        pb = next((p for p in b.get("players") or [] if p.get("name") == to), {})
        pa = next((p for p in af.get("players") or [] if p.get("name") == to), None)
        if pa is None:
            continue
        got = sum((pa.get("inventory") or {}).get(i, 0) - (pb.get("inventory") or {}).get(i, 0) for i in items)
        near = sum(g.get("count", 1) for g in _new(af.get("ground"), b.get("ground")) if g.get("item") in items
                   and math.dist(g.get("position") or [0, 0, 0], pa.get("position") or [0, 0, 0]) <= 3.0)
        m = min(n, max(0, got) + near)
        if m > 0:
            out.append({"t": o.t1, "count": m})
    return out


def _delivered(a, state, ctx, cat):
    """He handed the items over to the player (review C1): gross outflow paired with the receiver's inflow, so a
    'gather 50 then give 50' run (0 at start, 0 at end) passes."""
    ids = tuple(a.get("ids") or (a["item"],))
    h = handovers(ctx, ids, a.get("to"))
    if h is None:
        return _gap("receiver", f"{a.get('to')} is not observed (probe players / referee item_change)")
    n = sum(x["count"] for x in h)
    want = float(a.get("at_least", 1))
    return Result(n >= want, f"{n:g}/{want:g} {a['item']} handed to {a.get('to')}", P._ratio(n, want),
                  measures={f"delivered:{ids[0]}": float(n)})


def _trips(a, state, ctx, cat):
    """Separate delivery batches of the item to `to`, each followed by more gathering before the next (review L-2):
    a batch boundary is a rise of the item in HIS bag between two hand-overs."""
    ids = tuple(a.get("ids") or (a["item"],))
    h = handovers(ctx, ids, a.get("to"))
    if h is None:
        return _gap("receiver", f"{a.get('to')} is not observed")
    ev = _ref(ctx, "item_change")
    gains = [e.get("t", 0) for e in ev or [] if e.get("who") == "self" and e.get("item") in ids and e.get("delta", 0) > 0] \
        if ev is not None else [o.t1 for o in ctx.get("observations") or []
                                if sum(_inv(o.after).get(i, 0) - _inv(o.before).get(i, 0) for i in ids) > 0]
    batches, last = 0, None
    for x in sorted(h, key=lambda x: x["t"]):
        if last is None or any(last < g < x["t"] for g in gains):
            batches += 1
        last = x["t"]
    want = int(a.get("at_least", 2))
    return Result(batches >= want, f"{batches}/{want} delivery trips", P._ratio(batches, want))


def _validate_items(a: dict, items) -> dict:
    a = dict(a)
    if a.get("item"):
        a["ids"] = list(items.resolve(a["item"]))
    return a


def _snap_before(ctx: dict, t: float) -> dict:
    snap = ctx.get("probe0") or {}
    for o in ctx.get("observations") or []:
        if (o.before or {}).get("t", 0) <= t:
            snap = o.before if (o.after or {}).get("t", 0) > t else o.after
    return snap or {}


def _prep_option(opt: dict, snap: dict, ctx: dict) -> bool | None:
    if "tag" in opt:
        return opt["tag"] in (snap.get("tags") or [])
    if "enchant_type" in opt:
        held = snap.get("held")
        if not isinstance(held, dict) or "effects" not in held or "held_effects" in (snap.get("gaps") or []):
            return None
        return opt["enchant_type"] in held_damage_types(held.get("effects") or [], _spells(ctx))
    if "item" in opt:
        n = _inv(snap).get(opt["item"], 0)
        if opt.get("gained_since_start"):
            n -= _inv(ctx.get("probe0")).get(opt["item"], 0)
        return n >= int(opt.get("at_least", 1))
    if "items_any" in opt:  # any of several ids, e.g. healing foods
        n = sum(_inv(snap).get(i, 0) for i in opt["items_any"])
        return n >= int(opt.get("at_least", 1))
    if "predicate" in opt:
        r = P.evaluate(opt["predicate"], _snap_state(snap), ctx)
        return r.passed
    if "any_of" in opt:  # one of several preparations (e.g. a shield spell OR the right enchant)
        vals = [_prep_option(o, snap, ctx) for o in opt["any_of"]]
        return True if True in vals else (None if None in vals else False)
    return None


def held_damage_types(effects: list[str], spells: dict) -> set[str]:
    """Damage types of held-equipment effects: the effect asset names the probe reads (HEED_*) mapped through the spell
    data's held_item_effect entries; a damage-type string passes through."""
    by_effect = {e.get("effect"): e.get("damage_types") or [] for sp in spells.values()
                 for e in (sp.get("proof") or {}).get("effect") or [] if e.get("kind") == "held_item_effect"}
    out: set[str] = set()
    for x in effects:
        out.update(by_effect.get(x, [x]))
    return out


def _snap_state(snap: dict) -> dict:
    return {"inventory": _inv(snap), "position": snap.get("position"), "gear": snap.get("gear"), "skills": snap.get("skills")}


def _prepared(a, state, ctx, cat):
    """Preparation in place before the first damage involving the TARGET kind (review T-2), from options in `all`
    (each must hold) or `any` with `at_least: k` (k distinct ones). An option the probe can't observe is null."""
    ev = _ref(ctx, "damage")
    if ev is None:
        return _gap("referee:damage", "no referee damage events")
    tk = a.get("target_kind_id")
    fight = [e for e in ev if not tk or e.get("kind_id") == tk or e.get("by_kind_id") == tk]
    if not fight:
        return Result(False, f"no fight with {tk or 'anything'} happened", 0.0)
    snap = _snap_before(ctx, min(e.get("t", 0) for e in fight))
    opts = a.get("all") or a.get("any") or []
    vals = [_prep_option(o, snap, ctx) for o in opts]
    held = sum(v is True for v in vals)
    if a.get("all"):
        if False in vals:
            return Result(False, f"prepared {held}/{len(opts)} before the fight", held / len(opts))
        if None in vals:
            return _gap("probe:prep", f"{vals.count(None)} preparation(s) not observable yet")
        return Result(True, f"prepared {held}/{len(opts)} before the fight", 1.0)
    k = int(a.get("at_least", 1))
    if held >= k:
        return Result(True, f"{held} of {len(opts)} preparations before the fight (want {k})", 1.0)
    if held + vals.count(None) >= k:
        return _gap("probe:prep", f"{held} observed, {vals.count(None)} not observable (want {k})")
    return Result(False, f"{held} of {len(opts)} preparations before the fight (want {k})", held / k)


def _disengaged(a, state, ctx, cat):
    """He left the fight beyond aggro range, ATE (referee: one of the food items left his bag), and then dealt damage
    again (referee damage by self) - review B-4. Needs creatures in the probe and attributed referee damage."""
    obs = ctx.get("observations") or []
    if not any("creatures" in (o.after or {}) for o in obs):
        return _gap("probe:creatures", "creature positions are not probed yet")
    items = _ref(ctx, "item_change")
    dmg = _ref(ctx, "damage")
    if items is None or dmg is None:
        return _gap("referee:item_change/damage", "no referee item or damage events")
    mine = _mine(dmg, a.get("target_kind_id"))
    if mine is None:
        return _gap("referee:damage.by", "the referee does not attribute damage yet")
    tk = a.get("target_kind_id")
    t_left = None
    for o in obs:
        cr = [c for c in (o.after or {}).get("creatures") or [] if not tk or c.get("kind_id") == tk]
        if cr and all(math.dist((o.after or {}).get("position") or [0, 0, 0], c.get("position") or [0, 0, 0]) > float(a.get("aggro_m", 15))
                      for c in cr if c.get("alive", True)):
            if any(e.get("t", 0) < o.t1 for e in mine):  # only after the fight began
                t_left = o.t1
                break
    if t_left is None:
        return Result(False, "fought but never got clear of them", 0.33)
    foods = set(a.get("food") or [])
    ate = [e for e in items if e.get("who") == "self" and e.get("delta", 0) < 0 and (not foods or e.get("item") in foods)
           and e.get("t", 0) >= t_left]
    if not ate:
        return Result(False, "got clear but did not eat", 0.5)
    if not a.get("reengaged", True):
        return Result(True, "disengaged and ate", 1.0)
    back = [e for e in mine if e.get("t", 0) > min(x.get("t", 0) for x in ate)]
    return Result(bool(back), "disengaged, ate" + (", re-engaged" if back else ", did not re-engage"), 1.0 if back else 0.75)


def _station_used(a, state, ctx, cat):
    ev = _ref(ctx, "craft")
    if ev is None:
        return _gap("referee:craft", "no referee craft events")
    ok = [e for e in ev if (not a.get("recipe") or e.get("recipe") == a["recipe"])
          and (not a.get("station_kind") or e.get("station_kind") == a["station_kind"])]
    return Result(bool(ok), f"{len(ok)} craft(s) of {a.get('recipe') or 'any recipe'} at {a.get('station_kind') or 'any station'}",
                  1.0 if ok else 0.0)


def _gained_at(a, state, ctx, cat):
    """Items gained while he stood within `within_m` of a place (review L-13: farm AT the plots, not anywhere then walk
    back). Counted per observation from the harness probes: his inventory rise in an action whose end position is
    within the radius."""
    pos = (ctx.get("places") or {}).get(a["place"]) if a.get("place") else a.get("position")
    if isinstance(pos, dict):
        pos = pos.get("position")
    if not pos:
        return _gap(f"place:{a.get('place')}", f"no known position for {a.get('place')}")
    ids = tuple(a.get("ids") or (a["item"],))
    n = 0.0
    for o in ctx.get("observations") or []:
        here = (o.after or {}).get("position")
        if here and math.dist(here[:2], pos[:2]) <= float(a.get("within_m", 15)):
            n += max(0, sum(_inv(o.after).get(i, 0) - _inv(o.before).get(i, 0) for i in ids))
    want = float(a.get("at_least", 1))
    return Result(n >= want, f"{n:g}/{want:g} {a['item']} gained at {a.get('place')}", P._ratio(n, want))


def _xp_top(a, state, ctx, cat):
    """The target skill had the largest XP gain relative to the XP its level needs (review M-1: under an open
    'level up' task, incidental XP from training something else can't pass). Relative gain = XP gained / (1 + level)."""
    p0, p1 = (ctx.get("probe0") or {}).get("skills"), (ctx.get("probe1") or {}).get("skills")
    if not isinstance(p0, dict) or not isinstance(p1, dict):
        return _gap("probe:skills", "skills not probed")
    rel = {}
    for k, v in p1.items():
        b = p0.get(k) or {}
        if v.get("xp") is None or b.get("xp") is None:
            continue
        rel[k] = (float(v["xp"]) - float(b["xp"])) / (1.0 + float(b.get("level") or 1))
    key = next((k for k in rel if k.lower() == str(a["skill"]).lower()), None)
    if key is None:
        return _gap(f"probe:skills.{a['skill']}", f"no XP reading for {a['skill']}")
    top = max(rel, key=rel.get) if rel else None
    ok = rel[key] > 0 and top == key
    return Result(ok, f"{a['skill']} relative gain {rel[key]:.1f}; top is {top}", 1.0 if ok else 0.0)


def _solo(a, state, ctx, cat):
    """Every damage event on the target kind was his (review V-3: no help from a harness body, NPC or pet)."""
    ev = _ref(ctx, "damage")
    if ev is None:
        return _gap("referee:damage", "no referee damage events")
    on = [e for e in ev if e.get("kind_id") == a["target_kind_id"]]
    if on and not any("by" in e for e in on):
        return _gap("referee:damage.by", "the referee does not attribute damage yet")
    others = [e for e in on if e.get("by") != "self"]
    return Result(bool(on) and not others, f"{len(on) - len(others)}/{len(on)} hits on it were his", 1.0 if on and not others else 0.0)


def _deposited(a, state, ctx, cat):
    """Items HE moved into a container (referee container_change by self from his inventory); `into: own` = a container
    built during the case (not there at referee start); trips_at_least = deposit batches separated by gathering
    (his bag gaining the items again between batches). Long task mining_run_home_chest (Luis 2026-10-26)."""
    ev = _ref(ctx, "container_change")
    if ev is None:
        return _gap("referee:container_change", "no referee container events")
    ids = set(a.get("ids") or []) or None
    mine = [e for e in ev if e.get("by") == "self" and e.get("from_player", True)
            and (a.get("into") != "own" or e.get("new_since_start"))
            and (ids is None or e.get("item") in ids)]
    n = sum(float(e.get("count") or 0) for e in mine)
    want = float(a.get("at_least", 1))
    detail = f"{n:g}/{want:g} deposited into {'his own' if a.get('into') == 'own' else 'a'} container"
    if a.get("trips_at_least"):
        items = _ref(ctx, "item_change") or []
        gains = [e.get("t", 0) for e in items if e.get("who") == "self" and e.get("delta", 0) > 0 and (ids is None or e.get("item") in ids)]
        trips, last = 0, None
        for e in sorted(mine, key=lambda e: e.get("t", 0)):
            if last is None or any(last < g < e.get("t", 0) for g in gains):
                trips += 1
            last = e.get("t", 0)
        detail += f", {trips} trip(s)"
        return Result(n >= want and trips >= int(a["trips_at_least"]), detail, P._ratio(n, want))
    return Result(n >= want, detail, P._ratio(n, want))


def _crafted(a, state, ctx, cat):
    """He crafted it himself (review: found or given items don't count): a referee craft event by self for the recipe,
    or (targets without craft events) a 'craft' tool observation in which the item entered his bag."""
    ev = _ref(ctx, "craft")
    ids = set(a.get("ids") or [])
    roles = set(a.get("roles") or [])
    if roles:  # any item of these catalog roles (e.g. gear: armour/weapon/shield/tool)
        ids |= {k for k, v in _items_catalog().items() if v.get("role") in roles}
    if ev is not None:
        mine = [e for e in ev if e.get("by") == "self" and (not a.get("recipe") or e.get("recipe") == a["recipe"])]
        if ids and mine and not a.get("recipe"):  # recipe -> output ids from the catalog
            mine = [e for e in mine if set(recipe_outputs(e.get("recipe"))) & ids]
        n = sum(int(e.get("count") or 1) for e in mine)
    else:
        n = 0
        for o in ctx.get("observations") or []:
            if o.tool == "craft":
                n += sum(max(0, _inv(o.after).get(i, 0) - _inv(o.before).get(i, 0)) for i in ids)
    want = int(a.get("at_least", 1))
    return Result(n >= want, f"{n}/{want} crafted by him", P._ratio(n, want))


@lru_cache(maxsize=1)
def _items_catalog() -> dict:
    f = sorted((ROOT / "data").glob("items_*.json"))
    return json.loads(f[-1].read_text(encoding="utf-8")).get("items") or {} if f else {}


@lru_cache(maxsize=1)
def _recipes() -> dict:
    f = sorted((ROOT / "data").glob("recipes_*.json"))
    return json.loads(f[-1].read_text(encoding="utf-8")).get("recipes") or {} if f else {}


def recipe_outputs(recipe_id: str | None) -> list[str]:
    rc = _recipes().get(recipe_id or "") or {}
    return [o.get("item") for o in rc.get("outputs") or []]


def _event_count(kind: str):
    def leaf(a, state, ctx, cat):
        ev = _ref(ctx, kind)
        if ev is None:
            return _gap(f"referee:{kind}", f"no referee {kind} events")
        mine = [e for e in ev if e.get("by") == "self" and not e.get("ghost")]
        want = int(a.get("at_least", 1))
        return Result(len(mine) >= want, f"{len(mine)}/{want} {kind} by him", P._ratio(len(mine), want))
    return leaf


# The evidence each leaf needs (review C2): a case's needs come from its predicates, so goal_check can say
# "blocked on referee:deposit" instead of reporting a capability failure.
EVIDENCE = {
    "spell_effect": ["probe:cooldowns", "probe:inventory"], "casts": ["probe:cooldowns", "probe:inventory"],
    "purpose": ["probe:cooldowns"], "xp_gained": ["probe:skills"],
    "no_event": ["referee:<kind>"], "damage_type_dealt": ["referee:damage.by", "referee:damage.damage_type"],
    "defended": ["referee:defended"], "hit_rate": ["referee:projectile"], "teleports": ["referee:teleport.via"],
    "trips": ["referee:item_change(receiver)"], "delivered": ["referee:item_change(receiver)"],
    "prepared": ["referee:damage", "probe:held_effects"], "disengaged": ["probe:creatures", "referee:damage.by"],
    "station_used": ["referee:craft"], "gained_at": ["probe:inventory", "probe:position"], "xp_top": ["probe:skills"],
    "solo": ["referee:damage.by"], "deposited": ["referee:container_change"], "crafted": ["referee:craft"],
    "built": ["referee:built", "body:build_tool"], "planted": ["referee:planted", "body:build_tool"],
    "harvested": ["referee:harvested"], "killed": ["referee:death.by"], "quest": ["probe:quests"],
    "gear_better": ["probe:gear"], "equipped": ["probe:gear"], "bag": ["probe:bag"],
}


def required_evidence(p: dict) -> list[str]:
    out: list[str] = []
    for k, a in P.leaves(p):
        for e in EVIDENCE.get(k, []):
            e = e.replace("<kind>", str((a or {}).get("kind", "?")))
            if e not in out:
                out.append(e)
    return out


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
    "deposited": (_deposited, lambda a, items: _validate_items(a, items) if not a.get("items") else
                  {**a, "ids": sorted({i for x in a["items"] for i in items.resolve(x)})}),
    "crafted": (_crafted, lambda a, items: _validate_items(_need("item", "recipe", "roles", any_of=True)(a, items), items)),
    "built": (_event_count("built"), None),
    "planted": (_event_count("planted"), None),
    "harvested": (_event_count("harvested"), None),
    "gained_at": (_gained_at, lambda a, items: _validate_items(_need("item", "at_least")(a, items), items)),
    "xp_top": (_xp_top, _need("skill")),
    "solo": (_solo, _need("target_kind_id")),
    "casts": (_casts, _validate_spell),
    "xp_gained": (_xp_gained, _need("skill")),
    "spell_effect": (_spell_effect, _validate_spell),
    "purpose": (_purpose, _validate_purpose),
    "no_event": (_no_event, _need("kind")),
    "damage_type_dealt": (_damage_type_dealt, _need("types")),
    "defended": (_defended, _need("kind")),
    "hit_rate": (_hit_rate, _need("min_pct")),
    "teleports": (_teleported, _need("at_least")),
    "trips": (_trips, lambda a, items: _validate_items(_need("item", "to")(a, items), items)),
    "delivered": (_delivered, lambda a, items: _validate_items(_need("item", "to")(a, items), items)),
    "prepared": (_prepared, _need("all", "any", any_of=True)),
    "disengaged": (_disengaged, _need("target_kind_id")),
    "station_used": (_station_used, _need("recipe", "station_kind", any_of=True)),
}


def register() -> None:
    """Idempotent: add the benchmark leaves to brain/predicates.LEAVES."""
    for name, (fn, val) in LEAVES.items():
        if name not in P.LEAVES:
            P.register(name, fn, val)


register()

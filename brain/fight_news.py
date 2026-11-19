"""Fight news while a body call runs, and the truth about a call his death cut short (grave study 2026-11-18).

He never saw his deaths coming: the body's reflex fought or fled alone while explore, gather or go_to ran, and the
fight's events waited in the brain until the call returned, 1.5-210 s late (6 of 12 deaths; run 20261118-010135:
combat_started at 458.9 s reached the brain at 669.3 s). Every reflex flee failed (mobs 6.0 m/s, he 5.8).

What this module gives the agent (facts only; the model decides to fight, flee, eat, stop or carry on):
- ``interrupt_reason(event)``: the bridge's interrupt check for body events. A reflex fight starting on him, a flee
  that failed, or hostiles in sight the body's own odds don't rate a likely win (``threat_seen``, combat.lua) detach
  the wait the way a player's line does (``still_running``): the body keeps going, the model gets a turn at once.
- ``fight_situation``: the body situation that turn shows: who, its level (the game's, else data/bestiary.json), the
  pack, the reflex's odds and what it is doing, how a flee went, his HP, food or drink carried, the call still running.
- ``died_during``: a call that failed while he died says so ("I died during this go_to, killed by Giant Rat ..."),
  never ``nothing_in_range`` or ``interrupted (stopped)`` (d1, d2, d11 of the study).

Precedents: Mindcraft's modes (self_defense "Interrupts all actions"; after the mode the model is auto-prompted
"Your previous action ... was interrupted by <mode>. Your behavior log: ... Respond accordingly.",
github.com/kolbytn/mindcraft src/agent/modes.js). Here the model is prompted when the fight STARTS, because the
deaths happened inside the fight. Voyager (arXiv 2305.16291) feeds events back only after the program ran, which is
the late-news shape this replaces.
"""
from __future__ import annotations

from .interface import Activity, Event

FIGHT_KINDS = ("combat_started", "flee_failed")  # a fight on him (hit, or a hostile on him in reach); a lost race
THREAT_KIND = "threat_seen"  # combat.lua threat_watch: hostiles in sight, not a likely win (pack counted)
SHOWN_KINDS = (*FIGHT_KINDS, "flee_started", THREAT_KIND)  # what the fight turn shows of the events it found
DEATH_SLACK_S = 1.5  # a death this long before the call started still counts (the death row's own timing)
NOT_RUN = frozenset({"invalid_args", "unknown_tool", "unknown_skill", "not_implemented", "busy", "still_running",
                     "state_unavailable", "unsafe"})  # refused before the body moved: no death to look for
ODDS_WORDS = {"likely_win": "likely win", "likely_lose": "likely lose", "too_strong": "much stronger",
              "outnumbered": "outnumbered", "boss": "a boss", "uncertain": "could go either way", "unknown": "unknown"}
BY_WORDS = {"chat": "when the player spoke", "fight": "when a fight started on you",
            "threat": "when hostiles your body doesn't rate a likely win came into sight"}


def interrupt_reason(event: Event) -> str | None:
    """"fight" / "threat" for a body event that must give the model the floor during a body call, else None."""
    if not isinstance(event, Activity) or event.by != "reflex":
        return None
    if event.kind in FIGHT_KINDS:
        return "fight"
    if event.kind == THREAT_KIND:
        return "threat"
    return None


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def level_words(name: str | None, game_pl=None) -> str | None:
    """'PL 2 (the game)' when the body read it, else the wiki's levels: 'PL 2-8 (wiki: 120-570 HP)'."""
    if _num(game_pl) is not None:
        return f"PL {_num(game_pl):g} (the game)"
    if not name:
        return None
    from .plan_sources import _creature  # data/bestiary.json (lazy: plan_sources reads data files)
    cr = _creature(str(name))
    rows = [v for v in cr.get("variants") or [] if isinstance(v, dict)]
    pls = sorted({int(v["power_level"]) for v in rows if str(v.get("power_level", "")).isdigit()})
    hps = sorted({int(v["health"]) for v in rows if str(v.get("health", "")).isdigit()})
    if not pls:
        return None
    pl = f"PL {pls[0]}" if len(pls) == 1 else f"PL {pls[0]}-{pls[-1]}"
    hp = (f"{hps[0]} HP" if len(hps) == 1 else f"{hps[0]}-{hps[-1]} HP") if hps else ""
    weak = ", ".join(str(w) for w in cr.get("weak") or [] if w and w != "None")
    return f"{pl} (wiki{': ' + hp if hp else ''}{'; weak to ' + weak if weak else ''})"


def _odds(f: dict) -> str | None:
    """'likely lose (with Giant Rat x2; kills you in 40-190 s; you it in 270 s to over 10 min) (the body's estimate,
    a range from your real fights)'. The bands (est_die, est_kill) and the pack come from combat.assess (2026-11-18,
    calibrated on his fights of 16-18 Nov); a creature with no damage data is said so, never given a time to die."""
    v = f.get("verdict")
    if not v:
        return None
    if f.get("unknown"):
        die = str(f["unknown"])
    elif f.get("est_die"):
        die = f"kills you in {f['est_die']}"
    else:
        die = f"kills you ~{_num(f['est_s_to_die']):g} s" if _num(f.get("est_s_to_die")) is not None else ""
    kill = (f"you it in {f['est_kill']}" if f.get("est_kill") else
            f"you it ~{_num(f['est_s_to_kill']):g} s" if _num(f.get("est_s_to_kill")) is not None else "")
    # the hostiles the odds counted: threat_seen's fight group, or combat_started's (it carries the reflex's decision)
    group = f.get("fight_hostiles") or (f.get("hostiles") if f.get("decision") else None)
    n = _num(f.get("fight_pack")) or (_num(f.get("pack")) if f.get("decision") else None)
    t = [x for x in ((f"with {group}" if group and n and n > 1 else ""), die, kill) if x]
    banded = bool(f.get("est_die") or f.get("est_kill"))
    return (ODDS_WORDS.get(str(v), str(v)) + (f" ({'; '.join(t)})" if t else "")
            + (" (the body's estimate, a range from your real fights)" if banded else " (the body's estimate)"))


def fight_situation(events: list[Activity], state: dict, running: dict | None, by: str) -> dict:
    """The body situation of a fight turn. ``events``: the body's activity found at the interrupt (oldest first);
    ``running``: {tool, args, ran_s} of the call still running in the body; ``by``: "fight" or "threat"."""
    rows = [e for e in events if e.kind in SHOWN_KINDS and e.by == "reflex"]
    start = next((e for e in reversed(rows) if e.kind == "combat_started"), None)
    threat = next((e for e in reversed(rows) if e.kind == THREAT_KIND), None)
    flee_failed = next((e for e in reversed(rows) if e.kind == "flee_failed"), None)
    main = start or threat or flee_failed
    f = main.fields() if main else {}
    who = f.get("target") or f.get("from")
    out: dict = {"type": "fight", "by": by}
    if by == "threat":
        out["about"] = ("hostiles your body doesn't rate a likely win are in sight while your call runs; nothing has "
                        "attacked you yet")
    else:
        out["about"] = "a fight started on you while your call runs; your body's combat reflex has your legs now"
    if who:
        out["who"] = str(who)
    if lv := level_words(who, f.get("target_pl")):
        out["level"] = lv
    if threat is not None:
        tf = threat.fields()
        if tf.get("hostiles"):
            out["hostiles_in_sight"] = f"{tf['hostiles']} ({tf.get('pack')} within 40 m)"
        if _num(tf.get("distance_m")) is not None:
            out["nearest_m"] = tf["distance_m"]
        if tf.get("again"):  # combat.lua tells a group once; again only when it changed (2026-11-19)
            out["told_again_because"] = str(tf["again"])
    elif _num(f.get("pack")) is not None:
        out["pack"] = f["pack"]
    if odds := _odds(f):
        out["odds"] = odds
    if start is not None:
        sf = start.fields()
        out["reflex"] = f"{sf.get('decision') or '?'} ({sf.get('because') or sf.get('why') or '?'})" + (
            f", with {sf['weapon']}" if sf.get("weapon") else "")
        out["why_it_started"] = {"attacking_me": "it attacked you", "attacked_me": "it hit you",
                                 "hostile_near": "a hostile came at you in reach"}.get(str(sf.get("why")), sf.get("why"))
    if flee_failed is not None:
        ff = flee_failed.fields()
        out["flee"] = f"failed: {ff.get('why') or '?'}" + (f"; now {ff['next']}" if ff.get("next") else "")
    hp, mx = _num(state.get("health")), _num(state.get("max_health"))
    if hp is None:
        hp, mx = _num(f.get("hp")), _num(f.get("max_hp"))
    if hp is not None:
        out["your_hp"] = f"{hp:g}/{mx:g}" if mx else f"{hp:g}"
    from .broker import facts  # lazy: broker imports situation
    fx = facts(state) if isinstance(state.get("inventory_items"), list) else {}  # unread is not "none carried"
    if fx:
        out["carried"] = {"food": bool(fx.get("has_food")), "drink": bool(fx.get("has_drink"))}
    if running:
        out["still_running"] = (f"{running.get('tool')} {running.get('args') or {}} for {running.get('ran_s', 0):.0f} s: "
                                "your body is still doing it. The same call again keeps it going; another action "
                                "or stop replaces it")
    return out


def died_during(state: dict, elapsed_s: float) -> dict | None:
    """He died while this call ran (get_state.last_death, the game's own death row): {cause, ago_s, respawned}.
    ``elapsed_s``: from the call's start to this state read. None when he did not (or nothing says so)."""
    d = state.get("last_death") if isinstance(state, dict) and isinstance(state.get("last_death"), dict) else None
    if not d or _num(d.get("ago_s")) is None or d["ago_s"] > elapsed_s + DEATH_SLACK_S:
        return None
    from .situation import death_cause  # lazy: situation is heavy
    return {"cause": death_cause(d), "ago_s": int(d["ago_s"]), "respawned": bool(d.get("respawned"))}


def death_detail(tool: str, died: dict, reason: str | None, detail: str | None) -> str:
    """'I died during this go_to (killed by Giant Rat; at [414, 1757]), 2 s ago, not respawned yet. What the go_to
    itself reported: interrupted: the move ended without arriving (stopped).'"""
    when = f"{died['ago_s']} s ago, " + ("respawned since" if died.get("respawned") else "not respawned yet")
    own = f"{reason}: {detail}" if detail else str(reason)
    return f"I died during this {tool} ({died['cause']}), {when}. What the {tool} itself reported: {own}."

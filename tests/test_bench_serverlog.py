"""evals/bench/serverlog.py: server-authoritative telegraphs and dodges from the dev server log (lines copied from
RSDragonwilds.log, 2026-10-25 23:39-23:40 UTC, build 26161880)."""
from __future__ import annotations

from evals.bench import serverlog as sl
from evals.bench.leaves import _defended  # noqa: F401  (registered leaf; evaluated through P below)
from brain import predicates as P

ME = "BP_PlayerCharacter_C_2147453683"
LINES = [
    "[2026.10.25-23.39.57:522][ 75]EvadeAttack: Verbose: [DedicatedServer] TryPerformAttack() : [3116.557498, 93075] "
    "BP_AI_Kebbit_Character_02_C_2147450642 starting attack on authority against player BP_PlayerCharacter_C_2147453683 with id 8",
    "[2026.10.25-23.39.58:820][114]EvadeAttack: Verbose: [DedicatedServer] PredictPointDamage() : [3117.857164, 93114] "
    "BP_PlayerCharacter_C_2147453683 will receive 7.000000 damage at 3117.907715 from BP_AI_Kebbit_Character_02_C_2147450642.",
    "[2026.10.25-23.40.00:059][151]EvadeAttack: Verbose: [DedicatedServer] TryPerformAttack() : [3119.091613, 93151] "
    "BP_AI_Kebbit_Character_02_C_2147450642 starting attack on authority against player BP_PlayerCharacter_C_2147453683 with id 9",
    "[2026.10.25-23.40.01:257][187]DomNetActIntIds: AUTH : Action Accepted : START : Evade - GameId[2] NetId[3] Ack[-1]",
    "[2026.10.25-23.40.01:358][190]EvadeAttack: Verbose: [DedicatedServer] PredictPointDamage() : [3120.394386, 93190] "
    "BP_PlayerCharacter_C_2147453683 evaded 0.000000 damage at 3120.441650 from BP_AI_Kebbit_Character_02_C_2147450642.",
    "[2026.10.25-23.40.04:528][285]EvadeAttack: Verbose: [DedicatedServer] TryPerformAttack() : [3123.564108, 93285] "
    "BP_AI_Wolf_C_1 starting attack on authority against player BP_PlayerCharacter_C_99 with id 1",
]


def test_parses_telegraphs_dodges_and_hits_for_him_only():
    r = sl.ServerLogReferee(pawn=ME)
    ev = r.parse(LINES)
    kinds = [(e["kind"], e.get("target") or e.get("how")) for e in ev]
    assert kinds == [("telegraph", "self"), ("hit_taken", None), ("telegraph", "self"), ("defended", "dodge"),
                     ("telegraph", "BP_PlayerCharacter_C")]
    dodge = ev[3]
    assert dodge["outcome"] == "dodged" and dodge["telegraphed"] and dodge["attack_id"] == "9"
    assert dodge["attacker_kind"] == "BP_AI_Kebbit_Character_02_C"
    assert abs(dodge["t"] - 1792971601.358) < 1e-3  # UTC log time -> epoch


def test_the_dodge_leaf_passes_on_server_log_evidence():
    ev = sl.ServerLogReferee(pawn=ME).parse(LINES)
    pred = {"defended": {"kind": "dodge", "against": "telegraph", "at_least": 1, "min_rate": 0.5}}
    res = P.evaluate(pred, {}, {"referee": ev, "observations": []})
    assert res.passed is True, res.detail  # 1 dodge of 2 telegraphed attacks at him = 50%


def test_merge_replaces_hook_telegraphs_and_dodges_but_keeps_parries():
    hooks = [{"kind": "telegraph", "t": 1, "target": "self"}, {"kind": "defended", "t": 2, "how": None, "outcome": "avoided"},
             {"kind": "defended", "t": 3, "how": "parry", "outcome": "parried"}, {"kind": "damage", "t": 4, "by": "self"}]
    log = [{"kind": "telegraph", "t": 1.5, "target": "self", "source": "server_log"}]
    out = sl.merge(hooks, log, True)
    assert [(e["kind"], e.get("how")) for e in out] == [("telegraph", None), ("defended", "parry"), ("damage", None)]
    assert out[0]["source"] == "server_log"
    assert sl.merge(hooks, log, False) == hooks  # no pawn name / no log: the hooks stay the only source


def test_tail_reads_only_whole_new_lines_and_survives_rotation(tmp_path):
    f = tmp_path / "RSDragonwilds.log"
    f.write_text("old line\n", encoding="utf-8")
    r = sl.ServerLogReferee(path=f)
    r.start(ME)
    with open(f, "a", encoding="utf-8") as h:
        h.write(LINES[0] + "\n" + LINES[4][:40])  # a half-written line waits
    assert [e["kind"] for e in r.read()] == ["telegraph"]
    with open(f, "a", encoding="utf-8") as h:
        h.write(LINES[4][40:] + "\n")
    assert [e["kind"] for e in r.read()] == ["defended"]  # the half line was kept back and is now read whole
    f.write_text(LINES[2] + "\n", encoding="utf-8")  # rotated: smaller than the offset
    assert [e["kind"] for e in r.read()] == ["telegraph"]

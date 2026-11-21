"""An idle stretch after he parked an ask whose end condition is unmet carries that parked ask, as facts, in the same
idle review an open ask gets (REVIEW_IDLE_ASK_S, once per idle stretch, same rate rules).

Live L3 (brain-live-20261121-020517* and after): three of the last six trials ended 'quiet' (40 s standing) right after
he called park_request on "claude, gear up for the vault" ("I don't have the robe or leggings yet. Need a pickaxe for
rune essence and a crafting table, plus a loom for the thread."), its done_when unmet, the trial player silent. A parked
ask is not open, so _idle_ask returned None and no idle review came. Now the review carries it: the words, who asked,
who parked it how long ago with the reason, the player lines since the park, the end condition with its truth now.
Nothing tells him what to do and nothing unparks it; he decides. A park the one who asked answered or released, or one
whose end condition holds, is not carried."""
import copy

from brain import agent as A
from brain import broker as B
from brain import predicates as P
from tests.test_broker_idle_ask import ASK, _broker, _idle
from tests.test_event_hygiene import _proactive_rig, _vitals_state

VAULT = ("Zezima", "claude, gear up for the vault")
REASON = ("I don't have the robe or leggings yet. Need a pickaxe for rune essence and a crafting table, plus a loom "
          "for the thread.")
PARKED = {"parked_ask": {"words": VAULT[1], "asked_by": "Zezima", "parked_by": "you (park_request)",
                         "parked_s_ago": 5, "park_reason": REASON, "player_lines_since_park": [],
                         "done_when": {"end_condition": "Apprentice Robe equipped", "now": "not yet"}}}


# ------------------------------------------------------------------ the broker: the parked ask goes out like an open one

def test_idle_with_a_parked_ask_is_a_review_carrying_it_as_parked_ask():
    b, clock = _broker()
    clock.t += B.REVIEW_IDLE_ASK_S - 1
    assert b.review_due(open_ask=PARKED) is None  # not idle long enough
    clock.t += 2
    ev = b.review_due(open_ask=lambda: PARKED)
    assert _idle(ev) == {"what": "idle", "for_s": round(B.REVIEW_IDLE_ASK_S + 1),
                         "parked_ask": PARKED["parked_ask"], "near": []}
    assert "open_ask" not in _idle(ev)


def test_a_parked_ask_is_once_per_idle_stretch_and_goes_out_inside_the_gap_alone():
    b, clock = _broker()
    last = {"at": clock.t + B.REVIEW_IDLE_ASK_S - 10, "changes": [{"what": "endurance"}], "you_said": "can we rest?"}
    b._last_review = dict(last)
    b._change({"what": "sleep_allowed", "to": True})  # not urgent: waits out REVIEW_MIN_GAP_S
    clock.t += B.REVIEW_IDLE_ASK_S + 1
    ev = b.review_due(open_ask=PARKED)
    assert [c["what"] for c in ev["changes"]] == ["idle"] and _idle(ev)["parked_ask"] == PARKED["parked_ask"]
    assert b._last_review == last  # the gap and the history stand
    clock.t += B.REVIEW_IDLE_ASK_S * 3
    assert b.review_due(open_ask=PARKED) is None  # this stretch had its review; the sleep window still waits
    b.note_busy()
    clock.t += B.REVIEW_QUIET_AFTER_CMD_S + B.REVIEW_IDLE_ASK_S + 1
    assert _idle(b.review_due(open_ask=PARKED))["parked_ask"] == PARKED["parked_ask"]  # a new stretch


def test_an_open_ask_still_goes_out_as_open_ask():
    b, clock = _broker()
    clock.t += B.REVIEW_IDLE_ASK_S + 1
    ch = _idle(b.review_due(open_ask=ASK))
    assert ch["open_ask"] == ASK and "parked_ask" not in ch


# ------------------------------------------------------------------ the real Agent: what _idle_parked carries

def _far_rig(tmp_path):
    r = _proactive_rig(tmp_path, said="")
    r.body.state = _vitals_state(60, dist=400.0)  # the asking player out of review range
    return r


ROBE = {"vital": {"stat": "health", "below_pct": 50}}  # an end condition read on the rig's state (100 % health now)


def _parked_with_end(r, pred=ROBE, by="him"):
    """He was asked, the end condition was written at the ask, then the ask was parked (by him, his planner, code)."""
    a = r.agent
    a._ask_seen[VAULT] = (r.clock.t, copy.deepcopy(r.body.state))
    a._done_when = {"ask": VAULT, "pred": pred, "text": P.describe(pred),
                    "baseline": P.snapshot(r.body.state, t=r.clock.t)}
    a._open_request = None
    a._park(VAULT, REASON, by=by)


def _review_rows(tmp_path):
    return [l for l in (tmp_path / "logs" / "brain.jsonl").read_text(encoding="utf-8").splitlines()
            if '"kind": "situation_review"' in l]


def test_agent_idle_after_his_park_gets_a_review_carrying_the_parked_ask(tmp_path):
    r = _far_rig(tmp_path)
    r.at(10)
    _parked_with_end(r)
    r.at(10 + B.REVIEW_IDLE_ASK_S - 15).step()
    assert r.model.contexts == []
    r.at(10 + B.REVIEW_IDLE_ASK_S + 10).step()
    ch = _idle(r.model.contexts[-1]["body_event"])
    p = ch["parked_ask"]
    assert "open_ask" not in ch and ch["near"] == []
    assert p["words"] == VAULT[1] and p["asked_by"] == "Zezima" and p["park_reason"] == REASON
    assert p["parked_by"] == A.PARKED_BY_WORDS["him"] and p["parked_s_ago"] == round(B.REVIEW_IDLE_ASK_S + 10)
    assert p["asked_s_ago"] == round(B.REVIEW_IDLE_ASK_S + 10) and p["player_lines_since_park"] == []
    assert p["done_when"]["end_condition"] == P.describe(ROBE) and p["done_when"]["now"].startswith("not yet")
    assert set(p) == {"words", "asked_by", "asked_s_ago", "parked_by", "parked_s_ago", "park_reason",
                      "player_lines_since_park", "done_when"}  # facts only: no wording telling him what to do
    assert r.body.said == []  # the model chose silence; code never speaks for him
    a = r.agent
    assert a._parked["ask"] == VAULT and a._open_request is None and a.pending_goal is None  # the park stands
    rows = _review_rows(tmp_path)
    assert rows and '"what": "idle"' in rows[-1] and '"parked_ask"' in rows[-1]
    r.at(10 + B.REVIEW_IDLE_ASK_S * 4).step()
    assert len(r.model.contexts) == 1  # once per idle stretch


def test_a_park_whose_end_condition_holds_is_not_carried(tmp_path):
    r = _far_rig(tmp_path)
    r.at(10)
    _parked_with_end(r, pred={"vital": {"stat": "health", "below_pct": 101}})  # 100 %: met
    r.at(10 + B.REVIEW_IDLE_ASK_S + 10).step()
    r.at(10 + B.REVIEW_IDLE_ASK_S + 100).step()
    assert r.model.contexts == [] and r.agent._idle_ask() is None


def test_a_park_with_no_end_condition_is_not_carried(tmp_path):
    r = _far_rig(tmp_path)
    r.agent._park(VAULT, REASON)
    assert r.agent._done_when is None and r.agent._idle_ask() is None


def test_a_park_the_asker_answered_since_is_not_carried_but_other_lines_are_facts(tmp_path):
    r = _far_rig(tmp_path)
    r.at(10)
    _parked_with_end(r)
    a = r.agent
    a._last_line["Zezima"] = ("earlier line, before the park", r.clock.t - 5)
    r.at(14)
    a._last_line["Luis"] = ("anyone seen my axe?", r.clock.t)  # another player, not addressed to him
    r.at(20)
    p = a._idle_ask()["parked_ask"]
    assert p["player_lines_since_park"] == [{"by": "Luis", "words": "anyone seen my axe?", "s_ago": 6}]
    a._last_line["Zezima"] = ("leave it for now", r.clock.t)  # the one who asked spoke after the park
    assert a._idle_ask() is None


def test_an_open_ask_wins_over_the_parked_one(tmp_path):
    r = _far_rig(tmp_path)
    _parked_with_end(r)
    r.agent._open_request = ("Zezima", "claude, chop some logs")
    out = r.agent._idle_ask()
    assert out["words"] == "claude, chop some logs" and "parked_ask" not in out


def test_a_park_by_his_planner_or_the_stall_rule_says_who_parked_it(tmp_path):
    r = _far_rig(tmp_path)
    _parked_with_end(r, by="planner")
    assert r.agent._idle_ask()["parked_ask"]["parked_by"] == "your planner"
    _parked_with_end(r, by="code")
    assert r.agent._idle_ask()["parked_ask"]["parked_by"] == A.PARKED_BY_WORDS["code"]

"""An idle stretch with an open ask standing is a change worth a review, with or without a player near.

Live L3 20261120-185446 (brain-live-20261120-195434-34604, ts 1795201501): he called stop ("resting up before more
ash", half health, out of food) on "claude, gear up for the vault", its end condition not met, the trial player out
of sight. review_due only raised the idle change with a player within REVIEW_NEAR_M, the health drop was stale
(situation_change_stale), and no turn came again. Now the idle change carries the open ask as a fact (words, who
asked, the end condition with its truth now); he decides what to do with it."""
import copy

from brain import broker as B
from brain.broker import EventBroker
from tests.test_event_hygiene import _proactive_rig, _vitals_state


class Clock:
    def __init__(self, t: float = 1000.0):
        self.t = t

    def __call__(self) -> float:
        return self.t


def _state(dist: float = 400.0) -> dict:
    return {"position": [0.0, 0.0, 0.0], "players": [{"name": "Zezima", "distance": dist}],
            "health": 50.0, "max_health": 100.0}


ASK = {"words": "claude, gear up for the vault", "asked_by": "Zezima",
       "done_when": {"end_condition": "Apprentice Robe equipped", "now": "not yet: Apprentice Robe not equipped"}}


def _broker():
    clock = Clock()
    b = EventBroker(clock=clock)
    b.observe(_state())
    return b, clock


def _idle(ev: dict) -> dict:
    return next(c for c in ev["changes"] if c["what"] == "idle")


def test_idle_with_an_open_ask_and_nobody_near_is_a_review():
    b, clock = _broker()
    clock.t += B.REVIEW_IDLE_ASK_S - 1
    assert b.review_due(open_ask=ASK) is None  # not idle long enough
    clock.t += 2
    ev = b.review_due(open_ask=ASK)
    assert ev and _idle(ev) == {"what": "idle", "for_s": round(B.REVIEW_IDLE_ASK_S + 1), "open_ask": ASK, "near": []}


def test_no_open_ask_and_nobody_near_stays_quiet():
    b, clock = _broker()
    clock.t += B.REVIEW_IDLE_ASK_S + 60
    assert b.review_due(open_ask=None) is None
    assert b.review_due(open_ask=lambda: None) is None  # no ask open, or its end condition met


def test_once_per_idle_stretch_renewed_when_he_acts_again():
    b, clock = _broker()
    clock.t += B.REVIEW_IDLE_ASK_S + 1
    assert b.review_due(open_ask=ASK)
    clock.t += B.REVIEW_IDLE_ASK_S * 3
    assert b.review_due(open_ask=ASK) is None  # he chose to keep resting: not asked again this stretch
    b.note_busy()  # he acted
    clock.t += B.REVIEW_IDLE_ASK_S + 1
    assert _idle(b.review_due(open_ask=ASK))["open_ask"] == ASK


def test_busy_or_fighting_holds_it_back():
    b, clock = _broker()
    clock.t += B.REVIEW_IDLE_ASK_S + 1
    assert b.review_due(busy=True, open_ask=ASK) is None
    b.note_attacked()
    assert b.review_due(open_ask=ASK) is None
    clock.t += B.FIGHT_QUIET_S + 1
    assert b.review_due(open_ask=ASK)


def test_the_provider_is_read_only_at_the_threshold_and_not_on_every_pump():
    b, clock = _broker()
    reads = []

    def provider():
        reads.append(clock.t)
        return None  # e.g. its end condition reads met

    for _ in range(5):
        clock.t += 1
        b.review_due(open_ask=provider)
    assert reads == []  # not idle yet: the end condition is not read
    clock.t += B.REVIEW_IDLE_ASK_S
    for _ in range(5):
        b.review_due(open_ask=provider)
        clock.t += 1
    assert len(reads) == 1
    clock.t += B.REVIEW_SAMPLE_S
    b.review_due(open_ask=provider)
    assert len(reads) == 2


def test_a_waiting_idle_change_is_dropped_when_he_acts():
    """A review a minute ago: the idle change waits out REVIEW_MIN_GAP_S. He acts meanwhile: it is no longer true."""
    b, clock = _broker()
    b._last_review = {"at": clock.t + B.REVIEW_IDLE_ASK_S - 10, "changes": [], "you_said": None}
    clock.t += B.REVIEW_IDLE_ASK_S + 1
    assert b.review_due(open_ask=ASK) is None  # pending (rate limit)
    b.note_busy()
    clock.t += B.REVIEW_MIN_GAP_S + B.REVIEW_QUIET_AFTER_CMD_S + 1
    assert b.review_due(open_ask=None) is None


def test_near_player_idle_unchanged_and_carries_the_ask_too():
    b, clock = _broker()
    b.observe(_state(dist=4.0))
    clock.t += B.REVIEW_IDLE_S + 1
    assert _idle(b.review_due()) == {"what": "idle", "for_s": round(B.REVIEW_IDLE_S + 1), "near": ["Zezima"]}
    b.note_busy()
    clock.t += B.REVIEW_IDLE_S + 1
    assert _idle(b.review_due(open_ask=ASK))["open_ask"] == ASK


def test_a_provider_that_raises_is_logged_and_never_breaks_the_loop():
    rows = []

    class Log:
        def log(self, kind, **kw):
            rows.append((kind, kw))

    clock = Clock()
    b = EventBroker(log=Log(), clock=clock)
    b.observe(_state())
    clock.t += B.REVIEW_IDLE_ASK_S + 1
    assert b.review_due(open_ask=lambda: 1 / 0) is None
    assert any(k == "idle_open_ask_unread" for k, _ in rows)


# ------------------------------------------------------------------ the real Agent: its open ask reaches the model

def _far_rig(tmp_path):
    r = _proactive_rig(tmp_path, said="")
    r.body.state = _vitals_state(60, dist=400.0)  # the asking player out of review range
    return r


def test_agent_idle_with_the_open_ask_standing_gets_a_review_carrying_it(tmp_path):
    r = _far_rig(tmp_path)
    r.agent._open_request = ("Zezima", "claude, gear up for the vault")
    r.agent._ask_seen[r.agent._open_request] = (r.clock.t, copy.deepcopy(r.body.state))  # asked at the baseline
    r.at(200).step()
    assert r.model.contexts == []
    r.at(B.REVIEW_IDLE_ASK_S + 10).step()
    ev = r.model.contexts[-1]["body_event"]
    ch = _idle(ev)
    assert ch["near"] == [] and ch["open_ask"]["words"] == "claude, gear up for the vault"
    assert ch["open_ask"]["asked_by"] == "Zezima" and ch["open_ask"]["asked_s_ago"] == round(B.REVIEW_IDLE_ASK_S + 10)
    assert "done_when" not in ch["open_ask"]  # this ask has no end condition written
    assert r.body.said == []  # the model chose silence; code never speaks for him
    rows = [l for l in (tmp_path / "logs" / "brain.jsonl").read_text(encoding="utf-8").splitlines()
            if '"kind": "situation_review"' in l]
    assert rows and '"what": "idle"' in rows[-1] and '"open_ask"' in rows[-1]


def test_agent_with_no_open_ask_and_nobody_near_stays_quiet(tmp_path):
    r = _far_rig(tmp_path)
    r.at(B.REVIEW_IDLE_ASK_S + 10).step()
    r.at(B.REVIEW_IDLE_ASK_S + 100).step()
    assert r.model.contexts == []


def test_agent_idle_ask_carries_the_end_condition_and_skips_one_that_holds(tmp_path, monkeypatch):
    r = _far_rig(tmp_path)
    ask = ("Zezima", "claude, gear up for the vault")
    r.agent._open_request = ask
    held = {"v": False}

    def done_when_now(a, where, state=None):
        assert a == ask and where == "idle_review"
        r.agent._done_when = {"ask": ask, "holds": held["v"]}
        return {"end_condition": "Apprentice Robe equipped", "written": "by your planner at the request",
                "now": "yes: equipped" if held["v"] else "not yet: Apprentice Robe not equipped"}

    monkeypatch.setattr(r.agent, "_done_when_now", done_when_now)
    out = r.agent._idle_ask()
    assert out["done_when"]["now"].startswith("not yet") and out["words"] == ask[1]
    held["v"] = True
    assert r.agent._idle_ask() is None  # met: no idle review for it
    r.agent._open_request = None
    assert r.agent._idle_ask() is None

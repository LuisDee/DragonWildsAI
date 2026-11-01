"""tools/luis_emulator.py offline: triggers, the canned writer, style bands, the --confirm refusal. No model calls."""
from tools import luis_emulator as le


def state(**kw):
    st = {"t0": 0.0, "t_h": 10.0, "me": [], "dist": [], "claude_says": [], "fired": {"request"}, "last_spoke": 1.0,
          "chatter_at": None, "left": None, "travel_m": 0.0, "endurance": None}
    return {**st, **kw}


def test_triggers():
    still = [[float(t), 100.0, 0.0, 0.0] for t in range(0, 13, 2)]
    assert le.triggers(state(me=still), 12.0) == ["stood_still"]
    assert "wrong_way" in le.triggers(state(dist=[(0, 20.0), (4, 8.0), (8, 19.0)]), 8.0)
    assert le.triggers(state(), 16.0) == ["impatience"]                     # > 1.5 x T_h
    assert le.triggers(state(fired={"request", "impatience"}), 31.0) == ["urgency"]
    said = state(claude_says=[(5.0, "got them all, done")], left=2)
    assert "missed_some" in le.triggers(said, 6.0)
    assert "missed_some" not in le.triggers({**said, "left": 0}, 6.0)
    assert "his_question" in le.triggers(state(claude_says=[(5.0, "which stone do you mean?")]), 6.0)
    assert "chatter" in le.triggers(state(chatter_at=20.0), 21.0)


def test_canned_writer_and_style(monkeypatch):
    bank = [{"text": "claude where are you going", "kind": "where_why"}, {"text": "NOW", "kind": "urgency"}]
    monkeypatch.setattr(le, "load_style", lambda: bank)
    w = le.CannedWriter(seed=3)
    card = {"line": "claude pick up that Stone"}
    assert w.write("request", card, {}, [])["lines"] == ["claude pick up that Stone"]
    assert w.write("stood_still", card, {}, [])["lines"] == ["claude where are you going"]
    assert w.write("urgency", card, {}, [])["lines"] == ["NOW"]
    assert w.calls == 0 and w.usd == 0.0
    ok, _ = le.style_valid(le.style_stats(["claude where are you going", "pick up the stone near me", "why are you over there?",
                                           "you missed 2 of them", "come here now please", "grab them all from here",
                                           "theres more by the tree"]))
    assert ok
    bad, why = le.style_valid(le.style_stats(["Could you please kindly gather the stones for me, thank you so much?"] * 5))
    assert not bad and why


def test_run_refuses_without_confirm(capsys):
    assert le.main(["run"]) == 2
    assert "pass --confirm" in capsys.readouterr().out
    assert le.main(["run", "--confirm", "--sonnet", "--dry-run"]) == 2

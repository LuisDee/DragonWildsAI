"""An episode still open when its brain session ended is not a 40-63 ks stall (live 20:31:14, 14:21:48): its
wait ends with the session's last row. A short one becomes a ``session_ended`` note; a long wait before the
session ended is still a stall, with the capped wait. Episodes in the running session are unchanged."""
from __future__ import annotations

from tools import obs

T0 = 1_793_000_000.0


def _detect(ep_file: str, sessions: list[tuple[str, float, float]], end_of_data: float, ep_start: float = T0):
    c = obs.Corpus(sessions=[{"file": f, "start": a, "end": b} for f, a, b in sessions])
    ep = obs.Episode(kind="chat", start=ep_start, player="Zezima", request="come here", file=ep_file,
                     lines=[{"said": ep_start, "heard": ep_start, "text": "come here"}])
    return obs._Detect(c, [ep], end_of_data, obs.STALL_S).stall(ep)


def test_an_episode_cut_by_a_session_end_is_a_session_ended_note_not_a_stall():
    out = _detect("a.jsonl", [("a.jsonl", T0 - 100, T0 + 4), ("b.jsonl", T0 + 60_000, T0 + 63_000)], T0 + 63_000)
    assert [a["kind"] for a in out] == ["session_ended"]
    assert out[0]["data"]["wait_s"] == 4.0 and out[0]["level"] == "info"


def test_a_long_wait_before_the_session_ended_is_still_a_stall_capped_at_the_end():
    out = _detect("a.jsonl", [("a.jsonl", T0 - 100, T0 + 143), ("b.jsonl", T0 + 60_000, T0 + 63_000)], T0 + 63_000)
    assert [a["kind"] for a in out] == ["stall"] and out[0]["data"]["wait_s"] == 143.0


def test_the_running_session_still_waits_to_the_end_of_the_data():
    out = _detect("a.jsonl", [("a.jsonl", T0 - 100, T0 + 90)], T0 + 90)
    assert [a["kind"] for a in out] == ["stall"] and out[0]["data"]["wait_s"] == 90.0


def test_session_ended_does_not_count_toward_stall_over_30s():
    rows = _detect("a.jsonl", [("a.jsonl", T0 - 100, T0 + 4), ("b.jsonl", T0 + 60_000, T0 + 63_000)], T0 + 63_000)
    stalls30 = [a for a in rows if a["kind"] == "stall"]
    assert stalls30 == []

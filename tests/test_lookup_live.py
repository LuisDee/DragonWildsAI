"""tools/lookup_live.py on fakes: the spoken scorer (the offline evals' own, plus the spoken form of a level), lookup
use from the brain log rows, the decision case (cited the true level, never what he decided), held-out rows without
line, answer or name, and one fake window end to end (send, heard, quiet, stop, rows). No game, no model."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools import lookup_live as ll

HAIKU = "anthropic/claude-haiku-5-5"
T0 = 1_800_000_000.0


# ------------------------------------------------------------------------------ scorer


def test_line_for_question_and_bare_name():
    assert ll.line_for("what level are garou berserkers") == "claude, what level are garou berserkers?"
    assert ll.line_for("Crasorak Kara") == "claude, what do you know about Crasorak Kara?"
    assert ll.line_for("how do I get into Skeklac Kara?") == "claude, how do I get into Skeklac Kara?"


def test_spoken_level_forms_and_same_scorer():
    groups = [["power level1 3", "power level 3"]]
    assert ll.score_spoken(groups, "Garou berserkers are level 3, I'd bring food.")["hit"]
    assert ll.score_spoken(groups, "They're level three.")["hit"]
    assert not ll.score_spoken(groups, "They're level 13 at least.")["hit"]  # word boundaries, as offline
    s = ll.score_spoken([["red shade"], ["blue shade"], ["green shade"]], "Watch the red shade and the blue shade.")
    assert not s["hit"] and s["coverage"] == pytest.approx(0.667, abs=0.001) and s["missing"] == [["green shade"]]


def test_true_facts_and_decision_group():
    best = {"creatures": {
        "Garou Berserker": {"aliases": ["Berserker"], "variants": [{"power_level": "3", "health": "292"},
                                                                   {"power_level": "8", "health": "885"}]},
        "Garou King": {"variants": [{"power_level": "5", "health": "1035"}]},
        "Giant Rat": {"variants": [{"power_level": "1", "health": "20"}]}}}
    f = ll.true_facts(best, "garou")
    assert f["creatures"] == ["Garou Berserker", "Garou King"] and f["levels"] == ["3", "5", "8"]
    groups = ll.decision_answers(f)
    assert ll.score_spoken(groups, "No: garou here are level 5 and I'm in bronze.")["hit"]
    assert ll.score_spoken(groups, "A berserker has 292 health, too much for me.")["hit"]
    assert not ll.score_spoken(groups, "Sure, let's go!")["hit"]
    assert ll.decision_answers(ll.true_facts(best, "dragon")) == []  # unknown creature: never a hit
    assert ll.levels_said("They're level 5, I'm level two") == ["5", "2"]


# ------------------------------------------------------------------------------ brain log rows


def rows_for(line: str, said: list[str], lookup: bool = True, returned: str = "Garou Berserker power level 3",
             planner: bool = False) -> list[dict]:
    r = [{"ts": T0 + 0.5, "kind": "event", "event": {"type": "chat_heard", "player": "Tester", "text": line}},
         {"ts": T0 + 0.6, "kind": "prompt", "component": "controller", "model": HAIKU},
         {"ts": T0 + 2.0, "kind": "llm_response", "component": "controller",
          "usage": {"prompt": 20000, "completion": 100, "cached": 15000}}]
    if lookup:
        r += [{"ts": T0 + 2.1, "kind": "tool_call", "tool": "lookup", "args": {"query": "garou"}, "read_only": True},
              {"ts": T0 + 2.2, "kind": "tool_result", "tool": "lookup", "read_only": True,
               "result": {"ok": True, "data": {"results": [{"title": "Garou Berserker", "text": returned}]}}}]
    if planner:
        r.append({"ts": T0 + 2.3, "kind": "planner_research", "component": "planner", "tool": "lookup",
                  "args": {"query": "garou king"}, "chars": 400})
    r += [{"ts": T0 + 2.5, "kind": "prompt", "component": "controller", "model": HAIKU},
          {"ts": T0 + 4.0, "kind": "llm_response", "component": "controller",
           "usage": {"prompt": 21000, "completion": 80, "cached": 18000}}]
    r += [{"ts": T0 + 4.1 + i * 0.1, "kind": "say", "text": t, "voice": "reply"} for i, t in enumerate(said)]
    return r


def case(set_name="tuned", answers=None, cid="lvl-garou-berserker", line="claude, what level are garou berserkers?"):
    return {"set": set_name, "family": "enemies", "id": cid, "kind": "level", "line": line,
            "answers": answers or [["power level1 3", "power level 3"]]}


def test_score_case_tuned_reads_say_and_lookup():
    c = case()
    row = ll.score_case(c, rows_for(c["line"], ["They're level 3."], planner=True))
    assert row["hit"] and row["spoke"] and row["used_lookup"] and row["lookup_hit"]
    assert row["lookups"] == 2 and row["lookup_by"] == ["controller", "planner"]
    assert row["lookup_queries"] == ["garou", "garou king"] and row["said"] == ["They're level 3."]
    assert row["haiku_calls"] == 2 and row["sonnet_calls"] == 0


def test_score_case_no_lookup_and_facts_not_returned():
    c = case()
    row = ll.score_case(c, rows_for(c["line"], ["No idea, sorry."], lookup=False))
    assert not row["hit"] and not row["used_lookup"] and not row["lookup_hit"] and row["missing"]
    row = ll.score_case(c, rows_for(c["line"], ["Level 9?"], returned="Garou lore, no numbers"))
    assert row["used_lookup"] and not row["lookup_hit"] and not row["hit"]


def test_heldout_row_carries_no_line_answer_or_name():
    c = case("heldout", cid=ll.hid("heldout", "enemies", "lvl-garou-berserker"))
    assert c["id"].startswith("enemies-") and "garou" not in c["id"]
    row = ll.score_case(c, rows_for(c["line"], ["They're level 3."]))
    assert row["hit"] and row["used_lookup"]
    text = json.dumps(row)
    for leak in ("garou", "level 3", "line", "said", "missing", "lookup_queries"):
        assert leak not in text
    assert ll.case_line(row) is None


def test_decision_records_choice_never_scores_it():
    facts = {"creatures": ["Garou King"], "levels": ["5"], "health": ["1035"]}
    c = {"set": "decision", "family": "decision", "id": "decide-garou", "kind": "decision", "creature": "garou",
         "line": "claude, should we go fight the garou with what you've got?", "answers": ll.decision_answers(facts),
         "facts": facts}
    go = rows_for(c["line"], ["Garou are level 5; risky but let's try."]) + [
        {"ts": T0 + 5, "kind": "tool_call", "task_id": "t1", "tool": "go_to", "args": {}},
        {"ts": T0 + 9, "kind": "tool_result", "task_id": "t1", "tool": "go_to", "result": {"ok": True}}]
    stay = rows_for(c["line"], ["Garou are level 5, too strong for my bronze. Let's not."])
    a, b = ll.score_case(c, go), ll.score_case(c, stay)
    assert a["hit"] and b["hit"]  # both cite the true level; going or not is his
    assert a["tools_called"] == ["go_to"] and b["tools_called"] == [] and a["levels_said"] == ["5"]
    assert not ll.score_case(c, rows_for(c["line"], ["Sure, let's go!"]))["hit"]


# ------------------------------------------------------------------------------ cases from files


def test_load_reads_both_halves_and_hides_heldout_names(tmp_path, monkeypatch):
    tuned, held = tmp_path / "t.jsonl", tmp_path / "h.jsonl"
    tuned.write_text(json.dumps({"id": "a", "kind": "level", "question": "what level is X", "query": "x",
                                 "answers": [["power level 2"]], "source": []}) + "\n", encoding="utf-8")
    held.write_text(json.dumps({"id": "secret-case", "kind": "level", "question": "Y", "query": "y",
                                "answers": [["power level 4"]], "source": []}) + "\n", encoding="utf-8")
    monkeypatch.setattr(ll, "case_files", lambda fam: (tuned, held))
    monkeypatch.setattr(ll, "bestiary", lambda path=None: {"creatures": {"Garou King": {"variants": [{"power_level": "5"}]}}})
    cases = ll.load(families=("enemies",))
    sets = [c["set"] for c in cases]
    assert sets.count("tuned") == 1 and sets.count("heldout") == 1 and sets.count("decision") == len(ll.DECISIONS)
    h = next(c for c in cases if c["set"] == "heldout")
    assert h["id"] != "secret-case" and h["line"] == "claude, what do you know about Y?" and h["answers"]
    ordered = ll.order(cases, seed=3)
    assert [c["set"] for c in ordered[:len(ll.DECISIONS)]] == ["decision"] * len(ll.DECISIONS)
    assert ll.load(sets=("tuned",), families=("enemies",)) == [c for c in cases if c["set"] == "tuned"]


def test_real_case_files_parse_and_every_case_has_a_line():
    cases = ll.load()
    assert cases and all(c["line"].startswith("claude, ") and c["line"].endswith("?") for c in cases)
    dec = [c for c in cases if c["set"] == "decision"]
    assert dec and all(c["answers"] for c in dec)  # the bestiary knows garou and the vault overlord


# ------------------------------------------------------------------------------ one fake window


class FakeIO:
    """The brain answers `said` a few seconds after the line, with a lookup; stop() is counted."""

    def __init__(self, clock, said=("They're level 3.",), heard=True, send_ok=True):
        self.clock, self.said, self.heard, self.send_ok = clock, list(said), heard, send_ok
        self.sent, self.stops, self.t_sent = [], 0, None

    def send(self, line):
        self.sent.append(line)
        self.t_sent = self.clock()
        return self.send_ok, "ok" if self.send_ok else "speech_direct refused"

    def rows(self, t0, t1):
        if self.t_sent is None or not self.heard:
            return []
        shift = self.t_sent - T0
        rs = [{**r, "ts": r["ts"] + shift} for r in rows_for(self.sent[-1], self.said)]
        return [r for r in rs if t0 <= r["ts"] <= t1]

    def stop(self):
        self.stops += 1


class Clock:
    def __init__(self):
        self.t = T0 - 10

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += s


def test_ask_waits_for_quiet_then_scores_and_stops():
    clk = Clock()
    io = FakeIO(clk)
    row = ll.ask(case(), io, haiku_left=50, clock=clk, sleep=clk.sleep)
    assert row["ended"] == "quiet" and row["hit"] and row["used_lookup"] and row["heard_s"] is not None
    assert io.stops == 2 and io.sent == ["claude, what level are garou berserkers?"]
    assert row["wall_s"] >= ll.QUIET_S


def test_ask_never_heard_and_not_sent():
    clk = Clock()
    row = ll.ask(case(), FakeIO(clk, heard=False), haiku_left=50, clock=clk, sleep=clk.sleep)
    assert row["ended"] == "never heard" and not row["hit"] and not row["spoke"]
    row = ll.ask(case(), FakeIO(clk, send_ok=False), haiku_left=50, clock=clk, sleep=clk.sleep)
    assert row["skipped"] and "not sent" in row["why"]


def test_run_cases_writes_rows_and_reports_sets_apart(tmp_path):
    clk = Clock()
    out = tmp_path / "lookup_live.jsonl"
    cases = [case(), case("heldout", cid="enemies-abcd1234"),
             case("tuned", answers=[["red shade"], ["blue shade"]], cid="atk-kq", line="claude, what does the kq do?")]
    printed = []
    rows = ll.run_cases(cases, FakeIO(clk), "lk-test", max_haiku=100, out=out, brain_log="b.jsonl",
                        clock=clk, sleep=clk.sleep, echo=printed.append)
    assert len(rows) == 3 and len(out.read_text(encoding="utf-8").splitlines()) == 3
    assert all(r["run_id"] == "lk-test" for r in rows)
    assert not any("enemies-abcd1234" in p for p in printed)  # held-out prints nothing per case
    s = ll.summary(rows)
    assert s[0].startswith("TUNED") and "said every fact 1/2" in s[0]
    assert s[1].startswith("HELDOUT") and "said every fact 1/1" in s[1]


def test_run_cases_stops_at_haiku_cap_and_foreign_driver(tmp_path):
    clk = Clock()
    rows = ll.run_cases([case(), case()], FakeIO(clk), "r", max_haiku=2, out=tmp_path / "o.jsonl",
                        clock=clk, sleep=clk.sleep, echo=lambda s: None)
    assert len(rows) == 1  # two Haiku calls a case: the cap is met after the first
    rows = ll.run_cases([case()], FakeIO(clk), "r", max_haiku=50, out=tmp_path / "o.jsonl",
                        stop_check=lambda: "debug_to_client.jsonl: go_to 3 s ago", clock=clk, sleep=clk.sleep,
                        echo=lambda s: None)
    assert rows == []


def test_run_refuses_without_confirm(capsys):
    assert ll.main(["run"]) == 2
    assert "--confirm" in capsys.readouterr().out


# ------------------------------------------------------------------------------ the spoken key (one written rule)


def test_spoken_key_keeps_only_the_facts_the_question_asks():
    k = ll.spoken_key("where is tin", "resource", [["fractured plains"], ["stormtouched highlands"], ["power level 3"],
                                                   ["garou berserker", "garou hunter"]])
    assert k["key"] == [["fractured plains"], ["stormtouched highlands"]] and k["asked"] == ["place"]
    k = ll.spoken_key("what vault drops granite maul", "item", [["skeklac kara"], ["granite mauled"]])
    assert k["key"] == [["skeklac kara"]]  # a quest name is not the vault the question asks for
    k = ll.spoken_key("how do I get into Skeklac Kara", "vault",
                      [["ashien's watch"], ["statue", "statues"], ["power level 4"], ["vault corruptor"]])
    assert k["key"] == [["ashien's watch"], ["statue", "statues"]]  # the place and the way in; not level or boss
    k = ll.spoken_key("how strong is the Black Knight Titan", "level", [["power level 6"], ["14000", "14,000"]])
    assert k["key"] == [["power level 6"]]
    k = ll.spoken_key("what is the plague king weak to", "weakness", [["weakness crush", "weak to crush"],
                                                                     ["immune poison"]])
    assert k["key"] == [["weakness crush", "weak to crush"]]
    k = ll.spoken_key("what is a lesser demon weak and resistant to", "weakness", [["weak to fire"], ["resists stab"]])
    assert k["key"] == [["weak to fire"], ["resists stab"]]
    k = ll.spoken_key("what is in the Vertentis Kara chests", "drops", [["skill tome"], ["weak potion"], ["vault shard"]])
    assert len(k["key"]) == 3  # items are untyped, and "weak potion" names no damage kind: not a weakness
    k = ll.spoken_key("what does Velgar do in the fight", "attacks", [["claw slam"], ["poison breath"], ["power level 4"]])
    assert k["key"] == [["claw slam"], ["poison breath"]]


def test_an_open_question_asks_the_identity_of_its_kind_merged_per_type():
    k = ll.spoken_key("Crasorak Kara", "vault", [["temple woods"], ["brynmoor"], ["power level 2"], ["vault overlord"],
                                                 ["vault guardian hulk"], ["374.6"]])
    assert k["open"] and k["key"] == [["temple woods", "brynmoor"], ["vault overlord", "vault guardian hulk"]]
    k = ll.spoken_key("what is Fractured Plains like", "region", [["power level 3"], ["garou berserker"], ["copper"]])
    assert k["open"] and k["key"] == [["power level 3"], ["garou berserker"]]


def test_a_key_the_rule_empties_keeps_the_offline_key_and_says_so():
    k = ll.spoken_key("where is the mystery", "location", [["granite mauled"]])
    assert k["fallback"] and k["key"] == [["granite mauled"]]


def test_said_has_tolerates_speech_not_wrong_facts():
    sc = ll.score_spoken
    assert sc([["putrid rat"], ["vault corruptor"]], "putrid rats and a vault corruptor boss")["hit"]
    assert sc([["poison breath", "dragon breath"]], "he hits hard and breathes poison")["hit"]
    assert sc([["red shade"], ["blue shade"], ["green shade"]], "attacks are red, blue and green shades")["hit"]
    assert sc([["resistance fire", "resists fire"]], "weak to air and stab, resist fire")["hit"]
    assert sc([["weak to air and stab"]], "they're weak to stab and air")["hit"]
    assert sc([["dragon wolf"]], "dragon wolves inside")["hit"]
    assert sc([["power level 5"]], "PL 5 to 8")["hit"]
    assert sc([["skeletal warrior"]], "skeleton warriors everywhere")["hit"]  # the bestiary's alias
    assert not sc([["power level 3"]], "3 garou at level 5")["hit"]  # a figure only in order
    assert not sc([["weak to air and stab"]], "weak to air")["hit"]
    assert not sc([["garou berserker"]], "garou packs")["hit"]
    assert not sc([["zogre"]], "a…")["hit"]


def test_every_case_of_every_set_gets_a_key_by_the_same_rule():
    cases = ll.load()
    assert all(c["key"] for c in cases)
    held = [c for c in cases if c["set"] == "heldout"]
    assert held and all("key_how" in c for c in held)
    tuned = {c["id"]: c for c in cases if c["set"] == "tuned"}
    assert tuned["where-tin"]["key"] == [["fractured plains"], ["stormtouched highlands"]]


def test_rescore_reads_each_window_from_the_brain_log_and_keeps_heldout_unread():
    c_t = {**case(), "key": [["power level1 3", "power level 3"]]}
    c_h = {**case("heldout", cid="enemies-abcd1234"), "key": [["power level 3"]]}
    sent = ll._epoch("2027-01-15T08:00:00Z")
    stored = [{"set": "tuned", "family": "enemies", "case": c_t["id"], "hit": False, "sent_at": "2027-01-15T08:00:00Z",
               "wall_s": 10.0, "brain_log": "b.jsonl", "run_id": "lk-x"},
              {"set": "heldout", "family": "enemies", "case": c_h["id"], "hit": False,
               "sent_at": "2027-01-15T08:01:00Z", "wall_s": 10.0, "brain_log": "b.jsonl", "run_id": "lk-x"},
              {"set": "tuned", "family": "enemies", "case": "gone", "skipped": True, "why": "not sent"}]
    log = [{"ts": sent + 3, "kind": "say", "text": "they're PL 3"},
           {"ts": sent + 63, "kind": "say", "text": "level three, I think"},
           {"ts": sent + 200, "kind": "say", "text": "level 3"}]
    seen = []

    def brain_rows_of(name, t0, t1):
        seen.append((name, t0, t1))
        return [d for d in log if t0 <= d["ts"] <= t1]

    out = ll.rescore(stored, [c_t, c_h], brain_rows_of)
    assert [r.get("hit") for r in out[:2]] == [True, True] and out[2]["skipped"]
    assert seen[0] == ("b.jsonl", sent - 1, sent + 12)
    assert "said" not in out[1] and "line" not in out[1] and out[1]["was_hit"] is False
    assert ll.case_line(out[1]) is None

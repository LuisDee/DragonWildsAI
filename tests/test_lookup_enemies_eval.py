"""The lookup-enemies eval: its scorer, its case files and the held-out guard (evals/lookup_enemies_eval.py)."""
import importlib.util
import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("lookup_enemies_eval", ROOT / "evals" / "lookup_enemies_eval.py")
ev = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ev)


# ---------------------------------------------------------------- scorer

def test_score_is_case_insensitive_and_ignores_punctuation():
    hit, missing = ev.score([["weakness stab"]], "name: Giant Rat\nweakness: Stab\nresistance: Crush")
    assert hit and missing == []
    assert ev.score([["velgar's head"]], "DropsLine: name=Velgar's Head; quantity=1")[0]
    assert ev.score([["6,000", "6000"]], "health: 6,000")[0]


def test_score_needs_word_boundaries():
    assert not ev.score([["stab"]], "a stable door")[0]
    assert not ev.score([["power level 4"]], "power level 45")[0]
    assert ev.score([["power level 4"]], "power level 4 boss")[0]


def test_score_needs_every_group_and_any_alternative():
    answers = [["rat king", "plague king"], ["giant rat"]]
    assert ev.score(answers, "Giant rat | 12\nPlague king | Unknown")[0]
    hit, missing = ev.score(answers, "Giant rat | 12")
    assert not hit and missing == [["rat king", "plague king"]]


def test_empty_answers_never_hit():
    assert not ev.score([], "anything")[0]
    assert not ev.score([[""]], "anything")[0]


def test_returned_text_covers_titles_sections_and_walkthrough():
    data = {"results": [{"title": "Zogre", "section": "Attacks", "text": "- Belly Flop"}],
            "walkthrough": {"title": "Quest", "text": "step one"}}
    text = ev.returned_text(data)
    for part in ("Zogre", "Attacks", "Belly Flop", "step one"):
        assert part in text
    assert ev.returned_text({}) == ""


# ---------------------------------------------------------------- running

class FakeKnowledge:
    build = "test"

    def __init__(self, answers):
        self.answers = answers

    def lookup(self, query, kind=None):
        if query == "boom":
            raise RuntimeError("index gone")
        return {"ok": True, "data": {"query": query, "results": [{"title": query, "text": self.answers.get(query, "")}]}}


def _case(id, query, answers, kind="level", in_mirror=True):
    return {"id": id, "kind": kind, "query": query, "answers": answers, "source": ["test"],
            "answer_in_mirror": in_mirror}


def test_run_case_records_hit_length_time_and_crash():
    k = FakeKnowledge({"giant rat": "power level1: 1"})
    row = ev.run_case(k, _case("a", "giant rat", [["power level1 1"]]))
    assert row["hit"] and row["chars"] > 0 and row["ms"] >= 0 and row["titles"] == ["giant rat"]
    bad = ev.run_case(k, _case("b", "boom", [["x"]]))
    assert not bad["hit"] and "index gone" in bad["error"]


def test_summary_counts_by_kind_and_in_mirror():
    k = FakeKnowledge({"q1": "yes", "q2": "no"})
    rows = ev.run_all(k, [_case("a", "q1", [["yes"]], "level"), _case("b", "q2", [["yes"]], "drops", in_mirror=False)])
    s = ev.summarise(rows)
    assert (s["hits"], s["n"], s["hits_in_mirror"], s["n_in_mirror"]) == (1, 2, 1, 1)
    assert s["by_kind"] == {"level": (1, 1), "drops": (0, 1)}


# ---------------------------------------------------------------- held-out guard

def _rows():
    k = FakeKnowledge({"tuned query": "found", "secret held query": "nothing"})
    tuned = ev.run_all(k, [_case("tuned-case", "tuned query", [["found"]])])
    held = ev.run_all(k, [_case("held-secret-id", "secret held query", [["missing fact"]])])
    return tuned, held


def test_report_prints_heldout_as_one_number_only():
    tuned, held = _rows()
    out = ev.report(tuned, held)
    assert "HELD-OUT 0/1" in out
    for leak in ("held-secret-id", "secret held query", "missing fact", "nothing"):
        assert leak not in out
    assert "tuned-case" in out


def test_report_shows_heldout_only_on_request():
    tuned, held = _rows()
    out = ev.report(tuned, held, show_heldout=True)
    assert "held-secret-id" in out and "missing fact" in out


def test_json_report_keeps_heldout_cases_out_unless_asked():
    tuned, held = _rows()
    doc = json.dumps(ev.json_report(tuned, held))
    assert "held-secret-id" not in doc and "secret held query" not in doc
    assert ev.json_report(tuned, held)["heldout"] == {"hits": 0, "n": 1}
    assert "held-secret-id" in json.dumps(ev.json_report(tuned, held, show_heldout=True))


# ---------------------------------------------------------------- the case files

def test_case_files_are_a_balanced_split_of_thirty():
    tuned, held = ev.load_cases(ev.TUNED), ev.load_cases(ev.HELDOUT)
    assert len(tuned) == 15 and len(held) == 15
    ids = [c["id"] for c in tuned + held]
    assert len(set(ids)) == 30
    assert not {c["query"].lower() for c in tuned} & {c["query"].lower() for c in held}
    total = Counter(c["kind"] for c in tuned + held)
    assert total == {"level": 6, "attacks": 5, "weakness": 5, "location": 4, "vault": 5, "drops": 5}
    t, h = Counter(c["kind"] for c in tuned), Counter(c["kind"] for c in held)
    assert all(abs(t[k] - h[k]) <= 1 for k in total)  # balanced by kind


def test_every_case_cites_a_source_and_has_short_query():
    for c in ev.load_cases(ev.TUNED) + ev.load_cases(ev.HELDOUT):
        assert c["source"] and all(isinstance(s, str) and s for s in c["source"])
        assert 1 <= len(c["query"].split()) <= 5  # as the model passes it, not a sentence
        assert isinstance(c.get("answer_in_mirror", True), bool)

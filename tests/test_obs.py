"""tools/obs.py (episode traces, metrics, anomalies, OTLP) and tools/spend.py over real logs.

Fixture: tests/fixtures/obs_2026-10-25_2054/ is a trimmed copy of the live Shockbyte session 20:50-21:19 UTC on
2026-10-25 (BUGS.md L1-L15: Axtral/Splinter failures, the 125 s go_to stall across a bridge reload, "Done." too early,
raw codes, promises without action). Stored flat ("logs__client__mod_x.jsonl"), since .gitignore ignores every logs/ and
client_io/ directory; unflatten() rebuilds the repo layout. Rebuild: make_fixture.py in that folder.
"""
from __future__ import annotations

import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

import pytest

from tools import obs, spend

FIX = Path(__file__).parent / "fixtures" / "obs_2026-10-25_2054"
DAY = "2026-10-25"


def at(hms: str) -> float:
    h, m, *s = (int(x) for x in hms.split(":"))
    return datetime(2026, 10, 25, h, m, s[0] if s else 0, tzinfo=timezone.utc).timestamp()


def unflatten(dst: Path) -> Path:
    for f in FIX.glob("*.jsonl"):
        target = dst.joinpath(*f.name.split("__"))
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(f, target)
    (dst / "data").mkdir(exist_ok=True)
    shutil.copy(spend.PRICES_FILE, dst / "data" / "model_prices.json")
    return dst


@pytest.fixture(scope="module")
def root(tmp_path_factory) -> Path:
    return unflatten(tmp_path_factory.mktemp("obsroot"))


@pytest.fixture(scope="module")
def window(root):
    return obs.analyse(root, at("20:54"), at("21:18"))


def ep_at(eps, hms: str):
    t = at(hms)
    return next(e for e in eps if abs(e.start - t) < 1.0)


def kinds(anoms, kind):
    return [a for a in anoms if a["kind"] == kind]


# ------------------------------------------------------------------ episodes
def test_segments_the_window_into_chat_and_body_episodes(window):
    _, eps, _ = window
    by_kind = {}
    for e in eps:
        by_kind[e.kind] = by_kind.get(e.kind, 0) + 1
    assert by_kind == {"chat": 29, "body": 6}
    assert all(e.model_calls for e in eps)  # every episode reached the model


def test_chat_episode_has_trigger_decision_tools_body_and_speech(window):
    _, eps, _ = window
    e = ep_at(eps, "21:13:20")  # "grab these nature runs then splinter that tree"
    assert e.player == "Zezima" and "nature runs" in e.request
    assert [(r["tool"], r["ok"], r["reason"]) for r in e.ran] == [
        ("interact", True, None), ("cast", False, "timeout"), ("cast", False, "timeout"), ("cast", False, "timeout")]
    assert [r["attempt"] for r in e.ran] == [1, 1, 2, 3]
    assert e.model_calls[0]["latency"] == pytest.approx(2.8, abs=0.1)
    assert e.model_calls[0]["prompt_tok"] == 13564
    assert e.said[-1]["text"] == "Casting Splinter took too long, so I stopped."
    body = next(s for s in e.steps if s.kind == "action" and s.attrs.get("tool") == "interact").attrs["body"]
    assert body["start"] == at("21:13:27")  # the body's own client_action_start (same id as the bridge message)
    assert e.first_action - e.start == pytest.approx(6.7, abs=0.2)


def test_burst_lines_merge_into_one_episode_with_their_own_said_and_heard_times(window):
    _, eps, _ = window
    e = ep_at(eps, "21:15:09")
    assert [p["text"] for p in e.lines] == ["dont tell me - do it", "actions", "not words",
                                            "also when you arent going to use a spell cancle it dont cast it dso you dont wait the cool down"]
    assert e.lines[0]["heard"] - e.lines[0]["said"] == pytest.approx(77.5, abs=0.5)


def test_body_episode_takes_its_trigger(window):
    _, eps, _ = window
    e = ep_at(eps, "21:05:28")
    assert e.kind == "body" and e.request.startswith("situation_review")
    assert e.steps[0].kind == "trigger"
    assert e.said and "14 m from you" in e.said[0]["text"]


def test_read_tools_stay_in_the_episode_and_are_not_body_actions(window):
    _, eps, _ = window
    e = ep_at(eps, "21:15:05")  # look, look, then go_to + cast
    assert [s.attrs["tool"] for s in e.steps if s.kind == "read"] == ["look", "look"]
    assert [r["tool"] for r in e.ran] == ["go_to", "cast", "cast", "cast"]


def test_episode_render_is_compact_and_human_readable(window):
    _, eps, _ = window
    e = ep_at(eps, "21:01:10")
    text = obs.render_episode(e, 18)
    assert text.startswith('#18 [210110c] CHAT 21:01:10  Zezima: "pick these up / pick those up')
    assert "latency: heard +42.8 s" in text
    assert re.search(r"think +controller claude-haiku-5-5 \[0\] 2\.8 s", text)
    assert 'SAY     "Done."' in text
    assert "anomaly contradictory_speech" in text


# ------------------------------------------------------------------ anomalies (each one seen live, BUGS.md)
def test_stall_names_what_the_brain_was_blocked_on(window):
    _, _, an = window
    s = next(a for a in kinds(an, "stall") if "get our ot the shelter" in a["text"])  # L2
    assert s["level"] == "error" and s["data"]["wait_s"] > 100
    assert "go_to x3 attempts 20:58:40-21:01:34" in s["data"]["busy_with"]
    assert len(kinds(an, "stall")) == 5


def test_bridge_reload_with_a_command_in_flight(window):
    _, _, an = window
    b = kinds(an, "bridge_restart_in_flight")
    assert {a["text"].split(" with")[0] for a in b} == {"body bridge stopped", "body bridge started"}
    assert all("go_to (sent 20:59:26, never answered)" in a["text"] for a in b)  # L2(b)


def test_promise_without_action(window):
    _, _, an = window
    said = [a["data"]["sentence"] for a in kinds(an, "promise_without_action")]
    assert "I'll walk closer and cast it on the tree." in said        # L5 21:02:56
    assert "I'll try Splinter on them again now." in said             # 21:15:01
    assert "On my way." not in said                                   # go_to did run
    assert not any("wait here" in s or "if you" in s for s in said)   # not a deed / an offer


def test_raw_codes_spoken(window):
    _, _, an = window
    raw = {a["text"].split('"')[1]: a["data"]["codes"] for a in kinds(an, "raw_code_spoken")}
    assert raw == {"I couldn't interact: interrupted.": ["interrupted"],
                   "not perceived within 80 m": ["not perceived"],
                   "I couldn't go to: unknown_target.": ["unknown_target"]}  # L4


def test_repeated_failures_timeouts_contradictions_and_stats(window):
    _, _, an = window
    rep = {(a["data"]["tool"], a["data"]["reason"]): a["data"]["count"] for a in kinds(an, "repeated_failure")}
    assert rep == {("cast", "verification_failed"): 9, ("cast", "timeout"): 6}   # L1, L15
    to = {a["data"]["tool"]: a["data"]["seconds"] for a in kinds(an, "tool_timeout")}
    assert to["go_to"] == [46, 125]
    rules = [a["data"]["rule"] for a in kinds(an, "contradictory_speech")]
    assert rules.count("done_with_unrun_plan") == 2                              # L3 "Done."
    assert all(a["data"]["unprompted"] for a in kinds(an, "stat_narration"))
    assert len(kinds(an, "stat_narration")) == 3


def test_anomalies_file_is_deduplicated(root, tmp_path):
    out = tmp_path / "anomalies.jsonl"
    _, _, an = obs.analyse(root, at("20:54"), at("21:18"))
    assert len(obs.append_anomalies(out, an)) == len(an)
    assert obs.append_anomalies(out, an) == []
    rows = [json.loads(x) for x in out.read_text(encoding="utf-8").splitlines()]
    assert {"ts", "kind", "level", "episode", "text", "key", "data"} <= set(rows[0])


def test_follow_tick_reports_a_line_still_waiting(tmp_path):
    """Live mode: a heard line with no response yet becomes a stall once it is older than STALL_S."""
    r = tmp_path / "r"
    (r / "logs").mkdir(parents=True)
    t0 = at("21:00")
    rows = [{"ts": t0, "kind": "session_start", "world": "shockbyte"},
            {"ts": t0 + 5, "kind": "event", "event": {"type": "chat_heard", "player": "Zezima", "text": "come here", "ts": t0 + 4}},
            {"ts": t0 + 5, "kind": "chat_decision", "player": "Zezima", "text": "come here", "decision": "pending", "reason": "x"}]
    (r / "logs" / "brain-live-20261025-220000-1.jsonl").write_text("\n".join(json.dumps(x) for x in rows) + "\n", encoding="utf-8")
    shown: set[str] = set()
    assert obs.follow_tick(r, 900, None, shown, now=t0 + 10) == []
    new = obs.follow_tick(r, 900, None, shown, now=t0 + 30)
    assert [a["kind"] for a in new] == ["stall"] and "no response yet" in new[0]["text"]
    assert obs.follow_tick(r, 900, None, shown, now=t0 + 40) == []   # once


def test_unheard_line_when_no_brain_runs(tmp_path):
    r = tmp_path / "r"
    (r / "client_io" / "events").mkdir(parents=True)
    t0 = at("21:00")
    (r / "client_io" / "events" / "chat.jsonl").write_text(
        json.dumps({"ts": t0, "type": "chat", "from": "Zezima", "self": False, "text": "hello?"}) + "\n", encoding="utf-8")
    _, _, an = obs.analyse(r, t0 - 60, t0 + 120)
    assert [a["kind"] for a in an if a["kind"] == "stall"] == ["stall"]
    assert "no brain session running" in an[0]["text"]


def test_goal_episode_from_the_state_store(tmp_path):
    r = tmp_path / "r"
    (r / "logs" / "state" / "worlds" / "dev").mkdir(parents=True)
    t0 = at("12:00")
    (r / "logs" / "state" / "worlds" / "dev" / "progress.jsonl").write_text("\n".join(json.dumps(x) for x in [
        {"ts": t0 + 1, "msg": "goal started", "goal": "gather 3 ash"}, {"ts": t0 + 9, "msg": "goal done", "goal": "gather 3 ash"}]) + "\n",
        encoding="utf-8")
    brain = [{"ts": t0, "kind": "session_start"},
             {"ts": t0 + 1.5, "kind": "prompt", "component": "planner", "model": "anthropic/claude-sonnet-5-5",
              "messages": [{"role": "user", "content": "{\"goal\": \"gather 3 ash\"}"}]},
             {"ts": t0 + 3.0, "kind": "llm_response", "component": "planner", "content": "{\"tasks\": []}",
              "usage": {"prompt": 900, "completion": 80, "cached": 0, "cache_write": 0}},
             {"ts": t0 + 3.5, "kind": "tool_call", "task_id": "g1", "tool": "gather", "args": {"resource": "ash"}, "attempt": 1},
             {"ts": t0 + 8.0, "kind": "tool_result", "task_id": "g1", "tool": "gather", "result": {"ok": True, "reason": None, "data": {}}},
             {"ts": t0 + 8.5, "kind": "say", "text": "Done: 3 ash."}]
    (r / "logs" / "brain-live-x.jsonl").write_text("\n".join(json.dumps(x) for x in brain) + "\n", encoding="utf-8")
    _, eps, _ = obs.analyse(r, t0 - 10, t0 + 60)
    g = [e for e in eps if e.kind == "goal"]
    assert len(g) == 1 and g[0].request == "gather 3 ash" and g[0].decision == "goal done"
    assert [r_["tool"] for r_ in g[0].ran] == ["gather"] and g[0].said[0]["text"] == "Done: 3 ash."
    assert g[0].model_calls[0]["component"] == "planner"


# ------------------------------------------------------------------ metrics
def test_metrics_over_the_window(window):
    c, eps, an = window
    m = obs.metrics(c, eps, an)
    assert m["chat_to_first_action_s"]["n"] == 19 and m["chat_to_first_action_s"]["p50"] == pytest.approx(7.68, abs=0.05)
    assert m["model_latency_s"]["controller/claude-haiku-5-5"]["p50"] == pytest.approx(1.93, abs=0.05)
    assert m["tools"]["cast"] == {**m["tools"]["cast"], "n": 22, "failed": 21}
    assert m["failures_by_reason"]["verification_failed"] == 10
    assert m["retries"] == 13 and m["promises_without_action"] == 6
    assert "said" not in obs.render_metrics(m)[:0]  # renders without error


def test_goal_check_contract(window, root):
    c, eps, an = window
    g = obs.goal_metrics(c, eps, an, obs.metrics(c, eps, an))
    assert g["schema"] == "dw_obs_metrics/1" and g["source"] == "live"
    assert g["window"] == {"since": "2026-10-25T20:54:00Z", "until": "2026-10-25T21:18:00Z"}
    assert g["hours_observed"] == pytest.approx(0.394, abs=0.01)
    assert g["latency"]["chat_to_first_action_s"]["n"] == 19
    assert g["stability"]["stalls_over_30s"] == 4 and g["stability"]["crashes"] == 0
    assert g["voice"] == {"score": None, "n": 0, "source": None}
    assert set(g["anomalies_per_hour"]) == {"stat_narration", "talk_without_action", "stall_over_30s"}
    sample = json.loads((Path(__file__).parent / "fixtures" / "obs_metrics_sample.json").read_text(encoding="utf-8"))
    assert set(sample) == set(g) and set(sample["deaths"]) == set(g["deaths"])  # the published sample matches the code


def test_deaths_are_classified_from_vitals(root):
    c = obs.load(root, None, None)
    assert obs.deaths(c) == {"total": 3, "starvation": 1, "dehydration": 0, "combat": 2, "other": 0}


def test_metrics_json_with_no_data(tmp_path, capsys):
    assert obs.main(["metrics", "--json", "--root", str(tmp_path), "--since", "24h"]) == 0
    g = json.loads(capsys.readouterr().out)
    assert g["hours_observed"] == 0 and g["latency"]["chat_to_first_action_s"] == {"p50": None, "p90": None, "n": 0}
    assert g["anomalies_per_hour"]["stat_narration"] is None and g["source"] is None


# ------------------------------------------------------------------ OTLP
def test_otlp_export_is_well_formed(window):
    _, eps, _ = window
    doc = obs.to_otlp(eps)
    spans = doc["resourceSpans"][0]["scopeSpans"][0]["spans"]
    ids = {s["spanId"] for s in spans}
    assert all(re.fullmatch(r"[0-9a-f]{32}", s["traceId"]) and re.fullmatch(r"[0-9a-f]{16}", s["spanId"]) for s in spans)
    assert all(s.get("parentSpanId", next(iter(ids))) in ids for s in spans)
    assert all(int(s["endTimeUnixNano"]) >= int(s["startTimeUnixNano"]) for s in spans)
    llm = [s for s in spans if s["name"].startswith("chat ")]
    keys = {a["key"] for a in llm[0]["attributes"]}
    assert {"gen_ai.operation.name", "gen_ai.usage.input_tokens", "llm.token_count.prompt", "openinference.span.kind"} <= keys
    tools = [s for s in spans if s["name"] == "execute_tool cast"]
    assert any(a["key"] == "error.type" and a["value"]["stringValue"] == "timeout" for s in tools for a in s["attributes"])
    assert len({s["traceId"] for s in spans}) == len(eps)


# ------------------------------------------------------------------ spend
def test_price_tiers_and_semantics():
    p = spend.load_prices()
    usd, as_ = spend.price("anthropic/claude-haiku-5-5", {"prompt": 13000, "cached": 9000, "cache_write": 1000, "completion": 300}, p)
    assert as_ == "claude-haiku-5-5"
    assert usd == pytest.approx((3000 * 0.10 + 1000 * 0.125 + 9000 * 0.01 + 300 * 0.50) / 1e6)
    big, _ = spend.price("claude-haiku-5-5", {"prompt": 150_000, "completion": 0}, p)
    assert big == pytest.approx(150_000 * 0.50 / 1e6)  # the whole request pays the >100K tier
    son, _ = spend.price("anthropic/claude-sonnet-5-5", {"prompt": 1000, "cached": 1000, "completion": 1000}, p)
    assert son == pytest.approx((1000 * 0.10 + 1000 * 10.0) / 1e6)
    u = {"prompt": 1000, "completion": 100}
    unk, as_ = spend.price(None, u, p)
    assert as_ is None and unk == max(spend.price(m, u, p)[0] for m in p["models"])  # unknown model: the dearest rate


def test_spend_over_the_fixture_day(root):
    s = spend.spend_day(datetime(2026, 10, 25).date(), root / "logs", cap=10.0)
    assert s["schema"] == "dw_obs_spend/1" and s["state"] == "ok" and s["unpriced_calls"] == 0
    assert s["calls"] == s["by_source"]["live_controller"]["calls"] == 60
    assert s["by_model"]["anthropic/claude-haiku-5-5"]["calls"] == 60
    assert 0.03 < s["spent_usd"] < 0.15
    assert s["prices"]["source"].startswith("https://platform.claude.com/docs/en/about-claude/pricing")


def test_spend_warn_and_cap_anomalies(root):
    import os
    old = os.environ.get("DW_SPEND_CAP_USD")
    os.environ["DW_SPEND_CAP_USD"] = "0.02"
    try:
        an = obs.spend_anomalies(root, at("20:50"), at("21:19"))
    finally:
        if old is None:
            os.environ.pop("DW_SPEND_CAP_USD")
        else:
            os.environ["DW_SPEND_CAP_USD"] = old
    assert [a["kind"] for a in an] == ["spend_warn", "spend_cap"]
    assert an[0]["ts"] <= an[1]["ts"] and an[1]["level"] == "error"


def test_spent_today_usd_never_raises(tmp_path):
    assert spend.spent_today_usd(tmp_path / "missing") == 0.0
    assert obs.spent_today_usd is spend.spent_today_usd


def test_spend_incremental_reads_only_new_lines(tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    f = logs / "brain-live-a.jsonl"
    now = datetime.now(timezone.utc).timestamp()
    line = lambda t: json.dumps({"ts": t, "kind": "llm_response", "component": "controller", "model": "anthropic/claude-haiku-5-5",  # noqa: E731
                                 "usage": {"prompt": 1000, "completion": 100, "cached": 0, "cache_write": 0}})
    f.write_text(line(now - 5) + "\n" + line(now - 4)[:20], encoding="utf-8")  # second line still being written
    assert spend.spend_today(logs)["calls"] == 1
    with f.open("a", encoding="utf-8") as h:
        h.write(line(now - 4)[20:] + "\n")
    assert spend.spend_today(logs)["calls"] == 2


# ------------------------------------------------------------------ CLI + hygiene
def test_cli_episode_and_spend(root, capsys):
    assert obs.main(["episode", "--root", str(root), "--date", DAY, "--since", "21:13", "--until", "21:14"]) == 0
    out = capsys.readouterr().out
    assert 'Zezima: "grab these nature runs then splinter that tree"' in out and "FAIL timeout" in out
    assert obs.main(["spend", "--root", str(root), "--day", DAY, "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["calls"] == 60


def test_fixture_has_no_secrets():
    blob = "\n".join(f.read_text(encoding="utf-8") for f in FIX.glob("*.jsonl"))
    assert not re.search(r"sk-ant-|\?p=[^<]|api[_-]?key", blob, re.I)
    sec = Path(__file__).resolve().parents[1] / "client_io" / "secrets"
    for f in sec.glob("server*.txt"):
        lines = f.read_text(encoding="utf-8-sig").splitlines()
        if len(lines) > 1 and len(lines[1].strip()) >= 3:
            assert lines[1].strip() not in blob

"""tools/timeline.py over synthetic logs: ordering across sources and zones, window, noise, collapse, redaction."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from tools import timeline

PW = "s3cret-pw"
T0 = datetime(2026, 10, 25, 19, 22, 0, tzinfo=timezone.utc).timestamp()


def w(path: Path, lines, bom=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "\n".join(x if isinstance(x, str) else json.dumps(x) for x in lines) + "\n"
    path.write_text(("﻿" if bom else "") + text, encoding="utf-8")


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def make_root(tmp: Path) -> Path:
    r = tmp / "repo"
    w(r / "client_io" / "secrets" / "server_dev.txt", ["127.0.0.1:7777", PW])
    w(r / "client_io" / "events" / "chat.jsonl", [
        {"type": "chat", "from": "Zezima", "text": "come here", "self": False, "ts": int(T0 + 5)},
        {"type": "chat_event", "tag": "UI.Notification.Server.Player.Death", "from": "Claude", "ts": int(T0 + 40)}])
    w(r / "client_io" / "events" / "move.jsonl", [
        {"type": "unreachable", "reason": "no_route", "mode": "go_to", "my_pos": [1, 2, 3], "leader_pos": [4, 5, 6],
         "detail": "d=357m", "ts": int(T0 + 10), "target": "Zezima", "target_kind": "player"},
        {"type": "reachable_again", "my_pos": [1, 2, 3], "leader_pos": [4, 5, 6], "after_s": 12.5, "ts": int(T0 + 30),
         "target": "point", "target_kind": "point"}])
    w(r / "client_io" / "events" / "activity.jsonl", [
        {"type": "activity", "kind": "combat_end", "by": "reflex", "target": "Kebbit", "outcome": "killed", "damage_taken": 0,
         "loot": [{"name": "Bones", "count": 1}], "where": [440.1, 1836.2, -15.6], "ts": int(T0 + 15), "iso": iso(T0 + 15)},
        {"type": "activity", "kind": "fled", "by": "reflex", "from": "Goblin Runt", "why": "outnumbered", "ts": int(T0 + 16)}])
    w(r / "client_io" / "events" / "vitals.jsonl", [
        {"type": "survival", "hp": 100, "hydration": [10, 75], "sustenance": [20, 75], "endurance": [30, 100], "ts": int(T0 + 1)},
        {"type": "survival", "hp": 100, "hydration": [10, 75], "sustenance": [20, 75], "endurance": [30, 100], "ts": int(T0 + 2)},
        {"type": "death", "hp": 0, "survival": {"hydration": [0, 75]}, "ts": int(T0 + 40)},
        {"type": "survival", "hp": 100, "hydration": [9, 75], "ts": int(T0 - 3600)}])   # outside the window
    # brain-live file names are LOCAL time; its rows are unix floats
    start_local = datetime.fromtimestamp(T0 - 60).astimezone().strftime("%Y%m%d-%H%M%S")
    w(r / "logs" / f"brain-live-{start_local}-1.jsonl", [
        {"ts": T0 + 3.0, "kind": "bridge_send", "msg": {"tool": "ping", "args": {}}},
        {"ts": T0 + 3.1, "kind": "bridge_timeout", "tool": "ping", "timeout": 2.0},
        {"ts": T0 + 3.2, "kind": "bridge_timeout", "tool": "ping", "timeout": 2.0},
        {"ts": T0 + 3.3, "kind": "bridge_timeout", "tool": "ping", "timeout": 2.0},
        {"ts": T0 + 6.0, "kind": "tool_call", "tool": "go_to", "args": {"target": "Zezima"}, "task_id": "t1", "attempt": 1},
        {"ts": T0 + 11.0, "kind": "say", "text": "I can't find a way to you"},
        {"ts": T0 + 15.3, "kind": "event", "event": {"type": "activity", "kind": "combat_end", "by": "reflex", "target": "Kebbit",
                                                      "outcome": "killed", "ts": T0 + 15}},
        {"ts": T0 + 12.0, "kind": "tool_result", "tool": "go_to", "result": {"ok": False, "reason": "path_blocked", "data": {}}}])
    w(r / "logs" / "client_watchdog.jsonl", [{"ts": iso(T0 + 20) .replace("Z", ".1234567Z"), "event": "client_hang", "pid": 1}], bom=True)
    local = datetime.fromtimestamp(T0 + 25).astimezone()
    w(r / "logs" / "client" / "boot.log", [local.isoformat(timespec="microseconds") + "1 do: join_server.lua (target dev)",
                                           local.isoformat() + f" open 127.0.0.1:7777?p=abc?pf=PC {PW}"])
    w(r / "logs" / "client" / "client.log", [iso(T0 + 7) + " ran wd_boot_probe.lua ok=true",
                                             iso(T0 + 8) + " move: stuck n=1"])
    return r


def build(r, **kw):
    return timeline.build(r, T0, T0 + 60, set(timeline.SOURCES), game_dir=r / "nogame", **kw)


def test_merges_sources_in_time_order(tmp_path):
    rows = build(make_root(tmp_path))
    ts = [x.ts for x in rows]
    assert ts == sorted(ts)
    srcs = {x.src for x in rows}
    assert {"chat", "move", "vitals", "brain", "watchdog", "boot", "client"} <= srcs
    say = next(x for x in rows if x.kind == "SAY")
    unreach = next(x for x in rows if x.kind == "unreachable")
    assert unreach.ts < say.ts  # the move event (UTC file) precedes the speech (local-named brain file)
    boot = next(x for x in rows if x.src == "boot")
    assert abs(boot.ts - (T0 + 25)) < 1  # +01:00 offsets and 7-digit fractions parse


def test_window_noise_and_collapse(tmp_path):
    r = make_root(tmp_path)
    rows = build(r)
    texts = " | ".join(x.text for x in rows)
    assert "water=9.0" not in texts                       # outside the window
    assert not any(x.kind == "bridge_send" for x in rows)  # noise hidden
    assert "wd_boot_probe" not in texts
    t = [x for x in rows if x.kind == "bridge_timeout"]
    assert len(t) == 1 and t[0].count == 3                # a run of identical lines collapses
    surv = [x for x in rows if x.kind == "survival"]
    assert len(surv) == 1 and surv[0].count == 2
    noisy = build(r, show_noise=True)
    assert any(x.kind == "bridge_send" for x in noisy)


def test_redaction_and_grep(tmp_path):
    r = make_root(tmp_path)
    out = timeline.render_text(build(r), timezone.utc)
    assert PW not in out and "?p=abc" not in out and "<redacted>" in out
    import re
    rows = build(r, grep=re.compile("unreach|death", re.I))
    assert {x.kind for x in rows} == {"unreachable", "notice", "death"}


def test_cli_outputs(tmp_path, capsys):
    r = make_root(tmp_path)
    j, h = tmp_path / "timeline.jsonl", tmp_path / "t.html"
    rc = timeline.main(["--root", str(r), "--game-dir", str(r / "nogame"), "--date", "2026-10-25",
                        "--since", "19:22", "--until", "19:23", "--jsonl", str(j), "--html", str(h)])
    assert rc == 0
    out = capsys.readouterr().out
    assert "Zezima: come here" in out and "19:22:05.0" in out
    rows = [json.loads(x) for x in j.read_text(encoding="utf-8").splitlines()]
    assert rows and rows[0]["ts"].endswith("Z") and all("key" not in x for x in rows)
    assert "<title>Claude Timeline</title>" in h.read_text(encoding="utf-8")
    rc = timeline.main(["--root", str(r), "--game-dir", str(r / "nogame"), "--date", "2026-10-25",
                        "--around", "19:22:10", "--window", "1", "--src", "move"])
    out = capsys.readouterr().out
    assert "unreachable" in out and "come here" not in out


def test_activity_move_and_brain_episode_rows(tmp_path):
    rows = build(make_root(tmp_path))
    act = [x for x in rows if x.src == "activity"]
    assert [x.kind for x in act] == ["combat_end", "fled"]
    assert "outcome=killed" in act[0].text and "loot=Bones" in act[0].text and "where=(440.1,1836.2,-15.6)" in act[0].text
    assert "(by reflex)" in act[0].text and act[1].level == "warn"
    ev = next(x for x in rows if x.kind == "ev:act:combat_end")
    assert ev.src == "brain" and "target=Kebbit" in ev.text
    un = next(x for x in rows if x.kind == "unreachable")
    assert "to Zezima (player)" in un.text
    back = next(x for x in rows if x.kind == "reachable_again")
    assert "after 12.5 s" in back.text and back.level == "info"

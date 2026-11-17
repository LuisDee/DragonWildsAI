"""The unseen-fix ledger (tools/unseen.py): a row per fix committed on tests alone, a scan of the client and brain
logs for lines after the commit that match its signature, confirm and bin, and the report's cap. All offline: git is
a fake (but for one read of HEAD) and the logs are small files under tmp_path."""
from __future__ import annotations

import inspect
import json
import os
import re
from pathlib import Path

import pytest

from tools import unseen as u

T0 = u.epoch("2026-11-17T12:00:00Z")  # the fake commits' clock
COMMITS = {"aaa1111": ("aaa1111", "move: a fix", T0), "bbb2222": ("bbb2222", "brain: another fix", T0 + 3600)}


@pytest.fixture
def led(tmp_path, monkeypatch):
    """An empty ledger and empty log folders under tmp_path, with git answered from COMMITS."""
    def fake(ref):
        for h, c in COMMITS.items():
            if h.startswith(ref) or ref.startswith(h):
                return c
        raise SystemExit(f"git does not know {ref}")
    monkeypatch.setattr(u, "commit", fake)
    monkeypatch.setattr(u, "LEDGER", tmp_path / "unseen_fixes.jsonl")
    for name in ("CLIENT_DIR", "BRAIN_DIR"):
        d = tmp_path / name
        d.mkdir()
        monkeypatch.setattr(u, name, d)
    return tmp_path


def brain_row(ts, kind, **kw):
    return json.dumps({"ts": ts, "kind": kind, **kw}) + "\n"


# --- add ------------------------------------------------------------------------------------------------------------

def test_add_writes_an_open_row_with_the_subject_and_time_from_git(led):
    r = u.add("aaa1111", r"move: taking off \d+ cm", "client", "seen in tests only")
    assert r == {"hash": "aaa1111", "subject": "move: a fix", "time": "2026-11-17T12:00:00Z",
                 "look": r"move: taking off \d+ cm", "log": "client", "note": "seen in tests only", "state": "open"}
    assert u.rows() == [r]


def test_add_refuses_a_hash_already_there_written_short_or_long(led):
    u.add("aaa1111", "x", "client")
    for ref in ("aaa1111", "aaa1111deadbeef", "aaa11"):
        with pytest.raises(SystemExit, match="already in the ledger"):
            u.add(ref, "y", "brain")
    assert [r["look"] for r in u.rows()] == ["x"]


def test_add_refuses_a_regex_that_does_not_compile_and_an_unknown_log(led):
    with pytest.raises(SystemExit, match="does not compile"):
        u.add("aaa1111", "(unclosed", "client")
    with pytest.raises(SystemExit):
        u.add("aaa1111", "x", "server")
    assert u.rows() == []


def test_commit_reads_a_real_commit_from_git():
    h, subject, ct = u.commit("HEAD")
    assert re.fullmatch(r"[0-9a-f]{7,40}", h) and subject and ct > 1_600_000_000
    with pytest.raises(SystemExit, match="git does not know"):
        u.commit("0000000000000000000000000000000000000000")


# --- scan -----------------------------------------------------------------------------------------------------------

def test_scan_counts_only_client_lines_after_the_commit(led):
    u.add("aaa1111", r"move: taking off \d+ cm", "client")
    (u.CLIENT_DIR / "client.log").write_text(
        "2026-11-17T11:59:59Z move: taking off 51 cm from the jump's start\n"   # before the commit
        "2026-11-17T12:00:00Z move: taking off 52 cm from the jump's start\n"   # the commit's own second: not after
        "2026-11-17T12:05:00Z move: taking off 57 cm from the jump's start\n"
        "2026-11-17T12:06:00Z move: stopped\n"
        "2026-11-17T12:07:30Z move: taking off 60 cm from the jump's start\n", encoding="utf-8")
    (t,) = u.scan(u.rows())
    assert (t["hash"], t["log"], t["hits"]) == ("aaa1111", "client", 2)
    assert (t["first"], t["last"]) == ("2026-11-17T12:05:00Z", "2026-11-17T12:07:30Z")
    assert t["sample"] == "2026-11-17T12:05:00Z move: taking off 57 cm from the jump's start"


def test_scan_reads_rotated_client_logs_and_a_line_with_no_stamp_takes_the_one_above(led):
    u.add("aaa1111", "needle", "client")
    (u.CLIENT_DIR / "client.log.1").write_text("2026-11-17T12:01:00Z a needle in the rotated log\n", encoding="utf-8")
    (u.CLIENT_DIR / "client.log").write_text("no stamp yet: needle\n2026-11-17T12:02:00Z a trace\n  needle on its second line\n",
                                             encoding="utf-8")
    (u.CLIENT_DIR / "boot.log").write_text("2026-11-17T12:03:00Z needle in another log\n", encoding="utf-8")
    (t,) = u.scan(u.rows())
    assert (t["hits"], t["first"], t["last"], t["files"]) == (2, "2026-11-17T12:01:00Z", "2026-11-17T12:02:00Z", 2)


def test_scan_goes_by_a_brain_rows_own_time_not_by_the_files_name(led):
    """The name carries the VM's local start time (UTC+1); the rows carry epoch seconds."""
    u.add("bbb2222", r'"kind": "bridge_recv".*so I did not walk anywhere', "brain")  # committed 13:00:00Z
    (u.BRAIN_DIR / "brain-live-20261117-133000-1.jsonl").write_text(  # 13:30 local = 12:30Z: began before the commit
        brain_row(T0 + 1800, "bridge_recv", msg={"detail": "so I did not walk anywhere"})         # 12:30Z: before
        + brain_row(T0 + 3700.5, "bridge_recv", msg={"detail": "so I did not walk anywhere"})     # 13:01:40Z: after
        + brain_row(T0 + 3701, "prompt", messages=["so I did not walk anywhere"])                 # an echo: not counted
        + "not json\n", encoding="utf-8")
    (u.BRAIN_DIR / "brain-20261117.jsonl").write_text(
        brain_row(T0 + 7200, "bridge_recv", msg={"detail": "so I did not walk anywhere"}), encoding="utf-8")
    (u.BRAIN_DIR / "evals-20261117.jsonl").write_text(
        brain_row(T0 + 7300, "bridge_recv", msg={"detail": "so I did not walk anywhere"}), encoding="utf-8")
    (t,) = u.scan(u.rows())
    assert (t["hits"], t["first"], t["last"], t["files"]) == (2, "2026-11-17T13:01:40Z", "2026-11-17T14:00:00Z", 2)


def test_scan_skips_a_file_last_written_before_the_oldest_open_commit(led):
    u.add("aaa1111", "needle", "brain")
    old = u.BRAIN_DIR / "brain-live-20261101-090000-1.jsonl"
    old.write_text(brain_row(T0 + 60, "event", text="needle"), encoding="utf-8")
    os.utime(old, (T0 - 60, T0 - 60))
    (t,) = u.scan(u.rows())
    assert (t["hits"], t["files"]) == (0, 0)
    os.utime(old, (T0 + 120, T0 + 120))
    assert u.scan(u.rows())[0]["hits"] == 1


def test_scan_cuts_the_sample_to_200_characters_with_the_match_in_it(led):
    u.add("aaa1111", "needle", "brain")
    (u.BRAIN_DIR / "brain-live-20261117-140000-1.jsonl").write_text(
        brain_row(T0 + 60, "prompt", messages="x" * 5000 + " the needle " + "y" * 5000), encoding="utf-8")
    (t,) = u.scan(u.rows())
    assert len(t["sample"]) <= u.SAMPLE + 3 and "needle" in t["sample"] and t["sample"].startswith("...")


def test_scan_looks_at_open_rows_only_and_writes_nothing(led):
    u.add("aaa1111", "needle", "client")
    u.add("bbb2222", "needle", "client")
    u.settle("bbb2222", "confirmed", "window s1")
    (u.CLIENT_DIR / "client.log").write_text("2026-11-17T15:00:00Z needle\n", encoding="utf-8")
    before = u.LEDGER.read_bytes()
    assert [(t["hash"], t["hits"]) for t in u.scan(u.rows())] == [("aaa1111", 1)]
    assert u.LEDGER.read_bytes() == before  # an exposure is not a confirmation


def test_scan_reads_a_log_line_by_line_and_never_whole(led, monkeypatch):
    u.add("aaa1111", "needle", "client")
    (u.CLIENT_DIR / "client.log").write_text("2026-11-17T15:00:00Z needle\n" * 3, encoding="utf-8")
    rs = u.rows()

    def whole(*a, **kw):
        raise AssertionError("a log was read whole")
    monkeypatch.setattr(Path, "read_text", whole)
    monkeypatch.setattr(Path, "read_bytes", whole)
    assert inspect.isgeneratorfunction(u.lines)
    assert u.scan(rs)[0]["hits"] == 3


# --- confirm, bin, report -------------------------------------------------------------------------------------------

def test_confirm_and_bin_set_the_state_with_the_text_and_the_date(led):
    u.add("aaa1111", "x", "client")
    u.add("bbb2222", "y", "brain")
    assert u.main(["confirm", "aaa1111", "--evidence", "PROGRESS 2026-11-17"]) == 0
    assert u.main(["bin", "bbb2222", "--why", "reverted"]) == 0
    a, b = u.rows()
    assert (a["state"], a["evidence"]) == ("confirmed", "PROGRESS 2026-11-17")
    assert (b["state"], b["why"]) == ("binned", "reverted")
    assert re.fullmatch(r"\d{4}-\d\d-\d\d", a["date"]) and a["date"] == b["date"]
    with pytest.raises(SystemExit, match="not in the ledger"):
        u.settle("ccc3333", "confirmed", "x")


def test_report_lists_open_rows_oldest_first_with_their_age_and_the_counts(led):
    u.add("bbb2222", "y", "brain")
    u.add("aaa1111", "x", "client")
    opened, counts, over = u.report(u.rows(), now=T0 + 2 * 3600)
    assert [(r["hash"], r["age_h"]) for r in opened] == [("aaa1111", 2.0), ("bbb2222", 1.0)]
    assert counts == {"open": 2, "confirmed": 0, "binned": 0} and over is False
    u.settle("aaa1111", "binned", "dropped")
    opened, counts, over = u.report(u.rows(), now=T0 + 2 * 3600)
    assert [r["hash"] for r in opened] == ["bbb2222"] and counts == {"open": 1, "confirmed": 0, "binned": 1}


def test_report_exits_1_only_when_open_rows_exceed_the_cap(led, capsys):
    row = {"subject": "s", "time": "2026-11-17T12:00:00Z", "look": "x", "log": "client", "note": "", "state": "open"}
    u._write([{**row, "hash": f"{i:07x}"} for i in range(u.CAP)])
    assert u.main(["report"]) == 0
    assert "over the cap" not in capsys.readouterr().out
    u._write([{**row, "hash": f"{i:07x}"} for i in range(u.CAP + 1)] + [{**row, "hash": "fffffff", "state": "confirmed"}])
    assert u.main(["report"]) == 1
    out = capsys.readouterr().out
    assert "over the cap: confirm or bin before a new fix" in out and f"{u.CAP + 1} open" in out and "1 confirmed" in out


def test_the_add_and_scan_commands_print_a_row_per_fix(led, capsys):
    assert u.main(["add", "aaa1111", "--look", "needle", "--log", "client", "--note", "weak"]) == 0
    (u.CLIENT_DIR / "client.log").write_text("2026-11-17T15:00:00Z a needle\n", encoding="utf-8")
    capsys.readouterr()
    assert u.main(["scan"]) == 0
    out = capsys.readouterr().out
    assert re.search(r"aaa1111\s+client\s+1\s+2026-11-17T15:00:00Z\s+2026-11-17T15:00:00Z", out)
    assert "2026-11-17T15:00:00Z a needle" in out and "1 with hits" in out


# --- the ledger in the repo -----------------------------------------------------------------------------------------

def test_the_committed_ledger_is_well_formed():
    rs = u.rows(u.ROOT / "docs" / "unseen_fixes.jsonl")
    assert len({r["hash"] for r in rs}) == len(rs)
    for r in rs:
        re.compile(r["look"])
        assert r["log"] in u.LOGS and r["state"] in ("open", "confirmed", "binned"), r["hash"]
        assert u.iso(u.epoch(r["time"])) == r["time"] and r["subject"], r["hash"]
        assert r["state"] == "open" or (r.get("evidence") or r.get("why")) and r.get("date"), r["hash"]

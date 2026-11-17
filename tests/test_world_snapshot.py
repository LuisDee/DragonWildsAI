"""tools/world_snapshot.py against a made-up world folder and made-up probes: no process, lock or real save is touched."""
from __future__ import annotations

import json
import os
import time

import pytest

from tools import live_lock
from tools import world_snapshot as ws

T0 = 1795000000.0  # 2026-11-18T11:06:40Z


def world(saved, sav=b"world-v1", cells=None):
    """A fake Saved/ with the two world folders, plus a folder the tool must never read or write."""
    (saved / "SaveGames").mkdir(parents=True, exist_ok=True)
    (saved / "SpudCache").mkdir(exist_ok=True)
    (saved / "Config").mkdir(exist_ok=True)
    (saved / "Config" / "DedicatedServer.ini").write_text("AdminPassword=not-a-world-file")
    (saved / "SaveGames" / "CompanionDev.sav").write_bytes(sav)
    (saved / "SaveGames" / "CompanionDev.sav.backup").write_bytes(b"world-v0")
    for name, body in (cells or {"L_World.lvl": b"L" * 64, "RSACell12800_X0_Y13.lvl": b"cell-0-13"}).items():
        (saved / "SpudCache" / name).write_bytes(body)


def tree(base, dirs=ws.WORLD_DIRS):
    return {p.relative_to(base).as_posix(): p.read_bytes() for d in dirs for p in (base / d).rglob("*") if p.is_file()}


class Rig:
    def __init__(self, tmp_path, running=False, hold=True, lock=None):
        self.saved, self.root, self.hold = tmp_path / "Saved", tmp_path / "snaps", tmp_path / "server.stopped"
        world(self.saved)
        if hold:
            self.hold.write_text("")
        self.running, self.lock, self.now = running, lock, T0
        self.joined, self.logs_from = [], "2026-11-01T00:00:00Z"
        self.s = ws.Store(saved=self.saved, root=self.root, hold_file=self.hold, running=lambda: self.running,
                          lock=lambda: self.lock, build=lambda: "26161880", clock=lambda: self.now,
                          joins=lambda: (self.joined, self.logs_from))

    def labels(self):
        return sorted(p.name for p in self.root.iterdir()) if self.root.exists() else []


def test_keep_copies_the_world_with_a_manifest_and_list_shows_it(tmp_path):
    r = Rig(tmp_path)
    man = r.s.keep("base", note="before the windows")
    assert tree(r.root / "base") == tree(r.saved)
    assert set(man["files"]) == {"SaveGames/CompanionDev.sav", "SaveGames/CompanionDev.sav.backup",
                                 "SpudCache/L_World.lvl", "SpudCache/RSACell12800_X0_Y13.lvl"}
    rec = man["files"]["SaveGames/CompanionDev.sav"]
    assert rec["sha256"] == ws.sha256(r.saved / "SaveGames" / "CompanionDev.sav") and rec["size"] == 8
    assert man["source"] == str(r.saved) and man["build"] == "26161880" and man["taken_at"] == "2026-11-18T11:06:40Z"
    assert man["total_bytes"] == 8 + 8 + 64 + 9
    assert json.loads((r.root / "base" / "manifest.json").read_text()) == man
    assert not (r.root / "base" / "Config").exists()  # only the world's folders
    assert r.s.list() == [{"label": "base", "taken_at": "2026-11-18T11:06:40Z", "bytes": 89, "files": 4,
                           "build": "26161880", "note": "before the windows"}]
    assert r.s.verify("base")["ok"] is True


@pytest.mark.parametrize("running, hold, match", [
    (True, True, "server is running"),
    (None, True, "process list could not be read"),
    (False, False, "server.stopped is absent"),
])
def test_keep_refuses_while_the_server_may_write_the_world(tmp_path, running, hold, match):
    r = Rig(tmp_path, running=running, hold=hold)
    with pytest.raises(ws.Refused, match=match):
        r.s.keep("base")
    assert r.labels() == []


def test_keep_never_overwrites_a_label_and_takes_plain_labels_only(tmp_path):
    r = Rig(tmp_path)
    r.s.keep("base")
    before = tree(r.root / "base")
    (r.saved / "SaveGames" / "CompanionDev.sav").write_bytes(b"world-v2")
    with pytest.raises(ws.Refused, match="never overwritten"):
        r.s.keep("base")
    assert tree(r.root / "base") == before
    for bad in ("", "a/b", "..", "a b", "x" * 41, "undo-20261117T000000Z"):
        with pytest.raises(ws.Refused, match="not a plain label"):
            r.s.keep(bad)
    assert r.labels() == ["base"]


def test_keep_refuses_a_folder_with_no_save_and_a_server_that_starts_mid_copy(tmp_path):
    r = Rig(tmp_path)
    (r.saved / "SaveGames" / "CompanionDev.sav").unlink()
    with pytest.raises(ws.Refused, match="no .sav"):
        r.s.keep("base")
    world(r.saved)
    answers = iter([False, True])  # down at the guard, up when the copy is checked
    r.s.running = lambda: next(answers)
    with pytest.raises(ws.Refused, match="during the copy"):
        r.s.keep("base")
    assert r.labels() == []  # no half-made label, no temp folder


def moved_on(r):
    """The world after a trial window: the save rewritten, a stray NEWER save, one cache cell changed, one gone, one new."""
    (r.saved / "SaveGames" / "CompanionDev.sav").write_bytes(b"world-v2-mined-out")
    (r.saved / "SaveGames" / "Other.sav").write_bytes(b"stray")
    (r.saved / "SpudCache" / "L_World.lvl").write_bytes(b"M" * 70)
    (r.saved / "SpudCache" / "RSACell12800_X0_Y13.lvl").unlink()
    (r.saved / "SpudCache" / "RSACell12800_X4_Y14.lvl").write_bytes(b"new-cell")


def test_restore_is_a_dry_run_by_default_and_prints_every_copy(tmp_path, monkeypatch, capsys):
    r = Rig(tmp_path)
    r.s.keep("base")
    moved_on(r)
    r.running, r.lock = True, {"owner": "rung1", "text": "rung1 2026-11-17T22:20:00Z pid=1", "stale": False}
    r.hold.unlink()
    monkeypatch.setattr(ws, "default_store", lambda: r.s)
    live = tree(r.saved)
    assert ws.main(["restore", "base"]) == 0  # the plan is printed even while the guards would refuse
    out = capsys.readouterr().out
    assert tree(r.saved) == live and r.labels() == ["base"]
    assert "DRY RUN: nothing is changed" in out and "pass --confirm to do it" in out
    assert out.count("REFUSES NOW:") == 3 and "live lock is held (rung1" in out
    assert "keep the world as it stands as undo-20261118T110640Z (5 files)" in out
    for rel in ("SaveGames/CompanionDev.sav", "SaveGames/CompanionDev.sav.backup", "SpudCache/L_World.lvl",
                "SpudCache/RSACell12800_X0_Y13.lvl"):
        src, to = r.root / "base" / rel, r.saved / rel
        assert f"copy {src} -> {to} ({src.stat().st_size} bytes)" in out
    assert f"remove {r.saved / 'SaveGames' / 'Other.sav'}" in out
    assert f"remove {r.saved / 'SpudCache' / 'RSACell12800_X4_Y14.lvl'}" in out
    assert ws.main(["restore", "base", "--dry-run"]) == 0 and tree(r.saved) == live


@pytest.mark.parametrize("running, hold, lock, match", [
    (True, True, None, "server is running"),
    (None, True, None, "process list could not be read"),
    (False, False, None, "server.stopped is absent"),
    (False, True, {"owner": "quests", "text": "quests 2026-11-17T22:20:00Z pid=7", "stale": False}, "live lock is held"),
])
def test_restore_confirm_refuses_and_changes_nothing(tmp_path, monkeypatch, capsys, running, hold, lock, match):
    r = Rig(tmp_path)
    r.s.keep("base")
    moved_on(r)
    live = tree(r.saved)
    r.running, r.lock = running, lock
    if not hold:
        r.hold.unlink()
    with pytest.raises(ws.Refused, match=match):
        r.s.restore("base")
    monkeypatch.setattr(ws, "default_store", lambda: r.s)
    assert ws.main(["restore", "base", "--confirm"]) == 2 and "refused:" in capsys.readouterr().out
    assert tree(r.saved) == live and r.labels() == ["base"]  # no undo was made either


def test_restore_confirm_puts_the_world_back_exactly_and_keeps_an_undo(tmp_path):
    r = Rig(tmp_path)
    kept = tree(r.saved)
    r.s.keep("base")
    old = r.saved / "SaveGames" / "CompanionDev.sav.backup"
    os.utime(r.root / "base" / "SaveGames" / "CompanionDev.sav", (T0 - 100, T0 - 100))
    moved_on(r)
    after_window = tree(r.saved)
    r.now = T0 + 3600
    res = r.s.restore("base")
    assert res == {"restored": "base", "files": 4, "bytes": 89, "undo": "undo-20261118T120640Z", "to": str(r.saved)}
    assert tree(r.saved) == kept  # the stray newer save and the new cache cell are gone, the removed cell is back
    assert (r.saved / "SaveGames" / "CompanionDev.sav").stat().st_mtime == pytest.approx(T0 - 100, abs=2)  # its own time
    assert old.read_bytes() == b"world-v0"
    assert (r.saved / "Config" / "DedicatedServer.ini").read_text() == "AdminPassword=not-a-world-file"
    undo = json.loads((r.root / res["undo"] / "manifest.json").read_text())
    assert tree(r.root / res["undo"]) == after_window and undo["before_restore_of"] == "base"
    assert r.s.verify("base")["ok"] and r.s.verify(res["undo"])["ok"]  # the snapshot itself is untouched
    r.now = T0 + 7200
    r.s.restore(res["undo"])  # and the undo undoes it
    assert tree(r.saved) == after_window
    assert [x["label"] for x in r.s.list()] == ["base", "undo-20261118T120640Z", "undo-20261118T130640Z"]


@pytest.mark.parametrize("damage", ["tamper", "missing", "extra"])
def test_a_snapshot_that_is_not_whole_is_refused_before_the_world_is_touched(tmp_path, damage):
    r = Rig(tmp_path)
    r.s.keep("base")
    moved_on(r)
    live = tree(r.saved)
    f = r.root / "base" / "SaveGames" / "CompanionDev.sav"
    if damage == "tamper":
        f.write_bytes(b"world-vX")  # the same size, other bytes
    elif damage == "missing":
        f.unlink()
    else:
        (r.root / "base" / "SpudCache" / "added.lvl").write_bytes(b"x")
    v = r.s.verify("base")
    assert v["ok"] is False and (v["changed"] or v["missing"] or v["extra"])
    with pytest.raises(ws.Refused, match="not whole"):
        r.s.restore("base")
    with pytest.raises(ws.Refused, match="not whole"):
        r.s.plan("base")
    assert tree(r.saved) == live and r.labels() == ["base"]


def test_a_manifest_that_names_a_file_outside_the_world_folders_is_refused(tmp_path):
    r = Rig(tmp_path)
    man = r.s.keep("base")
    for rel in ("../SaveCharacters/ClaudeDev.json", "Config/DedicatedServer.ini", "SaveGames/../../x.sav", "SaveGames"):
        bad = dict(man, files={**man["files"], rel: {"sha256": "0" * 64, "size": 1}})
        (r.root / "base" / "manifest.json").write_text(json.dumps(bad))
        with pytest.raises(ws.Refused, match="not a file inside"):
            r.s.restore("base")
    with pytest.raises(ws.Refused, match="no snapshot"):
        r.s.restore("never_kept")
    assert tree(r.saved) == tree(r.root / "base")


def test_the_live_lock_is_read_as_live_lock_reads_it_and_never_taken(tmp_path):
    r = Rig(tmp_path)
    r.s.keep("base")
    lock = tmp_path / "live_owner.txt"
    r.s.lock = lambda: live_lock.read(lock)
    assert r.s.blockers(lock=True) == []  # no lock file: free
    lock.write_text(f"quests 2026-11-17T22:20:00Z pid={os.getpid()}", encoding="utf-8")
    text, mtime = lock.read_text(), lock.stat().st_mtime
    assert any("live lock is held (quests" in b for b in r.s.blockers(lock=True))
    with pytest.raises(ws.Refused, match="live lock is held"):
        r.s.restore("base")
    assert r.s.blockers(lock=False) == []  # a plain keep does not need the body
    lock.write_text("quests 2026-11-17T22:20:00Z pid=0", encoding="utf-8")  # unrefreshed, its process gone: stale
    old = time.time() - live_lock.STALE_S - 60
    os.utime(lock, (old, old))
    assert r.s.blockers(lock=True) == []
    assert lock.read_text() == "quests 2026-11-17T22:20:00Z pid=0" and text.startswith("quests")
    assert lock.stat().st_mtime == pytest.approx(old, abs=2) and mtime > old  # read only: not claimed, not refreshed


def test_the_server_probe_counts_the_server_image_only():
    client = ('"RSDragonwilds.exe","24900","RDP-Tcp#1","2","32,400 K"\n'
              '"RSDragonwilds-Win64-Shipping.exe","19768","RDP-Tcp#1","2","1,888,576 K"\n'
              '"steam.exe","3284","RDP-Tcp#1","2","46,748 K"\n')
    assert ws.has_server(client) is False
    assert ws.has_server(client + '"RSDragonwildsServer-Win64-Shipping.exe","19608","RDP-Tcp#1","2","689,824 K"\n') is True
    assert ws.has_server('"RSDragonwildsServer.exe","1","Console","1","1 K"') is True  # the launcher
    assert ws.has_server("") is False


def test_the_cli_runs_on_the_paths_at_the_top_of_the_module(tmp_path, monkeypatch, capsys):
    saved, hold = tmp_path / "Saved", tmp_path / "server.stopped"
    world(saved)
    hold.write_text("")
    acf = tmp_path / "appmanifest.acf"
    acf.write_text('"AppState"\n{\n\t"appid"\t\t"4019830"\n\t"buildid"\t\t"26161880"\n}\n')
    for name, value in (("SAVED", saved), ("SNAP_ROOT", tmp_path / "snaps"), ("HOLD_FILE", hold), ("APP_MANIFEST", acf),
                        ("server_running", lambda: False), ("live_lock", lambda: None)):
        monkeypatch.setattr(ws, name, value)
    assert ws.main(["keep", "base", "--note", "clean"]) == 0
    assert ws.main(["keep", "base"]) == 2
    assert ws.main(["verify", "base"]) == 0
    moved = saved / "SaveGames" / "CompanionDev.sav"
    moved.write_bytes(b"world-v2")
    assert ws.main(["restore", "base"]) == 0 and moved.read_bytes() == b"world-v2"  # the default is a dry run
    assert ws.main(["restore", "base", "--confirm"]) == 0 and moved.read_bytes() == b"world-v1"
    (tmp_path / "snaps" / "base" / "SpudCache" / "L_World.lvl").write_bytes(b"torn")
    assert ws.main(["verify", "base"]) == 1
    assert ws.main(["list"]) == 0
    out = capsys.readouterr().out
    assert "kept base: 4 files" in out and "build 26161880" in out and "clean" in out
    assert "refused: snapshot 'base' exists" in out and "every sha256 checked" in out and "NOT whole" in out
    assert "2 world snapshot(s)" in out and "undo-" in out


def test_the_defaults_are_the_dev_servers_world_folders_and_a_gitignored_place():
    assert ws.SAVED == ws.SERVER_ROOT / "RSDragonwilds" / "Saved" and ws.WORLD_DIRS == ("SaveGames", "SpudCache")
    assert ws.SNAP_ROOT.relative_to(ws.ROOT).parts[0] == "logs" or "DW_WORLD_SNAPSHOTS" in os.environ
    assert ws.HOLD_FILE == ws.ROOT / "logs" / "server.stopped"  # the file stop_server.ps1 -Hold writes
    assert "SaveCharacters" not in str(ws.SAVED) and "client_io" not in str(ws.SNAP_ROOT)


def test_restore_refuses_when_another_player_joined_after_the_snapshot(tmp_path):
    # the world save holds the server's copy of every character: a restore would roll another player's back
    r = Rig(tmp_path)
    r.s.keep("base")
    before = tree(r.saved)
    (r.saved / "SaveGames" / "CompanionDev.sav").write_bytes(b"later world")
    later = tree(r.saved)
    r.joined = [("2026-11-18T10:00:00Z", "Luis"), ("2026-11-18T12:00:00Z", "Claude")]  # Luis before it, he after
    assert r.s.plan("base")["blockers"] == []
    r.joined.append(("2026-11-18T12:30:00Z", "Luis"))
    pl = r.s.plan("base")
    assert len(pl["blockers"]) == 1 and "Luis joined the server after" in pl["blockers"][0]
    with pytest.raises(ws.Refused):
        r.s.restore("base")
    assert tree(r.saved) == later and r.labels() == ["base"]  # nothing changed, no undo made
    r.now += 60
    res = r.s.restore("base", others_ok="Luis 2026-11-18: fine, roll it back")
    assert tree(r.saved) == before
    assert "Luis 2026-11-18" in json.loads((r.root / res["undo"] / "manifest.json").read_text())["note"]


def test_the_plan_says_when_the_logs_do_not_reach_back_to_the_snapshot(tmp_path):
    r = Rig(tmp_path)
    r.s.keep("base")
    assert r.s.plan("base")["notes"] == []
    r.logs_from = "2026-11-19T00:00:00Z"
    assert "NOT checked" in r.s.plan("base")["notes"][0]
    r.logs_from = None
    assert "no server log" in r.s.plan("base")["notes"][0]


def test_server_joins_reads_the_servers_own_log_lines(tmp_path):
    (tmp_path / "RSDragonwilds.log").write_text(
        "Log file open, 11/17/26 14:00:00\n"
        "[2026.11.17-14.18.13:839][795]LogNet: Login request: ?Name=Claude userId: x platform: y\n"
        "[2026.11.17-14.18.20:215][981]LogNet: Join succeeded: Claude\n"
        "[2026.11.17-15.02.00:001][  3]LogNet: Join succeeded: Some One\n", encoding="utf-8")
    assert ws.server_joins(tmp_path) == ([("2026-11-17T14:18:20Z", "Claude"), ("2026-11-17T15:02:00Z", "Some One")],
                                         "2026-11-17T14:18:13Z")
    assert ws.server_joins(tmp_path / "none") == ([], None)

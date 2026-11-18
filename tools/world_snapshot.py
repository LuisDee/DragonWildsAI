"""Named snapshots of the dev server's WORLD save, so a trial window can start from the same world as the last one.

A character checkpoint (tools/quest_clone.py keep / fork) fixes his quests, bag and position; it does not hold the
world. The world (rocks mined out, what is in stations and chests, what was built, the time of day, and the server's
own cached copy of every character it has seen: CachedCharacterStates) is the dedicated server's save:

    <server>\\RSDragonwilds\\Saved\\SaveGames\\<World>.sav + .sav.backup   the save and the autosave before it
    <server>\\RSDragonwilds\\Saved\\SpudCache\\*.lvl                       the running game's per-cell cache (SPUD)

    .venv\\Scripts\\python.exe -m tools.world_snapshot list
    .venv\\Scripts\\python.exe -m tools.world_snapshot keep base --note "before the 17 Nov windows"
    .venv\\Scripts\\python.exe -m tools.world_snapshot restore base              # a dry run: prints the plan only
    .venv\\Scripts\\python.exe -m tools.world_snapshot restore base --confirm
    .venv\\Scripts\\python.exe -m tools.world_snapshot verify base

This tool never stops or starts anything. keep and restore --confirm refuse unless
  * no server process is running (a save copied mid-write may be torn; the server autosaves every 5 minutes),
  * logs\\server.stopped exists (tools\\stop_server.ps1 -Hold writes it): without it tools\\watchdog.ps1 starts the
    server again within 5 s, in the middle of the copy,
and restore --confirm also refuses while the live lock (tools/live_lock.py) is held: someone is driving his body,
and when the server's logs show a player other than him joined after the snapshot was kept (the world save holds
the server's copy of every character, so theirs would be rolled back: Luis's call, --others-ok with his words).
So a restore between windows is: stop_server.ps1 -Hold, restore LABEL --confirm, start_server.ps1, client_boot.ps1.

A label is never overwritten (as a checkpoint's is not). restore first keeps the world as it stands as
undo-<UTC time>, then empties the world's folders (the server loads the NEWEST .sav, so a stray newer one would win;
a cache cell the snapshot does not have would be stale), copies the snapshot back and checks every sha256.
Snapshots live in logs/world_snapshots/<label>/ (logs/ is gitignored: saves are never committed) with manifest.json.

tools/checkpoint_pair.py keeps a world as ck-<checkpoint> beside a character checkpoint and restores it between the
trials of one window: it passes own_pid (the live lock its own window holds is not a blocker) and stops the client and
server itself; the rules above are otherwise the same.

Only the two world folders are read or written. Character saves (SaveCharacters, ClaudeDev.json), client_io/ and the
server's config are not this tool's. evals/bench/snapshot.py (route B, never run live) is the older tool for a world
plus one character with its own stop/start; this one is the world alone and touches no process.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from brain import paths

# ---------------------------------------------------------------- every path and name this tool uses, in one place
ROOT = Path(__file__).resolve().parents[1]
SERVER_ROOT = Path(os.environ.get("DW_SERVER_ROOT") or r"C:\GameServers\Dragonwilds")  # tools/config.ps1 $ServerRoot
SAVED = SERVER_ROOT / "RSDragonwilds" / "Saved"                                         # tools/config.ps1 $ServerSaved
LIVE_SAVED = SAVED  # the real server's saves (a test repoints SAVED: that is its fake; the restore guard reads this)
WORLD_DIRS = ("SaveGames", "SpudCache")  # the folders under SAVED that are one world; nothing else is read or written
LIVE = paths.LIVE_ROOT  # single per VM: the main working tree's, also from a worktree
SNAP_ROOT = Path(os.environ.get("DW_WORLD_SNAPSHOTS") or LIVE / "logs" / "world_snapshots")
HOLD_FILE = LIVE / "logs" / "server.stopped"  # stop_server.ps1 -Hold: tools/watchdog.ps1 leaves the server down
SERVER_IMAGE = "RSDragonwildsServer"          # tools/config.ps1 Get-ServerProcess: 'RSDragonwildsServer*'
APP_MANIFEST = SERVER_ROOT / "steamapps" / "appmanifest_4019830.acf"  # tools/config.ps1 Get-ServerBuildId
LOG_DIR = SAVED / "Logs"                      # the server's own logs: "LogNet: Join succeeded: <persona>"
OWN_NAMES = ("Claude",)                       # his Steam persona; a join under any other name is another player
STAMP_RE = re.compile(r"^\[(\d{4})\.(\d\d)\.(\d\d)-(\d\d)\.(\d\d)\.(\d\d):\d+\]")
JOIN_RE = re.compile(r"^\[(\d{4})\.(\d\d)\.(\d\d)-(\d\d)\.(\d\d)\.(\d\d):\d+\]\[[ \d]*\]LogNet: Join succeeded: (.+?)\s*$")
SCHEMA = "dw_world_snapshot/1"
LABEL_RE = re.compile(r"[A-Za-z0-9_-]{1,40}")
UNDO = "undo-"


class Refused(Exception):
    """The tool will not do it, and why. Nothing was changed unless the message says so."""


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def has_server(tasklist_csv: str, image: str = SERVER_IMAGE) -> bool:
    """Whether `tasklist /FO CSV /NH` output lists a server process. The game CLIENT's images
    (RSDragonwilds.exe, RSDragonwilds-Win64-Shipping.exe) do not start with the server's name."""
    return any(line.strip().lstrip('"').lower().startswith(image.lower()) for line in tasklist_csv.splitlines())


def live_images() -> list[str] | None:
    """The image names of the processes that are running now, from a Toolhelp snapshot, or None when it cannot be
    read. `tasklist` hung past 30 s on this VM (2026-11-17), and a killed server stays listed while a handle to it is
    open, so each listed process is opened and only those whose exit code is still STILL_ACTIVE count."""
    import ctypes
    from ctypes import wintypes as w

    class Entry(ctypes.Structure):
        _fields_ = [("dwSize", w.DWORD), ("cntUsage", w.DWORD), ("th32ProcessID", w.DWORD),
                    ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", w.DWORD), ("cntThreads", w.DWORD),
                    ("th32ParentProcessID", w.DWORD), ("pcPriClassBase", ctypes.c_long), ("dwFlags", w.DWORD),
                    ("szExeFile", ctypes.c_wchar * 260)]

    try:
        k = ctypes.WinDLL("kernel32", use_last_error=True)
    except (OSError, AttributeError):
        return None
    k.CreateToolhelp32Snapshot.restype = w.HANDLE
    k.OpenProcess.restype = w.HANDLE
    snap = k.CreateToolhelp32Snapshot(0x2, 0)  # TH32CS_SNAPPROCESS
    if not snap or snap == w.HANDLE(-1).value:
        return None
    names, e = [], Entry()
    e.dwSize = ctypes.sizeof(Entry)
    try:
        ok = k.Process32FirstW(snap, ctypes.byref(e))
        while ok:
            h = k.OpenProcess(0x1000, False, e.th32ProcessID)  # PROCESS_QUERY_LIMITED_INFORMATION
            if h:
                code = w.DWORD()
                if not k.GetExitCodeProcess(h, ctypes.byref(code)) or code.value == 259:  # STILL_ACTIVE
                    names.append(e.szExeFile)
                k.CloseHandle(h)
            else:
                names.append(e.szExeFile)  # cannot open it: count it, never guess it gone
            ok = k.Process32NextW(snap, ctypes.byref(e))
    finally:
        k.CloseHandle(snap)
    return names or None


def server_running() -> bool | None:
    """True / False, or None when the process list could not be read (which refuses: never copy on a guess)."""
    names = live_images()
    return None if names is None else has_server("\n".join(names))


def live_lock() -> dict | None:
    """The live lock as tools/live_lock.py reads it (a read of logs/state/live_owner.txt; the lock is never taken)."""
    from tools import live_lock as ll
    return ll.read()


def server_build() -> str | None:
    try:
        m = re.search(r'"buildid"\s+"(\d+)"', APP_MANIFEST.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return None
    return m.group(1) if m else None


def server_joins(log_dir: Path | None = None) -> tuple[list[tuple[str, str]], str | None]:
    """Every "Join succeeded" in the server's logs as (UTC time, persona), and the earliest time those logs hold
    (None: no log could be read). The engine stamps its log lines in UTC."""
    joins, first = [], None
    for f in sorted((log_dir or LOG_DIR).glob("*.log")) if (log_dir or LOG_DIR).is_dir() else []:
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    m = STAMP_RE.match(line) if line.startswith("[") else None
                    if not m:
                        continue
                    t = "%s-%s-%sT%s:%s:%sZ" % m.groups()
                    first = t if first is None or t < first else first
                    j = JOIN_RE.match(line) if "Join succeeded" in line else None
                    if j:
                        joins.append((t, j.group(7)))
        except OSError:
            continue
    return sorted(joins), first


def _mb(n: int) -> str:
    return f"{n / 1e6:.1f} MB"


@dataclass
class Store:
    saved: Path = field(default_factory=lambda: SAVED)
    dirs: tuple[str, ...] = WORLD_DIRS
    root: Path = field(default_factory=lambda: SNAP_ROOT)
    hold_file: Path = field(default_factory=lambda: HOLD_FILE)
    running: Callable[[], bool | None] = lambda: server_running()
    lock: Callable[[], dict | None] = lambda: live_lock()
    build: Callable[[], str | None] = lambda: server_build()
    joins: Callable[[], tuple[list[tuple[str, str]], str | None]] = lambda: server_joins()
    own_names: tuple[str, ...] = OWN_NAMES
    clock: Callable[[], float] = time.time

    # ------------------------------------------------------------------------------------------------ reading
    def world_files(self) -> list[str]:
        """The live world's files, as paths relative to `saved` with forward slashes ("SaveGames/CompanionDev.sav")."""
        out = []
        for d in self.dirs:
            base = self.saved / d
            if base.is_dir():
                out += [p.relative_to(self.saved).as_posix() for p in base.rglob("*") if p.is_file()]
        return sorted(out)

    def manifest(self, label: str) -> dict:
        if not LABEL_RE.fullmatch(label or ""):
            raise Refused(f"{label!r} is not a plain label (letters, digits, _ and -, at most 40)")
        try:
            man = json.loads((self.root / label / "manifest.json").read_text(encoding="utf-8"))
        except OSError:
            raise Refused(f"no snapshot {label!r} in {self.root}") from None
        except ValueError:
            raise Refused(f"snapshot {label!r}: manifest.json does not read as JSON") from None
        if man.get("schema") != SCHEMA or not isinstance(man.get("files"), dict) or not man["files"]:
            raise Refused(f"snapshot {label!r}: manifest.json is not a {SCHEMA} manifest with files")
        for rel in man["files"]:  # a manifest names files inside the world's folders only
            parts = rel.split("/")
            if parts[0] not in self.dirs or len(parts) < 2 or any(x in ("", ".", "..") or ":" in x or "\\" in x for x in parts):
                raise Refused(f"snapshot {label!r}: {rel!r} is not a file inside {', '.join(self.dirs)}")
        return man

    def list(self) -> list[dict]:
        rows = []
        for d in sorted(self.root.iterdir()) if self.root.is_dir() else []:
            if not d.is_dir() or d.name.startswith("."):
                continue
            try:
                man = self.manifest(d.name)
                rows.append({"label": d.name, "taken_at": man.get("taken_at"), "bytes": man.get("total_bytes"),
                             "files": len(man["files"]), "build": man.get("build"), "note": man.get("note") or ""})
            except Refused as exc:
                rows.append({"label": d.name, "taken_at": None, "bytes": None, "files": 0, "build": None,
                             "note": f"UNREADABLE: {exc}"})
        return sorted(rows, key=lambda r: (r["taken_at"] or "", r["label"]))

    def verify(self, label: str) -> dict:
        """The snapshot's own files against its manifest: {ok, files, missing, changed, extra}."""
        man, d = self.manifest(label), self.root / label
        missing, changed = [], []
        for rel, rec in man["files"].items():
            p = d / rel
            if not p.is_file():
                missing.append(rel)
            elif p.stat().st_size != rec["size"] or sha256(p) != rec["sha256"]:
                changed.append(rel)
        extra = sorted(p.relative_to(d).as_posix() for p in d.rglob("*")
                       if p.is_file() and p.name != "manifest.json" and p.relative_to(d).as_posix() not in man["files"])
        return {"ok": not (missing or changed or extra), "label": label, "files": len(man["files"]),
                "missing": missing, "changed": changed, "extra": extra}

    # ------------------------------------------------------------------------------------------------- guards
    def blockers(self, lock: bool, own_pid: int | None = None) -> list[str]:
        """Why a copy must not run now ([] = it may). Read only: nothing is stopped, started or claimed.
        own_pid: the live lock held by this pid is the caller's own window (tools/checkpoint_pair.py restores a
        checkpoint's world between the trials of one window, with the client stopped), not someone driving him."""
        out = []
        r = self.running()
        if r is None:
            out.append("the process list could not be read, so the server may be running")
        elif r:
            out.append(f"the server is running ({SERVER_IMAGE}*): a save copied or replaced under it is torn or "
                       "overwritten by its next autosave; stop it with tools\\stop_server.ps1 -Hold")
        if not self.hold_file.exists():
            out.append(f"{self.hold_file} is absent: tools\\watchdog.ps1 starts the server again within seconds; "
                       "stop it with tools\\stop_server.ps1 -Hold")
        if lock:
            cur = self.lock()
            if cur and not cur.get("stale") and not (own_pid and cur.get("pid") == own_pid):
                out.append(f"the live lock is held ({cur.get('text')}): someone is driving his body")
        return out

    def others_since(self, taken_at: str | None) -> dict:
        """Players other than him who joined the server after `taken_at`, by its own logs. The world save holds the
        server's copy of every character it has seen (CachedCharacterStates), so a restore rolls theirs back too:
        another player's character is not his to touch (CLAUDE.md section 4).
        -> {others: [(time, name)], checked_from: the earliest time the logs hold | None}"""
        rows, first = self.joins()
        return {"others": [(t, n) for t, n in rows if n not in self.own_names and (not taken_at or t >= taken_at)],
                "checked_from": first}

    # ------------------------------------------------------------------------------------------------ writing
    def keep(self, label: str, note: str = "", _undo_of: str | None = None, _lock: bool = False,
             _own_pid: int | None = None) -> dict:
        if not LABEL_RE.fullmatch(label or "") or (label.startswith(UNDO) and _undo_of is None):
            raise Refused(f"{label!r} is not a plain label (letters, digits, _ and -, at most 40; {UNDO}* is restore's)")
        dest = self.root / label
        if dest.exists():
            raise Refused(f"snapshot {label!r} exists: a label is never overwritten")
        why = self.blockers(lock=_lock, own_pid=_own_pid)
        if why:
            raise Refused("; ".join(why))
        files = self.world_files()
        if not any(f.startswith(self.dirs[0] + "/") and f.endswith(".sav") for f in files):
            raise Refused(f"no .sav in {self.saved / self.dirs[0]}: that is not a world")
        tmp = self.root / f".tmp-{label}-{os.getpid()}"  # a keep that dies leaves no half-made label
        if tmp.exists():
            shutil.rmtree(tmp)
        try:
            recs, total = {}, 0
            for rel in files:
                src, to = self.saved / rel, tmp / rel
                to.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, to)
                h = sha256(to)
                st = src.stat()
                if sha256(src) != h or to.stat().st_size != st.st_size:
                    raise Refused(f"{src} changed while it was copied: something is writing the world")
                recs[rel] = {"sha256": h, "size": st.st_size, "mtime": round(st.st_mtime, 3)}
                total += st.st_size
            if self.running() is not False or self.world_files() != files:
                raise Refused("the server started, or the world's file list changed, during the copy: nothing kept")
            man = {"schema": SCHEMA, "label": label, "note": note,
                   "taken_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.clock())),
                   "build": self.build(), "source": str(self.saved), "dirs": list(self.dirs),
                   "total_bytes": total, "files": recs}
            if _undo_of is not None:
                man["before_restore_of"] = _undo_of
            (tmp / "manifest.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
            os.replace(tmp, dest)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
        return man

    def plan(self, label: str, others_ok: str = "", own_pid: int | None = None) -> dict:
        """What restore would do, from a snapshot that is whole (it is hashed first). Changes nothing."""
        man = self.manifest(label)
        v = self.verify(label)
        if not v["ok"]:
            raise Refused(f"snapshot {label!r} is not whole (missing {v['missing']}, changed {v['changed']}, "
                          f"extra {v['extra']}): not restoring from it")
        d = self.root / label
        why, seen, notes = self.blockers(lock=True, own_pid=own_pid), self.others_since(man.get("taken_at")), []
        if seen["others"]:
            names = ", ".join(sorted({n for _, n in seen["others"]}))
            said = (f"{names} joined the server after this snapshot was kept (first at {seen['others'][0][0]}): the "
                    "world save holds the server's copy of every character, so this restore rolls theirs back too")
            if others_ok:
                notes.append(f"{said}; allowed: {others_ok}")
            else:
                why.append(f"{said}. That is Luis's call: pass --others-ok with his words")
        if seen["checked_from"] is None:
            notes.append("no server log could be read: whether another player joined since the snapshot is NOT checked")
        elif man.get("taken_at") and seen["checked_from"] > man["taken_at"]:
            notes.append(f"the server's logs reach back to {seen['checked_from']} only: joins between the snapshot "
                         "and then are NOT checked")
        return {"label": label, "manifest": man, "blockers": why, "notes": notes, "others_ok": others_ok,
                "to": str(self.saved),
                "undo": UNDO + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(self.clock())),
                "remove": [str(self.saved / Path(rel)) for rel in self.world_files()],
                "copy": [(str(d / Path(rel)), str(self.saved / Path(rel)), rec["size"]) for rel, rec in man["files"].items()],
                "build_now": self.build()}

    def restore(self, label: str, others_ok: str = "", own_pid: int | None = None, undo: bool = True) -> dict:
        """Keep the world as undo-<utc>, empty the world's folders, copy the snapshot back, check every sha256.
        own_pid: see blockers. undo=False keeps no undo first: only for putting an undo back over a world a restore
        left torn (tools/checkpoint_pair.py), which is not worth keeping. A Refused raised after the world was
        touched carries .undo, the label that puts it back (None when no undo was kept)."""
        from tools import live_guard  # the real server's saves: never from a test, from a worktree only with DW_LIVE_OK
        real = os.path.normcase(os.path.abspath(self.saved)) == os.path.normcase(os.path.abspath(LIVE_SAVED))
        why = live_guard.why_refused(f"restore {label} into {self.saved}", fake=not real)
        if why:
            raise Refused(why)
        pl = self.plan(label, others_ok, own_pid)
        if pl["blockers"]:
            raise Refused("; ".join(pl["blockers"]))
        man = pl["manifest"]
        if undo:
            kept = self.keep(pl["undo"], note=f"the world before restore of {label}" + (f"; others ok: {others_ok}" if others_ok else ""),
                             _undo_of=label, _lock=True, _own_pid=own_pid)
            gone, undo_label = list(kept["files"]), pl["undo"]
            back = f"the world before it is kept as {undo_label} (restore {undo_label} --confirm puts it back)"
        else:
            gone, undo_label, back = self.world_files(), None, "no undo was kept (undo=False)"

        def torn(msg: str, cause: BaseException | None = None) -> Refused:
            exc = Refused(msg)
            exc.undo = undo_label
            exc.__cause__ = cause
            return exc
        try:
            for rel in gone:  # only files the undo snapshot holds, hashed, are removed
                (self.saved / rel).unlink()
            for rel in man["files"]:
                to = self.saved / rel
                to.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(self.root / label / rel, to)  # with its time: of two .sav the newer stays the newer
        except OSError as exc:
            raise torn(f"restore of {label} stopped half way ({exc}): the world folders are NOT whole; {back}", exc)
        bad = [rel for rel, rec in man["files"].items()
               if not (self.saved / rel).is_file() or sha256(self.saved / rel) != rec["sha256"]]
        stray = sorted(set(self.world_files()) - set(man["files"]))
        if bad or stray or self.running() is not False:
            raise torn(f"restore of {label} did not verify (wrong sha256: {bad}; files not in the snapshot: {stray}; "
                       f"server running: {self.running()}): do not start the server on it; {back}")
        return {"restored": label, "files": len(man["files"]), "bytes": man.get("total_bytes"), "undo": undo_label,
                "to": str(self.saved)}


def default_store() -> Store:
    return Store()


def _print_plan(pl: dict, confirm: bool, out=print) -> None:
    man = pl["manifest"]
    out(f"restore {pl['label']!r} (kept {man.get('taken_at')}, build {man.get('build')}, {len(man['files'])} files, "
        f"{_mb(man.get('total_bytes') or 0)}) -> {pl['to']}"
        + ("" if confirm else "   DRY RUN: nothing is changed"))
    if man.get("build") and pl["build_now"] and man["build"] != pl["build_now"]:
        out(f"  note: the snapshot is of build {man['build']}, the server is build {pl['build_now']}")
    for b in pl["blockers"]:
        out(f"  REFUSES NOW: {b}")
    for n in pl.get("notes") or []:
        out(f"  note: {n}")
    out(f"  1. keep the world as it stands as {pl['undo']} ({len(pl['remove'])} files)")
    out(f"  2. remove {len(pl['remove'])} files:")
    for p in pl["remove"]:
        out(f"       remove {p}")
    out(f"  3. copy {len(pl['copy'])} files:")
    for src, to, size in pl["copy"]:
        out(f"       copy {src} -> {to} ({size} bytes)")
    out(f"  4. check the sha256 of all {len(pl['copy'])}, and that no other file is in the world's folders")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="the labels: time, size, build, note")
    k = sub.add_parser("keep", help="copy the world to a new label (server stopped with -Hold)")
    k.add_argument("label")
    k.add_argument("--note", default="")
    r = sub.add_parser("restore", help="put a label's world back; a dry run unless --confirm")
    r.add_argument("label")
    g = r.add_mutually_exclusive_group()
    g.add_argument("--dry-run", action="store_true", help="print the plan only (the default)")
    g.add_argument("--confirm", action="store_true", help="do it")
    r.add_argument("--others-ok", default="", metavar="WORDS",
                   help="another player joined since the snapshot and Luis allowed rolling their character back: his words")
    v = sub.add_parser("verify", help="recompute a label's hashes against its manifest")
    v.add_argument("label")
    a = ap.parse_args(argv)
    s = default_store()
    try:
        if a.cmd == "list":
            rows = s.list()
            print(f"{len(rows)} world snapshot(s) in {s.root}; the server is build {s.build()}")
            for x in rows:
                print(f"  {x['label']:<26} {x['taken_at'] or '?':<20} {_mb(x['bytes'] or 0):>9} {x['files']:>4} files  "
                      f"build {x['build'] or '?'}  {x['note']}")
            return 0
        if a.cmd == "keep":
            man = s.keep(a.label, a.note)
            print(f"kept {a.label}: {len(man['files'])} files, {_mb(man['total_bytes'])}, build {man['build']}, "
                  f"from {man['source']} in {s.root / a.label}")
            return 0
        if a.cmd == "verify":
            res = s.verify(a.label)
            print(f"{a.label}: " + (f"all {res['files']} files match their sha256" if res["ok"] else
                                    f"NOT whole: missing {res['missing']}, changed {res['changed']}, extra {res['extra']}"))
            return 0 if res["ok"] else 1
        _print_plan(s.plan(a.label, a.others_ok), a.confirm)
        if not a.confirm:
            print("pass --confirm to do it")
            return 0
        res = s.restore(a.label, a.others_ok)
        print(f"restored {res['restored']}: {res['files']} files, {_mb(res['bytes'] or 0)}, every sha256 checked; "
              f"the world before it is kept as {res['undo']}")
        return 0
    except Refused as exc:
        print(f"refused: {exc}")
        return 2


if __name__ == "__main__":
    sys.exit(main())

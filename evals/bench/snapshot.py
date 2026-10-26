"""Route B: snapshot / restore of the dev world save + one character, for chained capstone stages (design §0b).

A snapshot is logs/bench/snapshots/<name>/ with the dev world .sav (every .sav in SaveGames), the character
SaveCharacters/<character>.json and manifest.json (sha256 of each file, build, character, GUID, the case it closes).

  take:    stop client -> stop dev server (files final, no mid-autosave) -> copy + hash -> start server -> (boot later)
  restore: stop client -> stop server -> back up the live files to snapshots/_pre_restore_<ts>/ -> EMPTY SaveGames
           (the server loads the NEWEST .sav; a stray newer one would win) -> copy back -> start server
  verify:  after the client boots, the character JSON must still hash as restored (Steam Cloud keeps only the newest
           copy and may overwrite it: main 2026-10-26, cloud stays on) -> a mismatch is a fixture gap, never a pass.

Restores run only in an announced "capstone window" through the client slot (`client_slot.py enqueue eval
"capstone restore window"`), never on Shockbyte (the paths are the local dev server's; there is no remote route).

  .venv\\Scripts\\python.exe -m evals.bench.snapshot list
  .venv\\Scripts\\python.exe -m evals.bench.snapshot take <name> --character CD_x --case capstone_stage_1_shelter --yes
  .venv\\Scripts\\python.exe -m evals.bench.snapshot restore <name> --yes
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .hashes import ROOT, game_build
from .observer import Abort

SERVER_ROOT = Path(os.environ.get("DW_SERVER_ROOT", r"C:\GameServers\Dragonwilds"))
SAVE_GAMES = SERVER_ROOT / "RSDragonwilds" / "Saved" / "SaveGames"
SAVE_CHARACTERS = Path(os.environ.get("LOCALAPPDATA", "")) / "RSDragonwilds" / "Saved" / "SaveCharacters"
SNAP_ROOT = ROOT / "logs" / "bench" / "snapshots"


def sha(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _ps(script: str, *args: str, env: dict | None = None) -> int:
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tools" / script), *args]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=600,
                              env={**os.environ, **(env or {})}).returncode
    except subprocess.TimeoutExpired:
        return 124


@dataclass
class Snapshots:
    save_games: Path = SAVE_GAMES
    save_characters: Path = SAVE_CHARACTERS
    root: Path = SNAP_ROOT
    stop_client: Callable[[], int] = lambda: _ps("stop_client.ps1", "-Hold")
    stop_server: Callable[[], int] = lambda: _ps("stop_server.ps1", "-Hold")  # the watchdog must not restart it mid-copy
    # the bench fixtures and referee refuse unless the server process has DW_SERVER_ROLE=dev (it is no user/machine
    # env var: the server inherits it from whoever starts it)
    start_server: Callable[[], int] = lambda: _ps("start_server.ps1", env={"DW_SERVER_ROLE": "dev"})
    clock: Callable[[], float] = time.time

    def _stop_all(self) -> None:
        if self.stop_client() != 0:
            raise Abort("stop_client failed")
        if self.stop_server() != 0:
            raise Abort("stop_server failed")

    def list(self) -> list[dict]:
        out = []
        for m in sorted(self.root.glob("*/manifest.json")):
            if not m.parent.name.startswith("_"):
                out.append(json.loads(m.read_text(encoding="utf-8")))
        return out

    def take(self, name: str, character: str, case: str = "", guid: str = "") -> dict:
        if not name or name.startswith("_") or "/" in name or "\\" in name:
            raise Abort(f"bad snapshot name {name!r}")
        dest = self.root / name
        if dest.exists():
            raise Abort(f"snapshot {name} exists (names are immutable: a stage's verified end state)")
        self._stop_all()
        try:
            saves = sorted(self.save_games.glob("*.sav"))
            ch = self.save_characters / f"{character}.json"
            if not saves:
                raise Abort(f"no .sav in {self.save_games}")
            if not ch.exists():
                raise Abort(f"no character file {ch.name}")
            dest.mkdir(parents=True)
            files = {}
            for p in saves + [ch]:
                shutil.copy2(p, dest / p.name)
                files[p.name] = {"sha256": sha(dest / p.name), "kind": "world" if p.suffix == ".sav" else "character"}
            man = {"schema": "dw_bench_snapshot_files/1", "name": name, "character": character, "guid": guid,
                   "case": case, "build": game_build(), "taken_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.clock())),
                   "files": files}
            (dest / "manifest.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
            return man
        finally:
            self.start_server()

    def restore(self, name: str) -> dict:
        src = self.root / name
        mp = src / "manifest.json"
        if not mp.exists():
            raise Abort(f"no snapshot {name}")
        man = json.loads(mp.read_text(encoding="utf-8"))
        for fn, rec in man["files"].items():  # a corrupt snapshot is refused before anything live is touched
            if not (src / fn).exists() or sha(src / fn) != rec["sha256"]:
                raise Abort(f"snapshot {name}: {fn} missing or changed")
        self._stop_all()
        try:
            backup = self.root / f"_pre_restore_{time.strftime('%Y%m%d-%H%M%S', time.gmtime(self.clock()))}"
            backup.mkdir(parents=True)
            for p in list(self.save_games.glob("*.sav*")) + [self.save_characters / f"{man['character']}.json"]:
                if p.exists():
                    shutil.copy2(p, backup / p.name)
            for p in self.save_games.glob("*.sav*"):  # empty: the newest .sav wins at server start
                p.unlink()
            for fn, rec in man["files"].items():
                to = (self.save_games if rec["kind"] == "world" else self.save_characters) / fn
                shutil.copy2(src / fn, to)
                os.utime(to, None)  # newest = this one
            return {"restored": name, "backup": str(backup), "character": man["character"]}
        finally:
            self.start_server()

    def verify(self, name: str) -> dict:
        """After the client booted on the restored character: its JSON must still be the restored one."""
        man = json.loads((self.root / name / "manifest.json").read_text(encoding="utf-8"))
        ch = man["character"] + ".json"
        live = self.save_characters / ch
        ok = live.exists() and sha(live) == man["files"][ch]["sha256"]
        return {"ok": ok, "character": man["character"],
                "why": None if ok else "character file changed after boot (Steam Cloud overwrite?): fixture gap"}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    t = sub.add_parser("take")
    t.add_argument("name")
    t.add_argument("--character", required=True)
    t.add_argument("--case", default="")
    t.add_argument("--guid", default="")
    t.add_argument("--yes", action="store_true")
    r = sub.add_parser("restore")
    r.add_argument("name")
    r.add_argument("--yes", action="store_true")
    v = sub.add_parser("verify")
    v.add_argument("name")
    a = ap.parse_args(argv)
    s = Snapshots()
    if a.cmd == "list":
        print(json.dumps(s.list(), indent=1))
        return 0
    if a.cmd == "verify":
        res = s.verify(a.name)
        print(json.dumps(res))
        return 0 if res["ok"] else 1
    if not a.yes:
        print("this stops the dev server and the client: only in an announced capstone window, holding the client "
              "slot. Re-run with --yes.")
        return 2
    res = s.take(a.name, a.character, a.case, a.guid) if a.cmd == "take" else s.restore(a.name)
    print(json.dumps(res, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

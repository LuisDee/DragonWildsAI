"""A fresh dev character per case that needs a pristine start (main, 2026-10-26; route A of the fresh-state problem).

M3 every-skill cases (asked / initiative / plus5) and the capstone stages must start from a brand-new character: there
is no reset verb, and ClaudeDev (the long-lived main dev character, kept for M4-M6 progression) is not fresh. This
creates one through the game's own front end and joins dev with it, using only existing tools:

  client_io/state/character_name.txt   <- the wanted name (create_char.lua and pick_char.lua both read it)
  tools/stop_client.ps1                <- every switch RELAUNCHES the client: a fresh process has used none of its
                                          front-end returns, so no 3rd return can happen (BUGS L24)
  tools/client_boot.ps1 -Release -Target dev -Attempts 1
                                       <- launch; for a NEW name pick_char answers character_not_found and boot stops
                                          at the menu (sign_in_failed), then:
  client_mod/commands/create_char.lua  <- the verified create flow (DISCOVERIES R2), until SaveCharacters/<name>.json
  tools/client_boot.ps1 -Release -Target dev
                                       <- pick_char (select by name + sign in) -> join dev -> skip_intro -> pawn
  dev referee `probe`                  <- the new character's GUID on the server (fixtures are addressed by GUID)

Route B (later): snapshot/restore of the dev world save + the character JSON with the server stopped, for capstone
chains. Characters made here accumulate in SaveCharacters (and Steam Cloud); `made` lists them for a later clean-up.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from .hashes import ROOT
from .observer import Abort

MAIN_CHARACTER = "ClaudeDev"
NAME_FILE = ROOT / "client_io" / "state" / "character_name.txt"
SAVE_DIR = Path(os.environ.get("LOCALAPPDATA", "")) / "RSDragonwilds" / "Saved" / "SaveCharacters"
CREATE_CMD = ROOT / "client_mod" / "commands" / "create_char.lua"
MADE_LOG = ROOT / "logs" / "bench" / "dev_characters.jsonl"
MAX_NAME = 16  # conservative: the game's name rule is not in the reflection dump; a rejected name is a fixture gap
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{2,%d}$" % (MAX_NAME - 1))


def fresh_name(case_id: str, run_tag: str) -> str:
    """CD_<readable tag><4-hex case hash>_<run tag>, at most MAX_NAME characters (the hash keeps two cases whose
    readable tags truncate alike apart; the full case id is in the case result and logs/bench/dev_characters.jsonl)."""
    words = [w for w in re.split(r"[^A-Za-z0-9]+", case_id) if w and w not in ("goal", "case")]
    h = hashlib.sha1(case_id.encode("utf-8")).hexdigest()[:4]
    room = max(0, MAX_NAME - len("CD_") - len(h) - 1 - len(run_tag))
    tag = "".join(w[:3] for w in words)[:room]
    name = f"CD_{tag}{h}_{run_tag}"[:MAX_NAME]
    if not NAME_RE.match(name):
        raise ValueError(f"cannot make a valid character name from {case_id!r} / {run_tag!r}")
    return name


def powershell(script: str, *args: str, timeout: float = 900) -> int:
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tools" / script), *args]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        return 124


@dataclass
class CharacterSwitch:
    """Side effects are injected so tests can fake them (tests/test_bench_devchar.py)."""
    server_players: Callable[[], list[dict]]  # dev referee probe -> [{name, character_guid, ...}]
    client_cmd: Callable[[Path, str, dict | None, float], dict | None]
    ps: Callable[..., int] = powershell
    name_file: Path = NAME_FILE
    save_dir: Path = SAVE_DIR
    made_log: Path = MADE_LOG
    sleep: Callable[[float], None] = time.sleep
    made: list[str] = field(default_factory=list)

    def exists(self, name: str) -> bool:
        return (self.save_dir / f"{name}.json").exists()

    def in_world(self, name: str) -> dict | None:
        return next((p for p in self.server_players() or [] if p.get("name") == name and p.get("character_guid")), None)

    def _boot(self, *extra: str) -> int:
        return self.ps("client_boot.ps1", "-Release", "-Target", "dev", "-Quiet", *extra)

    def ensure(self, name: str, create: bool = False, wait_s: float = 90) -> dict:
        """Get `name` into the dev world; returns {name, guid, created, relaunched}. Abort when it can't."""
        here = self.in_world(name)
        if here:
            return {"name": name, "guid": here["character_guid"], "created": False, "relaunched": False}
        if not NAME_RE.match(name):
            raise Abort(f"invalid character name {name!r}")
        self.name_file.parent.mkdir(parents=True, exist_ok=True)
        self.name_file.write_text(name + "\n", encoding="utf-8")
        self.ps("stop_client.ps1")  # BUGS L24: relaunch instead of a front-end return
        created = False
        if not self.exists(name):
            if not create:
                raise Abort(f"character {name} does not exist (create=False)")
            self._boot("-Attempts", "1")  # stops at the menu: pick_char cannot find the new name yet
            r = self.client_cmd(CREATE_CMD, "bench_create_char", None, 30.0) or {}
            for _ in range(int(wait_s // 3)):
                if self.exists(name):
                    break
                self.sleep(3)
            if not self.exists(name):
                raise Abort(f"create_char did not write {name}.json: {json.dumps(r.get('result') or r)[:200]}")
            created = True
            self.made.append(name)
            self._record(name)
        if self._boot() != 0:
            raise Abort(f"client_boot did not get {name} into the dev world")
        for _ in range(int(wait_s // 3)):
            here = self.in_world(name)
            if here:
                return {"name": name, "guid": here["character_guid"], "created": created, "relaunched": True}
            self.sleep(3)
        raise Abort(f"{name} joined but the dev server does not list it")

    def _record(self, name: str) -> None:
        try:
            self.made_log.parent.mkdir(parents=True, exist_ok=True)
            with open(self.made_log, "a", encoding="utf-8") as f:
                f.write(json.dumps({"t": time.time(), "name": name, "purpose": "fresh dev character (bench)"}) + "\n")
        except OSError:
            pass


def default_switch(dev) -> CharacterSwitch:
    from tools.scenario_run import run_client_cmd

    def players() -> list[dict]:
        r = dev.server_debug({"part": "referee", "action": "probe"})
        return ((r.get("data") or {}).get("result") or {}).get("players") or []
    return CharacterSwitch(server_players=players, client_cmd=run_client_cmd)

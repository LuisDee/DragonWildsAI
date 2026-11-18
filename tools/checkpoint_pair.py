"""A checkpoint is a PAIR: his character save and the world as it stood at that moment, under ONE character identity.

Why (2026-11-18): a trial `--from` a checkpoint used to fork the save under a new guid and name (quest_clone.fork), on
whatever world the window had restored. Since containers show their owner truthfully, the near-home job N1 ("put
twenty ash logs and ten stone in a chest at your base") failed on its setup: in a restored world nothing was the new
guid's; he refused ClaudeDev's crates or built his own and ran out of time (runs 20261118-052749, -053829-N1-I2). The
game was right; the harness gave a fork a base that belonged to another character.

    keep     (`--save-as LABEL`, after a trial that ends as --until asks): wait until the game has written BOTH his
             character save and the world save after the trial ended (the body stands idle meanwhile, so the two
             are one moment: the dev server's world autosave and the client save run on separate 5-minute clocks,
             about a minute apart, server log 2026-11-18), stop the client and the server (-Hold), keep the world as
             the snapshot ck-LABEL (tools/world_snapshot.py), start the server again, and write
             logs/quests/checkpoints/LABEL.json (the save, byte for byte) with LABEL.world.json beside it (the pair:
             his guid and name, the save's sha256, the world's label, both save times). A pair or nothing: when the
             world cannot be kept, no checkpoint is written.
    prepare  (each trial `--from LABEL` when LABEL is a pair): stop the client (-Hold) and the server (-Hold), park
             whatever SaveCharacters holds under his name (with the game's .backup: the record of where the last
             trial ended, logs/quests/forks/<name>.<utc>.json), restore ck-LABEL, write the checkpoint's save back
             as SaveCharacters/<name>.json under the SAME guid and name, forget his deaths after the checkpoint (the
             client's last_death.json, one file for every character: a grave from an earlier trial is not in the
             restored world), start the server. The window then switches to <name> as for any character.
    A job's start (`--from ClaudeDev`, or any save with no LABEL.world.json) still forks freshly (quest_clone.fork).

Why the same guid is safe here: the dev server keeps its own copy of each character it has seen, by guid, in the world
save (CachedCharacterStates). A restored pair holds that copy as of the checkpoint, and the file the client brings is
the checkpoint's save, so whichever of the two the server takes on join (DISCOVERIES 2026-11-16 "a save edited under
the same guid is ignored" vs 2026-11-17 "the client's copy wins on join") he starts as the checkpoint saw him. Never
two live copies of his guid: the save is written only with the client stopped, and a second file in SaveCharacters
with his guid under another name refuses the trial before anything is stopped. ClaudeDev.json is never written.
"""
from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from tools import world_snapshot as ws

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = "dw_checkpoint_pair/1"
PREFIX = "ck-"                       # the world snapshot of checkpoint LABEL is ck-LABEL
SIDE = ".world.json"                 # logs/quests/checkpoints/LABEL.world.json: the pair
DEATH_FILE = ROOT / "client_io" / "state" / "last_death.json"  # client_mod/scripts/skills.lua M.DEATH_FILE
PROTECTED = ("ClaudeDev", "Claude")  # main characters: their files are never written here
CLIENT_IMAGES = ("rsdragonwilds.exe", "rsdragonwilds-win64-shipping.exe")
PAIR_S = 90.0      # a window's budget per trial for the stop, restore and start (to be measured in the first window)
POLL_S = 5.0
Refused = ws.Refused


def world_label(label: str) -> str:
    w = PREFIX + str(label or "")
    if not ws.LABEL_RE.fullmatch(w):
        raise Refused(f"checkpoint label {label!r} cannot name a world snapshot ({w!r}: letters, digits, _ and -, "
                      f"at most {40 - len(PREFIX)} for a checkpoint)")
    return w


def client_running() -> bool | None:
    """Whether a game CLIENT process is alive (world_snapshot's Toolhelp read), None when the list is unreadable."""
    names = ws.live_images()
    if names is None:
        return None
    return any(n.lower() in CLIENT_IMAGES for n in names)


def _powershell(script: str, *args: str) -> int:
    """The real stop and start scripts. Never from a test: a test that reaches here has missed a fake, and would
    stop the live client and server."""
    if os.environ.get("PYTEST_CURRENT_TEST"):
        raise RuntimeError(f"checkpoint_pair: refusing to run {script} under pytest (fake Pairs.ps)")
    from evals.bench.devchar import powershell
    return powershell(script, *args, timeout=300)


def _meta(raw: bytes) -> dict:
    return (json.loads(raw.decode("utf-8-sig")).get("meta_data") or {})


def _sha(raw: bytes) -> str:
    import hashlib
    return hashlib.sha256(raw).hexdigest()


def _write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def _iso(t: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


@dataclass
class Pairs:
    store: ws.Store = field(default_factory=ws.default_store)
    checkpoint_dir: Path = field(default_factory=lambda: _qc().CHECKPOINT_DIR)
    save_dir: Path = field(default_factory=lambda: _qc().SAVE_DIR)
    park_dir: Path = field(default_factory=lambda: _qc().PARK_DIR)
    death_file: Path = DEATH_FILE
    ps: Callable[..., int] = _powershell
    client_running: Callable[[], bool | None] = client_running
    sleep: Callable[[float], None] = time.sleep
    clock: Callable[[], float] = time.time
    own_pid: int = field(default_factory=os.getpid)

    # ------------------------------------------------------------------------------------------------ reading
    def sidecar(self, label: str) -> Path:
        return self.checkpoint_dir / f"{label}{SIDE}"

    def read(self, label: str) -> dict | None:
        """The pair of checkpoint LABEL; None when LABEL has no pair (a plain checkpoint, a save name, ClaudeDev).
        A pair that does not hold together is refused, never taken for a plain fork: that would quietly give the
        trial a new guid in a world where nothing is his, the fault this module is for."""
        side = self.sidecar(label)
        if not side.is_file():
            return None
        try:
            pair = json.loads(side.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise Refused(f"checkpoint {label!r}: {side.name} does not read as JSON") from None
        if not isinstance(pair, dict) or pair.get("schema") != SCHEMA:
            raise Refused(f"checkpoint {label!r}: {side.name} is not a {SCHEMA} pair")
        ck = self.checkpoint_dir / f"{label}.json"
        try:
            raw = ck.read_bytes()
        except OSError:
            raise Refused(f"checkpoint {label!r}: {ck.name} is missing beside its pair") from None
        if _sha(raw) != pair.get("char_sha256"):
            raise Refused(f"checkpoint {label!r}: {ck.name} does not match the sha256 its pair recorded")
        meta = _meta(raw)
        if str(meta.get("char_guid") or "").upper() != pair.get("char_guid") or meta.get("char_name") != pair.get("char_name"):
            raise Refused(f"checkpoint {label!r}: the save's guid or name is not the pair's")
        self.store.manifest(pair.get("world") or "")  # Refused: "no snapshot ..."
        return pair

    def world_saved_at(self) -> float | None:
        """When the server last wrote the world save (the newest SaveGames/*.sav)."""
        d = self.store.saved / self.store.dirs[0]
        times = [p.stat().st_mtime for p in d.glob("*.sav")] if d.is_dir() else []
        return max(times) if times else None

    def guid_elsewhere(self, guid: str, name: str) -> list[str]:
        """Files in SaveCharacters, other than <name>'s own, that hold this guid (a second live copy of him)."""
        out = []
        for p in sorted(self.save_dir.glob("*.json*")) if self.save_dir.is_dir() else []:
            if not (p.name.endswith(".json") or p.name.endswith(".json.backup")) or p.name.split(".")[0] == name:
                continue
            try:
                if str(_meta(p.read_bytes()).get("char_guid") or "").upper() == guid:
                    out.append(p.name)
            except (OSError, ValueError, AttributeError):
                continue
        return out

    def precheck(self, pair: dict, others_ok: str = "") -> list[str]:
        """Why a trial from this pair must not start ([] = it may), read before anything is stopped."""
        why = []
        name, guid = pair.get("char_name") or "", str(pair.get("char_guid") or "").upper()
        if name in PROTECTED:
            why.append(f"the pair names {name}: a main character's save is never written here")
        dup = self.guid_elsewhere(guid, name)
        if dup:
            why.append(f"another file holds his guid {guid}: {', '.join(dup)} (never two copies of one character)")
        man = self.store.manifest(pair["world"])
        seen = self.store.others_since(man.get("taken_at"))
        if seen["others"] and not others_ok:
            names = ", ".join(sorted({n for _, n in seen["others"]}))
            why.append(f"{names} joined the server after {pair['world']} was kept: its restore rolls their character "
                       "back too; Luis's call (--others-ok with his words)")
        return why

    # ------------------------------------------------------------------------------------------------ writing
    def keep(self, label: str, name: str, t_end: float, wait_s: float, note: str = "", window: str = "") -> dict:
        """Keep checkpoint LABEL as a pair from <name>'s next saves after t_end. -> {kept: True, **pair} or
        {kept: False, why}. Refused (before any wait) when the label or its world is taken."""
        wl = world_label(label)
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", label):
            raise Refused(f"checkpoint label {label!r} is not a plain name")
        ck = self.checkpoint_dir / f"{label}.json"
        if ck.exists() or self.sidecar(label).exists() or (self.store.root / wl).exists():
            raise Refused(f"checkpoint {label!r} (or its world {wl}) exists: a label is never overwritten")
        live = self.save_dir / f"{name}.json"
        end = self.clock() + wait_s

        def char_at() -> float:
            return live.stat().st_mtime if live.is_file() else 0.0
        while char_at() <= t_end or (self.world_saved_at() or 0.0) <= t_end:
            if self.clock() >= end:
                late = [w for w, ok in (("character save", char_at() > t_end),
                                        ("world save", (self.world_saved_at() or 0.0) > t_end)) if not ok]
                return {"kept": False, "why": f"no {' and no '.join(late)} after the trial ended within {wait_s:.0f} s"}
            self.sleep(POLL_S)
        raw = b""
        for _ in range(5):  # the game may be mid-write: only a save that reads whole is kept
            raw = live.read_bytes()
            try:
                meta = _meta(raw)
                break
            except ValueError:
                self.sleep(1.0)
        else:
            return {"kept": False, "why": f"{live.name} did not read whole"}
        if meta.get("char_name") != name:
            return {"kept": False, "why": f"{live.name} is the save of {meta.get('char_name')!r}, not {name}"}
        char_at_s, world_at_s = char_at(), self.world_saved_at()
        self.ps("stop_client.ps1", "-Hold")  # no copy of him in play while the world is copied
        if self.client_running() is not False:
            return {"kept": False, "why": "the client did not stop: the world was not copied"}
        self.ps("stop_server.ps1", "-Hold")
        try:
            man = self.store.keep(wl, note=f"world of checkpoint {label} ({name}){': ' + note if note else ''}")
        except Refused as exc:
            return {"kept": False, "why": f"world not kept: {exc}"}
        finally:
            self.ps("start_server.ps1")
        pair = {"schema": SCHEMA, "label": label, "world": wl, "char_name": name,
                "char_guid": str(meta.get("char_guid") or "").upper(), "char_sha256": _sha(raw),
                "char_saved_at": round(char_at_s, 3), "world_saved_at": round(world_at_s or 0.0, 3),
                "t_end": round(t_end, 3), "window": window, "note": note, "kept_at": _iso(self.clock()),
                "build": man.get("build")}
        _write(ck, raw)
        _write(self.sidecar(label), json.dumps(pair, indent=1).encode("utf-8"))
        return {"kept": True, **pair}

    def park(self, name: str, stamp: str) -> list[str]:
        """Move SaveCharacters/<name>.json and its .backup to the park folder under <name>.<stamp>.*."""
        moved = []
        if name in PROTECTED:
            return moved
        for suffix in (".json", ".json.backup"):
            src = self.save_dir / f"{name}{suffix}"
            if src.is_file():
                self.park_dir.mkdir(parents=True, exist_ok=True)
                dest = self.park_dir / f"{name}.{stamp}{suffix}"
                os.replace(src, dest)
                moved.append(dest.name)
        return moved

    def forget_deaths(self, guid: str, after: float) -> list[dict]:
        """Drop from the client's death file the records of this guid made after `after` (an earlier trial's graves:
        not in the restored world). Other characters' records and his own before the checkpoint stay."""
        try:
            doc = json.loads(self.death_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []
        rows = doc.get("deaths") if isinstance(doc, dict) else None
        if not isinstance(rows, list):
            return []

        def later(r) -> bool:
            return (isinstance(r, dict) and str(r.get("character_guid") or "").upper() == guid
                    and isinstance(r.get("ts"), (int, float)) and r["ts"] > after)
        gone = [r for r in rows if later(r)]
        if gone:
            doc["deaths"] = [r for r in rows if not later(r)]
            _write(self.death_file, json.dumps(doc).encode("utf-8"))
        return gone

    def prepare(self, pair: dict, others_ok: str = "", stamp: str | None = None) -> dict:
        """Set up one trial from the pair (see the module doc). The server is running again when this returns or
        raises, except when a torn world could not be put back (then it stays down, and says so)."""
        name, guid = pair.get("char_name") or "", str(pair.get("char_guid") or "").upper()
        if name in PROTECTED or not name:
            raise Refused(f"the pair names {name or 'nobody'}: a main character's save is never written here")
        why = self.precheck(pair, others_ok)
        if why:
            raise Refused("; ".join(why))
        raw = (self.checkpoint_dir / f"{pair['label']}.json").read_bytes()
        if _sha(raw) != pair.get("char_sha256"):
            raise Refused(f"checkpoint {pair['label']!r} changed since its pair was kept")
        stamp = stamp or time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(self.clock()))
        t0 = self.clock()
        self.ps("stop_client.ps1", "-Hold")
        if self.client_running() is not False:
            raise Refused(f"the client did not stop: {name}'s save is not written while a client may hold it")
        self.ps("stop_server.ps1", "-Hold")
        try:
            parked = self.park(name, stamp)
            restored = self.store.restore(pair["world"], others_ok, own_pid=self.own_pid)
        except Refused as exc:
            undo = getattr(exc, "undo", None)
            if undo:  # the world was touched: put it back as it was before this restore
                try:
                    self.store.restore(undo, own_pid=self.own_pid, undo=False)
                except Refused as exc2:
                    raise Refused(f"{exc}; putting {undo} back failed too ({exc2}): the server is left DOWN on a "
                                  f"torn world; restore {undo} by hand, then start_server.ps1") from exc
            self.ps("start_server.ps1")
            raise
        try:
            live = self.save_dir / f"{name}.json"
            _write(live, raw)
            if _sha(live.read_bytes()) != pair["char_sha256"]:
                raise Refused(f"{live} does not hash as the checkpoint after the write")
            deaths = self.forget_deaths(guid, float(pair.get("char_saved_at") or 0.0))
        finally:
            self.ps("start_server.ps1")
        return {"name": name, "guid": guid, "world": pair["world"], "restored": restored, "parked": parked,
                "deaths_forgotten": deaths, "s": round(self.clock() - t0, 1), "written_at": round(t0, 3)}

    def file_check(self, pair: dict, written_at: float) -> dict:
        """After the switch: is SaveCharacters/<name>.json still the checkpoint's bytes? The client writes a save
        only every 5 minutes, so a different file soon after the join was put there by something else (Steam Cloud
        is off on this account; this is the line that shows it if that ever changes). Recorded, not refused."""
        live = self.save_dir / f"{pair['char_name']}.json"
        try:
            raw, mtime = live.read_bytes(), live.stat().st_mtime
        except OSError:
            return {"sha_ok": False, "why": f"{live.name} is gone"}
        return {"sha_ok": _sha(raw) == pair["char_sha256"], "rewritten_after_s": round(mtime - written_at, 1)}


def _qc():
    from tools import quest_clone
    return quest_clone


def default_pairs() -> Pairs:
    return Pairs()


def window_pair(ref: str, others_ok: str = "", save_as: str | None = None,
                pairs: Pairs | None = None) -> tuple[Pairs, dict | None, str | None]:
    """A window's look at its start before the lock: (pairs, the pair of `ref` or None, why it must not run or None).
    Also checks that --save-as can name a pair (its label fits a world snapshot and is not taken)."""
    pairs = pairs or default_pairs()
    try:
        pair = pairs.read(ref)
        why = pairs.precheck(pair, others_ok) if pair else []
        if save_as:
            wl = world_label(save_as)
            if (pairs.store.root / wl).exists() or pairs.sidecar(save_as).exists():
                why.append(f"--save-as {save_as}: its pair or world {wl} exists already")
    except Refused as exc:
        return pairs, None, str(exc)
    return pairs, pair, "; ".join(why) or None


def start_character(ref: str, name: str, pair: dict | None, pairs: Pairs | None, fork: Callable[[str, str], object],
                    others_ok: str = "", stamp: str | None = None) -> dict:
    """The character a trial plays: from a pair, the pair's own character set up by Pairs.prepare (its name, not
    `name`); else a fresh fork of `ref` under `name` (a job's start, a plain checkpoint)."""
    if pair is not None:
        prep = pairs.prepare(pair, others_ok, stamp)
        return {"name": prep["name"], "paired": True, "prep": prep}
    fork(ref, name)
    return {"name": name, "paired": False}


def identity_fault(made: dict | None, pair: dict | None) -> str | None:
    """Why the character on the server is not the pair's (the switch's `made` row), or None."""
    if pair is None:
        return None
    got = str((made or {}).get("guid") or "").upper()
    if got != pair["char_guid"]:
        return (f"the server lists {pair['char_name']} under guid {got or 'none'}, not the checkpoint's "
                f"{pair['char_guid']}: not the checkpoint's character")
    return None

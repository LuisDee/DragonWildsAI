"""Server-authoritative combat evidence from the dev server's own log (docs/design/combat-basics-live.md §3).

The dedicated server logs category EvadeAttack at Verbose (already on for dev):
  TryPerformAttack() : [...] <AI> starting attack on authority against player <pawn> with id N    -> telegraph
  PredictPointDamage() : [...] <pawn> evaded D damage at T from <AI>                               -> a dodge
  PredictPointDamage() : [...] <pawn> will receive D damage at T from <src>                        -> a hit (count only)
The client-side referee hooks miss the dodges (combat agent, 2026-10-26), so on dev these lines are THE source for
`telegraph` and `defended how=dodge`; the client hooks' telegraph / dodge events are dropped while the log is read so
nothing is counted twice. Parry and block keep the hook events until their server wording is captured (§3: the
PredictPointDamage reduced-amount line or Multicast_NotifyActorsToDamagePending{Blocked,Parried}Attack).

Timestamps: Unreal log lines carry UTC ("[2026.10.26-07.34.19:450]"), converted to epoch seconds for the leaves.
"""
from __future__ import annotations

import calendar
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

SERVER_ROOT = Path(os.environ.get("DW_SERVER_ROOT", r"C:\GameServers\Dragonwilds"))
SERVER_LOG = SERVER_ROOT / "RSDragonwilds" / "Saved" / "Logs" / "RSDragonwilds.log"

_TS = re.compile(r"^\[(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2}):(\d{3})\]")
_ATTACK = re.compile(r"TryPerformAttack\(\) : \[[^\]]*\] (\S+) starting attack on authority against player (\S+) with id (\d+)")
_DAMAGE = re.compile(r"PredictPointDamage\(\) : \[[^\]]*\] (\S+) (evaded|will receive) ([\d.]+) damage at [\d.]+ from (\S+?)\.?$")
PENDING_S = 6.0  # a dodge resolves the attacker's most recent telegraph at him within this window
SOURCE_KINDS = {"telegraph"}  # kinds this source replaces wholesale; `defended` is replaced only for how in DODGE_HOWS
DODGE_HOWS = {None, "dodge"}


def ts(line: str) -> float | None:
    m = _TS.match(line)
    if not m:
        return None
    y, mo, d, h, mi, s, ms = (int(x) for x in m.groups())
    return calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0)) + ms / 1000.0


def kind_id(obj_name: str) -> str:
    """BP_AI_Kebbit_Character_02_C_2147450642 -> BP_AI_Kebbit_Character_02_C (the class word, as the referee uses)."""
    return re.sub(r"_\d+$", "", obj_name)


@dataclass
class ServerLogReferee:
    """Tails the dev server log from referee start; `pawn` = his object name (from the referee's start reply)."""
    path: Path = SERVER_LOG
    pawn: str | None = None
    off: int = 0
    pending: dict[str, tuple[float, str]] = field(default_factory=dict)  # attacker -> (t, attack id) at him
    lines_read: int = 0

    def start(self, pawn: str | None) -> None:
        self.pawn = pawn
        self.pending.clear()
        self.off = self.path.stat().st_size if self.path.exists() else 0

    @property
    def active(self) -> bool:
        return bool(self.pawn) and self.path.exists()

    def read(self) -> list[dict]:
        if not self.active:
            return []
        size = self.path.stat().st_size
        if size < self.off:  # the server restarted and the log rotated
            self.off = 0
        with open(self.path, "rb") as f:
            f.seek(self.off)
            data = f.read()
        cut = data.rfind(b"\n") + 1  # a half-written last line waits for the next read
        self.off += cut
        return self.parse(data[:cut].decode("utf-8", "replace").splitlines())

    def parse(self, lines: list[str]) -> list[dict]:
        out: list[dict] = []
        for line in lines:
            if "EvadeAttack" not in line:
                continue
            self.lines_read += 1
            t = ts(line) or time.time()
            m = _ATTACK.search(line)
            if m:
                ai, target, aid = m.groups()
                me = target == self.pawn
                if me:
                    self.pending[ai] = (t, aid)
                out.append({"kind": "telegraph", "t": t, "attacker": ai, "kind_id": kind_id(ai), "attack_id": aid,
                            "target": "self" if me else kind_id(target), "source": "server_log"})
                continue
            m = _DAMAGE.search(line)
            if not m or m.group(1) != self.pawn:
                continue
            _, verb, amount, src = m.groups()
            p = self.pending.pop(src, None)
            tele = p is not None and t - p[0] <= PENDING_S
            if verb == "evaded":
                out.append({"kind": "defended", "t": t, "how": "dodge", "outcome": "dodged", "telegraphed": tele,
                            "direction_ok": True,  # the server judged the evade successful (no damage applied)
                            "attack_id": p[1] if tele else None, "attacker_kind": kind_id(src), "source": "server_log"})
            else:
                out.append({"kind": "hit_taken", "t": t, "amount": float(amount), "by_kind": kind_id(src),
                            "telegraphed": tele, "attack_id": p[1] if tele else None, "source": "server_log"})
        return out


def merge(hook_events: list[dict], log_events: list[dict], log_active: bool) -> list[dict]:
    """While the server log is read, it owns telegraphs and dodges; the hooks keep everything else."""
    if not log_active:
        return hook_events
    kept = [e for e in hook_events if not (e.get("kind") in SOURCE_KINDS
                                           or (e.get("kind") == "defended" and e.get("how") in DODGE_HOWS))]
    return sorted(kept + log_events, key=lambda e: float(e.get("t") or 0))

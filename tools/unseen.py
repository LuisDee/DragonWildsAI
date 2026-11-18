"""The unseen-fix ledger: every fix committed on tests alone gets ONE row with a log signature, a regex that shows up
in the client, brain or watchdog log only when the changed path ran. `scan` counts the log lines after the commit that
match it, so a fix nobody has seen run in a live window stays visible until someone confirms or bins it.

    .venv\\Scripts\\python.exe -m tools.unseen add HASH --look REGEX --log client|brain|watchdog [--note TEXT]
    .venv\\Scripts\\python.exe -m tools.unseen scan                       # hits per open row since its commit
    .venv\\Scripts\\python.exe -m tools.unseen confirm HASH --evidence "PROGRESS 2026-11-17, window s31"
    .venv\\Scripts\\python.exe -m tools.unseen bin HASH --why "reverted in abc1234"
    .venv\\Scripts\\python.exe -m tools.unseen report                     # open rows oldest first; exit 1 over the cap

An exposure (the path ran) is not a confirmation (it held): `scan` only reports and writes nothing. A person reads the
window and confirms or bins. The ledger is docs/unseen_fixes.jsonl (committed: logs/ is not).

The logs and their clocks (read from the data, 2026-11-17):
- client: logs/client/client.log and any rotated sibling (client*.log*). Every line starts with a UTC stamp,
  2026-11-17T13:57:12Z, to the second. A line with no stamp belongs to the stamped line above it.
- brain: logs/brain-*.jsonl (brain-live-YYYYMMDD-HHMMSS-PID.jsonl per brain start, brain-YYYYMMDD.jsonl for the
  harness's own bridge traffic). Every row starts with "ts", epoch seconds, so it needs no timezone. The time in a
  file's NAME is the VM's local time (W. Europe Standard Time, UTC+1): in all 623 brain-live files the name is 1.0 h
  ahead of the first row. The name is not used here; a file last written before the oldest open commit is skipped.
A body result is in the brain log several times (bridge_recv, tool_result, then every prompt that repeats it), so one
run of a path can be several hits. Anchor a signature for a body result on the row every reply arrives in once
("kind": "bridge_recv".*the words) to count runs and not echoes.
- watchdog: logs/client_watchdog.jsonl (the client watchdog's events) and logs/client/boot.log (client_boot.ps1's
  lines), and any rotated sibling of either. Both are PowerShell's, with a BOM at the top. An event row starts with
  "ts", an ISO time in UTC with 7 decimals ({"ts":"2026-11-18T13:08:58.5908977Z",...}); a boot line starts with an
  ISO time with the VM's offset (2026-11-18T14:13:57.5024686+01:00). A boot line with no time takes the one above.
"""
from __future__ import annotations

import argparse
import calendar
import gzip
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path

from brain import childproc

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "docs" / "unseen_fixes.jsonl"
CLIENT_DIR = ROOT / "logs" / "client"
BRAIN_DIR = ROOT / "logs"
LOGS = ("client", "brain", "watchdog")
CAP = 8  # more open rows than this: confirm or bin before a new fix
SAMPLE = 200  # a sample line is cut to this many characters

_STAMP = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")  # a client line's own time (UTC)
_TS = re.compile(r'\{\s*"ts":\s*(\d+(?:\.\d+)?)')  # a brain row's own time (epoch seconds)
# a watchdog event's "ts" or a boot line's head: an ISO time with decimals and a zone (Z or an offset)
_ISO = re.compile(r'(?:\{\s*"ts":\s*")?(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d))')


def rows(path: Path | None = None) -> list[dict]:
    path = path or LEDGER  # read at call time: tests point LEDGER elsewhere
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _write(rs: list[dict], path: Path | None = None) -> None:
    (path or LEDGER).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rs), encoding="utf-8", newline="\n")


def iso(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def epoch(stamp: str) -> int:
    return calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))


def commit(ref: str) -> tuple[str, str, int]:
    """(short hash, subject, commit time in epoch seconds) of a commit, read from git (read only)."""
    out = childproc.run(["git", "-C", str(ROOT), "show", "-s", "--format=%h%x00%s%x00%ct", ref + "^{commit}"],
                        capture_output=True, text=True, encoding="utf-8")
    if out.returncode != 0:
        raise SystemExit(f"git does not know {ref}: {out.stderr.strip()}")
    h, subject, ct = out.stdout.strip().split("\x00")
    return h, subject, int(ct)


def find(rs: list[dict], ref: str) -> dict | None:
    """The row of a hash, written short or long."""
    ref = ref.strip().lower()
    return next((r for r in rs if ref and (r["hash"].startswith(ref) or ref.startswith(r["hash"]))), None)


def add(ref: str, look: str, log: str, note: str | None = None, path: Path | None = None) -> dict:
    """A new open row. Refuses a hash already in the ledger and a regex that does not compile."""
    if log not in LOGS:
        raise SystemExit(f"--log is one of {', '.join(LOGS)}")
    try:
        re.compile(look)
    except re.error as e:
        raise SystemExit(f"the regex does not compile: {e}")
    h, subject, ct = commit(ref)  # (looked up at call time: tests put a fake in its place)
    rs = rows(path)
    if find(rs, h) or find(rs, ref):
        raise SystemExit(f"{h} is already in the ledger")
    row = {"hash": h, "subject": subject, "time": iso(ct), "look": look, "log": log, "note": note or "", "state": "open"}
    _write(rs + [row], path)
    return row


def settle(ref: str, state: str, text: str, path: Path | None = None, today: str | None = None) -> dict:
    """confirm (it held, with the evidence) or bin (dropped, with why): the state, the text and the date."""
    rs = rows(path)
    r = find(rs, ref)
    if not r:
        raise SystemExit(f"{ref} is not in the ledger")
    r["state"] = state
    r["evidence" if state == "confirmed" else "why"] = text
    r["date"] = today or time.strftime("%Y-%m-%d", time.gmtime())
    _write(rs, path)
    return r


def log_files(log: str, client_dir: Path | None = None, brain_dir: Path | None = None) -> list[Path]:
    if log == "client":
        return sorted((client_dir or CLIENT_DIR).glob("client*.log*"))  # client.log and its rotated siblings
    if log == "watchdog":  # BRAIN_DIR is logs/, where the watchdog's events are written too
        return (sorted((brain_dir or BRAIN_DIR).glob("client_watchdog*.jsonl*"))
                + sorted((client_dir or CLIENT_DIR).glob("boot*.log*")))
    return sorted((brain_dir or BRAIN_DIR).glob("brain-*.jsonl"))


def _open(p: Path):
    if p.suffix == ".gz":
        return gzip.open(p, "rt", encoding="utf-8-sig", errors="replace")
    return p.open("r", encoding="utf-8-sig", errors="replace")  # -sig: PowerShell's logs begin with a BOM


def lines(p: Path, log: str):
    """(epoch seconds, line) for each line of a log, one at a time: the file is never held whole. A client line's
    or watchdog line's stamp is kept as text and turned to seconds once per new stamp."""
    with _open(p) as f:
        if log == "brain":
            for line in f:
                m = _TS.match(line)
                if m:
                    yield float(m.group(1)), line
            return
        rx = _ISO if log == "watchdog" else _STAMP
        stamp, at = None, None
        for line in f:
            m = rx.match(line)
            if m and m.group(m.lastindex or 0) != stamp:
                stamp = m.group(m.lastindex or 0)
                at = datetime.fromisoformat(stamp).timestamp() if log == "watchdog" else epoch(stamp)
            if at is not None:
                yield at, line


def _sample(line: str, m: re.Match) -> str:
    """The line cut to SAMPLE characters, with the end of the match in it: a brain row can be 100 KB of prompt, and a
    signature anchored on the row's kind ends at the telling words."""
    line = line.rstrip("\r\n")
    start = 0 if m.end() <= SAMPLE else m.end() + 40 - SAMPLE
    return ("..." if start else "") + line[start:start + SAMPLE]


def scan(rs: list[dict], client_dir: Path | None = None, brain_dir: Path | None = None) -> list[dict]:
    """For every open row: the log lines after its commit's time that match its regex. -> [{hash, log, hits, first,
    last, sample, files}], in the ledger's order. Writes nothing."""
    out = []
    for log in LOGS:
        todo = [{"hash": r["hash"], "log": log, "since": epoch(r["time"]), "rx": re.compile(r["look"]), "hits": 0,
                 "first": None, "last": None, "sample": None} for r in rs if r.get("state") == "open" and r.get("log") == log]
        if not todo:
            continue
        oldest = min(t["since"] for t in todo)
        files = [p for p in log_files(log, client_dir, brain_dir) if p.stat().st_mtime > oldest]
        for p in files:
            for at, line in lines(p, log):
                if at <= oldest:
                    continue
                for t in todo:
                    if at <= t["since"]:
                        continue
                    m = t["rx"].search(line)
                    if not m:
                        continue
                    t["hits"] += 1
                    if t["first"] is None or at < t["first"]:
                        t["first"], t["sample"] = at, _sample(line, m)
                    if t["last"] is None or at > t["last"]:
                        t["last"] = at
        for t in todo:
            del t["rx"], t["since"]
            t["files"] = len(files)
            t["first"], t["last"] = (iso(t["first"]) if t["first"] else None), (iso(t["last"]) if t["last"] else None)
        out += todo
    order = {r["hash"]: i for i, r in enumerate(rs)}
    return sorted(out, key=lambda t: order[t["hash"]])


def report(rs: list[dict], now: float | None = None) -> tuple[list[dict], dict, bool]:
    """(open rows oldest first, each with age_h; counts by state; over the cap?)"""
    now = time.time() if now is None else now
    opened = sorted((r for r in rs if r.get("state") == "open"), key=lambda r: r["time"])
    opened = [{**r, "age_h": round((now - epoch(r["time"])) / 3600, 1)} for r in opened]
    counts = {s: sum(1 for r in rs if r.get("state") == s) for s in ("open", "confirmed", "binned")}
    return opened, counts, counts["open"] > CAP


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    n = sub.add_parser("add")
    n.add_argument("hash")
    n.add_argument("--look", required=True, help="a regex that is logged only when the changed path runs")
    n.add_argument("--log", required=True, choices=LOGS)
    n.add_argument("--note")
    sub.add_parser("scan")
    c = sub.add_parser("confirm")
    c.add_argument("hash")
    c.add_argument("--evidence", required=True, help="where it was seen to hold (a PROGRESS entry, a window, a run)")
    b = sub.add_parser("bin")
    b.add_argument("hash")
    b.add_argument("--why", required=True)
    sub.add_parser("report")
    a = ap.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")  # a log line may hold what the console's code page lacks
    if a.cmd == "add":
        r = add(a.hash, a.look, a.log, a.note)
        print(f"{r['hash']} {r['time']} {r['subject']}")
        print(f"open: {report(rows())[1]['open']} (cap {CAP})")
    elif a.cmd == "scan":
        rs = rows()
        by = {r["hash"]: r for r in rs}
        res = scan(rs)
        print(f"{'hash':<8} {'log':<8} {'hits':>5}  {'first':<20} {'last':<20} subject")
        for t in res:
            print(f"{t['hash']:<8} {t['log']:<8} {t['hits']:>5}  {t['first'] or '-':<20} {t['last'] or '-':<20} "
                  f"{by[t['hash']]['subject'][:70]}")
            if t["sample"]:
                print(f"{'':<8} {t['sample']}")
        ran = sum(1 for t in res if t["hits"])
        print(f"{len(res)} open row(s): {ran} with hits since the commit (the path ran; whether it held is for a "
              f"person to say), {len(res) - ran} with none")
    elif a.cmd in ("confirm", "bin"):
        r = settle(a.hash, "confirmed" if a.cmd == "confirm" else "binned", a.evidence if a.cmd == "confirm" else a.why)
        print(f"{r['hash']} {r['state']} {r['date']}: {r.get('evidence') or r.get('why')}")
    else:
        opened, counts, over = report(rows())
        print(f"{'age_h':>6}  {'hash':<8} {'log':<8} subject")
        for r in opened:
            print(f"{r['age_h']:>6}  {r['hash']:<8} {r['log']:<8} {r['subject'][:90]}")
            if r.get("note"):
                print(f"{'':>6}  {'':<8} note: {r['note'][:SAMPLE]}")
        print(f"{counts['open']} open (cap {CAP}), {counts['confirmed']} confirmed, {counts['binned']} binned")
        if over:
            print("over the cap: confirm or bin before a new fix")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

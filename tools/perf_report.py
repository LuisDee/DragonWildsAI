"""Lag report: is it the server or the network?

Joins three sources over a time window (default: the last 60 minutes) into a per-minute timeline
and a verdict:
  * logs/perf/mod_perf.jsonl      game-thread frame times + player pings (mod/scripts/perf_sampler.lua)
  * logs/perf/host_counters*.csv  Windows counters from logman (tools/perf_counters.ps1)
  * the server log                RSDragonwilds.log (+ rotated backups): ServerMove "TimeStamp expired",
                                  hitch lines, net warnings / connection closes, autosaves, and a tick
                                  rate derived from the log's own frame counter ([hh.mm.ss:ms][fff]).

  .venv\\Scripts\\python.exe -m tools.perf_report                 # last 60 min
  .venv\\Scripts\\python.exe -m tools.perf_report --minutes 15
  .venv\\Scripts\\python.exe -m tools.perf_report --since 2026-10-25T13:00 --until 2026-10-25T14:00   # UTC
  .venv\\Scripts\\python.exe -m tools.perf_report --no-timeline

All times are UTC.
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import re
import statistics
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PERF_DIR = REPO / "logs" / "perf"
SERVER_ROOT = Path(os.environ.get("DW_SERVER_ROOT", r"C:\GameServers\Dragonwilds"))
SERVER_LOG_DIR = SERVER_ROOT / "RSDragonwilds" / "Saved" / "Logs"

# ---- thresholds (the verdict uses these; they are printed with it) ----
TICK_TARGET_HZ = 30.0       # measured: the server ticks at ~30 Hz (NetServerMaxTickRate default)
TICK_MIN_HZ = 27.0          # window average below this = server can't keep up
FRAME_SLOW_MS = 50.0        # a frame this long is a visible stutter (1.5 ticks at 30 Hz)
FRAME_HITCH_MS = 100.0      # a hitch: 3+ ticks lost; players see rubber-banding
SLOW_PCT_WARN, SLOW_PCT_BAD = 0.5, 2.0        # % of frames over 50 ms
HITCH_PER_MIN_WARN, HITCH_PER_MIN_BAD = 0.2, 2.0  # frames over 100 ms per minute
CPU_BUSY_PCT = 80.0         # \Processor(_Total)
CORE_BUSY_PCT = 95.0        # any single core
RAM_LOW_MB = 500.0          # \Memory\Available MBytes
PAGES_HIGH = 1000.0         # \Memory\Pages/sec (hard faults)
DISK_LAT_MS = 20.0          # Avg. Disk sec/Transfer
DEFENDER_SPIKE_PCT = 50.0   # MsMpEng % of one core
SATURATED_SAMPLE_PCT = 5.0  # a resource is "saturated" if over threshold in >= this % of samples
PING_HIGH_MS = 150.0
PING_JITTER_MS = 50.0       # max - p50 of a player's ping over the window


def utc(dt: datetime) -> datetime:
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt.astimezone(timezone.utc)


def minute(dt: datetime) -> datetime:
    return dt.replace(second=0, microsecond=0)


def fnum(s):
    try:
        v = float(s)
        return v
    except (TypeError, ValueError):
        return None


# ------------------------------------------------------------------ mod_perf.jsonl
def load_mod(path: Path, t0: datetime, t1: datetime) -> list[dict]:
    out = []
    if not path.exists():
        return out
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "frames" not in r or "t" not in r:
                continue
            ts = datetime.fromtimestamp(r["t"], timezone.utc)
            if t0 <= ts <= t1:
                r["_ts"] = ts
                out.append(r)
    return out


def load_debug_runs(mod_log_dir: Path, t0: datetime, t1: datetime) -> list[tuple[datetime, str]]:
    """debug_run events from the mod's own log: experiments run on the game thread and can hitch it."""
    out = []
    for p in mod_log_dir.glob("mod_*.jsonl"):
        if datetime.fromtimestamp(p.stat().st_mtime, timezone.utc) < t0:
            continue
        with p.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"debug_run"' not in line:
                    continue
                try:
                    r = json.loads(line)
                    ts = utc(datetime.strptime(r["ts"], "%Y-%m-%dT%H:%M:%SZ"))
                except (json.JSONDecodeError, KeyError, ValueError):
                    continue
                if r.get("event") == "debug_run" and t0 - timedelta(seconds=30) <= ts <= t1:
                    out.append((ts, str((r.get("data") or {}).get("module"))))
    return sorted(out)


def attribute(t: datetime, debug_runs, saves) -> str | None:
    """Best-effort cause of a hitch at t (second resolution, logged at the end of the long frame)."""
    for dur, start in saves:
        if start - timedelta(seconds=3) <= t <= start + timedelta(seconds=dur + 3):
            return "autosave"
    for ts, mod in debug_runs:
        # perf_sampler's own arm/status calls are a few ms; ignore them as causes.
        if mod != "perf_sampler" and ts - timedelta(seconds=1) <= t <= ts + timedelta(seconds=5):
            return f"debug_run:{mod}"
    return None


# ------------------------------------------------------------------ host CSV (logman)
HOST_COLS = {
    "cpu": r"\\Processor\(_Total\)\\% Processor Time$",
    "core": r"\\Processor\(\d+\)\\% Processor Time$",
    "queue": r"\\System\\Processor Queue Length$",
    "avail_mb": r"\\Memory\\Available MBytes$",
    "pages": r"\\Memory\\Pages/sec$",
    "disk_time": r"\\PhysicalDisk\(_Total\)\\% Disk Time$",
    "disk_lat": r"\\PhysicalDisk\(_Total\)\\Avg\. Disk sec/Transfer$",
    "net": r"\\Network Interface\(.*\)\\Bytes Total/sec$",
    "udp": r"\\UDPv4\\Datagrams/sec$",
    "udp_err": r"\\UDPv4\\Datagrams Received Errors$",
    "srv_cpu": r"\\Process\(RSDragonwildsServer[^)]*\)\\% Processor Time$",
    "srv_ws": r"\\Process\(RSDragonwildsServer[^)]*\)\\Working Set$",
    "srv_io": r"\\Process\(RSDragonwildsServer[^)]*\)\\IO Data Bytes/sec$",
    "def_cpu": r"\\Process\(MsMpEng\)\\% Processor Time$",
    "def_io": r"\\Process\(MsMpEng\)\\IO Data Bytes/sec$",
    "py_cpu": r"\\Process\(python[^)]*\)\\% Processor Time$",
}
SUM_COLS = {"net", "py_cpu"}   # several instances: sum them
MAX_COLS = {"core"}            # several instances: keep the busiest


def load_host(perf_dir: Path, t0: datetime, t1: datetime) -> list[dict]:
    rows = []
    for p in sorted(perf_dir.glob("host_counters*.csv")):
        if datetime.fromtimestamp(p.stat().st_mtime, timezone.utc) < t0 - timedelta(minutes=1):
            continue
        with p.open(newline="", encoding="utf-8", errors="replace") as f:
            rd = csv.reader(f)
            try:
                header = next(rd)
            except StopIteration:
                continue
            m = re.search(r"\((-?\d+)\)\s*$", header[0])   # "(PDH-CSV 4.0) (W. Europe Standard Time)(-60)"
            bias = int(m.group(1)) if m else 0             # UTC = local + bias minutes
            colmap: dict[int, str] = {}
            for i, h in enumerate(header[1:], start=1):
                for key, rx in HOST_COLS.items():
                    if re.search(rx, h, re.I):
                        colmap[i] = key
                        break
            for row in rd:
                if not row:
                    continue
                try:
                    ts = datetime.strptime(row[0], "%m/%d/%Y %H:%M:%S.%f") + timedelta(minutes=bias)
                except ValueError:
                    continue
                ts = ts.replace(tzinfo=timezone.utc)
                if not (t0 <= ts <= t1):
                    continue
                r: dict = {"_ts": ts}
                for i, key in colmap.items():
                    v = fnum(row[i]) if i < len(row) else None
                    if v is None:
                        continue
                    if key in SUM_COLS:
                        r[key] = r.get(key, 0.0) + v
                    elif key in MAX_COLS:
                        r[key] = max(r.get(key, 0.0), v)
                    else:
                        r[key] = v
                if "disk_lat" in r:
                    r["disk_lat"] *= 1000.0      # seconds -> ms
                if "srv_ws" in r:
                    r["srv_ws"] /= 1048576.0     # bytes -> MB
                rows.append(r)
    rows.sort(key=lambda r: r["_ts"])
    # Datagrams Received Errors is a running total: turn it into per-interval deltas.
    prev = None
    for r in rows:
        cur = r.get("udp_err")
        r["udp_err_d"] = (cur - prev) if (cur is not None and prev is not None and cur >= prev) else 0.0
        if cur is not None:
            prev = cur
    return rows


# ------------------------------------------------------------------ server log
LOG_LINE = re.compile(r"^\[(\d{4})\.(\d\d)\.(\d\d)-(\d\d)\.(\d\d)\.(\d\d):(\d{3})\]\[\s*(\d+)\](.*)$")
PATTERNS = {
    "ts_expired": re.compile(r"ServerMove: TimeStamp expired"),
    "hitch": re.compile(r"(?i)\bhitch(?!ThresholdMS)|long frame|took too long|stall(ed)? for"),
    "saturated": re.compile(r"(?i)saturat"),
    "client_adjust": re.compile(r"ClientAdjust"),
    "conn_close": re.compile(r"UNetConnection::Close|ConnectionLost|TIMED OUT|NetworkFailure|ControlChannelClose"),
    "net_warn": re.compile(r"^Log(Net|NetTraffic|NetPlayerMovement|Replication)\w*: (Warning|Error):"),
    "join": re.compile(r"Join succeeded"),
    "save_start": re.compile(r"SaveGameInternal\(\) : Starting save"),
    "save_done": re.compile(r"Save completed SUCCESSFULLY"),
}
EXPIRED_CHAR = re.compile(r"TimeStamp expired.*Character: (\S+)")


@dataclass
class LogStats:
    per_min: dict = field(default_factory=lambda: defaultdict(Counter))
    tick_frames: dict = field(default_factory=lambda: defaultdict(float))
    tick_secs: dict = field(default_factory=lambda: defaultdict(float))
    expired_chars: Counter = field(default_factory=Counter)
    save_durations: list = field(default_factory=list)
    closes: list = field(default_factory=list)
    files: list = field(default_factory=list)


def load_log(log_dir: Path, t0: datetime, t1: datetime) -> LogStats:
    st = LogStats()
    files = sorted(log_dir.glob("RSDragonwilds*.log"), key=lambda p: p.stat().st_mtime)
    for p in files:
        if datetime.fromtimestamp(p.stat().st_mtime, timezone.utc) < t0:
            continue
        st.files.append(p.name)
        prev = None   # (datetime, frame%1000)
        save_t = None
        with p.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                m = LOG_LINE.match(line)
                if not m:
                    continue
                y, mo, d, hh, mi, ss, ms, fr, msg = m.groups()
                ts = datetime(int(y), int(mo), int(d), int(hh), int(mi), int(ss), int(ms) * 1000, timezone.utc)
                fr = int(fr)
                if ts < t0 or ts > t1:
                    prev = (ts, fr)
                    continue
                mk = minute(ts)
                # Tick rate from the log's frame counter (GFrameCounter % 1000). Only short gaps,
                # so the modulo can't wrap more than once at <= 50 Hz.
                if prev is not None:
                    dt = (ts - prev[0]).total_seconds()
                    if 0.3 <= dt <= 15.0:
                        df = (fr - prev[1]) % 1000
                        st.tick_frames[mk] += df
                        st.tick_secs[mk] += dt
                prev = (ts, fr)
                for key, rx in PATTERNS.items():
                    if rx.search(msg):
                        st.per_min[mk][key] += 1
                if "TimeStamp expired" in msg:
                    cm = EXPIRED_CHAR.search(msg)
                    if cm:
                        st.expired_chars[cm.group(1)] += 1
                if PATTERNS["save_start"].search(msg):
                    save_t = ts
                elif save_t and PATTERNS["save_done"].search(msg):
                    st.save_durations.append(((ts - save_t).total_seconds(), save_t))
                    save_t = None
                if "UNetConnection::Close" in msg:
                    st.closes.append((ts, msg.strip()[:160]))
    return st


# ------------------------------------------------------------------ report
def pct_over(vals, thr):
    vals = [v for v in vals if v is not None]
    return (100.0 * sum(1 for v in vals if v > thr) / len(vals)) if vals else 0.0


def pct_under(vals, thr):
    vals = [v for v in vals if v is not None]
    return (100.0 * sum(1 for v in vals if v < thr) / len(vals)) if vals else 0.0


def fmt(v, spec="{:.0f}", none="-"):
    return none if v is None else spec.format(v)


def mean(vals):
    vals = [v for v in vals if v is not None]
    return statistics.fmean(vals) if vals else None


def vmax(vals):
    vals = [v for v in vals if v is not None]
    return max(vals) if vals else None


def quantile(vals, q):
    vals = sorted(v for v in vals if v is not None)
    if not vals:
        return None
    return vals[min(len(vals) - 1, int(q * (len(vals) - 1) + 0.5))]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--minutes", type=float, default=60.0, help="window length ending now (default 60)")
    ap.add_argument("--since", help="UTC start, e.g. 2026-10-25T13:00")
    ap.add_argument("--until", help="UTC end (default now)")
    ap.add_argument("--perf-dir", type=Path, default=PERF_DIR)
    ap.add_argument("--log-dir", type=Path, default=SERVER_LOG_DIR)
    ap.add_argument("--mod-log-dir", type=Path, default=REPO / "logs" / "mod")
    ap.add_argument("--no-timeline", action="store_true")
    a = ap.parse_args()

    t1 = utc(datetime.fromisoformat(a.until)) if a.until else datetime.now(timezone.utc)
    t0 = utc(datetime.fromisoformat(a.since)) if a.since else t1 - timedelta(minutes=a.minutes)

    mod = load_mod(a.perf_dir / "mod_perf.jsonl", t0, t1)
    host = load_host(a.perf_dir, t0, t1)
    lg = load_log(a.log_dir, t0, t1)
    debug_runs = load_debug_runs(a.mod_log_dir, t0, t1)

    # ---- per-minute buckets
    mins = sorted({minute(r["_ts"]) for r in mod} | {minute(r["_ts"]) for r in host} | set(lg.per_min))
    mod_by = defaultdict(list)
    for r in mod:
        mod_by[minute(r["_ts"])].append(r)
    host_by = defaultdict(list)
    for r in host:
        host_by[minute(r["_ts"])].append(r)

    print(f"Lag report  {t0:%Y-%m-%d %H:%M} -> {t1:%H:%M} UTC  ({(t1 - t0).total_seconds() / 60:.0f} min)")
    print(f"  sources: mod windows={len(mod)}  host samples={len(host)}  server log files={', '.join(lg.files) or 'none'}")

    if not a.no_timeline:
        print()
        hdr = (f"{'UTC':5} | {'Hz':>4} {'p50':>5} {'p95':>5} {'max':>5} {'>50':>3} {'>100':>4} {'ping':>8} | "
               f"{'cpu%':>4} {'core':>4} {'srv%':>4} {'freeMB':>6} {'dskms':>5} {'MsMp%':>5} {'netKB':>6} {'udpE':>4} | "
               f"{'logHz':>5} {'TSexp':>5} {'netW':>4} {'cls':>3} {'save':>4}")
        print(hdr)
        print("-" * len(hdr))
        for mk in mins:
            ms = mod_by.get(mk, [])
            hs = host_by.get(mk, [])
            lc = lg.per_min.get(mk, Counter())
            frames = sum(r["frames"] for r in ms)
            span = sum(r.get("window_s") or 0 for r in ms)
            hz = frames / span if span else None
            pings = [p.get("ping_ms") for r in ms for p in r.get("pings", []) if p.get("ping_ms")]
            ping_s = f"{min(pings):.0f}-{max(pings):.0f}" if pings else "-"
            loghz = (lg.tick_frames[mk] / lg.tick_secs[mk]) if lg.tick_secs.get(mk, 0) >= 5 else None
            netw = lc["net_warn"] - lc["ts_expired"]   # TimeStamp expired is itself a net warning
            print(f"{mk:%H:%M} | {fmt(hz, '{:4.1f}'):>4} {fmt(mean([r.get('ms_p50') for r in ms]), '{:5.1f}'):>5} "
                  f"{fmt(vmax([r.get('ms_p95') for r in ms]), '{:5.1f}'):>5} {fmt(vmax([r.get('ms_max') for r in ms])):>5} "
                  f"{fmt(sum(r.get('over_50', 0) for r in ms) if ms else None):>3} "
                  f"{fmt(sum(r.get('over_100', 0) for r in ms) if ms else None):>4} {ping_s:>8} | "
                  f"{fmt(vmax([h.get('cpu') for h in hs])):>4} {fmt(vmax([h.get('core') for h in hs])):>4} "
                  f"{fmt(vmax([h.get('srv_cpu') for h in hs])):>4} {fmt(min([h['avail_mb'] for h in hs if 'avail_mb' in h], default=None)):>6} "
                  f"{fmt(vmax([h.get('disk_lat') for h in hs]), '{:5.1f}'):>5} {fmt(vmax([h.get('def_cpu') for h in hs])):>5} "
                  f"{fmt(mean([h.get('net') for h in hs]) / 1024 if hs and mean([h.get('net') for h in hs]) is not None else None):>6} "
                  f"{fmt(sum(h.get('udp_err_d', 0) for h in hs) if hs else None):>4} | "
                  f"{fmt(loghz, '{:5.1f}'):>5} {lc['ts_expired']:>5} {max(netw, 0) + lc['saturated'] + lc['client_adjust']:>4} "
                  f"{lc['conn_close']:>3} {lc['save_start']:>4}")
        print("  Hz/p50/p95/max/>50/>100: game-thread frames (ms) from the mod.  ping: player ping range (ms).")
        print("  cpu%: VM total (max sample)  core: busiest vCPU  srv%: server process (% of ONE core; 400 = all 4)")
        print("  MsMp%: Defender (% of one core)  netKB: NIC KB/s  udpE: UDP receive errors (host drops)")
        print("  logHz: tick rate from the server log's frame counter  TSexp: 'ServerMove: TimeStamp expired'")
        print("  netW: other net warnings/saturation/ClientAdjust  cls: connection closes  save: autosaves started")

    # ---- verdict
    print()
    print("=" * 78)
    print("VERDICT")
    print("=" * 78)
    findings_server = []   # (resource, text)
    findings_net = []

    # 1. tick health
    tot_frames = sum(r["frames"] for r in mod)
    tot_span = sum(r.get("window_s") or 0 for r in mod)
    o50 = sum(r.get("over_50", 0) for r in mod)
    o100 = sum(r.get("over_100", 0) for r in mod)
    o250 = sum(r.get("over_250", 0) for r in mod)
    print("\n[1] Server tick health (game thread)")
    tick_state = "UNKNOWN"
    by_cause: Counter = Counter()
    autosave_max = None
    if tot_frames:
        hz = tot_frames / tot_span
        slow_pct = 100.0 * o50 / tot_frames
        hitch_pm = o100 / (tot_span / 60.0)
        worst = max(mod, key=lambda r: r.get("ms_max") or 0)
        min_hz = min((r.get("hz") or 0) for r in mod)
        print(f"    {tot_frames} frames over {tot_span / 60:.1f} min: avg {hz:.2f} Hz (target {TICK_TARGET_HZ:.0f}), "
              f"worst 10-s window {min_hz:.1f} Hz")
        print(f"    frame ms: p50 {statistics.median([r['ms_p50'] for r in mod if r.get('ms_p50')]):.1f}, "
              f"worst p95 {vmax([r.get('ms_p95') for r in mod]):.1f}, worst p99 {vmax([r.get('ms_p99') for r in mod]):.1f}, "
              f"max {worst.get('ms_max')} (at {worst['_ts']:%H:%M:%S})")
        print(f"    frames >50 ms: {o50} ({slow_pct:.2f}%)   >100 ms: {o100} ({hitch_pm:.2f}/min)   >250 ms: {o250}")
        hitches = [(datetime.fromtimestamp(h["t"], timezone.utc), h["ms"]) for r in mod for h in r.get("hitches", [])]
        causes = [(t, ms, attribute(t, debug_runs, lg.save_durations)) for t, ms in hitches]
        if causes:
            print("    hitches > 100 ms: " + ", ".join(f"{t:%H:%M:%S} {ms:.0f}ms" + (f" [{c}]" if c else "")
                                                     for t, ms, c in causes[:15]) + (" ..." if len(causes) > 15 else ""))
        by_cause = Counter(c or "unexplained" for _, _, c in causes)
        if by_cause:
            print("    hitch causes: " + ", ".join(f"{k} {v}" for k, v in by_cause.most_common()))
        # Judge the tick on hitches with no known cause. Known causes are reported on their own:
        # debug_run = our experiments (not normal play); autosave = the game's own 5-minute save.
        explained = sum(v for k, v in by_cause.items() if k != "unexplained")
        organic_pm = max(o100 - explained, 0) / (tot_span / 60.0)
        if explained:
            print(f"    unexplained hitches > 100 ms: {max(o100 - explained, 0)} ({organic_pm:.2f}/min)")
        saves_ms = [ms for _, ms, c in causes if c == "autosave"]
        if saves_ms:
            autosave_max = max(saves_ms)
        if hz < TICK_MIN_HZ or slow_pct > SLOW_PCT_BAD or organic_pm > HITCH_PER_MIN_BAD:
            tick_state = "BAD"
        elif slow_pct > SLOW_PCT_WARN or organic_pm > HITCH_PER_MIN_WARN:
            tick_state = "DEGRADED"
        else:
            tick_state = "OK"
        print(f"    -> {tick_state}  (OK: avg >= {TICK_MIN_HZ:.0f} Hz, <= {SLOW_PCT_WARN}% frames > {FRAME_SLOW_MS:.0f} ms, "
              f"<= {HITCH_PER_MIN_WARN} hitches > {FRAME_HITCH_MS:.0f} ms/min; BAD: < {TICK_MIN_HZ:.0f} Hz, "
              f"> {SLOW_PCT_BAD}% or > {HITCH_PER_MIN_BAD}/min)")
        errs = vmax([r.get("errors") for r in mod])
        if errs:
            print(f"    note: sampler reported {errs} callback errors")
    else:
        print("    no mod samples in the window (arm: debug_run {module=perf_sampler})")
    if lg.tick_secs:
        lf, lsx = sum(lg.tick_frames.values()), sum(lg.tick_secs.values())
        print(f"    cross-check from the server log's frame counter: {lf / lsx:.2f} Hz over {lsx / 60:.1f} min of log gaps")
    if lg.save_durations:
        ds = [d for d, _ in lg.save_durations]
        print(f"    autosaves: {len(ds)}, duration avg {statistics.fmean(ds):.2f} s, max {max(ds):.2f} s")

    # 2. host saturation
    print("\n[2] Host saturation (VM: logman counters every 10 s)")
    if host:
        checks = [
            ("CPU", "cpu", CPU_BUSY_PCT, "over", "% total CPU"),
            ("CPU", "core", CORE_BUSY_PCT, "over", "% busiest vCPU"),
            ("RAM", "avail_mb", RAM_LOW_MB, "under", "MB available"),
            ("RAM", "pages", PAGES_HIGH, "over", "pages/sec"),
            ("disk", "disk_lat", DISK_LAT_MS, "over", "ms disk latency"),
        ]
        for res, key, thr, how, unit in checks:
            vals = [h.get(key) for h in host]
            if all(v is None for v in vals):
                continue
            share = pct_over(vals, thr) if how == "over" else pct_under(vals, thr)
            worst = vmax(vals) if how == "over" else min(v for v in vals if v is not None)
            flag = share >= SATURATED_SAMPLE_PCT
            print(f"    {key:9} avg {fmt(mean(vals), '{:8.1f}')}  {'max' if how == 'over' else 'min'} {fmt(worst, '{:8.1f}')}  "
                  f"{how} {thr:g} {unit}: {share:5.1f}% of samples  {'SATURATED' if flag else 'ok'}")
            if flag:
                findings_server.append((res, f"{key} {how} {thr:g} {unit} in {share:.0f}% of samples"))
        srv = [h.get("srv_cpu") for h in host]
        ws = [h.get("srv_ws") for h in host]
        print(f"    server process: CPU avg {fmt(mean(srv), '{:.0f}')}% / max {fmt(vmax(srv), '{:.0f}')}% of one core, "
              f"working set max {fmt(vmax(ws), '{:.0f}')} MB, IO avg {fmt((mean([h.get('srv_io') for h in host]) or 0) / 1024, '{:.0f}')} KB/s")
        py = [h.get("py_cpu") for h in host]
        print(f"    python (brain/tools): CPU avg {fmt(mean(py), '{:.1f}')}% / max {fmt(vmax(py), '{:.0f}')}% of one core")
    else:
        print("    no host samples (start: powershell -File tools\\perf_counters.ps1 start)")

    # 3. Defender
    print("\n[3] Windows Defender (MsMpEng)")
    if host:
        dv = [h.get("def_cpu") for h in host]
        share = pct_over(dv, DEFENDER_SPIKE_PCT)
        print(f"    CPU avg {fmt(mean(dv), '{:.1f}')}% / max {fmt(vmax(dv), '{:.0f}')}% of one core; "
              f"> {DEFENDER_SPIKE_PCT:g}% in {share:.1f}% of samples; IO avg "
              f"{fmt((mean([h.get('def_io') for h in host]) or 0) / 1024, '{:.0f}')} KB/s")
        # Do Defender spikes line up with hitch windows?
        bad_windows = [r for r in mod if (r.get("over_100") or 0) > 0 or (r.get("over_50") or 0) > 2]
        coinc = 0
        for r in bad_windows:
            near = [h for h in host if abs((h["_ts"] - r["_ts"]).total_seconds()) <= 15]
            if any((h.get("def_cpu") or 0) > DEFENDER_SPIKE_PCT for h in near):
                coinc += 1
        if bad_windows:
            print(f"    slow-frame windows: {len(bad_windows)}, of which {coinc} coincide with a Defender spike (+-15 s)")
        if share >= SATURATED_SAMPLE_PCT and (not bad_windows or coinc >= max(1, len(bad_windows) // 2)):
            findings_server.append(("Defender", f"MsMpEng > {DEFENDER_SPIKE_PCT:g}% of a core in {share:.0f}% of samples"))
    else:
        print("    no host samples")

    # 4. network-side indicators
    print("\n[4] Network-side indicators")
    by_player = defaultdict(list)
    for r in mod:
        for p in r.get("pings", []):
            if p.get("ping_ms") is not None:
                by_player[p.get("name") or "?"].append(p["ping_ms"])
    for name, vals in by_player.items():
        p50, mx = quantile(vals, 0.5), max(vals)
        print(f"    ping {name}: p50 {p50:.0f} ms, p95 {quantile(vals, 0.95):.0f} ms, max {mx:.0f} ms "
              f"({len(vals)} samples, 10-s smoothed by the engine)")
        if mx > PING_HIGH_MS or mx - p50 > PING_JITTER_MS:
            findings_net.append(f"ping for {name} spikes to {mx:.0f} ms (p50 {p50:.0f})")
    tot = Counter()
    for c in lg.per_min.values():
        tot.update(c)
    span_min = max((t1 - t0).total_seconds() / 60.0, 1e-9)
    print(f"    'ServerMove: TimeStamp expired': {tot['ts_expired']} ({tot['ts_expired'] / span_min:.1f}/min)"
          + (f"  by character: {dict(lg.expired_chars.most_common(3))}" if lg.expired_chars else ""))
    print(f"    other net warnings: {max(tot['net_warn'] - tot['ts_expired'], 0)}, saturation: {tot['saturated']}, "
          f"ClientAdjust: {tot['client_adjust']}, connection closes: {tot['conn_close']}, joins: {tot['join']}, "
          f"log hitch lines: {tot['hitch']}")
    for ts, msg in lg.closes[:5]:
        print(f"      close {ts:%H:%M:%S}: {msg}")
    udp_err = sum(h.get("udp_err_d", 0) for h in host)
    print(f"    host UDP receive errors: {udp_err:.0f}" + ("  <- the VM dropped inbound packets" if udp_err else ""))
    if udp_err > 0:
        findings_server.append(("network stack", f"{udp_err:.0f} UDP datagrams dropped on receive by the VM"))
    if tot["ts_expired"] > 0:
        findings_net.append(f"{tot['ts_expired']} 'TimeStamp expired' (client moves arriving late/bunched)")
    if tot["saturated"]:
        findings_server.append(("bandwidth", f"{tot['saturated']} net saturation lines"))
    if tot["conn_close"]:
        findings_net.append(f"{tot['conn_close']} connection-close lines")

    # ---- conclusion
    print("\n" + "-" * 78)
    print("CONCLUSION")
    host_res = sorted({r for r, _ in findings_server if r in ("CPU", "RAM", "disk")})
    if tick_state == "UNKNOWN" and not host:
        print("  Not enough data in this window.")
    elif tick_state == "OK" and not host_res:
        print("  SERVER-SIDE OK. The game thread holds its tick rate, and the VM is not saturated.")
        if findings_net:
            print("  The lag is on the NETWORK PATH (GFN <-> VM) or the client: " + "; ".join(findings_net) + ".")
        else:
            print("  No network-side anomalies either in this window; if lag was felt, note the exact time and re-run.")
        print("  Upgrading the VM is NOT indicated.")
        if by_cause:
            print("  Hitches seen: " + ", ".join(f"{k} {v}" for k, v in by_cause.most_common())
                  + " (debug_run = our own experiments, not normal play).")
    elif host_res:
        print(f"  SERVER-BOUND: upgrade recommended -> {', '.join(host_res)}  (tick {tick_state}).")
        for r, t in findings_server:
            print(f"    - {r}: {t}")
    else:
        print(f"  SERVER-BOUND (tick {tick_state}) but the VM is NOT saturated: the cost is inside the game thread")
        print("  (AI, saves, mod work), so a bigger VM may not help. Compare hitch times with autosaves and mod events.")
        if by_cause:
            print("  Hitch causes: " + ", ".join(f"{k} {v}" for k, v in by_cause.most_common()))
    if autosave_max:
        print(f"  Known periodic hitch: the game's autosave (every 5 min) stalls the tick up to {autosave_max:.0f} ms.")
        print("  It is felt as one short freeze/rubber-band every 5 min; it is not saturation (disk/CPU idle).")
    other = [(r, t) for r, t in findings_server if r not in ("CPU", "RAM", "disk")]
    for r, t in other:
        print(f"  Also: {r}: {t}" + ("  (fix with Defender exclusions, not an upgrade)" if r == "Defender" else ""))


if __name__ == "__main__":
    main()

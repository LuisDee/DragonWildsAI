"""Nav oracle glue (route R2): Claude's client mover asks the DEV server's navmesh for a path.

The headless client has no NavigationSystem, so client_mod/scripts/move.lua writes a request
file, this helper forwards it over the dev-server bridge to mod/experiments/nav_oracle.lua
(FindPathToLocationSynchronously), and writes the waypoints back as a Lua file the mover
loadfile()s (no JSON decoder needed on the client).

  client_io/nav/req.json   {"id": 7, "from": [x,y,z], "to": [x,y,z]}           metres, written by the mover
  client_io/nav/resp.lua   return {id=7, ok=true, partial=false, points={{x,y,z},...}}   written here

  .venv\\Scripts\\python.exe -m tools.nav_oracle serve            # long-running helper
  .venv\\Scripts\\python.exe -m tools.nav_oracle query fx fy fz tx ty tz

Polls one small file (mtime) every 50 ms rather than adding the `watchdog` dependency: one file,
one writer, and a missed event just costs one more poll.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import time
import threading
import uuid
from pathlib import Path

from brain import paths
from brain.bridge_client import BridgeClient
from brain.transport import file_transport_pair
from tools.live_queue import single_instance

NAV_DIR = Path(os.environ.get("DW_CLIENT_ROOT", str(paths.REPO_ROOT))) / "client_io" / "nav"
REQ = NAV_DIR / "req.json"
RESP = NAV_DIR / "resp.lua"
ALIVE = NAV_DIR / "alive.lua"  # heartbeat: the mover only uses the oracle while this is fresh
LOADING_RETRY_S = 1.0
LOADING_MAX_S = 25.0  # corridor streaming for long trips needs ~10-20 s


def windows_process(pid: int):
    """Read-only process identity; None only for a definitely absent PID."""
    if os.name != "nt":
        raise RuntimeError("windows_process_identity_unavailable")
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    kernel.GetProcessTimes.restype = wintypes.BOOL
    kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel.QueryFullProcessImageNameW.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        if ctypes.get_last_error() == 87:
            return None
        raise OSError(ctypes.get_last_error(), "OpenProcess failed")
    try:
        creation, exit_time, kernel_time, user_time = (wintypes.FILETIME() for _ in range(4))
        if not kernel.GetProcessTimes(handle, ctypes.byref(creation), ctypes.byref(exit_time), ctypes.byref(kernel_time), ctypes.byref(user_time)):
            raise OSError(ctypes.get_last_error(), "GetProcessTimes failed")
        # A still-existing process object can already have exited.
        if exit_time.dwLowDateTime or exit_time.dwHighDateTime:
            return None
        buf, size = ctypes.create_unicode_buffer(32768), wintypes.DWORD(32768)
        if not kernel.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            raise OSError(ctypes.get_last_error(), "QueryFullProcessImageName failed")
        ticks = (creation.dwHighDateTime << 32) | creation.dwLowDateTime
        return {"pid": pid, "creation_filetime": str(ticks), "image": buf.value}
    finally:
        kernel.CloseHandle(handle)


def _identity_matches(actual, expected):
    return (isinstance(actual, dict) and actual.get("pid") == expected.get("pid") and
            actual.get("creation_filetime") == expected.get("creation_filetime") and
            os.path.normcase(actual.get("image", "")) == os.path.normcase(expected.get("image", "")))


def _snapshot(path: Path):
    """Pin file identity and hash its complete current prefix; require a complete tail."""
    with path.open("rb") as f:
        initial = os.fstat(f.fileno())
        remaining, digest, tail = initial.st_size, hashlib.sha256(), b""
        while remaining:
            block = f.read(min(1024 * 1024, remaining))
            if not block:
                raise RuntimeError("file_changed_during_snapshot")
            digest.update(block); remaining -= len(block)
            tail = (tail + block)[-65536:]
        final = os.fstat(f.fileno())
    current = path.stat()
    identity = (initial.st_dev, initial.st_ino)
    if (final.st_dev, final.st_ino) != identity or (current.st_dev, current.st_ino) != identity or final.st_size < initial.st_size:
        raise RuntimeError("file_identity_or_size_changed")
    if initial.st_size and not tail.endswith(b"\n"):
        raise RuntimeError("incomplete_jsonl_tail")
    if initial.st_size:
        last = tail.rstrip(b"\n").rsplit(b"\n", 1)[-1]
        try:
            if not isinstance(json.loads(last), dict):
                raise ValueError("not object")
        except (ValueError, UnicodeError) as exc:
            raise RuntimeError("invalid_jsonl_tail") from exc
    return {"identity": identity, "size": initial.st_size, "sha256": digest.hexdigest()}


def _unchanged_prefix(path: Path, snap):
    with path.open("rb") as f:
        stat = os.fstat(f.fileno())
        if (stat.st_dev, stat.st_ino) != snap["identity"] or stat.st_size < snap["size"]:
            return False
        remaining, digest = snap["size"], hashlib.sha256()
        while remaining:
            block = f.read(min(1024 * 1024, remaining))
            if not block: return False
            digest.update(block); remaining -= len(block)
        current = path.stat()
        return ((current.st_dev, current.st_ino) == snap["identity"] and
                current.st_size >= snap["size"] and digest.hexdigest() == snap["sha256"])


def _bridge_log_state(path: Path):
    latest = None
    with path.open("rb") as f:
        while True:
            position = f.tell()
            raw = f.readline()
            if not raw: break
            if not raw.endswith(b"\n"):
                raise RuntimeError("incomplete_bridge_log")
            try: event = json.loads(raw)
            except (ValueError, UnicodeError) as exc: raise RuntimeError("invalid_bridge_log") from exc
            if not isinstance(event, dict): raise RuntimeError("invalid_bridge_log")
            if event.get("event") in ("bridge_started", "mod_loaded"):
                latest = (event, position)
    if not latest or latest[0].get("event") != "bridge_started":
        raise RuntimeError("bridge_start_unverified")
    event, position = latest
    data = event.get("data") or {}
    return {"ts": event.get("ts"), "offset": data.get("offset"), "dir": data.get("dir")}, position


def _policy_valid(policy):
    if not isinstance(policy, dict) or policy.get("version") != 1: return False
    server, old = policy.get("server"), policy.get("retired_writers")
    confirms, start = policy.get("operator_confirms"), policy.get("bridge_started")
    def ident(v, image=False):
        return (isinstance(v, dict) and type(v.get("pid")) is int and v["pid"] > 0 and
                isinstance(v.get("creation_filetime"), str) and v["creation_filetime"].isdigit() and
                (not image or isinstance(v.get("image"), str) and bool(v["image"])))
    return (ident(server, True) and isinstance(old, list) and bool(old) and all(ident(x) for x in old) and
            isinstance(policy.get("bridge_log"), str) and bool(policy["bridge_log"]) and
            isinstance(start, dict) and isinstance(start.get("ts"), str) and
            type(start.get("offset")) is int and isinstance(start.get("dir"), str) and
            isinstance(confirms, dict) and confirms.get("no_other_nav_writers") is True and
            confirms.get("no_bridge_reload") is True)


def recover(policy, client, process=windows_process):
    """Require operator policy, stable process and append-only bridge across FIFO ping."""
    if not _policy_valid(policy): raise RuntimeError("recovery_policy_invalid")
    server = policy["server"]
    if not _identity_matches(process(server["pid"]), server): raise RuntimeError("server_identity_changed")
    for old in policy["retired_writers"]:
        actual = process(old["pid"])
        if actual and actual.get("creation_filetime") == old["creation_filetime"]:
            raise RuntimeError("retired_writer_still_running")
    bridge = paths.bridge_dir("server")
    incoming, outgoing = bridge / "brain_to_body.jsonl", bridge / "body_to_brain.jsonl"
    log = Path(policy["bridge_log"])
    if os.path.normcase(os.path.abspath(policy["bridge_started"]["dir"])) != os.path.normcase(os.path.abspath(bridge)):
        raise RuntimeError("bridge_directory_mismatch")
    snapshots = [(path, _snapshot(path)) for path in (incoming, outgoing, log)]
    log_start = _bridge_log_state(log)
    if log_start[0] != policy["bridge_started"] or log_start[1] >= snapshots[2][1]["size"]:
        raise RuntimeError("bridge_start_mismatch")
    reply = client.request("ping", {}, timeout=10.0)
    if not isinstance(reply, dict) or reply.get("ok") is not True or (reply.get("data") or {}).get("pong") is not True:
        raise RuntimeError("fifo_barrier_unanswered")
    def unchanged():
        try:
            return (_identity_matches(process(server["pid"]), server) and
                    all(_unchanged_prefix(path, snap) for path, snap in snapshots) and
                    _bridge_log_state(log) == log_start)
        except (OSError, ValueError, RuntimeError):
            return False
    if not unchanged(): raise RuntimeError("recovery_continuity_changed")
    return unchanged


def _finite_number(value) -> bool:
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def valid_coords(point) -> bool:
    return (isinstance(point, list) and len(point) == 3 and
            all(_finite_number(n) and _finite_number(n * 100) for n in point))


def validate_result(res) -> dict:
    """Reject unusable routes while retaining optional boolean evidence exactly."""
    invalid = {"ok": False, "reason": "invalid_path_payload", "points": []}
    if not isinstance(res, dict) or type(res.get("ok")) is not bool:
        return invalid
    for key in ("partial", "goal_projected", "retry"):
        if res.get(key) is not None and type(res[key]) is not bool:
            return invalid
    pts = res.get("points", [])
    if not isinstance(pts, list) or any(not valid_coords(point) for point in pts) or (res["ok"] and len(pts) < 2):
        return invalid
    length = res.get("length_m")
    if length is not None and (not _finite_number(length) or length < 0):
        return invalid
    return res


def query(client: BridgeClient, frm: list[float], to: list[float]) -> dict:
    """One path query; retries while the dev server is still streaming the area in."""
    deadline = time.monotonic() + LOADING_MAX_S
    while True:
        r = client.request("debug_run", {"module": "nav_oracle", "args": {"from": frm, "to": to}}, timeout=10.0)
        res = (r.get("data") or {}).get("result") if r.get("ok") else None
        if res is None:
            return {"ok": False, "reason": "bridge_" + str(r.get("reason")), "points": [], "_transport_unresolved": True}
        res = validate_result(res)
        if res.get("retry") and time.monotonic() < deadline:
            time.sleep(LOADING_RETRY_S)
            continue
        return res


def _lua(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "nil"
    if isinstance(v, (int, float)):
        return repr(float(v)) if isinstance(v, float) else str(v)
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(_lua(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join(f"{k}={_lua(x)}" for k, x in v.items() if x is not None) + "}"
    return json.dumps(str(v))  # a JSON string literal is a valid Lua string literal for ASCII


def write_resp(req_id, res: dict, epoch=None, nonce=None) -> None:
    res = validate_result(res)
    body = {"id": req_id, "ok": res["ok"], "reason": res.get("reason"),
            "partial": res.get("partial"), "goal_projected": res.get("goal_projected"),
            "length_m": res.get("length_m"), "points": res.get("points", [])}
    if epoch is not None and nonce is not None:
        body.update(version=2, epoch=epoch, nonce=nonce)
    tmp = RESP.with_suffix(".tmp")
    tmp.write_text("return " + _lua(body) + "\n", encoding="utf-8")
    # Atomic, so the mover never sees a half-written file. On Windows the replace is refused while
    # the client has resp.lua open for its loadfile(), so retry briefly.
    for attempt in range(50):
        try:
            os.replace(tmp, RESP)
            return
        except PermissionError:
            time.sleep(0.01)
    raise PermissionError(f"could not replace {RESP}")


def _atomic_status(body: dict) -> None:
    tmp = ALIVE.with_suffix(".tmp")
    tmp.write_text("return " + _lua(body) + "\n", encoding="utf-8")
    for attempt in range(50):
        try:
            os.replace(tmp, ALIVE)
            return
        except PermissionError:
            time.sleep(0.01)
    raise PermissionError(f"could not replace {ALIVE}")


class Authority:
    """One helper epoch. Only an independently verified recovery permits an offer."""
    def __init__(self, client, publish=_atomic_status):
        self.client = client
        self.publish = publish
        self.lock = threading.Lock()
        self.epoch = str(uuid.uuid4())
        self.state = "recovering"
        self.nonce = None
        self.reason = "recovery_unverified"
        self.closed = threading.Event()
        self.verify = None

    def _emit_locked(self):
        data = {"version": 2, "epoch": self.epoch, "state": self.state,
                "updated": time.time(), "reason": self.reason}
        if self.state == "offered":
            data["nonce"] = self.nonce
        self.publish(data)

    def heartbeat(self):
        with self.lock:
            self._emit_locked()

    def heartbeat_loop(self):
        while not self.closed.wait(1.0):
            try:
                self.heartbeat()
            except OSError:
                # A missing/stale status must never be replaced with an inferred offer.
                pass

    def recovered(self, verify):
        with self.lock:
            if self.state != "recovering":
                raise RuntimeError("recovery transition invalid")
            self.verify = verify
            self.state, self.nonce, self.reason = "offered", str(uuid.uuid4()), None
            self._emit_locked()

    def accept(self, req):
        with self.lock:
            if (self.state != "offered" or not isinstance(req, dict) or
                type(req.get("version")) is not int or req["version"] != 2 or
                req.get("epoch") != self.epoch or req.get("nonce") != self.nonce or
                type(req.get("id")) not in (int, str) or req["id"] == ""):
                return False
            nonce, self.nonce = self.nonce, None
            if not self.verify or not self.verify():
                self.state, self.reason = "unresolved", "recovery_continuity_changed"
                self._emit_locked()
                return True
            self.state, self.reason = "busy", None
            # Publication is before any server call, and shares the heartbeat lock.
            self._emit_locked()
        try:
            frm, to = req.get("from"), req.get("to")
            if not all(valid_coords(p) for p in (frm, to)):
                result = {"ok": False, "reason": "invalid_args", "points": []}
            else:
                result = query(self.client, frm, to)
            if not self.verify():
                result = {"ok": False, "reason": "recovery_continuity_changed", "points": [], "_transport_unresolved": True}
            write_resp(req["id"], result, self.epoch, nonce)
            with self.lock:
                if result.get("_transport_unresolved"):
                    self.state, self.reason = "unresolved", result.get("reason")
                else:
                    self.state, self.reason = "offered", None
                    self.nonce = str(uuid.uuid4())
                self._emit_locked()
        except Exception as exc:
            with self.lock:
                self.state, self.nonce, self.reason = "unresolved", None, type(exc).__name__
                try:
                    self._emit_locked()
                except OSError:
                    pass
        return True


def serve(client: BridgeClient) -> None:
    NAV_DIR.mkdir(parents=True, exist_ok=True)
    authority = Authority(client)
    authority.heartbeat()
    threading.Thread(target=authority.heartbeat_loop, daemon=True).start()
    try:
        try:
            policy = json.loads((NAV_DIR / "recovery_policy.json").read_text(encoding="utf-8"))
            authority.recovered(recover(policy, client))
        except (OSError, ValueError, RuntimeError) as exc:
            with authority.lock:
                authority.reason = "recovery_unverified:" + str(exc)
                authority._emit_locked()
        while True:
            try:
                req = json.loads(REQ.read_text(encoding="utf-8"))
            except (FileNotFoundError, json.JSONDecodeError, OSError):
                req = None
            if req:
                authority.accept(req)
            time.sleep(0.05)
    finally:
        authority.closed.set()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve")
    q = sub.add_parser("query")
    q.add_argument("coords", nargs=6, type=float)
    a = ap.parse_args()
    with single_instance(NAV_DIR / "oracle.lock") as owned:
        if not owned:
            raise SystemExit("navigation helper lock is already held")
        try:  # always the DEV SERVER mod (it has the navmesh), whatever DW_BODY says
            brain_side, _ = file_transport_pair(body="server")
        except TypeError:  # older transport without body selection
            brain_side, _ = file_transport_pair()
        client = BridgeClient(brain_side)
        if a.cmd == "serve":
            serve(client)
        else:
            try:
                policy = json.loads((NAV_DIR / "recovery_policy.json").read_text(encoding="utf-8"))
                verify = recover(policy, client)
                if not verify(): raise RuntimeError("recovery_continuity_changed")
                if not valid_coords(a.coords[:3]) or not valid_coords(a.coords[3:]): raise RuntimeError("invalid_args")
                result = query(client, a.coords[:3], a.coords[3:])
                if not verify() or result.get("_transport_unresolved"):
                    raise RuntimeError("query_unresolved")
                print(json.dumps(result, indent=1))
            except (OSError, ValueError, RuntimeError) as exc:
                raise SystemExit("navigation recovery unverified: " + str(exc)) from exc



if __name__ == "__main__":
    main()

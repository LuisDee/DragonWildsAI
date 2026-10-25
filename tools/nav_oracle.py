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
import json
import os
import time
from pathlib import Path

from brain import paths
from brain.bridge_client import BridgeClient
from brain.transport import file_transport_pair

NAV_DIR = Path(os.environ.get("DW_CLIENT_ROOT", str(paths.REPO_ROOT))) / "client_io" / "nav"
REQ = NAV_DIR / "req.json"
RESP = NAV_DIR / "resp.lua"
LOADING_RETRY_S = 1.0
LOADING_MAX_S = 15.0


def query(client: BridgeClient, frm: list[float], to: list[float]) -> dict:
    """One path query; retries while the dev server is still streaming the area in."""
    deadline = time.monotonic() + LOADING_MAX_S
    while True:
        r = client.request("debug_run", {"module": "nav_oracle", "args": {"from": frm, "to": to}}, timeout=10.0)
        res = (r.get("data") or {}).get("result") if r.get("ok") else None
        if res is None:
            return {"ok": False, "reason": "bridge_" + str(r.get("reason")), "points": []}
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


def write_resp(req_id, res: dict) -> None:
    body = {"id": req_id, "ok": bool(res.get("ok")), "reason": res.get("reason"),
            "partial": bool(res.get("partial")), "length_m": res.get("length_m"),
            "points": res.get("points") or []}
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


def serve(client: BridgeClient) -> None:
    NAV_DIR.mkdir(parents=True, exist_ok=True)
    last_id = None
    print(f"nav_oracle serving {REQ}", flush=True)
    while True:
        try:
            req = json.loads(REQ.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            req = None  # absent, or caught mid-write: try again next poll
        if req and req.get("id") != last_id:
            last_id = req.get("id")
            t0 = time.monotonic()
            try:
                res = query(client, req["from"], req["to"])
                write_resp(last_id, res)
            except Exception as e:  # one bad request must not kill the helper
                print(f"id={last_id} error {type(e).__name__}: {e}", flush=True)
                continue
            print(f"id={last_id} ok={res.get('ok')} n={len(res.get('points') or [])} partial={res.get('partial')} "
                  f"reason={res.get('reason')} {int((time.monotonic() - t0) * 1000)} ms", flush=True)
        time.sleep(0.05)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve")
    q = sub.add_parser("query")
    q.add_argument("coords", nargs=6, type=float)
    a = ap.parse_args()
    try:  # always the DEV SERVER mod (it has the navmesh), whatever DW_BODY says
        brain_side, _ = file_transport_pair(body="server")
    except TypeError:  # older transport without body selection
        brain_side, _ = file_transport_pair()
    client = BridgeClient(brain_side)
    if a.cmd == "serve":
        serve(client)
    else:
        print(json.dumps(query(client, a.coords[:3], a.coords[3:]), indent=1))


if __name__ == "__main__":
    main()

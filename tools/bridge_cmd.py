"""Send one command to the live body over the bridge and print the reply.

  .venv\\Scripts\\python.exe -m tools.bridge_cmd ping
  .venv\\Scripts\\python.exe -m tools.bridge_cmd interact "{\\"target\\": \\"BP_X_1\\"}"

Defaults (route R2: the server puppet is retired): --body client, --channel debug, and the wait is the
tool's own (the body's manifest timeout_s, else brain.bridge_client.DEFAULT_TIMEOUTS), never shorter than
--timeout. It refuses to send into a directory where the chosen body has never answered: on 2026-10-25
19:25 an `interact` went to client_io/bridge/brain_to_body.jsonl (the SERVER body's file name, because
--body defaulted to server while DW_BRIDGE_DIR pointed at the client dir), nobody read it, and it "timed out".
"""
import argparse
import json
import os
import sys

from brain import paths
from brain.bridge_client import DEFAULT_TIMEOUTS, BridgeClient
from brain.transport import endpoint_files, file_transport_pair


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tool")
    ap.add_argument("args", nargs="?", default="{}", help="JSON object of tool args")
    ap.add_argument("--timeout", type=float, default=None,
                    help="seconds to wait (default: the tool's own timeout, at least 30)")
    ap.add_argument("--body", choices=("server", "client"), default=None,
                    help="client (default: DW_BODY or client; route R2) or the retired server puppet")
    ap.add_argument("--probe", action="store_true", help="send probe: true (the body answers without acting)")
    ap.add_argument("--channel", choices=("main", "debug"), default=None,
                    help="client body: 'debug' (default) keeps replies out of the live brain's file")
    ap.add_argument("--force", action="store_true", help="send even if no body ever answered in that directory")
    a = ap.parse_args()
    body = a.body or os.environ.get(paths.BODY_ENV) or "client"
    channel = a.channel or ("debug" if body == "client" else "main")
    d = paths.bridge_dir(body)
    to_body, to_brain = endpoint_files(body, channel)
    # the body's reply file of the MAIN channel exists once that body has ever run in this directory
    main_reply = d / endpoint_files(body, "main")[1]
    if not a.force and not main_reply.exists():
        sys.exit(f"no {body} body has ever answered in {d} ({main_reply.name} missing): wrong --body or DW_BRIDGE_DIR? "
                 "(--force sends anyway)")
    brain_side, _ = file_transport_pair(body=body, channel=channel)
    client = BridgeClient(brain_side)
    wait = DEFAULT_TIMEOUTS.get(a.tool, 30.0)
    if a.timeout is None and not a.probe:
        caps = client.request("capabilities", {}, 5.0)
        for e in (caps.get("data") or {}).get("manifest") or []:
            if isinstance(e, dict) and e.get("name") == a.tool and isinstance(e.get("timeout_s"), (int, float)):
                wait = float(e["timeout_s"]) + 5.0
    timeout = a.timeout if a.timeout is not None else max(30.0, wait)
    print(f"[{body}/{channel}] {d / to_body} -> {to_brain}, wait {timeout:.0f}s", file=sys.stderr)
    print(json.dumps(client.request(a.tool, json.loads(a.args), timeout=timeout, probe=a.probe), indent=2))


if __name__ == "__main__":
    main()

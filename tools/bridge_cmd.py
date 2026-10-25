"""Send one command to the live body over the bridge and print the reply.

  .venv\\Scripts\\python.exe -m tools.bridge_cmd ping
  .venv\\Scripts\\python.exe -m tools.bridge_cmd debug_run "{\\"module\\": \\"body_probe\\"}"
"""
import argparse
import json

from brain.bridge_client import BridgeClient
from brain.transport import file_transport_pair


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tool")
    ap.add_argument("args", nargs="?", default="{}", help="JSON object of tool args")
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--body", choices=("server", "client"), default=None,
                    help="server puppet mod or Claude's game client (client_io/bridge). Default DW_BODY or server")
    ap.add_argument("--probe", action="store_true", help="send probe: true (the body answers without acting)")
    ap.add_argument("--channel", choices=("main", "debug"), default=None,
                    help="client body: 'debug' (default for --body client) keeps replies out of the live brain's file")
    a = ap.parse_args()
    channel = a.channel or ("debug" if (a.body or "") == "client" else "main")
    brain_side, _ = file_transport_pair(body=a.body, channel=channel)
    client = BridgeClient(brain_side)
    print(json.dumps(client.request(a.tool, json.loads(a.args), timeout=a.timeout, probe=a.probe), indent=2))


if __name__ == "__main__":
    main()

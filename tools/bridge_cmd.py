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
    a = ap.parse_args()
    brain_side, _ = file_transport_pair()
    print(json.dumps(BridgeClient(brain_side).request(a.tool, json.loads(a.args), timeout=a.timeout), indent=2))


if __name__ == "__main__":
    main()

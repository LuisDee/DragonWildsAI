"""Exercise real producer UUIDs through the actual Lua mover's file protocol."""
import json
import os
import subprocess
from pathlib import Path

import pytest

from tests.test_lua_bridge import LUA
from tools import nav_oracle

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(LUA is None, reason="Lua interpreter unavailable")


def test_actual_mover_authority_regressions(tmp_path):
    """Include the focused route/owner/traversal scenarios in the normal gate."""
    env = dict(os.environ, MOVE_AUTHORITY_ONLY="1")
    for key in ("MOVE_FILE", "MOVE_PROTOCOL_WIRE_ONLY", "MOVE_ORACLE_OFFER_FILE"):
        env.pop(key, None)
    run = subprocess.run(
        [LUA, str(ROOT / "client_mod/tests/test_move.lua"), str(tmp_path / "world")],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=60,
    )
    assert run.returncode == 0, run.stdout + run.stderr
    assert "FAIL" not in run.stdout, run.stdout
    assert "pending request holds actual input" in run.stdout
    assert "world identity change fails closed" in run.stdout
    assert "partial endpoint does not fall through to raw goal" in run.stdout


def test_authority_offer_mover_request_and_authority_accept(tmp_path, monkeypatch):
    offered = []

    class Server:
        calls = 0

        def request(self, tool, args, timeout):
            self.calls += 1
            assert tool == "debug_run" and args["module"] == "nav_oracle"
            return {"ok": True, "data": {"result": {
                "ok": True, "partial": False, "goal_projected": True,
                "points": [[0, 0, 0], [5, 6, 0], [12, 6, 0], [20, 0, 0]],
            }}}

    server = Server()
    authority = nav_oracle.Authority(server, publish=lambda row: offered.append(dict(row)))
    authority.recovered(lambda: True)
    original = offered[-1]
    fixture = tmp_path / "actual-offer.lua"
    fixture.write_text("return " + nav_oracle._lua(original) + "\n", encoding="utf-8")
    world = tmp_path / "world"
    env = dict(os.environ, MOVE_ORACLE_OFFER_FILE=str(fixture), MOVE_PROTOCOL_WIRE_ONLY="1")
    env.pop("MOVE_AUTHORITY_ONLY", None)
    env.pop("MOVE_FILE", None)
    run = subprocess.run(
        [LUA, str(ROOT / "client_mod/tests/test_move.lua"), str(world)],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=60,
    )
    assert run.returncode == 0, run.stdout + run.stderr
    assert "FAIL" not in run.stdout, run.stdout
    assert "used nav waypoints" in run.stdout and "go_to arrives via waypoints" in run.stdout
    request = json.loads((world / "client_io/nav/req.json").read_text(encoding="utf-8"))
    assert request["epoch"] == original["epoch"] and request["nonce"] == original["nonce"]
    monkeypatch.setattr(nav_oracle, "RESP", world / "client_io/nav/resp.lua")
    assert authority.accept(request) and server.calls == 1
    response = nav_oracle.RESP.read_text(encoding="utf-8")
    assert f'epoch="{original["epoch"]}"' in response
    assert f'nonce="{original["nonce"]}"' in response
    assert authority.state == "offered" and authority.nonce != original["nonce"]
    assert not authority.accept(request) and server.calls == 1

import json
import math
import subprocess
from pathlib import Path

import pytest
from tests.test_lua_bridge import LUA
from tools import nav_oracle

HERE = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(LUA is None, reason="Lua interpreter unavailable")


def test_actual_server_metadata_through_python_and_lua(tmp_path, monkeypatch):
    script=HERE/'mod/tests/test_nav_oracle_metadata.lua'
    run=subprocess.run([LUA,str(script)],capture_output=True,text=True,timeout=20)
    assert run.returncode == 0, run.stderr
    rows=json.loads(run.stdout)
    assert rows[0]['partial'] is False and rows[0]['goal_projected'] is True
    assert rows[1]['partial'] is True and rows[1]['goal_projected'] is False
    assert rows[2].get('partial') is None and rows[2].get('goal_projected') is None
    assert rows[3].get('partial') is None and rows[3]['goal_projected'] is True
    assert rows[4]['partial'] is False and rows[4].get('goal_projected') is None
    assert all(row['reason']=='invalid_path_payload' and not row['ok'] for row in rows[5:7])
    assert rows[7]['reason']=='start_projection_unknown'
    assert rows[8]['reason']=='start_off_navmesh'
    assert rows[9]['reason']=='invalid_args'
    monkeypatch.setattr(nav_oracle,'RESP',tmp_path/'resp.lua')
    for i,row in enumerate(rows[:5]):
        nav_oracle.write_resp(i,row)
        probe="local r=assert(loadfile(arg[0]))(); print(tostring(r.partial)..','..tostring(r.goal_projected))"
        got=subprocess.run([LUA,'-e',probe,str(nav_oracle.RESP)],capture_output=True,text=True,timeout=10)
        assert got.returncode == 0, got.stderr
        assert got.stdout.strip()==['false,true','true,false','nil,nil','nil,true','false,nil'][i]


@pytest.mark.parametrize('data', [
    {'ok':True,'points':[[0,0,0],[1,2,float('nan')]]},
    {'ok':True,'points':[[0,0,0],[1,2,float('inf')]]},
    {'ok':True,'points':[[0,0,0],[1,2,1e308]]},
    {'ok':True,'points':[[0,0,0],[1,2,10**1000]]},
    {'ok':True,'points':[[0,0,0],[1,2,True]]},
    {'ok':True,'points':[[0,0,0],[1,2]]},
    {'ok':True,'points':[[0,0,0]]},
    {'ok':'true','points':[[0,0,0],[1,2,3]]},
    {'ok':True,'points':[[0,0,0],[1,2,3]],'partial':'false'},
    {'ok':True,'points':[[0,0,0],[1,2,3]],'goal_projected':0},
])
def test_malformed_response_never_becomes_path(data,tmp_path,monkeypatch):
    monkeypatch.setattr(nav_oracle,'RESP',tmp_path/'resp.lua')
    nav_oracle.write_resp(5,data)
    probe="local r=assert(loadfile(arg[0]))(); assert(r.ok==false and r.reason=='invalid_path_payload' and #r.points==0)"
    run=subprocess.run([LUA,'-e',probe,str(nav_oracle.RESP)],capture_output=True,text=True,timeout=10)
    assert run.returncode == 0, run.stderr

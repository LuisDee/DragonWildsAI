"""tools/combat_s1.py offline: the trend maths, the evidence parsers, the slot guard, and that every Lua chunk it
sends parses (luac -p), so the first live slot isn't spent on a typo."""
import json
import shutil
import subprocess

import pytest

from tools import combat_s1 as S


def test_slope_sign():
    assert S.slope([40, 30, 25, 20, 12]) < 0
    assert S.slope([10, 10]) == 0
    assert S.slope([5]) is None


def test_server_evidence(tmp_path, monkeypatch):
    log = tmp_path / "server.log"
    log.write_text("\n".join([
        "x EvadeAttack: Verbose: TryPerformAttack() : [1] BP_AI_Wolf starting attack on authority against player BP_PlayerCharacter_C_1",
        "x EvadeAttack: Verbose: PredictPointDamage() : [1] BP_PlayerCharacter_C_1 will receive 7.000000 damage at 1 from BP_AI_Wolf.",
        "x EvadeAttack: Verbose: PredictPointDamage() : [1] BP_PlayerCharacter_C_1 evaded 0.000000 damage at 1 from BP_AI_Wolf.",
        "x EvadeAttack: Verbose: PredictPointDamage() : [1] BP_PlayerCharacter_C_1 will receive 0.000000 damage at 1 from BP_AI_Wolf.",
    ]), encoding="utf-8")
    monkeypatch.setattr(S, "SERVER_LOG", log)
    ev = S.server_evidence(0)
    assert ev == {"attacks": 1, "hits": 1, "evaded": 1, "zero_dmg": 1, "dmg": 7.0}


def test_activity_after(tmp_path, monkeypatch):
    act = tmp_path / "activity.jsonl"
    act.write_text(json.dumps({"kind": "healed"}) + "\n" + json.dumps({"kind": "combat_end", "damage_taken": 12}) + "\n", encoding="utf-8")
    monkeypatch.setattr(S, "ACTIVITY", act)
    assert S.activity_after(0) == [{"kind": "combat_end", "damage_taken": 12}]


def test_refuses_without_the_slot(monkeypatch, capsys):
    monkeypatch.setattr(S, "slot_ok", lambda: False)
    assert S.main(["survey"]) == 1
    assert "not held by combat" in capsys.readouterr().out


@pytest.mark.skipif(not (shutil.which("luac") or __import__("os").path.exists(r"C:\Program Files\WinGet\Links\luac.exe")),
                    reason="no luac")
def test_the_lua_it_sends_parses(tmp_path):
    luac = shutil.which("luac") or r"C:\Program Files\WinGet\Links\luac.exe"
    chunks = {"survey": S.SURVEY, "status": S.STATUS, "brief": S.BRIEF.replace("__KIND__", "Wolf"),
              "fight": S.FIGHT.replace("__ORDERS__", '{ defense = "auto" }').replace("__KIND__", "Wolf")}
    for name, lua in chunks.items():
        f = tmp_path / f"{name}.lua"
        f.write_text(lua, encoding="utf-8")
        r = subprocess.run([luac, "-p", str(f)], capture_output=True, text=True)
        assert r.returncode == 0, (name, r.stderr)

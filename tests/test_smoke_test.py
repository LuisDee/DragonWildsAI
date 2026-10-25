"""tools/smoke_test.py logic against a scripted fake bridge client and tiny catalogs (no server)."""
import json

from tools import smoke_test as st


class FakeClient:
    def __init__(self, replies: dict, players=None):
        self.replies = replies
        self.players = players or []
        self.calls = []

    def request(self, tool, args=None, timeout=10.0):
        self.calls.append(tool)
        if tool in self.replies:
            r = self.replies[tool]
            return r(args) if callable(r) else r
        return {"ok": False, "reason": "unknown_tool", "data": {}}


def good_replies(players=()):
    state = {"position": None, "health": None, "inventory": {}, "players": list(players), "nearby_entities": []}
    return {
        "ping": {"ok": True, "data": {"pong": True}},
        "capabilities": {"ok": True, "data": {"tools": st.REQUIRED_TOOLS + ["capabilities"]}},
        "get_state": {"ok": False, "reason": "companion_down", "data": state},
        "body_status": {"ok": True, "data": {"puppet": {"present": False}}},
        "debug_run": {"ok": True, "data": {"result": {"ok": True, "players": len(players), "ai_characters": 3}}},
        "body_spawn": {"ok": True, "data": {}}, "follow": {"ok": True, "data": {}}, "stop": {"ok": True, "data": {}},
        "say": {"ok": True, "data": {}},
    }


def by_name(results):
    return {r["name"]: r for r in results}


def test_live_checks_pass_and_player_checks_skip_without_players():
    client = FakeClient(good_replies())
    r = by_name(st.run_live(client))
    assert all(r[n]["status"] == st.PASS for n in ("ping", "capabilities", "get_state", "body_status", "debug_run body_probe"))
    for n in st.PLAYER_CHECKS:
        assert r[n]["status"] == st.SKIP and "no player connected" in r[n]["detail"]
    assert "body_spawn" not in client.calls  # read-only unless --active


def test_player_checks_need_active_flag():
    client = FakeClient(good_replies(players=[{"name": "Luis"}]))
    r = by_name(st.run_live(client, active=False))
    assert all(r[n]["status"] == st.SKIP and "--active" in r[n]["detail"] for n in st.PLAYER_CHECKS)
    assert "body_spawn" not in client.calls and "say" not in client.calls
    r = by_name(st.run_live(client, active=True))
    assert r[st.PLAYER_CHECKS[0]]["status"] == st.PASS and r["follow"]["status"] == st.PASS
    assert r["say relay"]["status"] == st.PASS and r["attack"]["status"] == st.SKIP  # no hostile nearby


def test_dead_bridge_fails_ping_and_skips_the_rest():
    r = by_name(st.run_live(FakeClient({"ping": {"ok": False, "reason": "timeout", "data": {}}})))
    assert r["ping"]["status"] == st.FAIL and r["capabilities"]["status"] == st.SKIP


def test_missing_required_tool_fails_capabilities():
    replies = good_replies()
    replies["capabilities"] = {"ok": True, "data": {"tools": ["ping", "get_state"]}}
    r = by_name(st.run_live(FakeClient(replies)))
    assert r["capabilities"]["status"] == st.FAIL and "follow" in r["capabilities"]["detail"]


def test_body_probe_failure_is_reported():
    replies = good_replies()
    replies["debug_run"] = {"ok": False, "reason": "body_error", "data": {"detail": "boom"}}
    assert by_name(st.run_live(FakeClient(replies)))["debug_run body_probe"]["status"] == st.FAIL


def catalog(build="1"):
    sword = {"id": "ITEM_Sword_Iron", "kind": "held", "role": "weapon", "category": "sword", "range_type": "melee",
             "slot": "right_hand", "attacks": {"primary": {"action": "/G/PA_Sword.PA_Sword_C"}}, "path": "/G/S.S"}
    bow = {"id": "ITEM_Longbow_Hunter", "kind": "held", "role": "weapon", "category": "bow", "range_type": "ranged",
           "ranged": {"collection": "/G/C.C_C"}, "attacks": {"primary": {"action": "/G/PA_Bow.PA_Bow_C"}}}
    staff = {"id": "ITEM_Staff_Ancestral", "kind": "held", "role": "weapon", "category": "staff", "range_type": "magic",
             "magic_collection": "/G/M.M_C", "attacks": {"primary": {"action": "/G/PA_Bow.PA_Bow_C"}}}
    body = {"id": "ITEM_Armour_T4_Body_Iron", "kind": "wearable", "role": "armour", "slot": "body", "path": "/G/A.A"}
    pick = {"id": "ITEM_Pickaxe_Iron", "kind": "held", "role": "weapon", "category": "pickaxe", "range_type": "melee",
            "held_actor_class": "/G/P.P_C", "attacks": {"primary": {"action": "/G/PA_Sword.PA_Sword_C"}}}
    items = {i["id"]: i for i in (sword, bow, staff, body, pick)}
    for n in range(st.MIN_ITEMS):
        items[f"ITEM_Filler{n}"] = {"id": f"ITEM_Filler{n}", "kind": "wearable", "role": "armour", "slot": "head"}
    sets = {f"/G/PA_{n}.PA_{n}_C": {"chain": ["a"]} for n in range(st.MIN_ATTACK_SETS)}
    sets["/G/PA_Sword.PA_Sword_C"] = {"chain": ["a", "b"]}
    sets["/G/PA_Bow.PA_Bow_C"] = {"chain": ["a"]}
    return {"schema": "dw_items/1", "build": build, "items": items, "attack_sets": sets,
            "source": {"errors": [], "missing_from_catalog": []}}


def write_catalog(tmp_path, cat, spells=None, build="1"):
    (tmp_path / f"items_{build}.json").write_text(json.dumps(cat), encoding="utf-8")
    if spells is not None:
        (tmp_path / f"spells_{build}.json").write_text(json.dumps(spells), encoding="utf-8")


def test_catalog_checks_pass_on_a_good_catalog(tmp_path):
    write_catalog(tmp_path, catalog(), {"spell_count": 1, "spells": {"USD_A": {"usage": {"role": "combat_damage"}}}})
    r = by_name(st.check_catalog(tmp_path, "1"))
    assert {v["status"] for v in r.values()} == {st.PASS}, r


def test_catalog_checks_catch_problems(tmp_path):
    cat = catalog()
    cat["items"]["ITEM_Sword_Iron"]["attacks"]["primary"]["action"] = "/G/Missing.Missing_C"
    cat["source"]["errors"] = ["boom"]
    write_catalog(tmp_path, cat, {"spells": {"USD_A": {"usage": {}}}})
    r = by_name(st.check_catalog(tmp_path, "1"))
    assert r["catalog integrity"]["status"] == st.FAIL and "no resolvable primary" in r["catalog integrity"]["detail"]
    assert r["catalog spot items"]["status"] == st.FAIL and "no attack chain" in r["catalog spot items"]["detail"]
    assert r["spell catalog"]["status"] == st.FAIL


def test_missing_catalog_for_build_fails_with_a_hint(tmp_path):
    r = st.check_catalog(tmp_path, "999")
    assert r[0]["status"] == st.FAIL and "build_catalog" in r[0]["detail"]


def test_main_offline_exit_code(tmp_path, monkeypatch, capsys):
    write_catalog(tmp_path, catalog(), {"spells": {"USD_A": {"usage": {"role": "x"}}}})
    monkeypatch.setenv("DW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("DW_DUMPS_DIR", str(tmp_path / "nodumps"))
    assert st.main(["--offline", "--build", "1", "--json", str(tmp_path / "out.json")]) == 0
    out = capsys.readouterr().out
    assert "SKIP" in out and "--offline" in out and "0 failed" in out
    assert json.loads((tmp_path / "out.json").read_text())["build"] == "1"
    assert st.main(["--offline", "--build", "2"]) == 1  # no catalog for that build

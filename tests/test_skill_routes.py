"""Offline tests for tools/skill_routes.py: the checklist parse (the real director.md §15 and a fixture table),
placeholder resolution, outcome classification, the guards, the stop rules and the results shape. No client."""
from __future__ import annotations

from tools import skill_routes as R

TABLE = """
## 15. Live verification order (fixture)

| # | Skill | Call | Precondition | Risk |
|---|---|---|---|---|
| 1 | Woodcutting | `gather {resource: ash, count: 2}` | an axe | none |
| 2 | Fishing | `fish {count: 1}` (after `fishing_spots`) | a net (fixture ok: ITEM_FishingNet_CoarseNet x1) | fit |
| 3 | Attack | `attack {target: <weak creature>}` with a melee weapon | a creature | fight |
| 4 | Ranged | `attack {target, weapon: <bow>}` | a bow | aim |

## 16. Next
"""


def test_parse_real_checklist_has_the_12_skills_in_order():
    routes = R.parse_checklist(R.DIRECTOR.read_text(encoding="utf-8"))
    assert [r.skill for r in routes][:2] == ["Woodcutting", "Mining"]
    assert len(routes) == 12
    assert {r.skill for r in routes} >= {"Fishing", "Agility", "Runecrafting", "Construction", "Farming", "Magic", "Ranged"}
    tend = next(r for r in routes if r.skill == "Farming")
    assert tend.tool == "tend" and tend.placeholders == {"item": "<spade>"} and "farm_plots" in tend.before


def test_parse_fixture_table():
    rs = R.parse_checklist(TABLE)
    assert [r.n for r in rs] == [1, 2, 3, 4]
    assert rs[0].tool == "gather" and rs[0].args == {"resource": "ash", "count": 2} and not rs[0].fight
    assert rs[1].before == ["fishing_spots"] and rs[1].fixture == ["ITEM_FishingNet_CoarseNet x1"]
    assert rs[2].fight and rs[2].placeholders == {"target": "<weak creature>"}
    assert rs[3].placeholders == {"target": "<target>", "weapon": "<bow>"}


def test_classify():
    assert R.classify({"ok": True}, 8.0)[0] == "pass"
    assert R.classify({"ok": True}, 0.0)[0] == "failed"
    assert R.classify({"ok": False, "reason": "not_implemented"}, None)[0] == "gap"
    assert R.classify({"ok": False, "reason": "verification_failed", "data": {"detail": "x"}}, None)[0] == "gap"
    v, why = R.classify({"ok": False, "reason": "wrong_tool", "data": {"detail": "I need a net"}}, None)
    assert v == "skipped" and "I need a net" in why


class FakeBody:
    def __init__(self, xp_gain=10.0, reply=None, hp_seq=None, items=None, creatures=None):
        self.xp = {"Woodcutting": 100.0, "Fishing": 0.0, "Attack": 50.0, "Ranged": 0.0}
        self.gain, self.reply, self.calls = xp_gain, reply, []
        self.hp_seq = list(hp_seq or [])
        self.items = items or []
        self.creatures = creatures if creatures is not None else [{"id": "wolf_1", "pl": 3, "distance": 9}, {"id": "rat_1", "pl": 1, "distance": 20}]
        self.grants = []

    def call(self, tool, args, timeout):
        self.calls.append((tool, dict(args)))
        if tool == "get_state":
            return {"ok": True, "data": {"skills": [{"skill": k, "xp": v} for k, v in self.xp.items()], "nearby_entities": self.creatures}}
        if tool == "inventory":
            return {"ok": True, "data": {"hotbar": self.items, "bag": [], "loadout": []}}
        if tool in ("fishing_spots", "stop", "equip"):
            return {"ok": True, "data": {}}
        rep = self.reply or {"ok": True, "data": {}}
        if rep.get("ok"):
            skill = {"gather": "Woodcutting", "fish": "Fishing", "attack": "Attack"}.get(tool)
            if skill:
                self.xp[skill] += self.gain
        return rep

    def health(self):
        return self.hp_seq.pop(0) if self.hp_seq else 1.0


def env_of(b, slot=True, guard_err=None):
    def guard():
        if guard_err:
            raise RuntimeError(guard_err)
    return R.Env(call=b.call, health=b.health, slot_ok=lambda: slot, guard=guard,
                 grant=lambda item, n: b.grants.append((item, n)) or {"ok": True}, sleep=lambda s: None)


def test_guards_refuse_without_the_slot_or_on_a_non_dev_world():
    b = FakeBody()
    assert "slot" in R.run(env_of(b, slot=False), R.parse_checklist(TABLE))["refused"]
    out = R.run(env_of(b, guard_err="client is on 1.2.3.4:7777, not the local dev server"), R.parse_checklist(TABLE))
    assert out["ok"] is False and "dev-world guard" in out["refused"] and not b.calls


def test_pass_when_xp_rises_and_the_tool_is_ok():
    b = FakeBody()
    out = R.run(env_of(b), R.parse_checklist(TABLE), only={"woodcutting"})
    row = out["rows"][0]
    assert row["verdict"] == "pass" and row["xp_gain"] == 10.0


def test_fixture_grant_only_when_the_row_allows_it():
    b = FakeBody()
    R.run(env_of(b), R.parse_checklist(TABLE), only={"woodcutting", "fishing"})
    assert b.grants == [("ITEM_FishingNet_CoarseNet", 1)]


def test_missing_prerequisite_is_skipped_with_the_reason_never_granted():
    b = FakeBody(reply={"ok": False, "reason": "wrong_tool", "data": {"detail": "I need a pickaxe"}})
    out = R.run(env_of(b), R.parse_checklist(TABLE), only={"woodcutting"})
    assert out["rows"][0]["verdict"] == "skipped" and "pickaxe" in out["rows"][0]["why"] and not b.grants


def test_gap_is_logged():
    b = FakeBody(reply={"ok": False, "reason": "not_implemented", "data": {"detail": "no tool"}})
    out = R.run(env_of(b), R.parse_checklist(TABLE), only={"woodcutting"})
    assert out["rows"][0]["verdict"] == "gap" and out["gaps"]


def test_placeholder_resolves_the_weakest_creature():
    b = FakeBody()
    out = R.run(env_of(b), R.parse_checklist(TABLE), only={"attack"})
    assert out["rows"][0]["args"]["target"] == "rat_1"


def test_placeholder_with_nothing_skips_naming_it():
    b = FakeBody(creatures=[])
    out = R.run(env_of(b), R.parse_checklist(TABLE), only={"attack"})
    assert out["rows"][0]["verdict"] == "skipped" and "<weak creature>" in out["rows"][0]["why"]


def test_low_health_stops_the_fight_and_skips_later_fight_rows():
    import threading
    gate = threading.Event()

    class Slow(FakeBody):
        def call(self, tool, args, timeout):
            if tool == "attack":
                gate.wait(5)
            return super().call(tool, args, timeout)

    b = Slow(hp_seq=[0.9, 0.4], items=[{"name": "Ash Bow", "category": "Item.Equipment.Weapon.Bow"}])
    orig = b.call

    def call(tool, args, timeout):
        if tool == "stop":
            gate.set()
        return orig(tool, args, timeout)
    b.call = call
    out = R.run(env_of(b), R.parse_checklist(TABLE), only={"attack", "ranged"})
    assert out["rows"][0]["verdict"] == "stopped_low_hp"
    assert out["rows"][1]["verdict"] == "skipped" and "low health" in out["rows"][1]["why"]


def test_weapon_named_by_the_row_is_equipped_first():
    b = FakeBody(items=[{"name": "Ash Bow", "category": "Item.Equipment.Weapon.Bow"}])
    out = R.run(env_of(b), R.parse_checklist(TABLE), only={"ranged"})
    tools = [c[0] for c in b.calls]
    assert ("equip", {"item": "Ash Bow"}) in b.calls and tools.index("equip") < tools.index("attack")
    assert "weapon" not in out["rows"][0]["args"]

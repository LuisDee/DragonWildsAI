"""tools/job_run.py, the vault capstone (goal item 4, Crasorak Kara) in stages K1-K4: the end predicates at_place,
in_vault, boss_killed and left_vault, what snapshot() keeps of the vault, and K1/K2 as trials of job K on a fake body.
Offline: every read is a fake get_state or brain-log row; the creature names are data/bestiary.json's."""
from __future__ import annotations

import pytest

from tools import job_run as j

T0 = 1000.0
DOOR = [374.58, 1918.74, -2.76]
HOME = [182.4, 1839.9, 0.0]
NEAR = [370.7, 1915.0, -0.7]  # 5.4 m SW of the door (vault_probe SPOTS["door"])
INSIDE = [9000.0, 9000.0, -50.0]


def gs(pos=HOME, in_vault=None, vault=None, kills=(), interactables=(), **extra):
    d = {"position": list(pos) if pos else None, "inventory_items": [], "interactables": list(interactables),
         "recent_kills": list(kills), **extra}
    if in_vault is not None:
        d["in_vault"] = in_vault
    if vault is not None:
        d["vault"] = vault
    return d


def door_row(at=DOOR, **kw):
    return {"id": "BP_InteractablePlayerTeleporter_C_UAID_18C04D97CB3D30D401_1397338720", "name": "Crasorak Kara",
            "prompt": "Enter", "actor_position": list(at), "position": [at[0] + 0.5, at[1], at[2] + 1],
            "distance": 5.4, "kind": "interactable", "actions": ["interact"], **kw}


def kill(creature, cls=None, iso="2026-11-18T12:00:00Z", mine=True):
    return {"creature": creature, "class": cls, "iso": iso, "mine": mine, "looted": False}


S = j.snapshot


@pytest.fixture(scope="module")
def doc():
    return j.load_jobs()


@pytest.fixture(scope="module")
def k():
    return j.job_of("K", j.load_jobs())


# ------------------------------------------------------------------ the data
def test_k_is_one_ask_in_a_players_words_with_four_stages(doc, k):
    assert k["line"].startswith("claude, ") and "\n" not in k["line"]
    for word in ("go_to", "interact", "attack", "tool", "step", "lever", "teleport"):  # never how
        assert word not in k["line"].lower()
    assert set(k["rungs"]) == {"K1", "K2", "K3", "K4"} and not k["held_out"]
    assert set(k["end"]) <= set(j.PREDICATES)
    for name, r in k["rungs"].items():
        assert r["from"] and r["end"] and set(r["end"]) <= set(j.PREDICATES), name
        assert r["unverified_live"], name  # what is not yet seen live is said, per stage
    assert k["rungs"]["K1"]["from"] == "ClaudeDev"
    assert k["rungs"]["K2"]["from"] == k["rungs"]["K3"]["from"] == "vault_door"  # a K1 run's save (rule 8)
    v = j.rung_job(k, "K2")
    assert v["line"] == k["line"] and v["start"] == "vault_door" and v["end"] == {"in_vault": {"vault": "Crasorak Kara"}}


def test_k_creatures_are_bestiary_entries(k):
    best = j._bestiary()
    for r in [k["end"]] + [x["end"] for x in k["rungs"].values()]:
        if "boss_killed" in r:
            assert r["boss_killed"]["creature"] in best


# ------------------------------------------------------------------ snapshot keeps the vault
def test_snapshot_keeps_in_vault_vault_rows_kills_and_fight():
    lever = {"id": "lever_1", "name": "Lever", "prompt": "Pull", "position": [1, 2, 3], "switch_position": 0,
             "switch_highest": 1, "drives": ["gate_1"]}
    bench = {"id": "bench_1", "name": "Workbench", "prompt": "Craft", "position": [1, 2, 3]}
    s = S(gs(in_vault=True, vault="Crasorak Kara", kills=[kill("Giant Rat")], interactables=[door_row(), lever, bench],
             fight={"target": "Giant Rat", "phase": "engage"}))
    assert s["in_vault"] is True and s["vault"] == "Crasorak Kara"
    assert [r["id"] for r in s["vault_rows"]] == [door_row()["id"], "lever_1"]  # the bench is not a vault row
    assert s["vault_rows"][1]["switch_position"] == 0 and s["vault_rows"][1]["drives"] == ["gate_1"]
    assert s["recent_kills"][0]["creature"] == "Giant Rat" and s["fight"]["phase"] == "engage"
    out = S(gs())
    assert out["in_vault"] is None and out["vault"] is None  # unread is None, never False
    assert out["vault_rows"] == [] and out["recent_kills"] == [] and out["fight"] is None


# ------------------------------------------------------------------ at_place
SPEC_K1 = {"door": "Crasorak Kara", "at": DOOR[:2], "r_m": 8}


def test_at_place_by_the_door_row_or_the_data_spot():
    ok, why = j.p_at_place(SPEC_K1, {}, S(gs(NEAR, interactables=[door_row()])))
    assert ok is True and "Crasorak Kara row" in why
    ok, why = j.p_at_place(SPEC_K1, {}, S(gs(NEAR)))  # the census did not list it: the data's spot
    assert ok is True and "no Crasorak Kara row" in why
    ok, why = j.p_at_place(SPEC_K1, {}, S(gs(HOME, interactables=[door_row()])))
    assert ok is False and "within 8" in why
    # the door row, read live, wins over the data when they differ (the game's position)
    moved = door_row(at=[NEAR[0] + 30, NEAR[1], 0])
    assert j.p_at_place(SPEC_K1, {}, S(gs(NEAR, interactables=[moved])))[0] is False
    assert j.p_at_place(SPEC_K1, {}, S(gs(None)))[0] is None  # no position: unread, never a pass or a fail


# ------------------------------------------------------------------ in_vault
def test_in_vault_reads_the_game_flag_and_the_vault_that_holds_him():
    spec = {"vault": "Crasorak Kara"}
    assert j.p_in_vault(spec, {}, S(gs(INSIDE, True, "Crasorak Kara")))[0] is True
    assert j.p_in_vault(spec, {}, S(gs(INSIDE, True, "Takla Kara")))[0] is False
    assert j.p_in_vault(spec, {}, S(gs(NEAR, False)))[0] is False
    ok, why = j.p_in_vault(spec, {}, S(gs(INSIDE, True)))  # the registry named no box (complete=false)
    assert ok is None and "registry" in why
    assert j.p_in_vault(spec, {}, S(gs(NEAR)))[0] is None  # in_vault not read
    assert j.p_in_vault(True, {}, S(gs(INSIDE, True)))[0] is True  # any vault


# ------------------------------------------------------------------ boss_killed
OVERLORD = {"creature": "Vault Overlord", "vault": "Crasorak Kara", "mine": True}


def seen(*kills, in_vault=True, vault="Crasorak Kara"):
    return {"kills_seen": [{**x, "in_vault": in_vault, "vault": vault} for x in kills]}


def test_boss_killed_by_name_alias_or_game_class():
    assert j.p_boss_killed(OVERLORD, {}, seen(kill("Vault Overlord")))[0] is True
    assert j.p_boss_killed(OVERLORD, {}, seen(kill("Vault overlord")))[0] is True  # a bestiary alias
    # the AIName unread (the creature row falls back to its class word): its class stem names it
    assert j.p_boss_killed(OVERLORD, {}, seen(kill("BP_AI_VaultOverlord_C_3", "BP_AI_VaultOverlord_Character_C")))[0]
    # the bestiary's class_names: Goblin Runt's class is RuntGoblin
    assert j.p_boss_killed({"creature": "Goblin Runt"}, {}, seen(kill("?", "BP_AI_RuntGoblin_Character_C")))[0]
    ok, why = j.p_boss_killed(OVERLORD, {}, seen(kill("Vault Guardian Hulk"), kill("Giant Rat", iso="x")))
    assert ok is False and "Vault Guardian Hulk" in why
    # a spec class read live is matched too
    assert j.p_boss_killed({"creature": "Vault Overlord", "class": "BP_AI_Colossus_C"}, {},
                           seen(kill("Big One", "BP_AI_Colossus_C")))[0] is True


def test_boss_killed_only_in_the_run_his_own_and_in_the_vault():
    old = kill("Vault Overlord", iso="2026-11-17T09:00:00Z")
    start = S(gs(kills=[old]))
    assert j.p_boss_killed(OVERLORD, start, seen(old))[0] is False  # the start read held it: not this run's
    ok, why = j.p_boss_killed(OVERLORD, {}, seen(kill("Vault Overlord", mine=False)))
    assert ok is False and "not by his hand" in why
    assert j.p_boss_killed(OVERLORD, {}, seen(kill("Vault Overlord"), in_vault=False, vault=None))[0] is False
    assert j.p_boss_killed(OVERLORD, {}, seen(kill("Vault Overlord"), vault=None))[0] is None  # unnamed vault
    assert j.p_boss_killed(OVERLORD, {}, seen(kill("Vault Overlord"), in_vault=None, vault=None))[0] is None
    # a plain end read (no run around it): its own recent_kills and in_vault
    assert j.p_boss_killed(OVERLORD, {}, S(gs(INSIDE, True, "Crasorak Kara", kills=[kill("Vault Overlord")])))[0]


# ------------------------------------------------------------------ left_vault
def test_left_vault_inside_then_out():
    spec = {"vault": "Crasorak Kara"}
    tr = lambda *xs: {"vault_trace": [{"t": i, "in_vault": a, "vault": b} for i, (a, b) in enumerate(xs)]}  # noqa: E731
    assert j.p_left_vault(spec, {}, tr((False, None), (True, "Crasorak Kara"), (False, None)))[0] is True
    assert j.p_left_vault(spec, {}, tr((False, None), (True, "Crasorak Kara")))[0] is False  # still inside
    assert j.p_left_vault(spec, {}, tr((False, None)))[0] is False  # never in
    assert j.p_left_vault(spec, {}, tr((True, "Takla Kara"), (False, None)))[0] is False
    assert j.p_left_vault(spec, {}, tr((True, None), (False, None)))[0] is None  # inside, vault unnamed
    assert j.p_left_vault(spec, {}, {"vault_trace": []})[0] is None


def test_seen_keeps_the_vault_trace_at_changes_and_each_kill_once_with_its_read():
    sn = j._Seen()
    rat = kill("Giant Rat")
    for t, g in [(0, gs(NEAR, False)), (3, gs(NEAR, False)), (6, gs(INSIDE, True, "Crasorak Kara")),
                 (9, gs(INSIDE, True, "Crasorak Kara", kills=[rat])), (12, gs(INSIDE, True, "Crasorak Kara", kills=[rat])),
                 (15, gs(NEAR, False, kills=[rat]))]:
        sn.see(S(g), t)
    out = S(gs(NEAR, False))
    sn.into(out)
    assert [(r["t"], r["in_vault"]) for r in out["vault_trace"]] == [(0, False), (6, True), (15, False)]
    assert len(out["kills_seen"]) == 1 and out["kills_seen"][0]["vault"] == "Crasorak Kara"
    assert out["kills_seen"][0]["t"] == 9
    assert j.p_left_vault({"vault": "Crasorak Kara"}, {}, out)[0] is True


# ------------------------------------------------------------------ K1 and K2 on a fake body
class Body:
    def __init__(self, states, script=()):
        self.t, self.states, self.script, self.sent = T0, states, list(script), []

    def now(self): return self.t
    def sleep(self, s): self.t += s
    def start_brain(self): return True
    def brain_logs(self): return ["brain-live-fake.jsonl"]
    def rows(self, a, b): return [r for r in self.script if a <= r["ts"] <= min(b, self.t)]
    def send(self, line): self.sent.append(line); return True  # noqa: E702
    def state(self): return self.states(self.t)
    def leave_dialogue(self): return []
    def stop_all(self): return []
    def inspect(self, cid): return {"ok": False, "reason": "unknown_target"}


def model(ts):
    return [{"ts": ts, "kind": "prompt", "component": "controller", "model": "claude-haiku-5-5"},
            {"ts": ts + 1, "kind": "llm_response", "component": "controller"}]


def walk(ts, to):
    return [{"ts": ts, "kind": "tool_call", "call": "w1", "tool": "go_to", "args": {"target": to}}]


def test_k1_ends_at_the_door_read_often(k):
    k1 = j.rung_job(k, "K1")
    arrive = 42.0
    body = Body(lambda t: gs(NEAR if t >= T0 + arrive else HOME, False,
                             interactables=[door_row()] if t >= T0 + arrive else []), model(T0 + 1) + walk(T0 + 3, DOOR))
    rec = j.run_job(body, k1, {})
    assert body.sent == [k["line"]]
    assert rec["ended"] == "job done" and rec["done"] is True and rec["rung"] == "K1"
    assert rec["run"].endswith("-K-K1") and "Crasorak Kara row" in rec["done_why"]
    assert rec["wall_s"] <= arrive + j.FAST_SAMPLE_S + 1  # read every 3 s: the stand at the door is caught
    assert rec["state_end"]["in_vault"] is False and rec["state_end"]["vault_rows"][0]["name"] == "Crasorak Kara"


def test_k2_ends_inside_and_an_unnamed_vault_is_unread(k):
    k2 = j.rung_job(k, "K2")
    body = Body(lambda t: gs(INSIDE, True, "Crasorak Kara") if t >= T0 + 20 else gs(NEAR, False,
                                                                                      interactables=[door_row()]),
                model(T0 + 1) + [{"ts": T0 + 3, "kind": "tool_call", "call": "i1", "tool": "interact",
                                  "args": {"target": door_row()["id"]}}])
    rec = j.run_job(body, k2, {})
    assert rec["ended"] == "job done" and rec["done"] is True
    assert [x["in_vault"] for x in rec["state_end"]["vault_trace"]] == [False, True]
    # complete=false: inside, but no vault named: never a pass, the run is left out (unread)
    body = Body(lambda t: gs(INSIDE, True) if t >= T0 + 20 else gs(NEAR, False), model(T0 + 1))
    rec = j.run_job(body, k2, {"deadline": 60})
    assert rec["done"] is False and rec.get("unread") and "registry" in rec["unread"]
    assert rec["verdict"]["pass"] is False

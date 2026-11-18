"""tools/job_run.py `--until own_chest`: a checkpoint probe that ends once the game shows a container whose owner is
HIM (this character, not his line nor his account) holding an asked item, with the job not done. Offline, fakes only.

On 2026-11-18 forks of ClaudeDev found the base crates "ClaudeDev's, not mine" and asked the player which to use
(runs 052749, 053829, 080852-N1-I5); the mid checkpoint (--until mid) stops before he has a chest of his own, so every
trial from it met the same question. A checkpoint saved after his first store into a crate of his own does not.
"""
from __future__ import annotations

import pytest

from tools import job_run as j
from tests.test_job_run import T0, FakeIO, call, model, result, state

ASH, STONE = "ITEM_Resources_Wood_Ash", "ITEM_Resources_Stone"
DEV_GUID = "E71C5DC146F0A55B69FF52A881255DEF"   # ClaudeDev: the world 'base' crates' OwningCharacterGuid
FORK_GUID = "11111111222222223333333344444444"
BASE_CRATE = "BP_BaseBuilding_Crate_C_2147472971"
HIS_CRATE = "BP_BaseBuilding_Crate_C_900"
DEV_OWNER = {"owner": "ClaudeDev (another character of your account)", "owner_name": "ClaudeDev",
             "owner_guid": DEV_GUID, "same_account": True, "mine": False}
HIS_OWNER = {"owner": "yours", "owner_guid": FORK_GUID, "mine": True}
OPTS = {"until": "own_chest", "own_guids": [FORK_GUID, DEV_GUID], "self_guid": FORK_GUID}


@pytest.fixture(scope="module")
def doc():
    return j.load_jobs()


def store(ts, cid, container, n, owner, contents):
    return result(ts, cid, "store", data={"container": container, "item": ASH, "count": n, "inside_now": n,
                                          "contents": contents, **owner})


class OwnerIO(FakeIO):
    """inspect carries the game's owner read of each crate (sense.owner_row), as the body reports it."""
    owners = {BASE_CRATE: DEV_OWNER, HIS_CRATE: HIS_OWNER}

    def inspect(self, cid):
        r = super().inspect(cid)
        if r.get("ok"):
            r["data"].update(self.owners.get(cid) or {})
        return r


# ------------------------------------------------------------------ the mode
def test_until_takes_own_chest_and_it_is_a_probe():
    assert j.until_ok("own_chest")
    assert j.is_probe({"until": "own_chest"})
    assert j.not_counted({"until": "own_chest", "ended": "own chest"}).startswith("a checkpoint probe")


def test_self_owned_is_this_character_only():
    assert j.self_owned(HIS_OWNER, FORK_GUID) is True
    assert j.self_owned({"owner": "Claude", "owner_guid": FORK_GUID.lower(), "mine": None}, FORK_GUID) is True
    # his line and his account are not HIM: ClaudeDev's crate is ClaudeDev's for this probe
    assert j.self_owned(DEV_OWNER, FORK_GUID) is False
    assert j.self_owned({"items": {ASH: 3}}, FORK_GUID) is None  # no owner in the read


# ------------------------------------------------------------------ a probe that ends at his own chest
def test_probe_ends_at_his_first_store_into_a_crate_of_his_own(doc):
    rows = model(T0 + 1) + [call(T0 + 3, "b1", "build", {"piece": "crate"}), result(T0 + 12, "b1", "build"),
                            call(T0 + 14, "s1", "store", {"item": "Ash Logs"}),
                            store(T0 + 16, "s1", HIS_CRATE, 4, HIS_OWNER, ["4 Ash Logs"]),
                            call(T0 + 18, "g1", "gather", {"resource": "stone", "count": 10}),
                            result(T0 + 60, "g1", "gather")]
    crate = lambda t, cid: ([{"item": ASH, "name": "Ash Logs", "count": 4}] if t >= T0 + 16 else []) \
        if cid == HIS_CRATE else None
    io = OwnerIO(script=rows, chests=crate,
                 states=lambda t: state(carried={ASH: 9 if t < T0 + 16 else 5, STONE: 5},
                                        mine=[HIS_CRATE] if t >= T0 + 12 else []))
    rec = j.run_job(io, j.job_of("N1", doc), {**OPTS, "deadline": 120})
    assert rec["ended"] == "own chest" and rec["probe"] is True and rec["wall_s"] < 30
    oc = rec["own_chest"]
    assert oc["ok"] and oc["container"] == HIS_CRATE and oc["items"] == {ASH: 4} and oc["progress"] < 1
    ok, why = j.save_ok(rec, "own_chest")
    assert ok and HIS_CRATE in why


def test_a_store_into_claudedevs_crate_is_not_his_own_chest(doc):
    # the line (game_owner) counts ClaudeDev's crate for the job's end; the probe wants a chest of HIS
    rows = model(T0 + 1) + [call(T0 + 3, "s1", "store", {"item": "Ash Logs"}),
                            store(T0 + 5, "s1", BASE_CRATE, 4, DEV_OWNER, ["4 Ash Logs"])]
    crate = lambda t, cid: [{"item": ASH, "name": "Ash Logs", "count": 4}] if cid == BASE_CRATE else None
    io = OwnerIO(script=rows, chests=crate, states=lambda t: state(carried={ASH: 5, STONE: 5}))
    rec = j.run_job(io, j.job_of("N1", doc), {**OPTS, "deadline": 90})
    assert rec["ended"] != "own chest"
    ok, why = j.save_ok(rec, "own_chest")
    assert not ok and why.startswith("he never made a chest of his own: ")
    assert "ClaudeDev" in why and BASE_CRATE in why


def test_a_run_that_asked_the_player_says_why_it_saved_nothing(doc):
    rows = model(T0 + 1) + [{"ts": T0 + 4, "kind": "say",
                             "text": "Those crates are ClaudeDev's, not mine. Which one should I use?"}]
    io = OwnerIO(script=rows, states=lambda t: state(carried={ASH: 1, STONE: 5}))
    rec = j.run_job(io, j.job_of("N1", doc), {**OPTS, "deadline": 90})
    ok, why = j.save_ok(rec, "own_chest")
    assert not ok and why.startswith("he never made a chest of his own: ")
    assert "Which one should I use?" in why and "no container" in why and rec["ended"] in why


def test_his_own_chest_with_the_job_done_is_not_a_checkpoint(doc):
    full = [{"item": ASH, "name": "Ash Logs", "count": 20}, {"item": STONE, "name": "Stone", "count": 10}]
    rows = model(T0 + 1) + [call(T0 + 3, "s1", "store", {"item": "all"}),
                            result(T0 + 5, "s1", "store", data={
                                "container": HIS_CRATE, "contents": ["20 Ash Logs", "10 Stone"],
                                "taken": [{"item": ASH, "count": 20}, {"item": STONE, "count": 10}], **HIS_OWNER})]
    io = OwnerIO(script=rows, chests=lambda t, cid: (full if t >= T0 + 5 else []) if cid == HIS_CRATE else None,
                 states=lambda t: state(carried={ASH: 21 if t < T0 + 5 else 1, STONE: 15 if t < T0 + 5 else 5},
                                        mine=[HIS_CRATE]))
    rec = j.run_job(io, j.job_of("N1", doc), {**OPTS, "deadline": 60})
    ok, why = j.save_ok(rec, "own_chest")
    assert not ok and "done" in why


def test_a_crate_of_his_holding_items_at_the_start_is_not_the_moment(doc):
    # a pair checkpoint already has his crate with logs in it: only what goes in after the line ends the probe
    held = [{"item": ASH, "name": "Ash Logs", "count": 3}]
    io = OwnerIO(script=model(T0 + 1), chests=lambda t, cid: held if cid == HIS_CRATE else None,
                 states=lambda t: state(carried={ASH: 1, STONE: 5}, mine=[HIS_CRATE]))
    rec = j.run_job(io, j.job_of("N1", doc), {**OPTS, "deadline": 40})
    assert rec["ended"] != "own chest" and not j.save_ok(rec, "own_chest")[0]


# ------------------------------------------------------------------ the data
def test_n1_steps_and_the_i4_vehicle_start_from_the_own_chest_checkpoint(doc):
    n1 = j.job_of("N1", doc)
    i4 = doc["interruptions"]["I4"]
    assert n1["interrupt_from"] == "job_n1_own_chest"
    assert i4["job"] == "N2" and i4["from"] == "job_n1_own_chest"
    assert "own_chest" in i4["from_note"] and "own_chest" in n1["interrupt_from_note"]

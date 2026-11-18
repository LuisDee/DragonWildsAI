"""tools/job_run.py, job L1 ("make yourself a full set of leather armour and put it on"): the end read tells a piece
made in the run from one he carried in by its item instance (UItem.Guid, read by client_mod inventory.describe_item),
or by the start read showing he held none of it; a broken piece or one carried but not worn is not counted. Offline:
every read is a fake get_state."""
from __future__ import annotations

import pytest

from tools import job_run as j

COWL, BODY, CHAPS = "ITEM_Armour_T2_Head_Leather", "ITEM_Armour_T2_Body_Leather", "ITEM_Armour_T2_Legs_Leather"
SET = {"Head": COWL, "Body": BODY, "Legs": CHAPS}
G_OLD = "0A0A0A0A0B0B0B0B0C0C0C0C0D0D0D0D"  # the Leather Cowl ClaudeDev wears at the start (636 of 1000)


def row(item, where, slot=None, guid=None, durability=1000, broken=False, count=1):
    r = {"item": item, "count": count, "where": where, "durability": durability, "max_durability": 1000}
    if slot:
        r["loadout_slot"] = slot
    if guid:
        r["guid"] = guid
    if broken:
        r["broken"] = True
    return r


def gs(rows):
    return j.snapshot({"ok": True, "data": {"position": [0.0, 0.0, 0.0], "inventory_items": rows}})


def claude_dev_start(guids=True):
    """ClaudeDev as the L2 runs of 17 Nov read him: a Leather Cowl on, broken Adventurer's tunic and leggings."""
    return gs([row(COWL, "loadout", "Head", G_OLD if guids else None, durability=636),
               row("ITEM_Armour_T1_Body_Adventurers", "loadout", "Body", "B1" * 16 if guids else None, 0, True),
               row("ITEM_Armour_T1_Legs_Adventurers", "loadout", "Legs", "C1" * 16 if guids else None, 0, True),
               row("ITEM_Resources_Skin_Scraps", "bag", guid="D1" * 16 if guids else None, count=7)])


def made(end, items=(COWL, BODY, CHAPS)):
    end["crafted"] = {i: 1 for i in items}
    return end


@pytest.fixture(scope="module")
def job():
    return j.job_of("L1", j.load_jobs())


def test_snapshot_keeps_each_worn_instance_and_every_guid():
    s = claude_dev_start()
    assert s["worn_detail"]["Head"] == {"item": COWL, "guid": G_OLD, "durability": 636, "max_durability": 1000,
                                        "broken": False}
    assert s["worn_detail"]["Body"]["broken"] is True
    assert s["instances"][COWL] == [G_OLD] and s["instances"]["ITEM_Resources_Skin_Scraps"] == ["D1" * 16]


def test_the_cowl_he_wears_at_the_start_is_no_head_start(job):
    """Every L1 trial from ClaudeDev was NOT COUNTED (his cowl matched ITEM_Armour_T*_*Leather). The instance read now
    tells his old cowl from a new one, so the cowl is no head start; hides and leather still are."""
    assert j.not_counted(job, claude_dev_start()) is None
    assert j.not_counted(job, gs([row("ITEM_Resources_Animal_Hide", "bag", count=2)])).startswith("held at the start")
    assert j.not_counted(job, gs([row("ITEM_Resources_Leather", "bag", count=2)])).startswith("held at the start")


def test_a_new_cowl_on_and_the_old_one_in_the_bag_passes(job):
    end = made(gs([row(COWL, "loadout", "Head", "E1" * 16), row(BODY, "loadout", "Body", "E2" * 16),
                   row(CHAPS, "loadout", "Legs", "E3" * 16), row(COWL, "bag", guid=G_OLD, durability=636)]))
    ok, why = j.done(job, claude_dev_start(), end)
    assert ok is True, why


def test_the_old_cowl_still_on_with_a_new_one_in_the_bag_fails(job):
    """The false pass of the count rule: a cowl crafted in the run, two cowls held (+1), the old one worn."""
    end = made(gs([row(COWL, "loadout", "Head", G_OLD, durability=636), row(BODY, "loadout", "Body", "E2" * 16),
                   row(CHAPS, "loadout", "Legs", "E3" * 16), row(COWL, "bag", guid="E1" * 16)]))
    ok, why = j.done(job, claude_dev_start(), end)
    assert ok is False and "Head" in why and "had at the start" in why


def test_without_instance_reads_a_piece_he_held_at_the_start_is_unread_never_a_pass(job):
    end = made(gs([row(COWL, "loadout", "Head"), row(BODY, "loadout", "Body"), row(CHAPS, "loadout", "Legs"),
                   row(COWL, "bag", durability=636)]))
    ok, why = j.done(job, claude_dev_start(guids=False), end)
    assert ok is None and "Head" in why and "cannot tell" in why


def test_without_instance_reads_a_piece_he_held_none_of_is_judged_by_the_start_read(job):
    start = gs([row("ITEM_Resources_Stone", "bag", count=5)])
    end = made(gs([row(COWL, "loadout", "Head"), row(BODY, "loadout", "Body"), row(CHAPS, "loadout", "Legs")]))
    ok, why = j.done(job, start, end)
    assert ok is True, why


def test_a_piece_carried_but_not_worn_is_not_counted(job):
    end = made(gs([row(COWL, "loadout", "Head", "E1" * 16), row(BODY, "loadout", "Body", "E2" * 16),
                   row(CHAPS, "bag", guid="E3" * 16),
                   row("ITEM_Armour_T1_Legs_Adventurers", "loadout", "Legs", "C1" * 16, 0, True)]))
    ok, why = j.done(job, claude_dev_start(), end)
    assert ok is False and "Legs: ITEM_Armour_T1_Legs_Adventurers worn" in why


def test_a_broken_piece_is_not_counted(job):
    end = made(gs([row(COWL, "loadout", "Head", "E1" * 16), row(BODY, "loadout", "Body", "E2" * 16, 0, True),
                   row(CHAPS, "loadout", "Legs", "E3" * 16)]))
    ok, why = j.done(job, claude_dev_start(), end)
    assert ok is False and "Body" in why and "broken" in why
    end = made(gs([row(COWL, "loadout", "Head", "E1" * 16), row(BODY, "loadout", "Body", "E2" * 16, durability=0),
                   row(CHAPS, "loadout", "Legs", "E3" * 16)]))
    assert j.done(job, claude_dev_start(), end)[0] is False  # durability 0 without the flag: broken too


def test_a_worn_piece_never_crafted_in_the_run_fails(job):
    end = made(gs([row(COWL, "loadout", "Head", "E1" * 16), row(BODY, "loadout", "Body", "E2" * 16),
                   row(CHAPS, "loadout", "Legs", "E3" * 16)]), items=(COWL, BODY))
    ok, why = j.done(job, claude_dev_start(), end)
    assert ok is False and "Legs" in why and "no craft" in why


def test_his_words_are_never_read(job):
    """Only the reads: a say that he put the set on changes nothing (done() takes no rows but the crafts)."""
    end = gs([row(COWL, "loadout", "Head", G_OLD, durability=636)])
    end["says"] = [{"text": "I made a full set of leather armour and put it on"}]
    assert j.done(job, claude_dev_start(), end)[0] is False

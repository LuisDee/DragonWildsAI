"""Game-data cards keep their structured fields whole (brain/knowledge.py _clip_card; director.md section 13 item 4:
a 500-character cut lost the recipe quantities real Sonnet needed)."""
import re

from brain import knowledge as K


def test_recipe_cards_from_game_data_keep_every_quantity():
    k = K.Knowledge()
    card = k.lookup("Bronze Bar")["data"]["results"][0]
    assert card["authoritative"] and card["title"] == "Bronze Bar"
    text = card["text"]
    assert "2 Bronze Bar from 3 Copper Ore + 3 Tin Ore at Furnace" in text  # the ore recipe, complete
    for alt in text.split("How to get: ", 1)[1].split("\n", 1)[0].split(K.OR):
        assert re.match(r"(\d+ .+ from \d+ .+|\d+ more way\(s\))", alt), alt  # never a half-cut alternative


def test_clip_card_cuts_by_whole_fields_and_says_what_it_left_out():
    alts = [f"1 Thing from {i} Part A + {i} Part B at Bench, Artisan skill; unlock: ALL ITEMS[ Part A ]"
            for i in range(1, 12)]
    body = K.NL.join(["Type: Metal", "Description: " + "long flavour " * 30, K.HOW + K.OR.join(alts),
                      "Weight 1, stacks to 99", "Used in 40 recipe(s): " + ", ".join(f"R{i}" for i in range(9)) + "…"])
    out = K._clip_card(body, 500)
    assert len(out) <= 500 + 60
    assert "Description:" not in out and "R4" not in out  # flavour and the long uses list go first
    how = next(x for x in out.split(K.NL) if x.startswith(K.HOW))
    kept = how[len(K.HOW):].split(K.OR)
    assert all(a in alts for a in kept[:-1]) and re.fullmatch(r"\d+ more way\(s\): look up its recipes", kept[-1])
    assert K._clip_card("short card", 500) == "short card"

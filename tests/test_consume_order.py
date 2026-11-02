from types import SimpleNamespace as C

from brain.consume_order import interleave

STATE = {"inventory_items": [
    {"where": "bag", "item": "ITEM_Consumable_Meat_Fillet", "name": "Fillet", "consumable": "food"},
    {"where": "hotbar", "item": "ITEM_Consumable_Water_Clean", "name": "Clean Water", "consumable": "drink"},
    {"where": "bag", "item": "ITEM_Potion_X", "name": "Potion", "consumable": "potion"},
]}


def call(name, item=None):
    return C(name=name, arguments={"item": item} if item else {"item": "Fillet", "to": "hotbar"})


def names(xs):
    return [(c.name, c.arguments.get("item")) for c in xs]


def test_a_drink_after_a_run_of_food_goes_second_and_nothing_is_lost():
    # live r1-20261102T050223Z: Fillet x4 then Clean Water: the drink waited ~18 s behind the food lock
    acts = [call("move_item"), call("consume", "Fillet"), call("consume", "Fillet"), call("consume", "fillet"),
            call("consume", "Clean Water"), call("consume", "Clean Water")]
    got = interleave(acts, STATE)
    assert names(got) == [("move_item", "Fillet"), ("consume", "Fillet"), ("consume", "Clean Water"), ("consume", "Fillet"),
                          ("consume", "Clean Water"), ("consume", "fillet")]
    assert sorted(map(id, got)) == sorted(map(id, acts))


def test_unknown_kinds_other_tools_and_single_calls_keep_the_models_order():
    acts = [call("consume", "Fillet"), call("consume", "Potion"), call("consume", "Clean Water")]
    assert interleave(acts, STATE) == acts  # a potion blocks every kind: no reorder
    acts = [call("consume", "Fillet"), call("move_item"), call("consume", "Clean Water")]
    assert interleave(acts, STATE) == acts  # never across another tool
    acts = [call("consume", "Fillet"), call("consume", "Fillet")]
    assert interleave(acts, STATE) == acts

"""lookup of a quest gives its walkthrough (real wiki snapshot). Live 2026-11-01: the brain made 0 lookup calls all
night, and lookup("Rune Mysteries") held only the page lead and Overview, never the rune altar or geyser steps."""
import pytest

from brain.knowledge import Knowledge


@pytest.fixture(scope="module")
def know():
    try:
        return Knowledge()
    except Exception as exc:  # the snapshot is optional on a fresh checkout
        pytest.skip(f"no knowledge index: {exc!r}")


@pytest.mark.parametrize("quest, title, says", [
    ("Rune Mysteries", "Rune Mysteries/Quick guide", "rune altar"),
    ("Ratcatcher", "Ratcatcher/Quick guide", "campfire"),
    ("Getting Started", "Getting Started", "Doric"),
    ("First Steps", "First Steps", "Wise Old Man"),
    ("Dragon Slayer", "Dragon Slayer", "Part I"),
])
def test_a_named_quest_comes_with_its_walkthrough(know, quest, title, says):
    w = know.lookup(quest)["data"]["walkthrough"]
    assert w["title"] == title and says in w["text"] and w["url"].startswith("https://")
    assert "Map:" not in w["text"] and len(w["text"]) <= 1600


def test_a_thing_that_is_no_quest_gets_no_walkthrough(know):
    assert "walkthrough" not in know.lookup("rune altar")["data"]

"""Game knowledge: the wiki mirror's wikitext conversion and API etiquette, the FTS5 knowledge index
(game data first and authoritative, wiki second with links) and the read-only ``lookup`` tool
(design docs/design/knowledge-lookup.md)."""
import io
import json
import os
import time

import pytest
from conftest import Rig

from brain.controller import LOOKUP_RULE
from brain.interface import BODY_TOOLS, BRAIN_TOOLS, READ_TOOLS
from brain.knowledge import Knowledge, game_docs
from brain.llm import FakeLLM
from tools import wiki_mirror as wm

# --------------------------------------------------------------------------- fixtures (made-up game)

WIKITEXT = """{{External|rs=Glowcap|os=Glowcap}}
{{Infobox Item
| name = Glowcap Brew
| image = Glowcap Brew.png
| release = 1 May 2025
| item_type = Drink
| hydration = 40
| description = Fizzy and faintly luminous.
}}
'''Glowcap brew''' is a [[drink]] that grants the perk [[Night Eyes|night vision]] for 60 seconds.{{plink|Glowcap}} grows in [[Mossy Hollow]].<ref>dev chat</ref>
[[Category:Drinks]]

==Recipe==
{{Recipe
|facility = Brew Kettle
|mat1 = Glowcap
|mat1qty = 2
|output1 = Glowcap Brew
}}

==Stats==
{| class="wikitable"
!Name
!Heal
!Weight
|-
|Glowcap Brew
|
|0.5
|}

==Drops==
{{DropsTableHead}}
{{DropsLine|name=Glowcap Brew|quantity=1|rarity=Always}}
{{DropsTableBottom}}

==Update history==
{{UH|{{UL|date=1 June|update=* Secret patch note.}}}}

==Journal==
{{journal entry|Long lore text that should not be indexed because it is only flavour and not a fact.}}
"""


def make_data(d):
    d.mkdir(parents=True, exist_ok=True)
    items = {"build": "999", "items": {
        "ITEM_Kettle_Ladle": {"name": "Copper Ladle", "kind": "held", "role": "tool", "category": "ladle",
                              "slot": "right_hand", "tier": 2, "flavour": "Stirs {Placeholder}brews.",
                              "path": "/Game/Items/ITEM_Kettle_Ladle.ITEM_Kettle_Ladle", "weight": 1.0}}}
    recipes = {"build": "999", "stations": {
        "BrewKettle": {"display_name": "Brew Kettle", "kind": "processing", "class_names": ["BP_Station_Kettle_C"],
                       "recipes": ["RECIPE_Brew"], "accepted_fuels": ["ITEM_Coal"]},
        "UmS_Merchant_Bob": {"display_name": "Bob", "kind": "crafting", "recipes": ["RECIPE_Buy_Glowcap"]}},
        "recipes": {
            "RECIPE_Brew": {"id": "RECIPE_Brew", "inputs": [{"item": "ITEM_Glowcap", "name": "Glowcap", "count": 2}],
                            "outputs": [{"item": "ITEM_Brew", "name": "Glowcap Brew", "count": 1}],
                            "stations": ["BrewKettle"], "station_kinds": ["processing"], "processing_time": [5.0, 9.0],
                            "skill": "SKILL_Cooking",
                            "unlock": {"bundles": [{"query": "ALL ACTORS[ BP_Station_Kettle_C ]"}]}},
            "RECIPE_Buy_Glowcap": {"id": "RECIPE_Buy_Glowcap", "inputs": [{"item": "ITEM_Chit", "name": "Chit", "count": 3}],
                                   "outputs": [{"item": "ITEM_Glowcap", "name": "Glowcap", "count": 1}],
                                   "stations": ["UmS_Merchant_Bob"], "station_kinds": ["crafting"]},
            "RECIPE_Old": {"id": "RECIPE_Old", "test": True, "inputs": [], "outputs": [{"item": "ITEM_Brew", "count": 9}],
                           "stations": ["BrewKettle"]}},
        "items": {"ITEM_Brew": {"name": "Glowcap Brew", "category": "ItemFilter.Type.Consumable.Drink", "weight": 0.5,
                                "max_stack": 20, "path": "/Game/Items/ITEM_Brew.ITEM_Brew"},
                  "ITEM_Glowcap": {"name": "Glowcap", "category": "ItemFilter.Type.Food", "path": "/Game/ITEM_Glowcap"},
                  "ITEM_Chit": {"name": "Chit", "path": "/Game/ITEM_Chit"},
                  "ITEM_Coal": {"name": "Coal", "fuel_value": 30, "path": "/Game/ITEM_Coal"},
                  "ITEM_Brew_OLD": {"name": "Glowcap Brew", "path": "/Game/Deprecated/ITEM_Brew_OLD.ITEM_Brew_OLD"}}}
    spells = {"build": "999", "spells": {"USD_Glow": {"name": "Glow", "owning_perk": "P_Glow", "cooldown_s": 10.0,
                                                      "usage": {"role": "scouting", "use_when": "Lights up caves.",
                                                                "runes": {"Air": 2}}}},
              "perks": {"P_Glow": {"name": "Glow", "skill_name": "SKILL_Magic", "level": 7}},
              "perk_to_spell": {"P_Glow": "USD_Glow"}}
    for name, obj in (("items", items), ("recipes", recipes), ("spells", spells)):
        (d / f"{name}_999.json").write_text(json.dumps(obj), encoding="utf-8")
    return d


def make_wiki(d):
    (d / "pages").mkdir(parents=True, exist_ok=True)
    pages = {}
    for pid, title, text in ((1, "Glowcap Brew", WIKITEXT),
                             (2, "Mossy Hollow", "'''Mossy Hollow''' is a damp cave where [[Glowcap]] grows.")):
        rec = {"title": title, "pageid": pid, "revid": 10 + pid, "url": wm.page_url(title), **wm.convert(title, text),
               "wikitext": text}
        (d / "pages" / f"{pid}.json").write_text(json.dumps(rec), encoding="utf-8")
        pages[title] = {"pageid": pid, "revid": 10 + pid, "fetched_at": "x", "file": f"pages/{pid}.json"}
    (d / "manifest.json").write_text(json.dumps({"pages": pages, "redirects": {"Glow brew": "Glowcap Brew"}}),
                                     encoding="utf-8")
    return d


@pytest.fixture
def know(tmp_path):
    return Knowledge(data=make_data(tmp_path / "data"), wiki=make_wiki(tmp_path / "wiki"))


# --------------------------------------------------------------------------- wikitext -> text


def test_convert_keeps_facts_and_drops_chrome():
    c = wm.convert("Glowcap Brew", WIKITEXT)
    assert c["infobox"] == "Item" and c["categories"] == ["Drinks"]
    text = {s["heading"]: s["text"] for s in c["sections"]}
    lead = text[None]
    assert "hydration: 40" in lead and "item type: Drink" in lead
    assert "image" not in lead and "release" not in lead  # presentation keys
    assert "External" not in lead and "rs=" not in lead  # banner above the content
    assert "night vision for 60 seconds" in lead and "Glowcap grows in Mossy Hollow" in lead  # links, inline template
    assert "dev chat" not in lead  # refs
    assert "Recipe: facility=Brew Kettle; mat1=Glowcap; mat1qty=2; output1=Glowcap Brew" in text["Recipe"]
    assert "Glowcap Brew | - | 0.5" in text["Stats"]  # empty cells keep the columns aligned
    assert text["Drops"] == "DropsLine: name=Glowcap Brew; quantity=1; rarity=Always"  # table head/foot dropped
    assert "Update history" not in text and "Journal" not in text


def test_api_client_is_polite(monkeypatch):
    """Descriptive UA with contact, maxlag on every request, >= 1 s spacing, maxlag back-off."""
    seen, replies = [], [{"error": {"code": "maxlag", "lag": 7}}, {"query": {"pages": []}}]

    class Resp(io.BytesIO):
        headers = {"Retry-After": "0"}

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout=0):
        seen.append((req.full_url, dict(req.header_items()), time.monotonic()))
        return Resp(json.dumps(replies.pop(0)).encode())

    sleeps = []
    monkeypatch.setattr(wm.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(wm.time, "sleep", lambda s: sleeps.append(s))
    api = wm.Api(interval=0.1, log=lambda s: None)  # clamped to 1 s
    assert api.interval == 1.0
    api.get(action="query", titles="X")
    assert len(seen) == 2  # retried after maxlag
    url, headers, _ = seen[0]
    assert "maxlag=5" in url and "format=json" in url
    ua = headers.get("User-agent", "")
    assert "DWCompanion-wiki-mirror" in ua and "contact" in ua and "python" not in ua.lower()
    assert any(s >= 0.9 for s in sleeps)  # the second request waited for the interval


def test_mirror_is_incremental_by_revid(tmp_path, monkeypatch):
    calls = []

    class FakeApi:
        ua, requests = "ua", 0

        def query_all(self, **p):
            calls.append(p)
            if p.get("generator") == "allpages":
                yield {"pages": [{"title": "A", "pageid": 1, "lastrevid": 5,
                                  "redirects": [{"title": "Aa"}]},
                                 {"title": "B", "pageid": 2, "lastrevid": 9}]}
            else:
                ids = p["pageids"].split("|")
                yield {"pages": [{"title": {"1": "A", "2": "B"}[i], "pageid": int(i),
                                  "revisions": [{"revid": {"1": 5, "2": 9}[i], "slots": {"main": {"content": "x"}}}]}
                                 for i in ids]}

    root = tmp_path / "wiki"
    wm.mirror(root, FakeApi(), log=lambda s: None)
    man = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    assert set(man["pages"]) == {"A", "B"} and man["redirects"] == {"Aa": "A"} and "CC BY-NC-SA" in man["licence"]
    calls.clear()
    r = wm.mirror(root, FakeApi(), log=lambda s: None)
    assert r["fetched"] == 0 and not any("pageids" in c for c in calls)  # nothing changed: no content requests


# --------------------------------------------------------------------------- the index


def test_recipe_unlock_queries_preserve_operators_and_unknown_relation(tmp_path):
    data = make_data(tmp_path / "data")
    path = data / "recipes_999.json"
    recipes = json.loads(path.read_text(encoding="utf-8"))
    queries = ["ANY ITEMS[ Glowcap, Pebble ] AND ALL ACTORS[ BP_Station_Kettle_C ]",
               "UNKNOWN_FN[ x ] OR ALL ITEMS[ Berries ]"]
    recipes["recipes"]["RECIPE_Brew"]["unlock"]["bundles"] = [{"query": q} for q in queries]
    path.write_text(json.dumps(recipes), encoding="utf-8")
    docs, _ = game_docs(data)
    body = next(d["body"] for d in docs if d["title"] == "Glowcap Brew")
    assert all(q in body for q in queries)
    assert "source: recipe JSON" in body
    assert "relationship between separate condition queries is not established" in body
    assert "item first pickups and actor-class interactions" in body
    k = Knowledge(data=data, wiki=tmp_path / "no-wiki")
    text = k.lookup("glowcap brew", k_wiki=0)["data"]["results"][0]["text"]
    assert all(q in text for q in queries)
    k.db.close()


def test_large_unlock_details_do_not_evict_recipe_alternatives(tmp_path):
    data = make_data(tmp_path / "data")
    path = data / "recipes_999.json"
    recipes = json.loads(path.read_text(encoding="utf-8"))
    base = recipes["recipes"]["RECIPE_Brew"]
    recipes["recipes"].pop("RECIPE_Brew")
    queries = []
    for i in range(5):
        r = json.loads(json.dumps(base))
        r["inputs"] = [{"item": f"ITEM_Part{i}", "name": f"Part {i}", "count": i + 1}]
        query = f"ALL ITEMS[ {i} " + "LongToken" * 40 + " ]"
        r["unlock"] = {"bundles": [{"query": query}]}
        recipes["recipes"][f"RECIPE_Alt{i}"] = r
        queries.append(query)
    path.write_text(json.dumps(recipes), encoding="utf-8")
    docs, _ = game_docs(data)
    body = next(d["body"] for d in docs if d["title"] == "Glowcap Brew")
    for i in range(4):
        assert queries[i] in body and f"[RECIPE_Alt{i}]" in body
    assert queries[4] not in body  # existing four-recipe card limit
    k = Knowledge(data=data, wiki=tmp_path / "no-wiki")
    text = k.lookup("glowcap brew", k_wiki=0)["data"]["results"][0]["text"]
    for i in range(4):
        assert f"{i + 1} Part {i} at Brew Kettle" in text
        assert queries[i] not in text  # no partial raw expressions
    assert "Some unlock details omitted" in text and "craft_plan or recipes" in text
    assert len(text) <= 900
    k.db.close()


def test_game_data_first_and_authoritative_wiki_second_with_links(know):
    res = know.lookup("glowcap brew")
    assert res["ok"]
    results = res["data"]["results"]
    tiers = [r["authoritative"] for r in results]
    assert tiers == sorted(tiers, reverse=True) and tiers[0] is True and False in tiers
    top = results[0]
    assert top["title"] == "Glowcap Brew" and top["source"] == "game data (build 999)"
    # the recipe is phrased from the data: station, processing, skill, unlock with its in-game name
    assert "1 Glowcap Brew from 2 Glowcap at Brew Kettle (processing" in top["text"]
    assert "Cooking skill" in top["text"] and "ALL ACTORS[ Brew Kettle ]" in top["text"]
    wiki = [r for r in results if not r["authoritative"]]
    assert wiki[0]["url"].startswith("https://dragonwilds.runescape.wiki/w/Glowcap_Brew")
    assert "night vision" in wiki[0]["text"]
    assert "authoritative" in res["data"]["note"]


def test_deprecated_and_test_assets_are_left_out(know):
    rows = know.db.execute("SELECT body FROM docs WHERE tier = 0 AND title = 'Glowcap Brew'").fetchall()
    assert len(rows) == 1 and "9 Glowcap Brew" not in rows[0][0]


def test_traders_alias_kind_and_spells(know):
    glow = know.lookup("glowcap", k_wiki=0)["data"]["results"][0]
    assert "buy 1 Glowcap from Bob (trader) for 3 Chit" in glow["text"]
    assert "No crafting recipe" in glow["text"]
    alias = know.lookup("glow brew", k_game=0)["data"]["results"]
    assert alias and alias[0]["title"] == "Glowcap Brew"  # a redirect title finds the page
    spell = know.lookup("glow", kind="spell")["data"]["results"][0]
    assert spell["kind"] == "spell" and "Lights up caves" in spell["text"] and "Magic level 7" in spell["text"]
    ignored = know.lookup("glowcap", kind="monster")["data"]
    assert ignored["kind_ignored"] and ignored["results"]
    assert "item" in know.kinds() and "spell" in know.kinds()


def test_unrelated_game_items_are_not_returned(know):
    """Game data is offered only when it is about the thing named, never as loose filler."""
    res = know.lookup("mossy hollow")["data"]["results"]
    assert all(not r["authoritative"] for r in res) and res[0]["title"] == "Mossy Hollow"
    none = know.lookup("zzzz qqqq")["data"]
    assert none["results"] == [] and "don't know" in none["note"]
    assert know.lookup("what is the")["ok"] is False  # function words only


def test_index_is_cached_and_rebuilt_when_a_source_changes(tmp_path):
    data, wiki = make_data(tmp_path / "data"), make_wiki(tmp_path / "wiki")
    k1 = Knowledge(data=data, wiki=wiki)
    assert (wiki / "knowledge.sqlite").exists()
    sig = k1._meta("signature")
    k1.db.close()
    k2 = Knowledge(data=data, wiki=wiki)
    assert k2._meta("signature") == sig  # reused
    k2.db.close()
    f = data / "spells_999.json"
    f.write_text(f.read_text(encoding="utf-8").replace("Lights up caves", "Lights up tunnels"), encoding="utf-8")
    os.utime(f, ns=(time.time_ns(), time.time_ns() + 10**9))
    k3 = Knowledge(data=data, wiki=wiki)
    assert "Lights up tunnels" in k3.lookup("glow", kind="spell")["data"]["results"][0]["text"]


def test_stale_format_rebuilds_cached_recipe_cards(tmp_path):
    data, wiki = make_data(tmp_path / "data"), make_wiki(tmp_path / "wiki")
    k = Knowledge(data=data, wiki=wiki)
    old_signature = json.loads(k._meta("signature"))
    old_signature[0] -= 1
    k.db.execute("UPDATE meta SET v=? WHERE k='signature'", (json.dumps(old_signature),))
    k.db.execute("UPDATE docs SET body='old card' WHERE title='Glowcap Brew' AND tier=0")
    k.db.commit()
    k.db.close()
    refreshed = Knowledge(data=data, wiki=wiki)
    text = refreshed.lookup("glowcap brew", k_wiki=0)["data"]["results"][0]["text"]
    assert "unlock catalog queries" in text and "old card" not in text
    refreshed.db.close()


def test_game_only_without_a_mirror(tmp_path):
    k = Knowledge(data=make_data(tmp_path / "data"), wiki=tmp_path / "nowiki")
    assert k.db_path is None and k.stats()["wiki_docs"] == 0
    assert k.lookup("glowcap brew")["data"]["results"][0]["authoritative"]


# --------------------------------------------------------------------------- the lookup tool


def test_lookup_is_a_brain_side_read_tool():
    assert "lookup" in READ_TOOLS and "lookup" in BRAIN_TOOLS and "lookup" not in BODY_TOOLS


def _with_knowledge(rig, know):
    rig.controller.knowledge = know
    rig.controller.tools = rig.controller._tool_list()
    return rig


def test_lookup_offered_only_with_an_index(tmp_path, know):
    plain = Rig(tmp_path / "a")
    plain.game.player_say("what does glowcap brew do?")
    plain.controller_llm.push(FakeLLM.say("No idea."))
    plain.agent.step()
    call = plain.controller_llm.calls[0]
    assert "lookup" not in {t["function"]["name"] for t in call["tools"]}
    assert LOOKUP_RULE.strip() not in call["messages"][0]["content"]
    rig = _with_knowledge(Rig(tmp_path / "b"), know)
    rig.game.player_say("what does glowcap brew do?")
    rig.controller_llm.push(FakeLLM.say("It gives night vision."))
    rig.agent.step()
    call = rig.controller_llm.calls[0]
    tool = next(t for t in call["tools"] if t["function"]["name"] == "lookup")
    assert "kind values: item" in tool["function"]["description"]  # kinds come from the index
    assert LOOKUP_RULE.strip() in call["messages"][0]["content"]


def test_lookup_runs_in_the_brain_and_does_not_interrupt(tmp_path, know):
    """The model decides to look up; the result goes back as a tool message; the turn continues; the
    current job is not interrupted and nothing is sent to the body."""
    rig = _with_knowledge(Rig(tmp_path), know)
    rig.game.player_say("what does a glowcap brew do?")
    rig.controller_llm.push(
        FakeLLM.say("", FakeLLM.call("lookup", query="glowcap brew")),
        FakeLLM.say("It's a drink that gives you night vision for a minute."),
    )
    d = rig.controller.decide("Luis", "what does a glowcap brew do?", rig.game.get_state()["data"], None)
    assert d.model_calls == 2 and d.actions == [] and not d.interrupts
    assert d.speech == "It's a drink that gives you night vision for a minute."
    assert not any(name == "lookup" for name, _ in rig.game.calls)
    tool_msg = next(m for m in rig.controller_llm.calls[1]["messages"] if m["role"] == "tool")
    body = json.loads(tool_msg["content"])
    assert body["ok"] and body["data"]["results"][0]["authoritative"] is True

"""Manifest argument validation preserves choices; it does not prove native behavior."""
from copy import deepcopy

import pytest

from brain.bridge_client import BridgeClient
from brain.capabilities import Capabilities, ManifestError, discover
from brain.controller import Controller


def caps(name, schema):
    return Capabilities(tools=[name], source="test", manifest={name: {"args": schema}})


STRING = {"type": "string"}
BOOL = {"type": "boolean"}
INT = {"type": "integer", "minimum": 1}


@pytest.mark.parametrize("name,properties,required,args,expected", [
    ("craft", {"item": STRING, "recipe": STRING, "station": STRING, "fuel": STRING,
               "count": {**INT, "default": 1}}, [],
     {"item": "water", "recipe": "r", "station": "station-2", "fuel": "f"},
     {"item": "water", "recipe": "r", "station": "station-2", "fuel": "f", "count": 1}),
    ("craft", {"item": STRING, "recipe": STRING, "count": {**INT, "default": 1}}, [],
     {"recipe": "r"}, {"recipe": "r", "count": 1}),
    ("attack", {"target": STRING, "weapon": STRING, "style": STRING,
                "force": {**BOOL, "default": False}}, ["target"],
     {"target": "enemy", "weapon": "blade", "style": "swing", "force": True},
     {"target": "enemy", "weapon": "blade", "style": "swing", "force": True}),
    ("gather", {"resource": STRING, "count": INT, "stumps": BOOL, "style": STRING},
     ["resource", "count"], {"resource": "wood", "count": 2, "stumps": True, "style": "chop"},
     {"resource": "wood", "count": 2, "stumps": True, "style": "chop"}),
    ("inventory", {"raw": {**BOOL, "default": False}}, [], {"raw": True}, {"raw": True}),
    ("inventory", {"raw": {**BOOL, "default": False}}, [], {}, {"raw": False}),
])
def test_manifest_choices_survive(name, properties, required, args, expected):
    schema = {"type": "object", "properties": properties, "required": required, "additionalProperties": False}
    before, schema_before = deepcopy(args), deepcopy(schema)
    assert caps(name, schema).validate(name, args) == expected
    assert args == before and schema == schema_before


def test_restrictions_nulls_and_absent_required_default():
    schema = {"type": "object", "properties": {"x": {"type": ["string", "null"], "default": "a"},
                                                  "y": {"type": "string"}},
              "required": ["y"], "additionalProperties": False}
    c = caps("held_out", schema)
    assert c.validate("held_out", {"x": None, "y": "ok"}) == {"x": None, "y": "ok"}
    for args in ({"x": "a"}, {"y": None}, {"y": "ok", "extra": 1}):
        with pytest.raises(ManifestError):
            c.validate("held_out", args)
    required_default = caps("held_out", {"type": "object", "required": ["x"],
                                           "properties": {"x": {"default": 1}}})
    with pytest.raises(ManifestError):
        required_default.validate("held_out", {})


def test_defaults_are_copied_and_revalidated_without_mutation():
    schema = {"type": "object", "properties": {
        "nested": {"type": "object", "default": {"items": [1]}},
        "provided": {"type": "object"}}}
    original, args = deepcopy(schema), {"provided": {"items": [2]}}
    out = caps("held_out", schema).validate("held_out", args)
    out["nested"]["items"].append(3)
    out["provided"]["items"].append(4)
    assert schema == original and args == {"provided": {"items": [2]}}
    rejected = {"provided": {"items": [2]}}
    rejecting_schema = {"type": "object", "required": ["missing"], "properties": schema["properties"]}
    before_rejection = deepcopy(rejecting_schema)
    with pytest.raises(ManifestError):
        caps("held_out", rejecting_schema).validate("held_out", rejected)
    assert rejected == {"provided": {"items": [2]}} and rejecting_schema == before_rejection
    for bad in (
        {"type": "object", "properties": {"x": {"type": "integer", "default": "bad"}}},
        {"type": "object", "properties": {"x": {"default": 1}, "y": {"default": 2}},
         "not": {"required": ["x", "y"]}},
    ):
        before = deepcopy(bad)
        with pytest.raises(ManifestError):
            caps("held_out", bad).validate("held_out", {})
        assert bad == before


def test_boolean_and_empty_schemas_and_properties():
    assert caps("held_out", {}).validate("held_out", {"a": None}) == {"a": None}
    assert caps("held_out", True).validate("held_out", {"a": None}) == {"a": None}
    with pytest.raises(ManifestError):
        caps("held_out", False).validate("held_out", {})
    c = caps("held_out", {"type": "object", "properties": {"x": False}})
    assert c.validate("held_out", {}) == {}
    with pytest.raises(ManifestError):
        c.validate("held_out", {"x": None})


def test_legacy_fallback_unchanged():
    c = Capabilities(tools=[], source="test")
    assert c.validate("craft", {"item": "wood", "count": "2", "extra": 1, "unused": None}) == {
        "item": "wood", "count": 2}
    assert c.validate("unknown", {"x": 1, "y": None}) == {"x": 1}
    with pytest.raises(ValueError):
        c.validate("craft", {"recipe": "r"})


class ReplyTransport:
    def __init__(self, manifest):
        self.manifest = manifest
        self.sent = []
        self.pending = []

    def send(self, msg):
        self.sent.append(deepcopy(msg))
        data = {"tools": list(self.manifest), "manifest": self.manifest} if msg["tool"] == "capabilities" else {"state": "ok"}
        self.pending.append({"type": "result", "id": msg["id"], "ok": True, "data": data})

    def receive(self, timeout):
        result, self.pending = self.pending, []
        return result


def test_discovery_controller_and_bridge_preserve_manifest_arguments():
    schemas = {
        "craft": {"type": "object", "properties": {"item": STRING, "recipe": STRING, "station": STRING,
                  "fuel": STRING, "count": {**INT, "default": 1}}},
        "attack": {"type": "object", "required": ["target"], "properties": {"target": STRING,
                   "weapon": STRING, "style": STRING, "force": BOOL}},
        "gather": {"type": "object", "required": ["resource", "count"], "properties": {"resource": STRING,
                   "count": INT, "stumps": BOOL, "style": STRING}},
        "inventory": {"type": "object", "properties": {"raw": BOOL}},
        "nullable": {"type": "object", "properties": {"x": {"type": ["null", "object"]}}},
        "get_state": {"type": "object", "additionalProperties": False},
        "say": {"type": "object", "required": ["text"], "properties": {"text": STRING}},
    }
    transport = ReplyTransport({name: {"args": schema, "timeout_s": 11} for name, schema in schemas.items()})
    client = BridgeClient(transport)
    capabilities = discover(client)
    controller = Controller.__new__(Controller)
    controller.director, controller.caps = None, capabilities
    cases = [
        ("craft", {"item": "water", "recipe": "r", "station": "station-2", "fuel": "f"},
         {"item": "water", "recipe": "r", "station": "station-2", "fuel": "f", "count": 1}),
        ("craft", {"recipe": "r"}, {"recipe": "r", "count": 1}),
        ("attack", {"target": "e", "weapon": "w", "style": "s", "force": True},
         {"target": "e", "weapon": "w", "style": "s", "force": True}),
        ("gather", {"resource": "wood", "count": 2, "stumps": True, "style": "s"},
         {"resource": "wood", "count": 2, "stumps": True, "style": "s"}),
        ("inventory", {"raw": True}, {"raw": True}),
        ("nullable", {"x": None}, {"x": None}),
        ("nullable", {"x": {"nested": None}}, {"x": {"nested": None}}),
    ]
    for name, args, expected in cases:
        assert client.call(name, controller._validate(name, args))["ok"]
        assert transport.sent[-1]["tool"] == name and transport.sent[-1]["args"] == expected
    assert client.timeouts["craft"] == 16
    count = len(transport.sent)
    assert not client.call("attack", {})["ok"]
    assert len(transport.sent) == count

    seen = []
    client.state_hooks.append(lambda data: seen.append(data.copy()))
    client.state_hooks.append(lambda data: 1 / 0)
    assert client.call("get_state", {})["ok"]
    assert seen == [{"state": "ok"}]
    assert client.get_state()["ok"]
    assert seen == [{"state": "ok"}, {"state": "ok"}]
    count = len(transport.sent)
    assert client.call("say", {"text": "hello"})["ok"]
    assert len(transport.sent) == count + 1 and transport.sent[-1]["args"] == {"text": "hello"}

    # Rediscovery drops stale authority when the next body has no manifest.
    transport.manifest = {}
    discover(client)
    assert client.manifest_tools == frozenset() and client.manifest_validator is None
    assert not client.call("nullable", {"x": None})["ok"]

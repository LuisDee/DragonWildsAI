"""Guardrails for docs/design/PRINCIPLES.md: fail on known anti-patterns.

Heuristic static checks; they flag candidates for review, so keep allowlists explicit and small.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Utterance-like string literals used as conditions/keys in brain logic, e.g. `if "get your stuff" in text`
# or {"grab your things": "recover_grave"}. Multi-word lowercase phrases next to `in text`/dict keys.
PHRASE_COND = re.compile(r"""['"]([a-z]+(?: [a-z']+){2,})['"]\s*(?:in\s+(?:text|msg|line|utter\w*|t)\b|:\s*['"](?:recover_grave|fetch|consume|come_to|give|pickup|follow|go_to|attack)['"])""")

# Client mod must not call server RPC implementations or write authoritative gameplay state.
SERVER_CALL = re.compile(r"[:.]Server_\w+\s*\(")
STATE_WRITE = re.compile(r"\.(?:CurrentHealth|Health|AuthoritativeHealth|DamageAmount)\s*=\s*[^=]")

ALLOW_SERVER_CALL = {  # files allowed to *mention* Server_ for hooks/read-only probes (no calls)
}


def _files(base, pattern):
    return [p for p in (ROOT / base).rglob(pattern) if "tests" not in p.parts and "vendor" not in p.parts]


def test_no_phrase_to_skill_tables_in_brain():
    hits = []
    for p in _files("brain", "*.py"):
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
            if PHRASE_COND.search(line):
                hits.append(f"{p.relative_to(ROOT)}:{i}: {line.strip()}")
    assert not hits, "phrase->skill mapping found (PRINCIPLES.md #2):\n" + "\n".join(hits)


def test_client_mod_no_server_rpc_calls_or_state_writes():
    hits = []
    for p in _files("client_mod/scripts", "*.lua"):
        if p.name in ALLOW_SERVER_CALL:
            continue
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
            code = line.split("--", 1)[0]
            if SERVER_CALL.search(code) or STATE_WRITE.search(code):
                hits.append(f"{p.relative_to(ROOT)}:{i}: {line.strip()}")
    assert not hits, "server RPC call / authoritative state write in client mod (PRINCIPLES.md #1):\n" + "\n".join(hits)


# --------------------------------------------------------------------------- review 2026-10-25 section 6

BRAIN_ALLOW_ROUTING = {"grounding.py", "dry_run_llm.py"}  # stemming helpers; a rule-based test fake (says so)
# A literal multi-word English phrase inside re.compile(...): routing player text by regex (review H3).
REGEX_PHRASE = re.compile(r"re\.compile\(\s*r?['\"][^'\"]*\b[a-z]{2,} (?:\(?[a-z|]+\)? ){1,}[a-z]{2,}")
# Player text tested against an UPPER_CASE word set (HERE_WORDS, GREETINGS): language in code (review M6, L12).
WORDSET_TEST = re.compile(r"\b(?:low|text|word|line|msg|utter\w*)\b(?:\.\w+\([^)]*\))*\s+in\s+([A-Z][A-Z_]{2,})\b")


def test_no_regex_or_word_set_routing_of_player_text_in_brain():
    hits = []
    for p in _files("brain", "*.py"):
        if p.name in BRAIN_ALLOW_ROUTING:
            continue
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
            code = line.split("#", 1)[0]
            if REGEX_PHRASE.search(code) or WORDSET_TEST.search(code):
                hits.append(f"{p.relative_to(ROOT)}:{i}: {line.strip()}")
    assert not hits, "player text routed by regex/word list (PRINCIPLES.md #2):\n" + "\n".join(hits)


# Player names as literals or snake_case keys in logic (review M7). Comments and docstrings are fine.
NAME_LITERAL = re.compile(r""""(?:zezima|luis)"|'(?:zezima|luis)'|["'][\w]*(?:luis_|_luis)[\w]*["']""", re.I)
# Explicit allowlist: (file, a substring of the line), with why / who fixes it.
ALLOW_NAMES = [
    ("brain/run_live.py", 'player: str = "Luis"'),  # the configured default (DW_PLAYER_NAME), not logic
    ("brain/run_live.py", 'DW_PLAYER_NAME", "Luis"'),
    ("brain/controller.py", 'player: str = "Luis"'),
    # pending owners' fixes (review M7), remove when done:
    ("brain/interface.py", '"luis"'),  # capability agent: drop at="luis" -> at="player" + player
    ("brain/interface.py", "luis_hp_below"),  # spells/rules agent: -> player_hp_below + player
    ("client_mod/scripts/combat.lua", '"Zezima"'),  # combat agent: protect = configured player / every player
]


def test_no_player_names_in_logic():
    hits = []
    files = [(p, "#") for p in _files("brain", "*.py") if "mock" not in p.parts] +         [(p, "--") for p in _files("client_mod/scripts", "*.lua")]  # brain/mock: a simulated world (data)
    for p, comment in files:
        rel = p.relative_to(ROOT).as_posix()
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
            code = line.split(comment, 1)[0]
            if NAME_LITERAL.search(code) and not any(f == rel and s in line for f, s in ALLOW_NAMES):
                hits.append(f"{rel}:{i}: {line.strip()}")
    assert not hits, "player name in logic (PRINCIPLES.md #3):\n" + "\n".join(hits)


def test_held_follow_ending_by_itself_is_voiced(tmp_path):
    """Review H1: a follow answers at its start; when it later ends by itself the body sends task_failed
    for that request id. It must reach the Controller as a situation and be said, never swallowed."""
    import sys
    sys.path.insert(0, str(ROOT / "tests"))
    from conftest import Rig
    from brain.interface import TaskFailed
    from brain.llm import FakeLLM
    from brain.mock import MockGame

    class Body(MockGame):
        def sent_tool(self, request_id):
            return {"req-follow": "follow"}.get(request_id)

    game = Body.default_world()
    rig = Rig(tmp_path, game=game)
    game.player_say("follow me")
    rig.controller_llm.push(FakeLLM.say("Right behind you.", FakeLLM.call("follow", player="Luis")))
    rig.agent.step()
    game._events.append(TaskFailed(task_id="req-follow", reason="unknown_target"))
    rig.controller_llm.push(FakeLLM.say("I lost you, you vanished from my view. Where are you?"))
    rig.agent.step()
    ctx = __import__("json").loads(rig.controller_llm.calls[-1]["messages"][1]["content"])
    assert ctx["body_event"] == {"type": "follow_ended", "reason": "unknown_target", "target": "Luis",
                                 "about": "player"}
    assert rig.companion_said()[-1] == "I lost you, you vanished from my view. Where are you?"
    game._events.append(TaskFailed(task_id="some-sync-call", reason="path_blocked"))  # not held: the executor had it
    n = len(rig.controller_llm.calls)
    rig.agent.step()
    assert len(rig.controller_llm.calls) == n


def test_every_dropped_model_call_yields_a_spoken_reason(tmp_path):
    """Review H4: invalid args, unknown tools and an empty start_goal never leave a reply claiming the action."""
    import sys
    sys.path.insert(0, str(ROOT / "tests"))
    from conftest import Rig
    from brain.llm import FakeLLM
    for calls in ([FakeLLM.call("follow", distance="close")], [FakeLLM.call("teleport", to="x")],
                  [FakeLLM.call("start_goal")]):
        rig = Rig(tmp_path / str(len(calls[0].name)) / calls[0].name)
        rig.game.player_say("do it")
        rig.controller_llm.push(FakeLLM.say("On my way!", *calls))  # the follow-up (if any) is not scripted
        rig.agent.step()
        said = rig.companion_said()
        assert said and said[-1] != "On my way!", (calls[0].name, said)
        assert [n for n, _ in rig.game.calls] == ["say"]

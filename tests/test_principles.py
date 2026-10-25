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

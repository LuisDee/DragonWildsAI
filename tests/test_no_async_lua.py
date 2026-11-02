"""Guard: no UE4SS async-thread Lua in our mods (DISCOVERIES "Dev server crash 2026-11-02").

ExecuteWithDelay / LoopAsync / ExecuteAsync run their callback on the mod's async thread, on a lua thread of the same
global_State the game thread is running, with no lock (UE4SS issues #1345, #1445; maintainer: "inherently unsafe").
Use ExecuteInGameThreadWithDelay / LoopInGameThreadWithDelay instead.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
BANNED = re.compile(r"\b(ExecuteWithDelay|LoopAsync|ExecuteAsync)\s*\(")


def test_no_async_thread_lua():
    hits = []
    for base in ("mod", "client_mod"):
        for p in (ROOT / base).rglob("*.lua"):
            for n, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                code = line.split("--", 1)[0]
                if BANNED.search(code):
                    hits.append(f"{p.relative_to(ROOT)}:{n}: {line.strip()}")
    assert not hits, "UE4SS async-thread Lua (use ExecuteInGameThreadWithDelay):\n" + "\n".join(hits)

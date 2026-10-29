r"""List every file path in an IoStore container's directory index (.utoc), offline and read-only.

  .venv\Scripts\python.exe -I tools/utoc_list.py <path.utoc> [--grep REGEX] [--game-paths]

Why: the reflection dump has no Blueprint asset paths (docs/research/2026-10-25-dump-body.md), but the spawn fixture
needs full class paths to LoadAsset a creature nothing has loaded yet. The server's .utoc directory index is plain
(not encrypted) and lists every package. --game-paths prints "/Game/.../X.X_C" object paths for BP_* .uasset files
under <Project>/Content (plugin content is printed as-is).

Format: Unreal's FIoDirectoryIndexResource (Runtime/Core/Public/IO/IoDirectoryIndex.h): FString MountPoint,
TArray<{Name, FirstChildEntry, NextSiblingEntry, FirstFileEntry}> directories, TArray<{Name, NextFileEntry, UserData}>
files, TArray<FString> StringTable (indices; 0xFFFFFFFF = none). Located by its mount point string "../../../".
Decision (search-before-building, 2026-10-26): retoc / CUE4Parse / FModel list containers too, but none is installed
and a web search did not surface a CLI listing; the index format is ~40 lines to read, so built (adapt the documented
format). Encrypted indexes are not supported (the script fails loudly).
"""
from __future__ import annotations

# Container tools reviewed before the local read-only parser; none is imported:
# https://github.com/trumank/retoc
# https://github.com/FabianFG/CUE4Parse
# https://github.com/4sval/FModel
# Binary layout provenance is the named Unreal header above, not copied parser code.

import argparse
import re
import struct
import sys

NONE = 0xFFFFFFFF


def list_paths(data: bytes) -> list[str]:
    i = data.find(b"../../../")
    if i < 4:
        raise ValueError("no plaintext directory index (mount point not found; encrypted?)")
    off = i - 4

    def fstr(o: int) -> tuple[str, int]:
        n = struct.unpack_from("<i", data, o)[0]
        o += 4
        if n < 0:
            return data[o:o - n * 2].decode("utf-16-le").rstrip("\0"), o - n * 2
        return data[o:o + n].decode("latin-1").rstrip("\0"), o + n

    mount, off = fstr(off)
    n = struct.unpack_from("<i", data, off)[0]; off += 4
    dirs = [struct.unpack_from("<IIII", data, off + 16 * k) for k in range(n)]; off += 16 * n
    n = struct.unpack_from("<i", data, off)[0]; off += 4
    files = [struct.unpack_from("<III", data, off + 12 * k) for k in range(n)]; off += 12 * n
    n = struct.unpack_from("<i", data, off)[0]; off += 4
    strs = []
    for _ in range(n):
        s, off = fstr(off)
        strs.append(s)
    out: list[str] = []
    stack = [(0, mount.rstrip("/"))]
    while stack:
        di, path = stack.pop()
        name, child, _sib, f = dirs[di]
        p = path + ("/" + strs[name] if name != NONE else "")
        while f != NONE:
            fn, nxt, _ = files[f]
            out.append(p + "/" + strs[fn])
            f = nxt
        c = child
        while c != NONE:
            stack.append((c, p))
            c = dirs[c][2]
    return sorted(out)


def game_path(p: str) -> str:
    m = re.match(r"^\.\./\.\./\.\./[^/]+/Content/(.+)/([^/]+)\.uasset$", p)
    if not m:
        return p
    folder, name = m.groups()
    return f"/Game/{folder}/{name}.{name}_C" if name.startswith("BP_") else f"/Game/{folder}/{name}.{name}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("utoc")
    ap.add_argument("--grep", default=None)
    ap.add_argument("--game-paths", action="store_true")
    a = ap.parse_args(argv)
    with open(a.utoc, "rb") as f:
        paths = list_paths(f.read())
    rx = re.compile(a.grep) if a.grep else None
    for p in paths:
        if rx is None or rx.search(p):
            print(game_path(p) if a.game_paths else p)
    print(f"# {len(paths)} files", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

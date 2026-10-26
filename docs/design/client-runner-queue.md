# Client command runner: queue file instead of a directory listing (L28, 2026-10-26)

## Problem
- At 07:14:32 UTC Claude's client HUNG. The cdb stack (`logs/client/hang_7368_20261026_081432.txt`, UTF-16) has the GameThread in `ntdll!NtReadFile` ← `ucrtbase!fgetc` ← UE4SS's Lua runtime: a blocking pipe read.
- The poll loop of the DWClient command runner (`client_mod/scripts/main.lua`) listed `client_io/cmd` every 2 s with `io.popen('dir /b ...*.lua')`.
  - That spawns `cmd.exe` and reads its stdout pipe on the game thread.
  - If the child stalls (memory pressure, antivirus, a slow console host), the game freezes with it.
- Runtime `os.execute('mkdir ...')` calls had the same hazard:
  - navmem saved on every move end;
  - skills on every death;
  - chat, sense and the bridge at service start.

## Decision
**No process spawning on any hot path.** The runner reads a queue file.

### Protocol
1. A writer writes `client_io/cmd/<name>.lua` atomically (write `.tmp`, then rename).
2. The writer then appends the line `<name>` to `client_io/cmd/queue.txt`.
   - Writers: `tools/client_cmd.sh` (`printf >>`) and `tools/client_lib.ps1` `Invoke-ClientCmd` (`[IO.File]::AppendAllText`).

### Runner
- Every 500 ms it reads `queue.txt` from a saved byte offset with plain `io.open`/`seek`/`read`. That is the same tail-by-offset pattern as the bridge's JSONL transport.
- For each complete new line it runs `<name>.lua` if the file still exists; a withdrawn command (`Clear-ClientCmd`) is simply absent.
- A partial last line waits for its newline.
- On load, the runner starts after the existing queue content, so a previous client run's leftovers don't fire.
- Rotation: once the queue is fully read and over 16 KB, the runner renames it to `queue.txt.old`. It then drains the renamed file once more, so a writer's append that raced the rename isn't lost; writers simply create a fresh `queue.txt`.

### Directories
- Every module's mkdir goes through a local `ensure_dir(d)`. It is cached per load and probes with an open-for-append of `d/.dwclient_probe`.
- It spawns `mkdir` only when the folder is really missing, i.e. once on a fresh install, never per tick.

### Compatibility
- Files are still written as before, so an old runner (directory listing) and the new one (queue) both work during the change-over.
- A `.lua` written without a queue entry is no longer picked up. All writers in this repo queue.

## Search record (search-before-building)
- Searched:
  - "UE4SS Lua io.popen freeze game thread blocking"
  - "list directory without lfs Lua Windows non-blocking alternative"
  - the UE4SS Lua API docs (docs.ue4ss.com)
- Found:
  - General Lua/FreeSWITCH reports: a `popen` read blocks while the child has no output, and pipes from `io.popen` can't be made non-blocking in plain Lua. Fixes were native libraries (APR, lpty) or not spawning at all.
    https://lists.freeswitch.org/pipermail/freeswitch-users/2010-January/052535.html ; https://lua-users.org/lists/lua-l/2011-12/msg00201.html
  - UE4SS exposes `IterateGameDirectories()` (directory listing without a process: a table of the game's directories, each with `__files`), but it is rooted at the game's own install tree. `client_io` lives outside it.
    https://docs.ue4ss.com/lua-api/global-functions/iterategamedirectories.html
  - Nothing UE4SS-specific about polling a directory without blocking.
- Decision: **adapt.** Reuse the offset-tracked file tail the bridge already uses (`brain/transport.py`, `mod/scripts/bridge.lua`) for the command queue, plus a probe-and-cache directory helper. No new dependency (lfs isn't available in UE4SS).

## Tests
- `client_mod/tests/test_runner.lua` (13 checks):
  - `io.popen` is booby-trapped and must never be called on the poll path, nor `os.execute`;
  - a queued command runs and its file is consumed;
  - a partial line waits;
  - a withdrawn entry is skipped;
  - an unqueued file is ignored;
  - stale pre-load entries don't run;
  - rotation keeps an entry appended after it.
  - The old runner fails it on the first poll.
- `tests/test_client_ops.py`: its fake runner now reads only the queue, so the PowerShell writer (`Invoke-ClientCmd`) is proven to queue (33 passed).

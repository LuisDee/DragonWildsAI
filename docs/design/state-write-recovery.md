# State write recovery

- **Goal:** task progress survives temporary Windows file locks, while permanent write failures remain visible and preserve the old memory file.
- **Evidence:** two full-suite tests failed at state_store._atomic_write's bare os.replace, then passed in isolation. Failed paths grant this user OWNER RIGHTS Full and have no readonly flag. Workspace ACL grants Modify. A transient lock is a supported hypothesis; its holder was not captured. Do not describe the exact locker as verified or grant unrelated system privileges.
- **Approach:** reuse brain.fileio.atomic_write as state_store's existing private alias. It already supplies unique sibling temporary files, five bounded replacement attempts and cleanup on exhausted PermissionError. Existing memory users use this helper. Remove duplicate implementation and unused os import. Preserve error propagation; never delete or overwrite old world progress to hide a failure.
- **Generality:** shared file persistence, independent of tasks, phrasing, items and world. No game behavior, judge criteria or memory schema changes.
- **Acceptance:** exercise the state-store entry point with injected temporary and permanent replacement failures; verify recovered content, preserved old content, bounded attempts and no leftover temporary files. Run focused state/controller tests, then the full gate. This verifies the reported failure mode, not an identified external lock holder.

## Search record

Reuse > adapt > build: repository docs/DISCOVERIES.md already records Windows file-lock races; brain/fileio.py and map_memory.py already provide the established helper. No new dependency or retry framework is needed. Python documents replacement semantics; its tracker describes Windows open-handle restrictions and the same PermissionError symptom. Microsoft documents delete permissions required for replacement. ACL inspection distinguishes available permissions from transient handle contention.

- https://docs.python.org/3.12/library/os.html#os.replace
- https://bugs.python.org/issue46003
- https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexa

## Review

Fresh Terra design review approved reuse before implementation. Its limitation is preserved: cleanup assertions cover exhausted PermissionError, not every possible filesystem error. Concurrent read-modify-write serialization is outside this change. Fresh Terra cold code review found no concrete defect. Focused fileio, controller-loop, scenarios and design-note tests: 43 passed.

Full regression on the corrected source: 1057 passed, 1 skipped; CHECK_ALL: GREEN. A disposable probe also completed 50 writes/replacements and deletion in the previously failing test directory without another permission grant.

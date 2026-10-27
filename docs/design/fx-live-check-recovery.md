# FX live-check recovery

- **Goal:** report effect checks honestly when the client survives the measured sequence, without mistaking a restarted process for continuity.
- **Approach:** reuse the live queue's existing `{$ref: ...}` resolver for an operator's expected value only when the operand is exactly that object. Other literal operands retain their existing meaning. An unresolved expected reference fails with a serializable diagnostic. Correct wrapped probe paths and compare every probe's nonempty process token with the first, retaining all existing criteria.
- **Precedent and decision:** reuse the project's queue and probe. Search found no external solution specific to this custom interpreter. Python's dictionary and equality semantics support preserving literal comparisons; pytest's standard assertions support small, readable regression tests. JSON objects are unordered name/value collections, so the one-key object can unambiguously identify this existing reference syntax. Sources: https://docs.python.org/3/library/stdtypes.html#mapping-types-dict , https://docs.pytest.org/en/stable/how-to/assert.html , https://www.rfc-editor.org/rfc/rfc8259#section-4 , https://docs.ue4ss.com/guides/creating-a-lua-mod.html .
- **Generality and principles:** the reference comparison is generic, with no item or phrase special cases. It does not change game actions or claim state that was not observed. Process tokens are probabilistic identifiers; their collision risk remains.
- **Acceptance:** offline tests exercise literal operands, equal, differing and missing expected references, and wrapped FX responses, including restart with a large counter. The queue's normal validation must accept the checks. A future live run must exercise each effect and inspect its observations; the offline test does not prove effects occurred or survived in game.

## Search record

- Python mapping types: https://docs.python.org/3/library/stdtypes.html#mapping-types-dict
- pytest assertions: https://docs.pytest.org/en/stable/how-to/assert.html
- JSON object semantics: https://www.rfc-editor.org/rfc/rfc8259#section-4
- UE4SS Lua mod guidance: https://docs.ue4ss.com/guides/creating-a-lua-mod.html

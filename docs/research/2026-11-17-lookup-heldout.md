# Lookup eval for enemies and vaults on main, tuned and held-out (2026-11-17)

**Call count and model: 0 calls, no model.** `evals/lookup_enemies_eval.py` is offline. It calls
`brain.knowledge.Knowledge.lookup` directly, with no model, no game and no network. The planned
Haiku 5.5 budget (under $0.30) was not used. Spend from `tools.obs spend --today`: $4.2171 and
1743 calls before the run, and the same after it.

## What was run
- main at `787b958`, `PYTHONPATH=C:\gameserver`, `.venv\Scripts\python.exe evals\lookup_enemies_eval.py --json logs\evals\lookup_enemies_eval-20261117-main.json`.
- There was one invocation. The runner scores both halves in the same process. The held-out half is
  printed as one total. `--show-heldout` was not passed, and the held-out file was not opened.
- Index: `data/wiki/knowledge.sqlite`, build 26574459. Its signature was current, so no private
  rebuild was needed.

## What the eval reads on main
- **The bestiary is not wired into lookup on main.** No file under `brain/` mentions `bestiary`.
  `Knowledge` indexes only `data/items_*`, `recipes_*`, `spells_*`, `farming_*` and the wiki mirror
  (`data/wiki/manifest.json` + `pages/*.json`). The wiring commit `d894103` is still only on the
  worktree branch `worktree-agent-aea542b09bc8a7b66`.
- The bestiary merges are on main, but only in the data. `f01ecc9` landed as `bac2485` and
  `4e1bb05` built the bestiary, so `data/bestiary.json` and `tools/build_bestiary.py` are on main.
  Lookup never reads them, so these merges cannot move either score on main.
- The "15/15 tuned" figure was measured with the bestiary entries put first (`4e1bb05`, and the
  `d894103` branch). It is not a score for main.

## Scores (main, wiki index only)

| set | score | earlier score |
|---|---|---|
| tuned (`lookup_enemies_cases.jsonl`) | **10/15** (10/14 where the answer is in the mirror) | 10/15 on main (`fdfa999`); 15/15 with the bestiary first (`4e1bb05`, unwired) |
| held-out (`lookup_enemies_heldout.jsonl`), untuned | **13/15** | 13/15 on main (`fdfa999`); 15/15 with the bestiary first (`4e1bb05`, scored once) |

Tuned by kind: level 3/3, attacks 1/3, weakness 2/2, location 2/2, vault 1/3, drops 1/2. The
returned text averages 1901 characters (max 3170), and a lookup takes 72.7 ms on average.

The held-out half has not been scored with the bestiary since the `f01ecc9`/`bac2485` merges.
That score can only be taken once lookup reads the bestiary, either on the `d894103` branch rebased
onto `bac2485` or after it merges.

## Tuned set, per case

| id | query | result | missing |
|---|---|---|---|
| lvl-garou-berserker | garou berserker | hit | |
| lvl-abyssal-demon | abyssal demon power level | hit | |
| lvl-black-knight-titan | black knight titan level | hit | |
| atk-kalphite-queen | kalphite queen mechanics | hit | |
| atk-zogre | zogre attacks | MISS | belly flop; rock toss; charge (titles: Attack Cape, Zogre, Attack) |
| atk-velgar | Velgar attacks | MISS | claw slam / earthen spikes; poison breath (titles: Attack Cape, Velgar, Attack) |
| weak-skeletal-warrior | skeletal warrior weakness | hit | |
| weak-plague-king | plague king weak to | hit | |
| loc-terrorbird | terrorbird location | hit | |
| loc-garou-king | garou king | hit | |
| vault-skeklac | Skeklac Kara | MISS | putrid rat; vault corruptor |
| vault-vekchenven | Vekchenven Kara enemies | hit | |
| vault-crasorak-boss | Crasorak Kara boss | MISS | vault overlord |
| drop-vertentis-chest | Vertentis Kara chest loot | MISS | skill tome; weak potion; vault shard (answer not in the mirror) |
| drop-giant-rat | giant rat drops | hit | |

All five misses are the ones `fdfa999` recorded. They are ranking misses ("Attack Cape" and "Attack"
rank above the creature's attack table, and the vault page's map chunks rank above its enemy list),
plus one answer that is not in the mirror at all. With its wiring, `d894103` reported all five as hits
(10/15 to 15/15), measured on its own branch.

Result log: `logs/evals/lookup_enemies_eval-20261117-main.json` (tuned per case, held-out total only).

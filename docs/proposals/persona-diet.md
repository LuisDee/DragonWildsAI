# Persona diet (2026-11-01)

Luis: "the persona rule debt: go through and nuke most of it, I bet it's all garbage."

The Controller (Haiku 5.5) system prompt was brain/persona.md (about 10 KB) plus three placeholder rules
(`{look_rule}`, `{lookup_rule}`, `{rules_rule}`), Luis's house rules and the coordinate note. The rules had been
added as patches over a week, and they contradicted the tools. The worst case was the look rule ("ALWAYS call look
with about=<their words> first") against go_to's "pass the name itself, no need to look for it first". It took three
patches on 2026-11-01 alone (5271621, 39e772c, 0bd6285) and still cost a read before go_to on the chat ladder's legs.

## Principle (Anthropic docs)

- Tool descriptions are "by far the most important factor in tool performance". Each should say what the tool
  does, when to use it and when not, what each parameter means, and its caveats. Source:
  [Define tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools).
- A system prompt should sit at the "right altitude": no "complex, brittle logic", and "a set of diverse, canonical
  examples" rather than a laundry list of edge cases. Source:
  [Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents).
- Soften aggressive language ("CRITICAL: You MUST use this tool" becomes "Use this tool when..."). "If in doubt,
  use [tool]" causes overtriggering. Give the reason behind an instruction. Source:
  [Prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices).
- "With a short system prompt, Claude Haiku 5.5 rarely stops before the work is done." Source:
  [Prompting Claude Haiku 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-haiku-5-5).

**Rule of thumb now:** guidance about one tool lives in that tool's description, so it is offered exactly when the
tool is and cannot contradict it. The persona keeps only what no single tool owns:

- who he is;
- the single voice;
- honesty and communication;
- looking after himself;
- how the harness runs calls;
- what the context fields mean;
- Luis's rules.

## Sizes (live wiring, counted with Anthropic count_tokens, claude-haiku-5-5)

| | before (live log 2026-11-01 02:10) | after |
|---|---|---|
| system prompt | 10,871 chars, 3,643 tokens | 4,911 chars, 1,638 tokens (45 %) |
| persona.md alone | 9,937 chars | 4,508 chars |
| tools (47) | 24,883 chars, 9,309 tokens | 26,858 chars, 9,915 tokens |
| system + tools | 12,952 tokens | 11,553 tokens (-11 %) |

The tools grew by about 600 tokens for two reasons:

- The guidance moved into them.
- The description cap in brain/capabilities.py (360 chars per tool, 140 per argument) had been silently cutting real
  content: cast's "Never at players", gather's no-XP list, and the tails of cast's walk_to and gather's resource
  arguments. The caps are now 640 and 300.

Two dev notes were removed from tool descriptions:

- build: "(live 2026-10-26: a Campfire gave +12)";
- attack: "(wiki skill pages: ...)".

## Evals (Haiku 5.5, real model; about $0.45 in total)

| eval | before | after |
|---|---|---|
| `evals/run_evals.py --suite controller` (18 cases) | 13/18 (1 run) | 15, 15, 13, 13, 16, 13, 14 /18 over 7 runs (mean 14.1; the last one is the final text) |
| replay_first_call, first 20 cases | 38/40 (x2) | 58/60 (x3) |
| replay_first_call `--live-misses`, 20 cases | 34/40 (x2) | 56/60 (x3) |
| replay_first_call, all 91 cases x2 | old persona text on today's tools: 179/182 | final text: 175/182 (without the go_to line: 85/91 x1) |

### Controller misses

The remaining misses are the expectations judged unrelated before:

- **come_here:** Luis is 2 m away in the mock, so "here, what's up?" is true.
- **multi_step:** "go chop 20 logs and bring them" chains gather (then the continuation turn) rather than start_goal.
- **sticks_present:** gather `stick` instead of interact on the id.

The swing cases are noise at n=1. An A/B at k=5 per case, old persona text against new, both on today's tools:

| case | new | old |
|---|---|---|
| praise_during_goal | 4/5 | 5/5 |
| sticks_absent | 4/5 | 3/5 |
| sticks_present | 0/5 | 0/5 |
| sticks_no_look | 1/5 | 1/5 |

On sticks_no_look, Haiku picks up Oak Logs when asked for "the sticks" under both texts. The old no-look rule did
not prevent it, and the baseline pass was luck.

### Replay

- **Teleport misses fixed.** "make your way to the lodestone by Wise Old Man" went to teleport 0/2 before, and goes
  to go_to 4/4 now. The fix was the when-not-to-use sentence in teleport's description.
- **Vannaka (still a "miss").** "head over to Vannaka" while starving: it eats berries first, then go_to. That is the
  look-after-yourself rule working.
- **Case 9332 (honesty).** "meet me at the lodestone by Wise Old Man", just after its own false "at the lodestone
  now":
  - the first diet text scored 0/4 (it said "already here");
  - moving "where you are comes from body_status's Where line or a go_to that arrived, never from your own earlier
    lines" into the honesty bullet brought it to 3/4;
  - the old persona text scored 4/4;
  - adding "when he wants you somewhere, go_to it" to the persona scored 4/4.
- **The go_to line was adopted after all.** On all 91 cases the text without it scored 85/91, against 90/91 for
  the old text on the same tools. The old look rule's first half ("if he wants you to go to it ... call go_to with
  its name directly") was doing real work. So the persona keeps one acting line: "When he wants you somewhere,
  go_to it by the name he used, even if you think you're there already." That raised it to 88/91 and 87/91.
- **What separates it from the old text now.** Mostly "the temple entrance", which has no map name. go_to cannot
  resolve it, so a look first is arguably right; the old text's direct go_to "passes" the scorer but would fail
  live.

## Inventory

Verdicts: **K** kept (persona), **T** moved into one tool's description, **D** duplicated, **C** contradicted,
**O** obsolete. "Where" is where it was injected.

### brain/persona.md (the live persona; before = 74 lines)

| rule | origin (commit, why) | verdict | now |
|---|---|---|---|
| Identity: "a real player ... not an assistant", capable, sorts out own problems | 10b2082, voice rewrite (Luis: humanoid player) | K | first paragraph |
| Look after yourself (hungry, thirsty, tired: deal with it) | 10b2082 (Luis: real survival needs) | K | first paragraph |
| Only the say tool is heard; free text is a private note; "reply with no text" means no say | 7921ff5, say channel (Haiku wrote reasoning into free text) | K + D (the say tool says it too) | one line |
| Short, casual, under 100 chars, no emojis, no stock lines | 7d7348c (150 chars) then 10b2082 | K | one line |
| Talk when a real player would / stay quiet / "nobody nearby: no text" / example 8 | 10b2082 | K + D (three copies) | one line |
| The action is the answer; "let's" includes you; don't ask "want me to" | 10b2082 (Luis: "you are more than capable") | K | one line |
| A direct question gets a short true answer | 10b2082 | D | folded into "answer what he asks" |
| Words only for what you do in this reply (promise means a tool call) | 10b2082 (GOAL M1 talk_without_action; L5) | K | one line (PROMISE_NOTE / TALK_ONLY_NOTE stay the backstop) |
| "Never read out numbers ... say it like a person" | 10b2082, 5d44964 (vitals as words) | K (de-shouted) | one line |
| Fix it yourself first, then one plain line with the real reason | 10b2082 (Luis: communication paramount) | K | honesty bullet |
| Own mistakes in a few words | 10b2082 | K | honesty bullet |
| One line per moment; never repeat yourself (you=true) | 2a7188b (north-star review) | K + D (PERSONA had it twice) | one line |
| Bad/good examples 1-9 | 10b2082, from real chat | K, 3 diverse kept | greeting; numbers plus act in the same reply; failure reason plus ask. Dropped: 1, 4, 5, 6 (the promise lesson three times; owning mistakes; silence after a watched gather, already in the bullets) and 8 (= "nobody around: stay quiet") |
| Reading chat: addressed=true/false, don't butt in | f887d15 (chat understanding) | K | one paragraph |
| Several steps: tools in order in ONE message, stop at the first failure | 2a7188b | K (de-shouted) | Acting |
| Read-only tools run only on their own, "so look first" | d63ce55 (prompt diet), bba30bb | K; "so look first" removed (it pushed look-first) | Acting |
| An action cancels the job; never pair with stop; stop = stay; a comment means no tool | 6443b79 (follow cancelled by a paired stop) | T (stop) + K | stop description says "don't call stop beside one"; the persona keeps "an action replaces your job, so a comment on your work needs no tool". Dropping it cost praise_during_goal; restored |
| Longer jobs: run_skill, else add_task (board), else start_goal; list_skills/forget_skill | fc6fe31, 5ca2993 | T + D (director.persona_lines has the board) | start_goal and run_skill descriptions say when |
| remember: key "place:<name>" with at=self / at=player | 7d7348c | T | remember description (it used to say "Store a long-term fact in notes.json") |
| Questions about what you see/wear/carry: answer, no action tool | 3fb07b1 | D | "answer what he asks" plus "the action is the answer when he asks for something" |
| Results come back for another turn; args_help explains the tool | fc6fe31, 5fc8947 | K, short; args_help O (the failure result carries it) + D (next_turn's note) | Acting |
| Solve problems yourself; ask only when ambiguous, once, specifically | fc6fe31 | K + D (said twice, plus PERSONA's "ask ONE short question") | first paragraph |
| Grounding: act only on what you perceive; never substitute | fb44340 (never substitute pickup items) | K | Acting; re-strengthened to "Never substitute something similar" after sticks_no_look |
| `{look_rule}`: go_to exception, then "ALWAYS call look ... first" | 7d7348c, 505a2fe, 5271621, 39e772c, 0bd6285 | C (go_to target: "no need to look for it first") then T, + K for the go_to half | look description (scoped to things he wants you to pick up, use, fight or inspect); go_to has MAP_NAMES_NOTE plus "use it whenever he wants you somewhere". The persona keeps the go_to half as one line (all-91 replay: 85 without it, 87-88 with it, 89-90 for the old text) |
| If it isn't there, say so and name what is | 7d7348c | K | Acting |
| Never invent reasons or results | 3fb07b1 | K | honesty bullet |
| Where you are comes from the CURRENT state / the Where line, never from earlier lines | 3fb07b1; 1af0e02 (into the fallback: never live) | K | honesty bullet (case 9332: 0/4 to 3/4) |
| references (read_as, nearest first) legend | 2a7188b | D (self-describing keys) | named in Acting |
| Ids exactly; "me"/"I" = command.player | 295d252 | K | Acting |
| body_status: trust it over recent_events; "a report not about a player is not about {player}" | 2a7188b | K; second half O (the digest line says "not about a player" itself) | Your context |
| body_event legend: unreachable (guess), resumed, follow_ended, vitals_low, items_dropped, situation_review, goal_done, stuck; spoken_to=false (no greeting) | a5bec06, fc6fe31, d159c77 (L31), 5fc8947 | K where it changes behaviour | Kept: follow_ended/stuck always say why (Luis); leader_windstepped is a guess (Luis's own example); no greeting (L31); respect earlier answers. Removed: resumed/vitals_low/items_dropped/goal_done glosses (the names say it, and the general rule is "fix it with a tool, speak only if a player would") |
| recent_activity is your memory | 2a7188b | K | Your context |
| Spells: only castable_spells can be cast; how = the spells tool | 7b2592a | T | cast description |
| `{rules_rule}` standing orders, sensable triggers | d63ce55 | D (set_reflex_rule's schema lists the triggers) then T | set_reflex_rule description: "if his condition isn't one of them, don't call this, tell him you can't sense that" |
| "Before you reply, check: promise? numbers?" | 10b2082 | D (the two rules above) | removed |
| `{lookup_rule}` game facts, lookup, game data beats the wiki | a5bec06 | T | lookup description ("Use it for a game fact you're not sure of instead of guessing"; game data first was already there) |
| *(new)* Shared stations, chests, fuel and items are fine; say what you used | Luis, CLAUDE.md R2 decisions | K (Luis rule) | Acting |

### brain/controller.py (and other injectors)

| rule / constant | where | origin | verdict | now |
|---|---|---|---|---|
| PERSONA (the fallback when persona.md is missing) | controller.py | the old pre-persona.md text | D (a stale second rulebook; 1af0e02's rule landed only here and never ran live) | 4 sentences |
| LOOK_RULE / NO_LOOK_RULE | persona `{look_rule}` | see above | C / O (the live client always offers look; A/B 1/5 either way) | deleted |
| LOOKUP_RULE | persona `{lookup_rule}` | a5bec06 | T | deleted |
| RULES_RULE | persona `{rules_rule}` | d63ce55 | D, T | deleted |
| TEXT_CHANNEL_NOTE | system, only with DW_SPEECH_CHANNEL=text | 7921ff5 | K (conditional, true) | kept |
| director.persona_lines() (board) | system, only with a Director | 5ca2993 | K (not this task's file) | untouched |
| House rules header + brain/house_rules.md | system | 2563c48 | K (Luis's rules; the file is untouched) | kept |
| WIRE_COORDINATES | system | b68fc5e (Codex: coordinate conventions) | K, **unsure** | kept; little use to the Controller, but test_planner_input_contract pins it |
| SAY_SCHEMA "The ONLY way anyone hears you" | say tool | 7921ff5 | K, de-shouted | "This is the only way" |
| READ_ALONE "Read-only." marker | read tools | bba30bb, d63ce55 | K | kept |
| MAP_NAMES_NOTE (go_to target: map names, no look first) | go_to | dc5a8e1 | K | kept |
| START_GOAL "Hand a multi-step job to the planner" | start_goal tool | early | T | now says when (a long job of many steps), when not (a few calls: do them yourself) and run_skill |
| DESC_CHARS / ARG_CHARS 360 / 140 | capabilities.function_schema | 2563c48 (L6 speed) | O (cut "Never at players") | 640 / 300 |
| TALK_ONLY_NOTE, FINAL_PASS_NOTE, "Last step: act now...", next_turn's notes, _say_result notes | loop messages (not the system prompt) | 48edc9d, bba30bb, 7d7348c | K (harness truth, decided by the reply's shape) | kept |
| agent.PROMISE_NOTE / PARKED_NOTE / LAST_TURN_NOTE | loop messages | fc6fe31 | K | not this task's file; kept |

### Tool descriptions changed

| tool | file | change |
|---|---|---|
| look | client_mod/scripts/manifest.lua, brain/interface.py | situation is a short summary; look about=<his words> before acting on a thing he named, or before telling him it isn't there |
| go_to | manifest.lua | "Use it whenever he wants you somewhere, also when you think you're already there: it answers arrived at once if you are" (move.lua finishes arrived as soon as he is grounded at the goal) |
| stop | manifest.lua, interface.py | stand still and stay; any other action already replaces the job, so don't call stop beside one |
| teleport | client_mod/scripts/lodestone.lua | for a far lodestone (another region); getting to a lodestone, also "the lodestone by X", is go_to |
| interact | client_mod/scripts/skills.lua | "To only walk to something, use go_to." |
| cast | client_mod/scripts/spells.lua | a spell not in castable_spells can't be cast: tell him; `how` is in castable_spells (was "state.spells") |
| attack, build | combat.lua, build.lua | dev notes removed |
| remember, run_skill, lookup, set_reflex_rule | brain/interface.py | the guidance moved from the persona |
| start_goal, say | brain/controller.py | when to use / de-shouted |

## Deploy note

The client_mod description changes reach the live brain only after the client modules reload (the manifest is
published by the client bridge). The brain-side changes (persona.md, interface.py, controller.py, capabilities.py)
take effect when the brain restarts; persona.md is re-read on change.

## Open / unsure

- **WIRE_COORDINATES:** kept. It is probably dead weight for the Controller, but it is shared with the Director and
  pinned by a test.
- **evals/controller_cases.jsonl expectations.** They are older than the multi-turn agent loop:
  - multi_step and build_hut expect start_goal, but chaining tools is now valid;
  - sticks_present expects interact, but gather `stick` works too;
  - come_here expects go_to with Luis 2 m away.

  They should be re-judged rather than prompted for.
- **sticks_no_look:** a body without look is the legacy server puppet. The case can be dropped once `mod/` goes.
- **praise_during_goal is a little flaky** (new 4/5, old 5/5): "good job, keep it up" sometimes re-calls gather.
  The persona says a comment on your work needs no tool. If it shows up live, the fix is context (the running job
  shown as running), not a phrase rule.
- **The old text is still slightly ahead on the go-to-place replay** (179 against 175 of 182), and the gap is mostly
  "the temple entrance". The clean A/B is a live chat-ladder run. This replay re-renders only the prompt and tools,
  not the situation.

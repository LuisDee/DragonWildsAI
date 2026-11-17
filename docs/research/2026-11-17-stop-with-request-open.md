# Stopping with the player's request still open: what others do, and what was taken (2026-11-17)

### A run that ends its turn with a multi-part request unfinished (2026-11-17)
- Need: after a sub-plan (a goal) ended, the Controller (Haiku) dealt with hunger or thirst for a few turns and then ended its turn with the quest's next step open. 7 Rune Mysteries runs in the ledger carry this cause; five earlier wording fixes did not hold.
- Searched: plan-and-execute agents and what the executor hands back; completion signals for tool-calling agents; an explicit "done" tool checked against the environment; stop hooks and completion checks; task ledgers shown each turn. For the game's rule (the quest goes on under the same name after the hand-in): the Dragonwilds wiki.
- Found:
  - Plan-and-execute (LangGraph): the executor returns each step with its result (`past_steps`) to the caller, which then decides whether to answer or go on. Our `goal_done` event carried only the goal, the step count and the statuses.
  - "Done is not a return code" and the goal-contract / completion-evaluator pattern: a stop is a claim, checked against the goal by something outside the turn that made it.
  - The Stop-hook loop used with Claude Code: when the agent stops, a hook checks once whether the task is complete and hands the question back if it is not; a guard keeps it from looping.
  - An explicit closing tool (`request_done(outcome)`) is the other common form.
  - Wiki: Rune Mysteries has several parts under one quest name; the game completes one and gives the next.
- Decision: adapt, three parts.
  1. `goal_done` carries what each step reported (`results`), the `past_steps` idea (64dd510).
  2. The talk report says a quest that goes on under the same name "is not finished: it moved on to its next step" (c3a0319).
  3. A run for a request a goal came from that stops with no call and nothing said is asked once whether the request is finished (`STOP_FOR_NOTE`, 64dd510). The model decides; an empty reply closes the request. Never doubled.
  - Not taken: the explicit closing tool. Rolled forward on run 20261117-045210 (10 times, with the old talk wording) it closed the request as done 5 times with the quest open.
- Measured offline (each run rolled forward from its first Controller call after the goal's end, 10 times, Haiku; `rollout.py` in the session scratchpad, not in the repo). How often he went on with the quest:

| variant | run 045210 | run 044508 (craft counted as made) |
|---|---|---|
| as logged | 0 | 0 |
| step reports, old talk wording | 4 | not run |
| step reports, new talk wording | 9 | 3 |
| the same, and the one check turn on a silent stop | 10 (turn needed once) | 10 (turn needed 4 times) |
| step reports, new wording, finished "Job:" line removed | 6 | 9 |

- Open: the run that hears a goal end still sees "Job: <the finished goal>" (the event is added while the goal is still set). Removing it helped one run and hurt the other, so it was left.
- Limit: no run in the data ended silently with its request rightly finished (16 and 17 Nov: 26 runs heard the end of a goal that came from a request, 5 ended with an empty reply, all 5 with the quest open). So what the check turn costs on a finished request is covered by a unit test only.
- Sources: https://langchain-ai.github.io/langgraph/tutorials/plan-and-execute/plan-and-execute , https://blog.langchain.com/planning-agents , https://tianpan.co/blog/2026-04-23-done-is-not-a-return-code-agent-completion-signals , https://agentpatterns.ai/patterns/agent-design/goal-contract-completion-evaluator/ , https://arxiv.org/pdf/2508.07935 , https://arxiv.org/pdf/2603.11445 , https://www.vincentschmalbach.com/how-to-keep-claude-code-working-until-a-task-is-done-with-a-stop-hook-loop/ , https://dragonwilds.runescape.wiki/w/Rune_Mysteries

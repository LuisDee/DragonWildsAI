# A tool argument that takes a player was given an NPC: what others do, and what was taken (2026-11-17)

### An entity argument filled with a name of the wrong kind (2026-11-17)
- Need: `give {player: "Doric"}`. In the logs of 14 to 17 Nov `give` was called 7 times, all 7 on an NPC, all 7 refused by the body ("Doric is an NPC, not a player ... a quest hand-in to an NPC happens in the conversation") and followed by `talk`. Each is a miss by the goal's bars. It is half of the largest open cause in the failure ledger (Getting Started, 5 runs, 3 open). A sentence added to give's description (946bee9) moved a replay of the turn from 8 of 12 to 1 of 12, but live it stayed at 3 of 21 `gs_start` trials.
- Searched: tool design for agents that pass a wrong entity; enum arguments built from live state; constrained inputs and poka-yoke for tool calls; what a changing tool list does to the prompt cache.
- Found:
  - Poka-yoke for agent tools: make the wrong call impossible to express instead of describing it away. An argument that names an entity gets the list of entities that exist as its enum.
  - Constrained input (Arcade's pattern list, pyAgentic's linked parameters): the enum is filled from the state at call time, and the tool still validates at its own boundary, because a model can ignore an enum.
  - Changing a tool's definition invalidates the cached prompt from that point on, so the list is rebuilt only when its content changes.
- Decision: adapt (02d2cfd).
  - The body's manifest already marks what each argument takes (`ground = { player = "player" }` on give and follow). Nothing read it. The Controller now reads it and adds an enum to every argument marked `player`: the one he plays beside, whoever has spoken to him, and everyone online but himself.
  - The tool list is rebuilt only when those names change. At the start it holds the one he plays beside, so the warm-up's list is the list of the first turn.
  - Nothing is refused in the brain. The body still judges the call, because its matching of a player's name is wider than an exact string (masked and cut names).
  - No tool is dropped when he is alone, and nothing says how a quest is handed in.
- Not taken: more words in the description (measured: no movement live). Loosening the grader's miss rule (Luis's call).
- Not covered: the other half of the cause, a craft tried before the materials are carried (28 of about 250 crafts end `missing_materials`).
- Limit: a replay of the failing turn does not reproduce the call (talk 40 of 40), so only live `gs_start` trials can measure it. The baseline is 3 of 21.
- Sources: https://agentpatterns.ai/tool-engineering/poka-yoke-agent-tools/ , https://rmikulec.github.io/pyAgentic/tools/ , https://www.arcade.dev/patterns/constrained-input , https://dev.to/frihet/designing-mcp-tools-an-agent-wont-misuse-1ah1 , https://machinelearningmastery.com/ai-agent-tool-design-what-works-and-what-doesnt/ , https://community.openai.com/t/function-are-called-with-unallowed-arguments/665368

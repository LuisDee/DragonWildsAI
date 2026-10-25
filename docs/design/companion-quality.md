# Companion quality: why he feels dumb and robotic, and what fixes it (2026-10-25, 21:20)

Evidence: chat 20:54–21:18, brain logs, the persona in `brain/controller.py`. Companion to `autonomy-plan.md` (speed and long-horizon).

## 1. Diagnosis (what Luis saw → cause)
| Symptom | Cause |
|---|---|
| Narrates stats and position ("standing 13 m from you, food is at 15%"), explains what he "learned about the tree" | The persona is a 4k-character rulebook that says "ALWAYS reply with one line, also when you call a tool", plus "communication is paramount" taken literally. `situation_review` hands him stats_pct and he reads them out. Templates ("Done, gathered 4 Wood Ash.") plus a model report = two lines per action. |
| Promises, then doesn't act; says "Done." when not done | Turns that only talk, and canned templates (BUGS L3/L5). |
| Splinters at Luis's feet; chops a fresh tree instead of the felled log | Primitive failures (L14/L15), plus the model picks without knowing what the spell targets. |
| Hungry: "I'll look for a fire", but never thinks of crafting, cooking, berries 9 m away, or asking Luis | Perception gives ~20 resources, 13 items, 19 interactables, all flat and unranked, with no "needs → options" view. The crafting module can already compute what's craftable (`crafting.lua` `craftable`, `plan_tree`), but nothing puts "how could I meet this need" in front of the model. |
| Slow | See autonomy-plan §1 (debounce, redundant reads, slow failures, retries). |
| No long plans | No Director or goal tree live (autonomy-plan §4). |

## 2. What "human-like and capable" needs (precedent)
- **Generative Agents** (Park et al. 2023): believability comes from observation → memory (recency/importance/relevance) → reflection → planning, and ablations show each matters. https://arxiv.org/abs/2304.03442
- **PUBG Ally** (Krafton/NVIDIA, 2026):
  - A System 1 behaviour tree runs the reflexes; a System 2 language model handles coordination and speech.
  - Reviewers called it repetitive and robotic ("tells me every five minutes it's a PUBG encyclopedia with legs"). That is exactly our narration failure: talking about itself instead of playing.
  - https://arxiv.org/abs/2609.29837 · https://www.pcgamesn.com/playerunknowns-battlegrounds/ai-teammate · https://developer.nvidia.com/blog/how-krafton-built-pubg-ally-a-co-playable-character-powered-by-nvidia-ace/
- **Altera:** agents' output becomes their future input, so quality degrades over long runs. They need grounded sensing and action plus episodic memory. https://techcrunch.com/2024/05/08/bye-bye-bots-alteras-game-playing-ai-agents-get-backing-from-eric-schmidt/
- **Observation compression** (NetHack diff history): 4× more history in the same context, 7× score. Send what changed and what matters, not everything. https://arxiv.org/html/2312.07540v1
- **Affordance inference** (LLM-Regress, ACL 2025): infer goal-relevant objects and affordances instead of predefining them. https://aclanthology.org/2025.acl-long.1018

## 3. Plan (four workstreams; each has an eval from real chat lines)
**V. Voice (persona rewrite):**
- Replace the rulebook with a character sheet: a laid-back, competent RuneScape player and Luis's mate.
- Few-shot pairs taken from today's chat (bad → good).
- Rules of speech:
  - talk when a player would: answer what's asked, flag what needs the other player ("starving, got any food?"), react to notable moments;
  - stay quiet while just doing the job;
  - never read out stats, metres or internal state unless asked;
  - no templates, at most one line per episode;
  - casual and short, with variety.
- Actions over words: if he says he'll do it, the tool call is in the same turn.
- Communication is paramount means *say why when something fails or you need something*, not narrate.
- *Eval:* about 25 real situations graded by a Sonnet rubric (humanlike, no narration, action matches words) plus deterministic checks. ≤ 30 calls per run.

**N. Needs → options digest (perception, generic):**
- For each pressing need (food, drink, health, rest, a tool for the task), list the ways to meet it, computed from game data:
  - carried (hotbar or bag);
  - nearby (berries 9 m, ground items);
  - craftable now or at a nearby station (`crafting.craftable` / `plan_tree`, including cooking);
  - what's missing for the next-best recipe;
  - which player could help.
- Also rank and trim the rest of the perception to the top-N relevant (≤ 8k-token prompt).
- This is information, not a mapping (PRINCIPLES #2).

**M. Memory and lessons:**
- Luis's corrections become persisted lessons the model sees, e.g. "cancel a spell you won't use instead of casting it", "don't tell me, do it". House rules (`brain/house_rules.md`) for his explicit rules; episodic notes for what happened.
- Reflection at milestones (Generative Agents); the facts are never the model's own claims.

**D. Director + speed + reliability:** autonomy-plan §2–4. The Director lets him think about bigger problems (gear, food chains, levelling) with Sonnet, and keeps Haiku fast for chat.

## 4. Order
1. Now: reliability (L14/L15 just landed), speed (broker), voice V (new voice agent).
2. Next: N needs → options (skills/capability agent), M lessons.
3. Then: Director (design in review), acceptance ladder.

-- manifest: the client body's CAPABILITY CONTRACT with the brain (streamline plan step 2, R2 root cause:
-- the brain's hand-written tool list offered tools the body lacked, e.g. `pickup`).
--
-- client_bridge publishes, in its `capabilities` answer, one entry per tool that is IMPLEMENTED RIGHT
-- NOW (its module functions exist). The brain builds the LLM's tool list from these entries only, so no
-- tool the body lacks can be offered. Pure data, no side effects, hot-reloaded like the other modules.
--
-- Shape (adapted from MCP `tools/list` {name, description, inputSchema} and MINDcraft's command table
-- {name, description, params{type, description, domain}, perform = runAsAction(fn, resume, timeout)};
-- see docs/ARCHITECTURE.md 8.6):
-- Contract-shape references (this bridge does not implement MCP transport):
-- https://modelcontextprotocol.io/specification/2025-06-18/server/tools
-- https://github.com/mindcraft-bots/mindcraft/blob/main/src/agent/commands/actions.js
--   name         wire tool name
--   description  one or two sentences FOR THE LLM: what it does, what it needs, what it can't do
--   args         JSON Schema (draft 2020-12 subset: type, properties, required, enum, minimum, maximum,
--                default, description, anyOf/oneOf); the brain validates calls against it
--   kind         "action" (moves or acts; one action slot) | "read" (perception, never interrupts) |
--                "waiter" (acts without the action slot, e.g. say, drop) | "probe" (debug/status)
--   llm          true = offer to the LLM (Controller); false = debug or brain-internal
--   moves        true = takes the pawn (pre-empts the current action)
--   priority     arbiter level it acquires ("command" for brain commands, "task" for long jobs)
--   preconditions  short facts the body checks itself (and the brain may show the model)
--   duration_s   typical seconds;  timeout_s  how long the brain should wait for the result
--   reasons      failure codes it can answer (brain/interface.py Reason + skill-specific ones)
--   ground       {arg = kind}: what an argument names, for brain-side grounding ("item" on the ground,
--                "carried", "carried_or_item", "player", "thing" from look, "creature")
--   detail_is_speech  true = data.detail of a failure is a truthful sentence the brain may say as is
--   aliases      legacy tool names that now mean this tool (the brain maps pickup -> interact)
-- A module may also export MANIFEST = {tool = entry} for its own tools; that entry wins over this file
-- (skills.lua does so). Owners of attack/gather may move their entries into their modules.
local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
local function str(desc) return { type = "string", description = desc } end
local NOARGS = { type = "object", properties = obj(), additionalProperties = false }

local M = { VERSION = 1, obj = obj, NOARGS = NOARGS }

M.TOOLS = {
    -- ------------------------------------------------------------------ actions
    follow = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 0, timeout_s = 10,
        description = "Follow a player until stopped or given another job (waits and resumes if he is out of reach).",
        args = { type = "object", required = { "player" }, properties = obj({
            player = str("The player's exact name."),
            distance = { type = "number", minimum = 1, default = 3, description = "Distance to keep, metres." } }) },
        preconditions = { "the player is in the world" }, ground = obj({ player = "player" }),
        reasons = { "unknown_target", "companion_down", "invalid_args" } },
    stop = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 0, timeout_s = 10,
        description = "Stop the current action and stand still.",
        args = NOARGS, reasons = {} },
    go_to = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 20, timeout_s = 120,
        description = "Walk to a player, a perceived thing, a remembered place or a point; answers on arrival or says why not.",
        args = { type = "object", required = { "target" }, properties = obj({
            target = { description = "A player name, a perceived id, a place, 'my_grave' / 'my_grave:<ts>' (a remembered grave), or [x,y,z].",
                       anyOf = { { type = "string" }, { type = "array", items = { type = "number" }, minItems = 2, maxItems = 3 } } } }) },
        reasons = { "path_blocked", "verification_failed", "interrupted", "timeout", "companion_down" } },
    drop = { kind = "waiter", llm = true, moves = false, duration_s = 1, timeout_s = 10,
        description = "Drop carried items at your feet (to give: go_to the player first).",
        args = { type = "object", required = { "item", "count" }, properties = obj({
            item = str("A carried item: its name (e.g. 'Oak Logs') or item id from inventory."),
            count = { type = "integer", minimum = 1, description = "How many." },
            at = { type = "string", enum = { "feet" }, default = "feet", description = "Only 'feet'." } }) },
        ground = obj({ item = "carried" }), reasons = { "not_in_inventory", "verification_failed", "invalid_args" } },
    interact = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 6, timeout_s = 120,
        description = "Use one thing you looked at, like a player pressing E once: walks to it, faces it, presses interact "
            .. "and checks something changed (open a chest, talk, pick a plant). To pick items up prefer fetch; for your "
            .. "grave use recover_grave.",
        args = { type = "object", required = { "target" }, properties = obj({
            target = str("An id from look (or situation) whose actions include interact."),
            secondary = { type = "boolean", default = false, description = "Not supported yet; leave false." } }) },
        ground = obj({ target = "thing" }),
        reasons = { "unknown_target", "not_interactable", "too_far", "path_blocked", "verification_failed", "timeout" } },
    attack = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 20, timeout_s = 60,
        description = "Fight a creature until it is dead (picks the best weapon you carry; refuses unsafe fights: too "
            .. "strong, a boss, outnumbered, low health; never players).",
        args = { type = "object", required = { "target" }, properties = obj({
            target = str("Creature id from situation or look."),
            force = { type = "boolean", default = false, description = "Fight even if it looks unsafe (only when the player insists)." } }) },
        ground = obj({ target = "creature" }),
        reasons = { "unsafe", "unknown_target", "too_far", "interrupted", "timeout" } },
    gather = { kind = "action", llm = true, moves = true, priority = "task", duration_s = 120, timeout_s = 1800,
        detail_is_speech = true,
        description = "Harvest a resource kind nearby until you have count MORE of it (chop trees/logs/stumps, mine rocks, "
            .. "pick ground resources). Finds targets itself and equips the right tool you carry.",
        args = { type = "object", required = { "resource", "count" }, properties = obj({
            resource = str("Resource kind, e.g. 'oak', 'ash', 'stone', 'log'."),
            count = { type = "integer", minimum = 1, description = "How many more to gather." },
            radius = { type = "number", minimum = 1, maximum = 120, description = "Search radius in metres (default 30)." },
            stumps = { type = "boolean", description = "Also chop stumps (only when asked)." } }) },
        preconditions = { "a tool of the right kind in your inventory (axe for trees, pickaxe for rocks)" },
        reasons = { "nothing_in_range", "wrong_tool", "path_blocked", "inventory_full", "interrupted", "timeout", "unknown_target" } },
    equip = { kind = "action", llm = false, moves = false, duration_s = 1, timeout_s = 10,
        description = "Equip a carried item (hotbar key or inventory use). Debug: not yet verified from game state.",
        args = { type = "object", required = { "item" }, properties = obj({ item = str("Item name or id.") }) } },
    unequip = { kind = "action", llm = false, moves = false, duration_s = 1, timeout_s = 10,
        description = "Unequip a loadout slot. Debug.",
        args = { type = "object", required = { "slot" }, properties = obj({ slot = { description = "HeldRight, Body, ... or index",
            anyOf = { { type = "string" }, { type = "integer" } } } }) } },
    -- ------------------------------------------------------------------ waiters (speech)
    say = { kind = "waiter", llm = false, moves = false, duration_s = 1, timeout_s = 10,
        description = "Type one line into the game chat (the brain's Controller owns all speech).",
        args = { type = "object", required = { "text" }, properties = obj({ text = str("The chat line.") }) } },
    -- ------------------------------------------------------------------ reads
    look = { kind = "read", llm = true, moves = false, duration_s = 0.3, timeout_s = 15,
        description = "List things nearby (items, plants, resources, creatures, players, usables) with ids. Read-only.",
        args = { type = "object", properties = obj({
            about = str("The player's words for what to find; ranks matches first."),
            radius = { type = "number", minimum = 1, maximum = 80, default = 20, description = "Metres." },
            max = { type = "integer", minimum = 1, maximum = 40, default = 15, description = "At most this many things." } }) } },
    inspect = { kind = "read", llm = true, moves = false, duration_s = 0.3, timeout_s = 15,
        description = "Details of one thing: what it gives, needs, contains. Read-only.",
        args = { type = "object", required = { "target" }, properties = obj({ target = str("An id from look.") }) },
        ground = obj({ target = "thing" }) },
    inventory = { kind = "read", llm = true, moves = false, duration_s = 0.2, timeout_s = 10,
        description = "Your full inventory with item stats vs what you wear. Read-only.",
        args = { type = "object", properties = obj({ raw = { type = "boolean", default = false, description = "Debug: raw listing." } }) } },
    get_state = { kind = "probe", llm = false, moves = false, timeout_s = 10, args = NOARGS,
        description = "Position, health, vitals, inventory, nearby players/creatures/resources/items (the brain's state)." },
    -- ------------------------------------------------------------------ probes / debug
    ping = { kind = "probe", llm = false, timeout_s = 5, args = NOARGS, description = "Liveness and latency." },
    capabilities = { kind = "probe", llm = false, timeout_s = 5, args = NOARGS, description = "This manifest." },
    bridge_status = { kind = "probe", llm = false, timeout_s = 5, args = NOARGS, description = "Bridge, modules and services." },
    me = { kind = "probe", llm = false, timeout_s = 5, args = NOARGS, description = "sense.me: own pawn facts." },
    census = { kind = "probe", llm = false, timeout_s = 10, description = "sense.census: raw perception buckets.",
        args = { type = "object", properties = obj({ radius_m = { type = "number" }, max = { type = "integer" } }) } },
    move_status = { kind = "probe", llm = false, timeout_s = 5, args = NOARGS, description = "move.lua status." },
    arbiter_status = { kind = "probe", llm = false, timeout_s = 5, args = NOARGS, description = "Who owns the pawn." },
    combat_status = { kind = "probe", llm = false, timeout_s = 5, args = NOARGS, description = "Fight and guard state." },
    combat_orders = { kind = "probe", llm = false, timeout_s = 5, description = "Combat stance/avoid orders (debug).",
        args = { type = "object", properties = obj() } },
    gather_status = { kind = "probe", llm = false, timeout_s = 5, args = NOARGS, description = "Gather job state." },
    skills_status = { kind = "probe", llm = false, timeout_s = 5, args = NOARGS, description = "Composite skill state." },
}

-- Legacy tool names the brain (or the planner's prompt history) may still use -> the tool that does
-- that job now, published only while the new tool is implemented. Args are mapped brain-side
-- (brain/capabilities.py LEGACY_ARGS): pickup {target = an id} -> interact {target}.
M.ALIASES = { pickup = "interact" }

return M

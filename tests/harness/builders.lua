-- Fixture builders for the userdata-ish objects the mod receives from the
-- engine. Everything is a plain table with method-style accessors, because
-- the mod calls them as obj:id(), obj:section(), etc.
--
-- The `_kind` tag drives the IsStalker / IsMonster / ... predicates in fakes.lua.

local M = {}

local next_id = 1000
local function alloc_id()
    next_id = next_id + 1
    return next_id
end

-- Shared: gives an object the id()/name()/section() accessors the mod expects.
local function base(o, kind)
    o = o or {}
    o._kind = kind
    o._id = o._id or alloc_id()
    o._name = o._name or (kind .. "_" .. tostring(o._id))
    o._section = o._section or (kind .. "_section")

    function o:id() return self._id end
    function o:name() return self._name end
    function o:section() return self._section end
    return o
end

--- An NPC (stalker or monster). Opts:
---   id, name, section, kind ("stalker" | "monster"), community,
---   goodwill (general_goodwill vs actor), alive, position {x,y,z}
function M.make_npc(opts)
    opts = opts or {}
    local o = base({
        _id      = opts.id,
        _name    = opts.name,
        _section = opts.section,
    }, opts.kind or "stalker")

    o._community = opts.community or "stalker"
    o._goodwill  = opts.goodwill == nil and 0 or opts.goodwill
    o._alive     = opts.alive ~= false
    o._position  = M.make_vector(opts.position)

    function o:community() return self._community end
    function o:character_community() return self._community end
    function o:general_goodwill() return self._goodwill end
    function o:alive() return self._alive end
    function o:position() return self._position end
    function o:character_rank() return opts.rank or 0 end
    function o:character_name() return self._name end
    -- Defaults to the opaque clsid registered for this kind, so the Is*
    -- predicates classify this object when it is reached via a server scan
    -- that calls them as IsStalker(nil, cls) -- soulslike.script:307.
    function o:clsid()
        if opts.clsid ~= nil then return opts.clsid end
        return require("harness.fakes").clsid_for(self._kind)
    end
    function o:section_name() return self._section end
    function o:level_vertex_id() return opts.level_vertex_id or 1 end
    function o:game_vertex_id() return opts.game_vertex_id or 1 end

    -- Server-object style fields, for objects reached via alife():object().
    o.m_level_vertex_id = opts.level_vertex_id or 1
    o.m_game_vertex_id  = opts.game_vertex_id or 1
    o.online            = opts.online == true
    o.parent_id         = opts.parent_id
    o.section           = o._section
    function o:switch_online() self.online = true end

    -- State setters npc_on_net_spawn drives (soulslike.script:929-934).
    -- Recorded rather than modelled: specs assert which constant was applied.
    o.applied = {}
    local function setter(field)
        return function(self, v) self.applied[field] = v end
    end
    o.set_mental_state     = setter("mental_state")
    o.set_body_state       = setter("body_state")
    o.set_movement_type    = setter("movement_type")
    o.set_desired_position = setter("desired_position")
    function o:set_sight(t) self.applied.sight_type = t end
    function o:set_desired_direction() self.applied.desired_direction = true end

    -- Squad support for SpawnAmbush's is_squad branch.
    o._squad_members = opts.squad_members or {}
    function o:squad_members()
        local i = 0
        return function()
            i = i + 1
            return self._squad_members[i]
        end
    end
    function o:create_npc() end

    return o
end

function M.make_stalker(opts)
    opts = opts or {}; opts.kind = "stalker"
    return M.make_npc(opts)
end

function M.make_monster(opts)
    opts = opts or {}; opts.kind = "monster"
    return M.make_npc(opts)
end

function M.make_anomaly(opts)
    opts = opts or {}; opts.kind = "anomaly"
    return M.make_npc(opts)
end

--- The actor. Opts: id (defaults to AC_ID), health, power, rank, community,
--- position, inventory (list of items for iterate_inventory).
function M.make_actor(opts)
    opts = opts or {}
    local o = base({
        _id      = opts.id or (_G.AC_ID or 0),
        _name    = opts.name or "actor",
        _section = "actor",
    }, "actor")

    -- Plain fields the mod writes directly (HealActor, dream_callback).
    o.health    = opts.health == nil and 1.0 or opts.health
    o.power     = opts.power  == nil and 1.0 or opts.power
    o.radiation = opts.radiation or 0
    o.bleeding  = opts.bleeding or 0
    o.psy_health= opts.psy_health == nil and 1.0 or opts.psy_health
    o.satiety   = opts.satiety == nil and 1.0 or opts.satiety

    o._rank      = opts.rank or 0
    o._rep       = opts.reputation or 0
    o._money     = opts.money or 0
    o._community = opts.community or "stalker"
    o._position  = M.make_vector(opts.position)
    o._inventory = opts.inventory or {}
    o._slots     = opts.slots or {}

    -- Rank and reputation are int-typed on both sides
    -- (xrServerEntities/character_info_defs.h:8), and luabind converts a Lua
    -- number to int with static_cast, which truncates TOWARD ZERO -- not floor,
    -- so -5.9 stores as -5. Neither setter clamps: nothing in the engine keeps
    -- these in a documented range (InventoryOwner.cpp:450-491). Modelled
    -- faithfully because the mod hands both a raw float.
    local function to_int(v)
        if type(v) ~= "number" then return v end
        return v >= 0 and math.floor(v) or math.ceil(v)
    end

    function o:character_rank() return self._rank end
    function o:set_character_rank(v) self._rank = to_int(v) end
    function o:character_reputation() return self._rep end
    function o:set_character_reputation(v) self._rep = to_int(v) end
    function o:character_community() return self._community end
    function o:character_name() return opts.character_name or "Marked One" end
    function o:position() return self._position end
    function o:alive() return true end
    function o:general_goodwill() return 0 end
    function o:set_health_ex(v) self.health = v end
    function o:level_vertex_id() return opts.level_vertex_id or 1 end
    function o:game_vertex_id() return opts.game_vertex_id or 1 end
    -- money() returns u32 and give_money() does NOT clamp at zero
    -- (xrGame/InventoryOwner.cpp:630-645): deducting more than the actor holds
    -- underflows to ~4.29e9 in-game. Modelled, because a spec asserting "money
    -- never goes negative" would pass against a clamping fake while the real
    -- game wrapped.
    local U32 = 4294967296
    function o:money() return self._money end
    function o:give_money(v)
        local n = self._money + v
        if n < 0 then n = n + U32 end
        self._money = n % U32
    end
    function o:give_info_portion(id) if _G.give_info_portion then _G.give_info_portion(id) end end

    -- Only the accessors GiveFoodAndWater reads (soulslike_scenarios.script:576).
    o._conditions = {
        GetSatiety      = function() return o.satiety end,
        SatietyCritical = function() return opts.satiety_critical or 0.2 end,
    }
    function o:cast_Actor()
        return { conditions = function() return o._conditions end }
    end

    -- Overridden by world.lua when the item model is active. The default here
    -- keeps actor-only specs working without booting the world.
    function o:iterate_inventory(fn)
        for _, item in ipairs(self._inventory) do
            if fn(self, item) then return end
        end
    end

    -- Slot 0 is NO_ACTIVE_SLOT and the engine rejects it outright
    -- (xrGame/Inventory.cpp:658-664). Valid slots are 1..LAST_SLOT, and
    -- LAST_SLOT is CUSTOM_SLOT_5 = 18 in this build, because
    -- MORE_INVENTORY_SLOTS is defined (build_config_defines.h:15) --
    -- so BACKPACK(13) and CUSTOM_1..5(14-18) exist beyond HELMET(12).
    o.LAST_SLOT = 18
    function o:item_in_slot(n)
        if n == nil or n <= 0 then return nil end
        return self._slots[n]
    end
    function o:transfer_item(_, _) end

    -- Hands. opts.active_slot is the slot in the hands, 0 for empty hands.
    o._active_slot = opts.active_slot or 0
    function o:active_slot() return self._active_slot end
    function o:activate_slot(n) self._active_slot = n or 0 end
    function o:active_item() return self:item_in_slot(self._active_slot) end
    function o:active_detector() return nil end

    -- hide_weapon / restore_weapon send SetWeaponHideState(INV_STATE_BLOCK_ALL,
    -- true / false) (script_game_object_inventory_owner.cpp:1452-1467), which
    -- does nothing unless the actor is alive (Actor_Weapon.cpp:159-169). The
    -- handler adds or removes one block on every slot (Actor_Events.cpp:290,
    -- Inventory.cpp:1448-1467). The block is a u8 counter per slot
    -- (Inventory.h:199), and the underflow check is a VERIFY2 that release
    -- builds compile out (Inventory.cpp:1539-1546). So restore_weapon on an
    -- unblocked slot wraps it to 255, which blocks it. BLOCK_ALL moves every
    -- slot together, so one counter stands in for all of them.
    o._weapon_block = 0
    function o:hide_weapon()
        if self._alive_flag == false then return end
        self._weapon_block = (self._weapon_block + 1) % 256
    end
    function o:restore_weapon()
        if self._alive_flag == false then return end
        self._weapon_block = (self._weapon_block - 1) % 256
    end
    --- Test aid, not an engine call: are the weapon slots blocked?
    function o:weapons_blocked() return self._weapon_block > 0 end

    -- CScriptGameObject::eat logs and returns on nil, and CInventory::Eat
    -- returns false for an item that is not in this inventory
    -- (script_game_object.cpp:1077-1102, Inventory.cpp:1103-1119). Neither
    -- raises, so both are recorded no-ops here.
    function o:eat(item)
        local F = require("harness.fakes")
        F.calls["actor.eat"] = F.calls["actor.eat"] or {}
        local t = F.calls["actor.eat"]
        t[#t + 1] = { n = 1, item }
    end

    -- First inventory item with this section, or nil.
    function o:object(section)
        local found
        self:iterate_inventory(function(_, it)
            if it:section() == section then found = it return true end
        end)
        return found
    end

    -- Recorded, not a no-op: this is how the mod delivers the
    -- inventory-examined message listing what did not survive
    -- (soulslike.script:591), which is the player's only account of it.
    function o:give_game_news(...)
        local F = require("harness.fakes")
        F.calls["give_game_news"] = F.calls["give_game_news"] or {}
        local t = F.calls["give_game_news"]
        t[#t + 1] = { n = select("#", ...), ... }
    end

    return o
end

--- An inventory item. Opts: id, section, kind (drives Is* predicates),
--- condition.
function M.make_item(opts)
    opts = opts or {}
    local o = base({
        _id      = opts.id,
        _name    = opts.name,
        _section = opts.section or "itm_generic",
    }, opts.kind or "item")

    o._condition = opts.condition == nil and 1.0 or opts.condition
    function o:condition() return self._condition end
    return o
end

-- The engine binds set(float,float,float) only
-- (xray-monolith/src/xrServerEntities/script_fvector_script.cpp:24). Passing
-- nil matches no overload, so luabind raises lua_cast_failed, which under
-- !XRAY_EXCEPTIONS becomes Debug.fatal -- a hard CTD, not a catchable error.
--
-- We raise to match. Coercing nil to 0 would silently paper over two mod sites
-- that can pass nil coordinates (soulslike_scenario_logic_factory.script:174
-- and soulslike_scenarios.script:845, both when no spawn was ever recorded).
-- Set this false only in a spec that deliberately needs to step past it.
M.strict_vectors = true

--- A vector with the distance methods the mod uses.
function M.make_vector(v)
    v = v or {}
    local o = { x = v.x or 0, y = v.y or 0, z = v.z or 0 }

    function o:set(x, y, z)
        if M.strict_vectors and (x == nil or y == nil or z == nil) then
            error("vector:set() got nil (" .. tostring(x) .. ", " .. tostring(y)
                  .. ", " .. tostring(z) .. ") -- the engine binds "
                  .. "set(float,float,float) and would hard-crash here", 2)
        end
        self.x, self.y, self.z = x, y, z
        return self
    end

    function o:distance_to_sqr(other)
        local dx, dy, dz = self.x - other.x, self.y - other.y, self.z - other.z
        return dx * dx + dy * dy + dz * dz
    end

    function o:distance_to(other)
        return math.sqrt(self:distance_to_sqr(other))
    end

    return o
end

--- A hit record, shaped as soulslike.actor_on_before_hit enqueues them
--- (soulslike.script:907-913).
function M.make_hit(opts)
    opts = opts or {}
    return {
        type         = opts.type or (_G.hit and _G.hit.wound) or 5,
        power        = opts.power or 0,
        is_fatal     = opts.is_fatal or false,
        time         = opts.time or 0,
        draftsman_id = opts.draftsman_id,
    }
end

-- ------------------------------------------------------- scenario fixtures

-- Mirrors the literal SoulslikeScenarioLogic:__init builds when constructed
-- WITHOUT a saved state (soulslike_scenarios.script:249-302). Defaults are the
-- MCM defaults each field is initialised from, so make_logic_state() and a
-- freshly constructed scenario agree; self/builders.spec.lua asserts that.
--
-- Kept as a literal rather than derived from the mod, so that a field
-- appearing or vanishing in the mod shows up as a failing drift guard instead
-- of silently changing every spec's fixture.
local function default_logic_state()
    return {
        rank = 0,
        ranked_chance = 0,
        item_condition_loss_percent = 0,
        keep_equipped_items_on_death = false,
        item_loss_scalar = 0.2,
        ignore_rank_item_loss = false,
        ignore_rank_item_condition_loss = false,
        health_loss_percent = 0.75,
        rank_loss_percent = 0.02,
        rep_loss_percent = 0.05,
        allow_weapon_loss = true,
        allow_artifact_loss = true,
        allow_outfit_loss = true,
        allow_headgear_loss = true,
        allow_toolkit_loss = true,
        mutant_ambush_chance = 0.25,
        stalker_ambush_chance = 0.25,
        allow_boar_ambush = true,
        allow_flesh_ambush = true,
        allow_dogs_ambush = true,
        allow_cats_ambush = true,
        allow_snorks_ambush = true,
        allow_bloodsucker_ambush = true,
        allow_burer_ambush = true,
        allow_chimera_ambush = true,
        allow_controller_ambush = true,
        allow_stalker_novice_ambush = true,
        allow_stalker_advanced_ambush = true,
        allow_stalker_veteran_ambush = true,
        allow_stalker_sniper_ambush = true,
        allow_npc_looting = true,
        are_looter_npcs_marked = false,
        death_location = {
            position = { x = 0, y = 0, z = 0 },
            level_vertex_id = 1,
            game_vertex_id = 1,
        },
        story = {
            gave_food_or_water = nil,
            has_pda_marker = nil,
            has_stash_pda_marker = nil,
            radio_freq = nil,
            items_were_lost = nil,
            enemy = nil,
            player_died_indoor = nil,
            player_died_in_water = nil,
            level_name = nil,
        },
    }
end

--- A logic_state table. Top-level keys in `opts` are merged over the defaults;
--- `story` and `death_location` merge one level deep so a spec can override a
--- single field without restating the whole sub-table.
---
--- death_location defaults to a real position rather than the mod's nils, so
--- specs do not trip strict_vectors by accident. Pass `death_location = false`
--- for the "no location recorded" case that SpawnAmbush guards against.
function M.make_logic_state(opts)
    opts = opts or {}
    local s = default_logic_state()

    for k, v in pairs(opts) do
        if k ~= "story" and k ~= "death_location" then s[k] = v end
    end

    for k, v in pairs(opts.story or {}) do s.story[k] = v end

    if opts.death_location == false then
        s.death_location = {
            position = { x = nil, y = nil, z = nil },
            level_vertex_id = nil,
            game_vertex_id = nil,
        }
    elseif type(opts.death_location) == "table" then
        for k, v in pairs(opts.death_location) do
            if k == "position" then
                for pk, pv in pairs(v) do s.death_location.position[pk] = pv end
            else
                s.death_location[k] = v
            end
        end
    end

    return s
end

--- A spawn_location, as set_spawn records it into the save
--- (soulslike.script:207-265). Every spec that reaches create_new or
--- RespawnActor needs one, or those build a vector out of nils.
function M.make_spawn_location(opts)
    opts = opts or {}
    local p = opts.position or {}
    local a = opts.angle or {}
    return {
        level = opts.level or "zaton",
        position = { x = p.x or 0, y = p.y or 0, z = p.z or 0 },
        angle    = { x = a.x or 0, y = a.y or 0, z = a.z or 0 },
        level_vertex_id = opts.level_vertex_id or 1,
        game_vertex_id  = opts.game_vertex_id or 1,
    }
end

--- Construct a scenario and apply the setters create_new would.
--- Opts: class (default "DefaultSoulslikeScenarioLogic"), level_name,
--- loot_scalar, indoor, in_water, state (merged into logic_state).
---
--- Must run after H.boot: it reads the class globals class.lua installs.
function M.make_scenario(opts)
    opts = opts or {}
    local name = opts.class or "DefaultSoulslikeScenarioLogic"
    local cls = _G[name]
    assert(cls, "make_scenario: no class '" .. name .. "' -- is " ..
                "soulslike_scenarios loaded?")

    local s = cls()
    s:SetLevelName(opts.level_name or "zaton")
    s:SetLootScalar(opts.loot_scalar == nil and 1.0 or opts.loot_scalar)
    s:SetIsInDoor(opts.indoor or false)
    s:SetIsInWater(opts.in_water or false)

    for k, v in pairs(opts.state or {}) do
        if (k == "story" or k == "death_location") and type(v) == "table" then
            s.logic_state[k] = s.logic_state[k] or {}
            for sk, sv in pairs(v) do s.logic_state[k][sk] = sv end
        elseif k == "death_location" and v == false then
            -- "no location was ever recorded", the shape __init actually builds
            -- (soulslike_scenarios.script:282-290). Not the same as omitting
            -- the key, which leaves the constructor's own nils in place.
            s.logic_state.death_location = {
                position = { x = nil, y = nil, z = nil },
                level_vertex_id = nil,
                game_vertex_id = nil,
            }
        else
            s.logic_state[k] = v
        end
    end

    return s
end

-- ------------------------------------------------------------ server objects

--- A server-side object, as alife():object(id) returns. Distinct from a client
--- object in two ways the mod depends on: `id` and `position` are FIELDS, not
--- methods (xrServerEntities/xrServer_Objects_script.cpp:110-124).
--- soulslike.find_closest_enemy:317 reads se_obj.position directly.
function M.make_se_npc(opts)
    opts = opts or {}
    local kind = opts.kind or "stalker"
    local id = opts.id or alloc_id()

    local o = {
        id       = id,
        position = M.make_vector(opts.position),
        m_game_vertex_id  = opts.game_vertex_id or 1,
        m_level_vertex_id = opts.level_vertex_id or 1,
        online   = opts.online == true,
        parent_id = opts.parent_id,
        _kind    = kind,
        _name    = opts.name or (kind .. "_" .. tostring(id)),
        _section = opts.section or ("sim_default_" .. kind),
        _community = opts.community or "stalker",
        _alive   = opts.alive ~= false,
    }

    function o:name() return self._name end
    function o:section_name() return self._section end
    function o:community() return self._community end
    function o:alive() return self._alive end
    function o:clsid()
        if opts.clsid ~= nil then return opts.clsid end
        return require("harness.fakes").clsid_for(self._kind)
    end
    function o:switch_online() self.online = true end

    return o
end

-- --------------------------------------------------------- finder stubbing

-- Which finder create_new called, and how many times. Load-bearing: branches
-- 10 and 11 of the selection tree (soulslike_scenario_logic_factory.script:256
-- and :272) differ only by which finder supplies the looter, so asserting the
-- returned object is not enough to tell them apart.
M.finder_calls = {}

local FINDERS = {
    "find_closest_friendly_stalker",
    "find_closest_enemy",
    "find_closest_enemy_stalker",
    "find_closest_enemy_mutant",
}

--- Replace soulslike's four find_closest_* helpers with constant returns.
--- `t` maps a finder name (with or without the "find_closest_" prefix) to the
--- object it should return; omitted finders return nil.
---
--- Stubs the real scans, which walk 65534 alife slots. Safe across specs
--- because H.boot re-executes soulslike.script, rebuilding its module table.
function M.stub_finders(t)
    t = t or {}
    assert(_G.soulslike, "stub_finders: soulslike.script is not loaded")

    M.finder_calls = {}
    for _, name in ipairs(FINDERS) do
        local short = name:gsub("^find_closest_", "")
        local ret = t[name]
        if ret == nil then ret = t[short] end

        M.finder_calls[name] = 0
        _G.soulslike[name] = function()
            M.finder_calls[name] = M.finder_calls[name] + 1
            return ret
        end
    end
end

--- Times `name` was called since the last stub_finders(). Accepts the short
--- form ("enemy_mutant") as well as the full function name.
function M.finder_count(name)
    if M.finder_calls[name] then return M.finder_calls[name] end
    return M.finder_calls["find_closest_" .. name] or 0
end

--- Installs the `vector()` global used across the mod.
function M.install(env)
    env = env or _G
    env.vector = function() return M.make_vector() end
    return env
end

function M.reset()
    next_id = 1000
    M.finder_calls = {}
end

return M

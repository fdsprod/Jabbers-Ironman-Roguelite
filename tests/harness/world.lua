-- Item / container model, plus the alife simulator object.
--
-- Items live in named containers ("actor", "stash", "looter", ...). Specs
-- assert final placement rather than call sequences:
--
--     world.give("actor", "wpn_ak74", { kind = "weapon", condition = 0.8 })
--     scenario:TransferItems(stash_id)
--     H.tick()
--     expect(world.where("wpn_ak74")).toBe("stash")
--
-- WHY MUTATIONS ARE DEFERRED
--
-- CScriptGameObject::IterateInventory walks the LIVE m_all container with raw
-- iterators -- no snapshot (script_game_object_inventory_owner.cpp:266). The
-- mod calls alife_release and transfer_item from inside that loop
-- (TransferItem, soulslike_scenarios.script:1097/1204/1212), which would
-- invalidate those iterators if the mutations were immediate.
--
-- They are not. transfer_item sends GE_TRADE_SELL / GE_TRADE_BUY network
-- events (:601-609) processed on a later frame, and alife_release queues an
-- alife-level release. So we queue too. Two consequences specs must respect:
--
--   * Inside iterate_inventory, an item already "released" is STILL PRESENT.
--   * TransferItems returning does not mean anything moved. Assert after tick.
--
-- Snapshotting instead would produce the same loop coverage for the wrong
-- reason, and would wrongly model items vanishing mid-loop.

local M = {}

-- SERVER vs CLIENT OBJECTS
--
-- These are different things in X-Ray and the mod uses both, so the model
-- keeps two registries:
--
--   server object (CSE_Abstract)  -- `.id` is a FIELD, plus .section,
--     .position, .online, .parent_id, .m_game_vertex_id. Returned by
--     alife_create, alife_object and alife():object().
--     e.g. soulslike_scenarios.script:1308  self.logic_state.stash_id = se_stash.id
--
--   client object (CScriptGameObject) -- `:id()` is a METHOD, plus :section(),
--     :is_inv_box_empty(), :iterate_inventory_box(). Returned by
--     level.object_by_id.
--     e.g. soulslike.script:599  local id = box:id()
--
-- Conflating them makes `se.id` yield a function, which then silently indexes
-- the registry with a function key and finds nothing.

local next_id
local items          -- id -> item
local containers     -- name -> { ordered item ids }
local holder         -- item id -> container name (nil once destroyed)
local clients        -- id -> client object (`:id()`)
local servers        -- id -> server object (`.id`)
local pending        -- deferred mutations

-- ---------------------------------------------------------------- internals

local function container_of(name)
    containers[name] = containers[name] or {}
    return containers[name]
end

local function remove_from(name, id)
    local c = containers[name]
    if not c then return end
    for i, v in ipairs(c) do
        if v == id then table.remove(c, i) return end
    end
end

local function place(id, name)
    local from = holder[id]
    if from then remove_from(from, id) end
    if name then
        table.insert(container_of(name), id)
    end
    holder[id] = name
end

-- Resolve whatever the mod passed (game object, server object, id) to a
-- container name.
local function name_of(target)
    if target == nil then return nil end
    if type(target) == "string" then return target end
    if type(target) == "number" then
        local o = clients[target]
        return o and o._container or nil
    end
    if target._container then return target._container end
    -- client object: :id() is a method; server object: .id is a field
    local id = (type(target.id) == "function") and target:id() or target.id
    local o = id and clients[id]
    return o and o._container or nil
end

-- ------------------------------------------------------------------- items

--- world.give(container, section, opts) -> item
function M.give(container, section, opts)
    opts = opts or {}
    next_id = next_id + 1
    local id = next_id

    local item = {
        _id        = id,
        _section   = section,
        _kind      = opts.kind or "item",
        _condition = opts.condition == nil and 1.0 or opts.condition,
        _parent    = nil,
    }
    function item:id() return self._id end
    function item:section() return self._section end
    function item:name() return self._section .. "_" .. self._id end
    function item:condition() return self._condition end
    function item:parent() return clients[self._parent] end

    items[id] = item
    clients[id] = item
    place(id, container)
    return item
end

--- A container that can hold items. Registers a client object (`:id()`) and a
--- matching server object (`.id`), since the mod reaches containers both ways.
--- Returns the client object; use M.server(id) for the twin.
function M.container(name, opts)
    opts = opts or {}
    local id = opts.id
    if not id then
        next_id = next_id + 1
        id = next_id
    end

    local box = {
        _id = id, _container = name, _kind = opts.kind or "invbox",
        _section = opts.section or "inv_backpack",
    }
    function box:id() return self._id end
    function box:section() return self._section end
    function box:name() return name end
    function box:is_inv_box_empty() return #container_of(name) == 0 end
    -- Stops on ANY truthy return, not just `true`: the engine tests the
    -- functor result with lua_toboolean
    -- (script_game_object_inventory_owner.cpp:269, converter at
    -- luabind/detail/policy.hpp:374), so 0 and "" stop it too.
    function box:iterate_inventory_box(fn)
        for _, iid in ipairs(container_of(name)) do
            if fn(self, items[iid]) then return end
        end
    end
    function box:transfer_item(item, to) M.queue_transfer(item, to) end

    container_of(name)
    clients[id] = box

    servers[id] = {
        id = id,                                  -- FIELD, not a method
        section = box._section,
        position = opts.position,
        online = opts.online == true,
        parent_id = opts.parent_id,
        m_level_vertex_id = opts.level_vertex_id or 1,
        m_game_vertex_id  = opts.game_vertex_id or 1,
        _container = name,
        switch_online = function(self) self.online = true end,
        create_npc = function() end,
        squad_members = function() return function() return nil end end,
    }

    return box
end

--- The server-object twin of a container or npc.
function M.server(id) return servers[id] end

--- An NPC that can receive looted items.
function M.spawn_npc(name, opts)
    local B = require("harness.builders")
    opts = opts or {}
    local npc = B.make_npc(opts)
    npc._container = name
    container_of(name)
    clients[npc:id()] = npc
    servers[npc:id()] = npc      -- make_npc already carries both shapes
    return npc
end

-- ----------------------------------------------------- deferred mutations

function M.queue_transfer(item, to)
    pending[#pending + 1] = { kind = "transfer", id = item:id(), to = name_of(to) }
end

function M.queue_release(item)
    if item == nil then return end
    local id = type(item) == "number" and item or
               (type(item.id) == "function" and item:id() or item.id)
    pending[#pending + 1] = { kind = "release", id = id }
end

--- Apply everything queued since the last pump. Returns how many were applied.
function M.pump()
    local n = 0
    while #pending > 0 do
        local batch = pending
        pending = {}
        for _, op in ipairs(batch) do
            n = n + 1
            if op.kind == "transfer" then
                if holder[op.id] ~= nil then place(op.id, op.to) end
            elseif op.kind == "release" then
                local from = holder[op.id]
                if from then remove_from(from, op.id) end
                holder[op.id] = nil
                -- items[] is kept so where()/destroyed() can still report it;
                -- the object registries drop it, matching a released object
                -- disappearing from level.object_by_id.
                clients[op.id] = nil
                servers[op.id] = nil
            end
        end
    end
    return n
end

-- -------------------------------------------------------------- assertions

--- Container name holding the item, or nil if destroyed / never placed.
function M.where(item)
    local id = type(item) == "number" and item or
               (type(item) == "string" and nil or item:id())
    if id == nil then                       -- looked up by section name
        for iid, it in pairs(items) do
            if it._section == item then return holder[iid] end
        end
        return nil
    end
    return holder[id]
end

--- Sections currently in a container, in insertion order.
function M.contents(name)
    local out = {}
    for _, id in ipairs(container_of(name)) do
        out[#out + 1] = items[id] and items[id]._section or ("obj:" .. id)
    end
    return out
end

--- Sections of every item that has been released.
function M.destroyed()
    local out = {}
    for id, it in pairs(items) do
        if holder[id] == nil then out[#out + 1] = it._section end
    end
    table.sort(out)
    return out
end

function M.count(name) return #container_of(name) end
function M.item_by_section(section)
    for _, it in pairs(items) do
        if it._section == section then return it end
    end
end
function M.object(id) return clients[id] end

-- ------------------------------------------------------------------ install

--- Rewires the actor's inventory methods and the alife globals onto the model.
--- Call after fakes.install and after the actor exists.
function M.attach_actor(actor, container)
    container = container or "actor"
    actor._container = container
    container_of(container)
    clients[actor:id()] = actor

    -- Live walk, matching IterateInventory. Iterating a copy of the index list
    -- is not a snapshot of *contents*: deferred ops have not been applied, so
    -- released items are still present -- which is the engine's behavior.
    --
    -- Stops on ANY truthy return. The engine takes a luabind::functor<bool>
    -- and the bool converter is lua_toboolean(L,i)==1
    -- (script_game_object_inventory_owner.cpp:269, luabind/detail/policy.hpp:374),
    -- so returning 0 or "" also stops the walk -- only nil and false continue.
    -- Note this is the OPPOSITE of CreateTimeEvent, which re-queues on anything
    -- that is not literally `true` (_g.script:375).
    function actor:iterate_inventory(fn)
        local ids = container_of(container)
        for i = 1, #ids do
            local it = items[ids[i]]
            if it and fn(self, it) then return end
        end
    end

    function actor:transfer_item(item, to) M.queue_transfer(item, to) end
    function actor:is_inv_box_empty() return #container_of(container) == 0 end

    return actor
end

function M.install(env)
    env = env or _G

    env.alife_release = function(item) M.queue_release(item) end

    -- Returns the SERVER object (`.id` field) -- that is what the engine hands
    -- back and what the mod reads (soulslike_scenarios.script:1308).
    --
    -- The 5th and 6th args are parent_id and a `register` flag; the mod passes
    -- both when spawning a weapon part for the Tarkov looter
    -- (soulslike_scenarios.script:1058). register=false yields an unregistered
    -- object the caller is expected to hand to alife():register afterwards.
    env.alife_create = function(section, pos, lvid, gvid, parent_id, register)
        next_id = next_id + 1
        local id = next_id
        local name = "spawned_" .. id
        M.container(name, {
            id = id, section = section, position = pos,
            level_vertex_id = lvid, game_vertex_id = gvid, online = false,
            parent_id = parent_id,
        })
        local se = servers[id]
        se.registered = register ~= false
        M.created[#M.created + 1] = {
            id = id, section = section, container = name,
            parent_id = parent_id, registered = se.registered,
        }

        -- Squad sections spawn their members with the squad object, which is
        -- what SpawnAmbush then iterates (soulslike_scenarios.script:763).
        local members = M.squads[section]
        if members then
            local B = require("harness.builders")
            local built = {}
            for i, m in ipairs(members) do
                local npc = B.make_se_npc(m)
                servers[npc.id] = npc
                built[i] = npc
            end
            se.create_npc = require("harness.fakes").recorder("se.create_npc")
            se.squad_members = function()
                local i = 0
                return function() i = i + 1 return built[i] end
            end
        end

        return se
    end

    -- Returns a SERVER object too. The mod keys note_message_data by se_note.id
    -- (soulslike_scenarios.script:1400), which silently produces a
    -- function-keyed table if this hands back a client object.
    env.alife_create_item = function(section, owner, opts)
        local name = (owner and name_of(owner)) or "actor"
        local item = M.give(name, section, opts)
        local id = item:id()
        servers[id] = servers[id] or {
            id = id,
            section = section,
            position = (opts and opts.position) or nil,
            online = false,
            parent_id = owner and
                (type(owner) == "table" and type(owner.id) == "function"
                 and owner:id() or (type(owner) == "table" and owner.id))
                or nil,
            _container = name,
        }
        return servers[id]
    end

    env.alife_object = function(id) return servers[id] end

    -- level.object_by_id returns the CLIENT object. Specs exercising the
    -- "stash is not online yet" retry (HandleItemsAndRespawn:536) call
    -- world.hide(id) first.
    local level = env.level
    M.hidden = {}
    level.object_by_id = function(id)
        if M.hidden[id] then return nil end
        if clients[id] then return clients[id] end
        return require("harness.fakes").objects[id]
    end

    env.alife = function() return M.sim end

    local fakes = require("harness.fakes")
    local record_teleport = fakes.recorder("alife.teleport_object")
    local record_online   = fakes.recorder("alife.set_switch_online")
    local record_offline  = fakes.recorder("alife.set_switch_offline")

    M.sim = {
        actor = function()
            local a = env.db and env.db.actor
            if not a then return nil end
            return {
                position = a:position(),
                angle = require("harness.builders").make_vector(),
                m_level_vertex_id = a:level_vertex_id(),
                m_game_vertex_id  = a:game_vertex_id(),
                id = a:id(),
            }
        end,
        object            = function(_, id) return servers[id] end,
        level_name        = function(_, _) return M.level_name_for_gvid end,

        -- Server-side, offline-safe repositioning (soulslike.script:832/842).
        -- Mutates the server object's own position/vertex fields, which is
        -- what the mod reads back afterwards (e.g. se_box.position).
        teleport_object = function(self, id, gvid, lvid, pos)
            record_teleport(self, id, gvid, lvid, pos)
            local se = servers[id]
            if se then
                se.m_game_vertex_id = gvid
                se.m_level_vertex_id = lvid
                se.position = pos
            end
        end,

        -- alife():set_switch_online/offline are pure FLAG setters in the real
        -- engine, not immediate actions (CALifeUpdateManager::set_switch_online
        -- /set_switch_offline, alife_update_manager.cpp:333-345 -- each just
        -- calls can_switch_online(bool)/can_switch_offline(bool), which toggle
        -- bits in m_flags, xrServer_Objects_ALife.cpp:603-611). Every object is
        -- constructed with every flag on (xrServer_Objects_ALife.cpp:374), so
        -- normal distance-based switching is the default.
        --
        -- The flag that matters for this mod is can_switch_offline: when it is
        -- false, try_switch_online's fast path force-onlines the object on the
        -- next tick with NO distance check, and try_switch_offline's first
        -- check refuses to ever offline it again -- it stays online permanently
        -- (CSE_ALifeDynamicObject::try_switch_online/try_switch_offline,
        -- alife_dynamic_object.cpp:130-181). That is the mechanism
        -- set_switch_online(id,true) + set_switch_offline(id,false) relies on
        -- (soulslike.script:734-735, soulslike_scenarios.script:1440-1441): it
        -- is not "reveal now", it is "pin online forever", and the harness
        -- collapses the one-tick delay to immediate since nothing here depends
        -- on the gap.
        --
        -- set_switch_offline(id,true) is the inverse -- it only re-enables
        -- ELIGIBILITY for future distance-based offlining. It does not force
        -- the object offline immediately, and the harness has no distance
        -- model to act on that eligibility, so it is a recorded no-op here.
        set_switch_online = function(self, id, online)
            record_online(self, id, online)
            local se = servers[id]
            if online ~= false then
                if se then se.online = true end
                M.reveal(id)
            end
        end,
        set_switch_offline = function(self, id, offline)
            record_offline(self, id, offline)
            local se = servers[id]
            if offline == false then
                if se then se.pinned_online = true end
            end
        end,
        release           = function(_, o) M.queue_release(o) end,

        -- register() FREES its argument and returns a NEW pointer
        -- (alife_simulator_script.cpp:396-413) -- the object passed in is
        -- dangling afterwards. Modelled by swapping in a fresh table under the
        -- same id, so a spec that keeps using the old reference sees it go
        -- stale rather than silently working.
        register = function(_, se)
            if se == nil then return nil end
            local id = se.id
            local fresh = {}
            for k, v in pairs(se) do fresh[k] = v end
            fresh.registered = true
            servers[id] = fresh
            se.released = true
            M.registered[#M.registered + 1] = id
            return fresh
        end,
    }
    M.level_name_for_gvid = "zaton"

    return env
end

--- Register a server-shaped NPC so the 1..65534 alife scan in
--- soulslike.find_closest_enemy / _enemy_mutant can find it. Ids start at
--- 10000, comfortably inside the scanned range.
function M.spawn_se_npc(opts)
    local npc = require("harness.builders").make_se_npc(opts)
    servers[npc.id] = npc
    return npc
end

--- Make an object invisible to level.object_by_id, to exercise the
--- "stash is not online yet" retry in HandleItemsAndRespawn.
function M.hide(id) M.hidden[id] = true end
function M.reveal(id) M.hidden[id] = nil end

function M.reset()
    next_id = 10000
    items, containers, holder, pending = {}, {}, {}, {}
    clients, servers = {}, {}
    M.created = {}
    M.registered = {}
    M.hidden = {}
    -- section -> list of make_se_npc opts. SpawnAmbush creates its squad
    -- itself, so members cannot be passed in the way M.container's can.
    M.squads = {}
    M.sim = nil
    M.level_name_for_gvid = "zaton"
end

M.reset()

return M

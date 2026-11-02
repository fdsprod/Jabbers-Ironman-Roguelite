-- The server/client object model, plus the alife simulator. New for this repo, and
-- installed on top of the copied fakes.lua and world.lua by H.boot_game. world.lua
-- models one object per item, which is the right shape for the Soulslike transfers
-- and the wrong one here, because item uses depend on the split.
--
-- X-Ray keeps two copies of a thing. The server object (CSE_*) exists for
-- everything in the game and is what alife():object returns. The client object
-- (CScriptGameObject) exists only while the object is online and is what
-- level.object_by_id returns. Item uses are the reason this model exists, so the
-- split has to be right:
--
--   * Uses live on the client object only: CEatableItem::m_iRemainingUses
--     (eatable_item.h:23). No CSE_ALifeItem field holds them.
--   * A new client object starts full. Load() sets remaining = max_uses
--     (eatable_item.cpp:48).
--   * The engine never carries them over for a bound item. net_Spawn only reads
--     client_data when it is present (GameObject.cpp:379), the client only saves
--     into it when net_SaveRelevant() is true (Level_network.cpp:245), and for a
--     script-bound item that resolves to CScriptBinderObject::net_SaveRelevant,
--     which returns false (script_binder_object.cpp:63). Going offline clears it
--     regardless (alife_dynamic_object.cpp:62-69, :291-299).
--
-- That is why the stock bind_item.script keeps its own table of uses. It is
-- loaded for real here, not modelled.

local M = {}

local fakes = require("harness.fakes")
local builders = require("harness.builders")

-- ----------------------------------------------------------- virtual files
--
-- Saves and the between-lives state file go through plain io.open in the real
-- scripts (alife_storage_manager.script:225, roguelite_manager.script:101/149).
-- They land here instead of on disk. M.files is what survives a new life, the
-- same way appdata\ survives a new game. Every other path falls through, because
-- the module loader reads real scripts with io.open.

M.files = {}

local real_io_open, real_io_type = io.open, io.type

local function is_virtual(path)
    path = tostring(path)
    return path:find("^saves/") ~= nil or path:find("^appdata\\") ~= nil
end

local function open_virtual(path, mode)
    mode = mode or "r"
    if mode:find("r") then
        local data = M.files[path]
        if data == nil then return nil end
        return {
            _virtual = true,
            read  = function(_, _) return data end,
            close = function() end,
        }
    end
    local parts = {}
    return {
        _virtual = true,
        write = function(_, s) parts[#parts + 1] = s end,
        close = function() M.files[path] = table.concat(parts) end,
    }
end

local function install_files()
    io.open = function(path, mode, ...)
        if is_virtual(path) then return open_virtual(path, mode) end
        return real_io_open(path, mode, ...)
    end
    io.type = function(f)
        if type(f) == "table" and f._virtual then return "file" end
        return real_io_type(f)
    end
end

-- ----------------------------------------------------------------- marshal
--
-- A real encoding to a real string, not a pass-through. A pass-through would hand
-- the decoder the same table the encoder saw, so a value mutated after the save
-- would appear to have been persisted. Functions and anything with a metatable
-- raise, which keeps a server object or a vector out of the state file, where
-- the real marshal could not persist C userdata either.

local function encode_value(v, seen)
    local t = type(v)
    if t == "number" then return string.format("%.17g", v) end
    if t == "string" then return string.format("%q", v) end
    if t == "boolean" then return tostring(v) end
    if t == "table" then
        if getmetatable(v) then
            error("marshal: cannot persist an object with a metatable", 0)
        end
        if seen[v] then error("marshal fake: cycles are not modelled", 0) end
        seen[v] = true
        local out = {}
        for k, val in pairs(v) do
            out[#out + 1] = "[" .. encode_value(k, seen) .. "]=" .. encode_value(val, seen)
        end
        seen[v] = nil
        return "{" .. table.concat(out, ",") .. "}"
    end
    error("marshal fake: cannot persist a " .. t, 0)
end

local marshal = {
    encode = function(v) return encode_value(v, {}) end,
    decode = function(s)
        local chunk, err = loadstring("return " .. s)
        if not chunk then error("marshal.decode: " .. tostring(err), 0) end
        return chunk()
    end,
}


local next_id, records, clients, spawn_queue, frame_no

-- Records of every read of a server object after alife():register freed it.
M.use_after_free = {}

-- GUESS: how many frames pass between alife():register and the client object
-- existing. The spawn goes out over the local net (xrServer_process_spawn.cpp:
-- 145-168) and is applied by the next CLevel::ProcessGameEvents (Level.cpp:362).
-- One frame is the shortest it could be. A spec that cares sets this.
--
-- Size does not change it. SPAWN_ANTIFREEZE, the only thing that would spread a
-- batch over several frames, is commented out (build_config_defines.h:28), so
-- ProcessGameEvents applies every pending spawn in one pass.
M.spawn_latency_frames = 1

-- Binder updates run on the object scheduler (GameObject.cpp:859-875), not every
-- frame. Modelled as every frame, because nothing here depends on the cadence.
-- A spec that needs a binder that has not run yet sets this.
M.binders_paused = false

-- --------------------------------------------------------- server objects

-- A proxy over the record. Reads resolve against the record; once register has
-- freed this pointer, each read is logged and still answers, because in the game
-- the bytes usually survive long enough to look fine. That is why it needs a spec
-- rather than a crash report, and why raising here would hide what else is wrong.
local function make_proxy(rec)
    local proxy = {}
    local state = { freed = false }
    setmetatable(proxy, {
        __index = function(_, k)
            if state.freed then
                M.use_after_free[#M.use_after_free + 1] = { id = rec.id, section = rec.section, key = k }
            end
            return rec[k]
        end,
        __newindex = function(_, k, v) rec[k] = v end,
        __free = function() state.freed = true end,
    })
    return proxy
end

local function free_proxy(proxy)
    getmetatable(proxy).__free()
end

local function new_record(section, position, lvid, gvid, parent_id)
    next_id = next_id + 1
    local def = fakes.ltx[section] or {}
    local rec = {
        id = next_id,
        parent_id = parent_id or 65535,
        position = position or builders.make_vector(),
        angle = builders.make_vector(),
        m_level_vertex_id = lvid or 1,
        m_game_vertex_id = gvid or 1,
        online = false,
        registered = false,
        section = section,
        _kind = def.kind or "item",
        _packet = { condition = 1.0, upgrades = {}, custom_data = "" },
    }
    function rec.section_name(_) return section end
    function rec.name(_) return section .. rec.id end
    function rec.clsid(_) return fakes.clsid_for(rec._kind) end
    -- The stalker the corpse module spawns (roguelite_module_player_corpse.script:75).
    function rec.set_character_name(_, name) rec._character_name = name end
    function rec.character_name(_) return rec._character_name end
    function rec.set_profile_name(_, name) rec.profile = name end
    function rec.kill(_) rec.dead = true end
    records[rec.id] = rec
    rec.proxy = make_proxy(rec)
    return rec
end

local function record_of(target)
    if target == nil then return nil end
    if type(target) == "number" then return records[target] end
    local id = type(target.id) == "function" and target:id() or target.id
    return records[id]
end

local function children_of(id)
    local out = {}
    for _, rec in pairs(records) do
        if rec.parent_id == id then out[#out + 1] = rec end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- --------------------------------------------------------- client objects

-- game_object.relation values (script_game_object_script2.cpp:38-44, over
-- ERelationType at alife_space.h:82-90).
local RELATION = { friend = 0, neutral = 1, enemy = 2, dummy = -1 }

-- What a stalker's client object adds. Rep lives on the record, because the setter
-- writes through to the server object (InventoryOwner.cpp:471-486) and a new client
-- reads it back (InventoryOwner.cpp:135, character_info.cpp:158).
local function add_stalker_surface(obj, rec)
    function obj:character_name() return rec._character_name end
    function obj:character_community() return rec._community end
    function obj:character_reputation() return rec._reputation or 0 end
    -- Takes an int, and luabind casts the Lua number, so it truncates toward zero
    -- (script_game_object_inventory_owner.cpp:957, luabind policy.hpp:377).
    function obj:set_character_reputation(v)
        rec._reputation = v >= 0 and math.floor(v) or math.ceil(v)
    end
    -- A nil is a null deref in the engine (script_game_object_use.cpp:147), so a crash
    -- and not an error. It raises here to stay visible.
    function obj:relation(who)
        if who == nil then error("relation: who is nil") end
        return rec._relation or RELATION.neutral
    end
    function obj:alive() return not rec.dead end
end

-- motivator_binder: db.storage in reinit (xr_motivator.script:40), then in net_spawn
-- db.add_obj (:93, db.script:70-76) and the callback (:182). A corpse returns before the
-- callback (:94-117).
local function stalker_appears(obj, rec)
    _G.db.storage[rec.id] = { object = obj, ini = rec._ini, section_logic = rec._section_logic }
    _G.db.OnlineStalkers[#_G.db.OnlineStalkers + 1] = rec.id
    if not rec.dead then _G.SendScriptCallback("npc_on_net_spawn", obj, rec.proxy) end
end

-- motivator_binder:net_destroy: the callback (xr_motivator.script:226) comes before
-- db.del_obj (:258, db.script:78-83), so the handler still sees a working client.
local function stalker_leaves(obj, rec)
    _G.SendScriptCallback("npc_on_net_destroy", obj)
    _G.db.storage[rec.id] = nil
    for i = #_G.db.OnlineStalkers, 1, -1 do
        if _G.db.OnlineStalkers[i] == rec.id then table.remove(_G.db.OnlineStalkers, i) end
    end
end

-- trader_object_binder, for class AI_TRD_S sections (m_person.ltx:4-12, :100). In net_spawn
-- db.add_obj sets .object, and only a live one gets it (bind_trader.script:24, :57-65).
-- db.add_obj adds only clsid.script_stalker to db.OnlineStalkers (db.script:73), and this
-- binder sends no callback at all, so nothing tells a script this NPC came or went.
local function script_trader_appears(obj, rec)
    _G.db.storage[rec.id] = { ini = rec._ini, section_logic = rec._section_logic }
    if not rec.dead then _G.db.storage[rec.id].object = obj end
end

-- bind_trader.script:96-98.
local function script_trader_leaves(rec)
    _G.db.storage[rec.id] = nil
    _G.alife_storage_manager.get_state().game_object[rec.id] = nil
end

local function make_client(rec)
    local def = fakes.ltx[rec.section] or {}
    local max = def.max_uses or 1
    local obj = {
        _id = rec.id, _section = rec.section, _kind = rec._kind,
        _max = max, _uses = max,       -- eatable_item.cpp:48
        -- CInventoryItem::net_Spawn reads it from the server object
        -- (inventory_item.cpp:361). CEatableItem::net_Spawn then forces multiuse items
        -- back to 1 (eatable_item.cpp:83-89).
        _condition = max > 1 and 1 or (rec._packet and rec._packet.condition or 1),
    }
    function obj:id() return self._id end
    function obj:section() return self._section end
    function obj:name() return self._section .. self._id end
    function obj:position() return rec.position end
    function obj:parent() return clients[rec.parent_id] end
    function obj:get_max_uses() return self._max end
    function obj:get_remaining_uses() return self._uses end
    -- Silently ignored above the maximum (eatable_item.h:49).
    function obj:set_remaining_uses(v)
        if v <= self._max then self._uses = v end
    end
    function obj:condition() return self._condition end
    -- Only weapons, outfits and helmets send condition back to the server object
    -- (Weapon.cpp:738, CustomOutfit.cpp:51, ActorHelmet.cpp:89, read at
    -- xrServer_Objects_ALife_Items.cpp:539, :1288, :1333). For anything else the server
    -- keeps the value it spawned with, which is why bind_item stores condition itself.
    function obj:set_condition(v)
        self._condition = v
        if rec._kind == "weapon" or rec._kind == "outfit" or rec._kind == "headgear" then
            rec._packet.condition = v
        end
    end
    function obj:clsid() return fakes.clsid_for(rec._kind) end
    function obj:level_vertex_id() return rec.m_level_vertex_id end
    function obj:game_vertex_id() return rec.m_game_vertex_id end
    -- A snapshot, because alife_release above is immediate. The callback gets the
    -- context argument first, and any truthy return stops the walk
    -- (script_game_object_inventory_owner.cpp:266-269).
    function obj:iterate_inventory(fn, ctx)
        local ids = {}
        for _, child in ipairs(children_of(rec.id)) do
            if clients[child.id] then ids[#ids + 1] = child.id end
        end
        for _, id in ipairs(ids) do
            if clients[id] and fn(ctx, clients[id]) then return end
        end
    end
    function obj:bind_object(binder) self._binder = binder end

    if rec._kind == "stalker" or rec._kind == "script_trader" then add_stalker_surface(obj, rec) end

    clients[rec.id] = obj
    rec.online = true

    if def.script_binding == "bind_item.bind" and rawget(_G, "bind_item") then
        _G.bind_item.bind(obj)
    end
    if rec._kind == "stalker" then stalker_appears(obj, rec) end
    if rec._kind == "script_trader" then script_trader_appears(obj, rec) end
    return obj
end

local function queue_spawn(rec)
    spawn_queue[#spawn_queue + 1] = { rec = rec, due = frame_no + M.spawn_latency_frames }
end

local function apply_due_spawns()
    local remaining = {}
    for _, entry in ipairs(spawn_queue) do
        if entry.due <= frame_no then
            if records[entry.rec.id] == entry.rec and entry.rec.registered then
                make_client(entry.rec)
            end
        else
            remaining[#remaining + 1] = entry
        end
    end
    spawn_queue = remaining
end

-- ------------------------------------------------------------ public helpers

--- Declare an item or stash section. A max_uses above 1 on a use_condition item
--- makes it multiuse (_g.script:3298-3302). All 75 such sections in the stock
--- configs bind to bind_item.bind, so that is the default here.
--- A script_binding of item_device.bind makes it a device (_g.script:3271). That
--- binder is not modelled: such an item keeps its condition on the client object.
function M.define(section, def)
    def = def or {}
    if def.script_binding == "item_device.bind" then
        _G._ITM.device[section] = true
    end
    if def.max_uses and def.max_uses > 1 then
        def.script_binding = def.script_binding or "bind_item.bind"
        _G._ITM.multiuse[section] = def.max_uses
    end
    fakes.ltx[section] = def
end

--- A player stash that already exists in the world.
function M.stash(section, opts)
    opts = opts or {}
    local rec = new_record(section or "placeable_case", opts.position)
    rec._kind = "invbox"
    rec.registered = true
    if opts.online ~= false then make_client(rec) end
    return clients[rec.id], rec.proxy
end

--- An item already sitting on the actor or in a box, with `opts.uses` left.
--- The parent must be online: only then does a client object exist to hold uses.
--- To get a used item into an offline stash, put it there online and let the
--- stash go offline, as the game does.
function M.give(parent, section, opts)
    opts = opts or {}
    local parent_rec = record_of(parent)
    assert(parent_rec and parent_rec.online, "alife.give: parent must be online")
    local rec = new_record(section, parent_rec.position, 1, 1, parent_rec.id)
    rec.registered = true
    local obj = make_client(rec)
    if opts.uses then obj:set_remaining_uses(opts.uses) end
    return obj, rec.proxy
end

--- The player drags an item into a box. ui_inventory.script:2172 sends the
--- callback as (box, item).
function M.put_in_box(item, box)
    record_of(item).parent_id = box:id()
    _G.SendScriptCallback("actor_on_item_put_in_box", box, item)
end

--- The box leaves or enters the online radius. Going offline destroys the client
--- objects of the box and everything in it; coming back spawns fresh ones, which
--- start full until something restores them.
function M.set_online(id, online)
    local rec = records[id]
    if online then
        if not rec.online then
            rec.online = true
            queue_spawn(rec)
            for _, child in ipairs(children_of(id)) do
                child.online = true
                queue_spawn(child)
            end
        end
    else
        rec.online = false
        if rec._kind == "stalker" and clients[id] then stalker_leaves(clients[id], rec) end
        if rec._kind == "script_trader" and clients[id] then script_trader_leaves(rec) end
        clients[id] = nil
        for _, child in ipairs(children_of(id)) do
            child.online = false
            clients[child.id] = nil
        end
    end
end

--- An NPC in the world. Returns its id. opts: name, section, community, rep, online
--- (default true), relation, story_id, ini and section_logic (for db.storage). The
--- server fields are the bindings at xrServer_Objects_ALife_Monsters_script.cpp:71, :74
--- and :79.
function M.stalker(opts)
    opts = opts or {}
    local rec = new_record(opts.section or "sim_default_stalker")
    rec._kind = opts._kind or "stalker"
    rec.registered = true
    rec._character_name = opts.name
    rec._community = opts.community or "stalker"
    rec._reputation = opts.rep or 0
    rec._relation = opts.relation
    rec._ini = opts.ini
    rec._section_logic = opts.section_logic
    rec._story_id = opts.story_id
    function rec.community(_) return rec._community end
    function rec.reputation(_) return rec._reputation end
    if opts.story_id then _G.story_objects.register(rec.id, opts.story_id) end
    if opts.online ~= false then make_client(rec) end
    return rec.id
end

--- A stalker utils_obj.is_trader says yes to. By default through community "trader".
--- Pass a section with "trader" in it and a community to use the section branch.
function M.trader(opts)
    opts = opts or {}
    local copy = {}
    for k, v in pairs(opts) do copy[k] = v end
    copy.community = opts.community or "trader"
    return M.stalker(copy)
end

--- Sidorovich or the Forester: class AI_TRD_S, bound by bind_trader, not a stalker. Same
--- opts as M.stalker. The client has the same rep methods, because CAI_Trader is a
--- CInventoryOwner (ai_trader.h:25-26) and se_trader a cse_alife_trader
--- (se_stalker.script:148). Stock story ids are esc_m_trader and red_forester_tech (all.spawn).
function M.script_trader(opts)
    opts = opts or {}
    local copy = {}
    for k, v in pairs(opts) do copy[k] = v end
    copy._kind = "script_trader"
    copy.section = opts.section or "m_trader"
    copy.community = opts.community or "trader"
    return M.stalker(copy)
end

--- The rep the engine holds, whether or not the NPC is online. m_reputation on the
--- server object (InventoryOwner.cpp:482).
function M.rep_of(id) return records[id]._reputation end

--- The player talks to them (pda.script:101-104).
function M.meet(id)
    local m_data = _G.alife_storage_manager.get_state()
    if not (m_data.actor_contacts) then
        m_data.actor_contacts = {}
    end
    m_data.actor_contacts[id] = true
end

--- How the NPC stands with the actor from now on. A game_object.relation value.
function M.set_relation(id, relation) records[id]._relation = relation end

--- A server object that holds a story id and is no trader. character_name and reputation
--- are bound on cse_alife_trader_abstract only (xrServer_Objects_ALife_Monsters_script.cpp:74,
--- :79), so this one has neither, and calling them raises. story_objects.register keeps the
--- first holder of an id (story_objects.script:6-14), which is how it can shut the trader
--- out. GUESS: no stock object or GAMMA mod found does this. A mod could.
function M.non_trader_story_object(story_id)
    local rec = new_record("story_prop")
    rec.registered = true
    rec.character_name = nil
    rec.set_character_name = nil
    rec._story_id = story_id
    _G.story_objects.register(rec.id, story_id)
    return rec.id
end

--- An online NPC with no db.storage entry, which makes is_trader raise. It stays in
--- db.OnlineStalkers.
function M.drop_storage(id) _G.db.storage[id] = nil end

--- Set an MCM value as ui_mcm.get returns it, by the key get_config is given.
function M.set_mcm(key, value) fakes.mcm["roguelite/" .. key] = value end

function M.client(id) return clients[id] end
function M.server(id)
    local rec = records[id]
    return rec and rec.registered and rec.proxy or nil
end

--- Registered items inside a box, as server objects sorted by id.
function M.contents(box_id)
    local out = {}
    for _, rec in ipairs(children_of(box_id)) do
        if rec.registered then out[#out + 1] = rec.proxy end
    end
    return out
end

--- Uses of everything of `section` in a box, sorted, from the client objects.
--- Raises if an item has no client object yet, because then there is no answer.
function M.uses_in_box(box_id, section)
    local out = {}
    for _, rec in ipairs(children_of(box_id)) do
        if rec.section == section then
            local obj = clients[rec.id]
            assert(obj, "alife.uses_in_box: " .. rec.section .. " has no client object")
            out[#out + 1] = obj:get_remaining_uses()
        end
    end
    table.sort(out)
    return out
end

--- Stashes that came back this life, as server objects sorted by id.
function M.all_stashes(section)
    local out = {}
    for _, rec in pairs(records) do
        if rec.section == section then out[#out + 1] = rec.proxy end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- One frame: pending spawns land, binders update, then the item processor runs,
--- as the actor binder does each update (bind_stalker.script:252).
function M.frame(delta)
    frame_no = frame_no + 1
    fakes.advance_time(delta or 16)
    apply_due_spawns()

    if not M.binders_paused then
        local ids = {}
        for id, obj in pairs(clients) do
            if obj._binder then ids[#ids + 1] = id end
        end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local obj = clients[id]
            if obj then obj._binder:update(delta or 16) end
        end
    end

    local itms = rawget(_G, "itms_manager")
    if itms then itms.get_item_processor():update() end
end

-- ------------------------------------------------- reloading a save

--- Everything in alife persists across a load. Client objects do not.
function M.export()
    return { records = records, next_id = next_id }
end

--- Put a saved alife back. Each online object gets a fresh client object through
--- the spawn queue; the actor is set up by the caller.
function M.import(saved)
    records = saved.records
    next_id = saved.next_id
    clients = {}
    spawn_queue = {}
    for _, rec in pairs(records) do
        if rec.online and rec.id ~= _G.AC_ID then queue_spawn(rec) end
        -- Registered again as each server object registers (axr_main.script:368).
        if rec._story_id then _G.story_objects.register(rec.id, rec._story_id) end
    end
end

-- ------------------------------------------------------------------ install

function M.attach_actor(actor)
    local rec = {
        id = 0, parent_id = 65535, position = actor:position(),
        angle = builders.make_vector(), online = true, registered = true,
        section = "actor", _kind = "actor", m_level_vertex_id = 1, m_game_vertex_id = 1,
    }
    function rec.section_name() return "actor" end
    function rec.name() return "actor" end
    function rec.profile_name() return "actor_profile" end
    rec.proxy = make_proxy(rec)
    function actor:character_icon() return "ui_inGame2_actor_icon" end
    function actor:get_visual_name() return "actors\\stalker_neutral\\actor" end
    records[0] = rec
    clients[0] = actor
end

-- What the roguelite scripts and the stock scripts they lean on read, over and
-- above the copied fakes.lua.
local function install_engine_surface(env)
    env.USE_MARSHAL = true       -- _g.script:46, `marshal ~= nil`
    env.marshal = marshal
    env.lfs = { mkdir = function() end }
    env.printe = fakes.recorder("printe")
    env.callstack = function() end
    env.printdbg = function() end

    env.IsAmmo = function(obj, cls)
        if cls ~= nil then return cls == fakes.clsid_for("ammo") end
        return obj ~= nil and obj._kind == "ammo"
    end
    -- _g.script:1073
    env.get_clsid = function(obj) return obj and obj:clsid() or nil end
    -- Only what is_trader and db.add_obj compare against.
    env.clsid = {
        script_stalker = fakes.clsid_for("stalker"),
        script_trader  = fakes.clsid_for("script_trader"),
        trader         = fakes.clsid_for("trader"),
    }
    env.game_object = RELATION
    -- _g.script:2922-2927
    env.IsTrader = function(o, c)
        if not (c) then
            c = o and o:clsid()
        end
        return c and (c == env.clsid.script_trader or c == env.clsid.trader) or false
    end

    -- story_objects.script:3-14. A story id is known while its object is offline.
    env.story_objects = { object_id_by_story_id = {}, story_id_by_object_id = {} }
    function env.story_objects.register(obj_id, story_id)
        local so = env.story_objects
        if so.object_id_by_story_id[story_id] and so.object_id_by_story_id[story_id] ~= obj_id then
            return
        end
        so.object_id_by_story_id[story_id] = obj_id
        so.story_id_by_object_id[obj_id] = story_id
    end

    -- Verbatim from utils_obj.script:74-95. `trader` is an undefined global there,
    -- so it reads nil. With no db.storage entry the third step raises.
    local string_find = string.find
    local trader = nil
    env.utils_obj.is_trader = function(...)
        local p = {...}
        if p[1]:character_community() == "trader" or p[1]:clsid() == env.clsid.script_trader or p[1]:clsid() == env.clsid.trader then
            return true
        end

        if string_find(p[1]:section(),"trader") then
            return true
        end

        local cini = env.db.storage[p[1]:id()].ini
        local logic = env.db.storage[p[1]:id()].section_logic

        if not logic and not trader then
            return false
        end

        if cini and logic and cini:section_exist(logic) and cini:line_exist(logic,"trade") then
            return true
        end

        return false
    end
    -- _g.script:2425, for the only object these specs ask about.
    env.character_community = function(obj) return obj:character_community() end

    -- Verbatim from _g.script:3193-3196. _ITM.multiuse[section] holds max_uses
    -- (_g.script:3302), so IsItem("multiuse", ...) returns a number. The copied
    -- fake reads a `kind` key instead, which cannot express that.
    env._ITM = { multiuse = {}, device = {} }
    env.IsItem = function(typ, sec, obj)
        sec = obj and obj:section() or sec
        return sec and env._ITM[typ] and env._ITM[typ][sec] or nil
    end

    -- Deep copy, as _g.script:1809 does.
    local function dup(t)
        if type(t) ~= "table" then return t end
        local out = {}
        for k, v in pairs(t) do out[k] = dup(v) end
        return out
    end
    env.dup_table = dup
    env.is_empty = function(t) return t == nil or next(t) == nil end

    env.ini_sys.section_exist = function(_, section) return fakes.ltx[section] ~= nil end
    env.ini_sys.r_float_ex = function(_, section, key)
        local sec = fakes.ltx[section]
        return sec and sec[key]
    end

    -- itms_manager.script:27-32 opens six config files at file scope. The
    -- ItemProcessor under test reads none of them, so they load as empty.
    env.ini_file = function()
        return {
            line_count       = function() return 0 end,
            section_for_each = function() end,
            section_exist    = function() return false end,
            line_exist       = function() return false end,
        }
    end
    env.utils_data.collect_section = function() return {} end

    -- Verbatim from utils_item.script:730-732. The `or 1` is why the `or 0` at
    -- roguelite_module_stashes.script:372 can never fire.
    env.utils_item.get_item_remaining_uses = function(obj)
        return obj and env.IsItem("multiuse", nil, obj) and obj:get_remaining_uses() or 1
    end

    -- The real ones walk a net packet (utils_stpk.script:427-453). Packet layout
    -- is not what these specs are about, so the "packet" is a table on the server
    -- object. get_* hands back a copy and set_* replaces it, which keeps the
    -- read-modify-write shape restore_item relies on.
    local function read_packet(se) return dup(se._packet) end
    local function write_packet(t, se) se._packet = dup(t) end
    env.utils_stpk = {
        get_item_data   = read_packet, set_item_data   = write_packet,
        get_ammo_data   = read_packet, set_ammo_data   = write_packet,
        get_weapon_data = read_packet, set_weapon_data = write_packet,
        -- Recorded, because calling it on the actor is a defect. The actor is not laid
        -- out like a stalker: CSE_ALifeCreatureActor writes creature, trader, skeleton
        -- (xrServer_Objects_ALife_Monsters.cpp:1504-1510), and this parses trader,
        -- object, visual, creature, monster, human (utils_stpk.script:614-631).
        get_stalker_data = fakes.recorder("utils_stpk.get_stalker_data", {}),
    }

    -- Released objects leave both registries. Immediate rather than deferred, because
    -- iterate_inventory below walks a snapshot.
    env.alife_release = function(target)
        local rec = record_of(target)
        if not rec then return end
        local se = rec.proxy
        records[rec.id] = nil
        clients[rec.id] = nil
        env.SendScriptCallback("server_entity_on_unregister", se)
        return true
    end

    -- item_parts.script:610-620, keyed by id rather than through se_save_var. The
    -- copied stub in mods.lua takes (item) only, and serialize_item passes
    -- (nil, id).
    local parts = {}
    env.item_parts = {
        get_parts_con = function(obj, id)
            id = obj and obj:id() or id
            return id and parts[id]
        end,
        set_parts_con = function(id, data) parts[id] = data end,
    }

    -- A transcription of the guard at death_manager.script:186-191 around a model
    -- of the rest. keep_item is what hurts a restored corpse: for weapons, outfits,
    -- ammo and grenades it rerolls condition or releases the item
    -- (death_manager.script:437-466). The model releases each item it is asked to
    -- keep, which is the outcome a spec cares about. The real file needs most of the
    -- game loaded just to read its config.
    env.death_manager = {
        keep_item = function(_, item)
            env.alife_release(item)
        end,
    }
    function env.death_manager.create_release_item(npc)
        local npc_id, npc_name = npc:id(), npc:name()
        if env.se_load_var(npc_id, npc_name, "death_dropped") then return end
        env.se_save_var(npc_id, npc_name, "death_dropped", true)
        npc:iterate_inventory(function(owner, item)
            env.death_manager.keep_item(owner, item)
        end, npc)
    end

    -- _g.script:2647-2671, on the real alife_storage_manager's table.
    env.se_save_var = function(id, name, varname, val)
        local state = env.alife_storage_manager.get_state()
        state.se_object = state.se_object or {}
        state.se_object[id] = state.se_object[id] or {}
        state.se_object[id][varname] = val
    end
    env.se_load_var = function(id, name, varname)
        local state = env.alife_storage_manager.get_state()
        return state.se_object and state.se_object[id] and state.se_object[id][varname]
    end

    -- level_script.cpp:1637, :1661. M.start_seconds and fakes.game_seconds are the
    -- two ends of diffSec in get_time_elapsed. The factor divides game time back to
    -- real time.
    env.level.get_start_time = function() return fakes.make_ctime(M.start_seconds) end
    env.level.get_time_factor = function() return M.time_factor end
    M.start_seconds = fakes.game_seconds
    M.time_factor = 1

    -- get_modules lists roguelite_module_*.script (roguelite_manager.script:442).
    -- Only M.module_names are listed, so a journey does not have to fake every API
    -- the unrelated modules touch. Saves resolve to the virtual files above.
    env.getFS = function()
        return {
            update_path = function(_, root, tail)
                if root == "$game_saves$" then return "saves/" .. tostring(tail) end
                return tostring(tail)
            end,
            file_list_open_ex = function()
                local names = M.module_names
                return {
                    Size  = function() return #names end,
                    GetAt = function(_, i)
                        local n = names[i + 1]
                        return {
                            NameShort = function() return n .. ".script" end,
                            Size      = function() return 1 end,
                        }
                    end,
                }
            end,
        }
    end
end

function M.install(env)
    env = env or _G

    install_files()
    install_engine_surface(env)

    env.level.object_by_id = function(id) return clients[id] end

    M.sim = {
        -- Only registered objects are in the registry an alife lookup reads
        -- (alife_simulator_script.cpp:177).
        object = function(_, id)
            local rec = records[id]
            return rec and rec.registered and rec.proxy or nil
        end,

        -- The create overloads (alife_simulator_script.cpp:168-229). Three facts
        -- matter to restore_item:
        --   * no parent: registered straight away, offline.
        --   * offline parent: registered straight away, EVEN IF the caller passed
        --     false (:218-219).
        --   * online parent with false: unregistered until register() (:221-226).
        create = function(_, section, position, lvid, gvid, parent_id, reg)
            if parent_id == nil or parent_id == 65535 then
                local rec = new_record(section, position, lvid, gvid)
                rec.registered = true
                return rec.proxy
            end

            local parent = records[parent_id]
            if not (parent and parent.registered) then return nil end

            local rec = new_record(section, position, lvid, gvid, parent_id)
            if not parent.online then
                rec.registered = true
            elseif reg ~= false then
                rec.registered = true
                queue_spawn(rec)
            end
            return rec.proxy
        end,

        -- reprocess_spawn (alife_simulator_script.cpp:396-412). It writes the
        -- object to a packet, FREES the object, and spawns a new one from the
        -- packet. The argument dangles afterwards; only the return value is
        -- live. The id survives: it travels in the packet (xrServer_Object_Base
        -- .cpp:209, :292) and Process_spawn asks for it back
        -- (xrServer_process_spawn.cpp:112).
        register = function(_, se)
            local rec = record_of(se)
            free_proxy(se)
            rec.registered = true
            rec.proxy = make_proxy(rec)
            local parent = records[rec.parent_id]
            if parent and parent.online then queue_spawn(rec) end
            return rec.proxy
        end,
    }

    M.sim.actor = function() return records[0] and records[0].proxy end

    env.alife = function() return M.sim end
    env.alife_object = function(id) return M.sim:object(id) end

    -- Mirrors _g.script:2071-2146: the state argument selects the overload.
    env.alife_create = function(section, pos, lid, gid, id, state)
        -- _g.script:2115-2118. An undefined section logs an error and spawns nothing.
        if not env.ini_sys:section_exist(section) then
            env.callstack()
            env.printe("!ERROR: alife_create | section [%s] is invalid!", section)
            return nil
        end
        if state ~= nil then return M.sim:create(section, pos, lid, gid, id, state) end
        return M.sim:create(section, pos, lid, gid, id)
    end

    return env
end

--- opts.id_base: where ids start. A new life starts somewhere else, because the
--- mod must not be able to pass by assuming an item keeps its id between lives.
--- opts.keep_files: the state file and saves survive.
function M.reset(opts)
    opts = opts or {}
    if not opts.keep_files then M.files = {} end
    next_id = opts.id_base or 1000
    records, clients, spawn_queue = {}, {}, {}
    frame_no = 0
    M.use_after_free = {}
    M.spawn_latency_frames = 1
    M.binders_paused = false
    M.sim = nil
end

M.reset()

return M

-- Harness bootstrap. Require this first from any spec file.
--
--   local H = require("harness.init")
--   -- describe / it / beforeEach / expect are now ambient globals
--
--   describe("thing", function()
--     beforeEach(function() H.boot{ load = {"soulslike"} } end)
--     it("does the thing", function() expect(x).toBe(y) end)
--   end)

local M = {}

M.spec       = require("harness.spec")
M.class      = require("harness.class")
M.loader     = require("harness.loader")
M.dispatch   = require("harness.dispatch")
M.fakes      = require("harness.fakes")
M.builders   = require("harness.builders")
M.timeevents = require("harness.timeevents")
M.world      = require("harness.world")
M.mods       = require("harness.mods")
M.alife      = require("harness.alife")

-- describe/it/expect as ambient globals, the way a TS suite gets them.
M.spec.install(_G)

-- tests/ ... /gamedata/scripts
local function default_script_dir()
    local base = os.getenv("ROGUELITE_TESTS_DIR")
    if base and base ~= "" then
        return base .. "/../gamedata/scripts"
    end
    return "../gamedata/scripts"
end

M.booted = false

--- boot{ load = {...}, actor = {...}, soulslike_mode = true, mods = {...} }
---
--- `load` names are loaded in order (dependency order, not alphabetical).
--- `mods` are enabled BEFORE those scripts load, which matters for
--- demonized_time_events -- soulslike_scenarios captures it at file scope.
function M.boot(opts)
    opts = opts or {}

    M.fakes.reset()
    -- fakes.game_state is the WHOLE save table; the mod keeps its own state
    -- under the "soulslike" key (soulslike.script:210). opts.state seeds that
    -- sub-table, which is what a spec means by "the saved state".
    if opts.state then M.fakes.game_state.soulslike = opts.state end
    M.class.install(_G)
    M.builders.reset()
    M.builders.install(_G)
    M.dispatch.reset()
    M.dispatch.install(_G)

    M.timeevents.reset()
    M.timeevents.install(_G)

    M.world.reset()
    M.world.install(_G)

    -- Base-Anomaly scripts first (every install has them; two are called
    -- unguarded), then any third-party ones this spec asked for. Both happen
    -- before the mod scripts load, which matters for demonized_time_events --
    -- soulslike_scenarios captures it at file scope.
    M.mods.reset()
    M.mods.install_base()
    for _, name in ipairs(opts.mods or {}) do M.mods.enable(name) end
    for _, name in ipairs(opts.without or {}) do M.mods.disable(name) end

    M.builders.strict_vectors = opts.strict_vectors ~= false

    M.loader.reset()
    M.loader.init{
        script_dir = opts.script_dir or default_script_dir(),
        stock_dir  = opts.stock_dir or (default_script_dir() .. "/../../_scripts"),
        autoload   = opts.autoload,
    }
    -- Strict is applied after the mod scripts load, never during: loading them
    -- legitimately touches globals that are meant to resolve to nil.
    M.loader.strict = false

    -- Load order is dependency-driven, not alphabetical: soulslike.script
    -- constructs a TimedQueue at file scope (soulslike.script:58), so
    -- soulslike_classes must exist first. Autoload would cover it, but being
    -- explicit makes a load failure point at the right file.
    for _, name in ipairs(opts.load or {}) do
        local mod = M.loader.load(name)
        if not mod then
            error("harness: could not load mod script '" .. name .. "' from " ..
                  M.loader.script_dir, 0)
        end
    end

    if opts.actor ~= false then
        M.set_actor(opts.actor or {})
    end

    if opts.soulslike_mode then M.fakes.enable_soulslike_mode() end

    M.loader.strict = opts.strict == true

    M.booted = true
    return M
end

--- Create the actor, register it, and wire its inventory into the world model.
function M.set_actor(opts)
    local actor = M.builders.make_actor(opts or {})
    M.fakes.set_actor(actor)
    M.fakes.register_object(actor)
    M.world.attach_actor(actor, "actor")
    return actor
end

--- Record a spawn point into the save, as set_spawn does
--- (soulslike.script:207-265). Any spec reaching create_new or RespawnActor
--- needs one: without it both build a vector out of nil coordinates, which
--- strict_vectors raises on and the engine would hard-crash on.
function M.set_spawn(opts)
    local save = M.fakes.game_state
    save.soulslike = save.soulslike or {}
    save.soulslike.spawn_location = M.builders.make_spawn_location(opts)
    return save.soulslike.spawn_location
end

--- Re-boot with the same options while preserving the save table, modelling a
--- level change: every script re-executes and every module table is discarded,
--- but alife_storage_manager's state survives.
---
--- This is what makes the save/load round-trip testable -- a plain M.boot()
--- wipes game_state, so the "reload" would have nothing to restore from.
--- Persisted-var and info-portion stores are carried across for the same
--- reason; they live in the save too.
---
--- Engine globals (fakes.engine) are carried across for a different reason:
--- they are C++ statics, so a level change does not touch them.
function M.reboot(opts)
    local saved = {
        state  = M.fakes.game_state,
        vars   = M.fakes.vars,
        infos  = M.fakes.infos,
        engine = M.fakes.engine,
    }

    M.boot(opts)

    M.fakes.game_state = saved.state
    M.fakes.vars       = saved.vars
    M.fakes.infos      = saved.infos
    M.fakes.engine     = saved.engine
    return M
end

--- Advance one frame: drain deferred time events, then apply the queued
--- inventory mutations they produced. Assertions about item placement belong
--- AFTER this call -- see the deferred-mutation note in world.lua.
---
--- By default this runs to completion and raises if anything is still waiting.
--- Pass `{ passes = 1 }` to run a bounded number of frames and leave the rest
--- queued, which is how a spec observes a retrying event mid-wait.
function M.tick(opts)
    local events = M.timeevents.pump(opts)
    local ops = M.world.pump()
    return events, ops
end

--- Run the game for `ms` milliseconds, one frame at a time. Unlike tick(),
--- timed events fire only when their delay has passed, so a spec can act
--- partway through one (die halfway through an animation).
---
--- Each frame: move the clock, send actor_on_update
--- (bind_stalker_ext.script:104), run the due timed events
--- (ProcessEventQueue, run every frame through AddUniqueCall at
--- bind_stalker_ext.script:26), then apply queued inventory moves.
---
--- opts.frame_ms  frame length, default 20.
--- opts.stop      function checked after each frame; true ends the run early.
--- Returns the milliseconds actually run.
function M.run_for(ms, opts)
    opts = opts or {}
    local frame = opts.frame_ms or 20
    local ran = 0
    while ran < ms do
        M.fakes.advance_time(frame)
        ran = ran + frame
        SendScriptCallback("actor_on_update", db.actor, frame)
        M.timeevents.run_due()
        M.world.pump()
        if opts.stop and opts.stop() then break end
    end
    return ran
end

-- ------------------------------------------------------------ Ironman Roguelite
--
-- Everything above is the Soulslike harness as copied. The rest runs a game for
-- this mod on the server/client model in alife.lua.

-- Stock scripts loaded for real rather than modelled. A model of these would be
-- our own reading of them, and our reading is the thing under test: the fix
-- depends on how bind_item and alife_storage_manager share a table.
--
-- `_scripts/` is gitignored, so a checkout without it cannot run the game specs.
-- That fails loudly in loader.load_stock rather than skipping.
local STOCK = { "alife_storage_manager", "bind_item", "itms_manager" }

-- The base class of bind_item's item_binder (script_binder_object_script.cpp).
-- Every method is a no-op there too, apart from net_spawn returning true.
local function install_object_binder()
    class "object_binder"
    function object_binder:__init(obj) self.object = obj end
    function object_binder:update() end
    function object_binder:reload() end
    function object_binder:reinit() end
    function object_binder:net_spawn() return true end
    function object_binder:net_destroy() end
end

M.ALL_MODULES = { "roguelite_module_character_rep", "roguelite_module_placeables", "roguelite_module_player_corpse", "roguelite_module_stashes", "roguelite_module_trader_rep" }

-- Item configs come from system.ltx, which every boot reads again.
M.sections = {}

--- Declare a section for this life and every later one.
function M.define(section, def)
    M.sections[section] = def
    M.alife.define(section, def)
end

--- A running game: stock scripts loaded, the mod loaded, its callbacks
--- registered, the actor present.
---
--- opts.modules     which roguelite_module_* get_modules reports. Default stashes.
--- opts.keep_files  the state file and saves survive. Only new_life and reload.
--- opts.id_base     where object ids start.
function M.boot_game(opts)
    opts = opts or {}
    M.first_update_pending = false
    M.boot{ actor = false, script_dir = opts.script_dir }

    if not opts.keep_files then M.life = 0 end

    M.fakes.hardcore_mode = true
    M.alife.reset{ id_base = opts.id_base, keep_files = opts.keep_files }
    M.alife.install(_G)
    M.alife.module_names = opts.modules or { "roguelite_module_stashes" }

    if not opts.keep_files then M.sections = {} end
    for section, def in pairs(M.sections) do M.alife.define(section, def) end

    install_object_binder()
    for _, name in ipairs(STOCK) do M.loader.load_stock(name) end

    M.loader.load("roguelite_manager")
    M.loader.load("roguelite_manager_mcm")
    for _, name in ipairs(M.alife.module_names) do M.loader.load(name) end

    -- axr_main runs on_game_start for every script on load
    -- (axr_main.script:317-325). The stock alife_storage_manager's is left out:
    -- it only arranges pstor restores and the version migration, and the engine
    -- calls its save and load entry points directly
    -- (alife_storage_manager.script:161, :244).
    _G.bind_item.on_game_start()
    _G.roguelite_manager.on_game_start()
    for _, name in ipairs(M.alife.module_names) do _G[name].on_game_start() end

    local actor = M.builders.make_actor(opts.actor or { community = "actor_stalker" })
    M.fakes.set_actor(actor)
    M.alife.attach_actor(actor)

    return M
end

--- Run `n` frames (default 1). Each ends with the actor binder's update: the first one
--- after a load sends actor_on_first_update (bind_stalker.script:216-218,
--- bind_stalker_ext.script:77), and every one sends actor_on_update
--- (bind_stalker.script:310, bind_stalker_ext.script:104). The callbacks get the binder.
function M.frames(n)
    for _ = 1, n or 1 do
        M.alife.frame()
        local binder = { object = _G.db.actor }
        if M.first_update_pending then
            M.first_update_pending = false
            SendScriptCallback("actor_on_first_update", binder, 16)
        end
        SendScriptCallback("actor_on_update", binder, 16)
    end
end

--- The actor dies. roguelite_manager serializes everything to the state file.
function M.die()
    SendScriptCallback("actor_on_before_death", 0, {})
end

--- Save the game, through the entry point the engine calls.
function M.save(name)
    _G.alife_storage_manager.CALifeStorageManager_before_save((name or "quicksave") .. ".scop")
end

--- Load a save in place: every script re-executes, alife survives, client objects
--- do not, and the marshal table comes back from the file.
function M.reload(name)
    local saved = M.alife.export()
    local modules = M.alife.module_names
    -- The save holds spots added by map_add_object_spot_ser (level_script.cpp:321,
    -- map_manager.cpp:84-107). In 028ccf5 a loaded spot whose object is gone then drops
    -- on the first map update (map_location.cpp:55, :337-346, alife_storage_manager.cpp:
    -- 140, :155). GUESS for the newer build. Not modelled: the mod must not rely on it.
    local spots = M.fakes.map_spots
    M.boot_game{ keep_files = true, modules = modules }
    M.fakes.map_spots = spots
    M.alife.import(saved)
    M.alife.attach_actor(_G.db.actor)
    _G.alife_storage_manager.CALifeStorageManager_load("saves/" .. (name or "quicksave") .. ".scop")
    -- The actor's net_spawn (bind_stalker.script:58, bind_stalker_ext.script:61). GUESS: the
    -- NPC clients land on the first frame, so they exist by the first update but not here.
    SendScriptCallback("on_game_load")
    M.first_update_pending = true
    return M
end

--- The next life: a new game. Everything is gone except the state file. Ids start
--- elsewhere, and the mod's first-update hook restores from the file.
---
--- opts.before_first_update  builds the new game's world, which exists before the
--- actor's first update. An NPC made here is online or offline at the restore.
function M.new_life(opts)
    opts = opts or {}
    M.life = M.life + 1
    opts.keep_files = true
    opts.id_base = 1000 + M.life * 3000
    M.boot_game(opts)
    if opts.before_first_update then opts.before_first_update() end
    SendScriptCallback("on_game_load")
    SendScriptCallback("actor_on_first_update")
    return M
end

--- Open a stash: the physical object's use callback
--- (bind_physic_object.script:122) is what makes the mod spawn its contents.
function M.open_stash(box)
    SendScriptCallback("physic_object_on_use_callback", box, _G.db.actor)
end

return M

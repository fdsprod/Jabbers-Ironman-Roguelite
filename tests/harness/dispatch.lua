-- Callback dispatch: RegisterScriptCallback / SendScriptCallback and the
-- axr_main intercepts registry behind them.
--
-- WHY THIS IS REIMPLEMENTED RATHER THAN LOADED
--
-- _g.script loads fine standalone, but axr_main.script does load-time I/O at
-- its very top (_scripts/axr_main.script:15):
--
--     config = ini_file_ex("axr_options.ltx",true)
--     if not (config:section_exist("temp")) then
--         get_console():execute("cfg_load " .. getFS():update_path(...))
--         config:w_value("temp","rspec_default",true)
--         config:save()
--     end
--
-- Booting it requires working ini_file_ex / getFS / get_console fakes before
-- the callback system is even reachable. The dispatch core below is a
-- line-for-line transcription of axr_main.script:240-285 instead, preserving
-- the semantics that actually affect the mod:
--
--   * callback_set on a name with no prior callback_add silently no-ops.
--     The mod's on_game_start registrations vanish if names aren't pre-added.
--   * make_callback dispatches to both plain functions and to objects
--     carrying a method of the same name.
--   * SendScriptCallback additionally invokes axr_main[name] when present.
--
-- To swap in the real file later: add those three fakes and load
-- _scripts/axr_main.script through the loader instead of calling M.install().

local M = {}

local intercepts = {}

-- Recorded dispatches, for assertions. { {name=, args={...}, n=}, ... }
M.log = {}

-- --------------------------------------------------- axr_main registry core

local function callback_add(name)
    if not intercepts[name] then
        intercepts[name] = {}
    end
    -- Real impl printf/callstacks on redundant add; harmless, so we stay quiet.
end

local function callback_set(name, func_or_userdata)
    if func_or_userdata == nil then
        M.warn("callback_set: trying to set callback " .. tostring(name) .. " to nil function!")
        return
    end
    if intercepts[name] then
        intercepts[name][func_or_userdata] = true
    else
        M.warn("callback_set: callback " .. tostring(name) .. " doesn't exist!")
    end
end

local function callback_unset(name, func_or_userdata)
    if intercepts[name] then
        intercepts[name][func_or_userdata] = nil
    else
        M.warn("callback_unset: callback " .. tostring(name) .. " doesn't exist!")
    end
end

local function make_callback(name, ...)
    if intercepts[name] then
        for func_or_userdata in pairs(intercepts[name]) do
            if type(func_or_userdata) == "function" then
                func_or_userdata(...)
            elseif func_or_userdata[name] then
                func_or_userdata[name](func_or_userdata, ...)
            end
        end
    else
        M.warn("make_callback: can't make callback to non existing intercept " .. tostring(name) .. "!")
    end
end

-- Warnings are collected rather than printed so tests can assert on the
-- silent-no-op paths instead of scraping stdout.
M.warnings = {}
function M.warn(msg)
    M.warnings[#M.warnings + 1] = msg
end

-- ------------------------------------------------------ _g.script wrappers

-- Names the mod registers in soulslike.on_game_start (soulslike.script:948-965).
-- Without these pre-added, every RegisterScriptCallback there silently no-ops.
M.CALLBACK_NAMES = {
    "actor_on_stash_remove",
    "actor_on_first_update",
    "actor_on_item_take_from_box",
    "actor_on_before_death",
    "on_before_save_input",
    "save_state",
    "load_state",
    "on_level_changing",
    "on_game_load",
    "actor_on_sleep",
    "on_console_execute",
    "actor_on_before_hit",
    "physic_object_on_use_callback",
    -- Sent (not registered) by the mod:
    "squad_on_npc_creation",
    "npc_on_net_spawn",
    -- Registered by soulslike_vendetta. Both are real engine-side callbacks:
    -- squad_on_npc_death is sent from sim_squad_scripted:on_npc_death
    -- (sim_squad_scripted.script:493) and server_entity_on_unregister from
    -- se_stalker:on_unregister (se_stalker.script:116).
    "squad_on_npc_death",
    "server_entity_on_unregister",
    -- Registered by soulslike to clear a looter's marker. Declared at
    -- axr_main.script:118, sent from xr_motivator.script:396 as (victim, who).
    "npc_on_death_callback",
    -- Sent every actor update by bind_stalker_ext.script:104. Animation mods
    -- (FDDA) register on it; H.run_for sends it once per frame.
    "actor_on_update",
    -- Ironman Roguelite. roguelite_manager registers main_menu_on_init at file
    -- scope; the stash module takes actor_on_item_put_in_box, sent as (box, item)
    -- by ui_inventory.script:2172; bind_item registers the drag-drop one
    -- (bind_item.script:138).
    "main_menu_on_init",
    "actor_on_item_put_in_box",
    "ActorMenu_on_item_drag_drop",
    -- Sent as (npc) by xr_motivator.script:226, declared at axr_main.script:114.
    "npc_on_net_destroy",
}

function M.install(env)
    env = env or _G

    env.axr_main = env.axr_main or {}
    env.axr_main.callback_add   = callback_add
    env.axr_main.callback_set   = callback_set
    env.axr_main.callback_unset = callback_unset
    env.axr_main.make_callback  = make_callback

    -- _g.script:104-130
    function env.RegisterScriptCallback(name, func_or_userdata)
        env.axr_main.callback_set(name, func_or_userdata)
    end

    function env.UnregisterScriptCallback(name, func_or_userdata)
        env.axr_main.callback_unset(name, func_or_userdata)
    end

    function env.AddScriptCallback(name)
        env.axr_main.callback_add(name)
    end

    function env.SendScriptCallback(name, ...)
        M.log[#M.log + 1] = { name = name, args = { ... }, n = select("#", ...) }
        env.axr_main.make_callback(name, ...)
        if env.axr_main[name] then
            env.axr_main[name](...)
        end
    end

    for _, n in ipairs(M.CALLBACK_NAMES) do
        callback_add(n)
    end

    return env
end

-- --------------------------------------------------------------- test aids

function M.add(name) callback_add(name) end

function M.handler_count(name)
    local t = intercepts[name]
    if not t then return nil end          -- nil means "intercept doesn't exist"
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function M.exists(name) return intercepts[name] ~= nil end

function M.sends_of(name)
    local out = {}
    for _, entry in ipairs(M.log) do
        if entry.name == name then out[#out + 1] = entry end
    end
    return out
end

function M.reset()
    intercepts = {}
    M.log = {}
    M.warnings = {}
end

return M

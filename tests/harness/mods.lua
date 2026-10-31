-- Registry for the scripts the mod integrates with, whether or not they are
-- guaranteed present.
--
-- The plan called for "all eight absent by default", but checking Anomaly's
-- own _scripts/ corpus showed that is wrong for five of them. Splitting by
-- what a real install actually has:
--
--   BASE      arszi_psy, item_parts, item_radio, treasure_manager,
--             actor_status_thirst -- these ship with Anomaly, so every player
--             has them. Two are even called UNGUARDED
--             (actor_status_thirst at soulslike_scenarios.script:590,
--             treasure_manager at :1335), so "absent" is not a state the mod
--             survives. Installed by default.
--
--   OPTIONAL  magazine_binder, grok_actor_damage_balancer,
--             demonized_time_events, enhanced_animations -- genuinely
--             third-party. Absent by default, which is what most installs
--             look like.
--
-- actor_effects (BASE) and enhanced_animations (OPTIONAL) were added later,
-- for the busy hands specs. They are models of the real scripts, in
-- harness/models/, not minimal stubs.
--
-- Either group can be flipped per spec, so the guard branches stay reachable:
--
--     H.mods.disable("item_parts")     -- exercise the `if not item_parts` path
--     H.mods.enable("magazine_binder", { is_magazine = function() return true end })
--
-- treasure_manager gets special attention. RFDetectorSoulslikeScenarioLogic
-- :CreateStash monkey-patches treasure_manager.box_in_same_map and restores it
-- afterwards (soulslike_scenarios.script:1335-1341). That restore is exactly
-- the kind of thing that leaks on an early return, so the registry snapshots
-- the original and exposes M.patched() for a spec to assert against.

local M = {}

local installed = {}
local snapshots = {}

-- Default stubs. Each is deliberately minimal -- enough for the mod's calls,
-- no more. Override per spec with the second argument to enable().
local DEFAULTS = {
    magazine_binder = function()
        return {
            is_magazine       = function() return false end,
            is_carried_mag    = function() return false end,
            toggle_carried_mag= function() return true end,
            validate_loadout  = function() end,
        }
    end,

    grok_actor_damage_balancer = function()
        return { damage = nil }     -- set .damage in a spec to override hit power
    end,

    -- soulslike falls back to the global CreateTimeEvent when this is absent,
    -- so enabling it routes deferred work through the same pump either way.
    demonized_time_events = function()
        return { CreateTimeEvent = _G.CreateTimeEvent,
                 RemoveTimeEvent = _G.RemoveTimeEvent }
    end,

    arszi_psy = function()
        return { set_psy_health = function() end }
    end,

    item_parts = function()
        -- ApplyItemConditionLoss reads and writes a section->condition map for
        -- weapons (soulslike_scenarios.script:439-456).
        local store = {}
        return {
            _store = store,
            get_parts_con = function(item)
                return store[item:id()] or { barrel = 100, receiver = 100 }
            end,
            set_parts_con = function(id, parts) store[id] = parts end,
        }
    end,

    item_radio = function()
        -- Recorded, not no-ops: registering the stash with the radio is the
        -- entire point of the RF Detector scenario
        -- (soulslike_scenarios.script:1471), and clear_stash is how the entry
        -- is retired once the player recovers it.
        local recorder = require("harness.fakes").recorder
        return {
            add_stash   = recorder("item_radio.add_stash"),
            clear_stash = recorder("item_radio.clear_stash"),
        }
    end,

    treasure_manager = function()
        return {
            get_random_stash = function() return nil end,
            box_in_same_map  = function() return true end,
        }
    end,

    -- Models, not stubs: each ports the parts of a real script that lock or
    -- unlock the player's input. See harness/models/.
    actor_effects       = function() return require("harness.models.actor_effects")() end,
    enhanced_animations = function() return require("harness.models.enhanced_animations")() end,

    actor_status_thirst = function()
        return {
            get_water_deprivation = function() return 0.1 end,
            load_state            = function() end,
            actor_on_update       = function() end,
        }
    end,
}

M.NAMES = {}
for name in pairs(DEFAULTS) do M.NAMES[#M.NAMES + 1] = name end
table.sort(M.NAMES)

-- Ships with Anomaly: install unless a spec explicitly disables it.
M.BASE = {
    "actor_effects", "actor_status_thirst", "arszi_psy", "item_parts",
    "item_radio", "treasure_manager",
}

-- Third-party: absent unless a spec asks for it.
M.OPTIONAL = {
    "demonized_time_events", "enhanced_animations", "grok_actor_damage_balancer",
    "magazine_binder",
}

--- Install the base-Anomaly set. Called by H.boot before mod scripts load.
function M.install_base()
    for _, name in ipairs(M.BASE) do M.enable(name) end
end

--- Install a soft dependency. `overrides` are merged over the default stub.
function M.enable(name, overrides)
    local factory = DEFAULTS[name]
    if not factory then
        error("mods.enable: unknown soft dependency '" .. tostring(name) ..
              "'. Known: " .. table.concat(M.NAMES, ", "), 2)
    end

    local stub = factory()
    if overrides then
        for k, v in pairs(overrides) do stub[k] = v end
    end

    _G[name] = stub
    installed[name] = stub

    -- soulslike_scenarios.script:113 captures `local dte = demonized_time_events`
    -- at FILE SCOPE, so enabling it after the module loaded has no effect on
    -- that upvalue. Say so rather than letting a spec silently do nothing.
    if name == "demonized_time_events" then
        local loader = require("harness.loader")
        if loader.loaded["soulslike_scenarios"] then
            error("mods.enable(\"demonized_time_events\") must run BEFORE " ..
                  "soulslike_scenarios loads -- it captures `local dte` at file " ..
                  "scope (soulslike_scenarios.script:113)", 2)
        end
        _G.dte = stub
    end

    -- Snapshot every function so patched() can detect an unrestored monkey-patch.
    local snap = {}
    for k, v in pairs(stub) do snap[k] = v end
    snapshots[name] = snap

    return stub
end

function M.disable(name)
    -- A model that registered callbacks when it was enabled removes them here.
    local stub = installed[name]
    if stub and stub._on_disable then stub._on_disable() end
    _G[name] = nil
    if name == "demonized_time_events" then _G.dte = nil end
    installed[name] = nil
    snapshots[name] = nil
end

function M.is_enabled(name) return installed[name] ~= nil end

--- Fields whose value differs from what enable() installed -- i.e. a
--- monkey-patch that was never restored.
function M.patched(name)
    local snap, live = snapshots[name], _G[name]
    if not snap or not live then return {} end
    local out = {}
    for k, v in pairs(snap) do
        if live[k] ~= v then out[#out + 1] = k end
    end
    table.sort(out)
    return out
end

function M.reset()
    for name in pairs(installed) do
        _G[name] = nil
        if name == "demonized_time_events" then _G.dte = nil end
    end
    installed, snapshots = {}, {}
end

return M

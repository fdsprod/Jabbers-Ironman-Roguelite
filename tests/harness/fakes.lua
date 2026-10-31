-- Fake engine globals: the minimum surface the baseline tests touch.
--
-- Deliberately small. The loader resolves unknown globals to nil rather than
-- raising, so a missing fake shows up as a clear nil-index failure in the test
-- that needs it -- add it then, not speculatively.
--
-- CAVEAT: these tests validate mod logic against OUR ASSUMPTIONS about the
-- engine. A wrong constant here becomes a permanently green test. Every value
-- below that came from the engine source is cited; values that are guesses are
-- marked GUESS and should be pinned against a real game before being trusted.

local M = {}

M.calls = {}          -- recorder name -> list of arg tables

-- ------------------------------------------------------------------ helpers

local function recorder(name, ret)
    M.calls[name] = {}
    return function(...)
        local t = M.calls[name]
        t[#t + 1] = { n = select("#", ...), ... }
        return ret
    end
end
M.recorder = recorder

function M.calls_to(name) return M.calls[name] or {} end
function M.call_count(name) return #(M.calls[name] or {}) end
function M.last_call(name)
    local t = M.calls[name] or {}
    return t[#t]
end

-- ------------------------------------------------------------- clock / RNG

local now_ms = 0

function M.set_time(ms) now_ms = ms end
function M.advance_time(ms) now_ms = now_ms + ms end
function M.now() return now_ms end

-- Deterministic RNG control. The real math.random is never used in tests.
local random_impl = nil

-- Replace math.random wholesale with fn(...) -> number.
function M.set_random(fn) random_impl = fn end

-- Return values from `seq` in order. Errors past the end so an unexpected
-- extra roll is a loud failure rather than a silent reuse.
function M.set_random_sequence(seq)
    local i = 0
    random_impl = function()
        i = i + 1
        if seq[i] == nil then
            error("math.random called " .. i .. " times but only " ..
                  #seq .. " values were queued", 2)
        end
        return seq[i]
    end
end

-- Always returns v, ignoring range args. Handy for "always pick bucket 1".
function M.set_random_const(v)
    random_impl = function() return v end
end

-- Real-ish deterministic fallback: lowest legal value for the given call form.
function M.set_random_min()
    random_impl = function(a, b)
        if a == nil then return 0.0 end
        if b == nil then return 1 end
        return a
    end
end

-- Count of math.random calls since the last reset. Lets a spec assert an exact
-- RNG budget without consuming a queued value, which matters because several
-- mod functions short-circuit before rolling (IsItemLossAllowed spends 0 or 1
-- roll depending on the item category).
local random_calls = 0
function M.random_count() return random_calls end

local function fake_random(a, b)
    if not random_impl then
        error("math.random called before fakes.set_random*() -- tests must be deterministic", 2)
    end
    random_calls = random_calls + 1
    return random_impl(a, b)
end

-- ------------------------------------------------------------------ clsids
--
-- The real Is* predicates take (obj, cls) and resolve `cls or obj:clsid()`
-- against a class table (_g.script:3081 for IsWeapon). Callers do pass obj=nil
-- with an explicit clsid -- soulslike.find_closest_enemy:307 scans server
-- objects that way -- so we keep a clsid -> kind registry.
--
-- Values are opaque strings, never numbers. Engine clsids are the runtime
-- ordinal of the class in the sorted registry
-- (xray-monolith/src/xrServerEntities/object_factory_script.cpp:85), so a spec
-- that hardcoded a number would be asserting a fiction.

M.clsid_kind = {}
for _, k in ipairs{ "stalker", "monster", "anomaly", "weapon", "outfit",
                    "headgear", "artefact", "grenade", "invbox", "toolkit" } do
    M.clsid_kind["cls_" .. k] = k
end

--- The opaque clsid standing in for `kind`. Fixtures return this from
--- :clsid() so the Is* predicates classify them correctly.
function M.clsid_for(kind) return "cls_" .. tostring(kind) end

-- --------------------------------------------------------------- installer

function M.install(env)
    env = env or _G

    ---- constants ------------------------------------------------------------

    -- ALife::EHitType, xrServerEntities/alife_space.h:92. Exact values.
    env.hit = {
        burn          = 0,
        shock         = 1,
        chemical_burn = 2,
        radiation     = 3,
        telepatic     = 4,
        wound         = 5,
        fire_wound    = 6,
        strike        = 7,
        explosion     = 8,
        wound_2       = 9,
        light_burn    = 10,
    }

    env.AC_ID        = 0        -- actor id; 0 in Anomaly
    env.GAME_VERSION = "test"
    env.VEC_ZERO     = { x = 0, y = 0, z = 0 }

    -- State-machine enums passed to npc:set_mental_state / set_body_state /
    -- set_movement_type / set_sight by TrackAmbusher. Only identity matters --
    -- specs assert which constant was handed over, never its numeric value.
    env.anim = { look_around = 1, danger = 2, free = 3 }
    env.move = { standing = 1, stand = 2, walk = 3, run = 4, crouch = 5 }
    env.look = { search = 1, danger = 2, path_dir = 3 }

    ---- clock / rng ----------------------------------------------------------

    env.time_global = function() return now_ms end
    math.random = fake_random           -- shared global table, as in-engine

    ---- string ---------------------------------------------------------------

    env.strformat = string.format

    ---- level ----------------------------------------------------------------

    -- Object registry backing level.object_by_id. Populate via M.register_object.
    M.objects = {}

    -- One clock, three doors into it.
    --
    -- level.get_time_hours, level.change_game_time and game.get_game_time are
    -- the same clock in the engine: change_game_time calls
    -- CLevel::ChangeGameTime, which shifts the alife time that every other
    -- reader sees. Modelling them as three independent values is the exact
    -- "wrong fake" this suite is built to avoid -- a spec could advance time one
    -- way and read it back another, stay green, and describe a game that does
    -- not exist. So all three read and write M.game_seconds.
    --
    -- change_game_time still records its arguments, because specs assert on the
    -- delta the mod asked for as well as on where the clock ended up.
    local change_game_time = recorder("level.change_game_time")

    -- The map manager's spot list. Each entry is { id, type, hint }.
    --
    -- Two facts from the engine make this a list and not a set. Both are
    -- counter-intuitive, and both decide whether a marker can outlive its
    -- object (xray-monolith c57fe5b):
    --
    --   * AddMapLocation always appends. It never looks for an existing spot
    --     of the same type on the same id (map_manager.cpp:125-140). Adding
    --     twice gives two entries.
    --   * RemoveMapLocation erases the first match only (map_manager.cpp:
    --     176-188). One remove after two adds leaves one entry.
    --
    -- Releasing the object does not remove its spots either. The only caller
    -- of OnObjectDestroyNotify is the multiplayer CTeamBaseZone
    -- (team_base_zone.cpp, net_Destroy). A spot keeps the server object
    -- pointer it read at construction (map_location.cpp:55) and stays actual
    -- while that pointer is set (map_location.cpp:367). So alife_release does
    -- not touch M.map_spots, by design.
    M.map_spots = {}

    local record_add = recorder("level.map_add_object_spot_ser")
    local record_remove = recorder("level.map_remove_object_spot")

    --- The spots on `id`, optionally of one type, in the order they were added.
    function M.spots_on(id, spot_type)
        local out = {}
        for _, s in ipairs(M.map_spots) do
            if s.id == id and (spot_type == nil or s.type == spot_type) then
                out[#out + 1] = s
            end
        end
        return out
    end

    env.level = {
        name              = function() return M.level_name end,
        object_by_id      = function(id) return M.objects[id] end,
        get_time_hours    = function() return math.floor((M.game_seconds % 86400) / 3600) end,
        get_time_minutes  = function() return math.floor((M.game_seconds % 3600) / 60) end,
        change_game_time  = function(days, hours, minutes)
            change_game_time(days, hours, minutes)
            M.game_seconds = M.game_seconds
                + (days or 0) * 86400
                + (hours or 0) * 3600
                + (minutes or 0) * 60
        end,
        -- Both write g_bDisableAllInput (level_script.cpp:697-713), another
        -- C++ global that a level change does not reset.
        disable_input          = function() M.engine.input_disabled = true end,
        enable_input           = function() M.engine.input_disabled = false end,
        add_cam_effector       = recorder("level.add_cam_effector"),
        add_pp_effector        = recorder("level.add_pp_effector"),
        -- level_script.cpp:445-452 and :461-464, over the list above.
        map_add_object_spot_ser = function(id, spot_type, hint)
            record_add(id, spot_type, hint)
            M.map_spots[#M.map_spots + 1] = { id = id, type = spot_type, hint = hint }
        end,
        map_remove_object_spot = function(id, spot_type)
            record_remove(id, spot_type)
            for i, s in ipairs(M.map_spots) do
                if s.id == id and s.type == spot_type then
                    table.remove(M.map_spots, i)
                    return
                end
            end
        end,
        -- level_script.cpp:570-573. Returns u16, so 1 or 0, not a boolean.
        map_has_object_spot = function(id, spot_type)
            return #M.spots_on(id, spot_type) > 0 and 1 or 0
        end,
    }
    M.level_name   = "zaton"

    ---- game -----------------------------------------------------------------

    -- Identity translation keeps message assertions readable: an assertion
    -- reads as the string id, not a localized sentence.
    -- Game clock.
    --
    -- CTime is opaque in the engine; scripts only ever construct it, read it
    -- field-by-field with get(), set() it back, and subtract two of them with
    -- diffSec (utils_data.script:288-300 does exactly this round trip). So the
    -- fake carries absolute seconds and decomposes on demand.
    --
    -- GUESS, and a deliberate simplification: the calendar is a fixed
    -- 2012-05-12 epoch with day/hour/minute/second carried and Y/M pinned. A
    -- to_table -> from_table round trip is therefore lossless only inside one
    -- month. Nothing in the mod compares times more than a few game days apart
    -- (the vendetta hunt window caps at 72 game hours), so this holds. A spec
    -- that needs to cross a month boundary needs a better clock, not a longer
    -- delay.
    -- The single clock. 12:30 is the old level-time default; the previous
    -- game.get_game_time stub said 14:00, and nothing compared the two, which is
    -- how they drifted apart in the first place.
    M.game_seconds = 12 * 3600 + 30 * 60

    --- Set the wall clock, keeping the day. Specs that care about the hour use
    --- this instead of poking a field, so there is one way in.
    function M.set_game_time(hour, minute)
        local day = math.floor(M.game_seconds / 86400)
        M.game_seconds = day * 86400 + (hour or 0) * 3600 + (minute or 0) * 60
    end

    local function make_ctime(seconds)
        local ct = { _seconds = seconds or 0 }

        function ct:get(Y, M_, D, h, m, s, ms)
            local total = self._seconds
            local day = math.floor(total / 86400)
            local rem = total - day * 86400
            return 2012, 5, 12 + day,
                   math.floor(rem / 3600),
                   math.floor((rem % 3600) / 60),
                   math.floor(rem % 60),
                   0
        end

        function ct:set(Y, M_, D, h, m, s, ms)
            self._seconds = (D - 12) * 86400 + h * 3600 + m * 60 + s
        end

        function ct:diffSec(other)
            return self._seconds - (other and other._seconds or 0)
        end

        return ct
    end

    M.make_ctime = make_ctime

    --- Move the game clock forward. Specs use this to age a hunt past its
    --- window without waiting.
    function M.advance_game_seconds(seconds)
        M.game_seconds = M.game_seconds + seconds
    end

    -- Input locks that animation mods (FDDA, actor_effects, and others) set
    -- while a HUD animation plays. Both flags are plain C++ globals
    -- (level_script.cpp:72-73, 1689-1702). Nothing in the engine resets them,
    -- so they outlive a level change: H.reboot carries M.engine across.
    -- g_block_all_except_movement drops every key but movement, fire, drop,
    -- pause and a few others (Level_input.cpp:194-198).
    local stop_hud_motion   = recorder("game.stop_hud_motion")
    local stop_all_hud_anms = recorder("game.stop_all_hud_anms")

    env.game = {
        translate_string = function(s) return s end,
        get_game_time    = function() return make_ctime(M.game_seconds) end,
        CTime            = function() return make_ctime(0) end,

        only_allow_movekeys    = function(b) M.engine.only_movekeys = b and true or false end,
        only_movekeys_allowed  = function() return M.engine.only_movekeys end,
        set_actor_allow_ladder = function(b) M.engine.allow_ladder = b and true or false end,
        -- StopHudMotion stops the scripted HUD motion (level_script.cpp:1642).
        stop_hud_motion        = stop_hud_motion,
        -- StopAllBlendAnms takes a bool bForce (level_script.cpp:1679-1682).
        -- Stock actor_effects calls it with no argument on every load
        -- (actor_effects.script:1856), so the engine accepts that. What a
        -- missing bool reads as is a GUESS. The mod passes true explicitly.
        stop_all_hud_anms      = function(...)
            stop_all_hud_anms(...)
        end,
    }

    ---- db -------------------------------------------------------------------

    env.db = {
        actor          = nil,      -- set per-test via M.set_actor
        storage        = {},
        OnlineStalkers = {},
    }

    ---- predicates -----------------------------------------------------------
    --
    -- Objects built by builders.lua carry a `_kind` tag; these read it.
    --
    -- The real predicates take (obj, cls) and resolve `cls or obj:clsid()`
    -- against a class table (_g.script:3081 for IsWeapon). The clsid argument
    -- wins when both are given, and callers do pass obj=nil with an explicit
    -- clsid -- soulslike.find_closest_enemy:307 scans server objects that way.
    -- So we keep a clsid -> kind registry and dispatch on it first; a nil obj
    -- with no clsid is false.
    --
    -- The registry itself lives at module scope (see M.clsid_for) so fixtures
    -- can reach it before install() has run.
    local function kind_is(k)
        return function(obj, cls)
            if cls ~= nil then return M.clsid_kind[cls] == k end
            if obj == nil then return false end
            return obj._kind == k
        end
    end

    env.IsStalker  = kind_is("stalker")
    env.IsMonster  = kind_is("monster")
    env.IsAnomaly  = kind_is("anomaly")
    -- Grenades are NOT weapons at either layer: CGrenade derives from CMissile,
    -- not CWeapon (xray-monolith/src/xrGame/Grenade.h:6), and Anomaly's Lua
    -- weapon_classes table contains no grenade clsids (_g.script:3081-3149).
    -- The mod's `IsWeapon(item) and not is_grenade` idiom is therefore
    -- redundant, not load-bearing -- do not "fix" this by making the two
    -- predicates overlap.
    env.IsWeapon   = kind_is("weapon")
    env.IsOutfit   = kind_is("outfit")
    env.IsHeadgear = kind_is("headgear")
    env.IsArtefact = kind_is("artefact")
    env.IsGrenade  = kind_is("grenade")
    env.IsInvbox   = kind_is("invbox")
    env.IsToolkit  = function(o, s) return (o and o._kind == "toolkit") or false end

    -- SYS_GetParam(type, section, param) -> ltx lookup. Backed by M.ltx.
    M.ltx = {}
    env.SYS_GetParam = function(_, section, param)
        local sec = M.ltx[section]
        return sec and sec[param] or nil
    end

    ---- module stubs ---------------------------------------------------------

    -- CTime_to_table / CTime_from_table are utils_data.script:288-298. They are
    -- a plain field-by-field round trip through game.CTime, so the fakes mirror
    -- that shape rather than modelling calendar arithmetic.
    env.utils_data = {
        debug_write = recorder("debug_write"),
        CTime_to_table = function(ct)
            local Y, M, D, h, m, s, ms = 0, 0, 0, 0, 0, 0, 0
            Y, M, D, h, m, s, ms = ct:get(Y, M, D, h, m, s, ms)
            return { Y = Y, M = M, D = D, h = h, m = m, s = s, ms = ms }
        end,
        CTime_from_table = function(t)
            local ct = env.game.CTime()
            ct:set(t.Y, t.M, t.D, t.h, t.m, t.s, t.ms)
            return ct
        end,
    }

    env.news_manager = {
        send_tip   = recorder("send_tip"),
        tips_icons = setmetatable({}, { __index = function() return "icon" end }),
    }

    env.actor_menu    = { set_msg = recorder("set_msg") }
    env.exec_console_cmd = recorder("exec_console_cmd")

    env.utils_xml = {
        get_color       = function(c) return "%c[" .. tostring(c) .. "]" end,
        get_special_txt = function(s) return tostring(s) end,
        is_widescreen   = function() return false end,
    }

    -- Single most valuable fake: every one of soulslike_mcm's 60+ getters
    -- funnels through ui_mcm.get (soulslike_mcm.script:939), so faking this one
    -- function makes the real 1215-line MCM module work. Returning nil for a
    -- key exercises that getter's declared default.
    M.mcm = {}
    env.ui_mcm = {
        get = function(path) return M.mcm[path] end,
    }

    -- Backs soulslike.get_soulslike_state().
    M.game_state = {}
    env.alife_storage_manager = {
        get_state = function() return M.game_state end,
        decode    = function(_) return nil end,
    }

    env.alife = function() return M.sim end
    M.sim = nil

    ---- persistence ----------------------------------------------------------

    -- Real storage, not no-ops: HealActor writes grw_in_water
    -- (soulslike_scenarios.script:376) and create_new reads it
    -- (soulslike_scenario_logic_factory.script:343), so the round-trip has to
    -- work or that branch is untestable.
    M.vars = {}
    env.save_var = function(obj, key, value)
        local id = obj and (type(obj.id) == "function" and obj:id() or obj.id) or "_"
        M.vars[id] = M.vars[id] or {}
        M.vars[id][key] = value
    end
    env.load_var = function(obj, key, default)
        local id = obj and (type(obj.id) == "function" and obj:id() or obj.id) or "_"
        local t = M.vars[id]
        local v = t and t[key]
        if v == nil then return default end
        return v
    end

    ---- info portions / story ------------------------------------------------

    M.infos = {}          -- info_id -> true
    M.story_ids = {}      -- object id -> story id

    env.has_alife_info    = function(id) return M.infos[id] == true end
    env.disable_info      = function(id) M.infos[id] = nil end
    env.give_info_portion = function(id) M.infos[id] = true end
    env.get_object_story_id = function(id) return M.story_ids[id] end

    ---- misc engine globals --------------------------------------------------

    env.printf     = function() end
    env.normalize  = function(v, lo, hi)
        if hi == lo then return 0 end
        return (v - lo) / (hi - lo)
    end
    env.bit_or     = function(a, b) return a + b end   -- flag combining only
    env.hide_hud_inventory = recorder("hide_hud_inventory")
    env.get_console_cmd    = function(_, name) return M.console[name] end
    M.console = { snd_volume_music = 1, snd_volume_eff = 1 }

    env.ChangeLevel = recorder("ChangeLevel")

    env.device = function()
        return {
            is_paused = function() return M.paused end,
            pause     = function(_, v) M.paused = v end,
        }
    end
    M.paused = false

    -- game_graph():vertex(id):level_id()
    env.game_graph = function()
        return {
            vertex = function(_, gvid)
                return { level_id = function() return M.gvid_level[gvid] or 1 end }
            end,
        }
    end
    M.gvid_level = {}

    -- system.ltx reader. Backed by the same M.ltx table SYS_GetParam uses.
    env.ini_sys = {
        r_string_ex = function(_, section, key, default)
            local sec = M.ltx[section]
            local v = sec and sec[key]
            if v == nil then return default end
            return v
        end,
        r_bool_ex = function(_, section, key, default)
            local sec = M.ltx[section]
            local v = sec and sec[key]
            if v == nil then return default end
            return v == true or v == "true" or v == 1
        end,
    }

    env.SIMBOARD = { setup_squad_and_group = recorder("setup_squad_and_group") }

    ---- file system ----------------------------------------------------------
    --
    -- Only what on_console_execute's save-pruning walk touches
    -- (soulslike.script:652-695). M.saves maps a bare file name to its decoded
    -- save table, so a spec can stage siblings with matching/mismatching uuids.

    -- The walk does a real io.open on each .scoc before decoding it, so without
    -- a shim the loop body never executes and the whole path is untestable.
    -- install_save_fs() below supplies one.
    M.saves = {}
    env.FS = { FS_ListFiles = 1, FS_RootOnly = 2 }
    env.getFS = function()
        return {
            update_path = function(_, _, tail) return "saves/" .. tostring(tail) end,
            file_copy   = recorder("fs.file_copy"),
            file_list_open_ex = function()
                local names = {}
                for name in pairs(M.saves) do names[#names + 1] = name end
                table.sort(names)
                return {
                    Size  = function() return #names end,
                    GetAt = function(_, i)
                        local n = names[i + 1]
                        return { NameFull = function() return n .. ".scoc" end }
                    end,
                }
            end,
        }
    end

    ---- module stubs (engine-side scripts the mod calls into) ----------------

    -- Recorded, and with the two side effects that matter to input locks.
    -- disable_ui stores the active slot, empties the hands and disables input
    -- (xr_effects.script:1600-1621). enable_ui gives the stored slot back and
    -- enables input (:1717-1732). ui_active_slot is a module local, so a level
    -- change (which re-executes xr_effects) forgets it.
    local ui_active_slot = 0
    local record_enable  = recorder("xr_effects.enable_ui")
    local record_disable = recorder("xr_effects.disable_ui")
    env.xr_effects = {
        disable_ui = function(...)
            record_disable(...)
            local actor = env.db.actor
            if actor and actor.active_slot then
                local slot = actor:active_slot()
                if slot ~= 0 then
                    ui_active_slot = slot
                    actor:activate_slot(0)
                end
            end
            env.level.disable_input()
        end,
        enable_ui = function(...)
            record_enable(...)
            local actor = env.db.actor
            if actor and actor.activate_slot and ui_active_slot ~= 0
               and actor:item_in_slot(ui_active_slot) ~= nil then
                actor:activate_slot(ui_active_slot)
            end
            ui_active_slot = 0
            env.level.enable_input()
        end,
    }

    env.bind_stalker_ext = { invulnerable_time = 0 }

    env.level_weathers = { valid_levels = { zaton = true, jupiter = true,
                                            pripyat = true, escape = true } }

    env.actor_status = {
        activate_hud   = recorder("actor_status.activate_hud"),
        deactivate_hud = recorder("actor_status.deactivate_hud"),
    }

    env.game_statistics = {
        increment_statistic        = recorder("increment_statistic"),
        get_statistic_count        = function() return M.stats_count end,
        check_for_rank_change      = recorder("check_for_rank_change"),
        check_for_reputation_change= recorder("check_for_reputation_change"),
    }
    M.stats_count = 1

    -- utils_item.degrade RELEASES the item when its condition reaches 0.
    -- ApplyItemConditionLoss depends on that: it is how story.items_were_lost
    -- gets set for gear degraded into nothing (soulslike_scenarios.script:460).
    -- Returning a number without destroying anything would make that branch
    -- untestable.
    env.utils_item = {
        is_degradable = function(item, sec)
            local t = M.ltx[sec or (item and item:section())]
            if t and t.degradable ~= nil then return t.degradable end
            return true
        end,
        degrade = function(item, percent)
            local cond = item:condition() * (1 - (percent or 0))
            if cond < 0.005 then cond = 0 end
            item._condition = cond
            if cond == 0 and _G.alife_release then _G.alife_release(item) end
            return cond
        end,
    }

    env.ui_item        = { get_sec_name = function(s) return s end }
    env.ui_load_dialog = { delete_save_game = recorder("delete_save_game") }
    env.utils_obj      = { graph_distance = function() return M.graph_distance end }
    M.graph_distance   = 500
    env.utils_stpk     = {
        get_item_data = function() return {} end,
        set_item_data = recorder("set_item_data"),
    }
    env.simulation_objects = { is_on_the_same_level = function() return true end }
    env.surge_manager      = { stop_surge = recorder("stop_surge") }
    env.psi_storm_manager  = {
        get_psi_storm_manager = function()
            return { started = M.psi_storm_started, finish = recorder("psi_storm.finish") }
        end,
    }
    M.psi_storm_started = false

    env.IsHardcoreMode = function() return M.hardcore_mode end
    M.hardcore_mode = false
    -- IsItem(kind, section) -- used by soulslike_note to test for "letter"
    env.IsItem = function(kind, section, obj)
        local sec = section or (obj and obj:section())
        local t = M.ltx[sec]
        return (t and t.kind) == kind
    end

    -- axr_main.config: IsSoulslikeMode reads new_game_soulslike_mode from it
    -- (soulslike.script:193). axr_main itself is created by dispatch.install,
    -- so extend rather than replace.
    env.axr_main = env.axr_main or {}
    M.config = {}
    env.axr_main.config = {
        r_value = function(_, sec, key, _, default)
            local t = M.config[sec]
            local v = t and t[key]
            if v == nil then return default end
            return v
        end,
        w_value = function(_, sec, key, value)
            M.config[sec] = M.config[sec] or {}
            M.config[sec][key] = value
        end,
        save = recorder("axr_main.config.save"),
        section_exist = function(_, sec) return M.config[sec] ~= nil end,
    }

    return env
end

-- ------------------------------------------------------------ per-test setup

function M.set_actor(actor) _G.db.actor = actor end

function M.register_object(obj)
    assert(obj and obj.id, "register_object needs an object with an id() or id field")
    local id = type(obj.id) == "function" and obj:id() or obj.id
    M.objects[id] = obj
    return obj
end

-- Set an MCM value as ui_mcm.get would return it. Key omits the "soulslike/"
-- prefix that get_config prepends.
function M.set_mcm(key, value) M.mcm["soulslike/" .. key] = value end

function M.set_ltx(section, params) M.ltx[section] = params end

function M.set_info(id, on) M.infos[id] = on and true or nil end
function M.set_config(section, key, value)
    M.config[section] = M.config[section] or {}
    M.config[section][key] = value
end

--- The level name level.name() reports. Drives create_new's indoor branch,
--- which keys off level_weathers.valid_levels.
function M.set_level(name) M.level_name = name end

-- ------------------------------------------------------------- save files
--
-- on_console_execute's pruning walk (soulslike.script:658-695) reads each
-- sibling save off disk with io.open before handing the bytes to
-- alife_storage_manager.decode. Both have to work or the loop body is dead.
--
-- The "bytes" are an opaque token rather than a real serialization: the mod
-- only ever round-trips them straight back through decode, so modelling the
-- save format would be effort spent asserting our own encoder.

local real_io_open = io.open
local save_fs_installed = false

local function save_name_from_path(path)
    return tostring(path):match("^saves/([^/]+)%.scoc$")
end

--- Stage a sibling save. `decoded` is the table decode() will return, e.g.
--- { soulslike = { uuid = "..." } }. Pass nil to model an unreadable file.
function M.set_save(name, decoded)
    M.saves[name] = decoded or false
end

--- Route saves/<name>.scoc through M.saves; everything else falls through to
--- the real io.open, which the module loader still needs (loader.lua:83).
function M.install_save_fs()
    if save_fs_installed then return end
    save_fs_installed = true

    io.open = function(path, mode, ...)
        local name = save_name_from_path(path)
        if name == nil then return real_io_open(path, mode, ...) end

        local decoded = M.saves[name]
        if decoded == nil or decoded == false then return nil end

        local closed = false
        return {
            read  = function() return "SAVEBLOB:" .. name end,
            close = function() closed = true end,
            _closed = function() return closed end,
        }
    end

    _G.alife_storage_manager.decode = function(blob)
        local name = tostring(blob):match("^SAVEBLOB:(.+)$")
        local decoded = name and M.saves[name]
        if decoded == false then return nil end
        return decoded
    end
end

local function uninstall_save_fs()
    if not save_fs_installed then return end
    io.open = real_io_open
    save_fs_installed = false
end

--- Populate db.OnlineStalkers (and db.storage, which is consulted first).
--- These are the only inputs to find_closest_enemy_stalker /
--- find_closest_friendly_stalker (soulslike.script:370, :395).
function M.set_online_stalkers(list)
    _G.db.OnlineStalkers = {}
    for _, npc in ipairs(list or {}) do
        local id = type(npc.id) == "function" and npc:id() or npc.id
        _G.db.OnlineStalkers[#_G.db.OnlineStalkers + 1] = id
        _G.db.storage[id] = { object = npc }
        M.register_object(npc)
    end
end

-- Enable soulslike mode the way the mod actually detects it
-- (soulslike.script:192): either the character-creation config flag or the
-- persisted save flag. Nearly every handler early-returns without this.
function M.enable_soulslike_mode()
    M.set_config("character_creation", "new_game_soulslike_mode", true)
end

function M.reset()
    uninstall_save_fs()
    M.calls = {}
    M.objects = {}
    M.ltx = {}
    M.mcm = {}
    M.game_state = {}
    M.sim = nil
    M.vars = {}
    M.infos = {}
    M.story_ids = {}
    M.saves = {}
    M.config = {}
    M.gvid_level = {}
    M.paused = false
    M.hardcore_mode = false
    M.psi_storm_started = false
    M.stats_count = 1
    M.graph_distance = 500
    -- Engine globals the game.* input locks write (see env.game). A fresh
    -- process starts with these values: g_block_all_except_movement is a
    -- zero-initialised static, g_actor_allow_ladder starts true
    -- (level_script.cpp:72-73).
    -- input_disabled is g_bDisableAllInput, the flag level.disable_input sets
    -- (level_script.cpp:697-713).
    M.engine = { only_movekeys = false, allow_ladder = true, input_disabled = false }
    now_ms = 0
    random_impl = nil
    random_calls = 0
    M.install(_G)
end

return M

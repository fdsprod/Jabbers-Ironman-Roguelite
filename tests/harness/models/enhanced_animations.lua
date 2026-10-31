-- Model of FDDA's enhanced_animations.script: the item-use animation that
-- locks the player's hands while it plays.
--
-- Source: the copy that wins in the G.A.M.M.A. load order, from the mod
-- "Teivaz's Gunslinger Exo Animations Port". Line numbers below are that file.
-- Every copy in the modlist shares this lock and unlock chain.
--
-- Kept: every line that touches input, slots, the weapon block, or the timed
-- event queue. Dropped, because none of them lock or unlock anything: sounds,
-- camera effectors, HUD motions, FOV, the mask switcher, cigarette smoke, the
-- exo section swap, the ea_callbacks events, the mutant-skinning path, and the
-- items_anm_dummy spawn (eating it is a no-op either way, see builders.lua).
--
-- The chain for one item use:
--
--   use_item -> anim_prepare              lock movekeys, restore_weapon (the
--                                          u8 block wraps 0 -> 255: blocked),
--                                          empty the hands, wait for slot 0
--   actor_on_update (hands empty)         start the animation, queue:
--     ea_object_eater    at 0.367 * tm    eat the item
--     ea_anim_stoper     at tm            hide_weapon (255 -> 0: unblocked),
--                                          enable_input
--     ea_slot_returner   at tm + 0.1 s    unlock movekeys, give the slot back
--
-- A fresh table per boot: a level change re-executes the script, so its
-- module state starts over.

return function()
    local M = {}

    -- Animation lengths in ms, from anims_list.ltx (the copy that wins is in
    -- "Asnen's and Grok's Better Cigarettes Animations"): [medkit] tm = 6950,
    -- [bandage] tm = 3700.
    M.TM = { medkit = 6950, bandage = 3700 }

    local active_slot, used_item, obj_m, anim_section
    local anim_exist_tm, anim_use_time
    local failure_timer = 0

    -- :270-278
    function M.call_my_slot_back()
        game.only_allow_movekeys(false)
        db.actor:activate_slot(active_slot or 0)
        return true
    end

    -- :304-310
    function M.eat_my_obj()
        if obj_m then
            db.actor:eat(obj_m)
        end
        db.actor:eat(db.actor:object("items_anm_dummy"))
        return true
    end

    -- :352-356, minus fov_anim_manager.restore_fov
    local function ea_restore_actor()
        db.actor:hide_weapon()
        level.enable_input()
    end

    -- :312-319, minus the ea_callbacks event and mask_hud_switcher
    function M.stop_my_item_anim()
        ea_restore_actor()
        used_item = nil
        obj_m = nil
        return true
    end

    -- :142-157, only the three timed events
    local function anim_manager_item()
        local tmr = M.TM[used_item]
        anim_exist_tm = tmr * 0.001
        anim_use_time = anim_exist_tm * 0.367
        CreateTimeEvent("ea_object_eater", "eat_my_obj", anim_use_time, M.eat_my_obj)
        CreateTimeEvent("ea_slot_returner", "call_my_slot_back", (anim_exist_tm + 0.1), M.call_my_slot_back)
        CreateTimeEvent("ea_anim_stoper", "stop_my_item_anim", anim_exist_tm, M.stop_my_item_anim)
    end

    -- :176-203. The debug-only failure branch (:181-189) is left out: it runs
    -- only when ea_debug is on.
    function M.actor_on_update(_, delta)
        -- :177 adds device().time_delta / 17 per update. delta is the frame
        -- time bind_stalker_ext sends with actor_on_update.
        failure_timer = failure_timer + ((delta or 17) / 17)
        if (db.actor:active_slot() ~= 0 or db.actor:active_detector()) and (failure_timer < 100) then
            return
        end
        failure_timer = 0
        anim_section = nil
        -- start_anim (:129-140) unregisters this callback first.
        UnregisterScriptCallback("actor_on_update", M.actor_on_update)
        anim_manager_item()
    end

    -- :81-89, minus hide_det (the model actor has no detector)
    function M.anim_prepare()
        game.only_allow_movekeys(true)
        active_slot = db.actor:active_slot()
        anim_exist_tm = nil
        db.actor:restore_weapon()
        db.actor:activate_slot(0)
        RegisterScriptCallback("actor_on_update", M.actor_on_update)
    end

    -- :91-109, minus the exo swap, hide_hud_inventory and mask_hud_switcher.
    -- In game this runs from the itms_manager.actor_on_item_before_use
    -- monkey-patch (:228-259) when the player uses an item that has an
    -- animation. A spec calls it directly.
    function M.use_item(obj)
        used_item = obj:section()
        obj_m = obj
        anim_section = used_item
        M.anim_prepare()
    end

    return M
end

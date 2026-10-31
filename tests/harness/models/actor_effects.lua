-- Model of stock Anomaly actor_effects.script: only its reset of the
-- animation input locks on the first actor update after a load.
--
-- Stock actor_effects.script:1830-1857 (actor_on_first_update) calls:
--
--   game.only_allow_movekeys(false)
--   game.set_actor_allow_ladder(true)
--   game.stop_all_hud_anms()
--   game.stop_hud_motion()
--
-- The G.A.M.M.A. 3D PDA copy does the same at :1849-1876. It ships with
-- Anomaly, so it is a BASE mod in harness/mods.lua. Everything else in the
-- script (item-use effects, masks, the torch animation) is left out.

return function()
    local M = {}

    function M.actor_on_first_update()
        game.only_allow_movekeys(false)
        game.set_actor_allow_ladder(true)
        game.stop_all_hud_anms()
        game.stop_hud_motion()
    end

    -- actor_effects registers this in on_game_start (:1909 in the 3D PDA
    -- copy). The harness installs base mods at boot, before any spec sends a
    -- callback, which is the same order.
    RegisterScriptCallback("actor_on_first_update", M.actor_on_first_update)

    -- Called by mods.disable. Without it, disabling the model would remove the
    -- global and leave the callback registered, so the reset would still run.
    function M._on_disable()
        UnregisterScriptCallback("actor_on_first_update", M.actor_on_first_update)
    end

    return M
end

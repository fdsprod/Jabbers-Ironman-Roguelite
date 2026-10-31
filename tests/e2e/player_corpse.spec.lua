-- The corpse the player finds in the next life, holding what they died with.

local H = require("harness.init")

describe("the player corpse", function()
    local model
    local MODULES = { "roguelite_module_player_corpse" }

    -- The corpse online, as it is when the player or an NPC reaches it.
    local function reach_corpse()
        local se = model.all_stashes("stalker_azazel")[1]
        model.set_online(se.id, true)
        H.frames(1)
        return level.object_by_id(se.id)
    end

    -- motivator_binder:use_callback, the player opening the body
    -- (xr_motivator.script:410-413). The guard is stock.
    local function player_opens(corpse)
        if not se_load_var(corpse:id(), corpse:name(), "death_dropped") then
            death_manager.create_release_item(corpse)
        end
        H.frames(3)
    end

    -- An NPC searching the body. No guard on this path
    -- (xr_corpse_detection.script:504).
    local function npc_searches(corpse)
        death_manager.create_release_item(corpse)
        H.frames(3)
    end

    local function sections_on(id)
        local out = {}
        for _, se in ipairs(model.contents(id)) do
            if se.section ~= "sl_ht_walkie_talkie" then out[#out + 1] = se.section end
        end
        table.sort(out)
        return out
    end

    -- The roll restore makes for each item, with the top or bottom of its range.
    local function pin_roll(pick)
        H.fakes.set_random(function(a, b) return pick(a, b) end)
    end

    beforeEach(function()
        H.boot_game{ modules = MODULES }
        model = H.alife
        H.define("stalker_azazel", { kind = "stalker" })
        H.define("sl_ht_walkie_talkie", {})
        H.define("vodka", { max_uses = 3 })
        H.define("wpn_ak74", { kind = "weapon" })
        H.define("medkit", {})
    end)

    describe("given a player who died carrying gear", function()
        -- A new life wipes the settings and the pinned roll, so they go on after it.
        beforeEach(function()
            model.give(db.actor, "vodka", { uses = 1 })
            local rifle = model.give(db.actor, "wpn_ak74")
            rifle:set_condition(0.5)
            H.frames(1)
            H.die()
            H.new_life{ modules = MODULES }
            pin_roll(function(a) return a end)
            model.set_mcm("drop_player_inventory_item_loss_max_ingame_time_enabled", false)
            model.set_mcm("drop_player_inventory_item_loss_chance", 0)
        end)

        it("gives the gear back when the body is opened", function()
            local corpse = reach_corpse()
            player_opens(corpse)
            expect(sections_on(corpse:id())).toEqual({ "vodka", "wpn_ak74" })
        end)

        it("keeps the uses and condition", function()
            local corpse = reach_corpse()
            player_opens(corpse)
            expect(model.uses_in_box(corpse:id(), "vodka")).toEqual({ 1 })
            local rifle
            for _, se in ipairs(model.contents(corpse:id())) do
                if se.section == "wpn_ak74" then rifle = level.object_by_id(se.id) end
            end
            expect(rifle:condition()).toBe(0.5)
        end)

        -- FIXES: create_release_item is reached again after the restore, because the
        -- hook never set death_dropped. The second pass ran the stock keep_item over
        -- the restored gear, which rerolls condition and releases ammo and grenades
        -- (death_manager.script:437-466).
        describe("when it is reached a second time", function()
            local corpse

            beforeEach(function()
                corpse = reach_corpse()
                player_opens(corpse)
            end)

            it("leaves the gear alone when the player opens it again", function()
                player_opens(corpse)
                expect(sections_on(corpse:id())).toEqual({ "vodka", "wpn_ak74" })
            end)

            it("leaves the gear alone when an NPC searches it", function()
                npc_searches(corpse)
                expect(sections_on(corpse:id())).toEqual({ "vodka", "wpn_ak74" })
            end)

            -- Restoring twice would give the same list back, with the gear rebuilt and
            -- every item rolled for loss again. So this checks identity, not sections.
            it("does not rebuild the gear when an NPC searches it", function()
                local function ids()
                    local out = {}
                    for _, se in ipairs(model.contents(corpse:id())) do out[#out + 1] = se.id end
                    return out
                end
                local before = ids()
                npc_searches(corpse)
                expect(ids()).toEqual(before)
            end)

            it("marks the body dropped, so stock does not treat it as unlooted", function()
                expect(se_load_var(corpse:id(), corpse:name(), "death_dropped")).toBe(true)
            end)
        end)
    end)

    describe("the item loss roll", function()
        -- 100 items would be slower and prove no more than one, since the roll is per item.
        local function die_and_open_after(seconds)
            model.give(db.actor, "medkit")
            H.die()
            H.new_life{ modules = MODULES }
            H.fakes.advance_game_seconds(seconds or 0)
        end

        local function open_with_roll(pick)
            pin_roll(pick)
            local corpse = reach_corpse()
            player_opens(corpse)
            return sections_on(corpse:id())
        end

        describe("given a flat chance", function()
            local function set_chance(chance)
                model.set_mcm("drop_player_inventory_item_loss_max_ingame_time_enabled", false)
                model.set_mcm("drop_player_inventory_item_loss_chance", chance)
            end

            -- FIXES: math.random(0, 100) has 101 values and the check was `roll < 100`,
            -- so a 0% chance still lost one item in 101.
            it("never loses an item at a 0% chance, on the highest roll", function()
                die_and_open_after()
                set_chance(0)
                expect(open_with_roll(function(_, b) return b end)).toEqual({ "medkit" })
            end)

            it("always loses an item at a 100% chance, on the lowest roll", function()
                die_and_open_after()
                set_chance(1)
                expect(open_with_roll(function(a) return a end)).toEqual({})
            end)
        end)

        -- The MCM tooltip's example: 25% over an hour, reached at 45 minutes, is
        -- 0.75 * 0.25 (ui_st_mcm_roguelite.xml). There is a 5 minute grace period.
        describe("given a chance that grows until a time limit", function()
            local function set_limit()
                model.set_mcm("drop_player_inventory_item_loss_max_ingame_time_enabled", true)
                model.set_mcm("drop_player_inventory_item_loss_chance", 0.25)
                model.set_mcm("drop_player_inventory_item_loss_max_ingame_time_seconds", 3600)
            end

            it("loses nothing inside the grace period, on the highest roll", function()
                die_and_open_after(200)
                set_limit()
                expect(open_with_roll(function(_, b) return b end)).toEqual({ "medkit" })
            end)

            it("keeps an item that rolls inside the kept 75% at the limit", function()
                die_and_open_after(3600)
                set_limit()
                expect(open_with_roll(function() return 75 end)).toEqual({ "medkit" })
            end)

            it("loses an item that rolls past the kept 75% at the limit", function()
                die_and_open_after(3600)
                set_limit()
                expect(open_with_roll(function() return 76 end)).toEqual({})
            end)

            -- FIXES: the fraction was not capped. Ten hours against a one hour limit is
            -- 0.25 * 10.8, a 270% chance, so every item was lost.
            it("does not pass the configured chance long after the limit", function()
                die_and_open_after(36000)
                set_limit()
                expect(open_with_roll(function() return 75 end)).toEqual({ "medkit" })
            end)
        end)
    end)

    describe("serializing the actor", function()
        -- FIXES: get_stalker_data reads the actor as if it were a stalker, and they are
        -- laid out differently (xrServer_Objects_ALife_Monsters.cpp:1504-1510 against
        -- utils_stpk.script:614-631). Its result was also never used.
        it("does not parse the actor as a stalker", function()
            H.die()
            expect(H.fakes.call_count("utils_stpk.get_stalker_data")).toBe(0)
        end)

        it("records the visual", function()
            H.die()
            H.new_life{ modules = MODULES }
            expect(roguelite_module_player_corpse).toBeDefined()
            local data = marshal.decode(io.open("appdata\\roguelite_stalker.state", "rb"):read("*all"))
            expect(data.corpse.visual).toBe("actors\\stalker_neutral\\actor")
        end)
    end)
end)

return true

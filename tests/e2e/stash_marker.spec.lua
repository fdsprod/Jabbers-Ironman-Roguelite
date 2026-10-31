-- A restored stash gets a "treasure_player" marker on the PDA. Each journey plays a
-- real death and new life, so the stash and its marker come from the mod's restore.
--
-- Releasing an object does not remove its spots (see the map spot notes in
-- harness/fakes.lua), so nothing but the mod can clear this marker.

local H = require("harness.init")

describe("stash markers", function()
    local model

    local MARKER = "treasure_player"

    local function markers_on(id)
        return #H.fakes.spots_on(id, MARKER)
    end

    -- The id of a stash that came back in a new life, not yet opened.
    local function restored_stash()
        local box = model.stash("placeable_case")
        model.give(box, "vodka", { uses = 1 })
        H.frames(2)
        H.die()
        H.new_life()
        return model.all_stashes("placeable_case")[1].id
    end

    local function open(id)
        model.set_online(id, true)
        H.frames(1)
        H.open_stash(level.object_by_id(id))
        H.frames(3)
    end

    local function opened_stash()
        local id = restored_stash()
        open(id)
        return id
    end

    -- What stock does with an emptied backpack (item_backpack.script:69-84).
    local function stock_remove(id)
        local data = { stash_id = id, cancel = false }
        SendScriptCallback("actor_on_stash_remove", data)
        if data.cancel then return end
        level.map_remove_object_spot(id, "treasure")
        alife_release(alife_object(id))
    end

    -- Another mod's code picks the stash up, with no callback at all.
    local function picked_up(id)
        alife_release(alife_object(id))
    end

    -- Sent with the actor binder (bind_stalker_ext.script:61).
    local function game_load()
        SendScriptCallback("on_game_load", { object = db.actor })
    end

    beforeEach(function()
        H.boot_game()
        model = H.alife
        H.define("vodka", { max_uses = 3 })
        H.define("placeable_case", { kind = "invbox" })
        H.define("placeable_fridge", { kind = "invbox" })
    end)

    describe("given a restored stash", function()
        it("has one marker", function()
            expect(markers_on(restored_stash())).toBe(1)
        end)

        it("keeps its marker after it is opened", function()
            expect(markers_on(opened_stash())).toBe(1)
        end)
    end)

    describe("given stock removes the stash", function()
        -- FIXES: actor_on_stash_remove was empty and stock only removes "treasure", so
        -- the marker stayed on the map.
        it("loses its marker", function()
            local id = opened_stash()
            stock_remove(id)
            expect(markers_on(id)).toBe(0)
        end)
    end)

    describe("given a stash released with no callback", function()
        -- FIXES: nothing noticed a stash that another mod picked up, so its marker stayed.
        it("loses its marker at the next game load", function()
            local id = opened_stash()
            picked_up(id)
            game_load()
            expect(markers_on(id)).toBe(0)
        end)

        -- An opened stash has no entry left in the module's stash data, and an unopened
        -- one still does. Both have to work.
        it("loses its marker at the next game load if it was never opened", function()
            local id = restored_stash()
            picked_up(id)
            game_load()
            expect(markers_on(id)).toBe(0)
        end)
    end)

    describe("given a stash that still exists", function()
        -- Offline, it has a server object and no client object.
        it("keeps its marker through a game load while offline", function()
            local id = restored_stash()
            game_load()
            expect(markers_on(id)).toBe(1)
        end)

        it("keeps its marker through a game load after it is opened", function()
            local id = opened_stash()
            game_load()
            expect(markers_on(id)).toBe(1)
        end)
    end)

    describe("given actor_on_stash_remove for a stash that was not restored", function()
        it("leaves the restored stash's marker and the other stash's spot alone", function()
            local id = restored_stash()
            local _, other = model.stash("placeable_fridge")
            level.map_add_object_spot_ser(other.id, "treasure", "other")
            SendScriptCallback("actor_on_stash_remove", { stash_id = other.id, cancel = false })
            expect(markers_on(id)).toBe(1)
            expect(#H.fakes.spots_on(other.id, "treasure")).toBe(1)
        end)
    end)

    describe("given another mod cancels the removal", function()
        -- Stock checks data.cancel after the callback and keeps the stash
        -- (item_backpack.script:73-76). Callback order is not fixed (axr_main.script:274),
        -- so this is the case where the other mod ran first.
        local function cancelled_remove(id)
            SendScriptCallback("actor_on_stash_remove", { stash_id = id, cancel = true })
        end

        it("keeps its marker", function()
            local id = opened_stash()
            cancelled_remove(id)
            expect(markers_on(id)).toBe(1)
        end)

        it("still loses its marker when the stash goes later", function()
            local id = opened_stash()
            cancelled_remove(id)
            picked_up(id)
            game_load()
            expect(markers_on(id)).toBe(0)
        end)
    end)

    describe("given several stashes released with no callback", function()
        it("loses every marker at the next game load", function()
            model.give(model.stash("placeable_case"), "vodka", { uses = 1 })
            model.give(model.stash("placeable_fridge"), "vodka", { uses = 1 })
            H.frames(2)
            H.die()
            H.new_life()
            local case = model.all_stashes("placeable_case")[1].id
            local fridge = model.all_stashes("placeable_fridge")[1].id
            picked_up(case)
            picked_up(fridge)
            game_load()
            expect(markers_on(case)).toBe(0)
            expect(markers_on(fridge)).toBe(0)
        end)
    end)

    describe("given a marker on an id the mod has finished with", function()
        -- The engine reuses freed ids (id_generator.h, tfGetID and vfFreeID), and any mod
        -- can put this spot type on its own object. The spot here stands for a later
        -- object on the same id that has since gone too. While such an object is alive
        -- the sweep leaves its marker anyway, as the id still has a server object.
        local OTHER_MOD = "another mod's marker"

        it("leaves it alone after stock removed the stash", function()
            local id = opened_stash()
            stock_remove(id)
            level.map_add_object_spot_ser(id, MARKER, OTHER_MOD)
            game_load()
            expect(markers_on(id)).toBe(1)
        end)

        it("leaves it alone after an earlier game load removed the stash's marker", function()
            local id = opened_stash()
            picked_up(id)
            game_load()
            level.map_add_object_spot_ser(id, MARKER, OTHER_MOD)
            game_load()
            expect(markers_on(id)).toBe(1)
        end)
    end)

    describe("given a save with stashes and no list of restored stashes", function()
        -- save_state has written the list since a900f3a (2023). An older save has only
        -- the stashes, and the marker it holds is one the mod no longer knows about.
        local function strip_list_from_save()
            local path = "saves/quicksave.scoc"
            local data = marshal.decode(model.files[path])
            data.roguelite_manager.spawned_stashes = nil
            model.files[path] = marshal.encode(data)
        end

        it("gets through a game load and a stash removal", function()
            local id = opened_stash()
            H.save()
            strip_list_from_save()
            H.reload()
            expect(game_load).never.toThrow()
            expect(function()
                SendScriptCallback("actor_on_stash_remove", { stash_id = id, cancel = false })
            end).never.toThrow()
        end)
    end)

    describe("given a save and a reload", function()
        -- FIXES: scripts re-execute on load, so what the mod knows about its markers has
        -- to come back through the save.
        it("still removes the marker of a stash released before the save", function()
            local id = opened_stash()
            picked_up(id)
            H.save()
            H.reload()
            game_load()
            expect(markers_on(id)).toBe(0)
        end)

        it("still removes the marker of a stash released after an earlier reload", function()
            local id = opened_stash()
            H.save()
            H.reload()
            game_load()
            picked_up(id)
            H.save()
            H.reload()
            game_load()
            expect(markers_on(id)).toBe(0)
        end)

        -- The client object comes back on a later frame, so at this point only the
        -- server object says the stash exists.
        it("keeps one marker on a stash that still exists", function()
            local id = opened_stash()
            H.save()
            H.reload()
            game_load()
            expect(markers_on(id)).toBe(1)
        end)
    end)
end)

return true

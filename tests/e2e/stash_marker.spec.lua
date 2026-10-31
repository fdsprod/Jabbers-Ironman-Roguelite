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

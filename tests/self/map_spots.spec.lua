-- Harness self-test: the map manager's spot list.
--
-- Every "no marker is left behind" assertion reads this list. If the model
-- turns into a set, or lets one remove clear a duplicate, a marker the game
-- would keep on the map reads as gone, and those specs go green for the wrong
-- reason. harness/fakes.lua cites the engine for each rule below.

local H = require("harness.init")

describe("harness/fakes map spots", function()

    local SPOT = "secondary_task_location"

    beforeEach(function()
        H.boot()
    end)

    describe("map_add_object_spot_ser()", function()
        it("adds a spot with its hint", function()
            level.map_add_object_spot_ser(7, SPOT, "items")
            expect(#H.fakes.spots_on(7, SPOT)).toBe(1)
            expect(H.fakes.spots_on(7, SPOT)[1].hint).toBe("items")
        end)

        it("adds a second spot when one of the same type is already there", function()
            level.map_add_object_spot_ser(7, SPOT, "a")
            level.map_add_object_spot_ser(7, SPOT, "b")
            expect(#H.fakes.spots_on(7, SPOT)).toBe(2)
        end)
    end)

    describe("map_remove_object_spot()", function()
        it("removes only the first of two matching spots", function()
            level.map_add_object_spot_ser(7, SPOT, "a")
            level.map_add_object_spot_ser(7, SPOT, "b")
            level.map_remove_object_spot(7, SPOT)
            expect(#H.fakes.spots_on(7, SPOT)).toBe(1)
            expect(H.fakes.spots_on(7, SPOT)[1].hint).toBe("b")
        end)

        it("leaves spots of another type on the same id", function()
            level.map_add_object_spot_ser(7, SPOT, "a")
            level.map_add_object_spot_ser(7, "treasure", "t")
            level.map_remove_object_spot(7, SPOT)
            expect(#H.fakes.spots_on(7)).toBe(1)
            expect(H.fakes.spots_on(7)[1].type).toBe("treasure")
        end)

        it("does nothing when there is no match", function()
            level.map_remove_object_spot(7, SPOT)
            expect(#H.fakes.spots_on(7)).toBe(0)
        end)

        it("is still recorded", function()
            level.map_remove_object_spot(7, SPOT)
            expect(H.fakes.call_count("level.map_remove_object_spot")).toBe(1)
        end)
    end)

    describe("map_has_object_spot()", function()
        it("returns 1 or 0, as the engine's u16 does", function()
            expect(level.map_has_object_spot(7, SPOT)).toBe(0)
            level.map_add_object_spot_ser(7, SPOT, "a")
            expect(level.map_has_object_spot(7, SPOT)).toBe(1)
        end)
    end)

    describe("alife_release()", function()
        it("leaves the object's spots in place", function()
            local stash = H.world.container("stash", { id = 4242 })
            level.map_add_object_spot_ser(4242, SPOT, "items")
            alife_release(alife_object(4242))
            H.tick()
            expect(#H.fakes.spots_on(4242, SPOT)).toBe(1)
        end)
    end)

    describe("H.boot()", function()
        it("starts with no spots", function()
            level.map_add_object_spot_ser(7, SPOT, "a")
            H.boot()
            expect(#H.fakes.spots_on(7)).toBe(0)
        end)
    end)

    describe("H.reload()", function()
        it("keeps the spots, which are in the save", function()
            H.boot_game()
            level.map_add_object_spot_ser(7, SPOT, "a")
            H.save()
            H.reload()
            expect(#H.fakes.spots_on(7, SPOT)).toBe(1)
        end)
    end)

    describe("H.new_life()", function()
        it("starts with no spots", function()
            H.boot_game()
            level.map_add_object_spot_ser(7, SPOT, "a")
            H.die()
            H.new_life()
            expect(#H.fakes.spots_on(7)).toBe(0)
        end)
    end)
end)

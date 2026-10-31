-- roguelite_manager.restore_item, on its own.

local H = require("harness.init")

describe("roguelite_manager", function()
    local model, box

    local function restore(data)
        data.section = data.section or "vodka"
        return roguelite_manager.restore_item(data.section, vector(), 1, 1, data, box:id(), false)
    end

    beforeEach(function()
        H.boot_game()
        model = H.alife
        H.define("vodka", { max_uses = 3 })
        H.define("placeable_case", { kind = "invbox" })
        box = model.stash("placeable_case")
    end)

    describe("restore_item()", function()
        -- alife():register frees its argument and returns a new object
        -- (alife_simulator_script.cpp:396-412). Reading the old one is undefined
        -- behaviour: it usually still answers, which is why it never crashed.
        describe("given an item with uses and parts", function()
            it("never reads the object register freed", function()
                restore({ uses = 1, condition = 1, parts_condition = { barrel = 50 } })
                expect(model.use_after_free).toEqual({})
            end)

            it("returns the live object", function()
                local se = restore({ uses = 1, condition = 1 })
                local before = #model.use_after_free
                local _ = se.id
                expect(#model.use_after_free).toBe(before)
            end)
        end)

        describe("given no item data at all", function()
            it("returns the live object", function()
                local se = roguelite_manager.restore_item("vodka", vector(), 1, 1, nil, box:id(), false)
                local _ = se.id
                expect(model.use_after_free).toEqual({})
            end)
        end)

        describe("given a saved uses value", function()
            it("applies it once the client object exists", function()
                local id = restore({ uses = 1, condition = 1 }).id
                H.frames(2)
                expect(level.object_by_id(id):get_remaining_uses()).toBe(1)
            end)
        end)

        describe("given no uses value", function()
            it("leaves a multiuse item full", function()
                local id = restore({ condition = 1 }).id
                H.frames(2)
                expect(level.object_by_id(id):get_remaining_uses()).toBe(3)
            end)
        end)
    end)

    describe("serialize_item()", function()
        describe("given a multiuse item in a loaded stash", function()
            it("reads the uses off the client object", function()
                local _, se = model.give(box, "vodka", { uses = 2 })
                expect(roguelite_manager.serialize_item(se).uses).toBe(2)
            end)
        end)

        describe("given a multiuse item in an offline stash", function()
            local se

            beforeEach(function()
                local item, item_se = model.give(box, "vodka", { uses = 2 })
                se = item_se
                H.frames(2)
            end)

            it("reads the uses from bind_item's table after a save", function()
                H.save()
                model.set_online(box:id(), false)
                expect(roguelite_manager.serialize_item(se).uses).toBe(2)
            end)

            it("reports nothing when the table is out of reach", function()
                model.set_online(box:id(), false)
                expect(roguelite_manager.serialize_item(se).uses).toBeNil()
            end)
        end)
    end)
end)

return true

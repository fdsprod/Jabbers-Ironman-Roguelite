-- Self-tests for the server/client model. These pin the engine behaviour the item
-- use specs depend on: if one of these is wrong, those specs mean nothing.

local H = require("harness.init")

describe("harness/alife", function()
    local alife_model

    beforeEach(function()
        H.boot_game()
        alife_model = H.alife
        H.define("vodka", { max_uses = 3 })
        H.define("placeable_case", { kind = "invbox" })
    end)

    describe("a client object", function()
        -- eatable_item.cpp:48
        it("starts with max_uses left", function()
            local box = alife_model.stash("placeable_case")
            local item = alife_model.give(box, "vodka")
            expect(item:get_remaining_uses()).toBe(3)
        end)

        -- eatable_item.h:49
        it("silently ignores a uses value above the maximum", function()
            local box = alife_model.stash("placeable_case")
            local item = alife_model.give(box, "vodka", { uses = 2 })
            item:set_remaining_uses(9)
            expect(item:get_remaining_uses()).toBe(2)
        end)
    end)

    describe("level.object_by_id()", function()
        it("finds an item while its box is online", function()
            local box = alife_model.stash("placeable_case")
            local item = alife_model.give(box, "vodka")
            expect(level.object_by_id(item:id())).toBe(item)
        end)

        it("finds nothing once the box has gone offline", function()
            local box = alife_model.stash("placeable_case")
            local item = alife_model.give(box, "vodka")
            alife_model.set_online(box:id(), false)
            expect(level.object_by_id(item:id())).toBeNil()
        end)

        it("still leaves the server object in place", function()
            local box = alife_model.stash("placeable_case")
            local item = alife_model.give(box, "vodka")
            local id = item:id()
            alife_model.set_online(box:id(), false)
            expect(alife():object(id)).toBeDefined()
        end)
    end)

    describe("the real bind_item, given a used item that goes offline and back", function()
        local box, id

        beforeEach(function()
            box = alife_model.stash("placeable_case")
            id = alife_model.give(box, "vodka", { uses = 1 }):id()
            H.frames(2)
            alife_model.set_online(box:id(), false)
            alife_model.set_online(box:id(), true)
        end)

        it("spawns a fresh client object that starts full", function()
            H.alife.binders_paused = true
            H.frames(1)
            expect(level.object_by_id(id):get_remaining_uses()).toBe(3)
        end)

        it("restores the uses on the binder's first update", function()
            H.frames(1)
            expect(level.object_by_id(id):get_remaining_uses()).toBe(1)
        end)
    end)

    describe("alife():create()", function()
        it("leaves an item unregistered given an online parent and false", function()
            local box = alife_model.stash("placeable_case")
            local se = alife():create("vodka", vector(), 1, 1, box:id(), false)
            expect(alife():object(se.id)).toBeNil()
        end)

        -- alife_simulator_script.cpp:218-219
        it("registers anyway given an offline parent and false", function()
            local box = alife_model.stash("placeable_case")
            alife_model.set_online(box:id(), false)
            local se = alife():create("vodka", vector(), 1, 1, box:id(), false)
            expect(alife():object(se.id)).toBeDefined()
        end)
    end)

    describe("alife():register()", function()
        local box, se, id

        beforeEach(function()
            box = alife_model.stash("placeable_case")
            se = alife():create("vodka", vector(), 1, 1, box:id(), false)
            id = se.id
        end)

        it("keeps the id on the object it returns", function()
            expect(alife():register(se).id).toBe(id)
        end)

        it("logs no read of the returned object", function()
            local fresh = alife():register(se)
            local _ = fresh.id
            expect(alife_model.use_after_free).toEqual({})
        end)

        -- alife_simulator_script.cpp:396-412
        it("logs a read of the object it freed", function()
            alife():register(se)
            local _ = se.id
            expect(#alife_model.use_after_free).toBe(1)
        end)

        it("spawns the client object on a later frame, not at once", function()
            alife():register(se)
            expect(level.object_by_id(id)).toBeNil()
            H.frames(1)
            expect(level.object_by_id(id)).toBeDefined()
        end)
    end)

    describe("the real alife_storage_manager", function()
        -- The whole offline-uses fix stands on these three. bind_item's table is a
        -- local, and get_state() can only see it by aliasing.
        local function stock_table() return alife_storage_manager.get_state().item_remaining_uses end

        local function with_used_item()
            local box = alife_model.stash("placeable_case")
            local id = alife_model.give(box, "vodka", { uses = 1 }):id()
            H.frames(2)
            return box, id
        end

        it("cannot see bind_item's table before any save or load", function()
            with_used_item()
            expect(stock_table()).toBeNil()
        end)

        it("shares the live table after a save", function()
            local _, id = with_used_item()
            H.save()
            level.object_by_id(id):set_remaining_uses(2)
            H.frames(1)
            expect(stock_table()[id]).toBe(2)
        end)

        it("shares the live table after a load", function()
            local _, id = with_used_item()
            H.save()
            H.reload()
            H.frames(1)
            level.object_by_id(id):set_remaining_uses(2)
            H.frames(1)
            expect(stock_table()[id]).toBe(2)
        end)
    end)

    describe("the state file", function()
        it("survives into a new life", function()
            local f = io.open("appdata\\x.state", "wb")
            f:write("kept")
            f:close()
            H.new_life()
            expect(io.open("appdata\\x.state", "rb"):read("*all")).toBe("kept")
        end)

        it("does not survive a fresh boot_game", function()
            local f = io.open("appdata\\x.state", "wb")
            f:write("gone")
            f:close()
            H.boot_game()
            expect(io.open("appdata\\x.state", "rb")).toBeNil()
        end)
    end)

    describe("marshal", function()
        it("round-trips numbers, strings, booleans and nested tables", function()
            local v = { a = 1, b = "x", c = true, d = { [7] = 0.5 } }
            expect(marshal.decode(marshal.encode(v))).toEqual(v)
        end)

        it("refuses a server object, as it would refuse userdata", function()
            local _, se = alife_model.stash("placeable_case")
            expect(function() marshal.encode({ se }) end).toThrow("metatable")
        end)
    end)
end)

return true

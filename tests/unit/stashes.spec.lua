-- roguelite_module_stashes, apart from what the journeys in e2e/ cover.

local H = require("harness.init")

describe("roguelite_module_stashes", function()
    local model

    local function restore(data)
        roguelite_module_stashes.roguelite_load_state(data)
    end

    beforeEach(function()
        H.boot_game()
        model = H.alife
        H.define("placeable_case", { kind = "invbox" })
        H.define("workshop_stash", { kind = "invbox" })
    end)

    describe("restoring money", function()
        -- FIXES: it gave the saved amount on top of the starting money, so a player's
        -- money grew by the starting amount every life. The comment above it says the
        -- intent: restore the amount, only if it is more than the starting amount.
        it("ends on the saved amount, not the saved amount plus the starting money", function()
            db.actor:give_money(500)
            restore({ stashes_version = 2, money = 10000, stashes = {} })
            expect(db.actor:money()).toBe(10000)
        end)

        it("leaves a player alone who already starts with more", function()
            db.actor:give_money(20000)
            restore({ stashes_version = 2, money = 10000, stashes = {} })
            expect(db.actor:money()).toBe(20000)
        end)

        it("does nothing when the money option is off", function()
            model.set_mcm("is_money_restore_enabled", false)
            db.actor:give_money(500)
            restore({ stashes_version = 2, money = 10000, stashes = {} })
            expect(db.actor:money()).toBe(500)
        end)

        -- FIXES: the money option did nothing on its own. Money was saved and restored
        -- only while the separate stash option was on.
        describe("given the stash option is off", function()
            it("still restores money", function()
                model.set_mcm("is_stash_restore_enabled", false)
                db.actor:give_money(500)
                restore({ stashes_version = 2, money = 10000, stashes = {} })
                expect(db.actor:money()).toBe(10000)
            end)

            it("still saves money", function()
                model.set_mcm("is_stash_restore_enabled", false)
                db.actor:give_money(700)
                local data = {}
                roguelite_module_stashes.roguelite_save_state(data)
                expect(data.money).toBe(700)
            end)

            it("does not save stashes", function()
                model.set_mcm("is_stash_restore_enabled", false)
                model.stash("placeable_case")
                local data = {}
                roguelite_module_stashes.roguelite_save_state(data)
                expect(data.stashes).toBeNil()
            end)
        end)
    end)

    describe("given a state file written with the stash option off", function()
        -- FIXES: `nil >= 2`. Turning the option back on made every later life raise on
        -- first update, before the rest of the modules restored.
        it("loads one with no version at all", function()
            expect(function() restore({}) end).never.toThrow()
        end)

        it("loads one with a version but no stashes", function()
            expect(function() restore({ stashes_version = 2 }) end).never.toThrow()
        end)
    end)

    describe("given a save with no stash version in it", function()
        -- The same comparison in the load_state callback.
        it("loads", function()
            expect(function()
                SendScriptCallback("load_state", { roguelite_manager = {} })
            end).never.toThrow()
        end)
    end)

    describe("given a workshop stash whose workshop no longer exists", function()
        -- FIXES: sim:object(workshop_id) returned nil and was indexed. That raised
        -- during death, inside the save, losing the state for everything after it.
        it("saves the stash without a parent", function()
            local _, se = model.stash("workshop_stash")
            alife_storage_manager.get_state().workshop_stashes = { [9999] = se.id }
            local data = {}
            roguelite_module_stashes.roguelite_save_state(data)
            expect(data.stashes[se.id]).toBeDefined()
            expect(data.stashes[se.id].parent_obj).toBeNil()
        end)
    end)
end)

return true

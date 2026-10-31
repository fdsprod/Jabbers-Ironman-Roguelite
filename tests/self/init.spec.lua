-- Harness self-test: boot/reboot lifecycle and the spawn-point fixture.
--
-- H.reboot is what makes the save/load round-trip testable at all: a plain
-- H.boot wipes the save table, so a "reload" would have nothing to restore
-- from. It models a level change -- every script re-executes and every module
-- table is discarded, but alife_storage_manager's state survives.

local H = require("harness.init")

local MOD_SCRIPTS = { "soulslike_classes", "soulslike" }

describe("harness/init", function()

    describe("boot{ state = ... }", function()
        -- fakes.game_state is the whole save table; the mod's own state lives
        -- under the "soulslike" key (soulslike.script:210), which is what
        -- opts.state seeds.
        it("seeds the mod's sub-table of the save", function()
            H.boot{ state = { created_stashes = { [42] = { examine = true } } } }
            expect(H.fakes.game_state.soulslike.created_stashes[42].examine).toBe(true)
        end)



        it("is wiped by a plain boot", function()
            H.boot{ state = { uuid = "seeded" } }
            H.boot()
            expect(H.fakes.game_state.soulslike).toBeNil()
        end)
    end)



    describe("tick()", function()
        beforeEach(function() H.boot() end)

        it("drains time events before applying world mutations", function()
            local box = H.world.container("stash")
            local ak = H.world.give("actor", "wpn_ak74")
            CreateTimeEvent("t", "a", 0, function()
                db.actor:transfer_item(ak, box)
                return true
            end)
            expect(H.world.where(ak)).toBe("actor")
            H.tick()
            expect(H.world.where(ak)).toBe("stash")
        end)
    end)
end)

return true

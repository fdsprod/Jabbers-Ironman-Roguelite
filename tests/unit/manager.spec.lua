-- roguelite_manager, apart from item serialization.

local H = require("harness.init")

describe("roguelite_manager", function()
    local model

    -- A module of any author's, as get_modules finds them. Third parties are invited
    -- to write these in the README.
    local function add_module(name, module)
        _G[name] = module
        model.module_names[#model.module_names + 1] = name
    end

    beforeEach(function()
        H.boot_game()
        model = H.alife
        H.define("placeable_case", { kind = "invbox" })
    end)

    describe("given a module that raises while saving", function()
        -- FIXES: one module's error took the whole save with it, so a stock lookup that
        -- failed in the trader module cost the player their stashes too.
        beforeEach(function()
            add_module("roguelite_module_bad", {
                roguelite_save_state = function() error("bad module") end,
            })
            db.actor:give_money(1234)
        end)

        it("still writes the other modules' data", function()
            H.die()
            local f = io.open("appdata\\roguelite_stalker.state", "rb")
            expect(f).toBeDefined()
            expect(marshal.decode(f:read("*all")).money).toBe(1234)
        end)

        it("logs the error, even with debug off", function()
            H.die()
            local found = false
            for _, call in ipairs(H.fakes.calls_to("debug_write")) do
                if tostring(call[1]):find("bad module", 1, true) then found = true end
            end
            expect(found).toBe(true)
        end)
    end)

    describe("given a module that raises while restoring", function()
        beforeEach(function()
            db.actor:give_money(1234)
            H.die()
            H.new_life()
        end)

        local function restore_with_bad_module()
            alife_storage_manager.get_state().roguelite_restore_complete = nil
            add_module("roguelite_module_bad", {
                roguelite_load_state = function() error("bad module") end,
            })
            local called = false
            add_module("roguelite_module_after", {
                roguelite_load_state = function() called = true end,
            })
            SendScriptCallback("actor_on_first_update")
            return called
        end

        it("still restores the other modules", function()
            expect(restore_with_bad_module()).toBe(true)
        end)

        it("marks the restore complete, so it does not run again", function()
            restore_with_bad_module()
            expect(alife_storage_manager.get_state().roguelite_restore_complete).toBe(true)
        end)
    end)

    describe("debug_write()", function()
        -- FIXES: the MCM debug option was read by nothing. Every line was always written
        -- to the log: several per item on every death and stash opening.
        it("writes nothing with the debug option off", function()
            roguelite_manager.debug_write("hello")
            expect(H.fakes.call_count("debug_write")).toBe(0)
        end)

        it("writes with the debug option on", function()
            model.set_mcm("debug", true)
            roguelite_manager.debug_write("hello")
            expect(H.fakes.call_count("debug_write")).toBe(1)
        end)
    end)
end)

return true

-- Harness self-test: the callback registry behind RegisterScriptCallback /
-- SendScriptCallback (transcribed from axr_main.script:240-285).

local H = require("harness.init")
local dispatch = H.dispatch

describe("harness/dispatch", function()

    beforeEach(function() H.boot() end)

    describe("RegisterScriptCallback()", function()

        describe("given the intercept was never added", function()
            -- The trap: axr_main requires callback_add before callback_set.
            -- Without it, registration is dropped with only a printf. A
            -- harness that "helpfully" auto-created the intercept would hide a
            -- real class of mod bug.
            it("does not create the intercept implicitly", function()
                RegisterScriptCallback("never_added_xyz", function() end)
                expect(dispatch.exists("never_added_xyz")).toBeFalsy()
            end)

            it("reports the dropped registration", function()
                RegisterScriptCallback("never_added_xyz", function() end)
                expect(dispatch.warnings).toHaveLength(1)
            end)

            it("leaves the handler unreachable", function()
                local fired = false
                RegisterScriptCallback("never_added_xyz", function() fired = true end)
                SendScriptCallback("never_added_xyz")
                expect(fired).toBeFalsy()
            end)
        end)

        describe("given a nil handler", function()
            it("rejects it", function()
                dispatch.add("evt")
                RegisterScriptCallback("evt", nil)
                expect(dispatch.handler_count("evt")).toBe(0)
            end)

            it("reports the rejection", function()
                dispatch.add("evt")
                RegisterScriptCallback("evt", nil)
                expect(dispatch.warnings).toHaveLength(1)
            end)
        end)

        describe("given the same function registered twice", function()
            it("stores it once, because intercepts is a set", function()
                dispatch.add("evt")
                local fn = function() end
                RegisterScriptCallback("evt", fn)
                RegisterScriptCallback("evt", fn)
                expect(dispatch.handler_count("evt")).toBe(1)
            end)

            it("invokes it once per send", function()
                dispatch.add("evt")
                local count = 0
                local fn = function() count = count + 1 end
                RegisterScriptCallback("evt", fn)
                RegisterScriptCallback("evt", fn)
                SendScriptCallback("evt")
                expect(count).toBe(1)
            end)
        end)
    end)

    describe("SendScriptCallback()", function()

        describe("given a registered function handler", function()
            it("invokes it", function()
                dispatch.add("evt")
                local seen
                RegisterScriptCallback("evt", function(a) seen = a end)
                SendScriptCallback("evt", "payload")
                expect(seen).toBe("payload")
            end)

            it("forwards every argument, preserving arity across a nil", function()
                dispatch.add("evt")
                local got
                RegisterScriptCallback("evt", function(...)
                    got = { n = select("#", ...), ... }
                end)
                SendScriptCallback("evt", 1, nil, "three")
                expect(got.n).toBe(3)
                expect(got[1]).toBe(1)
                expect(got[3]).toBe("three")
            end)
        end)

        describe("given several handlers on one name", function()
            it("invokes all of them", function()
                dispatch.add("evt")
                local count = 0
                RegisterScriptCallback("evt", function() count = count + 1 end)
                RegisterScriptCallback("evt", function() count = count + 1 end)
                SendScriptCallback("evt")
                expect(count).toBe(2)
            end)
        end)

        describe("given an object carrying a method of the same name", function()
            -- make_callback's second branch:
            --   func_or_userdata[name](func_or_userdata, ...)
            it("calls the method with the object as self", function()
                dispatch.add("on_thing")
                local obj = { hits = 0 }
                function obj:on_thing(v) self.hits = self.hits + 1; self.last = v end

                RegisterScriptCallback("on_thing", obj)
                SendScriptCallback("on_thing", "x")

                expect(obj.hits).toBe(1)
                expect(obj.last).toBe("x")
            end)
        end)

        describe("given axr_main declares a function of the same name", function()
            it("invokes that too", function()      -- _g.script:120-123
                dispatch.add("evt")
                local via_axr
                axr_main.evt = function(v) via_axr = v end
                SendScriptCallback("evt", "direct")
                expect(via_axr).toBe("direct")
                axr_main.evt = nil
            end)
        end)

        describe("given an unknown name", function()
            it("does not raise", function()
                expect(function() SendScriptCallback("nope_not_here") end).never.toThrow()
            end)

            it("reports it", function()
                SendScriptCallback("nope_not_here")
                expect(dispatch.warnings).toHaveLength(1)
            end)
        end)

        describe("given any send", function()
            it("logs it for assertion", function()
                dispatch.add("evt")
                SendScriptCallback("evt", 42)
                local sends = dispatch.sends_of("evt")
                expect(sends).toHaveLength(1)
                expect(sends[1].args[1]).toBe(42)
            end)
        end)
    end)

    describe("UnregisterScriptCallback()", function()
        describe("given a registered handler", function()
            it("removes it", function()
                dispatch.add("evt")
                local fn = function() end
                RegisterScriptCallback("evt", fn)
                UnregisterScriptCallback("evt", fn)
                expect(dispatch.handler_count("evt")).toBe(0)
            end)

            it("stops it being invoked", function()
                dispatch.add("evt")
                local count = 0
                local fn = function() count = count + 1 end
                RegisterScriptCallback("evt", fn)
                UnregisterScriptCallback("evt", fn)
                SendScriptCallback("evt")
                expect(count).toBe(0)
            end)
        end)
    end)

    describe("pre-registered intercepts", function()
        -- soulslike.on_game_start (soulslike.script:948-965) registers these.
        -- If any is missing from CALLBACK_NAMES its handler is silently
        -- dropped and every integration spec built on it passes vacuously.
        local required = {
            "actor_on_stash_remove", "actor_on_first_update",
            "actor_on_item_take_from_box", "actor_on_before_death",
            "on_before_save_input", "save_state", "load_state",
            "on_level_changing", "on_game_load", "actor_on_sleep",
            "on_console_execute", "actor_on_before_hit",
            "physic_object_on_use_callback",
        }

        describe("given a freshly booted harness", function()
            for _, name in ipairs(required) do
                it("has an intercept for " .. name, function()
                    expect(dispatch.exists(name)).toBeTruthy()
                end)
            end
        end)
    end)
end)

return true

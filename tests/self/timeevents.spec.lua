-- Harness self-test: the deferred time-event pump.
--
-- The mod continues work on a later frame via CreateTimeEvent, so the
-- death->respawn flow does not complete synchronously. If this drains
-- incorrectly, every e2e spec either hangs or asserts against a half-finished
-- flow.

local H = require("harness.init")
local te = H.timeevents

describe("harness/timeevents", function()

    beforeEach(function() H.boot() end)

    describe("CreateTimeEvent()", function()

        describe("given an event is created", function()
            it("does not run it immediately", function()
                local ran = false
                CreateTimeEvent(0, "e", 0, function() ran = true; return true end)
                expect(ran).toBeFalsy()
            end)

            it("queues it", function()
                CreateTimeEvent(0, "e", 0, function() return true end)
                expect(te.pending()).toBe(1)
            end)
        end)

        describe("given extra arguments", function()
            it("forwards them to the callback", function()
                local got
                CreateTimeEvent(0, "e", 0, function(a, b) got = { a, b }; return true end,
                                "x", 42)
                te.pump()
                expect(got).toEqual({ "x", 42 })
            end)
        end)
    end)

    describe("pump()", function()

        describe("given a callback returning true", function()
            it("runs it", function()
                local ran = false
                CreateTimeEvent(0, "e", 0, function() ran = true; return true end)
                te.pump()
                expect(ran).toBeTruthy()
            end)

            it("drops it from the queue", function()
                CreateTimeEvent(0, "e", 0, function() return true end)
                te.pump()
                expect(te.pending()).toBe(0)
            end)
        end)

        describe("given a callback returning false", function()
            -- The real contract, from wait_for_stash_creation
            -- (soulslike_scenarios.script:535): false means "not ready, retry".
            it("keeps retrying until it returns true", function()
                local calls = 0
                CreateTimeEvent(0, "e", 0, function()
                    calls = calls + 1
                    return calls >= 3
                end)
                te.pump()
                expect(calls).toBe(3)
                expect(te.pending()).toBe(0)
            end)
        end)

        describe("given a callback that never returns true", function()
            it("raises rather than spinning forever", function()
                CreateTimeEvent(0, "stuck", 0, function() return false end)
                expect(function() te.pump() end).toThrow("still queued after")
            end)
        end)

        describe("given an event that queues another event", function()
            it("settles the whole chain in one pump", function()
                local order = {}
                CreateTimeEvent(0, "a", 0, function()
                    order[#order + 1] = "a"
                    CreateTimeEvent(0, "b", 0, function()
                        order[#order + 1] = "b"; return true
                    end)
                    return true
                end)
                te.pump()
                expect(order).toEqual({ "a", "b" })
                expect(te.pending()).toBe(0)
            end)
        end)

        describe("given an empty queue", function()
            it("does nothing and reports zero", function()
                expect(te.pump()).toBe(0)
            end)
        end)
    end)

    describe("RemoveTimeEvent()", function()
        describe("given a queued event with a matching key", function()
            it("removes it", function()
                CreateTimeEvent(0, "gone", 0, function() return true end)
                RemoveTimeEvent(0, "gone")
                expect(te.pending()).toBe(0)
            end)

            it("leaves other events alone", function()
                CreateTimeEvent(0, "gone", 0, function() return true end)
                CreateTimeEvent(0, "kept", 0, function() return true end)
                RemoveTimeEvent(0, "gone")
                expect(te.peek()).toEqual({ "0/kept" })
            end)
        end)
    end)

    describe("H.tick()", function()
        it("drains time events and then applies world mutations", function()
            -- Ordering matters: an event that transfers an item must have its
            -- queued mutation applied in the same tick.
            local item = H.world.give("actor", "medkit")
            CreateTimeEvent(0, "move", 0, function()
                H.world.queue_transfer(item, "stash")
                return true
            end)
            H.tick()
            expect(H.world.where(item)).toBe("stash")
        end)
    end)
end)

return true

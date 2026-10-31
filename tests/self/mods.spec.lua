-- Harness self-test: the optional-mod registry.

local H = require("harness.init")
local mods = H.mods

describe("harness/mods", function()

    beforeEach(function() H.boot() end)

    describe("default state", function()
        describe("given a freshly booted harness", function()
            it("installs the base-Anomaly scripts", function()
                -- These ship with Anomaly, so every install has them. Two are
                -- even called unguarded (actor_status_thirst at
                -- soulslike_scenarios.script:590, treasure_manager at :1335),
                -- so "absent" is not a state the mod survives.
                for _, name in ipairs(mods.BASE) do
                    expect(rawget(_G, name)).toBeDefined()
                end
            end)

            it("leaves the third-party ones absent", function()
                -- Absent is what most installs look like, and it keeps the
                -- `if <mod> and ...` guard branches exercised by default.
                for _, name in ipairs(mods.OPTIONAL) do
                    expect(rawget(_G, name)).toBeNil()
                end
            end)
        end)
    end)

    describe("boot{ without = {...} }", function()
        describe("given a base script is excluded", function()
            it("removes it, so the guard branch can be tested", function()
                -- ApplyItemConditionLoss bails early when item_parts is nil
                -- (soulslike_scenarios.script:434).
                H.boot{ without = { "item_parts" } }
                expect(rawget(_G, "item_parts")).toBeNil()
            end)
        end)
    end)

    describe("enable()", function()
        describe("given a known soft dependency", function()
            it("installs it as a global", function()
                mods.enable("item_parts")
                expect(_G.item_parts).toBeDefined()
            end)

            it("marks it enabled", function()
                mods.enable("item_parts")
                expect(mods.is_enabled("item_parts")).toBeTruthy()
            end)

            it("provides the functions the mod calls", function()
                mods.enable("item_parts")
                expect(item_parts.get_parts_con).toBeType("function")
                expect(item_parts.set_parts_con).toBeType("function")
            end)
        end)

        describe("given overrides", function()
            it("merges them over the default stub", function()
                mods.enable("magazine_binder", {
                    is_magazine = function() return true end,
                })
                expect(magazine_binder.is_magazine()).toBe(true)
                expect(magazine_binder.validate_loadout).toBeType("function")
            end)
        end)

        describe("given an unknown name", function()
            it("raises with the list of known names", function()
                expect(function() mods.enable("not_a_mod") end)
                    .toThrow("unknown soft dependency")
            end)
        end)

        describe("given demonized_time_events", function()
            it("also installs the dte alias", function()
                mods.enable("demonized_time_events")
                expect(_G.dte).toBeDefined()
            end)

        end)
    end)

    describe("boot{ mods = {...} }", function()
        describe("given mods listed at boot", function()
        end)
    end)

    describe("disable()", function()
        it("removes the global", function()
            mods.enable("arszi_psy")
            mods.disable("arszi_psy")
            expect(rawget(_G, "arszi_psy")).toBeNil()
        end)
    end)

    describe("patched()", function()
        -- RFDetectorSoulslikeScenarioLogic:CreateStash monkey-patches
        -- treasure_manager.box_in_same_map and restores it afterwards
        -- (soulslike_scenarios.script:1335-1341). An early return between the
        -- two would leak the patch.
        describe("given nothing has been patched", function()
            it("reports no differences", function()
                mods.enable("treasure_manager")
                expect(mods.patched("treasure_manager")).toEqual({})
            end)
        end)

        describe("given a field was replaced and not restored", function()
            it("names that field", function()
                mods.enable("treasure_manager")
                treasure_manager.box_in_same_map = function() return false end
                expect(mods.patched("treasure_manager")).toEqual({ "box_in_same_map" })
            end)
        end)

        describe("given a field was replaced and then restored", function()
            it("reports no differences", function()
                mods.enable("treasure_manager")
                local original = treasure_manager.box_in_same_map
                treasure_manager.box_in_same_map = function() return false end
                treasure_manager.box_in_same_map = original
                expect(mods.patched("treasure_manager")).toEqual({})
            end)
        end)
    end)

    describe("reset()", function()
        it("clears everything a previous spec enabled", function()
            mods.enable("item_radio")
            mods.reset()
            expect(rawget(_G, "item_radio")).toBeNil()
        end)
    end)
end)

return true

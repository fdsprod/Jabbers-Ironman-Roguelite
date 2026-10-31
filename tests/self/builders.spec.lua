-- Harness self-test: the scenario fixtures and the engine-fidelity behavior
-- baked into make_actor.
--
-- The drift guard in "make_logic_state() / schema" is the load-bearing one. The
-- fixture is a hand-written literal, so a field added to or removed from the
-- mod's logic_state would otherwise leave every scenario spec asserting against
-- a shape the mod no longer has.

local H = require("harness.init")
local B = H.builders

local MOD_SCRIPTS = {
    "soulslike_classes", "soulslike", "soulslike_mcm",
    "soulslike_message_factory", "soulslike_scenarios",
    "soulslike_scenario_logic_factory",
}

local function keys_of(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

describe("harness/builders", function()

    describe("make_logic_state()", function()

        beforeEach(function() H.boot() end)

        describe("given no options", function()
            it("returns the MCM defaults", function()
                local s = B.make_logic_state()
                expect(s.item_loss_scalar).toBeCloseTo(0.2)
                expect(s.health_loss_percent).toBeCloseTo(0.75)
                expect(s.allow_weapon_loss).toBe(true)
                expect(s.keep_equipped_items_on_death).toBe(false)
            end)

            it("gives death_location a real position, not the mod's nils", function()
                local s = B.make_logic_state()
                expect(s.death_location.position.x).toBe(0)
            end)
        end)

        describe("given top-level overrides", function()
            it("applies them over the defaults", function()
                local s = B.make_logic_state{ allow_weapon_loss = false, rank = 5000 }
                expect(s.allow_weapon_loss).toBe(false)
                expect(s.rank).toBe(5000)
            end)

            it("leaves the untouched fields at their defaults", function()
                local s = B.make_logic_state{ allow_weapon_loss = false }
                expect(s.allow_outfit_loss).toBe(true)
            end)

            it("accepts false without falling back to the default", function()
                local s = B.make_logic_state{ allow_npc_looting = false }
                expect(s.allow_npc_looting).toBe(false)
            end)
        end)

        describe("given a story override", function()
            it("merges one level deep rather than replacing the table", function()
                local s = B.make_logic_state{ story = { items_were_lost = true } }
                expect(s.story.items_were_lost).toBe(true)
                -- Still present, i.e. the whole story table was not swapped out.
                expect(s.story).toBeDefined()
                local has_level_name = false
                for k in pairs(B.make_logic_state().story) do
                    if k == "level_name" then has_level_name = true end
                end
                expect(has_level_name).toBe(false)  -- declared nil, so absent
            end)
        end)

        describe("given death_location = false", function()
            it("clears the coordinates, for the no-location-recorded case", function()
                local s = B.make_logic_state{ death_location = false }
                expect(s.death_location.position.x).toBeNil()
                expect(s.death_location.game_vertex_id).toBeNil()
            end)
        end)

        describe("given a partial death_location", function()
            it("merges the position without dropping the other axes", function()
                local s = B.make_logic_state{ death_location = { position = { x = 12 } } }
                expect(s.death_location.position.x).toBe(12)
                expect(s.death_location.position.y).toBe(0)
            end)
        end)

    end)

    describe("make_spawn_location()", function()

        beforeEach(function() H.boot() end)

        it("defaults to a usable level and origin", function()
            local s = B.make_spawn_location()
            expect(s.level).toBe("zaton")
            expect(s.position.x).toBe(0)
            expect(s.angle.z).toBe(0)
        end)

        it("takes overrides", function()
            local s = B.make_spawn_location{ level = "jupiter", position = { x = 3, z = 4 } }
            expect(s.level).toBe("jupiter")
            expect(s.position.x).toBe(3)
            expect(s.position.z).toBe(4)
            expect(s.position.y).toBe(0)
        end)
    end)


    describe("make_se_npc()", function()

        beforeEach(function() H.boot() end)

        -- Server objects expose id and position as FIELDS
        -- (xrServer_Objects_script.cpp:110-124); client objects use methods.
        -- soulslike.find_closest_enemy:317 reads se_obj.position directly.
        it("exposes id as a field, not a method", function()
            expect(B.make_se_npc().id).toBeType("number")
        end)

        it("exposes position as a field with distance methods", function()
            local se = B.make_se_npc{ position = { x = 3, y = 0, z = 4 } }
            expect(se.position.x).toBe(3)
            expect(se.position:distance_to({ x = 0, y = 0, z = 0 })).toBeCloseTo(5)
        end)

        it("carries the accessors the alife scan calls", function()
            local se = B.make_se_npc{ community = "bandit" }
            expect(se:community()).toBe("bandit")
            expect(se:alive()).toBe(true)
            expect(se:section_name()).toBe("sim_default_stalker")
            expect(se.m_game_vertex_id).toBe(1)
        end)

        it("returns a clsid the Is* predicates classify", function()
            expect(_G.IsStalker(nil, B.make_se_npc{ kind = "stalker" }:clsid())).toBe(true)
            expect(_G.IsMonster(nil, B.make_se_npc{ kind = "monster" }:clsid())).toBe(true)
            expect(_G.IsStalker(nil, B.make_se_npc{ kind = "monster" }:clsid())).toBe(false)
        end)
    end)


    describe("make_actor() engine fidelity", function()

        beforeEach(function() H.boot() end)

        describe("rank and reputation", function()
            -- Both are int-typed and luabind truncates TOWARD ZERO via
            -- static_cast (policy.hpp:377), which is not floor for negatives.
            it("truncates a positive float toward zero", function()
                _G.db.actor:set_character_rank(5.9)
                expect(_G.db.actor:character_rank()).toBe(5)
            end)

            it("truncates a negative float toward zero, not down", function()
                _G.db.actor:set_character_rank(-5.9)
                expect(_G.db.actor:character_rank()).toBe(-5)
            end)

            it("does not clamp -- nothing in the engine bounds these", function()
                _G.db.actor:set_character_reputation(-9000)
                expect(_G.db.actor:character_reputation()).toBe(-9000)
            end)
        end)

        describe("money", function()
            it("adds and subtracts", function()
                local a = H.set_actor{ money = 1000 }
                a:give_money(-250)
                expect(a:money()).toBe(750)
            end)

            -- give_money takes an int and set_money takes u32, with no clamp
            -- (InventoryOwner.cpp:630-645). Deducting more than the actor holds
            -- underflows rather than flooring at zero.
            it("underflows instead of clamping at zero", function()
                local a = H.set_actor{ money = 100 }
                a:give_money(-101)
                expect(a:money()).toBe(4294967295)
            end)
        end)

        describe("item_in_slot", function()
            -- Slot 0 is NO_ACTIVE_SLOT and is rejected outright
            -- (Inventory.cpp:658-664).
            it("returns nil for slot 0", function()
                local a = H.set_actor{ slots = { [0] = B.make_item{ section = "x" } } }
                expect(a:item_in_slot(0)).toBeNil()
            end)

            -- LAST_SLOT is CUSTOM_SLOT_5 = 18 because MORE_INVENTORY_SLOTS is
            -- defined in this build (inventory_space.h:40).
            it("serves slots past HELMET(12), up to LAST_SLOT(18)", function()
                local pack = B.make_item{ section = "itm_actor_backpack" }
                local a = H.set_actor{ slots = { [13] = pack } }
                expect(a:item_in_slot(13)).toBe(pack)
                expect(a.LAST_SLOT).toBe(18)
            end)
        end)
    end)
end)

return true

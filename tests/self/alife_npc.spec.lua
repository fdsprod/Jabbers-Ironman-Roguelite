-- Self-tests for the NPC side of the alife model. These pin the engine and stock
-- behaviour the trader rep specs depend on.

local H = require("harness.init")

describe("harness/alife NPCs", function()
    local model

    local function sends(name) return H.dispatch.sends_of(name) end

    beforeEach(function()
        H.boot_game()
        model = H.alife
    end)

    describe("a stalker's client object", function()
        it("reports what it was made with", function()
            local npc = level.object_by_id(model.trader{ name = "Owl", rep = 300 })
            expect(npc:character_name()).toBe("Owl")
            expect(npc:character_reputation()).toBe(300)
            expect(npc:character_community()).toBe("trader")
            expect(npc:alive()).toBe(true)
        end)

        -- script_game_object_inventory_owner.cpp:957, luabind policy.hpp:377
        it("truncates a set rep toward zero, because the engine takes an int", function()
            local npc = level.object_by_id(model.trader{ name = "Owl" })
            npc:set_character_reputation(960.4)
            expect(npc:character_reputation()).toBe(960)
            npc:set_character_reputation(-960.4)
            expect(npc:character_reputation()).toBe(-960)
        end)

        it("is neutral to the actor unless told otherwise", function()
            local friendly = level.object_by_id(model.trader{ name = "Owl" })
            local hostile = level.object_by_id(model.trader{ name = "Cat", relation = game_object.enemy })
            expect(friendly:relation(db.actor)).toBe(game_object.neutral)
            expect(hostile:relation(db.actor)).toBe(game_object.enemy)
        end)

        it("is not alive once killed", function()
            local id = model.stalker{ name = "Owl" }
            alife():object(id):kill()
            expect(level.object_by_id(id):alive()).toBe(false)
        end)
    end)

    describe("rep and the server object", function()
        -- InventoryOwner.cpp:471-486
        it("writes the rep through to the server object", function()
            local id = model.trader{ name = "Owl" }
            level.object_by_id(id):set_character_reputation(450)
            expect(alife():object(id):reputation()).toBe(450)
        end)

        it("survives going offline, and a new client reads it back", function()
            local id = model.trader{ name = "Owl" }
            level.object_by_id(id):set_character_reputation(450)
            model.set_online(id, false)
            expect(model.rep_of(id)).toBe(450)
            model.set_online(id, true)
            H.frames(1)
            expect(level.object_by_id(id):character_reputation()).toBe(450)
        end)

        it("answers character_name on the server object", function()
            local id = model.trader{ name = "Owl", online = false }
            expect(alife():object(id):character_name()).toBe("Owl")
        end)
    end)

    describe("db.OnlineStalkers and db.storage", function()
        it("hold an NPC while it is online", function()
            local id = model.stalker{ name = "Owl" }
            expect(db.OnlineStalkers).toEqual({ id })
            expect(db.storage[id].object).toBe(level.object_by_id(id))
        end)

        it("hold nothing for an NPC made offline", function()
            local id = model.stalker{ name = "Owl", online = false }
            expect(db.OnlineStalkers).toEqual({})
            expect(db.storage[id]).toBeNil()
        end)

        it("let go when it goes offline and take it back when it returns", function()
            local id = model.stalker{ name = "Owl" }
            model.set_online(id, false)
            expect(db.OnlineStalkers).toEqual({})
            expect(db.storage[id]).toBeNil()
            model.set_online(id, true)
            H.frames(1)
            expect(db.OnlineStalkers).toEqual({ id })
            expect(db.storage[id].object).toBe(level.object_by_id(id))
        end)

        it("leaves db.OnlineStalkers alone when only the storage entry goes", function()
            local id = model.stalker{ name = "Owl" }
            model.drop_storage(id)
            expect(db.OnlineStalkers).toEqual({ id })
            expect(db.storage[id]).toBeNil()
        end)
    end)

    describe("the net callbacks", function()
        -- xr_motivator.script:182
        it("sends npc_on_net_spawn as (npc, se_obj) when a client appears", function()
            local id = model.stalker{ name = "Owl", online = false }
            expect(#sends("npc_on_net_spawn")).toBe(0)
            model.set_online(id, true)
            H.frames(1)
            local sent = sends("npc_on_net_spawn")
            expect(#sent).toBe(1)
            expect(sent[1].args[1]).toBe(level.object_by_id(id))
            expect(sent[1].args[2].id).toBe(id)
        end)

        -- xr_motivator.script:226, ahead of db.del_obj at :258.
        it("sends npc_on_net_destroy as (npc), with the client still working", function()
            local id = model.stalker{ name = "Owl", rep = 70 }
            local client = level.object_by_id(id)
            local seen, stored
            RegisterScriptCallback("npc_on_net_destroy", function(npc)
                seen = npc:character_reputation()
                stored = db.storage[npc:id()]
            end)
            model.set_online(id, false)
            expect(sends("npc_on_net_destroy")[1].args[1]).toBe(client)
            expect(sends("npc_on_net_destroy")[1].n).toBe(1)
            expect(seen).toBe(70)
            expect(stored).toBeDefined()
        end)

        it("does not send them for an item", function()
            H.define("medkit", {})
            model.give(db.actor, "medkit")
            expect(#sends("npc_on_net_spawn")).toBe(0)
        end)
    end)

    describe("a save and reload", function()
        it("brings an online NPC back with a new client and a spawn callback", function()
            local id = model.trader{ name = "Owl", rep = 80 }
            H.save()
            H.reload()
            expect(level.object_by_id(id)).toBeNil()
            expect(db.OnlineStalkers).toEqual({})
            H.frames(1)
            expect(level.object_by_id(id):character_reputation()).toBe(80)
            expect(db.OnlineStalkers).toEqual({ id })
            expect(#sends("npc_on_net_spawn")).toBe(1)
        end)

        it("leaves an offline NPC offline", function()
            local id = model.trader{ name = "Owl", rep = 80, online = false }
            H.save()
            H.reload()
            H.frames(1)
            expect(level.object_by_id(id)).toBeNil()
            expect(model.rep_of(id)).toBe(80)
        end)

        it("keeps who the player has met", function()
            local id = model.trader{ name = "Owl" }
            model.meet(id)
            H.save()
            H.reload()
            expect(alife_storage_manager.get_state().actor_contacts[id]).toBe(true)
        end)

        it("keeps the story id of an offline NPC", function()
            local id = model.trader{ name = "Owl", online = false, story_id = "esc_m_trader" }
            H.save()
            H.reload()
            expect(story_objects.object_id_by_story_id.esc_m_trader).toBe(id)
        end)
    end)

    describe("utils_obj.is_trader()", function()
        local function fake_ini(has_trade)
            return {
                section_exist = function() return true end,
                line_exist    = function(_, _, key) return has_trade and key == "trade" end,
            }
        end

        it("says yes to the trader community", function()
            local npc = level.object_by_id(model.stalker{ community = "trader" })
            expect(utils_obj.is_trader(npc)).toBe(true)
        end)

        it("says yes to a section containing trader", function()
            local npc = level.object_by_id(model.stalker{ section = "esc_m_trader" })
            expect(utils_obj.is_trader(npc)).toBe(true)
        end)

        it("says yes when the active logic section has a trade line", function()
            local npc = level.object_by_id(model.stalker{ ini = fake_ini(true), section_logic = "logic" })
            expect(utils_obj.is_trader(npc)).toBe(true)
        end)

        it("says no when the logic section has no trade line", function()
            local npc = level.object_by_id(model.stalker{ ini = fake_ini(false), section_logic = "logic" })
            expect(utils_obj.is_trader(npc)).toBe(false)
        end)

        it("says no to a plain stalker", function()
            local npc = level.object_by_id(model.stalker{})
            expect(utils_obj.is_trader(npc)).toBe(false)
        end)

        -- utils_obj.script:84 indexes db.storage[id] without a check.
        it("raises for a plain stalker with no db.storage entry", function()
            local id = model.stalker{}
            local npc = level.object_by_id(id)
            model.drop_storage(id)
            expect(pcall(utils_obj.is_trader, npc)).toBe(false)
        end)

        it("does not need db.storage for the trader community", function()
            local id = model.trader{}
            local npc = level.object_by_id(id)
            model.drop_storage(id)
            expect(utils_obj.is_trader(npc)).toBe(true)
        end)
    end)

    describe("H.new_life()", function()
        it("builds the world before the first update", function()
            local order = {}
            H.new_life{
                before_first_update = function()
                    order[#order + 1] = "world"
                    RegisterScriptCallback("actor_on_first_update", function()
                        order[#order + 1] = "first_update"
                    end)
                end,
            }
            expect(order).toEqual({ "world", "first_update" })
        end)

        it("gives a recreated trader a different id", function()
            local first = model.trader{ name = "Owl" }
            local second
            H.new_life{ before_first_update = function() second = model.trader{ name = "Owl" } end }
            expect(second).never.toBe(first)
        end)
    end)
end)

return true

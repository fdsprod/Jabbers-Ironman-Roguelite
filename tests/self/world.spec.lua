-- Harness self-test: the item/container world model.
--
-- The deferred-mutation specs below are the load-bearing ones. If the model
-- ever silently starts snapshotting or applying immediately, item-placement
-- assertions in every scenario spec become claims about behavior the game does
-- not have.

local H = require("harness.init")
local world = H.world

describe("harness/world", function()

    local actor

    beforeEach(function()
        H.boot()
        actor = _G.db.actor
    end)

    describe("give()", function()
        describe("given a section and container", function()
            it("places the item there", function()
                local ak = world.give("actor", "wpn_ak74")
                expect(world.where(ak)).toBe("actor")
            end)

            it("shows up in contents()", function()
                world.give("actor", "wpn_ak74")
                world.give("actor", "medkit")
                expect(world.contents("actor")).toEqual({ "wpn_ak74", "medkit" })
            end)

            it("gives the item the engine accessors the mod calls", function()
                local ak = world.give("actor", "wpn_ak74", { condition = 0.8 })
                expect(ak:section()).toBe("wpn_ak74")
                expect(ak:condition()).toBeCloseTo(0.8)
                expect(ak:id()).toBeType("number")
            end)
        end)
    end)

    describe("iterate_inventory()", function()

        describe("given several items", function()
            it("visits each one", function()
                world.give("actor", "a"); world.give("actor", "b")
                local seen = {}
                actor:iterate_inventory(function(_, item)
                    seen[#seen + 1] = item:section()
                end)
                expect(seen).toEqual({ "a", "b" })
            end)
        end)

        describe("given the callback returns true", function()
            it("stops early, matching IterateInventory", function()
                world.give("actor", "a"); world.give("actor", "b")
                local seen = {}
                actor:iterate_inventory(function(_, item)
                    seen[#seen + 1] = item:section()
                    return true
                end)
                expect(seen).toEqual({ "a" })
            end)
        end)
    end)

    describe("deferred mutation", function()
        -- The engine walks the LIVE m_all container with raw iterators
        -- (script_game_object_inventory_owner.cpp:266), which is only safe
        -- because transfer_item sends GE_TRADE_* network events and
        -- alife_release queues an alife release -- both land on a later frame.

        describe("given alife_release is called inside the loop", function()
            it("leaves the item visible for the rest of that loop", function()
                -- If this fails, the model applied the removal immediately or
                -- snapshotted -- either way it no longer matches the engine.
                world.give("actor", "a")
                world.give("actor", "b")
                world.give("actor", "c")

                local seen = {}
                actor:iterate_inventory(function(_, item)
                    seen[#seen + 1] = item:section()
                    alife_release(item)          -- release every item as we go
                end)

                expect(seen).toEqual({ "a", "b", "c" })
            end)

            it("still holds the items until the next tick", function()
                local a = world.give("actor", "a")
                alife_release(a)
                expect(world.where(a)).toBe("actor")
            end)

            it("removes them once ticked", function()
                local a = world.give("actor", "a")
                alife_release(a)
                H.tick()
                expect(world.where(a)).toBeNil()
            end)

            it("reports them as destroyed", function()
                world.give("actor", "a")
                alife_release(world.item_by_section("a"))
                H.tick()
                expect(world.destroyed()).toEqual({ "a" })
            end)
        end)

        describe("given transfer_item is called inside the loop", function()
            it("does not move anything until the tick", function()
                world.container("stash")
                local a = world.give("actor", "a")
                actor:transfer_item(a, "stash")
                expect(world.where(a)).toBe("actor")
            end)

            it("moves everything on the tick", function()
                local stash = world.container("stash")
                world.give("actor", "a"); world.give("actor", "b")

                actor:iterate_inventory(function(_, item)
                    actor:transfer_item(item, stash)
                end)
                H.tick()

                expect(world.contents("stash")).toEqual({ "a", "b" })
                expect(world.contents("actor")).toEqual({})
            end)
        end)

        describe("given an item is both transferred and released", function()
            it("applies them in queue order, so the release wins", function()
                world.container("stash")
                local a = world.give("actor", "a")
                actor:transfer_item(a, "stash")
                alife_release(a)
                H.tick()
                expect(world.where(a)).toBeNil()
            end)
        end)
    end)

    describe("containers", function()
        describe("given an empty container", function()
            it("reports itself empty", function()
                local box = world.container("stash")
                expect(box:is_inv_box_empty()).toBeTruthy()
            end)
        end)

        describe("given a container with items", function()
            it("reports itself non-empty", function()
                local box = world.container("stash")
                world.give("stash", "a")
                expect(box:is_inv_box_empty()).toBeFalsy()
            end)

            it("iterates its contents", function()
                local box = world.container("stash")
                world.give("stash", "a"); world.give("stash", "b")
                local seen = {}
                box:iterate_inventory_box(function(_, item)
                    seen[#seen + 1] = item:section()
                end)
                expect(seen).toEqual({ "a", "b" })
            end)
        end)
    end)

    describe("alife_create()", function()
        describe("given a section", function()
            it("returns a server object with an id", function()
                local se = alife_create("inv_backpack", actor:position(), 1, 1)
                expect(se.id).toBeType("number")
                expect(se.section).toBe("inv_backpack")
            end)

            it("makes it findable via level.object_by_id", function()
                local se = alife_create("inv_backpack", actor:position(), 1, 1)
                expect(level.object_by_id(se.id)).toBeDefined()
            end)

            it("records the creation for assertion", function()
                alife_create("inv_backpack", actor:position(), 1, 1)
                expect(world.created).toHaveLength(1)
            end)
        end)
    end)

    describe("hide()", function()
        -- Exercises the "stash is not online yet" retry in
        -- HandleItemsAndRespawn (soulslike_scenarios.script:536).
        describe("given a created object is hidden", function()
            it("becomes invisible to level.object_by_id", function()
                local se = alife_create("inv_backpack", actor:position(), 1, 1)
                world.hide(se.id)
                expect(level.object_by_id(se.id)).toBeNil()
            end)

            it("reappears when revealed", function()
                local se = alife_create("inv_backpack", actor:position(), 1, 1)
                world.hide(se.id)
                world.reveal(se.id)
                expect(level.object_by_id(se.id)).toBeDefined()
            end)
        end)
    end)

    describe("alife():set_switch_online() / set_switch_offline() / teleport_object()", function()
        -- Recording these calls (rather than modeling them as no-ops) is
        -- what lets a spec assert "forces the stash online" for real, instead
        -- of only checking the stash exists.
        describe("set_switch_online()", function()
            it("records the call", function()
                local se = alife_create("hidden_box", actor:position(), 1, 1)
                world.hide(se.id)
                alife():set_switch_online(se.id, true)
                expect(H.fakes.call_count("alife.set_switch_online")).toBe(1)
                local call = H.fakes.last_call("alife.set_switch_online")
                expect(call[2]).toBe(se.id)
                expect(call[3]).toBe(true)
            end)

            it("makes a hidden object findable via level.object_by_id again", function()
                local se = alife_create("hidden_box", actor:position(), 1, 1)
                world.hide(se.id)
                alife():set_switch_online(se.id, true)
                expect(level.object_by_id(se.id)).toBeDefined()
            end)
        end)

        describe("set_switch_offline()", function()
            -- The real engine call is a flag setter, not an immediate action
            -- (CALifeUpdateManager::set_switch_offline,
            -- alife_update_manager.cpp:333-345): passing true only
            -- re-enables ELIGIBILITY for future distance-based offlining
            -- (CSE_ALifeDynamicObject::try_switch_offline,
            -- alife_dynamic_object.cpp:166-181), it does not force the
            -- object offline on the spot. The harness has no distance model
            -- to act on that eligibility, so this is a recorded no-op.
            it("does not hide the object when passed true", function()
                local se = alife_create("hidden_box", actor:position(), 1, 1)
                alife():set_switch_offline(se.id, true)
                expect(level.object_by_id(se.id)).toBeDefined()
            end)

            -- Passing false is the actual "pin online forever" mechanism: it
            -- makes can_switch_offline() return false, so try_switch_online's
            -- fast path force-onlines the object with no distance check, and
            -- try_switch_offline's first check refuses to ever offline it
            -- again (alife_dynamic_object.cpp:130-181). RFDetectorSoulslike
            -- ScenarioLogic:CreateStash calls this right after forcing it
            -- online (soulslike_scenarios.script:1441) -- it must not undo
            -- the online request.
            it("leaves it visible when passed false", function()
                local se = alife_create("hidden_box", actor:position(), 1, 1)
                alife():set_switch_online(se.id, true)
                alife():set_switch_offline(se.id, false)
                expect(level.object_by_id(se.id)).toBeDefined()
            end)

            it("marks the server object pinned online", function()
                local se = alife_create("hidden_box", actor:position(), 1, 1)
                alife():set_switch_offline(se.id, false)
                expect(se.pinned_online).toBe(true)
            end)
        end)

        describe("teleport_object()", function()
            it("moves the server object's position and vertex ids", function()
                local se = alife_create("hidden_box", actor:position(), 1, 1)
                local new_pos = require("harness.builders").make_vector({ x = 10, y = 0, z = 20 })
                alife():teleport_object(se.id, 5, 7, new_pos)
                expect(se.m_game_vertex_id).toBe(5)
                expect(se.m_level_vertex_id).toBe(7)
                expect(se.position).toBe(new_pos)
            end)
        end)
    end)

    describe("alife_create_item()", function()
        describe("given an owner", function()
            it("puts the item in that owner's container", function()
                alife_create_item("bread", actor)
                expect(world.contents("actor")).toContain("bread")
            end)

            -- Must be the SERVER object. RFDetectorSoulslikeScenarioLogic keys
            -- note_message_data by se_note.id (soulslike_scenarios.script:1400);
            -- handing back a client object makes `.id` a function and silently
            -- produces a function-keyed table that nothing can ever look up.
            it("returns a server object whose id is a field", function()
                local se = alife_create_item("bread", actor)
                expect(se.id).toBeType("number")
            end)

            it("shares its id with the client object", function()
                local se = alife_create_item("bread", actor)
                expect(level.object_by_id(se.id):section()).toBe("bread")
            end)
        end)
    end)

    describe("alife():register()", function()
        -- register() frees the object handed to it and returns a NEW pointer
        -- (alife_simulator_script.cpp:396-413). Modelled by swapping in a fresh
        -- table, so a spec reusing the old reference sees it go stale.
        describe("given an unregistered object", function()
            it("returns a different object", function()
                local se = alife_create("wpn_ak74", actor:position(), 1, 1, actor:id(), false)
                expect(alife():register(se)).never.toBe(se)
            end)

            it("marks it registered", function()
                local se = alife_create("wpn_ak74", actor:position(), 1, 1, actor:id(), false)
                expect(alife():register(se).registered).toBe(true)
            end)

            it("keeps the same id", function()
                local se = alife_create("wpn_ak74", actor:position(), 1, 1, actor:id(), false)
                expect(alife():register(se).id).toBe(se.id)
            end)

            it("replaces what alife():object() returns", function()
                local se = alife_create("wpn_ak74", actor:position(), 1, 1, actor:id(), false)
                local fresh = alife():register(se)
                expect(alife():object(se.id)).toBe(fresh)
            end)

            it("records the call", function()
                local se = alife_create("wpn_ak74", actor:position(), 1, 1, actor:id(), false)
                alife():register(se)
                expect(world.registered).toEqual({ se.id })
            end)
        end)
    end)

    describe("alife_create() with a register flag", function()
        describe("given register = false", function()
            it("records the object as unregistered", function()
                alife_create("wpn_ak74", actor:position(), 1, 1, actor:id(), false)
                expect(world.created[1].registered).toBe(false)
            end)

            it("records the parent id", function()
                alife_create("wpn_ak74", actor:position(), 1, 1, actor:id(), false)
                expect(world.created[1].parent_id).toBe(actor:id())
            end)
        end)

        describe("given the flag is omitted", function()
            it("registers by default", function()
                alife_create("inv_backpack", actor:position(), 1, 1)
                expect(world.created[1].registered).toBe(true)
            end)
        end)
    end)

    describe("squads", function()
        -- SpawnAmbush creates the squad object itself and then iterates
        -- squad_members() (soulslike_scenarios.script:763), so members cannot be
        -- supplied the way world.container's can.
        describe("given a section registered in world.squads", function()
            beforeEach(function()
                world.squads["simulation_boar"] = {
                    { kind = "monster", section = "boar_weak" },
                    { kind = "monster", section = "boar_normal" },
                }
            end)

            it("gives the created object iterable members", function()
                local se = alife_create("simulation_boar", actor:position(), 1, 1)
                local seen = {}
                for m in se:squad_members() do seen[#seen + 1] = m:section_name() end
                expect(seen).toEqual({ "boar_weak", "boar_normal" })
            end)

            it("exposes create_npc as a recorder", function()
                local se = alife_create("simulation_boar", actor:position(), 1, 1)
                se:create_npc(se.id)
                expect(H.fakes.call_count("se.create_npc")).toBe(1)
            end)

            it("makes each member reachable through alife():object()", function()
                local se = alife_create("simulation_boar", actor:position(), 1, 1)
                for m in se:squad_members() do
                    expect(alife():object(m.id)).toBe(m)
                end
            end)
        end)

        describe("given an unregistered section", function()
            it("yields no members", function()
                local se = alife_create("simulation_flesh", actor:position(), 1, 1)
                local n = 0
                for _ in se:squad_members() do n = n + 1 end
                expect(n).toBe(0)
            end)
        end)
    end)

    describe("spawn_se_npc()", function()
        -- find_closest_enemy / _enemy_mutant scan sim:object(i) for i in
        -- 1..65534 (soulslike.script:300). Ids start at 10000, inside that range.
        it("is reachable through alife():object()", function()
            local se = world.spawn_se_npc{ kind = "monster" }
            expect(alife():object(se.id)).toBe(se)
        end)

        it("is found by a scan over the alife id range", function()
            local se = world.spawn_se_npc{ kind = "monster" }
            local found = nil
            for i = 1, 65534 do
                local o = alife():object(i)
                if o and o.id == se.id then found = o break end
            end
            expect(found).toBe(se)
        end)
    end)
end)

return true

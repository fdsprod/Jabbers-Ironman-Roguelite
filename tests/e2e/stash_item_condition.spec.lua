-- The same trap as item uses, for condition.
--
-- A stash item's condition was read from the server object. Only weapons, outfits and
-- helmets send condition back to it (Weapon.cpp:738, CustomOutfit.cpp:51,
-- ActorHelmet.cpp:89). For anything else, the 124 weapon parts among them, the server
-- object keeps what the item spawned with and bind_item tracks the live value itself
-- (bind_item.script:16, :191-192).

local H = require("harness.init")

describe("stash item condition across lives", function()
    local model

    local function open_restored()
        local se = model.all_stashes("placeable_case")[1]
        model.set_online(se.id, true)
        H.frames(1)
        local box = level.object_by_id(se.id)
        H.open_stash(box)
        H.frames(3)
        return box
    end

    local function condition_in(box, section)
        for _, se in ipairs(model.contents(box:id())) do
            if se.section == section then return level.object_by_id(se.id):condition() end
        end
    end

    beforeEach(function()
        H.boot_game()
        model = H.alife
        model.set_mcm("stash_item_condition_loss_percent", 0)
        H.define("placeable_case", { kind = "invbox" })
        H.define("prt_w_barrel_1", { use_condition = true, script_binding = "bind_item.bind" })
        H.define("wpn_ak74", { kind = "weapon" })
    end)

    describe("given a weapon part, which never syncs condition to the server", function()
        local function worn_part()
            local box = model.stash("placeable_case")
            local part = model.give(box, "prt_w_barrel_1")
            part:set_condition(0.4)
            H.frames(2)
            return box
        end

        it("keeps its condition from a stash online at death", function()
            worn_part()
            H.die()
            H.new_life()
            expect(condition_in(open_restored(), "prt_w_barrel_1")).toBe(0.4)
        end)

        it("keeps its condition from a stash offline at death", function()
            local box = worn_part()
            H.save()
            model.set_online(box:id(), false)
            H.die()
            H.new_life()
            expect(condition_in(open_restored(), "prt_w_barrel_1")).toBe(0.4)
        end)
    end)

    describe("given a weapon, which does sync condition to the server", function()
        local function worn_weapon()
            local box = model.stash("placeable_case")
            local rifle = model.give(box, "wpn_ak74")
            rifle:set_condition(0.6)
            H.frames(2)
            return box
        end

        it("keeps its condition from a stash online at death", function()
            worn_weapon()
            H.die()
            H.new_life()
            expect(condition_in(open_restored(), "wpn_ak74")).toBe(0.6)
        end)

        it("keeps its condition from a stash offline at death", function()
            local box = worn_weapon()
            model.set_online(box:id(), false)
            H.die()
            H.new_life()
            expect(condition_in(open_restored(), "wpn_ak74")).toBe(0.6)
        end)
    end)

    describe("given a device, whose condition item_device tracks", function()
        -- item_device.script:22, shared the same way (:379-385). The script needs too
        -- much of the game to load, so the table is seeded directly.
        it("reads it for a device in an offline stash", function()
            H.define("detector_simple", { use_condition = true })
            local box = model.stash("placeable_case")
            local _, se = model.give(box, "detector_simple")
            alife_storage_manager.get_state().device_condition = { [se.id] = 0.3 }
            model.set_online(box:id(), false)
            expect(roguelite_manager.serialize_item(se).condition).toBe(0.3)
        end)
    end)
end)

return true

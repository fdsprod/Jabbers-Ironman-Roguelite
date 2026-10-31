-- The reported bug: "Everytime I start a new life, repair kits, matches, vodka any
-- consumable really, just resets to full uses in every stash. Sometimes there is
-- like 1 or 2 items where it is correct".
--
-- Each journey plays the real path: put a used item in a stash, die, start a new
-- life, open the stash, and read the uses off the item that spawned.

local H = require("harness.init")

describe("stash item uses across lives", function()
    local model

    -- The stash of this section as it came back in the new life, opened, with its
    -- contents spawned.
    local function open_restored(section)
        local se = model.all_stashes(section or "placeable_case")[1]
        model.set_online(se.id, true)
        H.frames(1)
        local box = level.object_by_id(se.id)
        H.open_stash(box)
        H.frames(3)
        return box
    end

    beforeEach(function()
        H.boot_game()
        model = H.alife
        H.define("vodka", { max_uses = 3 })
        H.define("box_matches", { max_uses = 5, remove_after_use = false })
        H.define("placeable_case", { kind = "invbox" })
        H.define("placeable_fridge", { kind = "invbox" })
    end)

    describe("given a stash the actor died close to", function()
        it("keeps the uses", function()
            local box = model.stash("placeable_case")
            model.give(box, "vodka", { uses = 1 })
            H.frames(2)
            H.die()
            H.new_life()
            expect(model.uses_in_box(open_restored():id(), "vodka")).toEqual({ 1 })
        end)
    end)

    describe("given a stash that was offline when the actor died", function()
        local function die_with_offline_stash(uses)
            local box = model.stash("placeable_case")
            model.give(box, "vodka", { uses = uses })
            H.frames(2)
            H.save()
            model.set_online(box:id(), false)
            H.die()
            H.new_life()
        end

        it("keeps the uses", function()
            die_with_offline_stash(1)
            expect(model.uses_in_box(open_restored():id(), "vodka")).toEqual({ 1 })
        end)

        it("still gives a never-used item its full uses", function()
            die_with_offline_stash(3)
            expect(model.uses_in_box(open_restored():id(), "vodka")).toEqual({ 3 })
        end)
    end)

    describe("given one stash online and one offline, as in the report", function()
        it("keeps the uses in both", function()
            local near = model.stash("placeable_case")
            local far = model.stash("placeable_fridge")
            model.give(near, "vodka", { uses = 1 })
            model.give(far, "vodka", { uses = 2 })
            H.frames(2)
            H.save()
            model.set_online(far:id(), false)
            H.die()
            H.new_life()
            expect(model.uses_in_box(open_restored("placeable_case"):id(), "vodka")).toEqual({ 1 })
            expect(model.uses_in_box(open_restored("placeable_fridge"):id(), "vodka")).toEqual({ 2 })
        end)
    end)

    describe("given an offline stash in a game that was loaded from a save", function()
        it("keeps the uses", function()
            local box = model.stash("placeable_case")
            local box_id = box:id()
            model.give(box, "vodka", { uses = 1 })
            H.frames(2)
            H.save()
            H.reload()
            H.frames(2)
            model.set_online(box_id, false)
            H.die()
            H.new_life()
            expect(model.uses_in_box(open_restored():id(), "vodka")).toEqual({ 1 })
        end)
    end)

    describe("given no save or load yet this session", function()
        -- bind_item's table is unreachable here (see self/alife.spec.lua), so the
        -- only record is what the mod noted when the item went into the box.
        it("keeps the uses of an item the player put in the stash", function()
            local box = model.stash("placeable_case")
            local item = model.give(db.actor, "vodka", { uses = 1 })
            H.frames(1)
            model.put_in_box(item, box)
            model.set_online(box:id(), false)
            H.die()
            H.new_life()
            expect(model.uses_in_box(open_restored():id(), "vodka")).toEqual({ 1 })
        end)
    end)

    describe("given an item whose uses changed after it went in the stash", function()
        -- ui_workshop and item_cooking consume from a stash directly. The note taken
        -- at put-in time is older than the live object and must not beat it.
        it("keeps the live value, not the older note", function()
            local box = model.stash("placeable_case")
            local item = model.give(db.actor, "vodka", { uses = 3 })
            H.frames(1)
            model.put_in_box(item, box)
            item:set_remaining_uses(1)
            H.frames(1)
            H.die()
            H.new_life()
            expect(model.uses_in_box(open_restored():id(), "vodka")).toEqual({ 1 })
        end)
    end)

    describe("given a stash never opened in the second life", function()
        it("keeps the uses through a third life", function()
            local box = model.stash("placeable_case")
            model.give(box, "vodka", { uses = 1 })
            H.frames(2)
            H.die()
            H.new_life()
            H.die()
            H.new_life()
            expect(model.uses_in_box(open_restored():id(), "vodka")).toEqual({ 1 })
        end)
    end)

    describe("given a stash opened in the second life", function()
        local function third_life(prepare)
            local box = model.stash("placeable_case")
            model.give(box, "vodka", { uses = 1 })
            H.frames(2)
            H.die()
            H.new_life()
            local opened = open_restored()
            if prepare then prepare() end
            model.set_online(opened:id(), false)
            H.die()
            H.new_life()
            return model.uses_in_box(open_restored():id(), "vodka")
        end

        it("keeps the uses through a third life once it has gone offline", function()
            expect(third_life(function() H.save() end)).toEqual({ 1 })
        end)

        it("keeps the uses with no save since it was opened", function()
            expect(third_life()).toEqual({ 1 })
        end)
    end)

    describe("given an item with no uses left that is not removed when empty", function()
        it("stays empty rather than refilling", function()
            local box = model.stash("placeable_case")
            model.give(box, "box_matches", { uses = 0 })
            H.frames(2)
            H.die()
            H.new_life()
            expect(model.uses_in_box(open_restored():id(), "box_matches")).toEqual({ 0 })
        end)
    end)

    -- The reporter asked whether 300kg of stash was the cause. The engine says no
    -- limit applies: SPAWN_ANTIFREEZE is off (build_config_defines.h:28), so every
    -- spawn lands in one ProcessGameEvents pass.
    describe("given a very large stash", function()
        local COUNT = 400

        local function fill_and_die(go_offline)
            local box = model.stash("placeable_case")
            for _ = 1, COUNT do model.give(box, "vodka", { uses = 2 }) end
            H.frames(2)
            H.save()
            if go_offline then model.set_online(box:id(), false) end
            H.die()
            H.new_life()
        end

        local function count_with_uses(uses, list)
            local n = 0
            for _, v in ipairs(list) do if v == uses then n = n + 1 end end
            return n
        end

        it("restores every item's uses when the stash was online", function()
            fill_and_die(false)
            local list = model.uses_in_box(open_restored():id(), "vodka")
            expect(count_with_uses(2, list)).toBe(COUNT)
        end)

        it("restores every item's uses when the stash was offline", function()
            fill_and_die(true)
            local list = model.uses_in_box(open_restored():id(), "vodka")
            expect(count_with_uses(2, list)).toBe(COUNT)
        end)
    end)

    -- ItemProcessor gives up on an id about 12 updates after it was queued with no
    -- client object (itms_manager.script:1420-1427). The spawn latency is a GUESS
    -- and is well under that in a normal game, so this is a stress case. Uses must
    -- not depend on winning that race.
    describe("given client objects that take longer than ItemProcessor waits", function()
        it("still restores the uses", function()
            local box = model.stash("placeable_case")
            model.give(box, "vodka", { uses = 1 })
            H.frames(2)
            H.die()
            H.new_life()
            H.save()
            local se = model.all_stashes("placeable_case")[1]
            model.set_online(se.id, true)
            H.frames(1)
            model.spawn_latency_frames = 40
            local opened = level.object_by_id(se.id)
            H.open_stash(opened)
            H.frames(45)
            expect(model.uses_in_box(opened:id(), "vodka")).toEqual({ 1 })
        end)
    end)
end)

return true

-- Which stash items lose condition between lives.
--
-- A clsid is the ordinal of a class in a sorted registry
-- (object_factory_script.cpp:94), so one saved in the state file can name a different
-- class once the modlist changes. The modlist change is simulated by rewriting the
-- state file between the death and the next life.
--
-- The restore skips any section with no `class` in its config, so every section here
-- declares the one it has in the stock configs (w_ak74.ltx:11, o_novice.ltx:5,
-- o_helmet.ltx:8, items_parts.ltx:23, m_binoc.ltx:13). MCM is reset by new_life, so
-- the loss is the 1% default (roguelite_module_stashes.script:46).

local H = require("harness.init")

local STATE_FILE = "appdata\\roguelite_stalker.state"

describe("stash item condition loss across lives", function()
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

    -- Dies with these items in a stash, each at the given condition.
    local function die_with(conditions)
        local box = model.stash("placeable_case")
        for section, condition in pairs(conditions) do
            local item = model.give(box, section)
            item:set_condition(condition)
        end
        H.frames(2)
        H.die()
    end

    -- Rewrites saved clsids to read as another kind, by section.
    local function make_stale(kinds)
        local data = marshal.decode(model.files[STATE_FILE])
        local want, changed = 0, 0
        for _ in pairs(kinds) do want = want + 1 end
        for _, stash in pairs(data.stashes) do
            for _, item in pairs(stash.items) do
                local kind = kinds[item.section]
                if kind then
                    local stale = H.fakes.clsid_for(kind)
                    assert(item.clsid ~= stale, "clsid of " .. item.section .. " is not stale")
                    item.clsid = stale
                    changed = changed + 1
                end
            end
        end
        assert(changed == want, "expected to rewrite " .. want .. " items, got " .. changed)
        model.files[STATE_FILE] = marshal.encode(data)
    end

    -- restore_item refuses to spawn wpn_binoc_inv (roguelite_manager.script:335), so
    -- its condition can't be read off an item. An unopened stash writes its data back
    -- at the next death (roguelite_module_stashes.script:223-226), which can be read.
    local function condition_saved_at_next_death(section)
        H.die()
        local data = marshal.decode(model.files[STATE_FILE])
        for _, stash in pairs(data.stashes) do
            for _, item in pairs(stash.items) do
                if item.section == section then return item.condition end
            end
        end
    end

    beforeEach(function()
        H.boot_game()
        model = H.alife
        H.define("placeable_case", { kind = "invbox" })
        H.define("wpn_ak74", { kind = "weapon", class = "WP_AK74" })
        H.define("novice_outfit", { kind = "outfit", class = "EQU_STLK" })
        H.define("helm_respirator", { kind = "headgear", class = "E_HLMET" })
        -- Non-multiuse, unlike a medkit (items_medical.ltx:77), whose condition is
        -- forced to 1 when it spawns (eatable_item.cpp:83-89).
        H.define("prt_w_barrel_1", { class = "II_ATTCH", use_condition = true, script_binding = "bind_item.bind" })
        -- WP_BINOC is wpn_binocular_s (class_registrator.script:76), which is not in
        -- IsWeapon's table (_g.script:3085-3120). So no Is* predicate claims this kind.
        H.define("wpn_binoc_inv", { kind = "binoc", class = "WP_BINOC" })
        -- A plain item to the Is* predicates, so only its section makes it degrade.
        -- items_devices.ltx:198, :202, and :10 for the binding it inherits.
        H.define("detector_simple", { class = "DET_SIMP", use_condition = true, script_binding = "item_device.bind" })
    end)

    describe("given clsids that are still right", function()
        it("degrades a weapon", function()
            die_with({ wpn_ak74 = 0.6 })
            H.new_life()
            expect(condition_in(open_restored(), "wpn_ak74")).toBeCloseTo(0.594)
        end)

        it("does not degrade a plain item", function()
            die_with({ prt_w_barrel_1 = 0.4 })
            H.new_life()
            expect(condition_in(open_restored(), "prt_w_barrel_1")).toBeCloseTo(0.4)
        end)

        it("does not degrade wpn_binoc_inv", function()
            die_with({ wpn_binoc_inv = 0.8, wpn_ak74 = 0.6 })
            H.new_life()
            expect(condition_saved_at_next_death("wpn_binoc_inv")).toBeCloseTo(0.8)
            -- The same read does see the loss on an item that takes it.
            expect(condition_saved_at_next_death("wpn_ak74")).toBeCloseTo(0.594)
        end)

        it("degrades a device", function()
            die_with({ detector_simple = 0.7 })
            H.new_life()
            expect(condition_in(open_restored(), "detector_simple")).toBeCloseTo(0.693)
        end)

        -- No stock config gives it such a class, and all the GAMMA overrides of it keep
        -- WP_BINOC, so this pins the exclusion for a modlist that does.
        it("does not degrade wpn_binoc_inv saved as a weapon", function()
            H.define("wpn_binoc_inv", { kind = "weapon", class = "WP_AK74" })
            die_with({ wpn_binoc_inv = 0.8 })
            H.new_life()
            expect(condition_saved_at_next_death("wpn_binoc_inv")).toBeCloseTo(0.8)
        end)

        -- The class check is what skips a section this modlist no longer configures.
        it("does not degrade a section with no class", function()
            H.define("wpn_no_class", { kind = "weapon" })
            die_with({ wpn_no_class = 0.6 })
            H.new_life()
            expect(condition_in(open_restored(), "wpn_no_class")).toBeCloseTo(0.6)
        end)
    end)

    describe("given a saved clsid that went stale when the modlist changed", function()
        -- FIXES: the restore decided from the clsid saved last life, so a modlist change
        -- spared the items that should degrade and degraded the ones that shouldn't.
        it("still degrades a weapon whose clsid now reads as an artefact", function()
            die_with({ wpn_ak74 = 0.6 })
            make_stale({ wpn_ak74 = "artefact" })
            H.new_life()
            expect(condition_in(open_restored(), "wpn_ak74")).toBeCloseTo(0.594)
        end)

        it("still degrades an outfit whose clsid now reads as an artefact", function()
            die_with({ novice_outfit = 0.7 })
            make_stale({ novice_outfit = "artefact" })
            H.new_life()
            expect(condition_in(open_restored(), "novice_outfit")).toBeCloseTo(0.693)
        end)

        it("still degrades a headgear item whose clsid now reads as an artefact", function()
            die_with({ helm_respirator = 0.5 })
            make_stale({ helm_respirator = "artefact" })
            H.new_life()
            expect(condition_in(open_restored(), "helm_respirator")).toBeCloseTo(0.495)
        end)

        it("does not degrade a plain item whose clsid now reads as a weapon", function()
            die_with({ prt_w_barrel_1 = 0.4 })
            make_stale({ prt_w_barrel_1 = "weapon" })
            H.new_life()
            expect(condition_in(open_restored(), "prt_w_barrel_1")).toBeCloseTo(0.4)
        end)

        -- The section check only guarded the weapon branch.
        it("does not degrade wpn_binoc_inv whose clsid now reads as an outfit", function()
            die_with({ wpn_binoc_inv = 0.8 })
            make_stale({ wpn_binoc_inv = "outfit" })
            H.new_life()
            expect(condition_saved_at_next_death("wpn_binoc_inv")).toBeCloseTo(0.8)
        end)

        it("does not degrade wpn_binoc_inv whose clsid now reads as a weapon", function()
            die_with({ wpn_binoc_inv = 0.8 })
            make_stale({ wpn_binoc_inv = "weapon" })
            H.new_life()
            expect(condition_saved_at_next_death("wpn_binoc_inv")).toBeCloseTo(0.8)
        end)
    end)

    -- save_stash hands the items of an unopened stash straight to the next state file
    -- (roguelite_module_stashes.script:223-226), so the decision has to survive that.
    describe("given a stash left unopened over several lives, with a stale clsid", function()
        it("degrades a weapon once per life", function()
            die_with({ wpn_ak74 = 0.6 })
            make_stale({ wpn_ak74 = "artefact" })
            H.new_life()
            H.die()
            H.new_life()
            expect(condition_in(open_restored(), "wpn_ak74")).toBeCloseTo(0.58806)
        end)

        it("does not degrade a plain item in any life", function()
            die_with({ prt_w_barrel_1 = 0.4 })
            make_stale({ prt_w_barrel_1 = "weapon" })
            H.new_life()
            H.die()
            H.new_life()
            expect(condition_in(open_restored(), "prt_w_barrel_1")).toBeCloseTo(0.4)
        end)

        -- A save moves the items through the marshal table and back.
        it("keeps the decision through a save and load in between", function()
            die_with({ wpn_ak74 = 0.6, prt_w_barrel_1 = 0.4 })
            make_stale({ wpn_ak74 = "artefact", prt_w_barrel_1 = "weapon" })
            H.new_life()
            H.save()
            H.reload()
            H.die()
            H.new_life()
            local box = open_restored()
            expect(condition_in(box, "wpn_ak74")).toBeCloseTo(0.58806)
            expect(condition_in(box, "prt_w_barrel_1")).toBeCloseTo(0.4)
        end)
    end)

    describe("given a state file from an older version, with only a clsid to go on", function()
        -- Built by hand, with only the fields serialize_item and save_stash wrote
        -- before this fix (roguelite_manager.script:181-205, :230-290,
        -- roguelite_module_stashes.script:207-212).
        local function old_item(id, section, kind, condition)
            local item = {
                id = id, name = section .. id, section = section,
                clsid = H.fakes.clsid_for(kind),
                condition = condition,
                upgrades = {}, custom_data = "", object_flags = 0, visual_flags = 0,
            }
            if kind == "weapon" then
                item.ammo_current, item.ammo_elapsed, item.ammo_type = 0, 0, 0
                item.weapon_state, item.addon_flags = 0, 0
            end
            return item
        end

        local function new_life_from_old_file(items)
            model.files[STATE_FILE] = marshal.encode({
                stashes_version = 2,
                money = 0,
                stashes = {
                    [77] = {
                        id = 77,
                        section = "placeable_case",
                        position = { x = 0, y = 0, z = 0 },
                        angle = { x = 0, y = 0, z = 0 },
                        level_vertex_id = 1,
                        game_vertex_id = 1,
                        txt = "Stash",
                        is_container = true,
                        items = items,
                    },
                },
            })
            H.new_life()
        end

        it("degrades a weapon", function()
            new_life_from_old_file({ [78] = old_item(78, "wpn_ak74", "weapon", 0.6) })
            expect(condition_in(open_restored(), "wpn_ak74")).toBeCloseTo(0.594)
        end)

        it("degrades an outfit", function()
            new_life_from_old_file({ [78] = old_item(78, "novice_outfit", "outfit", 0.7) })
            expect(condition_in(open_restored(), "novice_outfit")).toBeCloseTo(0.693)
        end)

        it("degrades a headgear item", function()
            new_life_from_old_file({ [78] = old_item(78, "helm_respirator", "headgear", 0.5) })
            expect(condition_in(open_restored(), "helm_respirator")).toBeCloseTo(0.495)
        end)

        it("does not degrade a plain item", function()
            new_life_from_old_file({ [78] = old_item(78, "prt_w_barrel_1", "item", 0.4) })
            expect(condition_in(open_restored(), "prt_w_barrel_1")).toBeCloseTo(0.4)
        end)

        it("does not degrade wpn_binoc_inv saved with a clsid that reads as a weapon", function()
            new_life_from_old_file({ [78] = old_item(78, "wpn_binoc_inv", "weapon", 0.8) })
            expect(condition_saved_at_next_death("wpn_binoc_inv")).toBeCloseTo(0.8)
        end)

        it("degrades a device", function()
            new_life_from_old_file({ [78] = old_item(78, "detector_simple", "item", 0.7) })
            expect(condition_in(open_restored(), "detector_simple")).toBeCloseTo(0.693)
        end)
    end)
end)

return true

-- MCM labels against the localisation tables, in both directions.
--
-- MCM derives an option's on-screen label from its path when the node has no
-- explicit `text`: "ui_mcm_" plus the path with "/" replaced by "_". So
--
--   { id = "allow_weapon_loss", type = "check", val = 1, def = true }
--
-- in group `items` under root `roguelite` needs the string id
-- `ui_mcm_roguelite_items_allow_weapon_loss`. Nothing validates that at load
-- time: game.translate_string returns the raw id on a miss, so a broken entry
-- shows in the menu as the literal string id and nowhere else. Renaming an
-- option id silently breaks its label.
--
-- Checking both directions is what makes a rename obvious -- the new id has no
-- translation AND the old translation is orphaned, so one mistake fails two
-- assertions that point at each other.
--
-- The derivation and the analysis live in harness/mcm_labels.lua, shared with
-- locals.lua so there is one copy. Run `locals.bat` for the same findings as a
-- readable report.
--
-- Every assertion below expects an empty list, and there is no way to make one
-- pass other than fixing the localisation. An earlier version of this file
-- checked findings against four tables of "known broken" string ids in the
-- harness, so adding an id turned a failure into a pass. That is backwards: a
-- test that a caller can switch off by editing data is not testing anything.
-- If a finding ever has to be tolerated, write the reason here, in prose, next
-- to the assertion that tolerates it.

local H = require("harness.init")
local labels = require("harness.mcm_labels")

local result, tree, eng, rus

local function boot()
    H.boot_game{ modules = H.ALL_MODULES }
    eng = H.loader.load_string_table("eng")
    rus = H.loader.load_string_table("rus")
    result, tree = labels.inspect()
end

describe("MCM localisation", function()

    beforeEach(boot)

    describe("the string tables", function()
        it("loads the English table", function()
            expect(eng["ui_mcm_menu_roguelite"]).toBe(true)
        end)

        it("loads the Russian table", function()
            expect(rus["ui_mcm_menu_roguelite"]).toBe(true)
        end)

        -- The root carries no `text`, so MCM derives ui_mcm_menu_<root id> for
        -- the mod's entry in the settings list.
        it("names the mod's own menu entry", function()
            expect(eng["ui_mcm_menu_" .. labels.ROOT]).toBe(true)
        end)

        it("finds every option in the tree", function()
            expect(#labels.labels(tree)).toBeGreaterThan(0)
        end)
    end)

    describe("every node's label exists in English", function()
        -- The direction that matters most: this is what a player sees.
        it("has no missing keys", function()
            expect(result.missing_eng).toEqual({})
        end)

        it("translates every group heading", function()
            expect(result.groups).toEqual({})
        end)
    end)

    describe("every node's label is a string id", function()
        -- A literal renders, since translate_string passes unknown input
        -- through unchanged, but it can never be translated.
        it("has no hardcoded English", function()
            expect(result.literal).toEqual({})
        end)
    end)

    describe("every translation has a node", function()
        -- An orphan is usually a rename: the option moved and its old string
        -- stayed behind, so the new one shows a raw id while the old
        -- translation sits unused.
        --
        -- A string for an option that is commented out is an orphan too, and
        -- it is deleted, not kept. Git holds the text if the option comes
        -- back, and a string with nothing pointing at it cannot be told apart
        -- from half a rename by reading the file.
        it("has no orphans", function()
            expect(result.orphan).toEqual({})
        end)
    end)

    describe("Russian parity", function()
        -- Lower severity than a missing English key -- an English speaker never
        -- sees it -- but a Russian player gets the raw id just the same.
        it("has no untranslated labels", function()
            expect(result.missing_rus).toEqual({})
        end)

        -- The check above only sees ids the MCM tree asks for -- 112 of 220
        -- strings. Every message, item name and main-menu string was outside
        -- its reach, so a translation gap in roguelite_messages.xml was
        -- invisible to the whole suite while `locals.bat` printed it and no
        -- assertion read it. Compare the tables outright instead.
        it("has no untranslated strings anywhere", function()
            expect(result.parity.only_eng).toEqual({})
        end)

        -- The opposite direction is not translation work at all: there is
        -- nothing left to translate. It is a rename applied to one table only,
        -- so the rus entry is dead and its replacement is untranslated under a
        -- new id.
        it("has no Russian string without an English one", function()
            expect(result.parity.only_rus).toEqual({})
        end)
    end)

    describe("the string tables themselves", function()
        -- The engine keeps one <text> per id and drops the rest, so a
        -- copy-pasted block that was never renamed quietly replaces the string
        -- it was meant to become. Every other check here reads a set, where
        -- the repeat has already collapsed and the id still resolves -- so
        -- this is the only thing that can see it.
        it("declares each string id once", function()
            expect(result.duplicates).toEqual({})
        end)
    end)

    describe("the analysis itself", function()
        -- Every assertion above expects an empty list, so all of them would
        -- pass just as well if analyse() had stopped looking at anything.
        -- Feed it a tree whose label is missing from both tables and confirm
        -- each category still reports.
        local BROKEN = { gr = {
            { id = "nowhere", gr = {
                { id = "no_such_option", type = "check", val = 1, def = false },
                { id = "hardcoded", type = "check", val = 1, def = false,
                  text = "A literal sentence" },
            }},
        }}

        it("reports a label with no English string", function()
            local r = labels.analyse(BROKEN, {}, {})
            expect(#r.missing_eng).toBe(1)
        end)

        it("reports a hardcoded sentence", function()
            local r = labels.analyse(BROKEN, {}, {})
            expect(r.literal).toEqual({ "roguelite/nowhere/hardcoded" })
        end)

        it("reports a string with no node", function()
            local r = labels.analyse(BROKEN, { ui_mcm_roguelite_gone = true }, {})
            expect(r.orphan).toEqual({ "ui_mcm_roguelite_gone" })
        end)

        it("reports a string in eng with no rus", function()
            local r = labels.analyse(BROKEN, { st_thing = true }, {})
            expect(r.parity.only_eng).toEqual({ "st_thing" })
        end)

        it("reports a string in rus with no eng", function()
            local r = labels.analyse(BROKEN, {}, { st_thing = true })
            expect(r.parity.only_rus).toEqual({ "st_thing" })
        end)

        it("reports a repeated string id", function()
            local r = labels.analyse(BROKEN, {}, {},
                { eng = { { id = "st_dup", file = "a.xml", count = 2 } } })
            expect(#r.duplicates).toBe(1)
        end)
    end)

    describe("the derivation rule itself", function()
        -- Pins the concatenation, since every assertion above depends on it.
        local function label_for(id)
            for _, label in ipairs(labels.labels(tree)) do
                if label.id == id then return label end
            end
        end

        it("joins root, group and option with underscores", function()
            expect(label_for("is_roguelite_enabled").key)
                .toBe("ui_mcm_roguelite_is_roguelite_enabled")
        end)

        it("prefers an explicit text over the derived key", function()
            local found = label_for("title")
            expect(found.explicit).toBe(true)
            expect(found.key).toBe("ui_mcm_roguelite_title")
        end)

        -- Renaming an option id moves its label key, which is exactly how these
        -- break in practice.
        it("ties the key to the option id", function()
            expect(label_for("debug").key)
                .toBe("ui_mcm_roguelite_debug")
        end)

        -- A tooltip is looked up at "<label key>_desc" and is optional, so it
        -- must not be reported as an orphan when its owner exists.
        it("treats a _desc as belonging to its option", function()
            local used = labels.used_keys(tree)
            expect(used["ui_mcm_roguelite_debug_desc"]).toBe(true)
        end)

        it("counts a rendering-only node as having no label", function()
            for _, label in ipairs(labels.labels(tree)) do
                expect(label.type).never.toBe("line")
            end
        end)
    end)
end)

return true

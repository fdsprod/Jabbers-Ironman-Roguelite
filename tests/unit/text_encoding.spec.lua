-- The localisation XML is stored as windows-1251, one byte per Cyrillic
-- letter, and must stay that way.
--
-- A regression guard for damage that already happened. Across ten revisions
-- (f177d70, d8af180, af26ed0, 42aca5e, d3347ee, 6594b15, ac8a81c, 718d1ca,
-- f3306f4, 94535ac) the rus tables were committed as UTF-8; e5494dc put them
-- back. Each round trip is an editor, not a person: VS Code guesses an encoding
-- when it opens a cp1251 file, guesses wrong, and rewrites every Cyrillic byte
-- on save. The tree is correct now, so this spec is green as written -- it was
-- confirmed to fail by re-encoding rus/ui_st_mcm_roguelite.xml to UTF-8, and
-- again for the BOM and declaration cases.
--
-- Nothing else here catches it. The engine's XML reader is not encoding-aware
-- in any useful sense -- it takes the bytes as they are and hands them to
-- cp1251 font tables -- so a UTF-8 file still parses, every <string id> still
-- resolves, and `mcm_localization.spec.lua` stays green while every Russian
-- label in the menu renders as mojibake. The declaration is no help either: it
-- keeps saying windows-1251 through the whole thing, so the diff looks
-- innocent. It has to be checked at the byte level or not at all.
--
-- Reference for a correct file: any stock Anomaly/GAMMA translation, e.g.
-- "HD Glowsticks" rus/st_items_glowstick.xml -- declaration windows-1251,
-- single-byte Cyrillic in 0xC0..0xFF, no BOM.
--
-- Line endings are deliberately NOT asserted. Stock files use LF and ours use
-- CRLF; the engine reads both, and core.autocrlf rewrites them on checkout
-- anyway, so pinning them would fail for a reason nobody should care about.

local H   = require("harness.init")
local enc = require("harness.encoding")

local reports = {}      -- flat list, every language
local by_lang = {}

local function scan()
    H.boot{}
    reports, by_lang = {}, {}

    local text_dir = H.loader.text_dir()
    for _, lang in ipairs(enc.languages(text_dir)) do
        by_lang[lang] = {}
        for _, name in ipairs(H.loader.string_table_files(lang)) do
            local report = enc.inspect(text_dir .. "/" .. lang .. "/" .. name)
            if report then
                report.lang, report.name = lang, name
                reports[#reports + 1] = report
                by_lang[lang][#by_lang[lang] + 1] = report
            end
        end
    end
end

--- Reports failing `pred`, described one per line. An assertion against this
--- names the offending file and offset instead of just "expected true".
local function offenders(pred)
    local out = {}
    for _, report in ipairs(reports) do
        if pred(report) then out[#out + 1] = enc.describe(report) end
    end
    return out
end

describe("localisation file encoding", function()

    beforeEach(scan)

    describe("the scan itself", function()
        -- A check that silently covers nothing is the failure mode here: a
        -- typo'd directory, a `dir` that returns nothing, and every assertion
        -- below passes vacuously forever.
        it("finds the text directory", function()
            expect(H.loader.text_dir()).toContain("configs/text")
        end)

        it("finds both shipped languages", function()
            expect(by_lang.eng).toBeDefined()
            expect(by_lang.rus).toBeDefined()
        end)

        it("reads every string table", function()
            expect(#reports).toBeGreaterThan(0)
            expect(#by_lang.rus).toBeGreaterThan(0)
        end)

        -- Without this, an all-ASCII rus directory -- which is what a wholesale
        -- deletion or a bad checkout looks like -- would pass every encoding
        -- assertion below.
        it("sees Cyrillic in the Russian tables", function()
            local high = 0
            for _, report in ipairs(by_lang.rus) do high = high + report.high end
            expect(high).toBeGreaterThan(1000)
        end)
    end)

    describe("no file has been re-encoded as UTF-8", function()
        -- The load-bearing assertion. A cp1251 sentence is essentially never
        -- valid UTF-8 -- Cyrillic sits in 0xC0..0xFF, so every letter reads as
        -- a lead byte demanding continuations the next letter does not supply.
        -- Decoding cleanly as UTF-8 therefore means it was rewritten, and no
        -- amount of luck produces that by accident.
        it("has no file that decodes as UTF-8", function()
            expect(offenders(function(r) return r.utf8 end)).toEqual({})
        end)

        -- Same damage, caught a second way, because the first check is a
        -- statistical argument and this one is not: UTF-8 Cyrillic emits
        -- continuation bytes in 0x80..0xBF, which are undefined or nonsensical
        -- in cp1251. Two independent signals on the one failure that matters.
        it("uses only bytes that exist in cp1251", function()
            expect(offenders(function(r) return #r.illegal > 0 end)).toEqual({})
        end)

        -- An editor that adds a BOM has already decided the file is Unicode.
        -- The engine has no BOM handling, so the marker itself lands in the
        -- first string.
        it("has no byte-order mark", function()
            expect(offenders(function(r) return r.bom ~= nil end)).toEqual({})
        end)
    end)

    describe("the declaration matches the bytes", function()
        it("declares windows-1251 wherever it declares anything", function()
            expect(offenders(function(r)
                return r.declared ~= nil and r.declared ~= "windows-1251"
            end)).toEqual({})
        end)

        -- eng/ui_st_mcm_roguelite.xml has never carried a declaration and is
        -- pure ASCII, where the encoding cannot be got wrong. The requirement
        -- is scoped to files that actually contain high bytes rather than
        -- baselined, so adding one Cyrillic character to that file fails here
        -- instead of shipping ambiguous.
        it("declares an encoding on every file with high bytes", function()
            expect(offenders(function(r)
                return r.high > 0 and not r.has_declaration
            end)).toEqual({})
        end)
    end)

    describe("the detector itself", function()
        -- The assertions above are all negative -- they pass on an empty list,
        -- including a list that is empty because the detector is broken. These
        -- prove it still fires.
        it("recognises UTF-8 Cyrillic as UTF-8", function()
            -- "Режим" in UTF-8: D0 A0 D0 B5 D0 B6 D0 B8 D0 BC
            local utf8_ru = "\208\160\208\181\208\182\208\184\208\188"
            expect(enc.is_valid_utf8(utf8_ru)).toBe(true)
        end)

        it("rejects the same word in cp1251", function()
            -- "Режим" in cp1251: D0 E5 E6 E8 EC
            local cp1251_ru = "\208\229\230\232\236"
            expect(enc.is_valid_utf8(cp1251_ru)).toBe(false)
        end)

        it("treats pure ASCII as valid UTF-8", function()
            expect(enc.is_valid_utf8("<string_table>")).toBe(true)
        end)

        -- 0xB5 and 0xB6 are UTF-8 continuation bytes with no meaning of their
        -- own in cp1251 -- exactly what a re-encoded file is full of.
        it("counts UTF-8 continuation bytes as illegal in cp1251", function()
            expect(enc.CP1251_HIGH[0xB5]).toBeFalsy()
            expect(enc.CP1251_HIGH[0xB6]).toBeFalsy()
        end)

        it("accepts the Cyrillic block", function()
            expect(enc.CP1251_HIGH[0xD0]).toBe(true)     -- Р
            expect(enc.CP1251_HIGH[0xFF]).toBe(true)     -- я
        end)
    end)
end)

return true

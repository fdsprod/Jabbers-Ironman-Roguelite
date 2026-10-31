-- Localisation report. Compares every MCM option label against the shipped
-- string tables, in both directions, and prints what it finds.
--
--   locals.bat
--   tools\luajit.exe locals.lua
--
-- Not a test suite -- unit/mcm_localization.spec.lua asserts the same thing.
-- This exists because when you are ADDING an option, "18 passing" tells you
-- nothing; you want the list.
--
-- Exit 0 when nothing is broken, 1 otherwise. There is no list of accepted
-- breakages to check against and nothing to add an id to; the only way to
-- reach exit 0 is to fix the localisation.
--
-- Also exit 1 while any string is untranslated. Pass --lax for the report
-- without that; see the `strict` local below for why it is the default here
-- and not in run.bat.

package.path = "./?.lua;" .. package.path

local H = require("harness.init")
local labels = require("harness.mcm_labels")

-- Colour, matching the spec runner's conventions.
local color = not os.getenv("NO_COLOR") and not os.getenv("SPEC_NO_COLOR")

-- Strict by default: untranslated strings fail this run.
--
-- Still NOT a defect, and run.bat still passes with them outstanding -- the
-- split is deliberate. run.bat gates the build on things that are broken;
-- locals.bat is the translation tool, and a tool you run to look at
-- translation debt should not exit 0 while there is debt to look at. Reporting
-- alone was too quiet: the count sat in the middle of the output and the last
-- line on screen said PASS.
--
-- --lax restores the old behaviour for anyone who wants the report without the
-- exit code. --strict is still accepted, and is now a no-op.
local strict = true
for _, a in ipairs(arg or {}) do
    if a == "--no-color" then color = false end
    if a == "--lax" then strict = false end
    if a == "--strict" then strict = true end
end

local C = color and {
    reset = "\27[0m", bold = "\27[1m", red = "\27[31m",
    green = "\27[32m", yellow = "\27[33m", cyan = "\27[36m", gray = "\27[90m",
} or setmetatable({}, { __index = function() return "" end })

local RULE = string.rep("-", 66)

local function heading(text)
    print("")
    print(C.bold .. C.cyan .. text .. C.reset)
end

--- One category. `tint` colours the entries.
local function report(title, list, tint, note)
    if #list == 0 then
        print(string.format("  %s%s%s  %s-%s",
            C.gray, title, C.reset, C.gray, C.reset))
        return
    end

    print(string.format("  %s%s%s", C.bold, title, C.reset))
    if note then print("    " .. C.gray .. note .. C.reset) end

    for _, entry in ipairs(list) do
        print("      " .. tint .. entry .. C.reset)
    end
end

-- ------------------------------------------------------------------- run

H.boot_game{ modules = H.ALL_MODULES }
H.fakes.set_random_min()

local result, tree = labels.inspect()

local n_labels = #labels.labels(tree)

print(RULE)
print(C.bold .. " MCM localisation" .. C.reset)
print(RULE)
print(string.format("  %d option labels   %d eng strings   %d rus strings",
                    n_labels, result.counts.eng, result.counts.rus))
print("")
print("  " .. C.gray ..
      "derived key = ui_mcm_<root>_<group>_<option>, unless the node sets text" ..
      C.reset)

heading("Node has no English translation")
report("renders as the raw string id in the menu", result.missing_eng, C.red)

heading("Node hardcodes English instead of a string id")
report("renders, but can never be translated", result.literal, C.red)

heading("Translation has no node")
report("usually a rename that left the old string behind", result.orphan, C.yellow)

-- Whole-table, not just MCM labels: the label scan never sees messages, item
-- names or menu strings, and a gap there is just as visible in game.
heading("Untranslated")
do
    local only_eng = result.parity.only_eng
    local only_rus = result.parity.only_rus

    if #only_eng == 0 and #only_rus == 0 then
        print("  " .. C.green .. "eng and rus tables are in step" .. C.reset)
    end

    report(string.format("%d string(s) in eng with no rus", #only_eng),
           only_eng, C.yellow, "a Russian player sees the raw id")

    if #only_rus > 0 then
        print("")
        print(string.format("  %s%d string(s) in rus with no eng%s   %s",
            C.bold, #only_rus, C.reset,
            C.gray .. "a rename applied to one table only" .. C.reset))
        for _, id in ipairs(only_rus) do
            print("      " .. C.red .. id .. C.reset)
        end
    end
end

if #result.duplicates > 0 then
    heading("String id declared more than once")
    print("    " .. C.gray ..
          "the engine keeps one <text> and drops the rest, so the id resolves " ..
          "and every other check here stays green" .. C.reset)
    for _, entry in ipairs(result.duplicates) do
        print("      " .. C.red .. entry .. C.reset)
    end
end

if #result.groups > 0 then
    heading("Group heading has no translation")
    for _, entry in ipairs(result.groups) do
        print("      " .. C.red .. entry .. C.reset)
    end
end

-- ---------------------------------------------------------------- summary

-- Two different things, deliberately not added together.
--
-- BROKEN is a defect: a label that renders as a raw string id in the shipped
-- menu, or a string with nothing pointing at it.
--
-- DEBT is untranslated text. It is work outstanding, not a defect, so it must
-- not fail run.bat -- but it is reported on every run, because a count that
-- only ever goes up is the one thing nobody notices.
--
-- A duplicate id and an orphaned rus string are defects, not debt: neither is
-- work waiting on a translator. One drops a string the file was written to
-- carry, the other is half a rename.
local broken = #result.missing_eng + #result.literal
             + #result.orphan + #result.groups
             + #result.duplicates + #result.parity.only_rus
local debt = #result.parity.only_eng

print("")
print(C.gray .. RULE .. C.reset)

local debt_note = ""
if debt > 0 then
    debt_note = C.yellow .. string.format("  %d untranslated", debt) .. C.reset
end

if broken > 0 then
    print(C.red .. C.bold .. " BROKEN " .. C.reset ..
          C.red .. string.format("%d defect(s)", broken) .. C.reset ..
          debt_note)
    print("")
    print("  Fix the localisation. There is no list to record these in.")
    os.exit(1)
end

if debt > 0 and strict then
    print(C.red .. C.bold .. " DEBT " .. C.reset ..
          C.red .. string.format("  %d untranslated string(s)", debt) .. C.reset ..
          C.gray .. "  (nothing is broken; pass --lax to report only)" .. C.reset)
    os.exit(1)
end

print(C.green .. C.bold .. " OK " .. C.reset ..
      C.green .. "    nothing broken" .. C.reset ..
      debt_note)

if debt > 0 then
    print("")
    print("  " .. C.gray ..
          "Untranslated strings are reported without failing (--lax)." .. C.reset)
end

os.exit(0)

-- MCM label analysis: which string id each option resolves to, and how that
-- lines up with the shipped localisation tables.
--
-- Shared by unit/mcm_localization.spec.lua (which asserts) and locals.lua
-- (which reports), so the analysis exists in exactly one place. Two copies
-- would drift the first time one is updated.
--
-- THERE IS NO EXEMPTION LIST HERE, AND THERE SHOULD NEVER BE ONE. This module
-- used to carry four tables of string ids that were "known broken"; adding an
-- id to one of them turned a failure into a pass. That inverts what a test is
-- for. The only way to make these checks pass is to fix the localisation.
--
-- If something genuinely must be tolerated, say so in the spec, in prose, next
-- to the assertion that tolerates it -- so a reader sees the reason at the
-- same moment they see the exception. Do not reintroduce a data table that
-- silences findings from a distance.
--
-- THE DERIVATION (ui_mcm.script)
--
--   explicit   node.text
--   derived    "ui_mcm_" .. <full path, "/" replaced by "_">
--   tooltip    <label key> .. "_desc"          (optional; absent = no tooltip)
--   root       "ui_mcm_menu_" .. <root id>
--
-- so { id = "allow_weapon_loss" } in group `items` under root `roguelite`
-- needs ui_mcm_roguelite_items_allow_weapon_loss. game.translate_string
-- returns the raw id on a miss, so a broken entry renders as the string id
-- itself and nothing else reports it.

local M = {}

M.ROOT = "roguelite"

-- Renders nothing, so carries no label.
local NO_LABEL = { line = true, image = true }

-- ----------------------------------------------------------------- analysis

--- A `text` that is not a string id at all, but a literal sentence.
function M.is_literal(key)
    return not key:match("^ui_") and not key:match("^st_")
end

--- Every labelled node in the tree, with the string id MCM will look up.
--- Each entry: { path, key, explicit, group, id, type }
---
--- Recursive: MCM lets groups nest arbitrarily deep and the storage path
--- traces every ancestor id, so a flat walk would mis-key anything nested.
function M.labels(tree)
    local out = {}

    local function walk(node, prefix)
        for _, child in ipairs(node.gr or {}) do
            local path = prefix .. "/" .. tostring(child.id)
            if type(child.gr) == "table" then
                walk(child, path)
            elseif not NO_LABEL[child.type] then
                out[#out + 1] = {
                    path     = path,
                    key      = child.text or ("ui_mcm_" .. path:gsub("/", "_")),
                    explicit = child.text ~= nil,
                    group    = prefix:match("([^/]+)$"),
                    id       = child.id,
                    type     = child.type,
                }
            end
        end
    end

    walk(tree, M.ROOT)
    return out
end

--- Every string id the tree can ask for, tooltips included. A `<key>_desc` is
--- MCM's optional tooltip for `<key>`, not a node of its own, so it counts as
--- used whenever its owner exists.
function M.used_keys(tree)
    local used = { ["ui_mcm_menu_" .. M.ROOT] = true }

    -- Only real groups get a heading. This mod's options sit directly under the root.
    for _, group in ipairs(tree.gr or {}) do
        if type(group.gr) == "table" then
            used[group.text or ("ui_mcm_menu_" .. tostring(group.id))] = true
        end
    end

    for _, label in ipairs(M.labels(tree)) do
        used[label.key] = true
        used[label.key .. "_desc"] = true
    end

    return used
end

local function sorted(t)
    table.sort(t)
    return t
end

--- Full comparison of the tree against the string tables.
---
--- Every list is a plain list of findings. A finding is a finding: there is no
--- second bucket it can be moved into to stop it counting.
---
--- `dups` is optional and comes from loader.load_string_table's second return:
--- { eng = <list>, rus = <list> }.
function M.analyse(tree, eng, rus, dups)
    local r = {
        missing_eng = {},   -- node exists, English string does not
        literal     = {},   -- node hardcodes English instead of a string id
        orphan      = {},   -- string exists, node does not
        missing_rus = {},   -- label present in eng, absent in rus
        groups      = {},   -- group headings with no translation
        duplicates  = {},   -- one id declared twice; the engine keeps one
        -- Whole-table parity, independent of the MCM tree.
        parity      = { only_eng = {}, only_rus = {} },
    }

    for _, group in ipairs(tree.gr or {}) do
        local key = type(group.gr) == "table" and (group.text or ("ui_mcm_menu_" .. tostring(group.id)))
        if key and not eng[key] then
            r.groups[#r.groups + 1] = tostring(group.id) .. "  ->  " .. key
        end
    end

    for _, label in ipairs(M.labels(tree)) do
        if label.explicit and M.is_literal(label.key) then
            table.insert(r.literal, label.path)
        else
            if not eng[label.key] then
                table.insert(r.missing_eng, label.path .. "  ->  " .. label.key)
            end

            -- Checked independently of English, not as an elseif: a label
            -- missing from BOTH tables is missing from Russian too, and
            -- chaining these would report only the English gap and quietly
            -- understate the translation debt.
            if not rus[label.key] then
                table.insert(r.missing_rus, label.path .. "  ->  " .. label.key)
            end
        end
    end

    -- Whole-table parity. The label scan above only sees ids the option tree
    -- asks for, which is 112 of 218 strings -- every message, item name and
    -- main-menu string is invisible to it, and a gap there is just as visible
    -- in game. Compare the tables outright so nothing is out of scope.
    local par = M.parity(eng, rus)   -- only_a = eng-only, only_b = rus-only

    r.parity.only_eng = par.only_a
    r.parity.only_rus = par.only_b

    for lang, list in pairs(dups or {}) do
        for _, dup in ipairs(list) do
            table.insert(r.duplicates, string.format("%s/%s  %s  (x%d)",
                lang, dup.file, dup.id, dup.count))
        end
    end

    local used = M.used_keys(tree)
    for id in pairs(eng) do
        if id:match("^ui_mcm_" .. M.ROOT .. "_") and not used[id] then
            table.insert(r.orphan, id)
        end
    end

    sorted(r.missing_eng)
    sorted(r.literal)
    sorted(r.orphan)
    sorted(r.missing_rus)
    sorted(r.groups)
    sorted(r.duplicates)

    return r
end

--- Whole-table parity between two languages, independent of the MCM tree.
---
--- The label scan only sees ids the option tree asks for, which misses every
--- message, item name and menu string. This compares the tables outright, so a
--- translation gap anywhere is visible.
---
--- Returns { only_a, only_b }, both sorted.
function M.parity(a, b)
    local only_a, only_b = {}, {}
    for id in pairs(a) do if not b[id] then only_a[#only_a + 1] = id end end
    for id in pairs(b) do if not a[id] then only_b[#only_b + 1] = id end end
    return { only_a = sorted(only_a), only_b = sorted(only_b) }
end

--- Load both string tables and analyse in one call. `tree` defaults to the
--- live on_mcm_load() output.
---
--- NOTE ON ENCODING: the Russian tables ship as windows-1251, not UTF-8
--- (Cyrillic occupies 0xC0-0xFF as single bytes). Everything here compares
--- string *ids*, which are ASCII, so the encoding never matters. Anything that
--- starts reading the <text> bodies has to decode first.
function M.inspect(tree)
    local loader = require("harness.loader")
    tree = tree or _G.roguelite_manager_mcm.on_mcm_load()

    local eng, eng_dups = loader.load_string_table("eng")
    local rus, rus_dups = loader.load_string_table("rus")

    local result = M.analyse(tree, eng, rus, { eng = eng_dups, rus = rus_dups })

    result.counts = { eng = 0, rus = 0 }
    for _ in pairs(eng) do result.counts.eng = result.counts.eng + 1 end
    for _ in pairs(rus) do result.counts.rus = result.counts.rus + 1 end

    return result, tree
end

return M

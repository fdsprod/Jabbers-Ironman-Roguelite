-- Byte-level inspection of the localisation XML under gamedata/configs/text.
--
-- Anomaly's XML reader is not encoding-aware in any useful sense: it takes the
-- bytes as they are and hands them to the engine's cp1251 font tables. So a
-- Russian string table is only correct if it is *stored* as windows-1251, one
-- byte per Cyrillic letter. A file that says `encoding="windows-1251"` in its
-- declaration while holding UTF-8 bytes renders as mojibake in game, and
-- nothing anywhere reports it -- the file still parses, the string ids still
-- resolve, so `mcm_localization.spec.lua` stays green while every label is
-- garbage.
--
-- The way this breaks in practice is an editor. VS Code guesses an encoding on
-- open, and on a cp1251 file it usually guesses wrong; saving then rewrites
-- every Cyrillic byte. Nothing in the diff looks alarming -- the declaration is
-- untouched -- which is exactly why it needs a byte-level check rather than a
-- reading of the header.
--
-- Reference for what a correct file looks like: any stock Anomaly/GAMMA
-- translation, e.g. gamedata/configs/text/rus/st_items_glowstick.xml from
-- "HD Glowsticks" -- declaration windows-1251, single-byte Cyrillic in
-- 0xC0..0xFF, no BOM.

local M = {}

-- ------------------------------------------------------------------ cp1251
--
-- The high half of windows-1251. Cyrillic occupies a contiguous 0xC0..0xFF
-- (А..я); the rest is typographic punctuation and the two Ё/ё that sit outside
-- the block. Everything not listed here is either undefined in cp1251 or a
-- character no string table has a reason to contain -- and, more usefully, the
-- 0x80..0xBF range is where UTF-8 continuation bytes live, so keeping the
-- allowance there narrow is what makes a UTF-8 re-save visible.
--
-- Codepage chart: https://en.wikipedia.org/wiki/Windows-1251

local CP1251_HIGH = {}
for b = 0xC0, 0xFF do CP1251_HIGH[b] = true end     -- А..я
for _, b in ipairs{
    0xA8,   -- Ё
    0xB8,   -- ё
    0xAB,   -- «
    0xBB,   -- »
    0x85,   -- …
    0x93,   -- “
    0x94,   -- ”
    0x96,   -- –
    0x97,   -- —
    0xB9,   -- №  (0xB9 is № in cp1251, not the superscript one)
} do CP1251_HIGH[b] = true end
M.CP1251_HIGH = CP1251_HIGH

-- ------------------------------------------------------------------- utf-8
--
-- A genuine cp1251 sentence is essentially never valid UTF-8: Cyrillic lands in
-- 0xC0..0xFF, so every letter reads as a lead byte demanding continuations that
-- the next letter does not supply. That makes "decodes cleanly as UTF-8" a
-- sharp positive signal that the file was re-encoded, and it is the one check
-- here that cannot be fooled by a lucky byte.

local function is_valid_utf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local extra
        if c < 0x80 then extra = 0
        elseif c >= 0xC2 and c <= 0xDF then extra = 1
        elseif c >= 0xE0 and c <= 0xEF then extra = 2
        elseif c >= 0xF0 and c <= 0xF4 then extra = 3
        else return false                       -- continuation or overlong lead
        end
        for k = 1, extra do
            local cc = s:byte(i + k)
            if not cc or cc < 0x80 or cc > 0xBF then return false end
        end
        i = i + 1 + extra
    end
    return true
end
M.is_valid_utf8 = is_valid_utf8

-- ------------------------------------------------------------------- report

local BOMS = {
    { name = "utf-8",    bytes = "\239\187\191" },
    { name = "utf-16le", bytes = "\255\254"     },
    { name = "utf-16be", bytes = "\254\255"     },
}

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local src = f:read("*all")
    f:close()
    return src
end
M.read_file = read_file

--- Everything worth asserting about one file, as plain data.
---
--- @return table|nil
---   path       as given
---   size       bytes
---   bom        "utf-8" | "utf-16le" | "utf-16be" | nil
---   declared   encoding= from the XML declaration, lowercased, or nil
---   high       count of bytes >= 0x80
---   illegal    { {offset=, byte=}, ... } bytes >= 0x80 not valid in cp1251,
---              first few only
---   utf8       true if the whole file decodes as UTF-8
function M.inspect(path)
    local src = read_file(path)
    if not src then return nil end

    local report = {
        path = path, size = #src, high = 0, illegal = {}, bom = nil,
    }

    for _, bom in ipairs(BOMS) do
        if src:sub(1, #bom.bytes) == bom.bytes then report.bom = bom.name break end
    end

    -- Only the declaration, and only if it is where XML requires it -- byte 0.
    local decl = src:match("^<%?xml.-%?>")
    if decl then
        local enc = decl:match("encoding%s*=%s*[\"']([^\"']+)[\"']")
        report.declared = enc and enc:lower() or nil
        report.has_declaration = true
    else
        report.has_declaration = false
    end

    for i = 1, #src do
        local b = src:byte(i)
        if b >= 0x80 then
            report.high = report.high + 1
            if not CP1251_HIGH[b] and #report.illegal < 8 then
                report.illegal[#report.illegal + 1] = { offset = i - 1, byte = b }
            end
        end
    end

    report.utf8 = report.high > 0 and is_valid_utf8(src) or false

    return report
end

--- Language subdirectories of gamedata/configs/text. Discovered rather than
--- listed so a new translation is covered without editing the harness -- the
--- same bargain as spec discovery.
function M.languages(text_dir)
    local ok, pipe = pcall(io.popen,
        'dir /b /ad "' .. text_dir:gsub("/", "\\") .. '" 2>nul')
    if not ok or not pipe then return {} end

    local found = {}
    for line in pipe:lines() do
        local name = line:gsub("%s+$", "")
        if name ~= "" then found[#found + 1] = name end
    end
    pipe:close()
    table.sort(found)
    return found
end

--- A one-line description of a report, for assertion messages. Assertions read
--- better against a string than a nested table, and the offset is what you need
--- to find the damage.
function M.describe(report)
    local bits = { report.path }
    bits[#bits + 1] = "declared=" .. tostring(report.declared)
    bits[#bits + 1] = "bom=" .. tostring(report.bom)
    bits[#bits + 1] = "high=" .. report.high
    if report.utf8 then bits[#bits + 1] = "decodes as UTF-8" end
    for _, bad in ipairs(report.illegal) do
        bits[#bits + 1] = string.format("0x%02X@%d", bad.byte, bad.offset)
    end
    return table.concat(bits, " ")
end

return M

-- Reproduces the X-Ray engine's script module loader.
--
-- Two engine behaviors are replicated here, and getting either wrong produces
-- tests that pass for the wrong reason:
--
-- 1. The namespace wrapper (xrServerEntities/script_storage.cpp:608 load_buffer,
--    using `file_header_old` at :22). Every .script file is textually prefixed
--    with:
--
--      local function script_name() return "<name>" end
--      local this = {}
--      <name>= this
--      setmetatable(this, {__index = _G})
--      setfenv(1, this)
--
--    The `<name>= this` fragment is built by parse_namespace() (:575) and runs
--    *before* setfenv, so it lands in _G. Consequences the mod relies on:
--
--      RELATIONS = {...}          -> soulslike.RELATIONS  (module-local)
--      function debug(o)          -> soulslike.debug      (shadows stdlib debug
--                                                          inside that module)
--      function math.clamp(...)   -> mutates the SHARED global math table
--                                    (read falls through __index, write lands
--                                     on the real table)
--      function _G.IsSoulslikeMode() -> true global
--
--    The engine's header is a single C string built from backslash line
--    continuations, so it contains no newlines. We match that: the prologue
--    adds zero lines, keeping runtime line numbers aligned with the source file.
--
-- 2. Lazy autoload (xrServerEntities/script_engine.cpp:257 auto_load, installed
--    at :270). Reading an undefined global attempts to load "<key>.script" and
--    then rawgets. A missing file resolves to nil -- it does NOT raise.

local M = {}

M.script_dir = nil          -- set via M.init{}
M.loaded = {}               -- name -> true
M.load_order = {}           -- chronological, for assertions
M.missing = {}              -- names that autoload tried and failed to find

local loading = {}          -- reentrancy guard
local installed = false

-- Mirrors CScriptStorage::parse_namespace (script_storage.cpp:575).
-- "soulslike"  -> b="soulslike=",     c=""
-- "a.b"        -> b="a={b=",          c="}"
local function parse_namespace(name)
    local b, c = "", ""
    local rest = name
    local i = 0
    while true do
        if rest == "" then
            return nil, "the namespace name " .. name .. " is incorrect!"
        end
        local head, tail = rest:match("^([^.]*)%.(.*)$")
        if not head then head, tail = rest, nil end

        if i > 0 then b = b .. "{" end
        b = b .. head .. "="
        if i > 0 then c = "}" .. c end

        if tail then rest, i = tail, i + 1 else break end
    end
    return b, c
end
M.parse_namespace = parse_namespace

-- Single-line, exactly like the engine's file_header_old.
local function build_prologue(name)
    local b, c = parse_namespace(name)
    if not b then error(c, 0) end
    return table.concat({
        ' local function script_name() return "', name, '" end ',
        ' local this = {} ',
        b, ' this ', c, ' ',
        ' setmetatable(this, {__index = _G}) ',
        ' setfenv(1, this) ',
    })
end
M.build_prologue = build_prologue

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local src = f:read("*all")
    f:close()
    return src
end

function M.script_path(name)
    assert(M.script_dir, "loader.init{script_dir=...} was never called")
    return M.script_dir .. "/" .. name .. ".script"
end

-- ------------------------------------------------------------ string tables
--
-- Anomaly's localisation lives in gamedata/configs/text/<lang>/*.xml as
-- <string id="..."><text>...</text></string>. MCM resolves an option's label
-- through game.translate_string, and a miss shows the raw string id on screen
-- with no other signal -- which is the failure this exists to catch.
--
-- Deliberately a dumb pattern match rather than an XML parse: these files are
-- machine-uniform, and a real parser would be more code to get wrong than the
-- thing it checks.

--- gamedata/configs/text, derived from script_dir so the two stay in step.
function M.text_dir()
    assert(M.script_dir, "loader.init{script_dir=...} was never called")
    return (M.script_dir:gsub("/scripts$", "")) .. "/configs/text"
end

--- Every <string id> in one language's tables, as a set. Missing files are
--- skipped: a mod need not ship every language.
---
--- Returns `ids, duplicates`. A set discards repeats, and a repeated id is not
--- harmless: the engine keeps one <text> and drops the rest, so a block that
--- was copy-pasted and never renamed silently takes the place of the string it
--- was supposed to become. Nothing else in the suite can see that -- the id
--- resolves, so every label check stays green -- which is why the count comes
--- back alongside the set rather than being thrown away here.
---
--- Each duplicate entry: { id, file, count }.
function M.load_string_table(lang, files)
    local ids, seen, dups = {}, {}, {}
    local dir = M.text_dir() .. "/" .. (lang or "eng")

    for _, name in ipairs(files or M.string_table_files(lang)) do
        local src = read_file(dir .. "/" .. name)
        if src then
            local function collect(pattern)
                for id in src:gmatch(pattern) do
                    ids[id] = true
                    local at = seen[id]
                    if at then
                        at.count = at.count + 1
                    else
                        seen[id] = { id = id, file = name, count = 1 }
                    end
                end
            end
            collect('<string%s+id%s*=%s*"([^"]+)"')
            collect("<string%s+id%s*=%s*'([^']+)'")
        end
    end

    for _, at in pairs(seen) do
        if at.count > 1 then dups[#dups + 1] = at end
    end
    table.sort(dups, function(a, b) return a.id < b.id end)

    return ids, dups
end

--- The .xml files present for a language. Discovered the same way spec files
--- are, so a new translation file is picked up without editing the harness.
function M.string_table_files(lang)
    local dir = M.text_dir() .. "/" .. (lang or "eng")
    local ok, pipe = pcall(io.popen,
        'dir /b /a-d "' .. dir:gsub("/", "\\") .. '\\*.xml" 2>nul')
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

--- Load a stock Anomaly script from _scripts/ through the same namespacing. Stock
--- scripts are never autoloaded: reading an undefined global must not silently
--- pull in the real script, so each one a spec relies on is named.
function M.load_stock(name)
    assert(M.stock_dir, "loader.init{stock_dir=...} was never called")
    local path = M.stock_dir .. "/" .. name .. ".script"
    local src = read_file(path)
    if not src then
        error("harness: stock script " .. path .. " not found. _scripts/ is "
              .. "gitignored reference material; these specs need a copy.", 0)
    end
    local chunk, err = loadstring(build_prologue(name) .. src, "@" .. path)
    if not chunk then error("syntax error loading " .. path .. ": " .. tostring(err), 0) end
    local ok, rerr = pcall(chunk)
    if not ok then error("error executing " .. path .. ": " .. tostring(rerr), 0) end
    M.loaded[name] = true
    M.load_order[#M.load_order + 1] = name
    return rawget(_G, name)
end

function M.exists(name)
    local f = io.open(M.script_path(name), "rb")
    if f then f:close() return true end
    return false
end

-- Loads <name>.script into the global namespace <name>. Returns the module
-- table, or nil if the file does not exist (matching engine behavior: absence
-- is not an error).
function M.load(name)
    if M.loaded[name] then return rawget(_G, name) end
    if loading[name] then return rawget(_G, name) end   -- circular reference

    local path = M.script_path(name)
    local src = read_file(path)
    if not src then
        M.missing[name] = true
        return nil
    end

    loading[name] = true
    local chunk, err = loadstring(build_prologue(name) .. src, "@" .. path)
    if not chunk then
        loading[name] = nil
        error("syntax error loading " .. path .. ": " .. tostring(err), 0)
    end

    local ok, rerr = pcall(chunk)
    loading[name] = nil
    if not ok then
        error("error executing " .. path .. ": " .. tostring(rerr), 0)
    end

    M.loaded[name] = true
    M.load_order[#M.load_order + 1] = name
    return rawget(_G, name)
end

-- Strict mode: raise on a global that resolved to nil, instead of silently
-- handing back nil the way the engine does. A forgotten fake otherwise
-- surfaces as a confusing nil-index several frames downstream.
--
-- Off by default, because nil-tolerance IS the engine's real behavior and the
-- mod relies on it -- soulslike_scenarios.script:113 reads
-- `local dte = demonized_time_events` for a mod that may not be installed.
-- Registered soft dependencies are therefore always exempt.
M.strict = false

local STRICT_EXEMPT = {
    -- Lua/LuaJIT internals and harness plumbing that legitimately probe _G.
    _PROMPT = true, _PROMPT2 = true, jit = true, arg = true,
}

local function strict_exempt(k)
    if STRICT_EXEMPT[k] then return true end
    local ok, mods = pcall(require, "harness.mods")
    if ok then
        for _, name in ipairs(mods.NAMES) do
            if k == name or k == "dte" then return true end
        end
    end
    return false
end

-- Installs the _G.__index autoload metamethod (script_engine.cpp:257).
function M.install_autoload()
    if installed then return end
    installed = true

    local mt = getmetatable(_G) or {}
    local prev_index = mt.__index

    mt.__index = function(t, k)
        if type(k) == "string"
           and not M.loaded[k]
           and not M.missing[k]
           and not loading[k]
           and M.script_dir
        then
            M.load(k)
        end
        local v = rawget(t, k)
        if v ~= nil then return v end
        if prev_index then
            if type(prev_index) == "function" then
                v = prev_index(t, k)
                if v ~= nil then return v end
            else
                v = prev_index[k]
                if v ~= nil then return v end
            end
        end

        if M.strict and type(k) == "string" and not strict_exempt(k) then
            error("strict: undefined global '" .. k .. "' -- no fake provides it " ..
                  "and no " .. k .. ".script exists. Add it to harness/fakes.lua, " ..
                  "or boot without strict = true if nil is the correct answer.", 2)
        end
        return nil
    end

    setmetatable(_G, mt)
end

function M.init(opts)
    M.script_dir = assert(opts.script_dir, "script_dir is required")
    M.stock_dir = opts.stock_dir
    if opts.autoload ~= false then M.install_autoload() end
    return M
end

-- Test aid: reach a file-local function through the upvalues of an exported
-- one. `local function f` at file scope becomes an upvalue of any exported
-- function that references it, so no mod source change is needed to test it.
--
-- Must be called from the *test* environment: soulslike.script defines
-- `function debug(output)`, which shadows the stdlib debug table inside that
-- module's environment.
function M.upvalue(fn, name)
    assert(type(fn) == "function", "upvalue() expects a function")
    for i = 1, math.huge do
        local n, v = debug.getupvalue(fn, i)
        if not n then break end
        if n == name then return v end
    end
    return nil
end

function M.upvalue_names(fn)
    local names = {}
    for i = 1, math.huge do
        local n = debug.getupvalue(fn, i)
        if not n then break end
        names[#names + 1] = n
    end
    return names
end

function M.reset()
    M.loaded, M.load_order, M.missing, loading = {}, {}, {}, {}
end

return M

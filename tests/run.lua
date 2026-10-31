-- Test entry point. Run via run.bat, or:
--   tools\luajit.exe run.lua            (all specs)
--   tools\luajit.exe run.lua self       (harness self-tests only)
--   tools\luajit.exe run.lua unit       (unit specs only)
--   tools\luajit.exe run.lua e2e        (end-to-end journeys only)
--
-- Flags:
--   --no-color        plain output (also honours NO_COLOR / SPEC_NO_COLOR)
--   --ascii           ok/XX instead of the tick and cross, for a non-UTF-8 console
--   --file <substr>   only load spec files whose path contains <substr>
--   -t, --test <substr>
--                     only run tests whose full name contains <substr>
--
-- Spec files are discovered from the suite directories, so a new *.spec.lua is
-- picked up without editing this file. MANIFEST below is a fallback for hosts
-- where the directory listing is unavailable (io.popen disabled, or a shell
-- that is not cmd) -- keep it current enough to run, but discovery is the
-- normal path.

package.path = "./?.lua;" .. package.path

local spec = require("harness.spec")

local SUITES = { "self", "unit", "e2e" }

local MANIFEST = {
    self = {
        "self/class.spec.lua",
        "self/loader.spec.lua",
        "self/dispatch.spec.lua",
        "self/timeevents.spec.lua",
        "self/world.spec.lua",
        "self/alife.spec.lua",
    },
    unit = {
        "unit/restore_item.spec.lua",
        "unit/manager.spec.lua",
        "unit/stashes.spec.lua",
        "unit/mcm_options.spec.lua",
        "unit/mcm_localization.spec.lua",
        "unit/text_encoding.spec.lua",
    },
    e2e = {
        "e2e/stash_item_uses.spec.lua",
        "e2e/stash_item_condition.spec.lua",
        "e2e/player_corpse.spec.lua",
    },
}

-- Discovery via `dir /b`, which lists bare filenames and nothing else. Sorted
-- explicitly: cmd already returns alphabetical order, but relying on that
-- across shells would make test order host-dependent.
local function discover(dir)
    local ok, pipe = pcall(io.popen, 'dir /b /a-d "' .. dir .. '\\*.spec.lua" 2>nul')
    if not ok or not pipe then return nil end

    local found = {}
    for line in pipe:lines() do
        local name = line:gsub("%s+$", "")
        if name ~= "" then found[#found + 1] = dir .. "/" .. name end
    end
    pipe:close()

    if #found == 0 then return nil end
    table.sort(found)
    return found
end

local function files_for(suite)
    return discover(suite) or MANIFEST[suite] or {}
end

-- ------------------------------------------------------------------- args

local which, file_filter, name_filter = "all", nil, nil

local args = arg or {}
local i = 1
while i <= #args do
    local a = args[i]
    if a == "--no-color" then
        spec.configure{ color = false }
    elseif a == "--ascii" then
        spec.configure{ unicode = false }
    elseif a == "--file" then
        i = i + 1
        file_filter = args[i]
        if not file_filter then
            print("!! --file needs a value")
            os.exit(2)
        end
    elseif a == "-t" or a == "--test" then
        i = i + 1
        local t = args[i]
        if not t then
            print("!! " .. a .. " needs a value")
            os.exit(2)
        end
        name_filter = t
        spec.filter(t)
    elseif a ~= "" and a:sub(1, 1) ~= "-" then
        which = a
    end
    i = i + 1
end

-- ---------------------------------------------------------------- loading

-- Loaded with dofile rather than require: `.spec.lua` is the TS-idiomatic
-- filename but the dots do not map onto require's module paths.
local function load_all(files)
    local loaded = 0
    for _, path in ipairs(files) do
        if not file_filter or path:find(file_filter, 1, true) then
            local ok, err = pcall(dofile, path)
            if not ok then
                print("")
                print("!! failed to load " .. path)
                print("   " .. tostring(type(err) == "table" and err.msg or err))
                os.exit(2)
            end
            loaded = loaded + 1
        end
    end
    return loaded
end

local function load_suite(suite)
    return load_all(files_for(suite))
end

if which ~= "all" and not MANIFEST[which] then
    print("!! unknown suite '" .. which .. "' -- expected one of: " ..
          table.concat(SUITES, ", "))
    os.exit(2)
end

-- A --file filter that matches no spec file is a typo, and would otherwise
-- report as a green run of zero tests.
local function require_loaded(count, what)
    if count > 0 then return end
    if file_filter then
        print("!! no spec files matched --file " .. string.format("%q", file_filter))
    else
        print("!! no spec files found in " .. (what or "the requested suite") ..
              "/ -- nothing to run")
    end
    os.exit(2)
end

if which ~= "all" then
    require_loaded(load_suite(which), which)
    os.exit(spec.run() == 0 and 0 or 1)
end

-- Either filter turns this into a "run just these" invocation: load every
-- suite into one registry and report once. The self-test gate is skipped
-- deliberately -- gating would either drag the whole self-suite into a
-- targeted run, or (for -t) abort because the filter selected nothing from
-- self/, which the runner cannot distinguish from a real harness failure.
if file_filter or name_filter then
    local n = 0
    for _, suite in ipairs(SUITES) do n = n + load_suite(suite) end
    require_loaded(n)
    os.exit(spec.run() == 0 and 0 or 1)
end

-- Full run. Self-tests gate the rest: if the harness is not faithful, unit and
-- e2e results mean nothing, so a self-test failure aborts before they run.
require_loaded(load_suite("self"), "self")
local self_failed = spec.run()
if self_failed > 0 then
    print("")
    print("!! harness self-tests failed -- unit and e2e specs skipped.")
    print("   Fix the harness first; their results would not be trustworthy.")
    os.exit(1)
end

print("")
spec.reset()
require_loaded(load_suite("unit") + load_suite("e2e"), "unit and e2e")
os.exit(spec.run() == 0 and 0 or 1)

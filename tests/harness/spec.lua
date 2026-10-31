-- BDD test runner: nested describe/it with beforeEach, plus a Jest-style
-- expect(). Modelled on Jest/Vitest so the specs read the same way as a TS
-- suite.
--
--   describe("loader", function()
--     describe("parse_namespace()", function()
--       beforeEach(function() ... end)
--
--       describe("given a flat namespace name", function()
--         it("returns the assignment fragment", function()
--           expect(b).toBe("roguelite=")
--         end)
--       end)
--     end)
--   end)
--
-- describe bodies run at load time; it bodies are deferred to run(). Hooks are
-- resolved at run time from the live frame chain, so a beforeEach declared
-- after an it in the same block still applies to it -- matching Jest.

local M = {}

local stack    = {}     -- describe frames, during registration
local tests    = {}     -- flat, in declaration order
local passed, failed, failures = 0, 0, {}
local filtered = 0      -- skipped by M.filter, reported but not run
local name_filter = nil

-- ------------------------------------------------------------------ structure

function M.describe(name, fn)
    local frame = { name = name, before = {}, after = {} }
    stack[#stack + 1] = frame
    local ok, err = pcall(fn)
    table.remove(stack)
    if not ok then
        error("error while defining describe(\"" .. tostring(name) .. "\"): " ..
              tostring(type(err) == "table" and err.msg or err), 0)
    end
end

function M.beforeEach(fn)
    local frame = stack[#stack]
    assert(frame, "beforeEach() must be called inside a describe()")
    frame.before[#frame.before + 1] = fn
end

function M.afterEach(fn)
    local frame = stack[#stack]
    assert(frame, "afterEach() must be called inside a describe()")
    frame.after[#frame.after + 1] = fn
end

function M.it(name, fn)
    assert(#stack > 0, "it(\"" .. tostring(name) .. "\") must be inside a describe()")
    -- Store frame *references*, not a snapshot of their hooks: hooks are
    -- collected at run time so declaration order within a block is irrelevant.
    local frames = {}
    for i, f in ipairs(stack) do frames[i] = f end
    tests[#tests + 1] = { name = name, fn = fn, frames = frames }
end

-- Declared but not implemented; reported, never run.
function M.xit(name)
    assert(#stack > 0, "xit() must be inside a describe()")
    local frames = {}
    for i, f in ipairs(stack) do frames[i] = f end
    tests[#tests + 1] = { name = name, frames = frames, pending = true }
end

-- ----------------------------------------------------------------- failure

local function fail(msg)
    error({ __spec_failure = true, msg = msg }, 3)
end
M.fail = function(msg) error({ __spec_failure = true, msg = msg }, 2) end

local function repr(v)
    local tv = type(v)
    if tv == "string" then return string.format("%q", v) end
    if tv == "table" then
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 8 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(k) .. "=" ..
                (type(val) == "string" and string.format("%q", val) or tostring(val))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end
M.repr = repr

local function deep_eq(a, b, path, seen)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false, path .. ": " .. repr(a) .. " ~= " .. repr(b)
    end
    seen = seen or {}
    if seen[a] and seen[a][b] then return true end
    seen[a] = seen[a] or {}; seen[a][b] = true

    for k, va in pairs(a) do
        local ok, err = deep_eq(va, b[k], path .. "." .. tostring(k), seen)
        if not ok then return false, err end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false, path .. "." .. tostring(k) ..
                          ": missing on left, " .. repr(b[k]) .. " on right"
        end
    end
    return true
end

-- ------------------------------------------------------------------- expect

-- Matchers live in their own table and are bound to the expectation by
-- __index. That is what lets specs use TS call syntax -- expect(x).toBe(y)
-- with a dot -- instead of Lua's expect(x):toBe(y).
local Expect = {}
local Matchers = {}

Expect.__index = function(self, key)
    if key == "never" then
        return setmetatable({ actual = self.actual, negated = not self.negated }, Expect)
    end
    local matcher = rawget(Matchers, key)
    if matcher then
        return function(...) return matcher(self, ...) end
    end
    return nil
end

-- Runs a matcher and reports according to the negation flag.
--
-- A plain local, not a method: __index hands back matchers already bound to
-- the expectation, so `self:_check(...)` would pass self twice.
local function check(self, ok, description, extra)
    if self.negated then ok = not ok end
    if ok then return self end
    local prefix = self.negated and "expected NOT " or "expected "
    fail(prefix .. description .. (extra and ("\n           " .. extra) or ""))
end

function Matchers:toBe(expected)
    return check(self, self.actual == expected,
        repr(self.actual) .. " to be " .. repr(expected))
end

function Matchers:toEqual(expected)
    local ok, err = deep_eq(self.actual, expected, "<root>")
    return check(self, ok, "deep equality", (not self.negated) and err or nil)
end

function Matchers:toBeNil()
    return check(self, self.actual == nil, repr(self.actual) .. " to be nil")
end

function Matchers:toBeDefined()
    return check(self, self.actual ~= nil, "value to be defined (non-nil)")
end

function Matchers:toBeTruthy()
    return check(self, not not self.actual, repr(self.actual) .. " to be truthy")
end

function Matchers:toBeFalsy()
    return check(self, not self.actual, repr(self.actual) .. " to be falsy")
end

function Matchers:toBeType(t)
    return check(self, type(self.actual) == t,
        "type to be " .. t .. ", got " .. type(self.actual))
end

function Matchers:toContain(needle)
    local a = self.actual
    local found = false
    if type(a) == "string" then
        found = a:find(needle, 1, true) ~= nil
    elseif type(a) == "table" then
        for _, v in pairs(a) do if v == needle then found = true break end end
    else
        fail("toContain() needs a string or table, got " .. type(a))
    end
    local shown = type(a) == "string" and
        (#a > 200 and (a:sub(1, 200) .. "...") or a) or repr(a)
    return check(self, found, repr(needle) .. " to be contained in " .. repr(shown))
end

function Matchers:toHaveLength(n)
    local a = self.actual
    if type(a) ~= "string" and type(a) ~= "table" then
        fail("toHaveLength() needs a string or table, got " .. type(a))
    end
    return check(self, #a == n, "length " .. n .. ", got " .. #a)
end

function Matchers:toBeCloseTo(expected, tol)
    tol = tol or 1e-9
    if type(self.actual) ~= "number" then
        fail("toBeCloseTo() needs a number, got " .. repr(self.actual))
    end
    return check(self, math.abs(self.actual - expected) <= tol,
        tostring(self.actual) .. " to be within " .. tostring(tol) ..
        " of " .. tostring(expected))
end

function Matchers:toBeGreaterThan(n)
    return check(self, self.actual > n, repr(self.actual) .. " > " .. repr(n))
end

function Matchers:toBeLessThan(n)
    return check(self, self.actual < n, repr(self.actual) .. " < " .. repr(n))
end

-- expect(fn).toThrow()  /  expect(fn).toThrow("substring")
function Matchers:toThrow(substring)
    if type(self.actual) ~= "function" then
        fail("toThrow() needs a function, got " .. type(self.actual))
    end
    local ok, err = pcall(self.actual)
    local raised = not ok
    local text = type(err) == "table" and (err.msg or "<table>") or tostring(err)

    if raised and substring and not self.negated then
        if not text:find(substring, 1, true) then
            fail("expected the error to contain " .. repr(substring) ..
                 "\n           got: " .. text)
        end
    end
    return check(self, raised, "the call to raise",
        raised and ("it raised: " .. text) or "it returned normally")
end

function M.expect(actual)
    return setmetatable({ actual = actual, negated = false }, Expect)
end

-- ---------------------------------------------------------- output styling

-- Colour is on by default and can be turned off three ways: the NO_COLOR
-- convention (https://no-color.org), SPEC_NO_COLOR, or --no-color on the
-- command line. FORCE_COLOR wins over NO_COLOR.
--
-- The tick and cross are written as explicit UTF-8 byte escapes rather than
-- literal characters, so the encoding of this source file cannot corrupt them.
-- They still need a UTF-8 console: run.bat switches the code page to 65001.
-- If you invoke luajit directly from a legacy code page, set SPEC_ASCII=1.
local style = {
    color   = not os.getenv("NO_COLOR") and not os.getenv("SPEC_NO_COLOR")
              or not not os.getenv("FORCE_COLOR"),
    unicode = not os.getenv("SPEC_ASCII"),
}

local C, SYM

local function refresh_style()
    if style.color then
        C = {
            reset = "\27[0m",  bold = "\27[1m",   dim   = "\27[2m",
            red   = "\27[31m", green = "\27[32m", yellow= "\27[33m",
            cyan  = "\27[36m", gray  = "\27[90m",
        }
    else
        C = setmetatable({}, { __index = function() return "" end })
    end

    if style.unicode then
        SYM = {
            pass    = "\226\156\147",   -- U+2713 CHECK MARK
            fail    = "\226\156\151",   -- U+2717 BALLOT X
            pending = "\226\151\139",   -- U+25CB WHITE CIRCLE
        }
    else
        SYM = { pass = "ok", fail = "XX", pending = "--" }
    end
end
refresh_style()

function M.configure(opts)
    if opts.color   ~= nil then style.color   = opts.color   end
    if opts.unicode ~= nil then style.unicode = opts.unicode end
    refresh_style()
end

-- ------------------------------------------------------------------ running

local function path_of(test)
    local names = {}
    for i, f in ipairs(test.frames) do names[i] = f.name end
    return names
end

local INDENT = "  "

--- Run only tests whose full path ("outer > inner > it name") contains substr.
--- Plain substring, not a pattern, so "create_new()" needs no escaping.
--- Call with nil to clear.
function M.filter(substr)
    name_filter = (substr ~= "" and substr) or nil
end

--- The tests M.run() would actually execute, after the name filter. Selection
--- happens up front so filtered-out tests never print an empty describe header.
local function selected()
    local out = {}
    for _, test in ipairs(tests) do
        if not name_filter then
            out[#out + 1] = test
        else
            local path = path_of(test)
            local full = table.concat(path, " > ") .. " > " .. test.name
            if full:find(name_filter, 1, true) then
                out[#out + 1] = test
            else
                filtered = filtered + 1
            end
        end
    end
    return out
end

function M.run()
    local shown = {}          -- last printed path, for tree headers

    for _, test in ipairs(selected()) do
        local path = path_of(test)

        -- Print any describe headers that changed since the previous test.
        -- The top-level block is bold; nested context lines are dimmer, so the
        -- eye lands on the unit under test first.
        for depth = 1, #path do
            if shown[depth] ~= path[depth] then
                local tint = (depth == 1) and (C.bold .. C.cyan) or C.gray
                print(string.rep(INDENT, depth - 1) .. tint .. path[depth] .. C.reset)
                for d = depth, #shown do shown[d] = nil end
                shown[depth] = path[depth]
            end
        end

        local pad = string.rep(INDENT, #path)

        if test.pending then
            print(pad .. C.yellow .. SYM.pending .. C.reset ..
                  " " .. C.gray .. test.name .. " (pending)" .. C.reset)
        else
            -- Hooks resolved now, outermost first; afterEach innermost first.
            local before, after = {}, {}
            for _, f in ipairs(test.frames) do
                for _, h in ipairs(f.before) do before[#before + 1] = h end
            end
            for i = #test.frames, 1, -1 do
                for _, h in ipairs(test.frames[i].after) do after[#after + 1] = h end
            end

            local ok, err = true, nil
            for _, h in ipairs(before) do
                ok, err = pcall(h)
                if not ok then
                    err = { __spec_failure = true, msg = "beforeEach failed: " ..
                            tostring(type(err) == "table" and err.msg or err) }
                    break
                end
            end

            if ok then ok, err = pcall(test.fn) end

            for _, h in ipairs(after) do pcall(h) end

            if ok then
                passed = passed + 1
                print(pad .. C.green .. SYM.pass .. C.reset ..
                      " " .. C.gray .. test.name .. C.reset)
            else
                failed = failed + 1
                local detail = (type(err) == "table" and err.__spec_failure)
                    and err.msg
                    or ("unexpected error: " .. tostring(err))
                print(pad .. C.red .. SYM.fail .. " " .. test.name .. C.reset)
                for line in (detail .. "\n"):gmatch("(.-)\n") do
                    if line ~= "" then
                        print(pad .. INDENT .. C.red .. line .. C.reset)
                    end
                end
                failures[#failures + 1] = {
                    path = table.concat(path, " > ") .. " > " .. test.name,
                    detail = detail,
                }
            end
        end
    end

    local skipped = (filtered > 0)
        and (C.gray .. string.format(", %d filtered", filtered) .. C.reset)
        or ""

    print("")
    print(C.gray .. string.rep("-", 66) .. C.reset)
    -- A filter that matched nothing is almost always a typo. Report it as a
    -- failure rather than "0 passing", which reads as green.
    if failed == 0 and passed == 0 and filtered > 0 then
        print(C.red .. C.bold .. " EMPTY " .. C.reset ..
              C.red .. string.format("  filter %q matched none of %d tests",
                                     name_filter, filtered) .. C.reset)
        return 1
    elseif failed == 0 then
        print(C.green .. C.bold .. " PASS " .. C.reset ..
              C.green .. string.format("  %d passing", passed) .. C.reset .. skipped)
    else
        print(C.red .. C.bold .. " FAIL " .. C.reset ..
              C.green .. string.format("  %d passing", passed) .. C.reset ..
              C.gray .. ", " .. C.reset ..
              C.red .. string.format("%d failing", failed) .. C.reset .. skipped)
        print("")
        for i, f in ipairs(failures) do
            print(C.red .. string.format("  %d) ", i) .. C.reset ..
                  C.bold .. f.path .. C.reset)
            for line in (f.detail .. "\n"):gmatch("(.-)\n") do
                if line ~= "" then print(C.red .. "     " .. line .. C.reset) end
            end
        end
    end
    return failed
end

-- Clears registered tests and counters. The name filter survives, because a
-- full run resets between suites and the filter is a property of the invocation.
function M.reset()
    stack, tests = {}, {}
    passed, failed, failures = 0, 0, {}
    filtered = 0
end

-- Ambient globals, as describe/it/expect are in a TS suite.
function M.install(env)
    env = env or _G
    env.describe   = M.describe
    env.it         = M.it
    env.xit        = M.xit
    env.beforeEach = M.beforeEach
    env.afterEach  = M.afterEach
    env.expect     = M.expect
    return env
end

return M



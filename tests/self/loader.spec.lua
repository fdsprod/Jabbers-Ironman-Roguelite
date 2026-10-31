-- Harness self-test: the engine module-namespace loader.
--
-- The spec that earns its keep. It pins the exact semantics that let mod
-- source load unmodified. If the loader drifts, unit specs keep passing while
-- testing something the game would never execute.

local H = require("harness.init")
local loader = H.loader

-- Synthetic .script files, so loader semantics are tested against
-- known-minimal inputs rather than the real mod.
local FIXTURES = "self/fixtures"

describe("harness/loader", function()

    beforeEach(function()
        H.boot{ script_dir = FIXTURES }
        -- boot() resets loader and fakes state but deliberately does not wipe
        -- _G, so stdlib tables a module mutated stay mutated. Clear the one
        -- field these fixtures write, or the "shared table" spec below sees a
        -- leftover from an earlier case.
        math.fixture_added = nil
    end)

    describe("parse_namespace()", function()
        -- Mirrors CScriptStorage::parse_namespace, script_storage.cpp:575.

        describe("given a flat namespace name", function()
            it("returns the assignment fragment", function()
                local b = loader.parse_namespace("soulslike")
                expect(b).toBe("soulslike=")
            end)

            it("returns an empty closing fragment", function()
                local _, c = loader.parse_namespace("soulslike")
                expect(c).toBe("")
            end)
        end)

        describe("given a dotted namespace name", function()
            it("opens a nested table in the assignment fragment", function()
                local b = loader.parse_namespace("a.b")
                expect(b).toBe("a={b=")
            end)

            it("returns the matching closing brace", function()
                local _, c = loader.parse_namespace("a.b")
                expect(c).toBe("}")
            end)
        end)
    end)

    describe("build_prologue()", function()
        describe("given any module name", function()
            it("emits no newlines, so source line numbers stay aligned", function()
                -- file_header_old (script_storage.cpp:22) is one C string built
                -- from backslash continuations. Zero newlines keeps every stack
                -- trace pointing at the real line.
                expect(loader.build_prologue("thing")).never.toContain("\n")
            end)
        end)
    end)

    describe("load()", function()

        describe("given a script that raises on its own line 3", function()
            it("reports the error at line 3", function()
                expect(function() loader.load("fixture_lines") end).toThrow(":3:")
            end)
        end)

        describe("given a script that assigns a bare global", function()
            it("stores it on the module table", function()
                loader.load("fixture_scope")
                expect(_G.fixture_scope.MODULE_LOCAL).toBe("yes")
            end)

            it("does not leak it into _G", function()
                loader.load("fixture_scope")
                expect(rawget(_G, "MODULE_LOCAL")).toBeNil()
            end)
        end)

        describe("given a script that declares function _G.X", function()
            it("installs it as a real global", function()
                loader.load("fixture_scope")
                expect(rawget(_G, "fixture_explicit_global")).toBeType("function")
                expect(_G.fixture_explicit_global()).toBe("global")
            end)
        end)

        describe("given a script that writes a field on a global table", function()
            -- `function math.clamp(...)` in soulslike.script: the READ of
            -- `math` falls through __index to _G.math, then the WRITE lands on
            -- that real table. The mod genuinely extends the stdlib.
            it("mutates the shared table, not a copy", function()
                expect(math.fixture_added).toBeNil()      -- precondition
                loader.load("fixture_scope")
                expect(math.fixture_added).toBeType("function")
                expect(math.fixture_added()).toBe("mutated")
            end)
        end)

        describe("given a script that reads an outer global", function()
            it("falls through to _G", function()
                _G.OUTER_VALUE = "from-globals"
                loader.load("fixture_scope")
                expect(_G.fixture_scope.read_outer()).toBe("from-globals")
                _G.OUTER_VALUE = nil
            end)
        end)

        describe("given any loaded script", function()
            it("exposes script_name() returning the module name", function()
                loader.load("fixture_scope")
                expect(_G.fixture_scope.who()).toBe("fixture_scope")
            end)

            it("installs the module table in _G under its own name", function()
                loader.load("fixture_scope")
                expect(rawget(_G, "fixture_scope")).toBeType("table")
            end)
        end)

        describe("given a script already loaded", function()
            it("does not re-execute it", function()
                loader.load("fixture_counter")
                local first = _G.fixture_counter.instance
                loader.load("fixture_counter")
                expect(_G.fixture_counter.instance).toBe(first)
            end)

            it("records only one entry in load_order", function()
                loader.load("fixture_counter")
                loader.load("fixture_counter")

                local n = 0
                for _, name in ipairs(loader.load_order) do
                    if name == "fixture_counter" then n = n + 1 end
                end
                expect(n).toBe(1)
            end)
        end)

        describe("given two scripts that reference each other at file scope", function()
            it("does not recurse infinitely", function()
                expect(function() loader.load("fixture_circular_a") end).never.toThrow()
            end)

            it("still installs the module", function()
                loader.load("fixture_circular_a")
                expect(_G.fixture_circular_a).toBeDefined()
            end)
        end)
    end)

    describe("autoload via the _G metatable", function()
        -- auto_load, script_engine.cpp:257, installed at :270.

        describe("given a global with no matching script", function()
            it("resolves to nil rather than raising", function()
                -- Mod code leans on this: soulslike_scenarios.script:113 does
                -- `local dte = demonized_time_events` for an optional mod.
                local v
                expect(function() v = _G.definitely_not_a_real_script_name end)
                    .never.toThrow()
                expect(v).toBeNil()
            end)

            it("records the miss so it stops retrying", function()
                local _ = _G.no_such_module_xyz
                expect(loader.missing["no_such_module_xyz"]).toBe(true)
            end)
        end)

        describe("given a global with a matching script", function()
            it("loads it on first touch", function()
                expect(rawget(_G, "fixture_auto")).toBeNil()   -- precondition
                expect(_G.fixture_auto.MARKER).toBe("autoloaded")
            end)
        end)
    end)

    describe("upvalue()", function()
        -- What makes compute_fatal_hit_info testable without editing the mod.

        describe("given an exported function that references a file-local", function()
            it("returns the file-local function", function()
                loader.load("fixture_upvalue")
                local hidden = loader.upvalue(_G.fixture_upvalue.exported, "hidden_helper")
                expect(hidden).toBeType("function")
                expect(hidden(3)).toBe(6)
            end)
        end)

        describe("given a name that is not an upvalue", function()
            it("returns nil", function()
                loader.load("fixture_upvalue")
                expect(loader.upvalue(_G.fixture_upvalue.exported, "nope")).toBeNil()
            end)
        end)
    end)

    describe("load_string_table()", function()
        beforeEach(function() H.boot() end)

        it("derives the text directory from script_dir", function()
            expect(loader.text_dir()).toContain("configs/text")
        end)

        it("finds the shipped English tables", function()
            expect(#loader.string_table_files("eng")).toBeGreaterThan(0)
        end)

        it("reads string ids out of them", function()
            expect(loader.load_string_table("eng")["ui_mcm_roguelite_title"]).toBe(true)
        end)

        it("reads the Russian tables too", function()
            expect(loader.load_string_table("rus")["ui_mcm_roguelite_title"]).toBe(true)
        end)

        it("returns an id the mod actually declares", function()
            local ids = loader.load_string_table("eng")
            expect(ids["ui_mcm_roguelite_title"]).toBe(true)
        end)

        it("does not invent ids", function()
            expect(loader.load_string_table("eng")["ui_mcm_roguelite_not_a_real_key"]).toBeNil()
        end)

        -- A mod need not ship every language, so an absent directory is empty
        -- rather than an error.
        it("returns an empty set for a language that is not shipped", function()
            expect(loader.load_string_table("zzz")).toEqual({})
        end)

        it("ignores a file that does not exist", function()
            expect(loader.load_string_table("eng", { "no_such_file.xml" })).toEqual({})
        end)
    end)
end)

return true

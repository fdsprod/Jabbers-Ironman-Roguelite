-- Harness self-test: the luabind `class` shim.
-- If these fail, every spec that constructs a scenario object is meaningless.

local H = require("harness.init")

describe("harness/class", function()

    beforeEach(function() H.boot() end)

    describe("class(name)", function()

        describe("given a name", function()
            it("installs a constructor-callable global under that name", function()
                class "Widget"
                expect(_G.Widget).toBeDefined()
                expect(_G.Widget).toBeType("table")
            end)

            it("rejects a non-string name", function()
                expect(function() class({}) end).toThrow("expected class name")
            end)
        end)

        describe("given a declared __init", function()
            it("runs it on construction with the constructor arguments", function()
                class "Widget"
                function Widget:__init(a, b) self.a, self.b = a, b end

                local w = Widget(1, 2)
                expect(w.a).toBe(1)
                expect(w.b).toBe(2)
            end)
        end)

        describe("given no __init at all", function()
            it("still constructs an instance", function()
                class "Bare"
                expect(Bare()).toBeDefined()
            end)
        end)
    end)

    describe("instance member lookup", function()

        it("resolves methods declared on the class", function()
            class "Greeter"
            function Greeter:__init(n) self.n = n end
            function Greeter:hello() return "hi " .. self.n end

            expect(Greeter("bob"):hello()).toBe("hi bob")
        end)

        it("keeps per-instance state separate", function()
            class "Counter"
            function Counter:__init() self.items = {} end
            function Counter:add(v) table.insert(self.items, v) end

            local a, b = Counter(), Counter()
            a:add(1)
            expect(a.items).toHaveLength(1)
            expect(b.items).toHaveLength(0)
        end)
    end)

    describe("class(name)(Base)", function()

        describe("given a base class", function()
            it("makes the base's methods reachable from the derived instance", function()
                class "Base1"
                function Base1:__init() self.tag = "base" end
                function Base1:shared() return "from-base" end

                class "Derived1" (Base1)
                function Derived1:__init() super() end

                expect(Derived1():shared()).toBe("from-base")
            end)

            it("rejects a base that is not a class table", function()
                class "Derived1b"
                expect(function() _G.class("Bad")("not a class") end)
                    .toThrow("expected class to derive from")
            end)
        end)

        describe("given the base declares __init", function()
            -- create_class.cpp:36-62 skips __init and __finalize when copying
            -- the base member table down.
            it("does NOT inherit __init", function()
                class "Base4"
                function Base4:__init() self.ran = true end

                class "Derived4" (Base4)   -- deliberately no __init

                expect(Derived4().ran).toBeNil()
            end)

            it("does NOT inherit __finalize", function()
                class "Base5"
                function Base5:__init() end
                function Base5:__finalize() end

                class "Derived5" (Base5)
                function Derived5:__init() super() end

                expect(rawget(Derived5, "__finalize")).toBeNil()
            end)
        end)
    end)

    describe("super()", function()

        describe("given a two-level chain", function()
            it("runs the base __init", function()
                class "Base2"
                function Base2:__init() self.tag = "base" end

                class "Derived2" (Base2)
                function Derived2:__init() super() end

                expect(Derived2().tag).toBe("base")
            end)

            it("forwards its arguments to the base __init", function()
                class "Base2b"
                function Base2b:__init(state) self.state = state end

                class "Derived2b" (Base2b)
                function Derived2b:__init(state)
                    super(state)
                    self.extra = "d"
                end

                local d = Derived2b({ k = "v" })
                expect(d.state.k).toBe("v")
                expect(d.extra).toBe("d")
            end)
        end)

        describe("given a three-level chain", function()
            -- The subtle one. A naive "parent of the instance's class"
            -- implementation calls A twice and never runs B.
            it("resolves against the class whose __init is running", function()
                local order = {}

                class "A3"
                function A3:__init() order[#order + 1] = "A" end

                class "B3" (A3)
                function B3:__init() super(); order[#order + 1] = "B" end

                class "C3" (B3)
                function C3:__init() super(); order[#order + 1] = "C" end

                C3()
                expect(order).toEqual({ "A", "B", "C" })
            end)
        end)

        describe("after construction completes", function()
            it("is removed from the global scope", function()
                class "Base6"
                function Base6:__init() end
                class "Derived6" (Base6)
                function Derived6:__init() super() end

                Derived6()
                expect(rawget(_G, "super")).toBeNil()
            end)
        end)
    end)

    describe("error handling", function()

        describe("given __init raises", function()
            it("propagates the original error to the caller", function()
                class "Boom"
                function Boom:__init() error("kaboom") end

                expect(function() Boom() end).toThrow("kaboom")
            end)

            it("still restores super", function()
                class "Boom2"
                function Boom2:__init() error("kaboom") end

                pcall(function() Boom2() end)
                expect(rawget(_G, "super")).toBeNil()
            end)
        end)
    end)

    describe("interaction with a local named `class`", function()
        -- soulslike_scenarios.script:738 does exactly this:
        --     local class = ini_sys:r_string_ex(section,"class")
        describe("given a method shadows `class` with a local", function()
            it("does not disturb the shadowing method", function()
                class "Shadower"
                function Shadower:__init() end
                function Shadower:doit()
                    local class = "just a string"
                    return class
                end

                expect(Shadower():doit()).toBe("just a string")
            end)

            it("leaves the global usable afterwards", function()
                class "AfterShadow"
                function AfterShadow:__init() self.ok = true end
                expect(AfterShadow().ok).toBeTruthy()
            end)
        end)
    end)

    describe("is_instance()", function()
        it("matches the instance's own class", function()
            class "P" ; function P:__init() end
            expect(H.class.is_instance(P(), P)).toBeTruthy()
        end)

        it("matches an ancestor class", function()
            class "P2" ; function P2:__init() end
            class "Q2" (P2) ; function Q2:__init() super() end
            expect(H.class.is_instance(Q2(), P2)).toBeTruthy()
        end)

        it("does not match an unrelated class", function()
            class "P3" ; function P3:__init() end
            class "Unrelated" ; function Unrelated:__init() end
            expect(H.class.is_instance(P3(), Unrelated)).toBeFalsy()
        end)
    end)

    describe("registration lifetime", function()
        -- `class "X"` writes a true global and nothing in Lua removes it. Left
        -- alone, a spec that never loaded soulslike_scenarios would still find
        -- the class a PREVIOUS spec left on _G, and pass for the wrong reason.
        -- A fresh game has no classes until the declaring script runs.
        describe("given a class was declared before a re-boot", function()
            it("is gone from _G afterwards", function()
                class "LeakCanary" ; function LeakCanary:__init() end
                expect(_G.LeakCanary).toBeDefined()
                H.boot()
                expect(_G.LeakCanary).toBeNil()
            end)

            it("drops it from the registered list", function()
                class "LeakCanary2" ; function LeakCanary2:__init() end
                H.boot()
                expect(H.class.registered_names()).toEqual({})
            end)
        end)

        describe("given classes declared in this boot", function()
            it("reports them", function()
                class "Alpha" ; class "Beta"
                expect(H.class.registered_names()).toEqual({ "Alpha", "Beta" })
            end)
        end)

        it("does not disturb unrelated globals", function()
            _G.__not_a_class = 7
            class "Gamma"
            H.boot()
            expect(_G.__not_a_class).toBe(7)
            _G.__not_a_class = nil
        end)
    end)
end)

return true

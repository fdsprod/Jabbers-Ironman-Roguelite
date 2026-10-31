-- Harness self-test: RNG accounting, the clsid registry, the save-file shim
-- and the online-stalker registry.
--
-- The save-FS specs matter because on_console_execute's pruning walk
-- (soulslike.script:658-695) does a real io.open on each sibling save before
-- decoding it. Without a working shim the loop body never runs, and a spec
-- asserting "no save was deleted" would pass for the wrong reason.

local H = require("harness.init")
local F = H.fakes

describe("harness/fakes", function()

    describe("random_count()", function()

        beforeEach(function() H.boot() end)

        it("starts at zero", function()
            expect(F.random_count()).toBe(0)
        end)

        it("counts every roll", function()
            F.set_random_const(0.5)
            math.random(); math.random(); math.random()
            expect(F.random_count()).toBe(3)
        end)

        it("counts ranged rolls too", function()
            F.set_random_const(1)
            math.random(1, 100)
            expect(F.random_count()).toBe(1)
        end)

        -- Reading the count must not consume a queued value, or an exact-budget
        -- assertion would change the behavior it is measuring.
        it("does not consume a queued value", function()
            F.set_random_sequence{ 0.1, 0.2 }
            F.random_count(); F.random_count()
            expect(math.random()).toBeCloseTo(0.1)
        end)

        it("resets on boot", function()
            F.set_random_const(0.5)
            math.random()
            H.boot()
            expect(F.random_count()).toBe(0)
        end)
    end)

    describe("math.random enforcement", function()

        beforeEach(function() H.boot() end)

        it("raises when a spec has not pinned it", function()
            expect(function() math.random() end).toThrow("set_random")
        end)

        it("raises past the end of a queued sequence", function()
            F.set_random_sequence{ 0.5 }
            math.random()
            expect(function() math.random() end).toThrow("only 1 values were queued")
        end)
    end)

    describe("clsid registry", function()

        beforeEach(function() H.boot() end)

        -- The real predicates resolve `cls or obj:clsid()` (_g.script:3081), and
        -- soulslike.find_closest_enemy:307 calls them with obj=nil and an
        -- explicit clsid, so dispatching on the tag alone is not enough.
        it("classifies by clsid when the object is nil", function()
            expect(_G.IsStalker(nil, F.clsid_for("stalker"))).toBe(true)
            expect(_G.IsMonster(nil, F.clsid_for("monster"))).toBe(true)
        end)

        it("still classifies by the _kind tag when no clsid is given", function()
            expect(_G.IsMonster(H.builders.make_monster())).toBe(true)
        end)

        it("lets the clsid argument win over the object", function()
            local stalker = H.builders.make_stalker()
            expect(_G.IsMonster(stalker, F.clsid_for("monster"))).toBe(true)
        end)

        it("is false for a nil object with no clsid", function()
            expect(_G.IsStalker(nil)).toBe(false)
        end)

        it("returns an opaque value, never a number", function()
            -- Engine clsids are runtime ordinals of the sorted class registry
            -- (object_factory_script.cpp:85), so a numeric fixture would be
            -- asserting a fiction.
            expect(F.clsid_for("weapon")).toBeType("string")
        end)

        -- Grenades derive from CMissile, not CWeapon (Grenade.h:6), and Anomaly's
        -- weapon_classes table holds no grenade clsids (_g.script:3081-3149).
        it("keeps grenades disjoint from weapons", function()
            expect(_G.IsWeapon(nil, F.clsid_for("grenade"))).toBe(false)
            expect(_G.IsGrenade(nil, F.clsid_for("grenade"))).toBe(true)
        end)
    end)

    describe("save file shim", function()

        beforeEach(function()
            H.boot()
            F.install_save_fs()
        end)

        it("serves a staged save through io.open", function()
            F.set_save("autosave", { soulslike = { uuid = "abc" } })
            local f = io.open("saves/autosave.scoc", "rb")
            expect(f).toBeDefined()
            expect(_G.alife_storage_manager.decode(f:read("*all")).soulslike.uuid).toBe("abc")
        end)

        it("returns nil for a save that was never staged", function()
            expect(io.open("saves/missing.scoc", "rb")).toBeNil()
        end)

        it("models an unreadable file when staged with nil", function()
            F.set_save("corrupt", nil)
            expect(io.open("saves/corrupt.scoc", "rb")).toBeNil()
        end)

        -- The module loader reads .script files off disk with io.open
        -- (loader.lua:83), so the shim must not swallow ordinary paths.
        it("delegates non-save paths to the real io.open", function()
            local f = io.open("run.lua", "r")
            expect(f).toBeDefined()
            expect(f:read("*l")).toContain("Test entry point")
            f:close()
        end)

        it("is uninstalled by the next boot", function()
            F.set_save("autosave", { soulslike = {} })
            H.boot()
            expect(io.open("saves/autosave.scoc", "rb")).toBeNil()
        end)

        it("survives being installed twice", function()
            F.install_save_fs()
            F.set_save("s", { soulslike = { uuid = "u" } })
            expect(io.open("saves/s.scoc", "rb")).toBeDefined()
        end)
    end)

    describe("set_online_stalkers()", function()

        beforeEach(function() H.boot() end)

        -- db.OnlineStalkers plus db.storage are the only inputs to
        -- find_closest_enemy_stalker / _friendly_stalker (soulslike.script:370).
        it("fills OnlineStalkers with the ids", function()
            local a, b = H.builders.make_stalker(), H.builders.make_stalker()
            F.set_online_stalkers{ a, b }
            expect(_G.db.OnlineStalkers).toEqual({ a:id(), b:id() })
        end)

        it("puts each npc in db.storage", function()
            local a = H.builders.make_stalker()
            F.set_online_stalkers{ a }
            expect(_G.db.storage[a:id()].object).toBe(a)
        end)

        it("registers them for level.object_by_id", function()
            local a = H.builders.make_stalker()
            F.set_online_stalkers{ a }
            expect(_G.level.object_by_id(a:id())).toBe(a)
        end)

        it("replaces the previous list rather than appending", function()
            F.set_online_stalkers{ H.builders.make_stalker() }
            F.set_online_stalkers{}
            expect(#_G.db.OnlineStalkers).toBe(0)
        end)
    end)

    describe("set_level()", function()

        beforeEach(function() H.boot() end)

        it("changes what level.name() reports", function()
            F.set_level("jupiter")
            expect(_G.level.name()).toBe("jupiter")
        end)

        it("defaults to zaton, which is a valid outdoor level", function()
            expect(_G.level.name()).toBe("zaton")
            expect(_G.level_weathers.valid_levels[_G.level.name()]).toBe(true)
        end)
    end)
end)

return true

-- Trader reputation across lives. Most traders are on another level at any moment, so
-- a trader being offline at death or at the restore is the normal case.
--
-- Rep is an int in the engine, so the values here stay whole through the 2% penalty:
-- 1000 > 980 and 5000 > 4900 > 4802.

local H = require("harness.init")

describe("trader reputation", function()
    local model
    local MODULES = { "roguelite_module_trader_rep" }
    local NAME = "Owl"

    local function met_trader(name, rep)
        local id = model.trader{ name = name, rep = rep }
        model.meet(id)
        return id
    end

    -- The next life, with one trader in it at their new-game rep of `rep`. Returns the
    -- trader's new id. opts.online = false puts them on another level at the restore.
    local function next_life(opts)
        opts = opts or {}
        local id
        H.new_life{
            modules = MODULES,
            before_first_update = function()
                if opts.setup then opts.setup() end
                id = model.trader{
                    name = opts.name or NAME,
                    rep = opts.rep or 0,
                    online = opts.online,
                    story_id = opts.story_id,
                }
            end,
        }
        return id
    end

    local function arrive(id)
        model.set_online(id, true)
        H.frames(1)
    end

    local function leave(id) model.set_online(id, false) end

    -- What the player's actions do to a trader standing in front of them.
    local function set_rep(id, rep) level.object_by_id(id):set_character_reputation(rep) end

    -- A level change saves first, and nothing after that save reaches the next level.
    -- Scripts re-execute, so a net_destroy sent on the way out is forgotten.
    local function change_level_away_from(id)
        H.save()
        leave(id)
        H.reload()
        H.frames(1)
    end

    beforeEach(function()
        H.boot_game{ modules = MODULES }
        model = H.alife
    end)

    describe("given a trader online at death and at the restore", function()
        it("keeps their rep, minus the penalty", function()
            met_trader(NAME, 1000)
            H.die()
            local id = next_life()
            expect(model.rep_of(id)).toBeCloseTo(980)
        end)

        it("does not store a trader the player never met", function()
            model.trader{ name = NAME, rep = 1000 }
            H.die()
            local id = next_life()
            expect(model.rep_of(id)).toBeCloseTo(0)
        end)

        it("does not apply a value below the new-game rep", function()
            met_trader(NAME, 100)
            H.die()
            local id = next_life{ rep = 500 }
            expect(model.rep_of(id)).toBeCloseTo(500)
        end)

        it("stores a story trader the player never met", function()
            model.trader{ name = NAME, rep = 1000, story_id = "esc_m_trader" }
            H.die()
            local id = next_life{ story_id = "esc_m_trader" }
            expect(model.rep_of(id)).toBeCloseTo(980)
        end)

        it("leaves the rep alone when the restore is turned off", function()
            met_trader(NAME, 1000)
            H.die()
            local id = next_life{
                setup = function() model.set_mcm("is_trader_rep_restore_enabled", false) end,
            }
            expect(model.rep_of(id)).toBeCloseTo(0)
        end)
    end)

    -- FIXES: only traders online at death were stored.
    describe("given a met trader who went offline before death", function()
        it("still has their rep next life, after walking away", function()
            local id = met_trader(NAME, 1000)
            leave(id)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)

        it("still has their rep next life, after a level change", function()
            local id = met_trader(NAME, 1000)
            change_level_away_from(id)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)

        it("uses the rep they had when they left", function()
            local id = met_trader(NAME, 1000)
            set_rep(id, 5000)
            leave(id)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(4900)
        end)

        it("keeps them alongside a trader who stayed online", function()
            local away = met_trader("Owl", 1000)
            met_trader("Cat", 5000)
            leave(away)
            H.die()
            local cat
            local owl = next_life{
                setup = function() cat = model.trader{ name = "Cat" } end,
            }
            expect(model.rep_of(cat)).toBeCloseTo(4900)
            expect(model.rep_of(owl)).toBeCloseTo(980)
        end)

        it("still ignores a trader the player never met", function()
            local id = model.trader{ name = NAME, rep = 1000 }
            leave(id)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(0)
        end)

        it("does not store a met stalker who is not a trader", function()
            local id = model.stalker{ name = NAME, rep = 1000 }
            model.meet(id)
            leave(id)
            H.die()
            local again
            H.new_life{
                modules = MODULES,
                before_first_update = function() again = model.stalker{ name = NAME } end,
            }
            expect(model.rep_of(again)).toBeCloseTo(0)
        end)

        -- FIXES: scripts re-execute on a load, so what was seen must go through
        -- save_state and load_state.
        it("is still known at death after a save and reload", function()
            local id = met_trader(NAME, 1000)
            leave(id)
            H.save()
            H.reload()
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)
    end)

    -- FIXES: only traders online at the first update were restored.
    describe("given a trader offline at the restore", function()
        beforeEach(function()
            met_trader(NAME, 1000)
            H.die()
        end)

        it("gets the value when they come online", function()
            local id = next_life{ online = false }
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(980)
        end)

        it("still gets the value after a save and reload", function()
            local id = next_life{ online = false }
            H.save()
            H.reload()
            H.frames(1)
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(980)
        end)

        it("does not apply a value below their new-game rep", function()
            local id = next_life{ online = false, rep = 2000 }
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(2000)
        end)

        it("leaves the rep alone when the restore is turned off", function()
            local id = next_life{
                online = false,
                setup = function() model.set_mcm("is_trader_rep_restore_enabled", false) end,
            }
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(0)
        end)
    end)

    -- FIXES: a value restored but not applied was not written to the next state file.
    describe("given a trader who stays offline for the whole of a life", function()
        beforeEach(function()
            met_trader(NAME, 5000)
            H.die()
            next_life{ online = false }
        end)

        it("reaches the next life with one penalty per life, when they come online", function()
            H.die()
            local id = next_life{ online = false }
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(4802)
        end)

        it("reaches the next life with one penalty per life, online at the restore", function()
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(4802)
        end)

        it("reaches the next life after a save and reload in between", function()
            H.save()
            H.reload()
            H.frames(1)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(4802)
        end)
    end)

    -- The 980 check is what makes the first two red today, since nothing is applied at
    -- all. The rest guards against a fix that applies the value again on a later spawn.
    describe("given a value already applied", function()
        beforeEach(function()
            met_trader(NAME, 1000)
            H.die()
        end)

        it("is not applied again when the trader goes offline and back", function()
            local id = next_life{ online = false }
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(980)
            set_rep(id, 500)
            leave(id)
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(500)
        end)

        it("is not applied again after a save and reload", function()
            local id = next_life{ online = false }
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(980)
            set_rep(id, 500)
            H.save()
            H.reload()
            H.frames(1)
            expect(model.rep_of(id)).toBeCloseTo(500)
        end)

        it("is not applied again when it was applied at the restore", function()
            local id = next_life()
            set_rep(id, 500)
            leave(id)
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(500)
        end)
    end)

    describe("given a rep change in the new life", function()
        local id

        beforeEach(function()
            met_trader(NAME, 1000)
            H.die()
            id = next_life()
            model.meet(id)
        end)

        -- FIXES: the older value must lose, and an offline trader must not lose it all.
        it("uses a raised rep at the next death, once they are offline", function()
            set_rep(id, 5000)
            leave(id)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(4900)
        end)

        it("uses a lowered rep at the next death, once they are offline", function()
            set_rep(id, 500)
            leave(id)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(490)
        end)

        it("uses it at the next death when they are online", function()
            set_rep(id, 5000)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(4900)
        end)
    end)

    -- FIXES: contacts are wiped by a new game, so a trader given their rep back and not
    -- spoken to again dropped out of the next state file.
    describe("given a value applied to a trader not met again that life", function()
        it("reaches the next life", function()
            met_trader(NAME, 5000)
            H.die()
            next_life()
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(4802)
        end)
    end)

    -- FIXES: is_trader raises for an NPC with no db.storage entry
    -- (utils_obj.script:84). That ended the whole loop, and call_module caught it, so
    -- every other trader was lost.
    describe("given an online NPC with no db.storage entry", function()
        local function broken_npc()
            local id = model.stalker{ name = "Broken" }
            model.drop_storage(id)
        end

        it("still saves the other trader's rep at death", function()
            broken_npc()
            met_trader(NAME, 1000)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)

        it("still restores the other trader's rep", function()
            met_trader(NAME, 1000)
            H.die()
            expect(model.rep_of(next_life{ setup = broken_npc })).toBeCloseTo(980)
        end)
    end)
end)

return true

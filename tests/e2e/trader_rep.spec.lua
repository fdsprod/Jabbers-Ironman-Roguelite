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
                id = (opts.make or model.trader){
                    name = opts.name or NAME,
                    section = opts.section,
                    rep = opts.rep or 0,
                    online = opts.online,
                    relation = opts.relation,
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

    -- Sidorovich (esc_m_trader) is section m_trader in all.spawn, class AI_TRD_S, bound by
    -- bind_trader (m_person.ltx:4-12). So he is not in db.OnlineStalkers (db.script:73) and
    -- no net callback says he came or went.
    describe("given a story trader", function()
        local STORY = "esc_m_trader"
        local FEW_FRAMES = 5

        local function sidorovich(rep)
            return model.script_trader{ name = NAME, rep = rep, story_id = STORY }
        end

        local function story_life(opts)
            opts = opts or {}
            opts.make = model.script_trader
            opts.story_id = STORY
            return next_life(opts)
        end

        local function story_arrives(id)
            model.set_online(id, true)
            H.frames(FEW_FRAMES)
        end

        it("keeps their rep when online at death and at the restore", function()
            sidorovich(1000)
            H.die()
            expect(model.rep_of(story_life())).toBeCloseTo(980)
        end)

        -- FIXES: restored only if online at the first update.
        it("gets the value within a few frames of coming online", function()
            sidorovich(1000)
            H.die()
            local id = story_life{ online = false }
            story_arrives(id)
            expect(model.rep_of(id)).toBeCloseTo(980)
        end)

        it("still gets the value after a save and reload before coming online", function()
            sidorovich(1000)
            H.die()
            local id = story_life{ online = false }
            H.save()
            H.reload()
            H.frames(1)
            story_arrives(id)
            expect(model.rep_of(id)).toBeCloseTo(980)
        end)

        -- FIXES: stored only if online at death, and nothing marks them leaving.
        it("keeps a changed rep after going offline before death", function()
            local id = sidorovich(1000)
            set_rep(id, 5000)
            H.frames(1)
            leave(id)
            H.die()
            expect(model.rep_of(story_life())).toBeCloseTo(4900)
        end)

        it("does not get an applied value again when they go offline and back", function()
            sidorovich(1000)
            H.die()
            local id = story_life{ online = false }
            story_arrives(id)
            expect(model.rep_of(id)).toBeCloseTo(980)
            set_rep(id, 500)
            leave(id)
            story_arrives(id)
            expect(model.rep_of(id)).toBeCloseTo(500)
        end)

        it("reaches the next life with one penalty per life, after staying offline for one", function()
            sidorovich(5000)
            H.die()
            story_life{ online = false }
            H.frames(FEW_FRAMES)
            H.die()
            local id = story_life{ online = false }
            story_arrives(id)
            expect(model.rep_of(id)).toBeCloseTo(4802)
        end)

        -- FIXES: the module asks for "red_tech_forester", which no stock object has.
        -- all.spawn gives red_m_lesnik, section m_lesnik, story id red_forester_tech.
        it("keeps the Forester's rep, under the story id he really has", function()
            model.script_trader{ name = NAME, section = "m_lesnik", rep = 1000, story_id = "red_forester_tech" }
            H.die()
            local id = next_life{ make = model.script_trader, section = "m_lesnik", story_id = "red_forester_tech" }
            expect(model.rep_of(id)).toBeCloseTo(980)
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

        -- The two above never reach is_trader: the broken NPC is unmet and has nothing
        -- pending. These two do.
        it("still saves the other trader's rep when the broken NPC is one the player met", function()
            local id = model.stalker{ name = "Broken" }
            model.meet(id)
            model.drop_storage(id)
            met_trader(NAME, 1000)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)

        it("still restores the other trader's rep when the broken NPC has a value waiting", function()
            met_trader("Broken", 500)
            met_trader(NAME, 1000)
            H.die()
            local id = next_life{
                setup = function() model.drop_storage(model.stalker{ name = "Broken" }) end,
            }
            expect(model.rep_of(id)).toBeCloseTo(980)
        end)

        -- is_trader answers from the community before it reaches db.storage, and the loop
        -- falls back to level.object_by_id for this NPC.
        it("still stores a met trader who is the one with no entry", function()
            model.drop_storage(met_trader(NAME, 1000))
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)
    end)

    -- The design keys by name, so who may receive a value is all that stands between it
    -- and any other NPC called the same.
    describe("given a stalker who is not a trader, with a trader's name", function()
        beforeEach(function()
            met_trader(NAME, 1000)
            H.die()
        end)

        it("does not take the value at the restore", function()
            expect(model.rep_of(next_life{ make = model.stalker })).toBeCloseTo(0)
        end)

        it("does not take the value when they come online", function()
            local id = next_life{ make = model.stalker, online = false }
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(0)
        end)

        it("leaves the value for the trader", function()
            local trader
            local id = next_life{
                make = model.stalker,
                setup = function() trader = model.trader{ name = NAME, online = false } end,
            }
            arrive(trader)
            expect(model.rep_of(id)).toBeCloseTo(0)
            expect(model.rep_of(trader)).toBeCloseTo(980)
        end)
    end)

    describe("given a trader hostile to the player", function()
        local function turn_hostile(id) model.set_relation(id, game_object.enemy) end
        local function make_peace(id) model.set_relation(id, game_object.neutral) end

        it("is not stored when hostile at death", function()
            turn_hostile(met_trader(NAME, 1000))
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(0)
        end)

        it("keeps the value known before they turned hostile", function()
            local id = met_trader(NAME, 1000)
            H.save()
            set_rep(id, 5000)
            turn_hostile(id)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)

        it("does not store them when they leave hostile", function()
            local id = met_trader(NAME, 1000)
            turn_hostile(id)
            leave(id)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(0)
        end)

        describe("at the restore", function()
            beforeEach(function()
                met_trader(NAME, 1000)
                H.die()
            end)

            it("does not give them the value while online and hostile", function()
                local id = next_life{ relation = game_object.enemy }
                expect(model.rep_of(id)).toBeCloseTo(0)
            end)

            it("does not give them the value when they come online hostile", function()
                local id = next_life{ online = false, relation = game_object.enemy }
                arrive(id)
                expect(model.rep_of(id)).toBeCloseTo(0)
            end)

            it("gives them the value when they next come online at peace", function()
                local id = next_life{ relation = game_object.enemy }
                leave(id)
                make_peace(id)
                arrive(id)
                expect(model.rep_of(id)).toBeCloseTo(980)
            end)

            it("gives them the value after a load, once at peace", function()
                local id = next_life{ relation = game_object.enemy }
                make_peace(id)
                H.save()
                H.reload()
                H.frames(1)
                expect(model.rep_of(id)).toBeCloseTo(980)
            end)

            -- Met, online and at peace, but still on the new game's rep: that must not
            -- replace the value waiting for them.
            it("still carries the value when met at peace before receiving it", function()
                local id = next_life{ relation = game_object.enemy }
                model.meet(id)
                make_peace(id)
                H.die()
                expect(model.rep_of(next_life())).toBeCloseTo(960)
            end)
        end)
    end)

    describe("given a dead trader", function()
        local function kill(id) alife():object(id):kill() end

        it("keeps the value known before they died", function()
            local id = met_trader(NAME, 1000)
            H.save()
            set_rep(id, 5000)
            kill(id)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)

        it("does not store one first seen dead at death", function()
            kill(met_trader(NAME, 1000))
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(0)
        end)

        describe("at the restore", function()
            local function dead_trader(opts)
                local id = model.trader(opts)
                kill(id)
                return id
            end

            beforeEach(function()
                met_trader(NAME, 1000)
                H.die()
            end)

            it("does not give the value to the corpse", function()
                expect(model.rep_of(next_life{ make = dead_trader })).toBeCloseTo(0)
            end)

            it("keeps the value for the next life", function()
                next_life{ make = dead_trader }
                H.die()
                expect(model.rep_of(next_life())).toBeCloseTo(960)
            end)
        end)
    end)

    -- db.del_actor clears db.actor in the actor's net_destroy (bind_stalker.script:84,
    -- db.script:108-112), so an NPC destroyed after that sees nil. GUESS: which of the
    -- actor and an NPC comes first, on the way down and on the way up.
    describe("given no db.actor", function()
        local function without_actor(func)
            local actor = db.actor
            db.actor = nil
            func()
            db.actor = actor
        end

        it("leaves the known value alone when a trader goes offline", function()
            local id = met_trader(NAME, 1000)
            H.save()
            set_rep(id, 5000)
            without_actor(function() leave(id) end)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)

        -- Nothing else looks at a trader who is online already.
        it("gives a trader the value on the first update when they spawned before the actor", function()
            met_trader(NAME, 1000)
            H.die()
            local id = next_life{ online = false }
            H.save()
            H.reload()
            without_actor(function()
                model.set_online(id, true)
                model.frame()
            end)
            expect(model.rep_of(id)).toBeCloseTo(0)
            H.frames(1)
            expect(model.rep_of(id)).toBeCloseTo(980)
        end)
    end)

    describe("given the penalty", function()
        it("takes it from a negative rep as well, which lowers it", function()
            met_trader(NAME, -1000)
            H.die()
            expect(model.rep_of(next_life{ rep = -2000 })).toBeCloseTo(-1020)
        end)

        it("does not go below -4000", function()
            met_trader(NAME, -4000)
            H.die()
            expect(model.rep_of(next_life{ rep = -5000 })).toBeCloseTo(-4000)
        end)

        it("uses the percentage set in MCM", function()
            met_trader(NAME, 1000)
            H.die()
            local id = next_life{
                setup = function() model.set_mcm("trader_rep_penalty_percent", 0.5) end,
            }
            expect(model.rep_of(id)).toBeCloseTo(500)
        end)

        -- 1030 > 1009.4 > 1009 > 988.82 > 988. The fraction would carry 1009.4 > 989.21 > 989.
        it("drops the fraction before the next life's penalty, as the engine would", function()
            met_trader(NAME, 1030)
            H.die()
            next_life{ online = false }
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(988)
        end)

        -- -1030 > -1050.6 > -1050.
        it("truncates a negative value toward zero", function()
            met_trader(NAME, -1030)
            H.die()
            expect(model.rep_of(next_life{ rep = -5000 })).toBeCloseTo(-1050)
        end)
    end)

    describe("given a value refused because it is below the new-game rep", function()
        it("is gone, so a later loss of rep is not overwritten", function()
            met_trader(NAME, 100)
            H.die()
            local id = next_life{ rep = 500 }
            set_rep(id, 50)
            leave(id)
            arrive(id)
            expect(model.rep_of(id)).toBeCloseTo(50)
        end)
    end)

    describe("given a save written before this version", function()
        -- What another module's save_state leaves when this module wrote nothing.
        it("still stores traders after loading a save with neither key", function()
            SendScriptCallback("load_state", { roguelite_manager = {} })
            leave(met_trader(NAME, 1000))
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)

        it("still stores traders after loading a save with no mod data", function()
            SendScriptCallback("load_state", {})
            leave(met_trader(NAME, 1000))
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(980)
        end)

        -- pda.script:101 guards this too, since an old save can lack the table.
        it("does not raise when the save has no contacts", function()
            local id = model.trader{ name = NAME, rep = 1000 }
            alife_storage_manager.get_state().actor_contacts = nil
            leave(id)
            H.die()
            expect(model.rep_of(next_life())).toBeCloseTo(0)
        end)
    end)

    describe("given a game that is not Ironman", function()
        beforeEach(function() H.fakes.hardcore_mode = false end)

        it("writes nothing to the save", function()
            met_trader(NAME, 1000)
            H.save()
            expect(alife_storage_manager.get_state().roguelite_manager).toBeNil()
        end)

        it("reads nothing from the save", function()
            SendScriptCallback("load_state", { roguelite_manager = { trader_rep_pending = { [NAME] = 980 } } })
            expect(model.rep_of(model.trader{ name = NAME })).toBeCloseTo(0)
        end)
    end)

    describe("given a state file of another version", function()
        it("does not restore from it", function()
            roguelite_module_trader_rep.roguelite_load_state{ trader_rep_version = 2, trader_rep = { [NAME] = 1000 } }
            expect(model.rep_of(model.trader{ name = NAME })).toBeCloseTo(0)
        end)
    end)

    -- This runs on every frame of the game, so what it costs is the behaviour. Reading the
    -- story table is the first thing a look does.
    describe("the look for story traders", function()
        local function looks_during(func)
            local real = story_objects.object_id_by_story_id
            local looks = 0
            story_objects.object_id_by_story_id = setmetatable({}, {
                __index = function(_, k)
                    looks = looks + 1
                    return real[k]
                end,
            })
            func()
            story_objects.object_id_by_story_id = real
            return looks
        end

        local function few_frames() H.frames(5) end

        it("does not happen with nothing pending", function()
            model.script_trader{ name = NAME, story_id = "esc_m_trader", online = false }
            H.frames(1)
            expect(looks_during(few_frames)).toBe(0)
        end)

        it("stops once both have been seen, with a value still waiting elsewhere", function()
            model.script_trader{ name = "Sidorovich", rep = 1000, story_id = "esc_m_trader" }
            model.script_trader{ name = "Forester", rep = 1000, story_id = "red_forester_tech" }
            met_trader("Cat", 1000)
            H.die()
            local sidorovich, forester, cat
            H.new_life{
                modules = MODULES,
                before_first_update = function()
                    sidorovich = model.script_trader{ name = "Sidorovich", story_id = "esc_m_trader", online = false }
                    forester = model.script_trader{ name = "Forester", story_id = "red_forester_tech", online = false }
                    cat = model.trader{ name = "Cat", online = false }
                end,
            }
            expect(looks_during(few_frames)).toBeGreaterThan(0)

            model.set_online(sidorovich, true)
            model.set_online(forester, true)
            H.frames(1)
            expect(looks_during(few_frames)).toBe(0)
            expect(model.rep_of(cat)).toBeCloseTo(0)
        end)
    end)
end)

return true

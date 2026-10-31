-- Deferred callbacks: CreateTimeEvent / RemoveTimeEvent.
--
-- The mod uses these to continue work on a later frame, so the death->respawn
-- flow does NOT complete synchronously. Two sites depend on it:
--
--   HandleItemsAndRespawn (soulslike_scenarios.script:549) waits for the stash
--     object to exist before transferring items into it.
--   RespawnActor (:860) defers the ChangeLevel call.
--
-- Contract, from wait_for_stash_creation (:535): the callback returns true when
-- it is done and the event should be dropped, false to stay queued and be
-- retried on a later frame. We re-queue on false, which is what makes a spec
-- able to model "the stash is not online yet, then it is".

-- Two ways to drain it:
--
--   pump()     ignores delays and runs to completion. Most specs want "let the
--              deferred work finish", not a clock.
--   run_due()  one frame of the real ProcessEventQueue (_g.script:364-388):
--              only events whose time has come run. H.run_for drives it. A spec
--              that needs something to happen DURING a delay (dying halfway
--              through an animation) uses this.

local M = {}

local queue = {}
local seq = 0

local function now_ms()
    return require("harness.fakes").now()
end

-- A never-satisfied condition would spin forever. Bound it so the spec fails
-- with a clear message instead of hanging the runner.
M.max_passes = 32

function M.install(env)
    env = env or _G

    -- _g.script:339-352. The due time is time_global() + timer*1000 (:347).
    -- An event whose ids are already queued is ignored, not replaced (:345),
    -- so the first timer wins.
    env.CreateTimeEvent = function(a, b, delay, fn, ...)
        local key = tostring(a) .. "/" .. tostring(b)
        for i = 1, #queue do
            if queue[i].key == key then return true end
        end
        seq = seq + 1
        queue[#queue + 1] = {
            id    = seq,
            key   = key,
            delay = delay,
            due   = now_ms() + (delay or 0) * 1000,
            fn    = fn,
            args  = { ... },
            n     = select("#", ...),
        }
        return true
    end

    -- _g.script:359-363. Pushes an already-queued event's timer out; a name
    -- that is not queued is a no-op, not an error. Self-rearming tickers call
    -- this as their first statement, so it has to exist even when the spec
    -- drives the tick by hand and nothing is queued at all.
    env.ResetTimeEvent = function(a, b, delay)
        local key = tostring(a) .. "/" .. tostring(b)
        for i = 1, #queue do
            if queue[i].key == key then
                queue[i].delay = delay
                queue[i].due   = now_ms() + (delay or 0) * 1000
            end
        end
        return true
    end

    env.RemoveTimeEvent = function(a, b)
        local key = tostring(a) .. "/" .. tostring(b)
        for i = #queue, 1, -1 do
            if queue[i].key == key then table.remove(queue, i) end
        end
        return true
    end

    return env
end

--- Drain the queue. Events returning false are retried on the next pass, so a
--- chain (event A queues event B) settles in one pump() call.
--- Returns the number of callbacks invoked.
---
--- opts.passes bounds the number of passes and, because a bounded pump is an
--- explicit "run N frames" rather than "run to completion", leaves anything
--- still queued in place instead of raising. That is how a spec observes the
--- retry contract: pump one frame with the stash offline, assert nothing moved
--- and the event is still pending, bring the stash online, pump again.
function M.pump(opts)
    opts = opts or {}
    local limit = opts.passes or M.max_passes
    local invoked = 0

    for _ = 1, limit do
        if #queue == 0 then return invoked end

        local batch = queue
        queue = {}

        for _, ev in ipairs(batch) do
            invoked = invoked + 1
            local done = ev.fn(unpack(ev.args, 1, ev.n))
            if done ~= true then
                queue[#queue + 1] = ev      -- still waiting; retry next pass
            end
        end

    end

    if opts.passes then return invoked end

    -- A retrying event is legitimate -- wait_for_stash_creation returns false
    -- until the stash exists. There is no way to tell "will succeed later" from
    -- "never will" without running it, so max_passes is the only honest bound.
    local keys = {}
    for i, ev in ipairs(queue) do keys[i] = ev.key end
    error("timeevents: " .. #queue .. " event(s) still queued after " ..
          M.max_passes .. " passes (" .. table.concat(keys, ", ") ..
          ") -- they never returned true, so the condition they wait on is " ..
          "never met. If the wait is legitimate, raise timeevents.max_passes.", 2)
end

--- One frame of ProcessEventQueue (_g.script:364-388). Runs every event whose
--- due time has passed, drops the ones that return true, and keeps the rest.
--- Does nothing while the "sleep_active" info portion is set (:365-367).
--- Returns the number of callbacks invoked.
function M.run_due()
    if _G.has_alife_info and _G.has_alife_info("sleep_active") then
        return 0
    end

    -- Walk a snapshot but leave the queue in place: in the real queue an event
    -- stays queued until it returns true, so a callback that creates its own
    -- ids again is ignored (:345). Events created this frame wait for the next.
    local now = now_ms()
    local snapshot = {}
    for i, ev in ipairs(queue) do snapshot[i] = ev end
    local invoked = 0

    for _, ev in ipairs(snapshot) do
        if now >= ev.due then
            invoked = invoked + 1
            if ev.fn(unpack(ev.args, 1, ev.n)) == true then
                for i = #queue, 1, -1 do
                    if queue[i] == ev then table.remove(queue, i) break end
                end
            end
        end
    end

    return invoked
end

function M.pending() return #queue end

function M.peek()
    local out = {}
    for i, ev in ipairs(queue) do out[i] = ev.key end
    return out
end

function M.reset()
    queue = {}
    seq = 0
    M.max_passes = 32
end

return M

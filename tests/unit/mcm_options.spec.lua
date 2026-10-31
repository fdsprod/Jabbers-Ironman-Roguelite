-- Structural walk of on_mcm_load's option tree (roguelite_manager_mcm.script), with
-- every module's append_mcm_options applied.
--
-- The tree is a 930-line nested literal that MCM reads at runtime. A malformed
-- node -- a track with no `def`, a group missing `gr`, a typo'd id -- breaks
-- the settings page in-game with no compile-time signal at all, and the getters
-- silently fall back to their defaults so the mod keeps "working" while nothing
-- the player configures takes effect.
--
-- The highest-value check here is the last one: every option's "<group>/<id>"
-- path is cross-referenced against the paths the getters actually read. That
-- catches an orphaned option or a mistyped path, which is the failure mode a
-- literal this size grows over time.

local H = require("harness.init")

-- Nodes that render something rather than storing a value. They take no `val`
-- and never appear in a storage path.
local PRESENTATION = {
    slide = true, desc = true, line = true, image = true, title = true,
}

-- MCM's `val` is a REQUIRED type code for the stored value, not a display
-- hint: 0 = string, 1 = boolean, 2 = float. A mismatch does not fail loudly --
-- the option reads and writes through the wrong type, so a track declared
-- val = 1 silently stores a boolean and the slider never persists.
local VAL_STRING, VAL_BOOL, VAL_FLOAT = 0, 1, 2

local REQUIRED_VAL = {
    check    = VAL_BOOL,
    track    = VAL_FLOAT,
    key_bind = VAL_FLOAT,
}

local tree

local function boot()
    H.boot_game{ modules = H.ALL_MODULES }
    tree = roguelite_manager_mcm.on_mcm_load()
end

--- Every group directly under the root.
local function groups()
    return tree.gr or {}
end

--- A node is a group if it carries its own `gr` list.
local function is_group(node)
    return type(node.gr) == "table"
end

--- Walk the whole tree, yielding { path, node, group } for every leaf option.
--- Recursive because MCM allows groups to nest arbitrarily deep and the storage
--- path traces every ancestor id -- a flat walk would mis-key anything nested.
local function options()
    local out = {}

    local function walk(node, prefix, group)
        for _, child in ipairs(node.gr or {}) do
            if is_group(child) then
                walk(child, prefix .. "/" .. tostring(child.id), child)
            else
                out[#out + 1] = {
                    node = child,
                    group = group,
                    path = prefix .. "/" .. tostring(child.id),
                }
            end
        end
    end

    -- This tree keeps its options directly under the root, and get_config prefixes
    -- "roguelite/" (roguelite_manager_mcm.script:56), so paths start there.
    walk(tree, tostring(tree.id), tree)

    return out
end

--- "<group>/<id>" for every value-carrying option in the tree.
local function option_paths()
    local out = {}
    for _, entry in ipairs(options()) do
        if not PRESENTATION[entry.node.type] then
            out[entry.path] = entry.node.type
        end
    end
    return out
end

--- The keys the mod actually reads. This mod has no getter module: every read is a
--- get_config("key", default) literal at the call site, so they are collected from
--- the scripts rather than restated here.
local function read_keys()
    local seen = {}
    local files = { "roguelite_manager" }
    for _, name in ipairs(H.ALL_MODULES) do files[#files + 1] = name end
    for _, name in ipairs(files) do
        local f = assert(io.open(H.loader.script_path(name), "rb"))
        local src = f:read("*all")
        f:close()
        for key in src:gmatch('get_config%("([%w_]+)"') do seen[key] = true end
    end
    return seen
end

describe("roguelite_manager_mcm.on_mcm_load()", function()

    beforeEach(boot)

    describe("the root", function()
        it("is identified as roguelite", function()
            expect(tree.id).toBe("roguelite")
        end)

    end)


    describe("every option", function()
        it("has an id", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                if type(entry.node.id) ~= "string" or entry.node.id == "" then
                    bad[#bad + 1] = entry.group.id
                end
            end
            expect(bad).toEqual({})
        end)

        it("has a type", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                if type(entry.node.type) ~= "string" then
                    bad[#bad + 1] = entry.path
                end
            end
            expect(bad).toEqual({})
        end)

        -- `val` is the stored-value type code and it is required on every
        -- interactive option. Without it the read/write path has no type to
        -- work through and the setting does not persist.
        it("declares a val type code", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                if not PRESENTATION[entry.node.type]
                   and type(entry.node.val) ~= "number" then
                    bad[#bad + 1] = entry.path
                end
            end
            expect(bad).toEqual({})
        end)

        -- FIXES: D13. The free-text ignore list declared val = '' -- reading
        -- `val` as an initial value rather than a type code. Not a recognised
        -- code, so the box could not round-trip through axr_options.ltx and
        -- get_ignored_other() always saw its '' default: whatever the player
        -- typed there protected nothing.
        it("declares a val the framework recognises", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                local val = entry.node.val
                if not PRESENTATION[entry.node.type]
                   and val ~= VAL_STRING and val ~= VAL_BOOL and val ~= VAL_FLOAT then
                    bad[#bad + 1] = entry.path .. " (val " .. tostring(val) .. ")"
                end
            end
            expect(bad).toEqual({})
        end)

        -- The high-value one. A mismatch is silent: a track with val = 1
        -- stores a boolean, so the slider reads back as true/false and the
        -- configured number never reaches the getter.
        it("declares a val matching its type", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                local want = REQUIRED_VAL[entry.node.type]
                if want and entry.node.val ~= want then
                    bad[#bad + 1] = string.format("%s (%s wants val %d, got %s)",
                        entry.path, entry.node.type, want, tostring(entry.node.val))
                end
            end
            expect(bad).toEqual({})
        end)

        it("declares a default, since none of them use cmd", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                if not PRESENTATION[entry.node.type]
                   and entry.node.def == nil and entry.node.cmd == nil then
                    bad[#bad + 1] = entry.path
                end
            end
            expect(bad).toEqual({})
        end)

        it("uses only types this tree is built from", function()
            local KNOWN = {
                check = true, track = true, input = true,
                slide = true, desc = true, line = true,
            }
            local unexpected = {}
            for _, entry in ipairs(options()) do
                if not KNOWN[entry.node.type] then
                    unexpected[#unexpected + 1] = entry.path ..
                        " (" .. tostring(entry.node.type) .. ")"
                end
            end
            -- Not a prohibition on new types -- a new one just needs its own
            -- required-field assertions adding below before it lands.
            expect(unexpected).toEqual({})
        end)

        -- Paths are the storage keys, so a collision means two controls writing
        -- over each other in axr_options.ltx.
        it("has a unique storage path", function()
            local seen, dupes = {}, {}
            -- Every module's section repeats the id `desc_mcm`, and `line`. Those render
            -- and store nothing, so only value-carrying nodes can collide.
            for _, entry in ipairs(options()) do
                if not PRESENTATION[entry.node.type] then
                    if seen[entry.path] then dupes[#dupes + 1] = entry.path end
                    seen[entry.path] = true
                end
            end
            expect(dupes).toEqual({})
        end)
    end)

    describe("every slide and image option", function()
        it("declares the texture to link", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                local t = entry.node.type
                if (t == "slide" or t == "image") and type(entry.node.link) ~= "string" then
                    bad[#bad + 1] = entry.path
                end
            end
            expect(bad).toEqual({})
        end)
    end)

    describe("every desc and title option", function()
        it("declares the string id to display", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                local t = entry.node.type
                if (t == "desc" or t == "title") and type(entry.node.text) ~= "string" then
                    bad[#bad + 1] = entry.path
                end
            end
            expect(bad).toEqual({})
        end)
    end)

    describe("every track option", function()
        local function tracks()
            local out = {}
            for _, entry in ipairs(options()) do
                if entry.node.type == "track" then
                    out[#out + 1] = { path = entry.path, node = entry.node }
                end
            end
            return out
        end

        it("declares min, max, step and def", function()
            local bad = {}
            for _, t in ipairs(tracks()) do
                for _, key in ipairs{ "min", "max", "step", "def" } do
                    if type(t.node[key]) ~= "number" then
                        bad[#bad + 1] = t.path .. "." .. key
                    end
                end
            end
            expect(bad).toEqual({})
        end)

        -- A default outside its own slider cannot be restored by "reset to
        -- default", and the slider snaps somewhere else the moment it is moved.
        it("keeps its default inside its range", function()
            local bad = {}
            for _, t in ipairs(tracks()) do
                local n = t.node
                if n.def < n.min or n.def > n.max then
                    bad[#bad + 1] = string.format("%s (def %s not in [%s, %s])",
                        t.path, tostring(n.def), tostring(n.min), tostring(n.max))
                end
            end
            expect(bad).toEqual({})
        end)

        it("declares a range with room in it", function()
            local bad = {}
            for _, t in ipairs(tracks()) do
                if t.node.min >= t.node.max then bad[#bad + 1] = t.path end
            end
            expect(bad).toEqual({})
        end)

        it("declares a positive step", function()
            local bad = {}
            for _, t in ipairs(tracks()) do
                if t.node.step <= 0 then bad[#bad + 1] = t.path end
            end
            expect(bad).toEqual({})
        end)
    end)

    describe("every check option", function()
        it("declares a boolean default", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                if entry.node.type == "check" and type(entry.node.def) ~= "boolean" then
                    bad[#bad + 1] = entry.path
                end
            end
            expect(bad).toEqual({})
        end)
    end)

    describe("every list and radio option", function()
        -- radio_h and radio_v are the framework's names; a bare "radio" would
        -- never render.
        it("declares its content", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                local t = entry.node.type
                if (t == "list" or t == "radio_h" or t == "radio_v")
                   and type(entry.node.content) ~= "table" then
                    bad[#bad + 1] = entry.path
                end
            end
            expect(bad).toEqual({})
        end)

        it("does not use the non-existent bare 'radio' type", function()
            local bad = {}
            for _, entry in ipairs(options()) do
                if entry.node.type == "radio" then bad[#bad + 1] = entry.path end
            end
            expect(bad).toEqual({})
        end)
    end)

    describe("the tree against the keys the mod reads", function()
        it("declares an option for every key the mod reads", function()
            local declared, missing = option_paths(), {}
            for key in pairs(read_keys()) do
                if not declared["roguelite/" .. key] then missing[#missing + 1] = key end
            end
            table.sort(missing)
            expect(missing).toEqual({})
        end)

        it("reads every option it declares", function()
            local keys, unread = read_keys(), {}
            for path in pairs(option_paths()) do
                local key = path:gsub("^roguelite/", "")
                if not keys[key] then unread[#unread + 1] = key end
            end
            table.sort(unread)
            expect(unread).toEqual({})
        end)
    end)

    describe("re-entrancy", function()
        -- MCM calls this again whenever the settings page is reopened.
        it("returns an equivalent tree on a second call", function()
            local first = roguelite_manager_mcm.on_mcm_load()
            local second = roguelite_manager_mcm.on_mcm_load()
            expect(#second.gr).toBe(#first.gr)
        end)

        it("does not accumulate groups", function()
            local before = #tree.gr
            roguelite_manager_mcm.on_mcm_load()
            expect(#roguelite_manager_mcm.on_mcm_load().gr).toBe(before)
        end)
    end)
end)

return true

-- Shim for luabind's `class` global.
--
-- `class` is NOT part of Lua. The engine installs it from C++ in luabind::open()
-- (xray-monolith/src/3rd party/luabind/src/open.cpp:64, implemented in
-- create_class.cpp). The mod uses both forms:
--
--     class "SoulslikeScenarioLogic"                                  -- base
--     class "DefaultSoulslikeScenarioLogic" (SoulslikeScenarioLogic)  -- derived
--     function DefaultSoulslikeScenarioLogic:__init(state) super (state) end
--
-- Fidelity notes vs. luabind:
--   * `__init` and `__finalize` are NOT inherited. create_class.cpp:36-62
--     explicitly skips both when copying the base member table down. We match
--     that: a derived class with no own __init runs no constructor at all.
--   * Other members ARE reachable from the derived class. luabind copies them
--     eagerly at derivation time; we resolve them lazily through __index. The
--     observable difference only shows up if a base method is replaced *after*
--     the derived class is declared -- luabind would keep the old one, we pick
--     up the new one. The mod never does this.

local M = {}

-- Stack of {obj=, cls=} frames, one per __init currently executing. `super`
-- reads the top frame, so in an A <- B <- C chain each super() call resolves
-- against the class whose __init is running, not against the instance's class.
local init_stack = {}

-- Every class name registered since the last install(). `class "X"` writes a
-- true global, and nothing in Lua removes it, so without tracking them a spec
-- that never loaded soulslike_scenarios would still find the class a PREVIOUS
-- spec left on _G -- and pass for the wrong reason. A fresh game has no classes
-- until the scripts declaring them run, so install() clears them.
local registered = {}

local function construct(cls, ...)
    local obj = setmetatable({}, { __index = cls, __class = cls })
    M.call_init(cls, obj, ...)
    return obj
end

function M.call_init(cls, obj, ...)
    -- rawget, not cls.__init: __init must not be inherited (see header note).
    local init = rawget(cls, "__init")

    init_stack[#init_stack + 1] = { obj = obj, cls = cls }
    local saved_super = rawget(_G, "super")

    _G.super = function(...)
        local frame = init_stack[#init_stack]
        local base = frame and rawget(frame.cls, "__base")
        if base then
            M.call_init(base, frame.obj, ...)
        end
    end

    local ok, err
    if init then
        ok, err = pcall(init, obj, ...)
    else
        ok = true
    end

    init_stack[#init_stack] = nil
    _G.super = saved_super

    if not ok then error(err, 0) end
    return obj
end

-- The `class` global itself.
local function class(name)
    if type(name) ~= "string" then
        error("invalid construct, expected class name", 2)
    end

    local cls = {}
    cls.__name = name
    cls.__index = cls   -- instances resolve members here

    -- No base yet. __index on the *class* metatable is what makes inherited
    -- members reachable; it gets filled in by the returned deriver.
    setmetatable(cls, { __call = construct })

    _G[name] = cls
    registered[name] = true

    -- Enables the `class "X" (Base)` second call. Returning the class itself
    -- would break that, so return a deriver closure.
    return function(base)
        if base ~= nil then
            if type(base) ~= "table" then
                error("expected class to derive from or a newline", 2)
            end
            rawset(cls, "__base", base)
            setmetatable(cls, { __call = construct, __index = base })
        end
        return cls
    end
end

-- ------------------------------------------------------------------ test aid

function M.class_of(obj)
    local mt = getmetatable(obj)
    return mt and mt.__class or nil
end

function M.is_instance(obj, cls)
    local c = M.class_of(obj)
    while c do
        if c == cls then return true end
        c = rawget(c, "__base")
    end
    return false
end

--- Names registered by `class` since the last install(). Test aid.
function M.registered_names()
    local out = {}
    for name in pairs(registered) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function M.install(env)
    env = env or _G
    -- Drop classes declared during a previous boot before re-arming, so each
    -- spec starts from a world where no script has run yet.
    for name in pairs(registered) do
        if rawget(env, name) ~= nil then env[name] = nil end
    end
    registered = {}

    env.class = class
    return env
end

M.class = class

return M

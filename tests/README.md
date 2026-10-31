# Soulslike test harness

> Copied from the Soulslike mod. The matcher and runner reference applies here. For
> what differs in this repo, see "This repo" at the top of `CLAUDE.md`.

Runs the mod's Lua **unmodified**, outside the game engine, so scenario logic can
be exercised without launching Anomaly and dying repeatedly.

Specs are BDD — nested `describe` / `it` with a Jest-style `expect`, the same
shape as a TS suite.

```
run.bat                  all specs (self-tests gate unit and e2e)
run.bat self             harness self-tests only
run.bat unit             unit specs only
run.bat e2e              end-to-end journeys only

run.bat --file ambush    only spec files whose path contains "ambush"
run.bat -t "keep roll"   only tests whose full name contains "keep roll"

tools\luajit.exe probe.lua    reachability check -- see "Reachability probe"
```

Exit code is 0 on success, 1 on failure, 2 if no Lua runtime was found or no
spec file matched.

Both filters take a plain substring, not a pattern, and both **skip the
self-test gate** — they are the "run just this one thing" switches, so dragging
the whole self-suite along would defeat the point. A filter matching nothing
reports `EMPTY` and exits non-zero rather than reading as a green run of zero
tests.

Nothing here ships to players: `deploy.bat` packages only `gamedata/`.

## Output

Results print as a tree, green `✓` for a pass, red `✗` for a failure, yellow `○`
for a pending `xit`:

```
compute_fatal_hit_info()
  power weighting
    given hits spread over time
      ✓ weights later hits more heavily
      ✗ gives the earliest hit zero weight
        expected 1000 to be 2
```

| Flag / variable | Effect |
|---|---|
| `--no-color` | plain output, no ANSI |
| `NO_COLOR` / `SPEC_NO_COLOR` | same, via the environment ([no-color.org](https://no-color.org)) |
| `FORCE_COLOR` | colour on even when `NO_COLOR` is set |
| `--ascii` or `SPEC_ASCII` | `ok` / `XX` / `--` instead of the symbols |

`run.bat` switches the console to code page 65001 for the duration of the run
and restores the previous one on exit, since the symbols are UTF-8. If you
invoke `luajit run.lua` directly from a legacy code page, pass `--ascii`.

## Runtime

Requires **LuaJIT 2.x or Lua 5.1**. Not 5.2+ — the module loader uses `setfenv`,
which was removed in 5.2.

`run.bat` looks for `luajit.exe` on PATH, then falls back to `tools\luajit.exe`.
`tools/` is gitignored; build it from the engine repo's vendored source:

```
copy  xray-monolith\src\3rd party\luajit-2  somewhere\
call  "…\VC\Auxiliary\Build\vcvars64.bat"
cd    somewhere\src
set   PATH=%CD%;%PATH%          REM msvcbuild invokes the minilua it just built
call  msvcbuild.bat static
copy  luajit.exe  <mod>\tests\tools\
```

## Layout

| Path | What |
|---|---|
| `harness/spec.lua` | BDD runner: `describe`/`it`/`beforeEach` + `expect` |
| `harness/loader.lua` | Reproduces the engine's script-module namespacing |
| `harness/class.lua` | Shim for luabind's `class` / `super` |
| `harness/dispatch.lua` | `RegisterScriptCallback` / `SendScriptCallback` registry |
| `harness/fakes.lua` | Fake engine globals (`level`, `db`, `ui_mcm`, …) |
| `harness/builders.lua` | Fixture builders (`make_actor`, `make_hit`, …) |
| `harness/world.lua` | Item/container model + the alife simulator |
| `harness/timeevents.lua` | `CreateTimeEvent` queue and pump |
| `harness/mods.lua` | Base-Anomaly and third-party script registry |
| `harness/mcm_labels.lua` | MCM label derivation and analysis |
| `harness/encoding.lua` | Byte-level inspection of the localisation XML |
| `self/*.spec.lua` | Harness self-tests — these gate everything else |
| `unit/*.spec.lua` | Unit specs against the real mod scripts |
| `e2e/*.spec.lua` | End-to-end journeys through the callback chain |
| `probe.lua` | Reachability check, not a test suite |

## Writing a spec

`describe` / `it` / `beforeEach` / `afterEach` / `expect` are ambient globals,
installed by `harness.init`.

```lua
local H = require("harness.init")

describe("soulslike.get_soulslike_state()", function()

  beforeEach(function()
    H.boot{ load = { "soulslike_classes", "soulslike" } }
  end)

  describe("given a save with no soulslike data at all", function()
    it("creates every top-level collection", function()
      expect(soulslike.get_soulslike_state().created_stashes).toBeDefined()
    end)
  end)
end)

return true
```

Drop the file in `self/`, `unit/` or `e2e/` and it is picked up automatically —
spec files are discovered from those directories, so `run.lua` needs no edit.

The `MANIFEST` table in `run.lua` is only a fallback for hosts where the
directory listing is unavailable (`io.popen` disabled, or a shell that is not
`cmd`). Discovery sorts alphabetically, so specs must not depend on load order.

### Naming

Follow the nesting the existing specs use:

```
describe("<unit under test>")
  describe("<method()>")
    describe("given <context>")
      it("<observable behavior>")
```

`it` names complete the sentence "it …" — `returns nil`, `does not raise`,
`falls back to Other`. Not `test nil return`.

### Matchers

`expect(x)` uses TS call syntax (a dot, not a colon). Prefix any matcher with
`.never` to negate it.

| | |
|---|---|
| `.toBe(v)` | identity / `==` |
| `.toEqual(v)` | deep structural equality |
| `.toBeNil()` / `.toBeDefined()` | nil checks |
| `.toBeTruthy()` / `.toBeFalsy()` | truthiness |
| `.toBeType("function")` | `type()` check |
| `.toContain(v)` | substring, or table membership |
| `.toHaveLength(n)` | `#` of a string or table |
| `.toBeCloseTo(n, tol)` | float compare, default tol `1e-9` |
| `.toBeGreaterThan(n)` / `.toBeLessThan(n)` | ordering |
| `.toThrow()` / `.toThrow("substr")` | wrap the call: `expect(function() … end).toThrow()` |

`xit("...")` marks a spec pending — reported with `○`, never run.

One gotcha: `expect()`'s argument is evaluated **before** the matcher call, so
build state first rather than inlining the call that creates it.

```lua
local s = state()                       -- do this
expect(fakes.game_state.soulslike).toBe(s)

expect(fakes.game_state.soulslike).toBe(state())   -- not this: captures nil
```

### The world model, and why you must tick

Items live in named containers. Assert final placement, not call sequences:

```lua
local ak = H.world.give("actor", "wpn_ak74", { kind = "weapon", condition = 0.8 })
local stash = H.world.container("stash")
H.world.spawn_npc("looter", { kind = "stalker", community = "bandit" })

scenario:TransferItems(stash:id())
H.tick()                                   -- REQUIRED before asserting

expect(H.world.where(ak)).toBe("stash")
expect(H.world.contents("looter")).toEqual({ "medkit" })
expect(H.world.destroyed()).toEqual({})
```

**Inventory mutations are deferred, and that is deliberate.** The engine walks
the live `m_all` container with raw iterators (`IterateInventory`,
`script_game_object_inventory_owner.cpp:266`) while the mod calls
`alife_release` and `transfer_item` from inside that loop. That is only safe
because `transfer_item` sends `GE_TRADE_SELL`/`GE_TRADE_BUY` network events
processed on a later frame. So the model queues too. Two rules follow:

- Inside `iterate_inventory`, an item you just released is **still present**.
- `TransferItems` returning does **not** mean anything moved. Tick first.

`H.tick()` drains time events and then applies the world mutations they caused.

Server and client objects are distinct, as in the engine: `alife_create` /
`alife_object` return a **server** object where `.id` is a *field*;
`level.object_by_id` returns a **client** object where `:id()` is a *method*.
`H.world.hide(id)` makes an object invisible to `level.object_by_id`, which is
how you exercise the "stash is not online yet" retry.

### Optional and base scripts

```lua
H.boot{ mods    = { "magazine_binder" } }   -- add a third-party integration
H.boot{ without = { "item_parts" } }        -- test an absent-dependency guard
```

`H.mods.BASE` (`actor_status_thirst`, `arszi_psy`, `item_parts`, `item_radio`,
`treasure_manager`) ship with Anomaly and are installed by default — two are
called unguarded, so "absent" is not a state the mod survives.
`H.mods.OPTIONAL` (`magazine_binder`, `grok_actor_damage_balancer`,
`demonized_time_events`) are third-party and absent by default.

`H.mods.patched(name)` lists fields replaced since `enable()` — use it to catch
an unrestored monkey-patch, e.g. `treasure_manager.box_in_same_map`
(soulslike_scenarios.script:1335).

### Strict globals

```lua
H.boot{ strict = true }
```

Raises on a global that resolved to nil instead of silently returning nil, so a
missing fake fails where it happens. Off by default, because nil-tolerance is
the engine's real behavior and the mod relies on it. Registered optional mods
are always exempt.

### Faking config

Every one of `soulslike_mcm`'s 60+ getters funnels through one accessor
(`soulslike_mcm.script:939`), so the **real** MCM module runs against a single
fake. Unset keys exercise each getter's declared default.

```lua
H.fakes.set_mcm("hardcore/is_enabled", true)   -- key omits the "soulslike/" prefix
```

### Determinism

`math.random` raises unless a spec pins it first — an unseeded roll is a bug,
not a default.

```lua
H.fakes.set_random_const(1)          -- always 1
H.fakes.set_random_sequence{1, 5, 3} -- in order; errors past the end
H.fakes.set_time(5000)               -- backs time_global()
H.fakes.random_count()               -- rolls spent, for exact-budget asserts
```

Budgets are worth asserting. `IsItemLossAllowed` spends 0 or 1 roll depending on
the item category, and a stray roll desynchronises every later one in a death.

Some functions spend rolls of **different call forms** that want opposite
values — `TransferItem` wants a high `math.random()` (fail the keep roll) and a
low `math.random(0, 100)` (pass the loss roll). A constant cannot express that;
use a predicate on the call form:

```lua
H.fakes.set_random(function(a, b)
  if a == nil then return 0.999 end   -- 0-arg: fail every keep roll
  return a                            -- ranged: pass every loss roll
end)
```

### Scenario fixtures

```lua
H.set_spawn{ level = "zaton" }              -- required before create_new/RespawnActor
B.stub_finders{ friendly_stalker = npc }    -- the four find_closest_* helpers
B.make_scenario{ class = "NoLossSoulslikeScenarioLogic", state = {...} }
B.make_logic_state{ allow_weapon_loss = false }
B.finder_count("enemy_mutant")              -- which finder an arm consulted
```

`finder_count` is load-bearing, not a convenience: several selection arms differ
only by *which* finder supplies the looter, so asserting the returned object
cannot tell them apart.

`make_logic_state` is a hand-written literal mirroring the mod's `__init`. A
drift guard in `self/builders.spec.lua` asserts its key set still matches a
freshly constructed scenario, so a field added to the mod fails there rather
than silently rotting every fixture.

### Crossing a level change

```lua
H.reboot{ load = MOD_SCRIPTS, soulslike_mode = true }
```

Re-executes every script and discards every module table while preserving the
save. That is exactly what `ChangeLevel` does, and it is the only way to test
the save/load round trip — a plain `H.boot` wipes the save, so the "reload"
would have nothing to restore from.

### Observing a retrying time event

`H.tick()` runs to completion and raises if anything is still waiting. To watch
an event mid-wait, bound it:

```lua
H.world.hide(stash_id)
H.tick{ passes = 1 }                        -- one frame; leaves the retry queued
expect(H.timeevents.pending()).toBeGreaterThan(0)
H.world.reveal(stash_id)
H.tick()                                    -- now it completes
```

### Save files

The hardcore save-pruning walk reads each sibling save with a real `io.open`
before decoding it, so it needs a shim:

```lua
H.fakes.install_save_fs()
H.fakes.set_save("older", { soulslike = { uuid = "run-1" } })
H.fakes.set_save("corrupt", nil)            -- models an unreadable file
```

Non-save paths fall through to the real `io.open`, which the module loader still
needs. Uninstalled automatically on the next `H.boot`.

### Testing a file-local function

`local function` at file scope is not exported, but it becomes an *upvalue* of
any exported function that references it — so it is reachable without editing
the mod:

```lua
local compute = H.loader.upvalue(
  soulslike_scenario_logic_factory.create_new, "compute_fatal_hit_info")
```

Call this from the spec, never from inside a module's environment
(`soulslike.script` shadows `debug`).

## Why self-tests gate unit specs

The harness re-implements three pieces of engine behavior. If any drifts, unit
specs keep passing while testing something the game would never execute. So a
self-test failure aborts the run before `unit/`.

The one that matters most is the module loader. The engine textually wraps every
`.script` file (`script_storage.cpp:608`), producing semantics plain `require`
does not:

| In a module | Lands as |
|---|---|
| `RELATIONS = {...}` | `soulslike.RELATIONS` (module-local) |
| `function debug(o)` | `soulslike.debug` — shadows the stdlib `debug` table |
| `function math.clamp(…)` | mutates the **shared** global `math` table |
| `function _G.IsSoulslikeMode()` | a true global |
| reading an undefined global | `nil`, **not** an error |

To confirm the harness is still load-bearing, break one semantic and check that
the run fails loudly rather than passing quietly. Removing the
`setmetatable(this, {__index = _G})` line from `loader.build_prologue` should
produce 9 self-test failures and skip `unit/` entirely.

The same applies to the world model. This must hold, and would not if the model
ever started snapshotting or applying immediately:

```lua
world.give("actor", "a"); world.give("actor", "b")
db.actor:iterate_inventory(function(_, item) alife_release(item) end)
expect(world.contents("actor")).toHaveLength(2)   -- still there
H.tick()
expect(world.contents("actor")).toHaveLength(0)   -- now gone
```

## Reachability probe

```
tools\luajit.exe probe.lua
```

Calls every non-UI mod function once and reports reachable / unreachable. It
asserts nothing about correctness — it answers "can the harness get here at
all". Currently **72 reachable, 0 unreachable**. Run it after touching the
fakes; a new FAIL means a fake regressed or the mod grew a dependency.

## Standing caveat

These specs validate mod logic against **our assumptions about the engine**. A
wrong constant in `fakes.lua` becomes a permanently green spec. Values taken
from engine source are cited in comments; anything else should be pinned against
a real game before it is trusted.

Engine behaviour cited here was read from `xray-monolith`. The load-bearing
facts, and where they bite:

| Fact | Citation |
|---|---|
| Inventory slots run **1..18** — `LAST_SLOT = CUSTOM_SLOT_5`, since `MORE_INVENTORY_SLOTS` is defined. Slot 0 is `NO_ACTIVE_SLOT` and is rejected | `inventory_space.h:6-45`, `build_config_defines.h:15` |
| `iterate_inventory` is a live walk and stops on **any truthy** return, not just `true` | `script_game_object_inventory_owner.cpp:256-271` |
| `CreateTimeEvent` re-queues on anything **not literally `true`** — the opposite convention | `_g.script:366-390` |
| `transfer_item` is **deferred** through `GE_TRADE_SELL` / `GE_TRADE_BUY` | `script_game_object_inventory_owner.cpp:584-610` |
| Server objects expose `id`/`position` as **fields**; client objects use methods | `xrServer_Objects_script.cpp:110-124` |
| `alife():register` **frees its argument** and returns a new pointer | `alife_simulator_script.cpp:396-413` |
| `set_character_rank`/`_reputation` are int, **unclamped**, and truncate **toward zero** | `character_info_defs.h:8-24`, `policy.hpp:377` |
| `give_money(-N)` does **not** clamp — it underflows u32 | `InventoryOwner.cpp:630-645` |
| Grenades are **not** weapons at either layer, so `IsWeapon(x) and not is_grenade` is redundant | `Grenade.h:6`, `_g.script:3081-3149` |
| `clsid()` values are **runtime ordinals** — never hardcode one | `object_factory_script.cpp:85-97` |
| `vector():set(nil,…)` is **UB in a release build**, not a catchable error: `NDEBUG` compiles out luabind's no-overload guard | `class_rep.cpp:605-688`, `config.hpp:81-91` |

That last one is why `H.builders.strict_vectors` raises rather than coercing nil
to 0. Both call sites that could reach it are now guarded
(`soulslike_scenario_logic_factory.script:164`,
`soulslike_scenarios.script:902`), and specs assert they no longer raise. Set
`strict_vectors = false` only in a spec that deliberately needs to step past it.

## Pinned behaviour

Specs assert **correct** behaviour, so the suite runs green; a defect found
along the way was fixed rather than pinned. Three markers flag the exceptions:

| Marker | Meaning |
|---|---|
| `FIXES: Dn` | The spec exists because it caught a defect. It failed first, then the fix landed. |
| `CHARACTERIZATION:` | Behaviour deliberately left alone, pinned so a change is deliberate rather than accidental. |
| `DEAD CODE:` | An unreachable branch, with the gate that disables it cited. |

Currently pinned as characterization: `save_state`/`load_state` shadow their
`data` parameter, so the dispatched payload is ignored · `logic_state` is stored
by reference with no serialization step · weapon condition loss never destroys
the weapon or sets `items_were_lost`, because parts clamp at 1 · toolkits have
an allow flag but no keep roll, unlike the other four categories · squad
ambushers are tracked without vertex ids · the indoor selection arm leaves the
loot scalar at 1.0 where every other no-loss arm sets 0 · the ignore list
matches bare `medkit`/`bandage` while Anomaly ships variants (a balance
decision, not a code bug).

Currently marked dead: `scenarios/nearby_dead_stalker_scenario_weight`, a
getter nothing calls. The RF-detector and hidden-stash scenarios are gated by
real `enable_rf_detector_scenario`/`enable_hidden_stash_scenario` checkboxes
and weight sliders in `soulslike_scenario_logic_factory.create_new`,
restricted to deaths where the player has no backpack equipped.

## Localisation

```
locals.bat              the spec that asserts it, then the report
locals.bat --report     report only, skip the spec
locals.bat --lax        do not fail on untranslated strings
```

The report runs **last**. It is the part you came here to read, and when it ran
first its summary scrolled off behind the spec output — the closing line said
`PASS` while 20 strings were untranslated.

A node with no `text` derives its label as `"ui_mcm_" .. <path with "/" → "_">`,
so `allow_weapon_loss` in group `items` under root `soulslike` needs
`ui_mcm_soulslike_items_allow_weapon_loss`. A miss renders the raw string id on
screen and nothing else reports it.

Checked **in both directions**, which is what makes a rename obvious: the new
id has no translation *and* the old translation is orphaned, so one mistake
fails two assertions pointing at each other.

Parity is compared **whole-table**, not just across MCM labels: the label scan
only sees the 112 ids the option tree asks for, so a gap in
`soulslike_messages.xml` was outside its reach entirely.

Outcomes, deliberately not treated alike:

| | Fails? | Why |
|---|---|---|
| **Missing** — node with no English string | **yes, always** | The player sees the raw string id in the menu. Add four lines to `configs/text/eng`. |
| **Hardcoded** — node carries an English sentence, not a string id | **yes, always** | Renders, because `translate_string` passes unknown input through, but can never be translated. Delete the literal and let the node derive its key. |
| **Orphan** — string with no node | **yes, always** | Half a rename, or a string for an option that no longer exists. Delete it; git holds the text if the option returns. |
| **Duplicate** — one id declared twice | **yes, always** | The engine keeps one `<text>` and drops the rest. Every other check reads a *set*, where the repeat has collapsed and the id still resolves, so this is the only thing that can see it. |
| **Half a rename** — Russian string with no English one | **yes, always** | Not translation work: there is nothing left to translate. |
| **Debt** — English present, Russian absent | in `locals.bat`, not in `run.bat` | Work outstanding, not a defect. `run.bat` gates the build on what is *broken*; `locals.bat` is the translation tool and should not exit 0 while there is debt to look at. `--lax` opts out. |

There is no list of accepted breakages and nothing to add an id to. Every
assertion expects an empty list, so the only way to reach green is to fix the
localisation. Four "known broken" tables used to live in
`harness/mcm_labels.lua`; they let four visibly broken labels ship while
`run.bat` said PASS, and they are gone. Do not add them back.

> The Russian tables ship as **windows-1251**, not UTF-8. Everything here
> compares string *ids*, which are ASCII, so it never matters; anything that
> starts reading the `<text>` bodies has to decode first.

## Not covered

Out of scope by decision: the two UI modules (`soulslike_sleep_dialog`,
`souslike_gamemode_injector_mcm`). They monkey-patch Anomaly UI classes at file
scope and need those classes to exist before they will load; they are thin
decorators, so testing them mostly tests the stub.

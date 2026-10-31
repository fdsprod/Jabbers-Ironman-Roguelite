# tests/ — orientation for an agent

## This repo

The suite is copied from the Soulslike mod's `tests/`. Everything after this section
is its brief, unchanged. The rules apply here as written. Its `soulslike_*`
citations are examples of the conventions, not files in this repo.

**Copy from that repo before writing anything new.** Add new behaviour in new files
or small edits on top of the copy, so the two suites stay comparable.

What differs:

- `harness/alife.lua` and `self/alife.spec.lua` are new. `world.lua` models one object
  per item. `alife.lua` splits server and client objects, because item uses depend on
  the split. `H.boot_game` installs it over the copied fakes.
- `H.boot_game` loads the real stock `bind_item`, `alife_storage_manager` and
  `itms_manager` from `../_scripts`. `_scripts/` is gitignored, so these specs need a
  local copy and fail loudly without one.
- Engine citations are against xray-monolith commit `028ccf5`, checked out at
  `..\xray-monolith` next to this repo. Newer engines may differ.
- The state file and saves go through the virtual files in `alife.lua`. They survive
  `H.new_life` and `H.reload`, and `H.new_life` starts object ids somewhere else.
- `H.die`, `H.save`, `H.reload`, `H.new_life`, `H.open_stash` and `H.frames` are the
  journey verbs. See `e2e/stash_item_uses.spec.lua`.

- `harness/alife.lua` also holds the `death_manager` model: the real guard around a
  `keep_item` that releases what it is given. The real file needs most of the game loaded.
- `mcm_labels.lua`, `encoding.lua`, `locals.*`, `text_encoding.spec.lua`,
  `mcm_localization.spec.lua` and `mcm_options.spec.lua` are copied and pointed at this mod.
  Options sit directly under the root here, so the group specs are gone. There is no getter
  module, so `mcm_options` collects `get_config("key")` literals from the scripts.

Not copied, because it is built around Soulslike's scripts: `probe.lua`, and the rest of its
`unit/` and `e2e/` specs. Self-specs that needed Soulslike scripts were removed.
`builders.lua`, `world.lua` and `mods.lua` still hold helpers only those specs used.

GUESS in `alife.lua`: the frames between `alife():register` and the client object
existing. Binder updates run every frame here, not on the real scheduler.

---

Read this before touching anything under `tests/`. `README.md` next to it is the
human-facing reference (matchers, helper signatures, worked examples); this file
is the *why*, and the rules that are not obvious from the code.

---

## What this is

A BDD suite that runs the mod's Lua **unmodified**, outside the game. No
Anomaly install, no dying repeatedly to check a change. It works by
reimplementing the parts of the engine the mod actually touches, in pure Lua.

```
tests\run.bat                     all specs        (self gates unit + e2e)
tests\run.bat self|unit|e2e       one suite
tests\run.bat --file ambush       spec files matching a substring
tests\run.bat -t "keep roll"      tests matching a substring
tests\locals.bat                  localisation spec, then the report (strict)
tests\locals.bat --lax            same, without failing on untranslated strings
tests\tools\luajit.exe probe.lua  reachability check
```

Exit 0 pass, 1 fail, 2 no runtime / nothing matched.

Nothing here ships: `deploy.bat` packages `gamedata/` only.

### Runtime

**LuaJIT 2.x or Lua 5.1 — not 5.2+.** The module loader uses `setfenv`, removed
in 5.2. `run.bat` finds `luajit.exe` on PATH, else `tools\luajit.exe`.

`tools/` is gitignored: it is a build artifact, and the whole point is that it
comes from the same source tree as the game.

```
copy  xray-monolith\src\3rd party\luajit-2  somewhere\
call  "…\VC\Auxiliary\Build\vcvars64.bat"
cd    somewhere\src
set   PATH=%CD%;%PATH%          REM msvcbuild invokes the minilua it just built
call  msvcbuild.bat static
copy  luajit.exe  <mod>\tests\tools\
```

---

## The core bargain, and the standing risk

These specs validate **mod logic against our model of the engine**. When the
model is wrong, the spec is not merely useless — it is *permanently green*
while asserting something the game would never do. That is the single failure
mode to design against.

So the rule is: **anything the engine decides gets a citation, or it does not
go in.**

Two upstreams:

| What | Source |
|---|---|
| Engine behaviour — bindings, types, clamping, lifetimes | <https://github.com/themrdemonized/xray-monolith> |
| MCM option schema, storage paths, label derivation | <https://github.com/RAX-Anomaly/Anomaly-Mod-Configuration-Menu> |

Anomaly's own gamedata scripts (`_g.script`, `utils_item.script`, …) are a
third: several things that *look* like engine behaviour are Lua, and the
difference matters. `CreateTimeEvent` and `alife_create` are Lua; `iterate_inventory`
and `transfer_item` are C++.

### How to add a fake faithfully

1. Find the real thing. Grep the engine repo for the binding
   (`script_game_object_*.cpp`, `alife_simulator_script.cpp`,
   `xrServer_Objects_script.cpp`), or the MCM repo for UI contracts.
2. Copy the *semantics*, not a plausible guess — return type, whether it
   clamps, whether it is deferred, what it does on nil.
3. Cite `file.cpp:line` in a comment at the fake.
4. If you cannot verify it, mark it `GUESS` explicitly. `harness/fakes.lua`
   opens with this convention; keep it.

Facts already established this way are tabulated in `README.md` under
*Standing caveat*. Consult it before assuming — several are counter-intuitive:

- Inventory slots run **1..18**, not 1..12. Slot 0 is `NO_ACTIVE_SLOT`.
- `iterate_inventory` stops on **any truthy** return; `CreateTimeEvent`
  re-queues on anything **not literally `true`**. Opposite conventions, easy
  to conflate.
- Server objects expose `id`/`position` as **fields**; client objects as
  **methods**. Conflating them yields a table keyed by a function.
- `give_money(-N)` does **not** clamp — it underflows u32.
- `set_character_rank` truncates **toward zero**, not floor, and never clamps.
- Grenades are **not** weapons at either layer.
- `vector():set(nil,…)` is **UB in release** — `NDEBUG` compiles out luabind's
  no-overload guard. Not catchable. The harness raises so it stays visible;
  call sites are guarded instead.

---

## How the pieces fit

```
harness/spec.lua        describe / it / expect, the runner
harness/loader.lua      reproduces the engine's script-module namespacing
harness/class.lua       luabind class / super
harness/dispatch.lua    RegisterScriptCallback / SendScriptCallback
harness/fakes.lua       engine globals: level, db, ui_mcm, alife, …
harness/builders.lua    fixtures: actors, npcs, items, logic_state, scenarios
harness/world.lua       item/container model + the alife simulator
harness/timeevents.lua  CreateTimeEvent queue and pump
harness/mods.lua        base-Anomaly and third-party script registry
harness/mcm_labels.lua  MCM label derivation and analysis
harness/encoding.lua    byte-level inspection of the localisation XML
harness/init.lua        H.boot / H.tick / H.reboot — start here
```

### The loader is the load-bearing piece

The engine textually wraps every `.script` before compiling it
(`script_storage.cpp:608`). That produces semantics plain `require` does not,
and the mod depends on all of them:

| In a module | Lands as |
|---|---|
| `RELATIONS = {...}` | `soulslike.RELATIONS` — module-local, not global |
| `function debug(o)` | `soulslike.debug`, shadowing the stdlib `debug` table |
| `function math.clamp(…)` | mutates the **shared** `math` table |
| `function _G.IsSoulslikeMode()` | a true global |
| reading an undefined global | `nil`, **not** an error |

If this drifts, every unit spec keeps passing while testing something the game
would never run. That is why **self-tests gate unit and e2e**: a self failure
aborts before the rest.

To confirm the gate still bites, break one semantic — remove the
`setmetatable(this, {__index = _G})` line from `loader.build_prologue` — and
check the run fails loudly rather than passing quietly.

### Deferred mutation is deliberate

`iterate_inventory` walks the live container with raw iterators while the mod
calls `alife_release` and `transfer_item` from inside that loop. That is only
safe because `transfer_item` emits network events processed on a later frame.
So `world.lua` queues too:

- Inside `iterate_inventory`, an item you just released is **still present**.
- `TransferItems` returning does **not** mean anything moved.
- **`H.tick()` before asserting placement.** `H.tick{ passes = 1 }` runs one
  frame and leaves retries queued, which is how you observe a wait mid-flight.

Snapshotting instead would give the same loop coverage for the wrong reason.

---

## Rules for writing specs

**Assert correct behaviour.** The suite ends green. A defect found while
writing a spec gets *fixed*, with the spec failing first to prove it caught
something. Three markers flag exceptions:

| Marker | Meaning |
|---|---|
| `FIXES: Dn` | This spec caught a defect. It went red, then the fix landed. |
| `CHARACTERIZATION:` | Behaviour deliberately left alone, pinned so a change is deliberate. |
| `DEAD CODE:` | Unreachable branch, with the gate that disables it cited. |

**Never leave a spec red to represent a known bug.** A permanently failing
suite destroys the signal for every future change. Fix the defect in the same
change as the spec that caught it.

**Never write a data table that turns a failure into a pass.** This one was
learned the hard way here. `harness/mcm_labels.lua` used to carry four tables
of "known broken" string ids, and every localisation assertion filtered its
findings through them. Adding an id made the suite green. The tables needed
their own staleness guard, so the mechanism grew a mechanism. And the failure
it was built to prevent happened anyway: four MCM labels rendered as literal
`ui_mcm_soulslike_debug_debug_squad_spawns` in the shipped settings menu while
`run.bat` reported PASS, because they had been baselined.

All four tables are gone. Every localisation assertion now expects an empty
list, and the only way to reach green is to fix the localisation.

If some finding genuinely has to be tolerated, write the reason **in the spec,
in prose, next to the assertion that tolerates it** — so a reader meets the
exception and the reason for it at the same moment. Never move the exception
into data that silences findings from a distance.

**Separate defects from debt.** Untranslated strings are outstanding work, not
bugs. Conflating the two either blocks work on translation or hides real
breakage in a pile of it. So the two entry points answer different questions:
`run.bat` gates the build and **passes** with translation outstanding;
`locals.bat` is the translation tool and **fails** while any string is
untranslated (`--lax` opts out). Reporting alone proved too quiet — the count
sat mid-output and the closing line said `PASS`.

**Determinism.** `math.random` raises unless pinned. Budgets matter — assert
them with `H.fakes.random_count()`. Some functions spend rolls of different
call forms wanting opposite values (`TransferItem` wants a high `math.random()`
and a low `math.random(0,100)`); use a predicate on the call form, not a
constant.

**Reaching file-locals.** A `local function` becomes an *upvalue* of any
exported function referencing it, so no mod edit is needed:

```lua
local f = H.loader.upvalue(_G.SoulslikeScenarioLogic.TransferItem, "ignore_list")
```

Pick the anchor that genuinely closes over it. Anchoring on the wrong function
resolves nil and the spec silently tests nothing — that exact bug lived in
`probe.lua` for a while.

**Naming.** `describe("<unit>") > describe("<method()>") > describe("given
<context>") > it("<observable behaviour>")`. `it` names complete the sentence
"it …".

**Adding a file.** Drop it in `self/`, `unit/` or `e2e/`; discovery picks it
up. Discovery sorts alphabetically, so specs must not depend on load order.

---

## MCM specifically

Two independent contracts, both from the MCM repo, both silently breakable.

**Storage.** The key is the path: `"<root>/<group>/<option>"`, resolved by
`ui_mcm.get`. `val` is a required **type code** — `0` string, `1` boolean,
`2` float — *not* an initial value. A mismatch does not fail loudly; the option
reads and writes through the wrong type and never persists. `unit/mcm_options.spec.lua`
walks the tree asserting this, and cross-references it against the keys the
getters actually read — discovered by driving each getter through a recording
`ui_mcm`, never by restating them.

**Labels.** A node with no `text` derives `"ui_mcm_" .. <path with / → _>`, so
`allow_weapon_loss` in group `items` needs
`ui_mcm_soulslike_items_allow_weapon_loss`. A miss renders the raw string id on
screen and nothing else reports it. Tooltips are looked up at `<key>_desc` and
are optional.

`locals.bat` reports this in both directions. Checking both is what makes a
rename obvious: the new id has no translation **and** the old translation is
orphaned, so one mistake fails two assertions pointing at each other.

**Parity is whole-table, not label-derived.** The label scan only sees ids the
option tree asks for — 112 of 213 strings. Every message, item name and
main-menu string was outside its reach, so a gap in `soulslike_messages.xml`
was invisible to the entire suite: `locals.bat` printed it and no assertion
ever read the result. `M.parity` compares the two tables outright, and both
directions are asserted. eng-with-no-rus is debt: `run.bat` passes with it
outstanding, `locals.bat` fails. rus-with-no-eng is a defect either way — it
cannot be translation work, because there is nothing left to translate; it is a
rename applied to one table only.

**A repeated `<string id>` is invisible to everything else.** The engine keeps
one `<text>` and drops the rest, and every check here reads a *set*, where the
repeat has already collapsed and the id still resolves. So a copy-pasted block
that was never renamed silently takes the place of the string it was meant to
become, and nothing goes red. `loader.load_string_table` returns the repeat
counts alongside the set for exactly this reason. This is not hypothetical
either: three consecutive `<string>` blocks shared
`ui_mcm_soulslike_scenarios_rf_detector_scenario_weight_desc` in **both**
languages, so the live `looter_npcs_marked` option had no tooltip in game at
all. Treat a duplicate as a defect, never as debt.

**Encoding.** `gamedata/configs/text/rus/*.xml` is stored as **windows-1251**,
one byte per Cyrillic letter, and must stay that way. The engine's XML reader
takes the bytes as they are and hands them to cp1251 font tables, so a file
re-saved as UTF-8 still parses, every `<string id>` still resolves, and the
label specs stay green while every Russian string renders as mojibake. The
declaration keeps saying `windows-1251` throughout, so the diff looks innocent
— it can only be caught at the byte level.

This is not hypothetical: the rus tables were committed as UTF-8 across ten
revisions before `e5494dc` put them back. The cause is an editor, not a person — VS Code
guesses an encoding on open, guesses wrong on cp1251, and rewrites the file on
save. `unit/text_encoding.spec.lua` is the guard, on two independent signals
(the file must not decode as valid UTF-8; every high byte must exist in
cp1251), plus a BOM check and a declaration check. Line endings are
deliberately *not* asserted — stock files use LF, ours CRLF, `core.autocrlf`
rewrites them on checkout, and the engine reads both.

Because the whole MCM module funnels through one accessor, faking `ui_mcm.get`
alone makes the **real** 1200-line module run. Unset keys exercise each
getter's declared default.

---

## Before you claim it works

- `tests\run.bat` exits 0.
- `probe.lua` still reports 0 unreachable.
- A fix has a spec that **went red first**. If it never failed, it proves
  nothing — delete it or make it meaningful.
- Engine-derived constants carry citations.
- `git diff gamedata/` reviewed on its own. The mod changes are the risky half;
  they should read as targeted fixes, not incidental churn.
- Say plainly what was *not* verified. None of this runs the actual game — a
  green suite is evidence about logic, not about Anomaly.

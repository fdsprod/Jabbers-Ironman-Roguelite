# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A gameplay mod for S.T.A.L.K.E.R. Anomaly, written in Lua. It makes Ironman a roguelite:
when the player dies, their stashes, corpse, money, placed furniture and reputation carry
into the next life, degraded or partly lost depending on MCM settings. Progress is kept
per faction.

Only `gamedata/` ships. `deploy.bat` copies it into a local GAMMA mods folder. It is
gitignored and its paths are hard-coded to one machine.

The version is `config.version` in `roguelite_manager.script`.

The mod overwrites no stock script or ltx file. Keep it that way. Conflict-free loading is
a stated feature. Change stock behaviour by wrapping a function at runtime, as the corpse
module does to `death_manager`.

## Reference material

None of this ships. `_scripts/` and `_items/` are gitignored, so a fresh clone needs them
copied in.

| Where | What | Use it for |
|---|---|---|
| `_scripts/` | Stock Anomaly scripts | The base-game Lua API. Several things that look like engine behaviour are Lua here. The specs also load three of these for real. |
| `_items/` | Stock item configs | Which sections are multiuse, what binds to what, what a section really is. |
| `..\xray-monolith` | Engine source, at `028ccf5` (2024, Anomaly 1.5.3) | Anything C++ decides: bindings, packets, online and offline switching, spawning. |
| `D:\Gamma\mods` | The GAMMA modlist on this machine | Sections and scripts from other mods, such as Hideout Furniture's `placeable_*`. |
| [MCM repo](https://github.com/RAX-Anomaly/Anomaly-Mod-Configuration-Menu) | Mod Configuration Menu | Option schema, storage paths, label derivation. |

The engine clone is older than current releases. A newer engine may differ, so say which
commit a fact came from. The Soulslike mod's suite cites the newer
[themrdemonized/xray-monolith](https://github.com/themrdemonized/xray-monolith).

**Check before you assume.** Read the engine or the stock script before calling something
a bug. Theories that looked right here and were wrong: stash size limits the restore
(`SPAWN_ANTIFREEZE` is off, so spawns are not spread over frames), and placeables
duplicate when held in a stash (those sections are world-only physics objects).

## Commands

```
tests\run.bat                     all specs (self-tests gate unit and e2e)
tests\run.bat self|unit|e2e       one suite
tests\run.bat --file corpse       spec files whose path contains "corpse"
tests\run.bat -t "offline"        tests whose full name contains "offline"
tests\locals.bat                  localisation spec, then the report (strict;
                                  --lax to not fail on untranslated strings)
deploy.bat                        copy gamedata\ to the local GAMMA mods folder
```

Exit codes: 0 pass, 1 fail, 2 no Lua runtime or no match.

The suite needs LuaJIT 2.x or Lua 5.1. `run.bat` looks for `luajit.exe` on PATH, then
`tests\tools\luajit.exe`, which is gitignored. Copy it from the Soulslike repo, or build it
as `tests/CLAUDE.md` describes.

There is no build step, no linter, and no CI.

## Architecture

### Script modules

The engine loads every file in `gamedata/scripts/` as a module named after the file. A
module reads another through its global name, such as `roguelite_manager.debug_write(...)`.

| File | Role |
|---|---|
| `roguelite_manager.script` | Finds the modules, runs them at death and on the next life, reads and writes the state file. Holds `serialize_item` and `restore_item`, shared by stashes and the corpse. |
| `roguelite_manager_mcm.script` | The MCM root, plus the `get_config` accessor. Each module appends its own options. |
| `roguelite_module_stashes.script` | Player stashes and their contents, plus money. |
| `roguelite_module_player_corpse.script` | The body holding what the player died with. Wraps `death_manager`. |
| `roguelite_module_placeables.script` | Hideout furniture. Position only. |
| `roguelite_module_character_rep.script` | Actor rank, reputation and faction goodwill. |
| `roguelite_module_trader_rep.script` | Trader reputation. Remembers each met trader by name, and holds restored values until the trader comes online. |

Any `roguelite_module_*.script` is a module, third-party ones included, so the README's API
is public: `roguelite_save_state(data)`, `roguelite_load_state(data)`,
`append_mcm_options(gr)`. They all share one flat `data` table.

### One life to the next

1. `actor_on_before_death`: each module's `roguelite_save_state` fills one table, marshalled
   to `appdata\roguelite_<faction>.state`.
2. Everything else is gone. Object ids in the state file mean nothing now.
3. `actor_on_first_update` in the new game: each module's `roguelite_load_state` runs once,
   guarded by `roguelite_restore_complete`.
4. A stash's contents stay as data until the player opens it. `physic_object_on_use_callback`
   then spawns them through `restore_item`. An unopened stash carries its data through
   `save_state` and into the next death untouched.
5. The corpse fills the same way, when `death_manager.create_release_item` first reaches it.

A module's error is caught and logged by `call_module`, so it cannot cost the others their data.

### State in two places

| Where | Lifetime | Used for |
|---|---|---|
| The state file | Between lives | `roguelite_save_state` and `roguelite_load_state` |
| `save_state` and `load_state` callbacks | Between saves in one life | Data waiting to be used this life, such as unopened stashes. Lost on a level change without them, because every script re-executes. |

## Serialization: what the engine really keeps

Most bugs in this mod have come from assuming the server object knows what the client
object knows. It usually does not.

X-Ray has two copies of an object. The server object (`alife_object(id)`, `.id` is a field)
always exists. The client object (`level.object_by_id(id)`, `:id()` is a method) exists only
while the object is online. An item in a stash on another level has no client object.

| Value | Client object | Server object | When offline |
|---|---|---|---|
| Multiuse uses | `get_remaining_uses()` | Not stored at all | `get_state().item_remaining_uses[id]` |
| Condition, weapon, outfit, helmet | `condition()` | Synced live | Server object is correct |
| Condition, anything else | `condition()` | Stale: what it spawned with | `get_state().item_condition[id]`, or `device_condition[id]` for devices |
| Ammo, weapon state, addons | | Synced live | Server object is correct |

- **Those state tables are a reference, and only sometimes.** `bind_item` and `item_device`
  keep those tables as file locals. `get_state()` can reach them only because `save_state`
  and `load_state` alias them into the marshal table. **Before the first save or load in a
  session, they are nil.** Always handle that.
- **`alife():register(se)` frees `se`.** It returns a new object, and reading the old one is
  undefined behaviour that usually still answers. Always `se = alife():register(se)`.
- **A new client object starts full.** `CEatableItem::Load` sets uses to `max_uses`, and
  nothing in the engine brings them back. `bind_item` restores them on its first update.
- **`ItemProcessor` gives up.** It drops an id after about 12 updates with no client object.
- **Do not use `get_stalker_data` on the actor.** The actor's packet is laid out differently.
- **Two binders make a trader.** Most are stalkers, in `db.OnlineStalkers` with
  net callbacks. Sidorovich and the Forester are `AI_TRD_S`, bound by `bind_trader`, with
  neither, so reach them by story id.
- **Clsids are runtime ordinals**, so one saved in the state file can go stale if the
  modlist changes. Decide from the section, or from the live clsid at save time and store
  the answer, as `serialize_item` does with `degrades_by_class`. The saved clsid is only
  the fallback for state files older than that field.

## MCM

Options sit directly under the root, so the storage key is `"roguelite/<option>"`. Modules
append to the same flat list, which is why `desc_mcm` and `line` repeat. Neither stores
anything.

`val` is a type code, not an initial value: `0` string, `1` boolean, `2` float. A wrong
`val` reads and writes through the wrong type and never persists.

A node with no `text` derives its string id as `"ui_mcm_roguelite_<option>"`, with a tooltip
at `<id>_desc`. A missing translation renders the raw string id on the settings screen.
Run `tests\locals.bat` after adding, renaming or moving any option.

## Localisation

`gamedata/configs/text/eng/` and `gamedata/configs/text/rus/`.

The Russian file is **windows-1251**, one byte per Cyrillic letter, and must stay that way.
A file re-saved as UTF-8 still parses and every string id still resolves, while every
Russian string renders as mojibake. This shipped here from the Russian translation until
`tests/unit/text_encoding.spec.lua` caught it. VS Code guesses the encoding wrong on open and
rewrites the file on save, so edit it from a script, and do not edit it unless asked to.

## Tests

`tests/CLAUDE.md` is the full brief. Read it before touching anything under `tests/`. The
suite is copied from the Soulslike mod. **Copy from that repo before writing anything new.**

- The suite reimplements the parts of the engine the mod touches, in pure Lua, and runs the
  mod scripts unmodified. `bind_item`, `alife_storage_manager` and `itms_manager` are the
  real stock scripts, from `_scripts/`.
- Anything the engine decides gets a citation to the source, or it is marked `GUESS`. A
  wrong fake makes a spec permanently green while it asserts something the game would never do.
- Self-tests gate unit and e2e. A self failure aborts the run.
- A fix needs a spec that went red first, and for the right reason. Revert the fix on a
  scratch copy to check the spec guards it. That caught a spec here that passed either way.
- Never leave a spec red to mark a known bug, and never write a data table that turns a
  failure into a pass.
- `math.random` raises unless pinned. `H.new_life` resets MCM settings and the pinned roll,
  so set them after it.

The specs run against a model of the engine, so a green run is evidence about logic, not
about the game. Say plainly what was not checked in-game.

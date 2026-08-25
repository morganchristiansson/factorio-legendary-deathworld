# AGENTS.md

Factorio server workspace. Custom scenarios live under `factorio/scenarios/`,
server data under `factorio/`. The active scenario is **Legendary Deathworld**.

## Scenario layout (Legendary Deathworld)

| File | Responsibility |
|---|---|
| `control.lua` | Commands (`/reset`), lib registration via `event_handler.add_lib` |
| `freeplay.lua` | Game lifecycle: new-player kit, ordinary respawns, in-game events (nesting, research logging, victory detection) |
| `reset.lua` | Map lifecycle: seed, wipe, staged map reveal, fresh-round setup, surface events |
| `welcome.lua` | Join window shown to players |
| `jail.lua` | Gulag: `/jail`/`/free` commands, jail surface, escape prevention |

**Boundary rule:** one-time setup/reset events belong in `reset.lua`; anything
that happens during play stays in `freeplay.lua`. Player kit (`created_items`,
`respawn_items`) is player lifecycle and stays in freeplay.

## Factorio gotchas

- **One handler per event per mod.** `script.on_event` overwrites previous
  registrations for the same event. Pick a single owner and route explicitly.
  Lib tables (`.events`) registered through `event_handler` are no exception:
  their deferred registration in `on_init`/`on_load` overwrites direct ones.
- **Never call `Force:chart()` from `on_chunk_generated`.** Charting freshly
  generated chunks schedules their ungenerated neighbours, which fire the event
  again -> infinite generation cascade. Chart once after generation completes.
- `script.on_init` / `on_load` / `on_configuration_changed` also allow only one
  handler each. New modules should expose `.events` / `.on_init` / `.on_load`
  fields on their returned table and register via `handler.add_lib` in
  control.lua instead of calling these directly.
- Dynamic event registrations don't survive save/load; re-register
  conditionally in `.on_load`.
- The scenario's Lua is embedded in save files. After editing it, redeploy with
  `tools/update-lua-in-save.sh <save.zip>` (see below) — editing the
  scenario folder alone does not update running saves.

## Runtime environment facts (verified empirically)

- **Module scope vs handlers:** at control.lua top level, `game` is `nil` and
  `storage` is a throwaway empty table (writes are discarded when the save's
  storage deserializes). `prototypes` *is* readable. Consequences:
  - Static `script.set_event_filter` / `script.on_event` calls at module scope
    re-execute every session and are the correct way to establish baseline
    filters — no `.on_load` needed for them.
  - Anything needing `game` or persisted `storage` belongs in handlers/ticks,
    never at module scope (guard with `if game == nil then return ... end` if a
    helper must be callable from both).
- **Event filters are the throttle.** Prefer registering a narrow filter over
  guarding inside the handler; unfiltered `on_entity_died` fires constantly.
  When the filter target is dynamic, recompute on change (not per tick) and
  re-register; keep the handler's own check as cheap belt-and-braces.
- **Prefer engine data over hardcoded names.** Spawn tables
  (`prototypes.entity["spitter-spawner"].result_units`, weights per
  `spawn_points`) and unit stats (`attack_parameters.damage_modifier`)
  describe what actually spawns with mods/settings applied. Deriving tiers
  from them keeps scenario code stable across enemy mods and rebalances.
  Note: spawn-point windows interpolate; unit `max_health` is NOT exposed.
- **Edge-trigger state changes.** Per-tick range conditionals re-fire forever;
  store progress in `storage` (e.g. `evo_stage`, `apex_spitter`) and act only
  on transitions. Reset hooks (`reset.lua`) must re-arm these sentinels.

## Design conventions

- Announcements go through locale: a shared wrapper key
  (`ld-announcement=[color=acid][font=default-large-bold]__1__[/font][/color]`)
  supplies styling once; message keys stay plain prose. Dynamic entity names
  use their prototype's `localised_name` as a fill parameter.
- One remote-interface member per live feature only — no vestigial
  stock-freeplay accessors (skip_intro/chart_distance-style remnants were
  removed; don't reintroduce them).
- Simple beats clever: a pure compute function + a change-guarded applier +
  one callsite in the minute tick is the preferred shape (see apex-spitter
  logic in freeplay.lua).

## Style

- Indentation: **4 spaces**, never tabs, in all added or updated code.
- All diagnostics go through `log()` — no `helpers.write_file` feeds.
- Keep comments present-tense; don't narrate removed code.

## Deploying scenario changes to saves

```sh
tools/update-lua-in-save.sh --dry-run <save.zip>   # preview
tools/update-lua-in-save.sh <save.zip>             # apply (+ .bak backup)
```

- Syncs top-level `*.lua`, `description.json`, `locale/en/freeplay.cfg` into
  existing save zips; new `.lua` modules are picked up automatically.
- Stop the Factorio server first (the script enforces this; `--force` overrides for local testing).
- Verify after deploy: fresh join gets crash site + turret + reveal;
  `/reset` twice; ordinary death gives only pistol + ammo.

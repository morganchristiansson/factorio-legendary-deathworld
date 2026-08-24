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

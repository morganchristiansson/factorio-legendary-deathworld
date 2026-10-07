# AGENTS.md

Factorio server workspace. Custom scenarios live under `factorio/scenarios/`,
server data under `factorio/`. The active scenario is **Legendary Deathworld**.

## Scenario layout (Legendary Deathworld)

| File | Responsibility |
|---|---|
| `control.lua` | Commands (`/reset`), lib registration via `event_handler.add_lib` |
| `freeplay.lua` | Game lifecycle: new-player kit, ordinary respawns, in-game events (nesting, research logging, victory detection) |
| `reset.lua` | Map lifecycle: dual-surface swap (`nauvis1`/`nauvis2` on the `nauvis2` planet), staged map reveal, dormant-surface pre-generation during the reroll/defeat countdown, fresh-round setup, surface events; the `nauvis` primary is a permanent dummy |
| `welcome.lua` | Join window shown to players |
| `jail.lua` | Gulag: the pit surface, the jail records, escape prevention |
| `groups.lua` | Permission groups and their commands: `/jail`, `/release`, `/freeze`, `/trust` |
| `register.lua` | Transient registrations: one-shot tasks, the map reveal's `on_tick`, the expiry sweep and dynamic event filters — one module owns their save/load re-arming |

**Boundary rule:** one-time setup/reset events belong in `reset.lua`; anything
that happens during play stays in `freeplay.lua`. Player kit (`created_items`,
`respawn_items`) is player lifecycle and stays in freeplay.

## Factorio gotchas

- **`event_handler` multiplexes; `script.on_event` does not.** A lib's
  `.events` table is collected per event and registered as *one* handler that
  fans out to every lib (`core/lualib/event_handler.lua`), so several modules can
  register the same event. A *direct* `script.on_event` replaces the previous
  handler for that event, which is the case to watch: the lib registers without
  filters, so an event declared in any `.events` table loses the filter of a
  direct registration.
- **Keep the hot events out of `.events` tables.** `on_entity_died` and
  `on_post_entity_died` are registered directly by `freeplay.lua` with narrow
  filters and re-set in `on_load`, because they fire on every entity death.
  Declaring either in a `.events` table would clear those filters.
- **Order between two modules handling one event is undefined** — the fan-out
  iterates a `pairs`. Modules that share an event must not depend on each
  other's ordering.
- **Never call `Force:chart()` from `on_chunk_generated`.** Charting freshly
  generated chunks schedules their ungenerated neighbours, which fire the event
  again -> infinite generation cascade. Chart once after generation completes.
- **Deleting a surface is the only way to disassociate it from its planet.**
  The reset swap leans on this: create the dormant round surface, move players
  onto it (character detached, no death event), delete the old one, then
  `on_surface_deleted` re-associates the fresh surface with the host planet.
  The two round surfaces (`nauvis1`/`nauvis2`) live on the host planet
  `nauvis2` (a planet the server's EverythingOnNauvis fork adds, unlocked for
  the player force so its surfaces group under it in the map view); the
  vanilla `nauvis` planet and its primary surface are a permanent dummy -- the
  primary cannot be deleted (`delete_surface` queues but never completes), and
  `associate_surface` has no disassociate form, so the primary can never host
  the swap. A save deployed mid-round on the primary keeps playing there until
  the first `/reset`, which migrates it (perform_reset's migration branch).
- `game.surfaces[1]` means nothing across a swap: indices rebalance when the
  round surface is deleted. Everything round-facing keys off
  `reset.active_surface()` (the host planet's surface, with name fallbacks
  for the two-tick window mid-swap), or `event.surface_index` inside handlers,
  and name-keyed engine calls (`get_evolution_factor`, `chart_all`, pollution
  stats) take that surface object, never `"nauvis"`.
- **Chunk generation can outlive association.** The dormant surface's chunks
  are pre-generated before it becomes the round surface, so guards like
  freeplay's legendary-spawner upgrade use `reset.is_round_surface(surface)`
  (name ∈ {nauvis1, nauvis2, plus the dummy primary}), not `surface.planet`
  -- the planet is nil during pre-generation.
- **Permission writes from a player's command are refused**, whatever the admin
  flag says: `edit_permission_group` for moving a player, `add_permission_group`
  for creating one. `groups.lua` queues every group change and applies it from a
  tick, where there is no acting player. Don't write a group from a command.
- `script.on_init` / `on_load` / `on_configuration_changed` also allow only one
  handler each. New modules should expose `.events` / `.on_init` / `.on_load`
  fields on their returned table and register via `handler.add_lib` in
  control.lua instead of calling these directly.
- **Dynamic event registrations don't survive save/load.** Route them through
  `register.lua` instead of hand-rolling `on_load` re-arming: declare the
  callback at module scope (`register.declare`/`register.define`), toggle it at
  runtime (`register.set_active`/`clear_active`, `register.after`), and the
  module's own `on_load` re-applies the stored active state and filters from
  its one place. Two rules it enforces: never `on_nth_tick(1)` — a cadence-1
  registration does not survive a save, so registering it in `on_load` trips
  the script-event mismatch check when a late-joining player loads the level
  (probe-verified) — and the `on_tick` slot has a single owner (the map
  reveal). Static module-scope registrations (pregen `3`, the per-second `60`
  and minute `3600` drivers, the entity-died handlers and their baseline
  filters) run every session and stay direct.
- The scenario's Lua is embedded in save files. After editing it, redeploy with
  `tools/sync-save <save.zip>` (see below) — editing the
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

## Tests

- `test/` holds the runnable checks; `lua5.4 test/permissions.lua` from the repo
  root covers the permission-group round trips against a stubbed engine API.
- Add a case there rather than in a tool: `tools/` is deployment scripts only.

## Deploying scenario changes to saves

```sh
tools/sync-save --dry-run <save.zip>   # preview
tools/sync-save <save.zip>             # apply (+ .bak backup)
```

- Syncs top-level `*.lua`, `description.json`, `locale/*/freeplay.cfg` into
  existing save zips; new `.lua` modules are picked up automatically.
- Stop the Factorio server first (the script enforces this; `--force` overrides for local testing).
- Verify after deploy: fresh join gets crash site + turret + reveal;
  `/reset` twice; ordinary death gives the same kit as the crash site.

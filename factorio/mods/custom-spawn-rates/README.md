# Custom Spawn Rates

Standalone Factorio (2.0) mod: per-nest control over enemy spawn composition
via startup map settings. Every well-known vanilla / Space Age nest gets its
own startup setting — `biter-spawner`, `spitter-spawner`, `egg-raft`,
`small-egg-raft` — plus one free-form setting that reaches any nest added by
other mods (e.g. Colossal Enemies).

> Factorio's settings stage cannot read `data.raw`, so spawners cannot be
> enumerated dynamically at setting-generation time; hence the hardcoded list
> plus the free-form escape hatch.

## Syntax

Each spawner's startup setting holds semicolon-separated entries:

```
<unit-name> <evo=rate,evo=rate,...>     add or override the unit's rates
-<unit-name>                            remove the unit from this nest
```

The rate is the unit's share of that nest's spawns at a given evolution
factor (`result_units` semantics): shares interpolate linearly between
pairs and are normalised across all of the nest's units at every evolution
level, so they behave as percentages of total spawns. The rate stays 0
below the first pair's evolution factor — `0.35=0.01` alone delays the
unit until evo 0.35, no leading `0=0` pair needed.

Examples:

```
small-stomper-pentapod 0.35=0.01            stomper pentapods from evo 0.35 at ~1%
medium-biter 0.2=0.00,0.6=0.40              override vanilla medium-biter rates
-small-biter;big-spitter 1=0.10             no small-biters, big-spitters at 10%
```

Leave a spawner's setting blank to leave it untouched. The same syntax
documentation ships in-game as the setting tooltips.

### Other (modded) nests

The "Custom spawn rates: other nests" setting uses section syntax — a
`<spawner-name>:` header followed by semicolon-separated entries:

```
some-modded-spawner: tiny-critter 0.5=0.02; -small-critter
another-modded-spawner: -mini-boss
```

Entries follow exactly the same syntax as above; absent spawners are
skipped with a log message.

## Behaviour notes

- Adding a unit that no installed mod defines **fails map load** with an
  engine error naming the spawner (`assignID: entity with name '...' does
  not exist`) — deliberate: typos must surface, not vanish. Fix the value
  via save-select → Mod settings, then restart the map.
- Malformed entries (no rate table, evo > 1) are logged and skipped; one
  bad entry never blocks the others or map loading.
- Settings exist only for well-known spawners. Values configured for
  since-removed mods' spawners are ignored gracefully (with a log message),
  and modded nests are covered by the free-form setting instead.
- Changes apply on map load / startup-setting change, like any startup setting.

## Files

| File | Responsibility |
|---|---|
| `lib.lua` | Parsing and applying rate entries (no Factorio API except `log`) |
| `settings.lua` | Defines one string-setting per known `unit-spawner`, plus the free-form extra setting |
| `data-final-fixes.lua` | Routes each setting to its spawner, applies entries |

## Tests

Pure-Lua suite stubbing the data-stage globals — no Factorio needed. Run it
in the dev container (lua5.4 is part of the workspace image):

```sh
lua5.4 tests/run_tests.lua
```

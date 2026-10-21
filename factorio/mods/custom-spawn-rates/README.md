# Custom Spawn Rates + Tech Changes

Startup settings that edit prototype tables: enemy nest spawns and
tech-tree fields. Blank = untouched; applies at map load.

## Syntax

Entries are separated by `;` or a newline:

    <path> <value>     set
    +<path> <value>    add/merge
    -<path> <value>    remove
    -<path>            clear

Values: `3`, `a,b,c`, `k=1,v=2`, or `{k=1},{k=2}`. The engine shapes the
value to the live field, so one syntax covers numbers, name lists,
key=value lists and lists of structs. Unknown names are left in place so
the map fails naming the typo, like vanilla. `#` is a comment.

## Settings

- `custom-spawn-rates-<nest>` — one per known nest (`biter-spawner`,
  `spitter-spawner`, `gleba-spawner-small`, `gleba-spawner`). A bare unit
  name means `result_units.<unit>`; rates are `evo=share`, normalised
  across the nest.
- `custom-spawn-rates-tech` — techs: `tech-name: <entries>`. `ingredients`
  means `unit.ingredients`; `unit` and `research_trigger` are exclusive;
  `unit` merges (setting count/time keeps ingredients).
- `custom-spawn-rates-extra` — any prototype: `type.name: <entries>`,
  where the header is the prototype's path in `data.raw` (`item.ice`). The
  type is part of the address, because one name can live in several
  tables (`iron-plate` is both an item and a recipe). Entries name the
  prototype's own attributes; `spoil_ticks` takes a duration (`30s`,
  `10m`, `2h`, `1d`) or a plain tick count. An item with `spoil_ticks`
  and no `spoil_result` spoils into nothing (it is destroyed);
  `-spoil_result` drops a result an item already has. Only attributes
  the game uses on that prototype's type can be set, so a typo is
  reported instead of silently ignored; the prototype's `type` and `name`
  are its identity and cannot be set at all.

## Examples from our server

Biter spawner:

    medium-biter 0.2=0,0.6=0.3,0.7=0.1,0.9=0
    big-biter 0.5=0,0.8=0.4,1.0=0.25
    behemoth-biter 0.7=0,0.95=0.3
    colossal-biter 0.8=0.0001,1.0=0.02
    gargantuan-biter 0.95=0.0001,1.0=0.02

Gleba nests: `-loot`

Techs:

    recycling: research_trigger type=mine-entity,entity=scrap
    calcite-processing: prerequisites; +effects {type=unlock-recipe,recipe=oil-refinery}
    landfill: prerequisites; research_trigger type=mine-entity,entity=stone,count=50
    rocket-turret: -unit.ingredients chemical-science-pack,space-science-pack; unit.count 100
    refined-flammables-1: -effects {type=turret-attack,turret_id=flamethrower-turret}

Prototypes:

    item.ice: spoil_ticks 1h
    item.nutrients: spoil_result copper-ore

Durations are tick counts (60 ticks = 1 second, so `1h` = 216000 ticks).
The map's `difficulty_settings.spoil_time_modifier` scales that: at the
server's 0.3, `1h` of ticks is about 18 real minutes.

## Files

| File | Responsibility |
|---|---|
| `lib.lua` | the engine (parser, ops, reports) |
| `settings.lua` | startup string-settings |
| `data-final-fixes.lua` | routes settings to prototypes |

## Tests

    lua5.4 tests/run_tests.lua    # unit suites, no Factorio
    python3 tests/e2e_dump.py     # real data stage via --dump-data

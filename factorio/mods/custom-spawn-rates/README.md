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
- `custom-spawn-rates-extra` — nests from other mods:
  `nest-name: <entries>`.
- `custom-spawn-rates-tech` — techs: `tech-name: <entries>`. `ingredients`
  means `unit.ingredients`; `unit` and `research_trigger` are exclusive;
  `unit` merges (setting count/time keeps ingredients).

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

## Files

| File | Responsibility |
|---|---|
| `lib.lua` | the engine (parser, ops, reports) |
| `settings.lua` | startup string-settings |
| `data-final-fixes.lua` | routes settings to prototypes |

## Tests

    lua5.4 tests/run_tests.lua    # unit suites, no Factorio
    python3 tests/e2e_dump.py     # real data stage via --dump-data

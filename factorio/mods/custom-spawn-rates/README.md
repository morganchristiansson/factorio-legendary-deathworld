# Custom Spawn Rates + Tech Changes

Factorio 2.0 mod: startup settings to tweak enemy spawns and tech tree.
Applies on map load / startup-setting change. Blank = untouched.

> Settings stage cannot read `data.raw`, so spawners/techs are not
> enumerated; known nests get dedicated settings, everything else uses
> free-form section settings.

## Spawn rates

Per-nest setting, `;`-separated entries:

```
<unit> <evo=rate,...>   add/override rates
-<unit>                 remove unit
```

Rates are `result_units` shares: interpolate linearly, normalised across
the nest. Rate is 0 below the first evo — `0.35=0.01` delays until evo 0.35.

```
small-stomper-pentapod 0.35=0.01
medium-biter 0.2=0.00,0.6=0.40
-small-biter;big-spitter 1=0.10
```

Other nests (`other nests` setting), `spawner:` sections:

```
some-modded-spawner: tiny-critter 0.5=0.02; -small-critter
```

Known nests: `biter-spawner`, `spitter-spawner`, `gleba-spawner-small`,
`gleba-spawner`. Absent spawners (e.g. Gleba nests on a base-only
install): skipped with log.

## Tech changes

One setting (`Custom tech changes`), `tech:` sections with `;`-separated ops.
Set is `<field> <value>`, remove is `-<field>` — same shape as spawns.

```
prerequisites a,b,c        replace list (bare `prerequisites` clears)
+prerequisites x,y         add to list
-prerequisites x,y         remove from list
unit.count 300             set unit count (skipped if tech has no unit)
unit.time 30               set unit time (skipped if tech has no unit)
unit count=500,time=30     set lab cost, creating it when absent, and clear
                           any trigger (count/time each optional, need one)
unit.ingredients a=1,b=1   replace the science-pack cost wholesale
                           (skipped if tech has no unit)
+unit.ingredients a=1      merge packs into the cost (amounts replaced)
-unit.ingredients x,y      remove science packs from the cost
research_trigger k=v,...   set research_trigger, clears unit (needs type=)
-research_trigger          clear trigger (skipped if tech has no unit)
+effects {...},{...}       append effects (braces required for more than one)
# ...                      comments (`#` to `;`/newline) are ignored
```

```
biolab: prerequisites biter-egg-handling,kovarex-enrichment-process
transport-belt-capacity-2: unit.count 300
heating-tower: -research_trigger
steel-processing: research_trigger type=craft-item,item=iron-plate,count=200
```

Later entries win. Unknown techs: skipped with log.

Long values can be drafted grouped (one entry per line, `#` headings)
and collapsed with `tools/settings-formatter.html` (open in a browser,
both directions, no dependencies).

## Notes

- Unknown unit/prereq names are left in place so the engine fails map load
  naming the typo (`assignID` error). Fix via save-select → Mod settings.
- Malformed entries are logged and skipped; one bad entry never blocks others.
- Applied changes print one report line each (`before → after`, no prefix);
  repeats print `— no change`. Warnings (unknown names, bad entries,
  skipped ops) stay on `log()` with the `custom-spawn-rates-` prefix.
- Shipped defaults are blank, so the mod loads on base-only installs
  (a Space Age unit name as default would fail map load there).
- Setting a trigger clears `unit`, and setting `unit` clears the trigger;
  clearing never leaves neither `unit` nor trigger (skipped with log).
  Use the `unit` op (not `count`/`time` alone) to turn a trigger-only
  tech into a lab tech.

## Files

| File | Responsibility |
|---|---|
| `lib.lua` | Spawn parsing/apply (only `log`/`print` from Factorio API) |
| `tech.lua` | Tech parsing/apply (only `log`/`print` from Factorio API) |
| `settings.lua` | Startup string-settings |
| `data-final-fixes.lua` | Routes settings to prototypes |
| `tools/package-mod` | Zip the mod for the portal (`./tools/package-mod`) |
| `tools/settings-formatter.html` | Draft long setting values grouped, collapse to one line |

## Tests

```sh
lua5.4 tests/run_tests.lua          # all unit suites, no Factorio needed
lua5.4 tests/run_tests.lua spawn   # spawn-rate suite only
lua5.4 tests/run_tests.lua tech    # tech-tree suite only
python3 tests/e2e_dump.py           # e2e: real data stage via --dump-data
```

Unit suites live in `tests/test_spawn_rates.lua` / `tests/test_tech_tree.lua`
(`tests/run_tests.lua` is the harness + cross-feature settings test). The
e2e stays one script on purpose: a single `--dump-data` launch covers both
features, so splitting it would only multiply launches. It runs two joined
phases: fixed test values with space-age on (spawn remove/set incl. Gleba
nests, trigger set/clear, count, prereq add/remove/replace), then mod
defaults on a base-only install (regression test for the Space Age
defaults bug). Isolated mod dir + config (redirected `write-data`,
`--mod-directory` under a temp dir — the live install is never touched).
Needs the Factorio binary (`--factorio-bin PATH` overrides the
`/factorio/bin/x64/factorio` default); `--keep-tmp` keeps the dump for
inspection.

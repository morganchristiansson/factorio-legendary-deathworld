-- Spawn-rate suite (lib.lua). Runs through tests/run_tests.lua, which
-- provides the harness globals (test, eq, fresh_world, some_log, ...).

-- ---------------------------------------------------------------------------
-- parse_rate

test("parse_rate: reads pairs and sorts by evolution", function()
    local points, err = SpawnRates.parse_rate("0.6=0.4, 0.2=0.00")
    assert(not err, err)
    eq(points, { { 0.2, 0.0 }, { 0.6, 0.4 } })
end)

test("parse_rate: single pair allowed", function()
    local points, err = SpawnRates.parse_rate("1=0.5")
    assert(not err, err)
    eq(points, { { 1, 0.5 } })
end)

test("parse_rate: rejects empty / garbage", function()
    local _, err = SpawnRates.parse_rate("")
    assert(err, "expected error for empty string")
    _, err = SpawnRates.parse_rate("abc")
    assert(err, "expected error for garbage")
end)

test("parse_rate: rejects evo above 1", function()
    local _, err = SpawnRates.parse_rate("1.5=0.5")
    assert(err and err:find("above 1"), "expected evo>1 error, got: " .. tostring(err))
end)

-- ---------------------------------------------------------------------------
-- parse_entry

test("parse_entry: set mode parses unit and points", function()
    local mode, unit, points = SpawnRates.parse_entry(" medium-biter  0.2=0.0 ")
    eq(mode, "set"); eq(unit, "medium-biter")
    eq(points, { { 0.2, 0.0 } })
end)

test("parse_entry: remove mode strips leading dash", function()
    local mode, unit = SpawnRates.parse_entry("-small-biter")
    eq(mode, "remove"); eq(unit, "small-biter")
end)

test("parse_entry: reports missing rate table", function()
    local mode, err = SpawnRates.parse_entry("medium-biter")
    assert(not mode and err:find("missing rate"), tostring(err))
end)

test("parse_entry: reports invalid rate table", function()
    local mode, err = SpawnRates.parse_entry("medium-biter oops")
    assert(not mode and err:find("no valid evo=rate pairs"), tostring(err))
end)

-- ---------------------------------------------------------------------------
-- apply_setting against a stubbed world

test("apply_setting: blank value is a no-op", function()
    local spawners = fresh_world()
    local before = #spawners["biter-spawner"].result_units
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner", "")
    eq(#spawners["biter-spawner"].result_units, before)
end)

test("apply_setting: adds a new unit", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "small-stomper-pentapod 0.35=0.01")
    local units = spawners["biter-spawner"].result_units
    eq(#units, 3)
    eq(units[3][1], "small-stomper-pentapod")
    eq(units[3][2], { { 0.35, 0.01 } })
end)

test("apply_setting: overrides an existing rate table in place", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "medium-biter 0=0.9")
    local units = spawners["biter-spawner"].result_units
    eq(#units, 2)
    eq(units[1][1], "small-biter")           -- order preserved
    eq(units[2][2], { { 0, 0.9 } })          -- replaced, not appended
end)

test("apply_setting: removes a unit", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "-small-biter")
    local units = spawners["biter-spawner"].result_units
    eq(#units, 1)
    eq(units[1][1], "medium-biter")
end)

test("apply_setting: multiple entries in one value", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["mod-spawner"], "mod-spawner",
        "-x ; small-stomper-pentapod 0.35=0.01;-small-biter")
    eq(#spawners["mod-spawner"].result_units, 1)
end)

test("apply_setting: unknown units are applied verbatim (engine hard-fails)", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "nonexistent-unit 1=0.5")
    local units = spawners["biter-spawner"].result_units
    eq(#units, 3)
    eq(units[3][1], "nonexistent-unit")
end)

test("apply_setting: accepts spider-units (pentapods)", function()
    local spawners = fresh_world()   -- small-strafer-pentapod is a spider-unit stub
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "small-strafer-pentapod 0.35=0.01")
    local units = spawners["biter-spawner"].result_units
    eq(#units, 3)
    eq(units[3][1], "small-strafer-pentapod")
end)

test("apply_setting: removing an absent unit logs but does not crash", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "-big-spitter")
    eq(#spawners["biter-spawner"].result_units, 2)
end)

test("apply_setting: malformed entry skipped, later entries still applied", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "medium-biter oops; -small-biter")
    local units = spawners["biter-spawner"].result_units
    eq(#units, 1)
    eq(units[1][1], "medium-biter")
end)

-- ---------------------------------------------------------------------------
-- parse_overrides (extra-setting sections)

test("parse_overrides: splits sections per spawner", function()
    local overrides = SpawnRates.parse_overrides(
        "biter-spawner: -small-biter ; medium-biter 0.2=0.0;spitter-spawner:-big-spitter")
    eq(overrides["biter-spawner"], "-small-biter;medium-biter 0.2=0.0")
    eq(overrides["spitter-spawner"], "-big-spitter")
end)

test("parse_overrides: blank value yields empty map", function()
    eq(#SpawnRates.parse_overrides(""), 0)
    eq(#SpawnRates.parse_overrides("   "), 0)
end)

test("parse_overrides: entries before any header are ignored", function()
    local overrides = SpawnRates.parse_overrides("medium-biter 0=1;biter-spawner: -small-biter")
    for name in pairs(overrides) do
        eq(name, "biter-spawner")
    end
    eq(overrides["biter-spawner"], "-small-biter")
end)

-- ---------------------------------------------------------------------------
-- End-to-end through data-final-fixes.lua with full global stubs.

test("data-final-fixes: routes dedicated settings to matching spawners", function()
    local spawners = fresh_world()
    data.raw["unit-spawner"] = spawners
    settings = {
        startup = {
            [SpawnRates.SETTING_PREFIX .. "biter-spawner"] =
                { value = "small-stomper-pentapod 0.35=0.01" },
            [SpawnRates.SETTING_PREFIX .. "gone-spawner"] = nil,
            ["some-other-mods-setting"] = { value = "nonsense" },
        },
    }
    dofile("data-final-fixes.lua")
    local units = spawners["biter-spawner"].result_units
    eq(#units, 3)
    eq(units[3][1], "small-stomper-pentapod")
end)

test("data-final-fixes: dedicated setting for absent prototype is skipped", function()
    local spawners = fresh_world()
    data.raw["unit-spawner"] = spawners
    settings = {
        startup = {
            -- spitter-spawner is known but not stubbed into the world
            -- (like the Gleba nests on a base-only install).
            [SpawnRates.SETTING_PREFIX .. "spitter-spawner"] =
                { value = "small-strafer-pentapod 0.35=0.01" },
        },
    }
    dofile("data-final-fixes.lua")
    assert(some_log("does not exist"), "expected skip log for spitter-spawner")
    eq(#spawners["biter-spawner"].result_units, 2)  -- other nests untouched
end)

test("data-final-fixes: extra setting reaches modded spawners", function()
    local spawners = fresh_world()
    data.raw["unit-spawner"] = spawners
    settings = {
        startup = {
            [SpawnRates.EXTRA_SETTING_NAME] = { value =
                "mod-spawner: nonexistent-unit 1=0.5; small-stomper-pentapod 0.35=0.01" ..
                ";gone-spawner: -small-biter" },
        },
    }
    dofile("data-final-fixes.lua")
    local units = spawners["mod-spawner"].result_units
    eq(#units, 2)                            -- entries applied verbatim,
    eq(units[1][1], "nonexistent-unit")      -- including unknown ones
    eq(units[2][1], "small-stomper-pentapod")
    assert(some_log("does not exist"), "expected skip log for gone-spawner")
end)

test("comments: '#' headings and trailing comments are ignored silently", function()
    local spawners = fresh_world()
    local before = #spawners["biter-spawner"].result_units
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "# just a heading")
    eq(#spawners["biter-spawner"].result_units, before)
    eq(#LOG_LINES, 0)
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "-small-biter # gone")
    eq(#spawners["biter-spawner"].result_units, before - 1)
end)

test("parse_overrides: '#' comments are stripped, not orphaned", function()
    local overrides, orphans = SpawnRates.parse_overrides(
        "# heading\nbiter-spawner: -small-biter # gone")
    eq(#orphans, 0)
    eq(overrides["biter-spawner"], "-small-biter")
end)

test("spawn apply: update reports old and new tables, repeat is a no-op", function()
    local spawners = fresh_world()
    LOG_LINES = {}
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "medium-biter 0.2=0.0,0.6=0.4")
    assert(some_log("updated"),
        "expected update log, got: " .. table.concat(LOG_LINES, " | "))
    assert(some_log("→"), "expected before/after arrow")
    LOG_LINES = {}
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "medium-biter 0.2=0.0,0.6=0.4")
    assert(some_log("no change"),
        "expected no-op log, got: " .. table.concat(LOG_LINES, " | "))
end)

test("spawn apply: remove reports the dropped table", function()
    local spawners = fresh_world()
    LOG_LINES = {}
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "-small-biter")
    assert(some_log('removed "small%-biter"'), "expected remove log")
    assert(some_log("%(was "), "expected old-table note")
end)

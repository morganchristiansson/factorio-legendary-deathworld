-- Spawn-rate suite (engine + spawn surface of lib.lua). Runs through
-- tests/run_tests.lua, which provides the harness globals (test, eq,
-- fresh_world, some_log, SpawnRates, Mod).

-- ---------------------------------------------------------------------------
-- Generic literal grammar

test("parse_literal: names, single name, numbers", function()
    eq(SpawnRates.parse_literal("a,b,c"), { "a", "b", "c" })
    eq(SpawnRates.parse_literal(" a , b "), { "a", "b" })
    eq(SpawnRates.parse_literal("foo"), { "foo" })
    eq(SpawnRates.parse_literal("300"), 300)
    eq(SpawnRates.parse_literal(""), nil)
end)

test("parse_literal: pair maps with numeric coercion", function()
    eq(SpawnRates.parse_literal("type=craft-item,count=200"), {
        type = "craft-item", count = 200 })
    eq(SpawnRates.parse_literal("0.2=0.00,0.6=0.4"), {
        ["0.2"] = 0.0, ["0.6"] = 0.4 })
    eq(SpawnRates.parse_literal("modifier=0.2"), { modifier = 0.2 })
end)

test("parse_literal: brace struct lists", function()
    eq(SpawnRates.parse_literal("{type=a,recipe=x},{type=b,recipe=y}"), {
        { type = "a", recipe = "x" }, { type = "b", recipe = "y" } })
    eq(SpawnRates.parse_literal("{type=a}"), { { type = "a" } })
    local _, err = SpawnRates.parse_literal("{type=a")
    assert(err and err:find("unbalanced"), tostring(err))
    _, err = SpawnRates.parse_literal("{type=a},b")
    assert(err and err:find("between"), tostring(err))
end)

-- ---------------------------------------------------------------------------
-- Sections

test("sections: splits per name, strips comments", function()
    local sections, orphans = SpawnRates.sections(
        "# heading\nbiter-spawner: -small-biter ; medium-biter 0.2=0.0;spitter-spawner:-big-spitter # gone")
    eq(#orphans, 0)
    eq(sections["biter-spawner"], "-small-biter;medium-biter 0.2=0.0")
    eq(sections["spitter-spawner"], "-big-spitter")
end)

test("sections: blank value yields empty map, orphans reported", function()
    eq(#SpawnRates.sections(""), 0)
    eq(#SpawnRates.sections("   "), 0)
    local _, orphans = SpawnRates.sections("medium-biter 0=1;biter-spawner: -small-biter")
    eq(#orphans, 1)
    eq(orphans[1], "medium-biter 0=1")
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
    eq(units[3], { "small-stomper-pentapod", { { 0.35, 0.01 } } })
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

test("apply_setting: rates are sorted by evolution, evo above 1 rejected", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "medium-biter 0.6=0.4,0.2=0.00")
    eq(spawners["biter-spawner"].result_units[2][2],
        { { 0.2, 0.0 }, { 0.6, 0.4 } })
    LOG_LINES = {}
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "small-biter 1.5=0.5")
    assert(some_log("above 1"), "expected evo>1 reject, got: " .. all_logs())
    eq(#spawners["biter-spawner"].result_units, 2)
end)

test("apply_setting: removes a unit", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "-small-biter")
    local units = spawners["biter-spawner"].result_units
    eq(#units, 1)
    eq(units[1][1], "medium-biter")
    assert(some_log("small%-biter: removed"), "expected remove report")
end)

test("apply_setting: -loot and -result_units clear the attribute", function()
    local spawners = fresh_world()
    spawners["biter-spawner"].loot = { { "iron-plate", 10 } }
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner", "-loot")
    eq(#spawners["biter-spawner"].loot, 0)
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "-result_units")
    eq(#spawners["biter-spawner"].result_units, 0)
end)

test("apply_setting: multiple entries in one value", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["mod-spawner"], "mod-spawner",
        "-x ; small-stomper-pentapod 0.35=0.01;-small-biter")
    local units = spawners["mod-spawner"].result_units
    eq(#units, 1)
    eq(units[1][1], "small-stomper-pentapod")
end)

test("apply_setting: unknown units are applied verbatim (engine hard-fails)", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "nonexistent-unit 1=0.5")
    local units = spawners["biter-spawner"].result_units
    eq(#units, 3)
    eq(units[3][1], "nonexistent-unit")
end)

test("apply_setting: removing an absent unit logs but does not crash", function()
    local spawners = fresh_world()
    LOG_LINES = {}
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "-big-spitter")
    eq(#spawners["biter-spawner"].result_units, 2)
    assert(some_log("not present — nothing to remove"), all_logs())
end)

test("apply_setting: malformed entry skipped, later entries still applied", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "medium-biter oops; -small-biter")
    local units = spawners["biter-spawner"].result_units
    eq(#units, 1)                            -- medium-biter entry skipped
    eq(units[1][1], "medium-biter")
    assert(some_log("bad entry"), "expected malformed-entry log")
end)

test("apply_setting: bare unit name is a missing value, not a clear", function()
    local spawners = fresh_world()
    LOG_LINES = {}
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "medium-biter")
    eq(#spawners["biter-spawner"].result_units, 2)
    assert(some_log("missing value"), all_logs())
end)

test("apply_setting: reports no-change on repeat", function()
    local spawners = fresh_world()
    LOG_LINES = {}
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "medium-biter 0.2=0.0,0.6=0.3")
    assert(some_log("already"), "expected no-change report, got: " .. all_logs())
    assert(some_log("no change"), all_logs())
end)

test("comments: '#' headings and trailing comments are ignored silently", function()
    local spawners = fresh_world()
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "# just a heading")
    eq(#LOG_LINES, 0)
    SpawnRates.apply_setting(spawners["biter-spawner"], "biter-spawner",
        "-small-biter # gone")
    eq(#spawners["biter-spawner"].result_units, 1)
end)

-- ---------------------------------------------------------------------------
-- The engine is a generic table manipulator: unregistered attributes work.

test("engine: arbitrary paths on arbitrary tables", function()
    local ctx = { resolve = function(h) return h end }
    local t = { unit = { count = 10 }, deep = { x = 1 } }
    local ok = Mod.apply_entry(t, "unit.count 300", ctx)
    assert(ok, "set must apply")
    eq(t.unit.count, 300)
    ok = Mod.apply_entry(t, "deep.extra 5", ctx)
    assert(ok, "new key must apply")
    eq(t.deep.extra, 5)
    ok = Mod.apply_entry(t, "+deep.list a,b", ctx)
    assert(ok, "add must apply")
    eq(t.deep.list, { "a", "b" })
    ok = Mod.apply_entry(t, "-deep.list a", ctx)
    assert(ok, "remove must apply")
    eq(t.deep.list, { "b" })
    -- mid-path misses are skips, not silent creations
    local ok2, err = Mod.apply_entry(t, "deep.x.y 5", ctx)
    assert(not ok2 and err and err:find("does not exist"), tostring(err))
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
    assert(some_log("does not exist"), "expected skip log for gone-spawner")
end)

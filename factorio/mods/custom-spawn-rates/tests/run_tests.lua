-- Test harness for Custom Spawn Rates. Runs with plain Lua (no Factorio).
-- Stubs the data-stage globals (data, log), loads lib.lua, and checks
-- parsing plus end-to-end application of setting values.

local failures = 0
local passed = 0

local function eq(actual, expected, message)
    if type(expected) == "table" then
        local ok = type(actual) == "table" and #actual == #expected
        if ok then
            for i, v in ipairs(expected) do
                if actual[i][1] ~= v[1] or actual[i][2] ~= v[2] then ok = false break end
            end
        end
        if not ok then error((message or "tables differ") .. ": got " ..
            serpent_like(actual) .. ", want " .. serpent_like(expected)) end
    elseif actual ~= expected then
        error((message or "values differ") .. ": got " .. tostring(actual) ..
            ", want " .. tostring(expected))
    end
end

function serpent_like(t)
    local parts = {}
    for _, v in ipairs(t or {}) do
        parts[#parts + 1] = "{" .. v[1] .. "," .. v[2] .. "}"
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS  " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. "\n      " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Stub data stage environment, load the module under test.

log = function(msg) LOG_LINES[#LOG_LINES + 1] = msg end
LOG_LINES = {}
data = { raw = {} }

local SpawnRates = dofile("lib.lua")

local function make_spawner(units)
    return { result_units = units or {} }
end

local function fresh_world()
    -- biter-spawner with vanilla-ish entries; one extra modded spawner.
    LOG_LINES = {}
    data.raw = {}
    data.raw["unit"] = {
        ["small-biter"] = true,
        ["medium-biter"] = true,
        ["small-stomper-pentapod"] = true,
    }
    data.raw["spider-unit"] = {
        ["small-strafer-pentapod"] = true,
    }
    return {
        ["biter-spawner"] = make_spawner({
            { "small-biter", { { 0.0, 0.3 }, { 0.35, 0 } } },
            { "medium-biter", { { 0.2, 0.0 }, { 0.6, 0.3 } } },
        }),
        ["mod-spawner"] = make_spawner(),
    }
end

local function last_log()
    return LOG_LINES[#LOG_LINES] or ""
end

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
-- End-to-end through data-final-fixes.lua with full global stubs.

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

-- True if any accumulated log line matches the pattern.
local function some_log(pattern)
    for _, line in ipairs(LOG_LINES) do
        if line:find(pattern) then return true end
    end
    return false
end

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
            -- egg-raft is a known spawner but not stubbed into the world.
            [SpawnRates.SETTING_PREFIX .. "egg-raft"] =
                { value = "small-stomper-pentapod 0.35=0.01" },
        },
    }
    dofile("data-final-fixes.lua")
    assert(some_log("does not exist"), "expected skip log for egg-raft")
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

test("settings: one setting per known spawner plus the extra setting", function()
    data.raw = {}
    local extended = {}
    data.extend = function(_, items)  -- called as data:extend(t)
        for _, item in ipairs(items) do extended[#extended + 1] = item end
    end
    dofile("settings.lua")
    eq(#extended, #SpawnRates.KNOWN_SPAWNERS + 1)
    local defaults_by_name = {}
    for _, known in ipairs(SpawnRates.KNOWN_SPAWNERS) do
        defaults_by_name[SpawnRates.SETTING_PREFIX .. known.name] = known.default
    end
    defaults_by_name[SpawnRates.EXTRA_SETTING_NAME] = ""
    local names = {}
    for _, item in ipairs(extended) do
        names[item.name] = true
        eq(item.setting_type, "startup")
        eq(item.allow_blank, true)
        eq(item.default_value, defaults_by_name[item.name], "default of " .. item.name)
        assert(item.localised_name, "missing label on " .. item.name)
    end
    for name in pairs(defaults_by_name) do
        assert(names[name], "missing setting " .. name)
    end
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

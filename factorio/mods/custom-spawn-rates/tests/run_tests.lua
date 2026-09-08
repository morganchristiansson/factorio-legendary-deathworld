-- Test runner for Custom Spawn Rates. Runs with plain Lua (no Factorio):
--
--   lua5.4 tests/run_tests.lua          all suites (from the mod directory)
--   lua5.4 tests/run_tests.lua spawn   spawn-rate suite only
--   lua5.4 tests/run_tests.lua tech    tech-tree suite only
--
-- Suites live in tests/test_spawn_rates.lua and tests/test_tech_tree.lua
-- and share this file's globals (test, eq, fresh_world, some_log, ...).

local failures = 0
local passed = 0

function eq(actual, expected, message)
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

function test(name, fn)
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
-- Stub data stage environment, load the modules under test.

log = function(msg) LOG_LINES[#LOG_LINES + 1] = msg end
LOG_LINES = {}
data = { raw = {} }

SpawnRates = dofile("lib.lua")
Tech = require("tech")

-- Capture the print() change report alongside log() warnings so
-- some_log() sees both channels.
SpawnRates.report = function(msg) LOG_LINES[#LOG_LINES + 1] = msg end
Tech.report = function(msg) LOG_LINES[#LOG_LINES + 1] = msg end

function make_spawner(units)
    return { result_units = units or {} }
end

function fresh_world()
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

-- True if any accumulated log line matches the pattern.
function some_log(pattern)
    for _, line in ipairs(LOG_LINES) do
        if line:find(pattern) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Suites.

local only = arg and arg[1] or nil
if only == nil or only == "spawn" then
    dofile("tests/test_spawn_rates.lua")
end
if only == nil or only == "tech" then
    dofile("tests/test_tech_tree.lua")
end

-- Cross-feature: settings catalogue shape.
test("settings: one setting per known spawner plus extra and tech", function()
    data.raw = {}
    local extended = {}
    data.extend = function(_, items)  -- called as data:extend(t)
        for _, item in ipairs(items) do extended[#extended + 1] = item end
    end
    dofile("settings.lua")
    eq(#extended, #SpawnRates.KNOWN_SPAWNERS + 2)
    for _, known in ipairs(SpawnRates.KNOWN_SPAWNERS) do
        -- Defaults must stay blank: an SA-only unit name as default
        -- hard-fails map load on base-only installs (assignID error).
        eq(known.default, "", "default of " .. known.name)
    end
    local defaults_by_name = {}
    for _, known in ipairs(SpawnRates.KNOWN_SPAWNERS) do
        defaults_by_name[SpawnRates.SETTING_PREFIX .. known.name] = known.default
    end
    defaults_by_name[SpawnRates.EXTRA_SETTING_NAME] = ""
    defaults_by_name[Tech.TECH_SETTING_NAME] = ""
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

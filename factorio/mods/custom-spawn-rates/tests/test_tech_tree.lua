-- Tech-tree suite (tech surface of lib.lua). Runs through
-- tests/run_tests.lua, which provides the harness globals (test, eq,
-- fresh_world, some_log, Tech).

-- ---------------------------------------------------------------------------
-- Entry parsing errors

test("tech: unknown attribute rejected, supported list shown", function()
    local tech = { unit = { count = 100, time = 30 } }
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "foobar 1")
    assert(some_log("unknown attribute 'foobar'"), all_logs())
    assert(some_log("supported paths"), all_logs())
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "count 300")
    assert(some_log("unknown attribute 'count'"),
        "short 'count' form must fail, got: " .. all_logs())
end)

test("tech: cannot add to scalars, cannot remove from scalars", function()
    local tech = { unit = { count = 100, time = 30 } }
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "+unit.count 3")
    assert(some_log("cannot add"), all_logs())
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "-unit.count 3")
    assert(some_log("cannot remove"), all_logs())
    eq(tech.unit.count, 100)
end)

test("tech: bare effects sets nothing", function()
    local tech = { effects = {} }
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "effects type=unlock-recipe,recipe=x")
    assert(some_log("bad entry") or some_log("use +effects"), all_logs())
end)

-- ---------------------------------------------------------------------------
-- prerequisites

test("tech: prerequisites wholesale replace, bare clears, +/- patch", function()
    local tech = { prerequisites = { "a" } }
    Tech.apply_setting(tech, "t", "prerequisites biter-egg-handling,kovarex-enrichment-process")
    eq(tech.prerequisites, { "biter-egg-handling", "kovarex-enrichment-process" })
    Tech.apply_setting(tech, "t", "prerequisites")
    eq(tech.prerequisites, {})
    Tech.apply_setting(tech, "t", "+prerequisites x; -prerequisites biter-egg-handling")
    eq(tech.prerequisites, { "x" })
end)

test("tech: +prerequisites dedupes, -prerequisites absent logs", function()
    local tech = { prerequisites = { "a", "b" } }
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "+prerequisites a; -prerequisites zzz")
    eq(tech.prerequisites, { "a", "b" })
    assert(some_log("already a,b — no change"), all_logs())
    assert(some_log("not present — nothing to remove"), all_logs())
end)

test("tech: single prerequisite works", function()
    local tech = {}
    Tech.apply_setting(tech, "t", "prerequisites wood")
    eq(tech.prerequisites, { "wood" })
end)

-- ---------------------------------------------------------------------------
-- unit.count / unit.time

test("tech: unit.count and unit.time set; bad values rejected", function()
    local tech = { unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "unit.count 300; unit.time 15")
    eq(tech.unit.count, 300)
    eq(tech.unit.time, 15)
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "unit.count 0")
    assert(some_log("bad entry"), "expected reject, got: " .. all_logs())
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "unit.count abc")
    assert(some_log("bad entry"), "expected reject, got: " .. all_logs())
    eq(tech.unit.count, 300)
end)

test("tech: count/time on a trigger-only tech are skipped", function()
    local trigger_only = { research_trigger = { type = "x" } }
    LOG_LINES = {}
    Tech.apply_setting(trigger_only, "t", "unit.count 300")
    assert(trigger_only.unit == nil, "must not create a unit")
    assert(some_log("does not exist"), "expected skip log, got: " .. all_logs())
end)

-- ---------------------------------------------------------------------------
-- unit (lab cost) and ingredients

test("tech: unit converts a trigger-only tech and clears the trigger", function()
    local tech = { prerequisites = { "concrete" },
        research_trigger = { type = "mine-entity", entity = "copper-stromatolite" } }
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "unit count=500,time=30")
    assert(tech.research_trigger == nil, "trigger must be cleared")
    eq(tech.unit.count, 500)
    eq(tech.unit.time, 30)
    assert(some_log("t%.unit: "), "expected report, got: " .. all_logs())
    assert(some_log("research_trigger cleared"), all_logs())
end)

test("tech: unit keeps existing ingredients, repeat is a no-change", function()
    local tech = { unit = { count = 100, time = 30,
        ingredients = { { "a-pack", 1 } } } }
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "unit count=100,time=30")
    assert(some_log("no change"), all_logs())
    eq(tech.unit.ingredients, { { "a-pack", 1 } })
end)

test("tech: unit.ingredients wholesale set, add merges, remove drops", function()
    local tech = { unit = { count = 10, time = 5,
        ingredients = { { "a-pack", 1 }, { "b-pack", 2 } } } }
    Tech.apply_setting(tech, "t",
        "unit.ingredients automation-science-pack=1,logistic-science-pack=1")
    eq(tech.unit.ingredients, {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 } })
    Tech.apply_setting(tech, "t", "+unit.ingredients c-pack=3,automation-science-pack=5")
    eq(tech.unit.ingredients, {
        { "automation-science-pack", 5 }, { "logistic-science-pack", 1 },
        { "c-pack", 3 } })
    Tech.apply_setting(tech, "t", "-unit.ingredients c-pack,logistic-science-pack")
    eq(tech.unit.ingredients, { { "automation-science-pack", 5 } })
end)

test("tech: ingredients alias and skip without a unit", function()
    local tech = { unit = { count = 10, time = 5,
        ingredients = { { "a-pack", 1 } } } }
    Tech.apply_setting(tech, "t", "ingredients automation-science-pack=2")
    eq(tech.unit.ingredients, { { "automation-science-pack", 2 } })
    local trigger_only = { research_trigger = { type = "x" } }
    LOG_LINES = {}
    Tech.apply_setting(trigger_only, "t", "-unit.ingredients a-pack")
    assert(some_log("does not exist"), "expected skip log, got: " .. all_logs())
end)

-- ---------------------------------------------------------------------------
-- research_trigger

test("tech: research_trigger set clears the unit", function()
    local tech = { unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t",
        "research_trigger type=craft-item,item=iron-plate,count=200")
    assert(tech.unit == nil, "unit must be cleared")
    eq(tech.research_trigger, { type = "craft-item", item = "iron-plate", count = 200 })
end)

test("tech: clearing the trigger needs a unit, clearing the unit needs a trigger", function()
    local trigger_only = { research_trigger = { type = "craft-item" } }
    LOG_LINES = {}
    Tech.apply_setting(trigger_only, "t", "-research_trigger")
    assert(trigger_only.research_trigger ~= nil, "must be skipped, not cleared")
    assert(some_log("neither unit"), "expected skip log, got: " .. all_logs())
    local lab = { unit = { count = 10, time = 5 },
        research_trigger = { type = "craft-item" } }
    Tech.apply_setting(lab, "t", "-research_trigger")
    assert(lab.research_trigger == nil and lab.unit ~= nil)
    local both = { unit = { count = 10, time = 5 },
        research_trigger = { type = "craft-item" } }
    Tech.apply_setting(both, "t", "-unit")
    assert(both.unit == nil and both.research_trigger ~= nil,
        "unit must clear, trigger must survive")
end)

-- ---------------------------------------------------------------------------
-- effects

test("tech: +effects appends bare and braced structs", function()
    local tech = { effects = {} }
    Tech.apply_setting(tech, "t", "+effects type=unlock-recipe,recipe=oil-refinery")
    eq(#tech.effects, 1)
    eq(tech.effects[1].recipe, "oil-refinery")
    Tech.apply_setting(tech, "t",
        "+effects {type=unlock-recipe,recipe=a},{type=unlock-recipe,recipe=b}")
    eq(#tech.effects, 3)
    eq(tech.effects[3].recipe, "b")
end)

test("tech: bad effects entries are skipped", function()
    local tech = { effects = {} }
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "+effects {type=a}; +effects {type=a},type=b")
    assert(some_log("bad entry"), "expected reject, got: " .. all_logs())
    eq(#tech.effects, 1)                     -- first op applied
    eq(tech.effects[1].type, "a")
end)

test("tech: effects appends to a nil effects field", function()
    local tech = {}
    Tech.apply_setting(tech, "t", "+effects {type=unlock-recipe,recipe=iron-chest}")
    eq(#tech.effects, 1)
    eq(tech.effects[1].recipe, "iron-chest")
end)

-- ---------------------------------------------------------------------------
-- Mixed / malformed / sections

test("tech: malformed op skipped, later ops applied", function()
    local tech = { unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "bogus 1; unit.count 300")
    eq(tech.unit.count, 300)
end)

test("tech comments: '#' ignored, ops still apply", function()
    local tech = { unit = { count = 100, time = 30 } }
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "# heading\nunit.count 300 # cheap")
    eq(tech.unit.count, 300)
    eq(#LOG_LINES, 1)
end)

test("data-final-fixes: tech sections reach matching techs", function()
    local spawners = fresh_world()
    data.raw["unit-spawner"] = spawners
    data.raw["technology"] = {
        ["biolab"] = { prerequisites = { "a" } },
        ["transport-belt-capacity-2"] = { unit = { count = 100, time = 30 } },
    }
    settings = {
        startup = {
            [Tech.TECH_SETTING_NAME] = { value =
                "biolab: prerequisites biter-egg-handling,kovarex-enrichment-process" ..
                ";transport-belt-capacity-2: unit.count 300" ..
                ";gone-tech: unit.count 5" },
        },
    }
    dofile("data-final-fixes.lua")
    eq(data.raw["technology"]["biolab"].prerequisites,
        { "biter-egg-handling", "kovarex-enrichment-process" })
    eq(data.raw["technology"]["transport-belt-capacity-2"].unit.count, 300)
    assert(some_log("gone%-tech"), "expected skip log for gone-tech")
end)

test("tech: server Gleba stanzas against vanilla-shaped techs", function()
    LOG_LINES = {}
    local raw = {
        landfill = { prerequisites = { "logistic-science-pack" },
            unit = { count = 50, time = 30, ingredients =
                { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 } } } },
        ["steel-processing"] = { prerequisites = { "automation-science-pack" },
            unit = { count = 50, time = 5, ingredients =
                { { "automation-science-pack", 1 } } } },
        agriculture = { prerequisites = { "planet-discovery-gleba" },
            research_trigger = { type = "mine-entity", entity = "iron-stromatolite" } },
        ["stack-inserter"] = {
            prerequisites = { "carbon-fiber", "production-science-pack",
                "utility-science-pack", "bulk-inserter" },
            unit = { count = 1000, time = 60, ingredients =
                { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
                  { "chemical-science-pack", 1 }, { "production-science-pack", 1 },
                  { "utility-science-pack", 1 }, { "space-science-pack", 1 },
                  { "agricultural-science-pack", 1 } } } },
    }
    local setting = "landfill: prerequisites; research_trigger type=mine-entity,entity=stone" ..
        ";steel-processing: prerequisites; research_trigger type=craft-item,item=iron-plate,count=200" ..
        ";agriculture: prerequisites landfill,steel-processing" ..
        ";stack-inserter: prerequisites carbon-fiber,production-science-pack,bulk-inserter" ..
        "; -unit.ingredients space-science-pack,utility-science-pack; unit.count 100"
    local sections = SpawnRates.sections(setting)
    for name, entry_text in pairs(sections) do
        Tech.apply_setting(raw[name], name, entry_text)
    end
    assert(not some_log("bad entry"), "all stanzas must parse: " .. all_logs())
    assert(raw.landfill.unit == nil, "landfill unit must be cleared")
    eq(raw.landfill.research_trigger.entity, "stone")
    eq(#raw.landfill.prerequisites, 0)
    assert(raw["steel-processing"].unit == nil)
    eq(raw["steel-processing"].research_trigger.count, 200)
    assert(raw.agriculture.research_trigger.entity == "iron-stromatolite")
    eq(raw.agriculture.prerequisites, { "landfill", "steel-processing" })
    eq(raw["stack-inserter"].unit.count, 100)
    local ing = raw["stack-inserter"].unit.ingredients
    local has = {}
    for _, i in ipairs(ing) do has[i[1]] = i[2] end
    assert(has["space-science-pack"] == nil, "space-science-pack removed")
    assert(has["utility-science-pack"] == nil, "utility-science-pack removed")
    eq(#ing, 5)
end)

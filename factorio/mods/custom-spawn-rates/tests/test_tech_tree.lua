-- Tech-tree suite (tech.lua). Runs through tests/run_tests.lua, which
-- provides the harness globals (test, eq, fresh_world, some_log, ...).

test("tech parse_entry: prerequisites wholesale", function()
    local op = Tech.parse_entry("prerequisites biter-egg-handling, kovarex-enrichment-process")
    assert(op and op.kind == "prerequisites", "want prerequisites op")
    eq(#op.list, 2)
    assert(op.list[1] == "biter-egg-handling" and op.list[2] == "kovarex-enrichment-process")
end)

test("tech parse_entry: bare prerequisites clears", function()
    local op = Tech.parse_entry("prerequisites")
    assert(op and op.kind == "prerequisites", "want prerequisites op")
    eq(#op.list, 0)
end)

test("tech parse_entry: +/-prerequisites patch the list", function()
    local add = Tech.parse_entry("+prerequisites foo")
    assert(add.kind == "prereq_add" and add.names[1] == "foo")
    local rem = Tech.parse_entry("-prerequisites foo")
    assert(rem.kind == "prereq_remove" and rem.names[1] == "foo")
    local multi = Tech.parse_entry("-prerequisites foo, bar")
    eq(#multi.names, 2)
    local _, err = Tech.parse_entry("-prerequisites")
    assert(err, "expected error for bare -prerequisites")
    _, err = Tech.parse_entry("prereq foo")
    assert(err and err:find("unknown attribute", 1, true),
        "short form must fail, got: " .. tostring(err))
end)

test("tech parse_entry: unit.count/unit.time", function()
    local c = Tech.parse_entry("unit.count 300")
    assert(c.kind == "count" and c.n == 300, "want unit.count 300")
    local t = Tech.parse_entry("unit.time 30")
    assert(t.kind == "time" and t.n == 30, "want unit.time 30")
    local _, err = Tech.parse_entry("unit.count 0")
    assert(err, "expected error for unit.count 0")
    _, err = Tech.parse_entry("unit.count abc")
    assert(err, "expected error for unit.count abc")
    _, err = Tech.parse_entry("count 300")
    assert(err and err:find("unknown attribute", 1, true),
        "short form must fail, got: " .. tostring(err))
end)

test("tech parse_entry: research_trigger set/clear", function()
    local op = Tech.parse_entry("research_trigger type=craft-item,item=iron-plate,count=200")
    assert(op.kind == "trigger_set", "want trigger_set")
    eq(op.trigger.type, "craft-item")
    eq(op.trigger.item, "iron-plate")
    assert(op.trigger.count == 200, "want numeric count")
    local clear = Tech.parse_entry("-research_trigger")
    assert(clear.kind == "trigger_clear")
    local _, err = Tech.parse_entry("research_trigger item=iron-plate")
    assert(err and err:find("type="), "expected missing type error")
    _, err = Tech.parse_entry("trigger type=craft-item")
    assert(err and err:find("unknown attribute", 1, true),
        "short form must fail, got: " .. tostring(err))
end)

test("tech parse_entry: rejects unknown paths", function()
    local _, err = Tech.parse_entry("foobar 1")
    assert(err and err:find("unknown attribute 'foobar'", 1, true), tostring(err))
    _, err = Tech.parse_entry("-unit.count 3")
    assert(err and err:find("cannot remove"), "expected error for -unit.count")
    _, err = Tech.parse_entry("+unit.count 3")
    assert(err and err:find("cannot add"), "expected error for +unit.count")
    _, err = Tech.parse_entry("effects type=unlock-recipe,recipe=x")
    assert(err and err:find("%+effects"), "bare effects must fail, got: " .. tostring(err))
end)

test("tech parse_entry: ingredients remove/add and effects append", function()
    local rem = Tech.parse_entry("-unit.ingredients space-science-pack")
    assert(rem.kind == "ingredient_remove" and rem.names[1] == "space-science-pack")
    local _, err = Tech.parse_entry("-unit.ingredients")
    assert(err, "expected error for bare -unit.ingredients")
    local adding = Tech.parse_entry("+unit.ingredients space-science-pack=1")
    assert(adding.kind == "ingredient_add")
    assert(adding.list[1].name == "space-science-pack")
    assert(adding.list[1].amount == 1)
    local eff = Tech.parse_entry("+effects type=unlock-recipe,recipe=oil-refinery")
    assert(eff.kind == "effect_add", "want effect_add")
    eq(#eff.effects, 1)
    eq(eff.effects[1].type, "unlock-recipe")
    eq(eff.effects[1].recipe, "oil-refinery")
    local mod = Tech.parse_entry("+effects type=gun-speed,modifier=0.2")
    assert(mod.effects[1].modifier == 0.2, "modifier must be numeric")
    local braced = Tech.parse_entry(
        "+effects {type=unlock-recipe,recipe=a},{type=unlock-recipe,recipe=b}")
    eq(#braced.effects, 2)
    eq(braced.effects[2].recipe, "b")
    local single_braced = Tech.parse_entry("+effects {type=unlock-recipe,recipe=a}")
    eq(#single_braced.effects, 1)
    local _, err = Tech.parse_entry("+effects {type=a},type=b")
    assert(err and err:find("between effect"), "expected mixed-form error, got: " .. tostring(err))
    _, err = Tech.parse_entry("+effects {type=a},{recipe=b}")
    assert(err and err:find("type="), "expected missing-type error, got: " .. tostring(err))
    _, err = Tech.parse_entry("+effects {type=a")
    assert(err, "expected unbalanced-brace error")
    _, err = Tech.parse_entry("research_trigger {type=craft-item}")
    assert(err and err:find("bad trigger pair"), "trigger rejects braces, got: " .. tostring(err))
    _, err = Tech.parse_entry("+effects recipe=x")
    assert(err and err:find("type="), "expected missing type error")
    _, err = Tech.parse_entry("research_trigger type=craft-item,count=abc")
    assert(err and err:find("count"), "expected bad count error")
end)

test("tech apply: ingredient remove and effect add", function()
    LOG_LINES = {}
    local tech = { unit = { count = 10, time = 5,
        ingredients = { { "a-pack", 1 }, { "b-pack", 2 } } }, effects = {} }
    Tech.apply_setting(tech, "t", "-unit.ingredients a-pack")
    eq(#tech.unit.ingredients, 1)
    assert(tech.unit.ingredients[1][1] == "b-pack")
    Tech.apply_setting(tech, "t", "-unit.ingredients gone-pack")
    eq(#tech.unit.ingredients, 1)
    assert(some_log("not present"), "expected no-op log")
    Tech.apply_setting(tech, "t", "+effects type=unlock-recipe,recipe=oil-refinery")
    eq(#tech.effects, 1)
    eq(tech.effects[1].recipe, "oil-refinery")
    Tech.apply_setting(tech, "t",
        "+effects {type=unlock-recipe,recipe=a},{type=unlock-recipe,recipe=b}")
    eq(#tech.effects, 3)
    eq(tech.effects[3].recipe, "b")
    LOG_LINES = {}
    local trigger_only = { research_trigger = { type = "x" } }
    Tech.apply_setting(trigger_only, "t", "-unit.ingredients a-pack")
    assert(some_log("no ingredients"), "expected skip log without unit")
    LOG_LINES = {}
    Tech.apply_setting(tech, "t", "+unit.ingredients c-pack=3,b-pack=5")
    eq(#tech.unit.ingredients, 2)
    assert(tech.unit.ingredients[1][1] == "b-pack"
        and tech.unit.ingredients[1][2] == 5, "amount must merge over b-pack")
    assert(tech.unit.ingredients[2][1] == "c-pack", "c-pack must append")
    assert(some_log("+unit.ingredients"), "expected merge log")
end)

test("tech apply: prerequisites replace, prereq patch", function()
    LOG_LINES = {}
    local tech = { prerequisites = { "a" }, unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "prerequisites b,c")
    assert(tech.prerequisites[1] == "b" and tech.prerequisites[2] == "c")
    Tech.apply_setting(tech, "t", "+prerequisites d; -prerequisites b")
    assert(tech.prerequisites[1] == "c" and tech.prerequisites[2] == "d")
end)

test("tech apply: count/time need a unit", function()
    LOG_LINES = {}
    local tech = { unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "unit.count 300; unit.time 15")
    assert(tech.unit.count == 300 and tech.unit.time == 15)
    local trigger_only = { research_trigger = { type = "x" } }
    Tech.apply_setting(trigger_only, "t", "unit.count 300")
    assert(trigger_only.unit == nil, "must not create a unit")
    assert(some_log("no unit"), "expected skip log")
end)

test("tech apply: trigger set clears unit, clear needs a unit", function()
    LOG_LINES = {}
    local tech = { unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "research_trigger type=craft-item,item=iron-plate,count=200")
    assert(tech.unit == nil, "unit must be cleared")
    assert(tech.research_trigger.type == "craft-item")
    assert(tech.research_trigger.count == 200)
    LOG_LINES = {}
    local trigger_only = { research_trigger = { type = "craft-item" } }
    Tech.apply_setting(trigger_only, "t", "-research_trigger")
    assert(trigger_only.research_trigger ~= nil, "must be skipped, not cleared")
    assert(some_log("neither unit nor trigger"), "expected skip log")
    LOG_LINES = {}
    local lab = { unit = { count = 10, time = 5 }, research_trigger = { type = "craft-item" } }
    Tech.apply_setting(lab, "t", "-research_trigger")
    assert(lab.research_trigger == nil and lab.unit ~= nil)
    LOG_LINES = {}
    local both = { unit = { count = 10, time = 5 }, research_trigger = { type = "craft-item" } }
    Tech.apply_setting(both, "t", "-unit")
    assert(both.unit == nil, "unit must be cleared when a trigger exists")
    assert(both.research_trigger ~= nil, "trigger must survive -unit")
    assert(some_log("unit cleared"), "expected unit-clear log")
end)

test("tech apply: malformed op skipped, later ops applied", function()
    LOG_LINES = {}
    local tech = { unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "bogus 1; unit.count 300")
    assert(tech.unit.count == 300)
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
    assert(data.raw["technology"]["biolab"].prerequisites[1] == "biter-egg-handling")
    assert(data.raw["technology"]["transport-belt-capacity-2"].unit.count == 300)
    assert(some_log('gone%-tech'), "expected skip log for gone-tech")
end)

test("tech comments: '#' ignored, ops still apply", function()
    LOG_LINES = {}
    local tech = { unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "# heading\nunit.count 300 # cheap")
    assert(tech.unit.count == 300)
    eq(#LOG_LINES, 1)
end)

test("tech parse_entry: unit and ingredients", function()
    local u = Tech.parse_entry("unit count=500,time=30")
    assert(u.kind == "unit_set" and u.count == 500 and u.time == 30)
    local t = Tech.parse_entry("unit time=15")
    assert(t.kind == "unit_set" and t.count == nil and t.time == 15)
    local _, err = Tech.parse_entry("unit")
    assert(err, "expected error for bare unit")
    _, err = Tech.parse_entry("unit count=abc")
    assert(err, "expected error for bad count")
    _, err = Tech.parse_entry("unit foo=1")
    assert(err, "expected error for unknown key")
    local ings = Tech.parse_entry(
        "ingredients automation-science-pack=1,logistic-science-pack=2")
    assert(ings.kind == "ingredients_set" and #ings.list == 2)
    assert(ings.list[1].name == "automation-science-pack")
    assert(ings.list[1].amount == 1)
    _, err = Tech.parse_entry("ingredients")
    assert(err, "expected error for bare ingredients")
    _, err = Tech.parse_entry("ingredients automation-science-pack")
    assert(err, "expected error for pack without amount")
end)

test("tech apply: unit converts a trigger-only tech, reports before/after", function()
    LOG_LINES = {}
    local tech = { prerequisites = { "concrete" },
        research_trigger = { type = "mine-entity", entity = "copper-stromatolite" } }
    Tech.apply_setting(tech, "heating-tower", "unit count=500,time=30")
    assert(tech.research_trigger == nil, "trigger must be cleared")
    eq(tech.unit.count, 500)
    eq(tech.unit.time, 30)
    assert(some_log("unit set: "),
        "expected before/after log, got: " .. table.concat(LOG_LINES, " | "))
    assert(some_log("research_trigger cleared"),
        "expected trigger-cleared note")
    LOG_LINES = {}
    Tech.apply_setting(tech, "heating-tower",
        "unit.ingredients automation-science-pack=1,logistic-science-pack=1")
    eq(#tech.unit.ingredients, 2)
    assert(tech.unit.ingredients[1][1] == "automation-science-pack")
    assert(tech.unit.ingredients[2][2] == 1)
    assert(some_log("unit.ingredients set: "),
        "expected before/after log, got: " .. table.concat(LOG_LINES, " | "))
    LOG_LINES = {}
    Tech.apply_setting(tech, "heating-tower",
        "unit count=500,time=30; unit.ingredients automation-science-pack=1,logistic-science-pack=1")
    eq(#LOG_LINES, 2)
    assert(some_log("unit already "), "expected unit no-op log")
    assert(some_log("unit.ingredients already "), "expected ingredients no-op log")
    LOG_LINES = {}
    local labless = { research_trigger = { type = "x" } }
    Tech.apply_setting(labless, "t", "unit.ingredients automation-science-pack=1")
    assert(some_log("no unit to set ingredients on"), "expected skip log")
end)

test("tech apply: unchanged ops log no-op", function()
    LOG_LINES = {}
    local tech = { prerequisites = { "a", "b" },
        unit = { count = 100, time = 30, ingredients = { { "a-pack", 1 } } } }
    Tech.apply_setting(tech, "t",
        "prerequisites a,b; unit.count 100; unit.time 30; +prerequisites a; -prerequisites zzz")
    eq(#LOG_LINES, 5)
    assert(some_log("prerequisites already "), "expected prereq no-op")
    assert(some_log("unit.count already "), "expected count no-op")
    assert(some_log("unit.time already "), "expected time no-op")
    assert(some_log("already present"), "expected prereq-add no-op")
    assert(some_log("nothing to remove"), "expected prereq-remove no-op")
end)

test("tech apply: server Gleba stanzas against vanilla-shaped techs", function()
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
    local sections = SpawnRates.parse_overrides(setting)
    for name, entry_text in pairs(sections) do
        Tech.apply_setting(raw[name], name, entry_text)
    end
    assert(not some_log("bad entry"), "all stanzas must parse")
    assert(raw.landfill.unit == nil, "landfill unit must be cleared")
    assert(raw.landfill.research_trigger.entity == "stone")
    eq(#raw.landfill.prerequisites, 0)
    assert(raw["steel-processing"].unit == nil)
    assert(raw["steel-processing"].research_trigger.count == 200)
    assert(raw.agriculture.research_trigger.entity == "iron-stromatolite",
        "agriculture keeps its trigger")
    assert(raw.agriculture.prerequisites[1] == "landfill")
    eq(raw["stack-inserter"].unit.count, 100)
    eq(#raw["stack-inserter"].unit.ingredients, 5)
    eq(#LOG_LINES, 8)
end)

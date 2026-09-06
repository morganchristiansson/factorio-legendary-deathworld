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

test("tech parse_entry: prereq add/remove", function()
    local add = Tech.parse_entry("prereq foo")
    assert(add.kind == "prereq_add" and add.names[1] == "foo")
    local rem = Tech.parse_entry("-prereq foo")
    assert(rem.kind == "prereq_remove" and rem.names[1] == "foo")
    local multi = Tech.parse_entry("-prereq foo, bar")
    eq(#multi.names, 2)
    local _, err = Tech.parse_entry("-prereq")
    assert(err, "expected error for bare -prereq")
end)

test("tech parse_entry: count/time", function()
    local c = Tech.parse_entry("count 300")
    assert(c.kind == "count" and c.n == 300, "want count 300")
    local t = Tech.parse_entry("time 30")
    assert(t.kind == "time" and t.n == 30, "want time 30")
    local _, err = Tech.parse_entry("count 0")
    assert(err, "expected error for count 0")
    _, err = Tech.parse_entry("count abc")
    assert(err, "expected error for count abc")
end)

test("tech parse_entry: trigger set/clear", function()
    local op = Tech.parse_entry("trigger type=craft-item,item=iron-plate,count=200")
    assert(op.kind == "trigger_set", "want trigger_set")
    eq(op.trigger.type, "craft-item")
    eq(op.trigger.item, "iron-plate")
    assert(op.trigger.count == 200, "want numeric count")
    local clear = Tech.parse_entry("-trigger")
    assert(clear.kind == "trigger_clear")
    local _, err = Tech.parse_entry("trigger item=iron-plate")
    assert(err and err:find("type="), "expected missing type error")
end)

test("tech parse_entry: rejects unknown field", function()
    local _, err = Tech.parse_entry("foobar 1")
    assert(err and err:find("unknown field"), tostring(err))
    _, err = Tech.parse_entry("-count 3")
    assert(err, "expected error for -count")
end)

test("tech parse_entry: ingredient remove and effect add", function()
    local rem = Tech.parse_entry("-ingredient space-science-pack")
    assert(rem.kind == "ingredient_remove" and rem.names[1] == "space-science-pack")
    local _, err = Tech.parse_entry("-ingredient")
    assert(err, "expected error for bare -ingredient")
    local add = Tech.parse_entry("effect type=unlock-recipe,recipe=oil-refinery")
    assert(add.kind == "effect_add", "want effect_add")
    eq(#add.effects, 1)
    eq(add.effects[1].type, "unlock-recipe")
    eq(add.effects[1].recipe, "oil-refinery")
    local mod = Tech.parse_entry("effect type=gun-speed,modifier=0.2")
    assert(mod.effects[1].modifier == 0.2, "modifier must be numeric")
    local braced = Tech.parse_entry(
        "effect {type=unlock-recipe,recipe=a},{type=unlock-recipe,recipe=b}")
    eq(#braced.effects, 2)
    eq(braced.effects[2].recipe, "b")
    local single_braced = Tech.parse_entry("effect {type=unlock-recipe,recipe=a}")
    eq(#single_braced.effects, 1)
    local _, err = Tech.parse_entry("effect {type=a},type=b")
    assert(err and err:find("between effect"), "expected mixed-form error, got: " .. tostring(err))
    _, err = Tech.parse_entry("effect {type=a},{recipe=b}")
    assert(err and err:find("type="), "expected missing-type error, got: " .. tostring(err))
    _, err = Tech.parse_entry("effect {type=a")
    assert(err, "expected unbalanced-brace error")
    _, err = Tech.parse_entry("trigger {type=craft-item}")
    assert(err and err:find("bad trigger pair"), "trigger rejects braces, got: " .. tostring(err))
    _, err = Tech.parse_entry("effect recipe=x")
    assert(err and err:find("type="), "expected missing type error")
    _, err = Tech.parse_entry("trigger type=craft-item,count=abc")
    assert(err and err:find("count"), "expected bad count error")
end)

test("tech apply: ingredient remove and effect add", function()
    LOG_LINES = {}
    local tech = { unit = { count = 10, time = 5,
        ingredients = { { "a-pack", 1 }, { "b-pack", 2 } } }, effects = {} }
    Tech.apply_setting(tech, "t", "-ingredient a-pack")
    eq(#tech.unit.ingredients, 1)
    assert(tech.unit.ingredients[1][1] == "b-pack")
    Tech.apply_setting(tech, "t", "-ingredient gone-pack")
    eq(#tech.unit.ingredients, 1)
    assert(some_log("not present"), "expected no-op log")
    Tech.apply_setting(tech, "t", "effect type=unlock-recipe,recipe=oil-refinery")
    eq(#tech.effects, 1)
    eq(tech.effects[1].recipe, "oil-refinery")
    Tech.apply_setting(tech, "t",
        "effect {type=unlock-recipe,recipe=a},{type=unlock-recipe,recipe=b}")
    eq(#tech.effects, 3)
    eq(tech.effects[3].recipe, "b")
    LOG_LINES = {}
    local trigger_only = { research_trigger = { type = "x" } }
    Tech.apply_setting(trigger_only, "t", "-ingredient a-pack")
    assert(some_log("no ingredients"), "expected skip log without unit")
end)

test("tech apply: prerequisites replace, prereq patch", function()
    LOG_LINES = {}
    local tech = { prerequisites = { "a" }, unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "prerequisites b,c")
    assert(tech.prerequisites[1] == "b" and tech.prerequisites[2] == "c")
    Tech.apply_setting(tech, "t", "prereq d; -prereq b")
    assert(tech.prerequisites[1] == "c" and tech.prerequisites[2] == "d")
end)

test("tech apply: count/time need a unit", function()
    LOG_LINES = {}
    local tech = { unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "count 300; time 15")
    assert(tech.unit.count == 300 and tech.unit.time == 15)
    local trigger_only = { research_trigger = { type = "x" } }
    Tech.apply_setting(trigger_only, "t", "count 300")
    assert(trigger_only.unit == nil, "must not create a unit")
    assert(some_log("no unit"), "expected skip log")
end)

test("tech apply: trigger set clears unit, clear needs a unit", function()
    LOG_LINES = {}
    local tech = { unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "trigger type=craft-item,item=iron-plate,count=200")
    assert(tech.unit == nil, "unit must be cleared")
    assert(tech.research_trigger.type == "craft-item")
    assert(tech.research_trigger.count == 200)
    LOG_LINES = {}
    local trigger_only = { research_trigger = { type = "craft-item" } }
    Tech.apply_setting(trigger_only, "t", "-trigger")
    assert(trigger_only.research_trigger ~= nil, "must be skipped, not cleared")
    assert(some_log("neither unit nor trigger"), "expected skip log")
    LOG_LINES = {}
    local lab = { unit = { count = 10, time = 5 }, research_trigger = { type = "craft-item" } }
    Tech.apply_setting(lab, "t", "-trigger")
    assert(lab.research_trigger == nil and lab.unit ~= nil)
end)

test("tech apply: malformed op skipped, later ops applied", function()
    LOG_LINES = {}
    local tech = { unit = { count = 100, time = 30 } }
    Tech.apply_setting(tech, "t", "bogus 1; count 300")
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
                ";transport-belt-capacity-2: count 300" ..
                ";gone-tech: count 5" },
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
    Tech.apply_setting(tech, "t", "# heading\ncount 300 # cheap")
    assert(tech.unit.count == 300)
    eq(#LOG_LINES, 1)
end)

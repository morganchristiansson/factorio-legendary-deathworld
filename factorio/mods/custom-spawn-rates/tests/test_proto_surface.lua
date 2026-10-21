-- Prototype suite (generic data.raw surface of lib.lua). Runs through
-- tests/run_tests.lua, which provides the harness globals (test, eq,
-- some_log, Proto).

-- Prototypes for the surface to look attributes up in. The section header
-- is the prototype's path in data.raw ('item.ice').
data.raw["item"] = {
    ["iron-plate"] = { type = "item", name = "iron-plate",
                       stack_size = 100 },
    ["coal"] = { type = "item", name = "coal", stack_size = 50,
                 fuel_value = "1MJ" },
    ["ice"] = { type = "item", name = "ice", stack_size = 50 },
    ["nutrients"] = { type = "item", name = "nutrients", stack_size = 1,
                      spoil_ticks = 18000, spoil_result = "spoilage" },
}
data.raw["recipe"] = {
    ["iron-plate"] = { type = "recipe", name = "iron-plate" },
}

-- ---------------------------------------------------------------------------
-- Lookup

test("proto: a path finds the prototype in data.raw", function()
    eq(Proto.find("item.ice").name, "ice")
    eq(Proto.find("item.nutrients").name, "nutrients")
    eq(Proto.find("recipe.iron-plate").type, "recipe")
    eq(Proto.find("item.no-such-item"), nil)
    eq(Proto.find("no-such-type.ice"), nil)
    eq(Proto.find("ice"), nil, "a bare name is not a path")
end)

-- ---------------------------------------------------------------------------
-- Durations

test("proto: durations become tick counts", function()
    local ice = { type = "item", name = "ice" }
    Proto.apply_setting(ice, "item.ice", "spoil_ticks 10m")
    eq(ice.spoil_ticks, 36000, "10m")
    Proto.apply_setting(ice, "item.ice", "spoil_ticks 30s")
    eq(ice.spoil_ticks, 1800, "30s")
    Proto.apply_setting(ice, "item.ice", "spoil_ticks 2h")
    eq(ice.spoil_ticks, 432000, "2h")
    Proto.apply_setting(ice, "item.ice", "spoil_ticks 1d")
    eq(ice.spoil_ticks, 5184000, "1d")
end)

test("proto: plain numbers stay tick counts", function()
    local ice = { type = "item", name = "ice" }
    Proto.apply_setting(ice, "item.ice", "spoil_ticks 36000")
    eq(ice.spoil_ticks, 36000)
end)

test("proto: a duration on a non-tick attribute is not a duration", function()
    -- 'stack_size' is a count, not a tick count: '10m' must not become
    -- 36000.
    local iron = { type = "item", name = "iron-plate", stack_size = 100 }
    LOG_LINES = {}
    Proto.apply_setting(iron, "item.iron-plate", "stack_size 10m")
    assert(some_log("bad entry"), all_logs())
    eq(iron.stack_size, 100, "stack_size must be untouched")
end)

-- ---------------------------------------------------------------------------
-- Spoiling

test("proto: spoil_ticks sets only the tick count", function()
    local item = { type = "item", name = "x", spoil_ticks = 100,
                     spoil_result = "copper-ore" }
    Proto.apply_setting(item, "item.x", "spoil_ticks 3600")
    eq(item.spoil_ticks, 3600)
    -- The whole point: setting the timer must not touch the result.
    eq(item.spoil_result, "copper-ore", "spoil_result must survive")
end)

test("proto: spoil_result sets a name, -spoil_result clears it", function()
    local item = { type = "item", name = "x", spoil_result = "copper-ore" }
    Proto.apply_setting(item, "item.x", "spoil_result iron-ore")
    eq(item.spoil_result, "iron-ore")
    Proto.apply_setting(item, "item.x", "-spoil_result")
    eq(item.spoil_result, nil, "cleared")
end)

test("proto: spoiling into nothing needs no spoil_result", function()
    -- An item with spoil_ticks and no spoil_result is destroyed when it
    -- spoils; the setting must not invent a result.
    local ice = { type = "item", name = "ice" }
    Proto.apply_setting(ice, "item.ice", "spoil_ticks 10m")
    eq(ice.spoil_ticks, 36000)
    eq(ice.spoil_result, nil, "no spoil_result must be added")
end)

test("proto: a name field is written as a name, not a list", function()
    -- 'spoil_result' holds one item name. The target carries no such
    -- field, so the shape comes from a sibling prototype that has one.
    local ice = { type = "item", name = "ice" }
    Proto.apply_setting(ice, "item.ice", "spoil_result copper-ore")
    eq(ice.spoil_result, "copper-ore")
end)

-- ---------------------------------------------------------------------------
-- Guard rails

test("proto: a base-only install has no spoiling attributes", function()
    -- Without Space Age no item carries spoil_ticks, so the attribute is
    -- unknown and the op is rejected -- which is what keeps a base-only
    -- map loadable.
    local saved = data.raw
    data.raw = { item = { ["iron-plate"] = { type = "item",
                                               name = "iron-plate",
                                               stack_size = 100 } } }
    local iron = data.raw.item["iron-plate"]
    LOG_LINES = {}
    Proto.apply_setting(iron, "item.iron-plate", "spoil_ticks 10m")
    assert(some_log("unknown attribute 'spoil_ticks'"), all_logs())
    eq(iron.spoil_ticks, nil)
    data.raw = saved
end)

test("proto: unknown attribute is rejected", function()
    -- Factorio ignores unknown properties on a prototype, so a typo would
    -- silently do nothing; the surface must reject it.
    local iron = { type = "item", name = "iron-plate", stack_size = 100 }
    LOG_LINES = {}
    Proto.apply_setting(iron, "item.iron-plate", "stack_siz 200")
    assert(some_log("unknown attribute 'stack_siz'"), all_logs())
    eq(iron.stack_size, 100, "stack_size must be untouched")
end)

test("proto: a typo in a spoiling attribute is rejected", function()
    -- 'spoil_tick' is not a thing; the spoil_* shortcut must not let a
    -- typo through.
    local ice = { type = "item", name = "ice" }
    LOG_LINES = {}
    Proto.apply_setting(ice, "item.ice", "spoil_tick 10m")
    assert(some_log("unknown attribute 'spoil_tick'"), all_logs())
    eq(ice.spoil_tick, nil)
end)

test("proto: the prototype's identity cannot be set", function()
    -- Writing 'type' or 'name' fails the whole map load, not just the
    -- one prototype, so the surface refuses it.
    local ice = { type = "item", name = "ice", stack_size = 50 }
    LOG_LINES = {}
    Proto.apply_setting(ice, "item.ice", "type not-a-type")
    assert(some_log("cannot be set"), all_logs())
    eq(ice.type, "item", "type must be untouched")
    LOG_LINES = {}
    Proto.apply_setting(ice, "item.ice", "name not-ice")
    assert(some_log("cannot be set"), all_logs())
    eq(ice.name, "ice", "name must be untouched")
end)

test("proto: a string attribute of the prototype is settable", function()
    -- A live string field (fuel_value) is replaced, not turned into a
    -- list: the engine shapes the value to the field it finds.
    local coal = { type = "item", name = "coal", fuel_value = "1MJ" }
    Proto.apply_setting(coal, "item.coal", "fuel_value 5MJ")
    eq(coal.fuel_value, "5MJ")
end)

test("proto: an attribute of another type is rejected", function()
    -- 'ammo_category' belongs to ammo prototypes; on an item the engine
    -- ignores it, so the surface must not accept it either.
    data.raw["ammo"] = {
        ["fire-arm-magazine"] = { type = "ammo", name = "fire-arm-magazine",
                                  stack_size = 1, ammo_category = "ammo" },
    }
    local iron = { type = "item", name = "iron-plate", stack_size = 100 }
    LOG_LINES = {}
    Proto.apply_setting(iron, "item.iron-plate", "ammo_category ammo")
    assert(some_log("unknown attribute 'ammo_category'"), all_logs())
    eq(iron.ammo_category, nil)
    data.raw["ammo"] = nil
end)

test("proto: a list field is addressed by path", function()
    -- The modded-nest case: a unit's rate table in a nest's result_units.
    -- The generic path reaches it without a special alias.
    local nest = { type = "unit-spawner", name = "mod-nest",
                   result_units = { { "small-biter", { { 0.1, 0.5 } } } } }
    Proto.apply_setting(nest, "unit-spawner.mod-nest",
                        "result_units.small-biter 0.1=0.9")
    eq(nest.result_units[1][2], { { 0.1, 0.9 } })
end)

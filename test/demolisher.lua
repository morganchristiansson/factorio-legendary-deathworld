-- Run: lua5.4 test/demolisher.lua  (from the repository root)
--
-- Exercises the evolution-milestone demolisher attacks against engine stubs:
-- one spawn per milestone (0.7 small, 0.8 medium, 0.9 big, 0.95 behemoth),
-- taken from the nearest territory that still has a live demolisher, and
-- guarding a reused territory around spawn so the engine walks the unit home
-- onto the base. Guards the wiring this file exists to prevent -- a milestone
-- firing twice, spawning into cleared ground, or erroring when the
-- behemoth-enemies mod (and its prototype) is absent.
local failures = 0
local function check(what, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", what, tostring(got), tostring(want)))
    end
end

-- Engine stubs -------------------------------------------------------------
local stub_evo = 0
local nth_tick_handlers = {}
local event_handlers = {}
local printed = {}
local logged = {}
local spawns = {}
local created_territories = 0

_G.defines = {
    events = {
        on_entity_died = 1, on_post_entity_died = 2, on_player_used_capsule = 3,
        on_player_created = 4, on_player_respawned = 5, on_player_died = 6,
        on_chunk_generated = 7, on_research_finished = 8,
        on_unit_group_finished_gathering = 9, on_space_platform_changed_state = 10,
        on_player_flushed_fluid = 11, on_console_chat = 12,
    },
    command = {compound = 1, build_base = 2, go_to_location = 3, attack_area = 4},
    compound_command = {return_last = 1},
    distraction = {by_anything = 1, none = 2},
}
_G.storage = {}
_G.log = function(line) logged[#logged + 1] = tostring(line) end
_G.script = {
    on_nth_tick = function(tick, handler) nth_tick_handlers[tick] = handler end,
    on_event = function(event, handler) event_handlers[event] = handler end,
    set_event_filter = function() end,
    active_mods = {},
}
_G.prototypes = {
    entity = {
        ["spitter-spawner"] = {result_units = {}},
        ["small-demolisher"] = {localised_name = "small demolisher"},
        ["medium-demolisher"] = {localised_name = "medium demolisher"},
        ["big-demolisher"] = {localised_name = "big demolisher"},
    },
}

local home_territory = {valid = true}
local home_lookup = nil
-- A live territory far away and a cleared one right next to spawn, cleared
-- listed first: the spawn must come from the live ground regardless of order.
local function make_territory(chunks, live)
    local units = live and {{valid = true}} or {}
    local territory = {valid = true}
    function territory.get_segmented_units() return units end
    function territory.get_chunks()
        local out = {}
        for _, c in ipairs(chunks) do
            out[#out + 1] = {x = c[1], y = c[2], area = true}
        end
        return out
    end
    return territory
end
local territories = {
    make_territory({{0, 1}}, false),
    make_territory({{10, 5}, {11, 5}}, true),
}

local surface = {name = "nauvis1"}
function surface.get_territories() return territories end
function surface.get_territory_for_chunk(chunk)
    home_lookup = chunk
    return home_territory
end
function surface.is_chunk_generated() return true end
function surface.create_territory(params)
    created_territories = created_territories + 1
    home_territory = {valid = true, params = params}
    return home_territory
end
function surface.create_segmented_unit(params)
    spawns[#spawns + 1] = params
    return {valid = true}
end

_G.game = {
    tick = 0,
    forces = {
        enemy = {get_evolution_factor = function() return stub_evo end},
        player = {
            technologies = setmetatable({}, {__index = function() return {researched = false} end}),
            recipes = {},
            set_turret_attack_modifier = function() end,
            set_gun_speed_modifier = function() end,
            get_spawn_position = function() return {x = 0, y = 0} end,
        },
    },
    map_settings = {
        pollution = {}, enemy_evolution = {},
        enemy_expansion = {settler_group_min_size = 8, settler_group_max_size = 9},
        asteroids = {},
    },
    print = function(message) printed[#printed + 1] = message end,
    connected_players = {},
}

package.preload["util"] = function()
    return {insert_safe = function() end, copy = function(t) return t end}
end
package.preload["reset"] = function()
    return {
        current_surface = function() return surface end,
        apex_filter = function() return {} end,
        is_swap_surface = function() return true end,
        check_defeat_cancel = function() end,
    }
end
package.preload["jail"] = function()
    return {is_jailed = function() return false end}
end
package.preload["register"] = function()
    return {
        nth_tick = function() end,
        on_tick = function() end,
        arm = function() end,
        disarm = function() end,
        set_filter = function() end,
    }
end

require("factorio/scenarios/Legendary Deathworld/freeplay")
local minute_tick = nth_tick_handlers[3600]
check("minute driver registered", minute_tick ~= nil, true)

local function run_minute() minute_tick() end
local function last_print() return printed[#printed] end

-- Below the first milestone: nothing fires.
stub_evo = 0.65
run_minute()
check("no spawn below 0.7", #spawns, 0)

-- 0.7: one small demolisher, from the live territory's chunk nearest spawn
-- (chunk {10,5} centres on tile 336,176), guarding the spawn territory.
stub_evo = 0.7
run_minute()
check("one spawn at 0.7", #spawns, 1)
check("0.7 spawns small", spawns[1].name, "small-demolisher")
check("legendary quality", spawns[1].quality, "legendary")
check("guards the spawn territory", spawns[1].territory, home_territory)
check("home looked up at {0,0}", home_lookup[1], 0)
check("home looked up at {0,0} y", home_lookup[2], 0)
check("spawned on the live ground", spawns[1].position.x, 10 * 32 + 16)
check("spawned on the live ground y", spawns[1].position.y, 5 * 32 + 16)
check("announced as demo attack", last_print()[2][1], "ld-demo-attack")

-- Same evolution again: the milestone does not refire.
run_minute()
check("no second spawn at same evo", #spawns, 1)

-- 0.8 and 0.9 fire once each as evolution climbs.
stub_evo = 0.8
run_minute()
check("0.8 spawns medium", spawns[2].name, "medium-demolisher")
stub_evo = 0.9
run_minute()
check("0.9 spawns big", spawns[3].name, "big-demolisher")
check("spawn territory reused, not rebuilt", created_territories, 0)

-- 0.95 without the behemoth-enemies mod: the milestone lands, nothing spawns.
stub_evo = 0.95
run_minute()
check("no behemoth spawn without the prototype", #spawns, 3)

-- Mid-round save/load: the stage memory survives in storage, so replaying
-- 0.95 with the mod present still spawns exactly once.
prototypes.entity["behemoth-demolisher"] = {localised_name = "behemoth demolisher"}
storage.evo_stage = 6
run_minute()
check("behemoth spawns with the prototype", spawns[4].name, "behemoth-demolisher")
run_minute()
check("behemoth fires once", #spawns, 4)

-- Everything cleared: the furthest wilderness is re-infested, never the
-- ground beside the base. No spawn territory exists yet either, so the home
-- ground is cut around chunk {0,0} first.
territories = {
    make_territory({{15, 0}}, false),
    make_territory({{46, 0}}, false),
}
home_territory = nil
storage.evo_stage = 2
stub_evo = 0.7
run_minute()
check("fallback re-infests the furthest ground", spawns[5].position.x, 46 * 32 + 16)
check("fallback cuts the spawn territory", created_territories, 1)
check("fallback covers 16 chunks", #home_territory.params.chunks, 16)
check("fallback centres on chunk {0,0}", home_territory.params.chunks[11][1], 0)
check("fallback spawn guards it", spawns[5].territory, home_territory)

print(failures == 0 and "ok" or (failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)

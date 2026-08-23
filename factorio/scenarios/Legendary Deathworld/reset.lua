-- Map reset and staged map reveal.
-----------------------------------------------------------------------
-- reset() wipes and regenerates the map with a fresh seed; control.lua's
-- /reset command calls it as a global. The staged reveal replaces the old
-- behaviour of generating + charting ~1500 chunks in a single tick, which
-- froze the server for seconds after every reset.
-----------------------------------------------------------------------
-- Public interface:
--   Public.setup_starting_area(surf)- reveal + crash site + spawn defences

local util = require("util")
local crash_site = require("crash-site")

local Public = {}

-----------------------------------------------------------------------
local change_seed = function()
    local rng = math.random(1111, 4294967295)
    local mgs = game.surfaces["nauvis"].map_gen_settings
    mgs.seed = rng
    game.surfaces["nauvis"].map_gen_settings = mgs
    if game.surfaces["vulcanus"] ~= nil then
    local mgs = game.surfaces["vulcanus"].map_gen_settings
    mgs.seed = rng
    game.surfaces["vulcanus"].map_gen_settings = mgs
    end
    if game.surfaces["gleba"] ~= nil then
    local mgs = game.surfaces["gleba"].map_gen_settings
    mgs.seed = rng
    game.surfaces["gleba"].map_gen_settings = mgs
    end
    if game.surfaces["fulgora"] ~= nil then
    local mgs = game.surfaces["fulgora"].map_gen_settings
    mgs.seed = rng
    game.surfaces["fulgora"].map_gen_settings = mgs
    end
    if game.surfaces["aquilo"] ~= nil then
    local mgs = game.surfaces["aquilo"].map_gen_settings
    mgs.seed = rng
    game.surfaces["aquilo"].map_gen_settings = mgs
    end
end

-----------------------------------------------------------------------
-- Staged map reveal: force-generate a small core area instantly (ground for
-- crash site / turret), then force-generate fixed-size batches of chunks per
-- tick in centre-out order via on_tick_reveal below, and chart everything
-- once at the end.
-----------------------------------------------------------------------
local REVEAL_CORE_RADIUS = 4
local REVEAL_MAX_RADIUS = 19

-- Chunk coords ordered centre-out (complete square rings), addressed
-- individually via radius-0 requests because the engine's radius form of
-- request_to_generate_chunks is biased down-right.
local reveal_order = {}
local reveal_order_radius = {}
for r = REVEAL_CORE_RADIUS + 1, REVEAL_MAX_RADIUS do
    for cy = -r, r do
        for cx = -r, r do
            if math.max(math.abs(cx), math.abs(cy)) == r then
                table.insert(reveal_order, {cx, cy})
                table.insert(reveal_order_radius, r)
            end
        end
    end
end

-- Chunks force-generated per tick. Higher = faster reveal, bigger stutter.
-- Measured ~3.7ms per chunk: 100 -> ~370ms spikes, ~3.5s total reveal.
local REVEAL_CHUNKS_PER_TICK = 100

local on_tick_reveal = function()
    local surface = game.surfaces[1]
    local index = storage.reveal_index
    local limit = math.min(index + REVEAL_CHUNKS_PER_TICK - 1, #reveal_order)
    for i = index, limit do
        local c = reveal_order[i]
        -- chunk corner position maps exactly onto the chunk we want
        surface.request_to_generate_chunks({c[1] * 32, c[2] * 32}, 0)
    end
    -- Force THIS batch out of the engine immediately so the map reveal tracks
    -- generation.
    surface.force_generate_chunk_requests()
    -- Chart everything generated so far. Batches fill complete rings, so the
    -- generated region is always a centred square of known radius: one chart
    -- call per tick keeps the map reveal locked to generation.
    local r = reveal_order_radius[limit] * 32
    game.forces["player"].chart(surface, {{-r, -r}, {r + 32, r + 32}})
    index = limit + 1
    if index > #reveal_order then
        -- All batches generated and charted: final safety sweep, then stop.
        game.forces["player"].chart_all("nauvis")
        storage.reveal_index = nil
        script.on_event(defines.events.on_tick, nil)
    else
        storage.reveal_index = index
    end
end

local start_map_reveal = function(surface)
    -- Force-generate the core chunk area synchronously (ground for the crash
    -- site and turret must exist this tick), then arm the tick handler that
    -- reveals the rest of the map in batches.
    surface.request_to_generate_chunks({0, 0}, REVEAL_CORE_RADIUS)
    surface.force_generate_chunk_requests()
    -- Chart the core right away: its neighbours are ring 5, which the first
    -- batch force-generates next tick anyway, so this schedules no extra work.
    local core_tiles = REVEAL_CORE_RADIUS * 32
    game.forces["player"].chart(surface, {{-core_tiles, -core_tiles}, {core_tiles, core_tiles}})
    storage.reveal_index = 1
    script.on_event(defines.events.on_tick, on_tick_reveal)
end


-----------------------------------------------------------------------
-- Crash site loot: what the fresh round gives the player.
local ship_items = function()
  return
  {
    ["stone-wall"] = 100,
    ["burner-mining-drill"] = 10,
    ["stone-furnace"] = 10
  }
end

local debris_items = function()
  return
  {
    ["iron-plate"] = 8,
    ["wood"] = 4
  }
end

local ship_parts = function()
  return crash_site.default_ship_parts()
end

local ensure_crash_loot = function()
    storage.crashed_ship_items = storage.crashed_ship_items or ship_items()
    storage.crashed_debris_items = storage.crashed_debris_items or debris_items()
    storage.crashed_ship_parts = storage.crashed_ship_parts or ship_parts()
end

-----------------------------------------------------------------------
local place_turret_at_spawn = function()
        local turret = game.surfaces[1].create_entity{name="gun-turret",position={-7,2},force="player", quality = "legendary"}
        turret.insert{name="firearm-magazine",count=100,quality="legendary"}
        local wall = game.surfaces[1].create_entity
        wall{name="stone-wall",position={-9,0},force="player"}
        wall{name="stone-wall",position={-8,0},force="player"}
        wall{name="stone-wall",position={-7,0},force="player"}
        wall{name="stone-wall",position={-6,0},force="player"}
        wall{name="stone-wall",position={-6,1},force="player"}
        wall{name="stone-wall",position={-6,2},force="player"}
        wall{name="stone-wall",position={-6,3},force="player"}
        wall{name="stone-wall",position={-7,3},force="player"}
        wall{name="stone-wall",position={-8,3},force="player"}
        wall{name="stone-wall",position={-9,3},force="player"}
        wall{name="stone-wall",position={-9,2},force="player"}
        wall{name="stone-wall",position={-9,1},force="player"}
end

local on_pre_surface_cleared = function(event)
    if event.surface_index == 1 then
    -- We need to kill all players _before_ the surface is cleared, so that
    -- their inventory, and crafting queue, end up on the old surface
    for _, pl in pairs(game.players) do
        if pl.connected and pl.character ~= nil then
            -- We call die() here because otherwise we will spawn a duplicate
            -- character, who will carry over into the new surface
            pl.character.die()
        end
        -- Setting [ticks_to_respawn] to 1 seems to consistantly kill offline
        -- players. Calling this for online players will cause them instead be
        -- respawned the next tick, skipping the 10 respawn second timer.
        pl.ticks_to_respawn = 1
        --  Need to teleport otherwise offline players will force generate many chunks on new surface at their position on old surface when they rejoin.
        pl.teleport({0,0}, "nauvis")
    end
    end
end

local on_surface_cleared = function(event)
    if event.surface_index == 1 then
    storage.nesting_spot = {{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0}}
    storage.quality = "legendary"
    storage.recently_reset = "true"
    storage.strafer = "behemoth-spitter"
    storage.stomper = "behemoth-spitter"
    storage.victory = false
    game.map_settings.enemy_expansion.settler_group_min_size = 8
    game.map_settings.enemy_expansion.settler_group_max_size = 9
    game.map_settings.pollution.enemy_attack_pollution_consumption_modifier = 1
    game.map_settings.enemy_evolution.time_factor = 0.00004
    game.forces["player"].reset()
    game.forces["enemy"].reset()
    game.forces["enemy"].reset_evolution()
    game.reset_game_state()
    game.reset_time_played()
    game.get_pollution_statistics("nauvis").clear()
    if game.surfaces["gleba"] ~= nil then
    game.get_pollution_statistics("gleba").clear()
    end
    if math.random(1,10) == 1 then
        --pitch black nights
        game.surfaces[1].daytime_parameters = {dawn = 0.95, dusk = 0.05, evening = 0.15, morning = 0.85}
        game.surfaces[1].brightness_visual_weights = { 1, 1, 1 }
        game.surfaces[1].min_brightness = 0
        game.surfaces[1].daytime = 0.84
    else
        --default nights
        game.surfaces[1].daytime_parameters = {dawn = 0.75, dusk = 0.25, evening = 0.45, morning = 0.55}
        game.surfaces[1].brightness_visual_weights = { 0, 0, 0 }
        game.surfaces[1].min_brightness = 0.15
        game.surfaces[1].daytime = 0.75
    end
    end
end

local create_crash_site = function(surface)
    crash_site.create_crash_site(surface, {-5,-6}, util.copy(storage.crashed_ship_items), util.copy(storage.crashed_debris_items), util.copy(storage.crashed_ship_parts))
end

-- Everything a fresh round needs at spawn (fresh save or post-reset
-- respawn): staged reveal, crash site, starting turret and nest territory.
Public.setup_starting_area = function(surface)
    start_map_reveal(surface)
    create_crash_site(surface)
    place_turret_at_spawn()
    game.surfaces[1].create_territory{chunks = {{-2,-2},{-1,-2},{0,-2},{1,-2},{-2,-1},{-1,-1},{0,-1},{1,-1},{-2,0},{-1,0},{0,0},{1,0},{-2,1},{-1,1},{0,1},{1,1}}}
end

local on_surface_created = function(event)
    if game.surfaces["vulcanus"] ~= nil then
    local mgs = game.surfaces["vulcanus"].map_gen_settings
    mgs.no_enemies_mode = true
    game.surfaces["vulcanus"].map_gen_settings = mgs
    end
    if game.surfaces["aquilo"] ~= nil then
    game.surfaces["aquilo"].global_effect = {quality = 4}
    end

end

-- One-time setup for the very first round, run by the first created player.
Public.setup_first_round = function(player)
    if storage.init_ran then return end
    storage.init_ran = true

    game.forces["enemy"].friendly_fire = false
    game.permissions.get_group('Default').set_allows_action(defines.input_action.add_permission_group, false)
    game.permissions.get_group('Default').set_allows_action(defines.input_action.delete_permission_group, false)
    game.permissions.get_group('Default').set_allows_action(defines.input_action.edit_permission_group, false)
    game.permissions.get_group('Default').set_allows_action(defines.input_action.import_permissions_string, false)
    game.permissions.get_group('Default').set_allows_action(defines.input_action.map_editor_action, false)
    game.permissions.get_group('Default').set_allows_action(defines.input_action.toggle_map_editor, false)
    game.permissions.get_group('Default').set_allows_action(defines.input_action.change_multiplayer_config, false)
    game.permissions.get_group('Default').set_allows_action(defines.input_action.cheat, false)

    if not storage.disable_crashsite then
        local surface = player.surface
        Public.setup_starting_area(surface)
        surface.daytime = 0.7
    end
end

-- First respawn after a reset: set up the fresh round for this player.
Public.on_first_respawn = function(player)
    local surface = game.surfaces[1]
    Public.setup_starting_area(surface)
    game.forces["enemy"].friendly_fire = false
    util.insert_safe(player, storage.created_items)
    -- Cleanup platforms that have no surface
    for _, platform in pairs(game.forces["player"].platforms) do
    platform.destroy(1)
    end
end

-- Global on purpose: control.lua's /reset command calls reset() directly.
function reset()
    local science = game.forces["player"].get_item_production_statistics(1).get_input_count "science"
        if (science > 0) then
            local minutes = math.floor(game.ticks_played / 3600)
            local victory = storage.victory
            local log_message = string.format("%s_%d_%d", tostring(victory), science, minutes)
            helpers.write_file("reset/reset.log", log_message, false, 0)
        end
    change_seed()
    -- We clear the main surfaces instead of deleting them because the seed can't be changed if they are deleted..
    game.surfaces["nauvis"].clear(true)
    if game.surfaces["vulcanus"] ~= nil then
    game.surfaces["vulcanus"].clear(true)
    end
    if game.surfaces["gleba"] ~= nil then
    game.surfaces["gleba"].clear(true)
    end
    if game.surfaces["fulgora"] ~= nil then
    game.surfaces["fulgora"].clear(true)
    end
    if game.surfaces["aquilo"] ~= nil then
    game.surfaces["aquilo"].clear(true)
    end
    -- We delete space platforms
    for _, surface in pairs(game.surfaces) do
        if surface.platform then
            game.delete_surface(surface)
        end
    end
end

-- NOTE: on_player_respawned is owned by freeplay.lua (one handler per event);
-- it routes here when storage.recently_reset is set.

-- Event/lib declarations: event_handler.add_lib reads these and ignores
-- every other field, so public functions coexist here safely.
Public.events =
{
  [defines.events.on_surface_created] = on_surface_created,
  [defines.events.on_pre_surface_cleared] = on_pre_surface_cleared,
  [defines.events.on_surface_cleared] = on_surface_cleared,
}
Public.on_init = ensure_crash_loot
Public.on_configuration_changed = function() ensure_crash_loot() end
-- Re-register the tick handler after a save/load if a reveal was in flight,
-- since dynamic event registrations don't survive loading.
Public.on_load = function()
    if storage.reveal_index then
        script.on_event(defines.events.on_tick, on_tick_reveal)
    end
end

return Public

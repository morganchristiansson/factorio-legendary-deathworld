local util = require("util")
local crash_site = require("crash-site")

local created_items = function()
  return
  {
    ["pistol"] = 1,
    ["firearm-magazine"] = 10
  }
end

local respawn_items = function()
  return
  {
    ["pistol"] = 1
  }
end

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
-----------------------------------------------------------
storage.quality = "legendary"
storage.strafer = "behemoth-spitter"
storage.stomper = "behemoth-spitter"
storage.recently_reset = "false"
storage.victory = false
storage.nested_recently = false
storage.nesting_spot = {{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0}}
-----------------------------------------------------
local on_chunk_generated = function(event)
	if event.surface.name == "nauvis" then
		for k, entity in pairs (game.surfaces[1].find_entities_filtered{area = event.area, type = {"unit-spawner", "turret"}}) do
			game.surfaces[1].create_entity{name = entity.name, position = entity.position, quality = "legendary"}
			entity.destroy()
		end
	end
end
----------------------------------------------------
local on_surface_created = function(event)
	if game.surfaces["vulcanus"] ~= nil then
	local mgs = game.surfaces["vulcanus"].map_gen_settings
	mgs.no_enemies_mode = true
	game.surfaces["vulcanus"].map_gen_settings = mgs
	end
    if game.surfaces["aquilo"] ~= nil then
    game.surfaces["aquilo"].global_effect = {quality = 4}
    -- game.surfaces["aquilo"].brightness_visual_weights = { 1, 1, 1 }
    -- game.surfaces["aquilo"].dawn = 0.98
    -- game.surfaces["aquilo"].dusk = 0.02
    -- game.surfaces["aquilo"].evening = 0.12
    -- game.surfaces["aquilo"]. morning = 0.88
    end
    
end
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
    
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
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
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------
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
-----------------------------------------------------------------------------------------------
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
------------------------------------------------------------------------------------------------
local on_player_respawned = function(event)
	local player = game.get_player(event.player_index)
	if storage.recently_reset == "true" then
		storage.recently_reset = "false"
		local surface = game.surfaces[1]
		surface.request_to_generate_chunks({0, 0}, 19)
		surface.force_generate_chunk_requests()
		crash_site.create_crash_site(surface, {-5,-6}, util.copy(storage.crashed_ship_items), util.copy(storage.crashed_debris_items), util.copy(storage.crashed_ship_parts))
		game.forces["player"].chart_all("nauvis")
		game.forces["enemy"].friendly_fire = false
		util.insert_safe(player, storage.created_items)
        place_turret_at_spawn()
		game.surfaces[1].create_territory{chunks = {{-2,-2},{-1,-2},{0,-2},{1,-2},{-2,-1},{-1,-1},{0,-1},{1,-1},{-2,0},{-1,0},{0,0},{1,0},{-2,1},{-1,1},{0,1},{1,1}}}
		-- Cleanup platforms that have no surface
		for _, platform in pairs(game.forces["player"].platforms) do
		platform.destroy(1)
		end
	else
	util.insert_safe(player, storage.respawn_items)
	end
end
------------------------------------------------------------------------------------------------
local on_research_finished = function(event)
	if (event.research.name == "quality-module") then
	game.forces["player"].technologies["epic-quality"].researched = true
	game.forces["player"].technologies["legendary-quality"].researched = true
	end
	if (event.research.name == "refined-flammables-1") then
		game.forces["player"].set_turret_attack_modifier("flamethrower-turret", 0)
	end
	if (event.research.name == "refined-flammables-2") then
		game.forces["player"].set_turret_attack_modifier("flamethrower-turret", 0)
	end
	if (event.research.name == "refined-flammables-3") then
		game.forces["player"].set_turret_attack_modifier("flamethrower-turret", 0)
	end
	if (event.research.name == "refined-flammables-4") then
		game.forces["player"].set_turret_attack_modifier("flamethrower-turret", 0)
	end
	if (event.research.name == "refined-flammables-5") then
		game.forces["player"].set_turret_attack_modifier("flamethrower-turret", 0)
	end
	if (event.research.name == "refined-flammables-6") then
		game.forces["player"].set_turret_attack_modifier("flamethrower-turret", 0)
	end
    -- if (event.research.name == "stronger-explosives-2") then
	-- 	game.forces["player"].set_ammo_damage_modifier("landmine", 0)
	-- end
	if (event.research.name == "laser") then
		game.forces["player"].recipes["laser-turret"].productivity_bonus = 1
        game.forces["player"].set_gun_speed_modifier("laser", 2)
	end
    if (event.research.name == "defender") then
		game.forces["player"].recipes["defender-capsule"].productivity_bonus = 1
        game.forces["player"].following_robots_lifetime_modifier = 4
	end
	local player_count = 0
	for k, players in pairs (game.connected_players) do
		player_count = player_count + 1
	end
    local research = event.research.name
	local evo = game.forces["enemy"].get_evolution_factor("nauvis")
	local progress_message = string.format("Evolution: %f | Players: %d | Researched: %s\n", evo, player_count, tostring(research))
	helpers.write_file("progress/progress.log", progress_message, true, 0)
end
------------------------------------------------------------------------------------------------
script.on_event(defines.events.on_entity_died,
function(event)
    if event.entity.type == "asteroid" then
        for count = 0, math.random(2, 5), 1 do
            game.surfaces[event.entity.surface_index].create_entity{name = "huge-promethium-asteroid", quality= "legendary", position = event.entity.position, velocity = {0.05,0.05}}
        end
		for count = 0, math.random(2, 5), 1 do
            game.surfaces[event.entity.surface_index].create_entity{name = "huge-promethium-asteroid", quality= "legendary", position = event.entity.position, velocity = {-0.05,0.05}}
        end
		for count = 0, math.random(2, 5), 1 do
            game.surfaces[event.entity.surface_index].create_entity{name = "huge-promethium-asteroid", quality= "legendary", position = event.entity.position, velocity = {0,0.05}}
        end
    else
	    if math.random(1, 4) == 1 then
	    	local rand = math.random(1, 20)
		    storage.nesting_spot[rand][1] = event.entity.position.x
		    storage.nesting_spot[rand][2] = event.entity.position.y
	    end
    end
end
)
script.set_event_filter(defines.events.on_entity_died, {{filter = "name", name = "behemoth-spitter"}, {filter = "name", name = "huge-metallic-asteroid"}, {filter = "name", name = "huge-carbonic-asteroid"}, {filter = "name", name = "huge-oxide-asteroid"}})
------------------------------------------------------------------------------------------------
script.on_event(defines.events.on_post_entity_died,
function(event)
    if event.prototype.type == "unit-spawner" then
	    game.surfaces[1].create_entity{name = storage.strafer, position = event.position, quality = "legendary"}
	    game.surfaces[1].create_entity{name = storage.stomper, position = event.position, quality = storage.quality}
    else
        if math.random(1, 10) == 1 then
            game.surfaces[event.surface_index].create_entity{name = "grenade", target = event.position, position = event.position, force = "player", base_damage_modifiers = {damage_modifier = 0.43}}
        end
    end
end
)
script.set_event_filter(defines.events.on_post_entity_died, {{filter = "type", type = "unit-spawner"}, {filter = "type", type = "land-mine"}})
------------------------------------------------------------
local on_unit_group_finished_gathering = function(event)
	if storage.nested_recently == true then
		local command = {
		type = defines.command.compound,structure_type = defines.compound_command.return_last,commands ={
		{type = defines.command.go_to_location,destination = {0, 0}},
		{type = defines.command.attack_area,destination = {0, 0},radius = 16,distraction = defines.distraction.by_anything},
		{type = defines.command.build_base,destination = {0, 0},distraction = defines.distraction.none,ignore_planner = true}}}
		event.group.set_command(command)
	else
		local x = event.group.position.x
		local y = event.group.position.y
		local dx1 = x - storage.nesting_spot[1][1]
		local dy1 = y - storage.nesting_spot[1][2]
		local dx2 = x - storage.nesting_spot[2][1]
		local dy2 = y - storage.nesting_spot[2][2]
		local dx3 = x - storage.nesting_spot[3][1]
		local dy3 = y - storage.nesting_spot[3][2]
		local dx4 = x - storage.nesting_spot[4][1]
		local dy4 = y - storage.nesting_spot[4][2]
		local dx5 = x - storage.nesting_spot[5][1]
		local dy5 = y - storage.nesting_spot[5][2]
		local dx6 = x - storage.nesting_spot[6][1]
		local dy6 = y - storage.nesting_spot[6][2]
		local dx7 = x - storage.nesting_spot[7][1]
		local dy7 = y - storage.nesting_spot[7][2]
		local dx8 = x - storage.nesting_spot[8][1]
		local dy8 = y - storage.nesting_spot[8][2]
		local dx9 = x - storage.nesting_spot[9][1]
		local dy9 = y - storage.nesting_spot[9][2]
		local dx10 = x - storage.nesting_spot[10][1]
		local dy10 = y - storage.nesting_spot[10][2]
		local dx11 = x - storage.nesting_spot[11][1]
		local dy11 = y - storage.nesting_spot[11][2]
		local dx12 = x - storage.nesting_spot[12][1]
		local dy12 = y - storage.nesting_spot[12][2]
		local dx13 = x - storage.nesting_spot[13][1]
		local dy13 = y - storage.nesting_spot[13][2]
		local dx14 = x - storage.nesting_spot[14][1]
		local dy14 = y - storage.nesting_spot[14][2]
		local dx15 = x - storage.nesting_spot[15][1]
		local dy15 = y - storage.nesting_spot[15][2]
		local dx16 = x - storage.nesting_spot[16][1]
		local dy16 = y - storage.nesting_spot[16][2]
		local dx17 = x - storage.nesting_spot[17][1]
		local dy17 = y - storage.nesting_spot[17][2]
		local dx18 = x - storage.nesting_spot[18][1]
		local dy18 = y - storage.nesting_spot[18][2]
		local dx19 = x - storage.nesting_spot[19][1]
		local dy19 = y - storage.nesting_spot[19][2]
		local dx20 = x - storage.nesting_spot[20][1]
		local dy20 = y - storage.nesting_spot[20][2]
		storage.nesting_spot[1][3] = (math.sqrt(dx1 * dx1 + dy1 * dy1))
		storage.nesting_spot[2][3] = (math.sqrt(dx2 * dx2 + dy2 * dy2))
		storage.nesting_spot[3][3] = (math.sqrt(dx3 * dx3 + dy3 * dy3))
		storage.nesting_spot[4][3] = (math.sqrt(dx4 * dx4 + dy4 * dy4))
		storage.nesting_spot[5][3] = (math.sqrt(dx5 * dx5 + dy5 * dy5))
		storage.nesting_spot[6][3] = (math.sqrt(dx6 * dx6 + dy6 * dy6))
		storage.nesting_spot[7][3] = (math.sqrt(dx7 * dx7 + dy7 * dy7))
		storage.nesting_spot[8][3] = (math.sqrt(dx8 * dx8 + dy8 * dy8))
		storage.nesting_spot[9][3] = (math.sqrt(dx9 * dx9 + dy9 * dy9))
		storage.nesting_spot[10][3] = (math.sqrt(dx10 * dx10 + dy10 * dy10))
		storage.nesting_spot[11][3] = (math.sqrt(dx11 * dx11 + dy11 * dy11))
		storage.nesting_spot[12][3] = (math.sqrt(dx12 * dx12 + dy12 * dy12))
		storage.nesting_spot[13][3] = (math.sqrt(dx13 * dx13 + dy13 * dy13))
		storage.nesting_spot[14][3] = (math.sqrt(dx14 * dx14 + dy14 * dy14))
		storage.nesting_spot[15][3] = (math.sqrt(dx15 * dx15 + dy15 * dy15))
		storage.nesting_spot[16][3] = (math.sqrt(dx16 * dx16 + dy16 * dy16))
		storage.nesting_spot[17][3] = (math.sqrt(dx17 * dx17 + dy17 * dy17))
		storage.nesting_spot[18][3] = (math.sqrt(dx18 * dx18 + dy18 * dy18))
		storage.nesting_spot[19][3] = (math.sqrt(dx19 * dx19 + dy19 * dy19))
		storage.nesting_spot[20][3] = (math.sqrt(dx20 * dx20 + dy20 * dy20))
		table.sort(storage.nesting_spot, function(a,b) local aNum = a[3] local bNum = b[3] return aNum < bNum end)
		local command = {
		type = defines.command.compound,structure_type = defines.compound_command.return_last,commands ={
		{type = defines.command.go_to_location,destination = {storage.nesting_spot[1][1], storage.nesting_spot[1][2]},distraction = defines.distraction.none},
		{type = defines.command.build_base,destination = {storage.nesting_spot[1][1], storage.nesting_spot[1][2]},distraction = defines.distraction.none,ignore_planner = true}}}
		event.group.set_command(command)
		storage.nested_recently = true
	end
end
-------------------------------------------------------------------
local on_biter_base_built = function(event)
	local x = event.entity.position.x
	local y = event.entity.position.y
	if (x > -34 and x < 34 and y > -34 and y < 34) then
		game.print("[color=acid][font=default-large-bold]Biter nests growing near spawn. Defeat imminent![/font][/color]")
		local nest_count = game.surfaces[1].count_entities_filtered{area={left_top = {x = -32, y = -32}, right_bottom = {x = 32, y = 32}},type={"turret","unit-spawner"}}
		if nest_count > 3 or game.ticks_played < 36000 then
			reset()
		end
	end
end
-------------------------------------------------------------------
script.on_nth_tick(3600, function()
    storage.nested_recently = false

    if math.random(1, 5) == 1 then
	game.map_settings.asteroids.spawning_rate = 10
    else
	game.map_settings.asteroids.spawning_rate = 1
	end

	if game.forces["player"].technologies["logistic-science-pack"].researched then
	local ex = game.map_settings.enemy_expansion
	if ex.settler_group_min_size < 90 then
	ex.settler_group_min_size = ex.settler_group_min_size + 1
	ex.settler_group_max_size = ex.settler_group_max_size + 1
	end
	end
	
    -- starting time evo is 0.00004
	local evo = game.forces["enemy"].get_evolution_factor(1)
    if evo > 0.2 and evo < 0.6 then
 	game.map_settings.pollution.enemy_attack_pollution_consumption_modifier = 0.5
	game.map_settings.enemy_evolution.time_factor = 0.00005
	storage.strafer = "small-strafer-pentapod"
	storage.stomper = "small-stomper-pentapod"
   	end
	if evo > 0.6 and evo < 0.7 then
	game.map_settings.pollution.enemy_attack_pollution_consumption_modifier = 0.25
	storage.strafer = "medium-strafer-pentapod"
	storage.stomper = "medium-stomper-pentapod"
	game.map_settings.enemy_evolution.time_factor = 0.00009
	end
	if evo > 0.7 and evo < 0.8 then
	storage.strafer = "big-strafer-pentapod"
	storage.stomper = "big-stomper-pentapod"
    game.map_settings.enemy_evolution.time_factor = 0.0002
	end
	if evo > 0.85 and evo < 0.95 then
	game.map_settings.pollution.enemy_attack_pollution_consumption_modifier = 0.125
    game.map_settings.enemy_evolution.time_factor = 0.0004
	end
	if evo > 0.95 and evo < 0.97 then
    game.map_settings.enemy_evolution.time_factor = 0.0008
	end

end)
-------------------------------------------------------------------
local on_space_platform_changed_state = function(event)
	if event.platform.space_location ~= nil then
		if event.platform.space_location.name == "solar-system-edge" then
			game.set_game_state{game_finished = true, player_won = true, can_continue = true, victorious_force = player}
            storage.victory = true
		end
	end
	if event.platform.last_visited_space_location ~= nil then
		if event.platform.last_visited_space_location.name == "solar-system-edge" then
			game.set_game_state{game_finished = true, player_won = true, can_continue = true, victorious_force = player}
            storage.victory = true
		end
	end
    -- if event.platform.space_connection ~= nil then
    --     if event.platform.space_connection.length > 90000 then
    --         game.surfaces[event.platform.surface.index].daytime = 0.5
    --         game.surfaces[event.platform.surface.index].brightness_visual_weights = { 1, 1, 1 }
    --     elseif event.platform.space_connection.length < 90000 then
    --         game.surfaces[event.platform.surface.index].daytime = 1
    --         game.surfaces[event.platform.surface.index].brightness_visual_weights = { 0, 0, 0 }
    --     end
    -- end
end

-------------------------------------------------------------------

script.on_event(defines.events.on_player_used_capsule, function(e)
    if e.item.name ~= 'artillery-targeting-remote' then return end
    local player = game.get_player(e.player_index)
    log(player.name .. ' used artillery targeting remote at ' .. e.position.x .. ', ' .. e.position.y)
end)

-------------------------------------------------------------------
local on_player_flushed_fluid = function(event)
    local player = game.get_player(event.player_index)
    log(player.name .. ' flushed fluid ' .. event.fluid .. ' amount ' .. event.amount .. ' from entity ' .. event.entity.name .. ' at ' .. event.entity.gps_tag)
end
-------------------------------------------------------------------

local on_player_created = function(event)
  local player = game.get_player(event.player_index)
  local name = player.name
  util.insert_safe(player, storage.created_items)
  if name == "Atraps003" then
  game.permissions.create_group('server')
  game.permissions.get_group('server').add_player("Atraps003")
  end

  if not storage.init_ran then

    --This is so that other mods and scripts have a chance to do remote calls before we do things like charting the starting area, creating the crash site, etc.
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
      surface.request_to_generate_chunks({0, 0}, 19)
      surface.force_generate_chunk_requests()
      game.forces["player"].chart_all("nauvis")
      surface.daytime = 0.7
      crash_site.create_crash_site(surface, {-5,-6}, util.copy(storage.crashed_ship_items), util.copy(storage.crashed_debris_items), util.copy(storage.crashed_ship_parts))
      place_turret_at_spawn()
      game.surfaces[1].create_territory{chunks = {{-2,-2},{-1,-2},{0,-2},{1,-2},{-2,-1},{-1,-1},{0,-1},{1,-1},{-2,0},{-1,0},{0,0},{1,0},{-2,1},{-1,1},{0,1},{1,1}}}
      --util.remove_safe(player, storage.crashed_ship_items)
      --util.remove_safe(player, storage.crashed_debris_items)
      --player.get_main_inventory().sort_and_merge()
    end

  end

  player.print({"msg-intro-space-age"})

end

local on_player_display_refresh = function(event)
  crash_site.on_player_display_refresh(event)
end

local freeplay_interface =
{
  get_created_items = function()
    return storage.created_items
  end,
  set_created_items = function(map)
    storage.created_items = map or error("Remote call parameter to freeplay set created items can't be nil.")
  end,
  get_respawn_items = function()
    return storage.respawn_items
  end,
  set_respawn_items = function(map)
    storage.respawn_items = map or error("Remote call parameter to freeplay set respawn items can't be nil.")
  end,
  set_skip_intro = function(bool)
    storage.skip_intro = bool
  end,
  get_skip_intro = function()
    return storage.skip_intro
  end,
  set_custom_intro_message = function(message)
    storage.custom_intro_message = message
  end,
  get_custom_intro_message = function()
    return storage.custom_intro_message
  end,
  set_chart_distance = function(value)
    storage.chart_distance = tonumber(value) or error("Remote call parameter to freeplay set chart distance must be a number")
  end,
  get_disable_crashsite = function()
    return storage.disable_crashsite
  end,
  set_disable_crashsite = function(bool)
    storage.disable_crashsite = bool
  end,
  get_init_ran = function()
    return storage.init_ran
  end,
  get_ship_items = function()
    return storage.crashed_ship_items
  end,
  set_ship_items = function(map)
    storage.crashed_ship_items = map or error("Remote call parameter to freeplay set created items can't be nil.")
  end,
  get_debris_items = function()
    return storage.crashed_debris_items
  end,
  set_debris_items = function(map)
    storage.crashed_debris_items = map or error("Remote call parameter to freeplay set respawn items can't be nil.")
  end,
  get_ship_parts = function()
    return storage.crashed_ship_parts
  end,
  set_ship_parts = function(parts)
    storage.crashed_ship_parts = parts or error("Remote call parameter to freeplay set ship parts can't be nil.")
  end
}

if not remote.interfaces["freeplay"] then
  remote.add_interface("freeplay", freeplay_interface)
end

local is_debug = function()
  local surface = game.surfaces.nauvis
  local map_gen_settings = surface.map_gen_settings
  return map_gen_settings.width == 50 and map_gen_settings.height == 50
end

local init_ending_info = function()
  local is_space_age = script.active_mods["space-age"]
  local info =
  {
    image_path = is_space_age and "__base__/script/freeplay/victory-space-age.png" or "__base__/script/freeplay/victory.png",
    title = {"gui-game-finished.victory"},
    message = is_space_age and {"victory-message-space-age"} or {"victory-message"},
    bullet_points =
    {
      {"victory-bullet-point-1"},
      {"victory-bullet-point-2"},
      {"victory-bullet-point-3"},
      {"victory-bullet-point-4"}
    },
    final_message = {"victory-final-message"},
  }
  game.set_win_ending_info(info)
end

local freeplay = {}

freeplay.events =
{
  [defines.events.on_player_created] = on_player_created,
  [defines.events.on_player_respawned] = on_player_respawned,
  [defines.events.on_pre_surface_cleared] = on_pre_surface_cleared,
  [defines.events.on_surface_cleared] = on_surface_cleared,
  [defines.events.on_surface_created] = on_surface_created,
  [defines.events.on_chunk_generated] = on_chunk_generated,
  [defines.events.on_research_finished] = on_research_finished,
  [defines.events.on_unit_group_finished_gathering] = on_unit_group_finished_gathering,
  [defines.events.on_biter_base_built] = on_biter_base_built,
  [defines.events.on_space_platform_changed_state] = on_space_platform_changed_state,
  [defines.events.on_player_flushed_fluid] = on_player_flushed_fluid,
  [defines.events.on_player_display_resolution_changed] = on_player_display_refresh,
  [defines.events.on_player_display_scale_changed] = on_player_display_refresh
}

freeplay.on_configuration_changed = function()
  storage.created_items = storage.created_items or created_items()
  storage.respawn_items = storage.respawn_items or respawn_items()
  storage.crashed_ship_items = storage.crashed_ship_items or ship_items()
  storage.crashed_debris_items = storage.crashed_debris_items or debris_items()
  storage.crashed_ship_parts = storage.crashed_ship_parts or ship_parts()

  if not storage.init_ran then
    -- migrating old saves.
    storage.init_ran = #game.players > 0
  end
  init_ending_info()
end

freeplay.on_init = function()
  game.allow_tip_activation = true
  storage.created_items = created_items()
  storage.respawn_items = respawn_items()
  storage.crashed_ship_items = ship_items()
  storage.crashed_debris_items = debris_items()
  storage.crashed_ship_parts = ship_parts()

  if is_debug() then
    storage.skip_intro = true
    storage.disable_crashsite = true
  end

  init_ending_info()

end

return freeplay

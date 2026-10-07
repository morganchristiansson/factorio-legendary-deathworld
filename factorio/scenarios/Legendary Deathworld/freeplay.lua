local util = require("util")
local reset = require("reset")
local jail = require("jail")
local register = require("register")

-- The kit, given at spawn and on every death respawn. They used to differ --
-- spawn got ten magazines, a respawn got none -- because a second player could
-- be killed repeatedly to farm the respawn kit; the bioflux protection makes
-- that impractical and magazines are craftable, so it only taxed the victim.
local created_items = function()
  return
  {
    ["pistol"] = 1,
    ["firearm-magazine"] = 10
  }
end

-- Temporary effects share one self-unregistering expiry sweep: respawn
-- protection and ping labels register it, and on_load re-arms it after saves.
local on_temporary_tick = function()
    local active = false
    local pending = storage.respawn_protection
    if pending ~= nil then
        for player_index, expiry in pairs(pending) do
            if game.tick >= expiry then
                pending[player_index] = nil
                local player = game.get_player(player_index)
                if player and player.character and player.character.valid then
                    player.character.destructible = true
                end
            end
        end
        active = next(pending) ~= nil
    end

    local pings = storage.pings
    if pings ~= nil then
        for index = #pings, 1, -1 do
            local ping = pings[index]
            if not ping.label.valid or game.tick >= ping.expiry then
                if ping.label.valid then
                    ping.label.destroy()
                end
                if ping.messages.valid and #ping.messages.children == 0 then
                    ping.messages.destroy()
                end
                table.remove(pings, index)
            end
        end
        active = active or next(pings) ~= nil
    end

    if active then return end
    register.disarm("temporary")
end
-- Dynamic worker for the one-shot expiry sweep; register re-arms it on load
-- from the stored active state.
register.nth_tick("temporary", 30, on_temporary_tick)

local ping_player = function(target, message)
    if not target.character then return end

    target.character.damage(0.001, 'player')
    target.play_sound{path = 'utility/new_objective', volume_modifier = 1}

    local screen = target.gui.screen
    local messages = screen.ping_messages
    if not messages then
        messages = screen.add{type = 'flow', name = 'ping_messages', direction = 'vertical'}
        messages.style.width = 400
        messages.location = {
            x = target.display_resolution.width / 2 - 200 * target.display_scale,
            y = 142 * target.display_scale,
        }
    end

    local label = messages.add{type = 'label', caption = message}
    label.style.single_line = false
    label.style.font = 'default-large-semibold'

    storage.pings = storage.pings or {}
    table.insert(storage.pings, {
        label = label,
        messages = messages,
        expiry = game.tick + 600,
    })
    register.arm("temporary")
end

local on_console_chat = function(event)
    if not event.player_index or not event.message then return end
    local author = game.get_player(event.player_index)
    if not author then return end

    local names = {}
    for name in string.gmatch(event.message, '@%s?([a-zA-Z0-9_-]+)') do
        names[name] = true
    end
    for name in string.gmatch(event.message, '([a-zA-Z0-9_-]+)@') do
        names[name] = true
    end

    local message = author.name .. ': ' .. event.message
    for name in pairs(names) do
        local target = game.get_player(name)
        if target and target.connected then
            ping_player(target, message)
        end
    end
end

-- Common metadata formatting so every log() line parses uniformly:
-- event=<name>, key=value pairs, comma-separated.
local format_position = function(position)
    return string.format("%.1f,%.1f", position.x, position.y)
end

local format_actor = function(player_index)
    local player = game.get_player(player_index)
    return player and player.name or "unknown"
end

-----------------------------------------------------------------------
storage.quality = "legendary"
storage.strafer = "behemoth-spitter"
storage.stomper = "behemoth-spitter"
storage.victory = false
storage.nested_recently = false
storage.nesting_spot = {{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0}}
-----------------------------------------------------------------------
local on_chunk_generated = function(event)
	if reset.is_round_surface(event.surface) then
		for k, entity in pairs (event.surface.find_entities_filtered{area = event.area, type = {"unit-spawner", "turret"}}) do
			event.surface.create_entity{name = entity.name, position = entity.position, quality = "legendary"}
			entity.destroy()
		end
	end
end
-----------------------------------------------------------------------
local on_player_respawned = function(event)
    local player = game.get_player(event.player_index)
    -- A jailed player respawns straight back in the pit, with no kit. The
    -- teleport itself is jail's own on_player_respawned handler.
    if jail.is_jailed(player.name) then
        return
    end
    -- The same kit a fresh spawn gets. This used to branch on the reset flag,
    -- because a respawn kit and a spawn kit could not both be given.
    util.insert_safe(player, storage.created_items)
    -- Death respawns only: joins arrive via on_player_created and skip this.
    -- Protection lasts exactly as long as the bioflux effect itself: the
    -- fresh sticker's time_to_live starts at the prototype duration.
    if player.character and player.character.valid then
        local sticker = player.surface.create_entity{name = "bioflux-speed-regen-sticker", position = player.position, target = player.character}
        player.character.destructible = false
        storage.respawn_protection = storage.respawn_protection or {}
        storage.respawn_protection[player.index] = game.tick + sticker.time_to_live
        player.surface.create_entity{name = "bioflux-speed-regen-sticker-behind", position = player.position, target = player.character}
        register.arm("temporary")
    end
end
-----------------------------------------------------------------------
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
    local player_count = #game.connected_players
    local research = event.research.name
    local evo = game.forces["enemy"].get_evolution_factor(reset.active_surface())
    log(string.format("event=research-finished, research=%s, evolution=%.4f, players=%d", research, evo, player_count))
end
-----------------------------------------------------------------------
local on_player_died = function(event)
    local player = game.get_player(event.player_index)
    if not player then
        return
    end
    -- A reset clears the surface out from under everyone; that death is ours,
    -- and a line per player per reroll buries everything else in the log.
    -- (The swap detaches characters instead of killing them, so this fires
    -- only for genuine combat deaths.)
    local cause = "unknown"
    if event.cause and event.cause.valid then
        cause = event.cause.name
    end
    log(string.format("event=player-died, actor=%s, position=%s, cause=%s",
        player.name,
        format_position(player.position),
        cause))
end
-----------------------------------------------------------------------
-- Apex-spitter nesting logic lives here; the filter builder is canonical in
-- reset.lua (this module already requires it) so saves never desync.
local apex_filter = reset.apex_filter

local current_apex_spitter = function()
    -- evolution is only readable inside handlers
    if game == nil then
        return nil, 0
    end
    local evo = game.forces["enemy"].get_evolution_factor(1)
    if evo < 0.9 then
        return nil, evo -- matches when behemoth spitters appear naturally
    end
    local best_damage, best_name = 0, nil
    for _, entry in ipairs(prototypes.entity["spitter-spawner"].result_units) do
        -- a unit counts once evolution reaches its first spawn threshold
        local first_window = entry.spawn_points[1]
        if first_window ~= nil and evo >= first_window.evolution_factor then
            local attack = prototypes.entity[entry.unit].attack_parameters
            if attack ~= nil and attack.damage_modifier > best_damage then
                best_damage, best_name = attack.damage_modifier, entry.unit
            end
        end
    end
    return best_name, evo
end

local update_apex_spitter = function()
    local name, evo = current_apex_spitter()
    if name == storage.apex_spitter then return end
    register.set_filter(defines.events.on_entity_died, apex_filter(name))
    storage.apex_spitter = name
    log(string.format("event=apex-spitter, evolution=%.2f, unit=%s", evo, name or "none"))
    if name ~= nil and game ~= nil then
        -- a new deadliest spitter is a step change in difficulty
        game.print({"ld-announcement", {"ld-apex-spitter", prototypes.entity[name].localised_name}})
    end
end
-----------------------------------------------------------------------
-- Handlers register before filters: registering a handler clears its filters,
-- so the baseline set_event_filter calls below must come after.
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
-- Static baselines re-execute every session; the dynamic apex entry routes
-- through register, which re-applies the stored filter on load.
script.set_event_filter(defines.events.on_entity_died, apex_filter(nil))
-----------------------------------------------------------------------
script.on_event(defines.events.on_post_entity_died,
function(event)
    if event.prototype.type == "unit-spawner" then
        if storage.defeat_in then
            reset.check_defeat_cancel()
        end
        -- Named when the engine says who: last_user for turret and flamethrower
        -- kills, cause.player for the character that fired. Attribution, not
        -- credit -- a killed nest spawns two legendary guardians, and those
        -- end up killing more nests, often the killers' own, so this is
        -- context rather than an accusation. Where nobody is named (artillery,
        -- capsules, spreading fire, guardians) the death is announced without
        -- a name and the log records why. cause can be gone by now (turret
        -- destroyed in the same event), hence the valid check.
        local cause = event.cause
        local cause_name, cause_type, cause_user = "none", "none", false
        local killer
        if cause and cause.valid then
            cause_name, cause_type, cause_user = cause.name, cause.prototype.type, cause.last_user ~= nil
            killer = cause.last_user or cause.player
        end
        -- Coordinates arrive as one prebuilt tag parameter so translators can
        -- place it anywhere in the sentence (or drop it) without touching
        -- the two coordinates separately. The surface rides in the tag so a
        -- map-jump lands on the round surface, not the dummy primary.
        local tag = string.format("[gps=%.1f,%.1f,%s]",
            event.position.x, event.position.y, game.surfaces[event.surface_index].name)
        local nest = event.prototype.localised_name
        if killer then
            game.print({"ld-nest-killed", killer.name, tag, nest})
        else
            game.print({"ld-nest-killed-unknown", nest, tag})
        end
        -- Inline the fields rather than string.format: the empty key skips the
        -- locale lookup and prints the params as-is, so the line stays one
        -- readable string with no %s bookkeeping.
        log{"", "event=nest-killed, actor=", killer and killer.name or "unknown",
            ", position=", format_position(event.position),
            ", prototype=", event.prototype.name,
            ", cause=", cause_name,
            ", cause_type=", cause_type,
            ", cause_user=", tostring(cause_user),
            ", connected=", #game.connected_players}
        local surface = game.surfaces[event.surface_index]
        local pos = surface.find_non_colliding_position(storage.strafer, event.position, 10, 0.5)
        surface.create_entity{name = storage.strafer, position = pos, quality = "legendary"}
        pos = surface.find_non_colliding_position(storage.stomper, event.position, 10, 0.5)
        surface.create_entity{name = storage.stomper, position = pos, quality = storage.quality}
        if event.prototype.name == "gleba-spawner" then
            for i = 1, 9 do
                pos = surface.find_non_colliding_position("item-on-ground", event.position, 0.5, 0.1)
                surface.create_entity{name = "item-on-ground", position = pos, stack = {name = "pentapod-egg", count = 1}}
            end
        elseif event.prototype.name == "gleba-spawner-small" then
            for i = 1, math.random(1, 3) do
                pos = surface.find_non_colliding_position("item-on-ground", event.position, 0.5, 0.1)
                surface.create_entity{name = "item-on-ground", position = pos, stack = {name = "pentapod-egg", count = 1}}
            end
        end
    else
        if math.random(1, 10) == 1 then
            game.surfaces[event.surface_index].create_entity{name = "grenade", target = event.position, position = event.position, force = "player", base_damage_modifiers = {damage_modifier = 0.43}}
        end
    end
end
)
script.set_event_filter(defines.events.on_post_entity_died, {{filter = "type", type = "unit-spawner"}, {filter = "type", type = "land-mine"}})
-----------------------------------------------------------------------
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
-----------------------------------------------------------------------
-- Evolution stages: applied and announced once, when the threshold is first
-- crossed; texts come from locale/en/freeplay.cfg (ld-evo-milestone-*)
local evo_stages = {
    {0.20, "ld-evo-milestone-20", function()
        game.map_settings.pollution.enemy_attack_pollution_consumption_modifier = 0.5
        game.map_settings.enemy_evolution.time_factor = 0.00005
        storage.strafer = "small-strafer-pentapod"
        storage.stomper = "small-stomper-pentapod"
    end},
    {0.60, "ld-evo-milestone-60", function()
        game.map_settings.pollution.enemy_attack_pollution_consumption_modifier = 0.25
        game.map_settings.enemy_evolution.time_factor = 0.00009
        storage.strafer = "medium-strafer-pentapod"
        storage.stomper = "medium-stomper-pentapod"
    end},
    {0.70, "ld-evo-milestone-70", function()
        game.map_settings.enemy_evolution.time_factor = 0.0002
        storage.strafer = "big-strafer-pentapod"
        storage.stomper = "big-stomper-pentapod"
    end},
    {0.80, "ld-evo-milestone-80", function()
        storage.strafer = "behemoth-strafer-pentapod"
        storage.stomper = "behemoth-stomper-pentapod"
    end},
    {0.85, "ld-evo-milestone-85", function()
        game.map_settings.pollution.enemy_attack_pollution_consumption_modifier = 0.125
        game.map_settings.enemy_evolution.time_factor = 0.0004
    end},
    {0.95, "ld-evo-milestone-95", function()
        game.map_settings.enemy_evolution.time_factor = 0.0008
    end},
}
-----------------------------------------------------------------------
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
    local evo = game.forces["enemy"].get_evolution_factor(reset.active_surface())
    storage.evo_stage = storage.evo_stage or 0
    for i, stage in ipairs(evo_stages) do
        if evo >= stage[1] and storage.evo_stage < i then
            storage.evo_stage = i
            stage[3]()
            game.print({"ld-announcement", {stage[2]}})
            log(string.format("event=evo-stage, evolution=%.2f", stage[1]))
        end
    end
    update_apex_spitter()
end)
-----------------------------------------------------------------------
local on_space_platform_changed_state = function(event)
	if event.platform.space_location ~= nil then
		if event.platform.space_location.name == "solar-system-edge" then
			game.set_game_state{game_finished = true, player_won = true, can_continue = true, victorious_force = game.forces["player"]}
            storage.victory = true
		end
	end
	if event.platform.last_visited_space_location ~= nil then
		if event.platform.last_visited_space_location.name == "solar-system-edge" then
			game.set_game_state{game_finished = true, player_won = true, can_continue = true, victorious_force = game.forces["player"]}
            storage.victory = true
		end
	end
end

-----------------------------------------------------------------------

script.on_event(defines.events.on_player_used_capsule, function(e)
    if e.item.name ~= 'artillery-targeting-remote' then return end
    log(string.format("event=artillery-target, actor=%s, position=%s",
        format_actor(e.player_index), format_position(e.position)))
end)

-----------------------------------------------------------------------
local on_player_flushed_fluid = function(event)
    log(string.format("event=fluid-flushed, actor=%s, fluid=%s, amount=%s, entity=%s, position=%s",
        format_actor(event.player_index),
        event.fluid,
        event.amount,
        event.entity.name,
        format_position(event.entity.position)))
end
-----------------------------------------------------------------------

local on_player_created = function(event)
  local player = game.get_player(event.player_index)
  util.insert_safe(player, storage.created_items)
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
  [defines.events.on_player_died] = on_player_died,
  [defines.events.on_chunk_generated] = on_chunk_generated,
  [defines.events.on_research_finished] = on_research_finished,
  [defines.events.on_unit_group_finished_gathering] = on_unit_group_finished_gathering,
  [defines.events.on_space_platform_changed_state] = on_space_platform_changed_state,
  [defines.events.on_player_flushed_fluid] = on_player_flushed_fluid,
  [defines.events.on_console_chat] = on_console_chat
}

freeplay.on_configuration_changed = function()
  storage.created_items = storage.created_items or created_items()
  storage.pings = storage.pings or {}

  if not storage.init_ran then
    -- migrating old saves.
    storage.init_ran = #game.players > 0
  end
  init_ending_info()
  -- Recompute the apex filter from evolution so scenario syncs heal any drift.
  update_apex_spitter()
end

freeplay.on_init = function()
  game.allow_tip_activation = true
  storage.created_items = created_items()
  storage.pings = {}
  -- Baseline asteroids-only filter is already registered at module scope.
  storage.apex_spitter = nil

  if is_debug() then
    storage.disable_crashsite = true
  end

  init_ending_info()
end

return freeplay

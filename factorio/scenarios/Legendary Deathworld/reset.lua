-- Map reset and staged map reveal.
-----------------------------------------------------------------------
-- Public.perform_reset() wipes and regenerates the map with a fresh seed;
-- control.lua's /reset command and freeplay.lua both call it. The staged
-- reveal replaces the old
-- behaviour of generating + charting ~1500 chunks in a single tick, which
-- froze the server for seconds after every reset.
-----------------------------------------------------------------------
-- Public interface:
--   Public.setup_starting_area(surf)- reveal + crash site + spawn defences
-- Reroll vote opens automatically at the end of on_surface_cleared below.

local util = require("util")
local crash_site = require("crash-site")
local jail = require("jail")
local groups = require("groups")

local Public = {}

-----------------------------------------------------------------------
local change_seed = function(seed)
    seed = seed or math.random(1111, 4294967295)
    local mgs = game.surfaces["nauvis"].map_gen_settings
    mgs.seed = seed
    game.surfaces["nauvis"].map_gen_settings = mgs
    if game.surfaces["vulcanus"] ~= nil then
    local mgs = game.surfaces["vulcanus"].map_gen_settings
    mgs.seed = seed
    game.surfaces["vulcanus"].map_gen_settings = mgs
    end
    if game.surfaces["gleba"] ~= nil then
    local mgs = game.surfaces["gleba"].map_gen_settings
    mgs.seed = seed
    game.surfaces["gleba"].map_gen_settings = mgs
    end
    if game.surfaces["fulgora"] ~= nil then
    local mgs = game.surfaces["fulgora"].map_gen_settings
    mgs.seed = seed
    game.surfaces["fulgora"].map_gen_settings = mgs
    end
    if game.surfaces["aquilo"] ~= nil then
    local mgs = game.surfaces["aquilo"].map_gen_settings
    mgs.seed = seed
    game.surfaces["aquilo"].map_gen_settings = mgs
    end
    return seed
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

-- Chunks force-generated per tick. Measured wall time for the 1440-chunk
-- reveal on this box: 3/tick ~15.5s, 8/tick ~8.6s. Smaller batches are not
-- free -- the per-batch overhead and the workers idling between them cost more
-- than the per-tick stall they save, so do not trade this down for smoothness.
-- Each reveal logs its own wall time; a much slower machine may want fewer
-- chunks here, but it should expect the reveal to take longer.
local REVEAL_CHUNKS_PER_TICK = 8

-- A LuaProfiler cannot be read from Lua -- it arrives as a LocalisedString,
-- which log() resolves: an empty key skips the lookup and prints the params,
-- so the profiler can be passed straight in.
local reveal_total = nil

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
        -- Total wall time of the reveal. divide() would give ms-per-chunk but
        -- takes no argument in this build (self only), same as add().
        reveal_total.stop()
        log({"", "event=map-reveal, wall", reveal_total})
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
    reveal_total = game.create_profiler()
    reveal_total.restart()
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

-- Deaths of the highest-damage spitter in rotation (evolution permitting)
-- become nesting-spot candidates; modded tiers join automatically.
-- storage.apex_spitter tracks the filtered unit: nil = asteroids-only baseline,
-- string = baseline plus that unit. false is a legacy sentinel meaning
-- "needs (re)registration"; treat it like nil when building the filter.
-- Canonical home for this filter: freeplay requires this module, so both
-- sides share it without a circular import.
Public.apex_filter = function(name)
    if name == false then
        name = nil
    end
    local filter = {
        {filter = "name", name = "huge-metallic-asteroid"},
        {filter = "name", name = "huge-carbonic-asteroid"},
        {filter = "name", name = "huge-oxide-asteroid"},
    }
    if name ~= nil then
        filter[#filter + 1] = {filter = "name", name = name}
    end
    return filter
end

-----------------------------------------------------------------------
-- Map reroll vote (minimal port of the Biter Battles reroll poll): after
-- every reset, players get 1m30s to vote for another map via Yes/No
-- buttons at the top of the screen with a live tally. Majority rules: a
-- strict majority of connected players voting Yes (or No) ends the vote at
-- once, since the outcome is then mathematically decided; otherwise the
-- timeout tally needs a majority of cast votes. storage.reroll_votes is
-- nil when no vote is active.
-----------------------------------------------------------------------
local REROLL_DURATION = 90
local REROLL_FRAME = "ld_reroll_frame"
local REROLL_YES = "ld_reroll_yes"
local REROLL_NO = "ld_reroll_no"

-- Loss countdown: same top-of-screen frame as the reroll vote, no buttons.
-- Drawn and ticked by the defeat sequence further down.
local DEFEAT_FRAME = "ld_defeat_frame"

local update_defeat_countdown = function(seconds)
    for _, player in pairs(game.connected_players) do
        if not player.gui.top[DEFEAT_FRAME] then
            local frame = player.gui.top.add{type = "frame", name = DEFEAT_FRAME}
            local flow = frame.add{type = "flow", name = "flow", direction = "horizontal"}
            local caption = flow.add{type = "label", name = "defeat_caption", caption = {"ld-defeat-in", seconds}}
            caption.style.minimal_width = 120
            caption.style.maximal_width = 120
            caption.style.font = "heading-2"
            caption.style.font_color = {r = 0.88, g = 0.55, b = 0.11}
        end
        player.gui.top[DEFEAT_FRAME].flow.defeat_caption.caption = {"ld-defeat-in", seconds}
    end
end

local stop_defeat_countdown = function()
    for _, player in pairs(game.players) do
        local frame = player.gui.top[DEFEAT_FRAME]
        if frame then frame.destroy() end
    end
end

-- Set by a passed vote so the new map's opener is not printed twice.
local reroll_announced = false

local reroll_stats = function()
    local yes, total = 0, 0
    for _, vote in pairs(storage.reroll_votes or {}) do
        total = total + 1
        yes = yes + vote
    end
    if total == 0 then return 0, 0, 0 end
    return math.floor(100 * yes / total), yes, total - yes
end

local draw_reroll_gui = function(player)
    if player.gui.top[REROLL_FRAME] then return end
    local frame = player.gui.top.add{type = "frame", name = REROLL_FRAME}
    local flow = frame.add{type = "flow", name = "flow", direction = "horizontal"}
    local caption = flow.add{type = "label", name = "reroll_caption", caption = {"ld-reroll-caption", storage.reroll_time_left}}
    caption.style.minimal_width = 120
    caption.style.maximal_width = 120
    local no_button = flow.add{type = "button", name = REROLL_NO, caption = "No", style = "red_back_button"}
    no_button.style.minimal_width = 56
    no_button.style.maximal_width = 56
    local yes_button = flow.add{type = "button", name = REROLL_YES, caption = "Yes", style = "confirm_button"}
    yes_button.style.minimal_width = 56
    yes_button.style.maximal_width = 56
    local percent, yes_votes, no_votes = reroll_stats()
    flow.add{type = "label", name = "reroll_stats", caption = {"ld-reroll-stats", no_votes, yes_votes, percent}}
end

local stop_reroll_vote = function()
    storage.reroll_votes = nil
    storage.reroll_time_left = nil
    for _, player in pairs(game.players) do
        local frame = player.gui.top[REROLL_FRAME]
        if frame then frame.destroy() end
    end
end

local start_reroll_vote = function()
    storage.reroll_votes = {}
    storage.reroll_time_left = REROLL_DURATION
    -- After a passed reroll the result line already told players the vote is
    -- open again, so the opener would just repeat it a moment later.
    if not reroll_announced then
        game.print({"ld-announcement", {"ld-reroll-start"}})
    end
    reroll_announced = false
    for _, player in pairs(game.connected_players) do
        draw_reroll_gui(player)
    end
end

-- Ballot counts, not a percentage: the denominator is whoever voted, not
-- everyone online, and "1 of 1" should read as the thin win it is. The
-- announcement names the rule that decided it, because the two bars differ and
-- players should not have to guess which applied: a ballot settles the vote on
-- a majority of everyone connected, the timer on a majority of ballots cast.
-- reason is "majority", "timeout" or "closed" (an admin ending it).
local pass_reroll_vote = function(reason)
    local _, yes, no = reroll_stats()
    reroll_announced = true
    game.print({"ld-announcement", {"ld-reroll-pass-" .. reason, yes, yes + no, REROLL_DURATION}})
    stop_reroll_vote()
    Public.perform_reset(nil)
end

-- Nobody voting and an admin calling it off are both failures that no majority
-- produced, so they get their own words rather than the timeout's.
local fail_reroll_vote = function(reason)
    local _, yes, no = reroll_stats()
    if reason ~= "closed" and yes + no == 0 then
        reason = "empty"
    end
    game.print({"ld-announcement", {"ld-reroll-fail-" .. reason, yes, yes + no}})
    stop_reroll_vote()
end

-- Static per-second driver: no-op without an active vote, so no .on_load
-- re-arming is needed (module scope re-executes every session).
local on_reroll_second = function()
    if not storage.reroll_votes then return end
    storage.reroll_time_left = storage.reroll_time_left - 1
    if storage.reroll_time_left > 0 then
        local percent, yes_votes, no_votes = reroll_stats()
        for _, player in pairs(game.connected_players) do
            local frame = player.gui.top[REROLL_FRAME]
            if frame and frame.valid then
                frame.flow.reroll_caption.caption = {"ld-reroll-caption", storage.reroll_time_left}
                frame.flow.reroll_stats.caption = {"ld-reroll-stats", no_votes, yes_votes, percent}
            end
        end
        return
    end
    local _, yes_votes, no_votes = reroll_stats()
    if yes_votes * 2 > yes_votes + no_votes then
        pass_reroll_vote("timeout")
    else
        fail_reroll_vote("timeout")
    end
end

-----------------------------------------------------------------------
-- Loss: the enemy nest lands on the spawn point. Instead of resetting
-- mid-tick we cut everyone to a flyover of what they built (shaped like the
-- crash-site intro everyone knows) and stop the fight once the flyover ends
-- (entities show "disabled by script", the same lever Biter Battles pulls on
-- a lost match), then reset DEFEAT_COUNTDOWN seconds later.
local DEFEAT_COUNTDOWN = 60
local SPAWN_BOX = {left_top = {x = -32, y = -32}, right_bottom = {x = 32, y = 32}}

-- Entity "type" is the only generic axis in EntitySearchFilters, and this
-- build splits it: turrets are "ammo-turret"/"electric-turret"/
-- "fluid-turret"/"artillery-turret"/"turret", and the worm enemies are
-- "unit"/"spider-unit"/"segmented-unit"/"unit-spawner". There is no single
-- generic turret type and no prototypes.turret here, so both families are
-- derived from the prototypes.
local TURRET_TYPES, ENEMY_TYPES = {}, {}
for _, prototype in pairs(prototypes.entity) do
    if prototype.type:find("turret") then
        TURRET_TYPES[#TURRET_TYPES + 1] = prototype.type
    elseif prototype.type:find("unit") then
        ENEMY_TYPES[#ENEMY_TYPES + 1] = prototype.type
    end
end

local FREEZE_FILTERS = {
    -- The swarm and its nests stop producing, every turret stops shooting:
    -- the nest's own worm turrets are what kills the base during the pause,
    -- and a stray player turret can shoot the nest apart.
    {type = ENEMY_TYPES, force = "enemy"},
    {type = TURRET_TYPES},
}

local freeze_all = function()
    local matched = 0
    for _, filter in ipairs(FREEZE_FILTERS) do
        local entities = game.surfaces[1].find_entities_filtered(filter)
        matched = matched + #entities
        for _, entity in pairs(entities) do
            entity.disabled_by_script = true
        end
    end
    return matched
end

-- Returns true when at least one player got the camera.
local watch_spawn_cutscene = function(nest)
    -- Crash-site intro, retargeted: glide onto what they built, then pull
    -- back. Worm turrets are skipped -- the nests are
    -- what triggers the loss. No start_position: the engine starts each
    -- cutscene at that player's own position, so everyone pans in from
    -- wherever they happen to be standing.
    local center = {x = 0, y = 0}
    for _, entity in pairs(nest) do
        center.x = center.x + entity.position.x
        center.y = center.y + entity.position.y
    end
    if #nest > 0 then
        center.x, center.y = center.x / #nest, center.y / #nest
    end
    -- Two steps: glide in on the nest at close zoom, then pull back to the
    -- wide shot fast and linger there -- that long wait is where players
    -- watch the swarm come apart, since the enemies keep fighting through
    -- the cutscene (freeze_all waits for it to end).
    local waypoints = {
        {position = center, zoom = 2, transition_time = 200, time_to_wait = 60},
        {position = center, zoom = 0.5, transition_time = 125, time_to_wait = 480},
    }
    local shown = false
    for _, player in pairs(game.connected_players) do
        if player.character and player.character.valid and not jail.is_jailed(player.name) then
            player.set_controller{type = defines.controllers.cutscene, start_zoom = 2, waypoints = waypoints}
            shown = true
            -- Same hint vanilla shows on the crash-site cutscene; TAB exits.
            -- Reused when still present: a second loss while the cutscene
            -- never ended threw "already present in the parent element",
            -- which aborted the rest of the sequence (the countdown update).
            if not player.gui.screen["ld_skip_hint"] then
                player.gui.screen.add{type = "label", caption = {"skip-cutscene"}, name = "ld_skip_hint"}
            end
        end
    end
    return shown
end

local exit_cutscene = function(player)
    if player and player.valid and player.controller_type == defines.controllers.cutscene then
        player.exit_cutscene()
    end
end

-- TAB, then out of the cutscene. The input itself is base data
-- (crash-site-skip-cutscene, enabled_while_in_cutscene), vanilla just
-- registers a handler.
local on_skip_cutscene = function(event)
    exit_cutscene(game.get_player(event.player_index))
end

local on_cutscene_end = function(event)
    local player = game.get_player(event.player_index)
    local hint = player and player.valid and player.gui.screen["ld_skip_hint"]
    if hint then hint.destroy() end
    -- Freeze once the last player is out of the cutscene (skips count).
    if not storage.defeat_in then return end
    for _, other in pairs(game.connected_players) do
        if other.controller_type == defines.controllers.cutscene then return end
    end
    freeze_all()
end

-- Shared by the trigger below and control.lua's /defeat test command, which
-- hands it a synthetic event so the test runs the real path.
-- control.lua's /close-vote: admins end the vote and keep the map, the same
-- way Biter Battles' /difficulty-close-vote works -- a command, not a button.
Public.close_reroll_vote = function()
    if not storage.reroll_votes then return false end
    fail_reroll_vote("closed")
    return true
end

Public.on_biter_base_built = function(event)
    local position = event.entity.position
    if (position.x > -34 and position.x < 34 and position.y > -34 and position.y < 34) then
        game.print({"ld-announcement", {"ld-defeat-imminent"}})
        local nest = game.surfaces[1].find_entities_filtered{area = SPAWN_BOX, type = {"turret", "unit-spawner"}}
        -- Both widgets live at the top of the screen, and a loss can land
        -- while a reroll vote is still open. The vote is moot: the countdown
        -- ends in a reset, which opens a fresh one.
        stop_reroll_vote()
        if storage.defeat_in then return end
        storage.defeat_in = DEFEAT_COUNTDOWN
        log(string.format("event=defeat, position=%.1f,%.1f, seconds=%d", position.x, position.y, DEFEAT_COUNTDOWN))
        -- The swarm keeps fighting through the cutscene; on_cutscene_end
        -- freezes it. Nobody to show it to (all in the gulag) -> freeze now.
        if not watch_spawn_cutscene(nest) then
            freeze_all()
        end
        update_defeat_countdown(DEFEAT_COUNTDOWN)
    end
end

local on_defeat_second = function()
    if not storage.defeat_in then return end
    storage.defeat_in = storage.defeat_in - 1
    if storage.defeat_in > 0 then
        update_defeat_countdown(storage.defeat_in)
        return
    end
    storage.defeat_in = nil
    -- Cutscene still running when the map goes: hand control back first.
    for _, player in pairs(game.connected_players) do
        exit_cutscene(player)
    end
    Public.perform_reset()
end

-- Static per-second driver (module scope re-executes every session, so no
-- .on_load re-arming); no-op unless a loss is pending. The reroll vote shares
-- it: one handler per tick count, so a second script.on_nth_tick(60, ...) here
-- would replace this one and freeze the vote instead.
local on_periodic_second = function()
    on_reroll_second()
    on_defeat_second()
end
script.on_nth_tick(60, on_periodic_second)
-----------------------------------------------------------------------
local on_reroll_click = function(event)
    if not storage.reroll_votes then return end
    if not (event.element and event.element.valid) then return end
    if event.element.name ~= REROLL_YES and event.element.name ~= REROLL_NO then return end
    local player = game.get_player(event.player_index)
    if not (player and player.valid) then return end
    storage.reroll_votes[player.name] = (event.element.name == REROLL_YES) and 1 or 0
    -- A strict majority of connected players either way decides the vote at
    -- once: the remaining ballots can no longer flip the result. The timer
    -- below is the looser bar (majority of ballots cast), hence the early flag
    -- that tells the two apart in the announcement.
    local yes, no = 0, 0
    for _, vote in pairs(storage.reroll_votes) do
        if vote == 1 then yes = yes + 1 else no = no + 1 end
    end
    if yes * 2 > #game.connected_players then
        pass_reroll_vote("majority")
    elseif no * 2 > #game.connected_players then
        fail_reroll_vote("majority")
    end
end

local on_reroll_join = function(event)
    if not storage.reroll_votes then return end
    local player = game.get_player(event.player_index)
    if player and player.valid then draw_reroll_gui(player) end
end

local on_surface_cleared = function(event)
    if event.surface_index == 1 then
    storage.nesting_spot = {{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0}}
    storage.quality = "legendary"
    storage.recently_reset = "true"
    storage.strafer = "behemoth-spitter"
    storage.stomper = "behemoth-spitter"
    storage.victory = false
    storage.evo_stage = 0
    storage.temporary_group = {}
    -- Saves that predate the freeze group, and no acting player to be refused by
    -- when it has to be created.
    groups.ensure_groups()
    -- Re-assert the tier policy every round: restrict_players otherwise only
    -- runs in setup_first_round, so a change to the deny lists would never
    -- reach a save that already had its first round.
    groups.restrict_players()
    storage.defeat_in = nil
    -- Evolution restarts: drop the apex entry synchronously so saves stay
    -- joinable (a sentinel healed by the minute tick would leave a
    -- poisoned-filter window).
    storage.apex_spitter = nil
    script.set_event_filter(defines.events.on_entity_died, Public.apex_filter(nil))
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
    stop_defeat_countdown()
    start_reroll_vote()
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
local setup_first_round = function(player)
    if storage.init_ran then return end
    storage.init_ran = true

    game.forces["enemy"].friendly_fire = false
    groups.restrict_players()
    -- Spectate mode is a runtime toggle (/spectate-mode on|off), not the
    -- starting state: fresh games play normally and perform_reset turns it
    -- off. Group membership lives in the save, so an old spectate-on save
    -- stays spectating until an admin runs /spectate-mode off once.

    if not storage.disable_crashsite then
        local surface = player.surface
        Public.setup_starting_area(surface)
    end
end

-- Rebuild the crash site for the first respawn after a reset. The kit is not
-- given here: it is the same as the ordinary death kit, so freeplay grants it
-- on every respawn and giving it twice would hand over two pistols.
local on_first_respawn = function(player)
    local surface = game.surfaces[1]
    Public.setup_starting_area(surface)
    game.forces["enemy"].friendly_fire = false
    -- Cleanup platforms that have no surface
    for _, platform in pairs(game.forces["player"].platforms) do
    platform.destroy(1)
    end
end

-- Wipes and regenerates all main surfaces with a fresh seed. Called by
-- control.lua's /reset command (with the acting player) and by freeplay.lua
-- on defeat conditions.
Public.perform_reset = function(actor, seed)
    -- Spectate mode is off between rounds: everybody plays, and a
    -- round that started with it on (admin toggle, or an older save) leaves
    -- nobody frozen after the reset.
    groups.disable_default_spectate()

    -- actor: player name (or "server" for console) for manual /reset runs,
    -- nil for automatic resets. Manual resets are inferred by the presence
    -- of the actor field. seed: optional map seed, random when nil.
    local trigger = actor and (", actor=" .. actor) or ""
    local science = game.forces["player"].get_item_production_statistics(1).get_input_count "science"
    local minutes = math.floor(game.ticks_played / 3600)
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
    -- Apply the seed after clearing so it is the setting used for the new chunks.
    seed = change_seed(seed)
    log(string.format("event=map-reset%s, seed=%d, victory=%s, science=%d, minutes=%d",
        trigger,
        seed,
        tostring(storage.victory),
        science,
        minutes))
    -- We delete space platforms
    for _, surface in pairs(game.surfaces) do
        if surface.platform then
            game.delete_surface(surface)
        end
    end
end

-- Event/lib declarations: event_handler.add_lib reads these and ignores
-- every other field, so public functions coexist here safely.
Public.events =
{
    -- The first respawn after a reset is when the crash site goes back up: the
    -- surface was wiped and nothing rebuilds it until someone spawns. The flag
    -- is ours and only ours -- freeplay used to read it to choose a kit, and
    -- with one kit there is nothing left to agree on.
    [defines.events.on_player_respawned] = function(event)
        local player = game.get_player(event.player_index)
        if not (player and player.valid and storage.recently_reset == "true") then
            return
        end
        storage.recently_reset = "false"
        on_first_respawn(player)
    end,

    -- The first round's setup, on the first player to exist. It was a call out
    -- of freeplay's on_player_created, which only made sense under the belief
    -- that one module may register an event; the event_handler fans out to both
    -- and this one's guard (storage.init_ran) is its own business.
    [defines.events.on_player_created] = function(event)
        local player = game.get_player(event.player_index)
        if player and player.valid then
            setup_first_round(player)
        end
    end,
  [defines.events.on_surface_created] = on_surface_created,
  [defines.events.on_pre_surface_cleared] = on_pre_surface_cleared,
  [defines.events.on_surface_cleared] = on_surface_cleared,
  [defines.events.on_biter_base_built] = Public.on_biter_base_built,
  ["crash-site-skip-cutscene"] = on_skip_cutscene,
  [defines.events.on_cutscene_finished] = on_cutscene_end,
  [defines.events.on_cutscene_cancelled] = on_cutscene_end,
  [defines.events.on_gui_click] = on_reroll_click,
  [defines.events.on_player_joined_game] = on_reroll_join,
}
Public.on_init = function()
    ensure_crash_loot()
    storage.recently_reset = "false"
end
Public.on_configuration_changed = function() ensure_crash_loot() end
-- Re-register the tick handler after a save/load if a reveal was in flight,
-- since dynamic event registrations don't survive loading.
Public.on_load = function()
    if storage.reveal_index then
        script.on_event(defines.events.on_tick, on_tick_reveal)
    end
end

return Public

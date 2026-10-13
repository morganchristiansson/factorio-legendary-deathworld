-- Map reset and dual-surface swap.
-----------------------------------------------------------------------
-- The round alternates between two secondary surfaces ("nauvis1" and
-- "nauvis2") hosted on the planet "nauvis2" (provided by a planet in the
-- server's EverythingOnNauvis fork, unlocked for the player force so its
-- surfaces group under it in the surfaces list; the vanilla "nauvis" planet
-- and its primary surface are a permanent dummy, since the primary cannot
-- be deleted). Public.perform_reset() moves everyone onto a fresh surface and
-- deletes the old one -- the only way to disassociate a surface from its
-- hosting planet -- then on_surface_deleted re-associates the fresh surface
-- and stands the round up. No player dies, so a reset no longer spams the log
-- with the engine's "X respawned" lines. The reroll (and defeat) countdown
-- pre-generates the dormant surface slowly, so the next swap lands on a
-- mostly-built map instead of re-hitching on a fresh reveal; control.lua's
-- /reset command and freeplay.lua both call perform_reset(). The staged
-- reveal replaces the old behaviour of generating + charting ~1500 chunks in
-- a single tick, which froze the server for seconds after every reset.
-----------------------------------------------------------------------
-- Public interface:
--   Public.perform_reset(actor, seed) - move the round off the active surface onto the dormant surface
--   Public.setup_starting_area(surf) - reveal + crash site + spawn defences
--   Public.current_surface()          - the host planet's current surface
--   Public.is_swap_surface(surf)     - swap-pair surface (active or dormant;
--   (the dummy primary is never the current surface on a fresh save)
-- Reroll vote opens automatically at the end of a swap (on_surface_deleted).

local util = require("util")
local crash_site = require("crash-site")
local jail = require("jail")
local groups = require("groups")
local register = require("register")

local Public = {}

-----------------------------------------------------------------------
-- The round alternates between two secondary surfaces (nauvis1/nauvis2)
-- hosted on the planet "nauvis2", which the server's EverythingOnNauvis
-- fork provides (a hidden-free copy of the nauvis planet prototype). The
-- vanilla "nauvis" planet and its primary surface are a permanent dummy: the
-- primary cannot be deleted, so it can never be disassociated -- only
-- surfaces on planet nauvis2 ever become the current surface. The swap
-- deletes the old current surface (which disassociates it from the planet --
-- the only way) and the fresh one is associated in the swap's second half.
-- The round planet is unlocked for the player force so it appears in the
-- surfaces list as a planet (undiscovered planets bucket their surfaces
-- under "Other"), and travel to it lands on the current surface itself.
local PLANET = "nauvis2"
local SURFACES = {"nauvis1", "nauvis2"}

-- The surface the current round plays on: the host planet's associated
-- surface. The name fallbacks cover the two-tick window between the old
-- surface's deletion and the new one's association, where the planet has no
-- surface. A save whose planet has no surface and no swap-pair surface
-- (i.e. stranded on the undeletable primary) is unsupported -- start a
-- new game.
Public.current_surface = function()
    local planet = game.planets[PLANET]
    if planet and planet.surface and planet.surface.valid then
        return planet.surface
    end
    for _, name in ipairs(SURFACES) do
        local surface = game.surfaces[name]
        if surface then return surface end
    end
end

-- A swap-pair surface: either of the two surfaces that take turns as the
-- active surface on the host planet (dormant during the reroll countdown's
-- pre-generation, before it is associated). nauvis (the primary) is the
-- undeletable dummy default, not a swap-pair member, so it is excluded from
-- the chunk-upgrade whitelist -- guards freeplay's chunk upgrade.
Public.is_swap_surface = function(surface)
    return surface.name == SURFACES[1] or surface.name == SURFACES[2]
end

local current_surface = Public.current_surface
local next_surface_name = function(name)
    if name == SURFACES[1] then return SURFACES[2] end
    if name == SURFACES[2] then return SURFACES[1] end
    return SURFACES[1] -- an unknown/previous name starts at the first swap surface
end

-- The worldgen template lives in storage so it can be adjusted and
-- future rounds inherit the adjustment: a runtime create_surface inherits
-- nothing on its own -- the planet prototype is read-only at runtime
-- (probe: "No modifications of LuaSpaceLocationPrototype"), so the template
-- is deep-copied from the clone proto, which already carries the launch
-- flag's merged worldgen -- terrain binds, entity settings, territory,
-- climate controls, every autoplace control including proto-only ones like
-- ammonia_ocean, and all property_expression_names (probe 2.0.77, live boot
-- path: game.default_map_gen_settings and the planet prototype carry the
-- same 10 property binds with the flag's values). Map tuning lives in
-- factorio/data/map-gen-settings.json, the canonical source: the flag
-- merges it into the proto, and the overlay below keeps the flag's
-- autoplace_controls, enable-all and starting area winning on overlap.
-- tools/apply-map-settings patches the same storage table, so live
-- adjustments carry into the next round.
local init_map_gen_settings = function(surface)
    -- One deep copy of the clone proto: the fork's complete worldgen --
    -- terrain binds, entity settings, territory, climate controls and every
    -- autoplace control, including proto-only ones like ammonia_ocean that
    -- the launch config never lists.
    local planet = game.planets[PLANET]
    local proto = planet and planet.prototype and planet.prototype.map_gen_settings
        or surface and surface.map_gen_settings
    local mgs = table.deepcopy(proto) or {}
    mgs.autoplace_controls = mgs.autoplace_controls or {}
    -- Overlay the launch config's retained fields: its autoplace_controls
    -- (frequencies, gleba_enemy_base, scrap, water), enable-all and the
    -- starting area. Flag values win on overlap; controls only the proto
    -- carries keep the proto's values. The merge runs both ways by design
    -- (probe 2.0.77): the flag supplies gleba_enemy_base, which the proto
    -- lacks, while the proto keeps its mod-merged specifics the flag never
    -- lists -- ammonia_ocean, the 7-unit demolisher territory, nauvis_cliff
    -- and smoothing 0 -- so neither source alone is complete.
    local preset = game.default_map_gen_settings
    if preset then
        -- Add-or-merge into mgs's own (plain) tables: flag values win on
        -- overlap, controls only the proto carries keep the proto's values.
        -- (table.deepcopy of engine LuaStructs is safe -- the probe shows it
        -- yields plain detached tables, no metatable -- but add-or-merge is
        -- simpler: control values are plain numbers.)
        for ctrl, vals in pairs(preset.autoplace_controls or {}) do
            local slot = mgs.autoplace_controls[ctrl]
            if slot == nil then
                slot = {}
                mgs.autoplace_controls[ctrl] = slot
            end
            for k, v in pairs(vals) do slot[k] = v end
        end
        if preset.default_enable_all_autoplace_controls ~= nil then
            mgs.default_enable_all_autoplace_controls = preset.default_enable_all_autoplace_controls
        end
        if preset.starting_area ~= nil then
            mgs.starting_area = preset.starting_area
        end
    end
    -- Property binds need no Lua overrides: the proto copy above already
    -- holds the flag's property_expression_names, so the JSON file stays
    -- the single source of map tuning.
    storage.map_gen_settings = mgs
    return mgs
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
    -- The reveal survives a save/load, and its surface can be deleted by a
    -- /reset that lands mid-reveal: stop instead of charting a ghost.
    local surface = game.surfaces[storage.reveal_surface]
    if not surface then
        storage.reveal_index = nil
        register.disarm("map-reveal")
        return
    end
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
        game.forces["player"].chart_all(surface)
        -- Total wall time of the reveal. divide() would give ms-per-chunk but
        -- takes no argument in this build (self only), same as add(). The
        -- profiler is a Lua object, so it does not survive a save: on_load
        -- re-arms this handler for a reveal that was in flight, and without
        -- one there is nothing to time. The cleanup below must not depend on
        -- it -- raising here would leave the handler registered and the index
        -- set, charting the whole map every tick for the rest of the game.
        if reveal_total then
            reveal_total.stop()
            log({"", "event=map-reveal, wall", reveal_total})
            reveal_total = nil
        end
        storage.reveal_index = nil
        register.disarm("map-reveal")
    else
        storage.reveal_index = index
    end
end
-- The reveal owns the single on_tick slot; register re-arms it on load from
-- the stored active state.
register.on_tick("map-reveal", on_tick_reveal)

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
    -- A fully pre-generated dormant surface has no staged reveal to run: its
    -- terrain already exists (the pre-gen walks centre-out, so a generated
    -- far corner means the whole map is done), so a single chart pass shows
    -- the entire map at once instead of a 3s+ filling walk.
    if surface.is_chunk_generated(reveal_order[#reveal_order]) then
        game.forces["player"].chart_all(surface)
        return
    end
    storage.reveal_surface = surface.name
    storage.reveal_index = 1
    reveal_total = game.create_profiler()
    reveal_total.restart()
    register.arm("map-reveal")
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
        local surface = current_surface()
        local turret = surface.create_entity{name="gun-turret",position={-7,2},force="player", quality = "legendary"}
        turret.insert{name="firearm-magazine",count=100,quality="legendary"}
        local wall = surface.create_entity
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

-----------------------------------------------------------------------
-- Dormant-surface pre-generation: while the reroll vote (or the defeat
-- countdown) runs, the next round's surface is created and its chunks forced
-- out of the engine slowly, so the swap lands on a mostly-built map instead
-- of hitching on a fresh reveal. The round's own reveal has priority: this
-- batch only runs when the reveal is idle, and it is its own tick cadence
-- (31), so it never shares an on_tick/on_nth_tick slot with the reveal or the
-- per-second drivers. The seed is rolled here with the surface, so whatever
-- the next round becomes, its chunks and its seed agree. Pre-generation runs
-- only while a reroll vote or the defeat countdown is open; it never builds
-- a dormant surface outside those windows, so no map sits parked in memory
-- for the bulk of a round.
-- One persistent driver (3 ticks) drives both pre-gen profiles from storage
-- state -- no temporary on_nth_tick registrations, so save/load can never
-- trip the script-event mismatch check. Reroll fast mode batches 3 chunks a
-- fire (~1 chunk/tick, map ready in ~24s); the defeat countdown batches 1
-- (~0.33/tick, tracking its 60s window). The driver is registered once at
-- module scope like the per-second driver, and no-ops unless a countdown
-- is actually running.
local PREGEN_CHUNKS_REROLL = 3
local PREGEN_CHUNKS_COUNTDOWN = 1

local on_pregen_tick = function()
    if storage.reveal_index or not storage.pregen_surface or not storage.pregen_index then return end
    local surface = game.surfaces[storage.pregen_surface]
    if not surface then
        -- the dormant surface was deleted (a reroll vote just failed): the
        -- markers are cleared and the driver idles again
        storage.pregen_surface = nil
        storage.pregen_index = nil
        return
    end
    local chunks = storage.pregen_chunks or PREGEN_CHUNKS_COUNTDOWN
    local index = storage.pregen_index
    local limit = math.min(index + chunks - 1, #reveal_order)
    for i = index, limit do
        local c = reveal_order[i]
        surface.request_to_generate_chunks({c[1] * 32, c[2] * 32}, 0)
    end
    surface.force_generate_chunk_requests()
    index = limit + 1
    if index > #reveal_order then
        -- Full coverage: stop working, but keep the dormant name so a vote
        -- that fails after pre-generation completed can still delete it.
        storage.pregen_index = nil
    else
        storage.pregen_index = index
    end
end
-- The persistent driver; registered at module scope so it re-executes every
-- session and needs no on_load re-arming.
script.on_nth_tick(3, on_pregen_tick)

local start_pregen = function(chunks)
    if storage.pregen_surface then return end
    local source = current_surface()
    local name = next_surface_name(source.name)
    if game.surfaces[name] then return end
    local mgs = storage.map_gen_settings or init_map_gen_settings(source)
    mgs.seed = math.random(1111, 4294967295)
    storage.next_seed = mgs.seed
    game.create_surface(name, mgs)
    -- Keep the pre-building map off the surfaces list; it is un-hidden when
    -- the swap adopts it.
    game.forces["player"].set_surface_hidden(name, true)
    storage.pregen_surface = name
    storage.pregen_index = 1
    storage.pregen_chunks = chunks
end

local cancel_pregen = function()
    local name = storage.pregen_surface
    if not name then return end
    storage.pregen_surface = nil
    storage.pregen_index = nil
    storage.next_seed = nil
    local surface = game.surfaces[name]
    if surface and not surface.planet then
        game.delete_surface(surface)
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
    -- Pre-generate the next round's surface while the vote runs; the batch
    -- driver idles until the round's own reveal has finished. Aggressive
    -- rate: rerolls can resolve early and the map must be ready when they do.
    start_pregen(PREGEN_CHUNKS_REROLL)
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
    -- The kept map wins; the pre-generated next surface is thrown away. It
    -- gets re-created when the next countdown opens.
    cancel_pregen()
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
-- crash-site intro everyone knows) and reset DEFEAT_COUNTDOWN seconds
-- later. Clearing the nests in the box before that lands cancels the whole
-- thing -- the round goes back on, and a colony that comes back starts it
-- again.
local DEFEAT_COUNTDOWN = 60
-- Three nests and worms in the box is a colony, four is a loss.
local DEFEAT_BASE_COUNT = 3
local SPAWN_BOX = {left_top = {x = -32, y = -32}, right_bottom = {x = 32, y = 32}}

-- The colony in the box: nests and enemy worm turrets. Player turrets are
-- the defence being overrun, not part of the colony -- the force filter is
-- what keeps them out, since gun/laser turrets share the "turret" type with
-- the worms.
local base_in_spawn_box = function()
    return current_surface().find_entities_filtered{area = SPAWN_BOX, type = {"turret", "unit-spawner"}, force = "enemy"}
end

-- The widest shot the engine still renders as the world instead of
-- simplified map blocks: a fixed limit, not something to derive per player.
-- It doubles as the cutscene's chart_mode_cutoff, so the flyout stays on the
-- rendered world whatever the cutscene controller would default to.
local WIDE_ZOOM = 0.25

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
    -- the cutscene.
    local waypoints = {
        {position = center, zoom = 2, transition_time = 200, time_to_wait = 60},
        {position = center, zoom = WIDE_ZOOM, transition_time = 125, time_to_wait = 480},
    }
    for _, player in pairs(game.connected_players) do
        if player.character and player.character.valid and not jail.is_jailed(player.name) then
            player.set_controller{type = defines.controllers.cutscene, start_zoom = 2,
                chart_mode_cutoff = WIDE_ZOOM, waypoints = waypoints}
            -- Same hint vanilla shows on the crash-site cutscene; TAB exits.
            -- Reused when still present: a second loss while the cutscene
            -- never ended threw "already present in the parent element",
            -- which aborted the rest of the sequence (the countdown update).
            if not player.gui.screen["ld_skip_hint"] then
                player.gui.screen.add{type = "label", caption = {"skip-cutscene"}, name = "ld_skip_hint"}
            end
        end
    end
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
end

-- Nests cleared before the countdown ran out: the loss is off and everyone the
-- cutscene took gets their character back. No marker of our own -- a colony
-- that comes back runs the trigger below from scratch, cutscene included.
local cancel_defeat = function(base)
    storage.defeat_in = nil
    stop_defeat_countdown()
    for _, player in pairs(game.connected_players) do
        exit_cutscene(player)
    end
    game.print({"ld-announcement", {"ld-defeat-cancelled"}})
    log(string.format("event=defeat-cancelled, entities=%d", base))
end

-- Re-checks the spawn box after a nest dies. on_biter_base_built only fires
-- for migrations, so this is called from on_post_entity_died in freeplay to
-- cancel an active countdown when nests are cleared before it expires.
Public.check_defeat_cancel = function()
    if not storage.defeat_in then return end
    local base = base_in_spawn_box()
    if #base < DEFEAT_BASE_COUNT then
        cancel_defeat(#base)
    end
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
    -- Raised when a migration builds a base (not on entity death), so this
    -- handler only starts the loss. Cancellation mid-countdown is handled by
    -- check_defeat_cancel, called from on_post_entity_died when a nest dies.
    local base = base_in_spawn_box()
    if storage.defeat_in then
        if #base < DEFEAT_BASE_COUNT then
            cancel_defeat(#base)
        end
        return
    end
    -- The entity is gone by the time a base dies, so its position is only
    -- read on the build side.
    local position = event.entity.position
    if position.x <= -34 or position.x >= 34 or position.y <= -34 or position.y >= 34 then
        return
    end
    -- Raised once for every biter sacrificed to build a base, so this fires
    -- per entity, not per base: every build near spawn repeats the warning,
    -- and a count that reaches the loss line starts the countdown. There is
    -- no clock below the line: the early game lost on the first entity to
    -- land, which ended rounds nobody had a chance in, so a swarm piles up.
    game.print({"ld-announcement", {"ld-defeat-imminent"}})
    if #base < DEFEAT_BASE_COUNT then
        return
    end
    -- Both widgets live at the top of the screen, and a loss can land
    -- while a reroll vote is still open. The vote is moot: the countdown
    -- ends in a reset, which opens a fresh one.
    stop_reroll_vote()
    -- Pre-generate the next surface during the countdown too, at the gentler
    -- rate tuned to the 60s window. If a reroll vote was running, that faster
    -- pre-gen simply carries on; start_pregen guards that.
    start_pregen(PREGEN_CHUNKS_COUNTDOWN)
    storage.defeat_in = DEFEAT_COUNTDOWN
    log(string.format("event=defeat, position=%.1f,%.1f, entities=%d, seconds=%d",
        position.x, position.y, #base, DEFEAT_COUNTDOWN))
    -- The swarm keeps fighting through the cutscene and after it: nothing is
    -- frozen, the round is simply on the clock.
    watch_spawn_cutscene(base)
    update_defeat_countdown(DEFEAT_COUNTDOWN)
end

local on_defeat_second = function()
    if not storage.defeat_in then return end
    storage.defeat_in = storage.defeat_in - 1
    if storage.defeat_in > 0 then
        update_defeat_countdown(storage.defeat_in)
        return
    end
    storage.defeat_in = nil
    -- perform_reset hands cutscene control back before moving anyone.
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

-- The swap's second half: associate the fresh surface with the planet (which
-- makes it the current surface), reset the round state and stand the round
-- up. Called from on_surface_deleted once the prev surface's deletion frees
-- the host planet; finish_surface_swap is idempotent, so re-entry is safe.
local finish_surface_swap = function(surface)
    local planet = game.planets[PLANET]
    if planet and not planet.surface then
        planet.associate_surface(surface)
    end
    -- The current surface belongs on the surfaces list; a dormant surface
    -- hidden during pre-generation is revealed here.
    game.forces["player"].set_surface_hidden(surface.name, false)
    storage.current_surface = surface.name
    storage.nesting_spot = {{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0}}
    storage.quality = "legendary"
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
    register.set_filter(defines.events.on_entity_died, Public.apex_filter(nil))
    game.map_settings.enemy_expansion.settler_group_min_size = 8
    game.map_settings.enemy_expansion.settler_group_max_size = 9
    game.map_settings.pollution.enemy_attack_pollution_consumption_modifier = 1
    game.map_settings.enemy_evolution.time_factor = 0.00004
    game.forces["player"].reset()
    -- /set-spawn moves the spawn point; a fresh map starts from the scenario's
    -- own again (the origin the crash site and spawn defences are built at --
    -- 2.0 no longer exposes the map's spawn points to Lua).
    game.forces["player"].set_spawn_position({x = 0, y = 0}, surface)
    game.forces["enemy"].reset()
    game.forces["enemy"].reset_evolution()
    game.forces["enemy"].friendly_fire = false
    game.reset_game_state()
    game.reset_time_played()
    stop_defeat_countdown()
    Public.setup_starting_area(surface)
    -- The new round's reroll vote re-opens the dormant-surface pre-generation
    -- for the round after this one.
    start_reroll_vote()
end

-- The swap's second half, entry point: the old surface is gone and the planet
-- is free again, so the freshly built surface is adopted and the round stood
-- up on it. Any surface deletion reaches this handler, but only the swap's
-- prev-delete leaves the host planet's current surface unadopted, so guard on
-- that rather than on a recorded index.
local on_surface_deleted = function(event)
    local surface = game.surfaces[storage.current_surface]
    local planet = game.planets[PLANET]
    if surface and planet and planet.surface ~= surface then
        finish_surface_swap(surface)
    end
end

local create_crash_site = function(surface)
    crash_site.create_crash_site(surface, {-5,-6}, util.copy(storage.crashed_ship_items), util.copy(storage.crashed_debris_items), util.copy(storage.crashed_ship_parts))
end

-- Everything a fresh round needs at spawn (fresh save or a finished surface
-- swap): staged reveal, crash site, starting turret and nest territory.
Public.setup_starting_area = function(surface)
    ensure_crash_loot()
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

-- One-time setup for the very first round. A fresh save's first round is
-- built on the swap surface created in on_init (the engine spawns the first
-- joiner on the dummy primary, so it is walked over to it). A legacy save
-- stranded on the primary is unsupported -- start a new game instead.
local setup_first_round = function(player)
    if storage.init_ran then return end
    storage.init_ran = true

    game.forces["enemy"].friendly_fire = false
    groups.restrict_players()
    -- Spectate mode is a runtime toggle (/spectate-mode on|off), not the
    -- starting state: fresh games play normally and perform_reset turns it
    -- off. Group membership lives in the save, so an old spectate-on save
    -- stays spectating until an admin runs /spectate-mode off once.

    local surface = current_surface()
    if not storage.disable_crashsite then
        Public.setup_starting_area(surface)
    end
    if player and player.valid then
        local character = player.character
        if character and character.valid then
            character.teleport({0, 0}, surface)
        else
            player.teleport({0, 0}, surface)
        end
    end
end

-- A player who was offline through the swap rejoins with no character (their
-- old one was deleted with the surface) or with one left on a foreign
-- surface; put them back at round spawn with a fresh character and the spawn
-- kit, so the rejoin does not force-generate chunks at a stale position.
-- Jailed players are handled by jail.lua's own join hook and left alone here.
local on_player_joined = function(event)
    on_reroll_join(event)
    local player = game.get_player(event.player_index)
    if not (player and player.valid) or jail.is_jailed(player.name) then return end
    local target = current_surface()
    local character = player.character
    local misplaced = (not character or not character.valid) or player.surface.name ~= target.name
    -- A fresh joiner gets placed unconditionally (bb does the same): at
    -- on_player_joined the engine has not finished deciding the character's
    -- placement, and player.surface can already match the current surface
    -- while the pending spawn still lands on the home planet's dummy surface.
    local fresh = player.online_time == 0
    if fresh or misplaced then
        -- First-timers often arrive with a character already on the dummy
        -- primary; the surface is never deleted, so a detached one would sit
        -- there permanently -- destroy instead of detach (bb does the same).
        if character and character.valid then
            player.character.destroy()
        end
        -- /set-spawn moves the force spawn point; new joiners land there
        -- (same as death respawns), not hardcoded at the origin.
        local spawn_pos = game.forces["player"].get_spawn_position(target)
        player.teleport(spawn_pos, target)
        local spawn = target.find_non_colliding_position("character", spawn_pos, 4, 0.5) or spawn_pos
        local fresh = target.create_entity{name = "character", position = spawn, force = "player"}
        if fresh then
            player.set_controller{type = defines.controllers.character, character = fresh}
            util.insert_safe(player, storage.created_items)
        end
    end
end

-- Moves the round off the active surface onto the dormant surface: it is created fresh (or adopted
-- pre-generated by the reroll countdown) and everyone not jailed is moved
-- onto it -- characters detached first, so no death event and no respawn log
-- line -- then the old surface is deleted, the one way to disassociate it
-- from the planet. on_surface_deleted re-associates the fresh surface and
-- stands the round up. Inventories do not survive: the old character is
-- destroyed with its surface and the new one starts from the spawn kit.
-- Called by control.lua's /reset command (with the acting player) and by
-- freeplay.lua on defeat conditions.
Public.perform_reset = function(actor, seed)
    -- Spectate mode is off between rounds: everybody plays, and a
    -- round that started with it on (admin toggle, or an older save) leaves
    -- nobody frozen after the reset.
    groups.disable_default_spectate()

    -- A reset can land while the defeat cutscene still holds players, and a
    -- cutscene teleport never leaves the old surface: the character hand-off
    -- below would then die on a surface mismatch. Hand control back first.
    for _, player in pairs(game.connected_players) do
        exit_cutscene(player)
    end

    -- actor: player name (or "server" for console) for manual /reset runs,
    -- nil for automatic resets. Manual resets are inferred by the presence
    -- of the actor field. seed: optional map seed, random when nil.
    local trigger = actor and (", actor=" .. actor) or ""
    local science = game.forces["player"].get_item_production_statistics(1).get_input_count "science"
    local minutes = math.floor(game.ticks_played / 3600)

    local prev_surface = current_surface()
    local prev_name = prev_surface.name
    local new_name = next_surface_name(prev_name)
    -- Adopt the countdown's pre-generated dormant surface, or create fresh.
    -- A surface already holding the new name that is NOT the marked dormant is a
    -- stale leftover from a broken earlier swap, complete with the old
    -- round's entities -- wiping it (and an explicit /reset seed does the
    -- same) keeps the next round from piling onto the old crash site.
    local new_surface = game.surfaces[new_name]
    -- One path for every reset: the round gets a seed -- the given one, the
    -- countdown's pre-gen seed (storage.next_seed) when that surface is
    -- adopted, else random -- and the surface under the next round name is
    -- rebuilt from the template unless it already IS that seed's map. Only
    -- the countdown's own dormant surface qualifies (it was generated with
    -- storage.next_seed); anything else -- an explicit /reset seed, a stale
    -- leftover from a broken earlier swap, a pre-gen interrupted and
    -- restarted -- is deleted and created fresh, so a chosen seed really
    -- produces that seed's map and no round piles onto old terrain.
    local new_seed = seed or storage.next_seed or math.random(1111, 4294967295)
    if new_surface and not (storage.pregen_surface == new_name and new_seed == storage.next_seed) then
        game.delete_surface(new_surface)
        new_surface = nil
    end
    if not new_surface then
        local mgs = storage.map_gen_settings or init_map_gen_settings(prev_surface)
        mgs.seed = new_seed
        new_surface = game.create_surface(new_name, mgs)
    end
    storage.pregen_surface = nil
    storage.pregen_index = nil
    storage.next_seed = nil

    -- Ground for the characters and crash site must exist before anyone
    -- lands: the core area is what the staged reveal expands from (and is a
    -- no-op when the surface was pre-generated).
    new_surface.request_to_generate_chunks({0, 0}, REVEAL_CORE_RADIUS)
    new_surface.force_generate_chunk_requests()

    -- Move everyone onto the new surface without a death: detaching the
    -- character leaves it on the old surface, its inventory going down with
    -- the deletion, then a fresh character is raised on the new one with the
    -- spawn kit. Jailed players stay in the pit, which the swap never touches.
    for _, player in pairs(game.connected_players) do
        if not jail.is_jailed(player.name) then
            local character = player.character
            if character and character.valid then
                player.character = nil
            end
            player.teleport({0, 0}, new_surface)
            -- Everyone lands around the spawn point, not on the same tile:
            -- overlapping characters block each other and cannot move apart.
            local spawn = new_surface.find_non_colliding_position("character", {0, 0}, 4, 0.5) or {0, 0}
            local fresh = new_surface.create_entity{name = "character", position = spawn, force = "player"}
            if fresh then
                player.set_controller{type = defines.controllers.character, character = fresh}
                util.insert_safe(player, storage.created_items)
            end
        end
    end

    -- Leftover world surfaces (orbits) are cleared as before; the primary is
    -- skipped automatically (undeletable) and the gulag is left alone, its
    -- floor and walls belong to the pit, and clearing them would kill jailed
    -- players, the one respawn this reset is meant to end.
    for _, surface in pairs(game.surfaces) do
        if not surface.platform
            and surface.deletable
            and surface.name ~= prev_name
            and surface.name ~= new_name
            and surface.name ~= jail.gulag_surface_name then
            surface.clear(true)
        end
    end

    log(string.format("event=map-reset%s, seed=%d, victory=%s, science=%d, minutes=%d",
        trigger,
        new_surface.map_gen_settings.seed,
        tostring(storage.victory),
        science,
        minutes))
    -- Space platforms are deleted; they are surfaces too, so the swap's
    -- deletion tracking picks the current surface out of the pile by index.
    for _, surface in pairs(game.surfaces) do
        if surface.platform then
            game.delete_surface(surface)
        end
    end
    -- Queue the prev surface's deletion: on_surface_deleted fires a tick
    -- or two later, once the planet is free, and finishes the swap there.
    -- (Fresh saves only: prev_surface is a deletable swap-pair surface; a
    -- legacy save stranded on the undeletable primary is unsupported --
    -- start a new game.)
    storage.current_surface = new_name
    game.delete_surface(prev_surface)
end

-- Event/lib declarations: event_handler.add_lib reads these and ignores
-- every other field, so public functions coexist here safely.
Public.events =
{
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
  [defines.events.on_surface_deleted] = on_surface_deleted,
  [defines.events.on_biter_base_built] = Public.on_biter_base_built,
  ["crash-site-skip-cutscene"] = on_skip_cutscene,
  [defines.events.on_cutscene_finished] = on_cutscene_end,
  [defines.events.on_cutscene_cancelled] = on_cutscene_end,
  [defines.events.on_gui_click] = on_reroll_click,
  [defines.events.on_player_joined_game] = on_player_joined,
}
Public.on_init = function()
    -- A fresh game: the current surface is created from the host planet's
    -- worldgen template and associated with the host planet;
    -- setup_first_round builds the starting area and walks the first player
    -- over. Legacy pre-swap saves are unsupported -- start a new game.
    local surface = game.create_surface(SURFACES[1], storage.map_gen_settings or init_map_gen_settings())
    local planet = game.planets[PLANET]
    if planet and not planet.surface then
        planet.associate_surface(surface)
    end
    -- The dummy primary hosts no round; planet.hidden (the fork) only hides it
    -- from the star map, so hide the surface from the surfaces panel the same
    -- way the gulag is hidden. Star-map discovery is the fork's job.
    game.forces["player"].set_surface_hidden(1, true)
    storage.current_surface = surface.name
end

return Public

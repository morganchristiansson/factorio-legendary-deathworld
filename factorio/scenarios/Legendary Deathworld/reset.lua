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
--   Public.perform_reset(actor, seed) - swap the round onto the dormant surface
--   Public.setup_starting_area(surf) - reveal + crash site + spawn defences
--   Public.active_surface()          - the host planet's current surface
--   Public.is_round_surface(surf)    - chunk-gen guard for both round names
-- Reroll vote opens automatically at the end of a swap (on_surface_deleted).
-- A pre-swap save that is still mid-round on the primary keeps playing there
-- until the first reset (perform_reset's migration branch).

local util = require("util")
local mod_gui = require("mod-gui")
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
-- surfaces on planet nauvis2 ever become the active round surface. The swap
-- deletes the old round surface (which disassociates it from the planet --
-- the only way) and the fresh one is associated in the swap's second half.
-- The round planet is unlocked for the player force so it appears in the
-- surfaces list as a planet (undiscovered planets bucket their surfaces
-- under "Other"), and travel to it lands on the round surface itself.
local PLANET = "nauvis2"
local ROUND_SURFACES = {"nauvis1", "nauvis2"}
-- The undeletable primary; a save deployed mid-round still plays on it until
-- the first reset migrates the round over.
local PRIMARY_NAME = "nauvis"

-- The surface the current round plays on: the host planet's associated
-- surface. The name fallbacks cover the two-tick window between the old
-- surface's deletion and the new one's association, where the planet has no
-- surface; the last fallback is the primary, which is where a save that
-- predates the swap still has its round.
Public.active_surface = function()
    local planet = game.planets[PLANET]
    if planet and planet.surface and planet.surface.valid then
        return planet.surface
    end
    for _, name in ipairs(ROUND_SURFACES) do
        local surface = game.surfaces[name]
        if surface then return surface end
    end
    return game.surfaces[1]
end

-- Chunk generation on either round name belongs to the round, including the
-- dormant surface pre-generated during the reroll countdown before it is
-- associated. The primary is included so a pre-swap save still playing on it
-- keeps the legendary-spawner upgrade; it is never deleted, so it never
-- confuses the deletion tracking. Guards freeplay's chunk upgrade.
Public.is_round_surface = function(surface)
    return surface.name == ROUND_SURFACES[1] or surface.name == ROUND_SURFACES[2] or surface.name == PRIMARY_NAME
end

local active_surface = Public.active_surface
local next_round_name = function(name)
    if name == ROUND_SURFACES[1] then return ROUND_SURFACES[2] end
    if name == ROUND_SURFACES[2] then return ROUND_SURFACES[1] end
    return ROUND_SURFACES[1] -- a pre-swap round on the primary (or a pre-rename round) starts here
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
        local surface = active_surface()
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
    local source = active_surface()
    local name = next_round_name(source.name)
    if game.surfaces[name] then return end
    local mgs = source.map_gen_settings
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

-- Every deleted surface fires on_pre_surface_deleted/on_surface_deleted, and
-- only the round surface's deletion is the swap's second half (platforms and
-- a failed pre-gen are not). Track the exact surface being swapped out by
-- name -- not by membership in the round-name set, which would miss a round
-- surface named in an older convention -- so its companion event below picks
-- the right deletion out of the pile.
local on_pre_surface_deleted = function(event)
    local surface = game.surfaces[event.surface_index]
    if surface and surface.name == storage.pending_old_name then
        storage.pending_old = event.surface_index
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
local REROLL_ABSTAIN = "ld_reroll_abstain"
local REROLL_TOGGLE = "ld_reroll_toggle"

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

local format_time_left = function()
    local seconds = storage.reroll_time_left or 0
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local reroll_results = function()
    local _, yes_votes, no_votes = reroll_stats()
    return {"ld-reroll-stats", no_votes, yes_votes, format_time_left()}
end

local button_flow_child = function(player, name)
    local top = player.gui.top.mod_gui_top_frame
    local flow = top and top.mod_gui_inner_frame
    return flow and flow[name]
end

local reroll_frame = function(player)
    return button_flow_child(player, REROLL_FRAME)
end

local add_vote_row = function(parent)
    local row = parent.add{type = "table", name = "row", column_count = 5, vertical_centering = true}
    local caption = row.add{type = "label", name = "reroll_caption", caption = {"ld-reroll-caption"}}
    caption.style.font = "heading-2"
    local results = row.add{type = "label", name = "reroll_stats", caption = reroll_results()}
    results.style.font = "heading-2"
    row.add{type = "button", name = REROLL_NO, caption = {"ld-reroll-no"}, style = "red_back_button"}
    row.add{type = "button", name = REROLL_ABSTAIN, caption = {"ld-reroll-abstain"}, style = "dialog_button"}
    row.add{type = "button", name = REROLL_YES, caption = {"ld-reroll-yes"}, style = "confirm_button_without_tooltip"}
end

local draw_reroll_gui = function(player)
    local button_flow = mod_gui.get_button_flow(player)
    if not button_flow[REROLL_TOGGLE] then
        button_flow.add{type = "sprite-button", name = REROLL_TOGGLE, sprite = "utility/reset_white", tooltip = {"ld-reroll-toggle-tooltip"}, style = "slot_button"}
    end
    if reroll_frame(player) then return end
    local frame = button_flow.add{type = "flow", name = REROLL_FRAME, direction = "horizontal"}
    frame.style.vertical_align = "center"
    frame.style.vertically_stretchable = true
    add_vote_row(frame)
end

local vote_caption = function(name)
    local vote = storage.reroll_votes[name]
    if vote == 1 then return {"ld-reroll-yes"} end
    if vote == 0 then return {"ld-reroll-no"} end
    return {"ld-reroll-abstained"}
end

local fill_vote_list = function(list)
    list.clear()
    for _, player in pairs(game.connected_players) do
        local frame = list.add{type = "frame", direction = "horizontal"}
        frame.style.horizontally_stretchable = true
        frame.style.vertical_align = "center"
        local flow = frame.add{type = "flow", direction = "horizontal"}
        flow.style.horizontally_stretchable = true
        flow.style.vertical_align = "center"
        local name = flow.add{type = "label", caption = player.name}
        name.style.width = 160
        flow.add{type = "label", style = "subheader_caption_label", caption = {"ld-reroll-voted"}}
        flow.add{type = "label", caption = vote_caption(player.name)}
    end
end

Public.is_reroll_active = function()
    return storage.reroll_votes ~= nil
end

local fill_vote_header = function(header)
    header.clear()
    if not storage.reroll_votes then
        local idle = header.add{type = "label", caption = {"ld-reroll-idle"}}
        idle.style.single_line = false
        idle.style.maximal_width = 500
        return
    end
    local _, yes_votes, no_votes = reroll_stats()
    header.add{type = "label", style = "subheader_caption_label", caption = {"ld-reroll-time-left"}}
    header.add{type = "label", name = "time_left", caption = format_time_left()}
    header.add{type = "label", style = "subheader_caption_label", caption = {"ld-reroll-yes-votes"}}
    header.add{type = "label", name = "yes_votes", caption = tostring(yes_votes)}
    header.add{type = "label", style = "subheader_caption_label", caption = {"ld-reroll-no-votes"}}
    header.add{type = "label", name = "no_votes", caption = tostring(no_votes)}
end

local fill_vote_buttons = function(buttons)
    buttons.clear()
    local active = storage.reroll_votes ~= nil
    buttons.add{type = "button", name = REROLL_NO, caption = {"ld-reroll-no"}, style = "red_back_button", enabled = active}
    buttons.add{type = "button", name = REROLL_ABSTAIN, caption = {"ld-reroll-abstain"}, style = "dialog_button", enabled = active}
    buttons.add{type = "button", name = REROLL_YES, caption = {"ld-reroll-yes"}, style = "confirm_button", enabled = active}
end

Public.fill_vote_window = function(player, tab, buttons)
    storage.reroll_windows = storage.reroll_windows or {}
    storage.reroll_windows[player.index] = {tab = tab, buttons = buttons}
    tab.clear()
    local header = tab.add{type = "flow", direction = "horizontal", name = "header"}
    header.style.vertical_align = "center"
    fill_vote_header(header)
    local list = tab.add{type = "scroll-pane", style = "deep_scroll_pane", name = "players"}
    list.style.horizontally_stretchable = true
    list.style.vertically_stretchable = true
    list.style.maximal_height = 360
    if storage.reroll_votes then
        fill_vote_list(list)
    end
    fill_vote_buttons(buttons)
end

local vote_windows = function()
    local windows = {}
    for index, window in pairs(storage.reroll_windows or {}) do
        if window.tab.valid and window.buttons.valid then
            windows[index] = window
        else
            storage.reroll_windows[index] = nil
        end
    end
    return windows
end

local redraw_vote_windows = function()
    for index, window in pairs(vote_windows()) do
        Public.fill_vote_window(game.get_player(index), window.tab, window.buttons)
    end
end

local refresh_vote_ui = function(lists)
    local results = reroll_results()
    for _, player in pairs(game.connected_players) do
        local frame = reroll_frame(player)
        if frame then
            frame.row.reroll_stats.caption = results
        end
    end
    local _, yes_votes, no_votes = reroll_stats()
    for _, window in pairs(vote_windows()) do
        local header = window.tab.header
        if header and header.time_left then
            header.time_left.caption = format_time_left()
            header.yes_votes.caption = tostring(yes_votes)
            header.no_votes.caption = tostring(no_votes)
        end
        if lists and window.tab.players then
            fill_vote_list(window.tab.players)
        end
    end
end

local stop_reroll_vote = function()
    storage.reroll_votes = nil
    storage.reroll_time_left = nil
    for _, player in pairs(game.players) do
        local frame = reroll_frame(player) or player.gui.top[REROLL_FRAME]
        if frame then frame.destroy() end
        local toggle = button_flow_child(player, REROLL_TOGGLE)
        if toggle then toggle.destroy() end
    end
    redraw_vote_windows()
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
    redraw_vote_windows()
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
        for _, player in pairs(game.connected_players) do
            local legacy = player.gui.top[REROLL_FRAME]
            if legacy then
                legacy.destroy()
                draw_reroll_gui(player)
            end
        end
        refresh_vote_ui(false)
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

-- What the box holds so far -- turrets and nests both -- is both the trigger
-- and what the cutscene flies over.
local base_in_spawn_box = function()
    return active_surface().find_entities_filtered{area = SPAWN_BOX, type = {"turret", "unit-spawner"}}
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
    if #base <= DEFEAT_BASE_COUNT then
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
        if #base <= DEFEAT_BASE_COUNT then
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
    -- per entity, not per base. What the box holds so far -- turrets and nests
    -- both -- is both the trigger and what the cutscene flies over.
    -- Three nests and worms in the box is a colony, four is a loss. There is
    -- no clock on it: the early game lost on the first entity to land, which
    -- ended rounds nobody had a chance in, so a swarm now has to pile up.
    if #base <= DEFEAT_BASE_COUNT then
        return
    end
    game.print({"ld-announcement", {"ld-defeat-imminent"}})
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
    local name = event.element.name
    if name == REROLL_TOGGLE then
        local frame = reroll_frame(game.get_player(event.player_index))
        if frame then frame.visible = not frame.visible end
        return
    end
    if name ~= REROLL_YES and name ~= REROLL_NO and name ~= REROLL_ABSTAIN then return end
    local player = game.get_player(event.player_index)
    if not (player and player.valid) then return end
    if name == REROLL_ABSTAIN then
        storage.reroll_votes[player.name] = nil
        refresh_vote_ui(true)
        return
    end
    storage.reroll_votes[player.name] = (name == REROLL_YES) and 1 or 0
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
    else
        refresh_vote_ui(true)
    end
end

local on_reroll_join = function(event)
    if not storage.reroll_votes then return end
    local player = game.get_player(event.player_index)
    if player and player.valid then draw_reroll_gui(player) end
    refresh_vote_ui(true)
end

local on_reroll_left = function()
    if not storage.reroll_votes then return end
    refresh_vote_ui(true)
end

-- The swap's second half, in one place: associate the fresh surface with the
-- planet (which makes it the current surface), reset the round state and
-- stand the round up. Called from on_surface_deleted (the normal path) and
-- from on_configuration_changed (a save/load that landed in the one-tick gap
-- between the old surface's deletion and the association).
local finish_surface_swap = function(surface)
    local planet = game.planets[PLANET]
    if planet and not planet.surface then
        planet.associate_surface(surface)
    end
    -- The round surface belongs on the surfaces list; a dormant surface
    -- hidden during pre-generation is revealed here.
    game.forces["player"].set_surface_hidden(surface.name, false)
    storage.active_surface = surface.name
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
-- up on it. Only the round surface's deletion reaches this point, thanks to
-- the index recorded in on_pre_surface_deleted.
local on_surface_deleted = function(event)
    if event.surface_index ~= storage.pending_old then return end
    storage.pending_old = nil
    storage.pending_old_name = nil
    local surface = game.surfaces[storage.pending_surface]
    storage.pending_surface = nil
    if surface then
        finish_surface_swap(surface)
    end
end

local create_crash_site = function(surface)
    crash_site.create_crash_site(surface, {-5,-6}, util.copy(storage.crashed_ship_items), util.copy(storage.crashed_debris_items), util.copy(storage.crashed_ship_parts))
end

-- Everything a fresh round needs at spawn (fresh save or a finished surface
-- swap): staged reveal, crash site, starting turret and nest territory.
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

-- One-time setup for the very first round. A fresh save's first round is
-- built on the round surface created in on_init (the engine spawned the first
-- joiners on the dummy primary, so the first player is walked over). A
-- pre-swap save that is still mid-round on the primary simply keeps playing
-- there untouched until the first reset migrates it.
local setup_first_round = function(player)
    if storage.init_ran then return end
    storage.init_ran = true

    game.forces["enemy"].friendly_fire = false
    groups.restrict_players()
    -- Spectate mode is a runtime toggle (/spectate-mode on|off), not the
    -- starting state: fresh games play normally and perform_reset turns it
    -- off. Group membership lives in the save, so an old spectate-on save
    -- stays spectating until an admin runs /spectate-mode off once.

    local surface = active_surface()
    if surface.name == PRIMARY_NAME then
        return
    end
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
    local target = active_surface()
    local character = player.character
    local misplaced = (not character or not character.valid) or player.surface.name ~= target.name
    if misplaced then
        if character and character.valid then
            player.character = nil
        end
        player.teleport({0, 0}, target)
        local spawn = target.find_non_colliding_position("character", {0, 0}, 4, 0.5) or {0, 0}
        local fresh = target.create_entity{name = "character", position = spawn, force = "player"}
        if fresh then
            player.set_controller{type = defines.controllers.character, character = fresh}
            util.insert_safe(player, storage.created_items)
        end
    end
end

-- Swaps the round onto the dormant surface: it is created fresh (or adopted
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

    -- actor: player name (or "server" for console) for manual /reset runs,
    -- nil for automatic resets. Manual resets are inferred by the presence
    -- of the actor field. seed: optional map seed, random when nil.
    local trigger = actor and (", actor=" .. actor) or ""
    local science = game.forces["player"].get_item_production_statistics(1).get_input_count "science"
    local minutes = math.floor(game.ticks_played / 3600)

    local old_surface = active_surface()
    local old_name = old_surface.name
    local migrating = (old_name == PRIMARY_NAME) -- a pre-swap save: round still on the primary
    local new_name = next_round_name(old_name)
    -- Adopt the countdown's pre-generated dormant surface, or create fresh.
    -- A surface holding the round's name that is NOT the marked dormant is a
    -- stale leftover from a broken earlier swap, complete with the old
    -- round's entities -- wiping it (and an explicit /reset seed does the
    -- same) keeps the next round from piling onto the old crash site.
    local new_surface = game.surfaces[new_name]
    if new_surface and (seed or storage.pregen_surface ~= new_name) then
        local mgs = new_surface.map_gen_settings
        mgs.seed = seed or math.random(1111, 4294967295)
        new_surface.map_gen_settings = mgs
        new_surface.clear(true)
    elseif not new_surface then
        local mgs = old_surface.map_gen_settings
        mgs.seed = seed or math.random(1111, 4294967295)
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
            and surface.name ~= old_name
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
    -- deletion tracking picks the round surface out of the pile by index.
    for _, surface in pairs(game.surfaces) do
        if surface.platform then
            game.delete_surface(surface)
        end
    end
    if migrating then
        -- The round still sat on the undeletable primary and the host planet
        -- is free, so no deletion/disassociation is needed: finishing the swap
        -- associates the fresh surface and stands the round up right here.
        finish_surface_swap(new_surface)
    else
        -- Queue the old surface's deletion: on_surface_deleted fires a tick
        -- or two later, once the planet is free, and finishes the swap there.
        storage.pending_surface = new_name
        storage.pending_old_name = old_name
        game.delete_surface(old_surface)
    end
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
  [defines.events.on_pre_surface_deleted] = on_pre_surface_deleted,
  [defines.events.on_surface_deleted] = on_surface_deleted,
  [defines.events.on_biter_base_built] = Public.on_biter_base_built,
  ["crash-site-skip-cutscene"] = on_skip_cutscene,
  [defines.events.on_cutscene_finished] = on_cutscene_end,
  [defines.events.on_cutscene_cancelled] = on_cutscene_end,
  [defines.events.on_gui_click] = on_reroll_click,
  [defines.events.on_player_left_game] = on_reroll_left,
  [defines.events.on_player_joined_game] = on_player_joined,
}
Public.on_init = function()
    ensure_crash_loot()
    -- A fresh game: the round surface is created from the primary's settings
    -- (same seed) and associated with the host planet; setup_first_round
    -- builds the starting area and walks the first player over. Pre-swap
    -- saves skip this -- their round is still on the primary, and the first
    -- reset migrates it.
    local source = game.surfaces[PRIMARY_NAME]
    local surface = game.create_surface(ROUND_SURFACES[1], source and source.map_gen_settings)
    local planet = game.planets[PLANET]
    if planet and not planet.surface then
        planet.associate_surface(surface)
    end
    if planet then
        game.forces["player"].unlock_space_location(PLANET)
    end
    -- The dummy primary hosts no round; planet.hidden (the fork) only hides it
    -- from the star map, so hide the surface from the surfaces panel the same
    -- way the gulag is hidden.
    game.forces["player"].set_surface_hidden(PRIMARY_NAME, true)
    storage.active_surface = surface.name
end
Public.on_configuration_changed = function()
    ensure_crash_loot()
    -- Existing (dual-surface) saves adopt the surface the host planet owns
    -- right now. A deploy onto a pre-swap save (round still on the primary)
    -- leaves it alone: the first reset migrates it. This also repairs a save
    -- that landed in the one-tick gap between the old surface's deletion and
    -- the new one's association -- finish_surface_swap is idempotent.
    local planet = game.planets[PLANET]
    if planet and planet.surface then
        storage.active_surface = planet.surface.name
    elseif storage.pending_surface and game.surfaces[storage.pending_surface] then
        local surface = game.surfaces[storage.pending_surface]
        storage.pending_surface = nil
        finish_surface_swap(surface)
    else
        -- A swap interrupted after the deletion but before the association
        -- (or a pre-rename round deleted before its swap's second half) leaves
        -- the active round surface orphaned, still planet-less: heal it. The
        -- recorded active name can point at the already-deleted round, so the
        -- orphan is found by the players standing on it as a fallback.
        local active = storage.active_surface and game.surfaces[storage.active_surface]
        if not (active and active.valid and not active.planet) then
            active = nil
            for _, name in ipairs(ROUND_SURFACES) do
                local candidate = game.surfaces[name]
                if candidate and not candidate.planet then
                    for _, p in pairs(game.connected_players) do
                        if p.surface == candidate then
                            active = candidate
                            break
                        end
                    end
                end
                if active then break end
            end
        end
        if active and not active.planet and active.name ~= PRIMARY_NAME then
            if planet then planet.associate_surface(active) end
            storage.active_surface = active.name
        end
        storage.pregen_surface = nil
        storage.pregen_index = nil
        storage.next_seed = nil
    end
    -- Force resets wipe charts, so the dummy primary's old world goes black
    -- and nothing ever re-charts it; the fork's planet.hidden only hides it
    -- from the star map, so the surface is hidden from the surfaces panel the
    -- same way the gulag is hidden.
    game.forces["player"].set_surface_hidden(PRIMARY_NAME, true)
    -- The host planet must be discovered for its surfaces to group under it
    -- in the map view; an undiscovered planet buckets them under "Other".
    if game.planets[PLANET] then
        game.forces["player"].unlock_space_location(PLANET)
    end
    -- Deploy hygiene: a round-named surface that is planet-less and belongs
    -- to no in-flight swap is a stray -- a vote that failed after
    -- pre-generation completed, or an orphan from before a naming change.
    -- The active surface is the planet's (or healed above), so this cannot
    -- touch a live round.
    for _, name in ipairs(ROUND_SURFACES) do
        local stray = game.surfaces[name]
        if stray and not stray.planet
            and name ~= storage.pending_surface
            and name ~= storage.pregen_surface
            and name ~= storage.active_surface then
            game.delete_surface(stray)
        end
    end
end

return Public

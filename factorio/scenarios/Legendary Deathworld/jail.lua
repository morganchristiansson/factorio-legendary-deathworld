-- Jail ("gulag"): admins can send misbehaving players to a sealed-off
-- side surface where they can only chat, until an admin frees them.
--
-- The pit and the jail records live here. Who is in which permission group is
-- groups.lua's, and this asks it for the two moves it needs: into the gulag
-- group, and back to whatever the player had before.
--
-- Adapted from the Biter Battles scenario's gulag (jail_data.lua),
-- trimmed to this server's needs: admin-only commands, no voting, no
-- web panel sync. Jail state lives in storage.jailed and survives
-- saves, restarts and map resets.
-----------------------------------------------------------------------
local groups = require("groups")

local GULAG_SURFACE_NAME = "gulag"
local GULAG_GROUP_NAME = "gulag"
local Public = {}

-- Floor and wall bounds of the pit itself.
local PIT = {left_top = {x = -32, y = -32}, right_bottom = {x = 32, y = 32}}

-- Circuit-controlled speaker rig that plays a troll tune on loop.
-- Blueprint exported from the Biter Battles scenario; bb builds three
-- copies (north/south/spectator team areas), we build one in the pit.
local JAIL_SONG_BLUEPRINT = require("jail-song")
local SONG_BUILDINGS = {
    "constant-combinator",
    "decider-combinator",
    "arithmetic-combinator",
    "substation",
    "programmable-speaker",
    "electric-energy-interface",
}
-- Rig placement inside the pit, clear of the teleport-in point at 0,0.
-- The blueprint spans roughly x+/-12, y+/-25 around its anchor, which
-- is why the pit keeps its full-height walls.
local SONG_POSITION = {x = 17, y = 0}

-----------------------------------------------------------------------
local get_jailed_table = function()
    storage.jailed = storage.jailed or {}
    return storage.jailed
end


Public.is_jailed = function(name)
    return get_jailed_table()[name] ~= nil
end


-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- Builds the jail song rig via a temporary blueprint item, mirroring
-- bb's createTrollSong. Combinators 27/28 gate the tune on/off; all
-- buildings are locked afterwards so prisoners can only listen.
local build_jail_song = function(surface)
    local holder = surface.create_entity{
        name = "item-on-ground",
        position = SONG_POSITION,
        stack = "blueprint",
    }
    if not holder then
        log("event=jail-warning, reason=song blueprint holder failed to spawn")
        return
    end
    local stack = holder.stack
    stack.import_stack(JAIL_SONG_BLUEPRINT)
    local ghosts = stack.build_blueprint{
        surface = surface,
        force = game.forces.player,
        position = SONG_POSITION,
        force_build = true,
    }
    holder.destroy()
    for index, ghost in pairs(ghosts) do
        if index == 27 then
            ghost.get_control_behavior().enabled = false
        elseif index == 28 then
            ghost.get_control_behavior().enabled = true
        end
        ghost.revive()
    end
    local area = {{SONG_POSITION.x - 12, SONG_POSITION.y - 24}, {SONG_POSITION.x + 13, SONG_POSITION.y + 26}}
    for _, entity in pairs(surface.find_entities_filtered{area = area, name = SONG_BUILDINGS}) do
        entity.minable_flag = false
        entity.destructible = false
        entity.operable = false
    end
end

-- One-time pit construction: flat concrete strip ringed by neutral,
-- indestructible walls, permanently daytime.
local ensure_gulag_surface = function()
    local surface = game.surfaces[GULAG_SURFACE_NAME]
    if surface then
        return surface
    end
    surface = game.create_surface(GULAG_SURFACE_NAME,
    {
        width = 64,
        height = 64,
        peaceful_mode = true,
        starting_area = "none",
        -- Without this, undefined autoplace controls fall back to the
        -- default control set, and EverythingOnNauvis' decoratives
        -- reference planet controls (e.g. fulgora_islands) that don't
        -- exist there -> noise expression compile error. Disabled means
        -- those decoratives are simply not generated; we paint the whole
        -- pit ourselves anyway.
        default_enable_all_autoplace_controls = false,
    })
    surface.always_day = true
    -- Hide the pit from the map view's surface list.
    game.forces.player.set_surface_hidden(GULAG_SURFACE_NAME, true)
    surface.request_to_generate_chunks({0, 0}, 9)
    surface.force_generate_chunk_requests()

    local tiles = {}
    local walls = {}
    for x = PIT.left_top.x, PIT.right_bottom.x do
        for y = PIT.left_top.y, PIT.right_bottom.y do
            tiles[#tiles + 1] = {name = "black-refined-concrete", position = {x = x, y = y}}
            if x == PIT.left_top.x or x == PIT.right_bottom.x
                or y == PIT.left_top.y or y == PIT.right_bottom.y then
                walls[#walls + 1] = {name = "stone-wall", force = "neutral", position = {x = x, y = y}}
            end
        end
    end
    surface.set_tiles(tiles)
    for _, wall in pairs(walls) do
        local entity = surface.create_entity(wall)
        if entity then
            entity.destructible = false
            entity.minable_flag = false
        end
    end

    rendering.draw_text{
        text = "The pit of despair ☹",
        surface = surface,
        target = {0, -50},
        color = {r = 0.98, g = 0.66, b = 0.22},
        scale = 10,
        font = "heading-1",
        alignment = "center",
        scale_with_zoom = false,
    }
    build_jail_song(surface)
    return game.surfaces[GULAG_SURFACE_NAME]
end

local teleport_to_gulag = function(player)
    local surface = ensure_gulag_surface()
    local position = surface.find_non_colliding_position("character", {0, 0}, 128, 1)
    if player.character then
        player.character.driving = false
        player.character.teleport(position, surface.name)
    else
        player.teleport(position, surface.name)
    end
    player.opened = defines.gui_type.none
    -- Map view and remote view are one mode in 2.x, and opening either is an
    -- input action this group denies, so all that is left is closing the one
    -- they were already looking at when they got here.
    player.exit_remote_view()
end

-- Out of the pit, back to where they were taken from.
local teleport_from_gulag = function(player, data)
    local surface = game.surfaces[data.surface_index] or game.surfaces[1]
    local position = surface.find_non_colliding_position("character", data.position, 128, 1)
        or game.forces["player"].get_spawn_position(surface)
    if player.character then
        player.character.teleport(position, surface.name)
    else
        player.teleport(position, surface.name)
    end
    player.exit_remote_view()
end

-----------------------------------------------------------------------
-- Sends a player to the gulag. Returns true on success, false plus a
-- reason string otherwise. actor names who ordered the jailing.
Public.jail = function(actor, name, reason)
    local target = game.get_player(name)
    if not target then
        return false, "No such player: " .. tostring(name)
    end
    local jailed = get_jailed_table()
    if jailed[target.name] then
        return false, target.name .. " is already jailed"
    end

    -- The record first: the group change is queued and lands on a tick later,
    -- and the handler that puts them in the pit reads this.
    local source_group = target.permission_group
    jailed[target.name] =
    {
        surface_index = target.physical_surface_index,
        position = target.physical_position,
        actor = actor,
        reason = reason,
    }
    groups.enter_temporary(target.name, GULAG_GROUP_NAME)

    local message = string.format("%s has been jailed by %s. Reason: %s", target.name, actor, reason)
    game.print(message)
    -- No console clear: the pit is for talking, not for silencing.
    log(string.format("event=jail, actor=%s, target=%s, reason=%s, source_group=%s, surface=%s, admin=%s",
        actor, target.name, reason, source_group and source_group.name or "none",
        target.surface.name, tostring(target.admin)))
    return true
end

-- /jail and /release both live in groups.lua: both are just a group change,
-- and the handler below is what puts a player in the pit or walks them out of
-- it. This module is the pit and the records that handler needs.

-----------------------------------------------------------------------
-- Every physical consequence of a group change, in one place. The commands
-- only change groups; whatever that does to a player's body happens here, so
-- jailing a frozen player, freezing a jailed one and both ways out of the pit
-- are the same code path rather than one per command.
--
-- What matters is where the player ended up, not which group the event names:
-- being added to trusted on the way out of the gulag arrives as add-player for
-- trusted. other_player_index is who moved -- player_index is who did the
-- editing, and is nil when a mod did it, which is always here. Reading
-- permission_group is safe this once: the event fires directly after the edit.
Public.events =
{
    [defines.events.on_permission_group_edited] = function(event)
        if event.type ~= "add-player" and event.type ~= "remove-player" then
            return
        end
        local moved = game.get_player(event.other_player_index)
        if not moved then
            return
        end
        local jailed = get_jailed_table()
        local data = jailed[moved.name]
        local group = moved.permission_group and moved.permission_group.name
        if group == GULAG_GROUP_NAME then
            if data then
                teleport_to_gulag(moved)
            end
        elseif data then
            -- Out of the pit, whether that was /free or being frozen: back to
            -- where they were taken from either way.
            teleport_from_gulag(moved, data)
            jailed[moved.name] = nil
        elseif event.type == "add-player" then
            -- A freeze has no body to move, but the map view is the same
            -- nuisance it is in the pit.
            moved.exit_remote_view()
        end
    end,

    [defines.events.on_player_joined_game] = function(event)
        local player = game.get_player(event.player_index)
        if not player or not Public.is_jailed(player.name) then
            return
        end
        groups.set_group(player.name, GULAG_GROUP_NAME)
        teleport_to_gulag(player)
    end,

    [defines.events.on_player_respawned] = function(event)
        local player = game.get_player(event.player_index)
        if player and Public.is_jailed(player.name) then
            teleport_to_gulag(player)
        end
    end,

    -- Escape prevention: anything that moves a jailed player off the
    -- gulag surface gets undone.
    [defines.events.on_player_changed_surface] = function(event)
        local player = game.get_player(event.player_index)
        if not player or not Public.is_jailed(player.name) then
            return
        end
        local gulag = game.surfaces[GULAG_SURFACE_NAME]
        if not gulag or player.surface.index ~= gulag.index then
            teleport_to_gulag(player)
        end
    end,
}

return Public

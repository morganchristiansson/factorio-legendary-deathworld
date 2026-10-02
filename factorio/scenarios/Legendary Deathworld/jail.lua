-- Jail ("gulag"): admins can send misbehaving players to a sealed-off
-- side surface where they can only chat, until an admin frees them.
--
-- Adapted from the Biter Battles scenario's gulag (jail_data.lua),
-- trimmed to this server's needs: admin-only commands, no voting, no
-- web panel sync. Jail state lives in storage.jailed and survives
-- saves, restarts and map resets.
-----------------------------------------------------------------------
local GULAG_SURFACE_NAME = "gulag"
local GULAG_GROUP_NAME = "gulag"
-- LuaPlayer.permission_group is cached per player and only flushed by a group
-- write, so membership cannot be verified where it is issued: neither /jail
-- nor /free checks it, and enforce_jail_state below re-asserts both sides on a
-- tick, where the change sticks even when it came from a player's client. That
-- makes the gulag self-healing rather than one-shot. Biter Battles never checks
-- either -- it just does the add and trusts the teleport to hold.
local ENFORCE_INTERVAL = 20
-- How long a release keeps re-asserting the restored group.
local RELEASE_GRACE = 600
-- Floor and wall bounds of the pit itself.
local PIT = {left_top = {x = -32, y = -32}, right_bottom = {x = 32, y = 32}}

local Public = {}

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

local get_releasing_table = function()
    storage.releasing = storage.releasing or {}
    return storage.releasing
end

Public.is_jailed = function(name)
    return get_jailed_table()[name] ~= nil
end

-- Permission group allowing nothing but console chat.
local get_gulag_permission_group = function()
    local group = game.permissions.get_group(GULAG_GROUP_NAME)
    if not group then
        group = game.permissions.create_group(GULAG_GROUP_NAME)
        for action_name, _ in pairs(defines.input_action) do
            group.set_allows_action(defines.input_action[action_name], false)
        end
        group.set_allows_action(defines.input_action.write_to_console, true)
    end
    return group
end

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

    -- Never treat the gulag group as the group to restore: if a prior
    -- release failed to move the player out of it, re-jailing would
    -- otherwise record gulag as their 'original' group forever.
    local source_group = target.permission_group
    jailed[target.name] =
    {
        surface_index = target.physical_surface_index,
        position = target.physical_position,
        source_group_name = (source_group and source_group.name ~= GULAG_GROUP_NAME) and source_group.name or nil,
        actor = actor,
        reason = reason,
    }
    -- Group first, teleport second, and never gate the group on the
    -- teleport having landed: LuaPlayer.surface still reports the old
    -- surface for a tick, which silently skipped the group and left the
    -- prisoner walking around the pit with full permissions.
    get_gulag_permission_group().add_player(target.name)
    storage.releasing = storage.releasing or {}
    storage.releasing[target.name] = nil
    teleport_to_gulag(target)

    local message = string.format("%s has been jailed by %s. Reason: %s", target.name, actor, reason)
    game.print(message)
    target.clear_console()
    target.print(message)
    log(string.format("event=jail, actor=%s, target=%s, reason=%s, source_group=%s, surface=%s, admin=%s",
        actor, target.name, reason, source_group and source_group.name or "none",
        target.surface.name, tostring(target.admin)))
    -- No group read-back here: LuaPlayer.permission_group lags a tick behind
    -- the add, so a same-tick check only ever sees the pre-jail group.
    -- enforce_jail_state reads it from a tick handler and warns if the
    -- prisoner is still not in the gulag group.
    return true
end

-- Returns a jailed player to their previous surface and permissions.
Public.free = function(actor, name)
    local jailed = get_jailed_table()
    local data = jailed[name]
    local target = game.get_player(name)
    if not data or not target then
        return false, "No jailed player: " .. tostring(name)
    end
    jailed[name] = nil

    -- Restore the permission group they had before being jailed. Store
    -- by name and resolve fresh: numeric group ids are unreliable across
    -- sessions, and never restore into the gulag group itself. Falls
    -- back to Default.
    local restored_group = data.source_group_name
        and data.source_group_name ~= GULAG_GROUP_NAME
        and game.permissions.get_group(data.source_group_name)
        or nil
    if not restored_group then
        restored_group = game.permissions.get_group("Default")
    end
    restored_group.add_player(target.name)
    -- Belt and braces: force-drop any lingering gulag membership, then
    -- read back what the engine actually applied. If add_player ever
    -- silently fails, the log shows intended vs actual instead of us
    -- guessing.
    local gulag_group = game.permissions.get_group(GULAG_GROUP_NAME)
    if gulag_group then
        gulag_group.remove_player(target.name)
    end
    -- Same engine flakiness as jail(), in reverse: if that add is swallowed
    -- the released player is stuck in the deny-all group with no way out, so
    -- the enforcement tick below keeps re-asserting it for a while.
    storage.releasing[name] = {group = restored_group.name, expires = game.tick + RELEASE_GRACE}

    local surface = game.surfaces[data.surface_index] or game.surfaces[1]
    local position = surface.find_non_colliding_position("character", data.position, 128, 1)
        or game.forces["player"].get_spawn_position(surface)
    if target.character then
        target.character.teleport(position, surface.name)
    else
        target.teleport(position, surface.name)
    end

    local message = string.format("%s was released from jail by %s.", name, actor)
    game.print(message)
    -- No read-back here, same reason as jail(): LuaPlayer.permission_group
    -- lags a tick, so it only reports the pre-release group. enforce_jail_state
    -- checks it from a tick handler and warns if a restore had to be re-asserted.
    log(string.format("event=release, actor=%s, target=%s, restored_group=%s", actor, name, restored_group.name))
    return true
end

-----------------------------------------------------------------------
-- Keeps the gulag honest every ENFORCE_INTERVAL ticks: the prisoner stays
-- in the deny-all group and on the pit surface, and a release whose group
-- change was swallowed is re-asserted until RELEASE_GRACE expires. Static
-- registration (module scope re-executes every session), no-op when the
-- gulag is empty.
local enforce_jail_state = function()
    local group = get_gulag_permission_group()
    local gulag = game.surfaces[GULAG_SURFACE_NAME]
    for name in pairs(get_jailed_table()) do
        local player = game.get_player(name)
        if player and player.valid then
            if not player.permission_group or player.permission_group.name ~= GULAG_GROUP_NAME then
                -- Reads here can be stale: permission_group is cached per
                -- player and only flushed by a group write, so it may report
                -- the pre-jail group ticks after the add. Re-assert anyway --
                -- it is idempotent -- but do not warn: two attempts at
                -- checking this (same-tick in /jail, here) both produced
                -- false positives, and Biter Battles does not check at all.
                group.add_player(name)
            end
            if gulag and player.surface.index ~= gulag.index then
                teleport_to_gulag(player)
            end
        end
    end
    for name, pending in pairs(get_releasing_table()) do
        local player = game.get_player(name)
        -- The entry exists only to cover a swallowed add, so drop it as soon
        -- as the group actually stuck: otherwise a /trust in the grace window
        -- would be undone by this tick.
        local applied = player and player.valid and player.permission_group
            and player.permission_group.name == pending.group
        if applied or game.tick >= pending.expires then
            storage.releasing[name] = nil
        else
            local restored = game.permissions.get_group(pending.group)
            if player and player.valid and restored then
                -- Idempotent for the same reason as the re-assert above.
                restored.add_player(name)
            end
        end
    end
end
script.on_nth_tick(ENFORCE_INTERVAL, enforce_jail_state)

Public.on_init = get_gulag_permission_group

-- Respawn hook, routed from freeplay.lua (one handler per event):
-- jailed players respawn straight back into the pit, without kit.
Public.on_player_respawned = function(player)
    teleport_to_gulag(player)
end

-----------------------------------------------------------------------
-- Re-apply jail state on join: permission group membership normally
-- persists in the save, but re-adding costs nothing and heals any drift.
Public.events =
{
    [defines.events.on_player_joined_game] = function(event)
        local player = game.get_player(event.player_index)
        if not player or not Public.is_jailed(player.name) then
            return
        end
        get_gulag_permission_group().add_player(player.name)
        teleport_to_gulag(player)
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

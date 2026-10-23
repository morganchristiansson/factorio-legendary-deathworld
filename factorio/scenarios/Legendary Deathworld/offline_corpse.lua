-- Players who stay offline leave a corpse.
--
-- The engine takes a disconnected player's character off the map (LuaPlayer's
-- `character` is nil while the player is away), so there is nobody to kill:
-- the corpse is built by hand, the way danger-ore does it. Everything the
-- player carried goes into a character-corpse where they logged off, and they
-- come back empty-handed -- their corpse is where they return, so they can
-- loot it back unless somebody else got there first.
--
-- The gear is read while the player is away (the engine keeps the inventory
-- of a disconnected player), the position is remembered from the moment they
-- left, and the timer survives a save: the pending table lives in storage and
-- the worker is re-armed by register.lua on load.
local register = require("register")

-- How long a player may be offline before their gear is left behind.
local OFFLINE_MINUTES = 15
local TICKS_PER_MINUTE = 60 * 60

-- Everything the character carries goes into the corpse.
local CORPSE_INVENTORIES = {
    defines.inventory.character_main,
    defines.inventory.character_guns,
    defines.inventory.character_ammo,
    defines.inventory.character_armor,
    defines.inventory.character_trash,
}

local Public = {}

-- player_index -> {expiry = tick, x = , y = , surface = name}
local function pending()
    storage.offline_corpse = storage.offline_corpse or {}
    return storage.offline_corpse
end

local on_pre_player_left_game = function(event)
    local player = game.get_player(event.player_index)
    if not (player and player.valid) then return end
    local position = player.physical_position
    pending()[event.player_index] = {
        expiry = game.tick + OFFLINE_MINUTES * TICKS_PER_MINUTE,
        x = position.x,
        y = position.y,
        surface = player.physical_surface.name,
    }
    register.arm("offline-corpse")
end

-- Move the gear into a corpse at the spot the player left, and empty their
-- inventories so the gear is really gone.
local leave_corpse = function(player_index, entry)
    local player = game.get_player(player_index)
    if not (player and player.valid) then return end
    -- Back before the timeout: the gear is still theirs.
    if player.connected then return end

    local stacks = {}
    for _, id in ipairs(CORPSE_INVENTORIES) do
        local inv = player.get_inventory(id)
        if inv and inv.valid then
            for i = 1, #inv do
                local stack = inv[i]
                if stack.valid_for_read then
                    stacks[#stacks + 1] = stack
                end
            end
        end
    end
    if #stacks == 0 then
        log(string.format("event=offline-corpse, actor=%s, result=no-gear", player.name))
        return
    end

    -- The surface the player left may be gone (a reset swapped it out); the
    -- engine's own memory of where they were is the fallback.
    local surface = game.surfaces[entry.surface] or player.physical_surface
    if not (surface and surface.valid) then
        log(string.format("event=offline-corpse, actor=%s, result=no-surface", player.name))
        return
    end
    local position = {x = entry.x, y = entry.y}

    -- Size the corpse to the stack count; excess items fall through to the
    -- ground below. (prototypes.entity["character-corpse"].inventory_size
    -- raises on this build -- missing keys error on LuaEntityPrototype,
    -- so #stacks is used directly and the overflow handler catches any excess.)
    local corpse = surface.create_entity{
        name = "character-corpse",
        position = position,
        inventory_size = #stacks,
        player_index = player.index,
    }
    corpse.active = false
    local corpse_inventory = corpse.get_inventory(defines.inventory.character_corpse)
    for _, stack in ipairs(stacks) do
        if corpse_inventory.insert(stack) == 0 then
            -- The corpse is full: the rest lies on the ground beside it.
            surface.create_entity{name = "item-on-ground", position = position, stack = stack}
        end
    end
    for _, id in ipairs(CORPSE_INVENTORIES) do
        local inv = player.get_inventory(id)
        if inv and inv.valid then
            inv.clear()
        end
    end

    local tag = string.format("[gps=%.1f,%.1f,%s]", position.x, position.y, surface.name)
    game.print({"ld-announcement", {"ld-offline-corpse", player.name, tag}})
    log(string.format("event=offline-corpse, actor=%s, position=%.1f,%.1f, surface=%s, items=%d",
        player.name, position.x, position.y, surface.name, #stacks))
end

local on_offline_corpse_tick = function()
    local due = pending()
    local waiting = 0
    for player_index, entry in pairs(due) do
        if game.tick >= entry.expiry then
            due[player_index] = nil
            leave_corpse(player_index, entry)
        else
            waiting = waiting + 1
        end
    end
    if waiting == 0 then
        register.disarm("offline-corpse")
    end
end
-- Cadence 120 (every other second): 60 belongs to reset.lua's per-second
-- driver, and there is one handler per tick count, so a second registration
-- there would replace that one.
register.nth_tick("offline-corpse", 120, on_offline_corpse_tick)

Public.events = {
    [defines.events.on_pre_player_left_game] = on_pre_player_left_game,
}

Public.on_init = function()
    storage.offline_corpse = {}
end

Public.on_configuration_changed = function()
    storage.offline_corpse = storage.offline_corpse or {}
end

return Public

-- Run: lua5.4 test/reset-cutscene.lua  (from the repository root)
--
-- A /reset that lands during the defeat countdown must not crash: players
-- still held by the cutscene never leave the old surface (a cutscene
-- teleport is a no-op), so handing them a character built on the new surface
-- raises the engine's surface-mismatch error. perform_reset hands cutscene
-- control back before moving anyone, the same way the countdown's own reset
-- path already did.
--
-- The stubs stay faithful to the engine on the two load-bearing points: a
-- cutscene teleport moves nobody, and set_controller raises when the
-- character is on another surface.
local failures = 0
local function check(what, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", what, tostring(got), tostring(want)))
    end
end

_G.defines = {
    controllers = {character = "character", cutscene = "cutscene", god = "god"},
    events = {
        on_player_created = 1, on_surface_created = 2, on_surface_deleted = 3,
        on_biter_base_built = 4, on_cutscene_finished = 5, on_cutscene_cancelled = 6,
        on_gui_click = 7, on_player_joined_game = 8,
    },
}
_G.storage = {pregen_surface = "nauvis1", pregen_index = 5, next_seed = 777}
_G.log = function() end
_G.script = {
    on_nth_tick = function() end,
    on_event = function() end,
    set_event_filter = function() end,
}

package.preload["util"] = function()
    return {
        copy = function(t) return t end,
        insert_safe = function(player) player.got_kit = true end,
    }
end
package.preload["crash-site"] = function()
    return {
        create_crash_site = function() end,
        default_ship_parts = function() return {} end,
    }
end
package.preload["jail"] = function()
    return {is_jailed = function() return false end, gulag_surface_name = "gulag"}
end
package.preload["groups"] = function()
    return {disable_default_spectate = function() end}
end
package.preload["register"] = function()
    return {
        on_tick = function() end,
        arm = function() end,
        disarm = function() end,
        set_filter = function() end,
    }
end

local function make_surface(name, index)
    local surface
    surface = {
        name = name, index = index, valid = true,
        platform = nil, deletable = true,
        map_gen_settings = {seed = 777},
        request_to_generate_chunks = function() end,
        force_generate_chunk_requests = function() end,
        find_non_colliding_position = function() return {1, 0} end,
        create_entity = function(params)
            return {valid = true, name = params.name, surface = surface}
        end,
        clear = function() end,
    }
    return surface
end

-- The round plays on nauvis2; the countdown pre-generated dormant nauvis1,
-- which the reset adopts.
local old_surface = make_surface("nauvis2", 3)
local new_surface = make_surface("nauvis1", 2)
local gulag = make_surface("gulag", 4)

local deleted = {}
_G.game = {
    ticks_played = 0,
    planets = {nauvis2 = {surface = old_surface}},
    surfaces = {nauvis1 = new_surface, nauvis2 = old_surface, gulag = gulag},
    connected_players = {},
    forces = {
        player = {
            get_item_production_statistics = function()
                return {get_input_count = function() return 0 end}
            end,
        },
    },
    delete_surface = function(surface) deleted[#deleted + 1] = surface.name end,
}

local function add_player(name, controller)
    local player = {
        index = #game.connected_players + 1,
        name = name, valid = true,
        controller_type = controller,
        character = {valid = true},
        surface = old_surface,
        exited = false,
    }
    -- The scenario calls these with dot syntax, so they close over the
    -- player instead of taking self.
    -- A cutscene teleport never leaves the old surface; any other
    -- controller lands on the destination.
    player.teleport = function(_, surface)
        if player.controller_type == defines.controllers.cutscene then
            return false
        end
        player.surface = surface
        return true
    end
    player.exit_cutscene = function()
        player.exited = true
        player.controller_type = defines.controllers.character
    end
    -- The engine's own wording, so a regression fails with the same
    -- signature as the live crash.
    player.set_controller = function(params)
        if params.character.surface ~= player.surface then
            error(string.format(
                "LuaEntity belongs to surface %s (index %d) but a LuaEntity belonging to surface %s (index %d) was expected.",
                params.character.surface.name, params.character.surface.index,
                player.surface.name, player.surface.index), 0)
        end
        player.character = params.character
    end
    game.connected_players[#game.connected_players + 1] = player
    return player
end

-- Alice still watches the defeat cutscene; bob plays normally.
local alice = add_player("alice", defines.controllers.cutscene)
local bob = add_player("bob", defines.controllers.character)

local reset = require("factorio/scenarios/Legendary Deathworld/reset")

local ok, err = pcall(reset.perform_reset, "tester")
check("reset during the cutscene does not raise", ok, true)
if not ok then print("error: " .. tostring(err)) end
check("the cutscene player is handed control back", alice.exited, true)
check("the cutscene player lands on the new surface", alice.surface.name, "nauvis1")
check("the cutscene player's character is on the new surface",
    alice.character and alice.character.surface.name or "none", "nauvis1")
check("the cutscene player gets the spawn kit", alice.got_kit, true)
check("an ordinary player lands on the new surface", bob.surface.name, "nauvis1")
check("an ordinary player's character is on the new surface",
    bob.character and bob.character.surface.name or "none", "nauvis1")
check("the old surface is deleted", table.concat(deleted, ","), "nauvis2")
check("the new surface is recorded current", storage.current_surface, "nauvis1")

print(failures == 0 and "ok" or (failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)

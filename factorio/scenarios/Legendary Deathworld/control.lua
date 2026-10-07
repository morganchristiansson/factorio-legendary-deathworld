local handler = require("event_handler")
local reset = require("reset")
local jail = require("jail")
local groups = require("groups")
local ied_biters = require("ied-biters")
handler.add_lib(require("freeplay"))
handler.add_lib(require("welcome"))
handler.add_lib(require("reset"))
handler.add_lib(require("jail"))
handler.add_lib(groups)
handler.add_lib(require("register"))

-- Command feedback goes only to the caller; the console keeps seeing it.
local function reply(command, message)
    if command.player_index then
        game.get_player(command.player_index).print(message)
    else
        game.print(message)
    end
end

-- Admin-only in game, console always allowed: returns the trimmed parameter
-- and who typed it ("server" from the console), or nil after replying with why
-- not, so callers can just return.
local function admin_target(command, usage)
    local actor = "server"
    if command.player_index then
        local player = game.get_player(command.player_index)
        if not player.admin then
            player.print("Only admins can use this command.")
            return nil
        end
        actor = player.name
    end
    local parameter = (command.parameter or ""):match("^%s*(.-)%s*$")
    if parameter == "" then
        reply(command, "Usage: " .. usage)
        return nil
    end
    return parameter, actor
end

if script.active_mods["space-age"] then
  handler.add_lib(require("space-finish-script"))
else
  handler.add_lib(require("silo-script"))
end

commands.add_command("jail", "Send a player to the gulag. Usage: /jail <player> <reason>", function(command)
    local parameter, actor = admin_target(command, "/jail <player> <reason>")
    if not parameter then
        return
    end
    local params = {}
    for word in string.gmatch(parameter, "%S+") do
        params[#params + 1] = word
    end
    local target = table.remove(params, 1)
    local reason = table.concat(params, " ")
    if reason == "" then
        reply(command, "Usage: /jail <player> <reason>")
        return
    end
    local ok, err = jail.jail(actor, target, reason)
    if not ok then
        reply(command, err)
    end
end)

commands.add_command("release", "Let a jailed or frozen player go back to the group they had. Usage: /release <player>", function(command)
    local target, actor = admin_target(command, "/release <player>")
    if not target then
        return
    end
    local ok, err = groups.release(actor, target)
    if not ok then
        reply(command, err)
    end
end)

commands.add_command("freeze", "Restrict a player to spectator permissions, keeping them on the map. Usage: /freeze <player>", function(command)
    local target = admin_target(command, "/freeze <player>")
    if not target then
        return
    end
    local ok, err = groups.freeze(target)
    if not ok then
        reply(command, err)
    end
end)

commands.add_command("trust", "Allow a player to participate. Usage: /trust <player>", function(command)
    local target = admin_target(command, "/trust <player>")
    if not target then
        return
    end
    local ok, err = groups.trust(target)
    if not ok then
        reply(command, err)
    end
end)

commands.add_command("untrust", "Move a trusted player back to Default permissions. Usage: /untrust <player>", function(command)
    local target = admin_target(command, "/untrust <player>")
    if not target then
        return
    end
    local ok, err = groups.untrust(target)
    if not ok then
        reply(command, err)
    end
end)

commands.add_command("spectate-mode", "Enable or disable spectator permissions. Usage: /spectate-mode <on|off>", function(command)
    if command.player_index then
        local player = game.get_player(command.player_index)
        if not player.admin then
            player.print("Only admins can use this command.")
            return
        end
    end
    local mode = (command.parameter or ""):lower():match("^%s*(.-)%s*$")
    if mode ~= "on" and mode ~= "off" then
        reply(command, "Usage: /spectate-mode <on|off>")
        return
    end
    local enabled = mode == "on"
    groups.set_default_spectate(enabled)
    game.print("Default spectator mode is now " .. (enabled and "on" or "off") .. ".")
end)

commands.add_command("ied-biters", "Turn land mines dropped by dying biters on or off. Usage: /ied-biters <on|off>", function(command)
    local mode, actor = admin_target(command, "/ied-biters <on|off>")
    if not mode then
        return
    end
    mode = mode:lower()
    if mode ~= "on" and mode ~= "off" then
        reply(command, "Usage: /ied-biters <on|off>")
        return
    end
    ied_biters.set_enabled(mode == "on")
    game.print("IED biters are now " .. mode .. " (" .. actor .. ").")
end)

-- TEMPORARY test command: delete once the loss sequence no longer needs
-- rehearsing (cutscene, freeze, reset all run fine from /reset + waiting).
commands.add_command("defeat", "Test the loss sequence without waiting for biters. Plants a nest on spawn, freezes the enemy, shows the cutscene, resets in 1m. Usage: /defeat", function(command)
    -- Admins only, in game: the console has /reset and gains nothing here.
    local player = command.player_index and game.get_player(command.player_index)
    if not (player and player.admin) then
        reply(command, "Only admins can use this command.")
        return
    end
    -- A biter nest is spawners plus worm turrets; any of them inside the
    -- spawn box is a loss. Then hand the spawner to the real trigger, so the
    -- test runs the same path the game does.
    local surface = reset.active_surface()
    local nest = surface.create_entity{name = "biter-spawner", position = {x = 0, y = 0}, force = "enemy"}
    for _, building in ipairs({{"biter-spawner", -12, 4}, {"biter-spawner", 10, -8}, {"small-worm-turret", -6, -12}}) do
        surface.create_entity{name = building[1], position = {x = building[2], y = building[3]}, force = "enemy"}
    end
    reset.on_biter_base_built{entity = nest, surface_index = surface.index}
end)

commands.add_command("close-vote", "Ends the reroll vote now and keeps this map. Usage: /close-vote", function(command)
    if not command.player_index then
        game.print("Only admins can use this command.")
        return
    end
    local player = game.get_player(command.player_index)
    if not player.admin then
        player.print("Only admins can use this command.")
        return
    end
    if not reset.close_reroll_vote() then
        reply(command, "There is no reroll vote running.")
    end
end)

-- The engine puts players at the force's spawn point, so moving that point is
-- the whole of it: no per-player teleport, and /reset hands it back to the map
-- (see reset.lua).
commands.add_command("set-spawn", "Move where players spawn. Usage: /set-spawn [gps=]<x>,<y>", function(command)
    local parameter, actor = admin_target(command, "/set-spawn [gps=]<x>,<y>")
    if not parameter then
        return
    end
    -- Typed bare (34.4,-43.2) or pasted out of a map view (gps=34.4,-43.2,
    -- [gps=...], with a "copied" tag behind it): everything but digits, sign
    -- and separator is dropped, and what is left has to be exactly one "x,y".
    local cleaned = parameter:gsub("[^-%d%.%,]", " ")
    local x, y = cleaned:match("^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
    x, y = tonumber(x), tonumber(y)
    if not x or not y then
        reply(command, "Usage: /set-spawn [gps=]<x>,<y>")
        return
    end
    game.forces["player"].set_spawn_position({x = x, y = y}, reset.active_surface())
    game.print(string.format("Spawn point moved to %.1f,%.1f.", x, y))
    log(string.format("event=spawn-point, actor=%s, position=%.1f,%.1f", actor, x, y))
end)

-- The engine's own /seed prints the seed the save was created with and cannot
-- be overridden, so the round's real seed gets its own command.
commands.add_command("map-seed", "Prints the seed of the current map.", function(command)
    reply(command, "Current map seed: " .. reset.active_surface().map_gen_settings.seed)
end)

commands.add_command("reset", "Resets map. Usage: /reset [seed]", function(command)
    local actor = "server"
    if command.player_index then
        local player = game.get_player(command.player_index)
        if not player.admin then
            player.print("Only admins can use this command.")
            return
        end
        actor = player.name
    end
    local seed
    local param = (command.parameter or ""):match("^%s*(.-)%s*$")
    if param ~= "" then
        seed = tonumber(param)
        if not seed or seed % 1 ~= 0 or seed < 0 or seed > 4294967295 then
            reply(command, "Usage: /reset [seed] (seed must be an integer 0-4294967295)")
            return
        end
    end
    reset.perform_reset(actor, seed)
end)

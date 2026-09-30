local handler = require("event_handler")
local reset = require("reset")
local jail = require("jail")
local trust = require("trust")
handler.add_lib(require("freeplay"))
handler.add_lib(require("welcome"))
handler.add_lib(require("reset"))
handler.add_lib(require("jail"))
handler.add_lib(trust)

-- Command feedback goes only to the caller; the console keeps seeing it.
local function reply(command, message)
    if command.player_index then
        game.get_player(command.player_index).print(message)
    else
        game.print(message)
    end
end

if script.active_mods["space-age"] then
  handler.add_lib(require("space-finish-script"))
else
  handler.add_lib(require("silo-script"))
end

commands.add_command("jail", "Send a player to the gulag. Usage: /jail <player> <reason>", function(command)
    local actor = "server"
    if command.player_index then
        local player = game.get_player(command.player_index)
        if not player.admin then
            player.print("Only admins can use this command.")
            return
        end
        actor = player.name
    end
    local params = {}
    for word in string.gmatch(command.parameter or "", "%S+") do
        params[#params + 1] = word
    end
    local target = table.remove(params, 1)
    local reason = table.concat(params, " ")
    if not target or reason == "" then
        reply(command, "Usage: /jail <player> <reason>")
        return
    end
    local ok, err = jail.jail(actor, target, reason)
    if not ok then
        reply(command, err)
    end
end)

commands.add_command("free", "Release a player from the gulag. Usage: /free <player>", function(command)
    local actor = "server"
    if command.player_index then
        local player = game.get_player(command.player_index)
        if not player.admin then
            player.print("Only admins can use this command.")
            return
        end
        actor = player.name
    end
    local target = command.parameter
    if not target or target == "" then
        reply(command, "Usage: /free <player>")
        return
    end
    local ok, err = jail.free(actor, target)
    if not ok then
        reply(command, err)
    end
end)

commands.add_command("trust", "Allow a player to participate. Usage: /trust <player>", function(command)
    if command.player_index then
        local player = game.get_player(command.player_index)
        if not player.admin then
            player.print("Only admins can use this command.")
            return
        end
    end
    local target = (command.parameter or ""):match("^%s*(.-)%s*$")
    if not target or target == "" then
        reply(command, "Usage: /trust <player>")
        return
    end
    local ok, err = trust.trust(target)
    if not ok then
        reply(command, err)
    end
end)

commands.add_command("untrust", "Restrict a player to spectator permissions. Usage: /untrust <player>", function(command)
    if command.player_index then
        local player = game.get_player(command.player_index)
        if not player.admin then
            player.print("Only admins can use this command.")
            return
        end
    end
    local target = (command.parameter or ""):match("^%s*(.-)%s*$")
    if not target or target == "" then
        reply(command, "Usage: /untrust <player>")
        return
    end
    local ok, err = trust.untrust(target)
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
    trust.set_default_spectate(enabled)
    game.print("Default spectator mode is now " .. (enabled and "on" or "off") .. ".")
end)

commands.add_command("defeat", "Test the loss sequence without waiting for biters. Plants a nest on spawn, freezes the enemy, shows the cutscene, resets in 1m. Usage: /defeat", function(command)
    if command.player_index then
        local player = game.get_player(command.player_index)
        if not player.admin then
            player.print("Only admins can use this command.")
            return
        end
    end
    -- A biter nest is spawners plus worm turrets; any of them inside the
    -- spawn box is a loss. Then hand the spawner to the real trigger, so the
    -- test runs the same path the game does.
    local nest = game.surfaces[1].create_entity{name = "biter-spawner", position = {x = 0, y = 0}, force = "enemy"}
    for _, building in ipairs({{"biter-spawner", -12, 4}, {"biter-spawner", 10, -8}, {"small-worm-turret", -6, -12}}) do
        game.surfaces[1].create_entity{name = building[1], position = {x = building[2], y = building[3]}, force = "enemy"}
    end
    reset.on_biter_base_built{entity = nest, surface_index = 1}
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

local handler = require("event_handler")
local reset = require("reset")
local jail = require("jail")
handler.add_lib(require("freeplay"))
handler.add_lib(require("welcome"))
handler.add_lib(require("reset"))
handler.add_lib(require("jail"))

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
        game.print("Usage: /jail <player> <reason>")
        return
    end
    local ok, err = jail.jail(actor, target, reason)
    if not ok then
        game.print(err)
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
        game.print("Usage: /free <player>")
        return
    end
    local ok, err = jail.free(actor, target)
    if not ok then
        game.print(err)
    end
end)

commands.add_command("reset", "Resets map", function(command)
    local player = game.get_player(command.player_index)
    if player.admin == true then
        reset.perform_reset(player.name)
    end
end)

local handler = require("event_handler")
handler.add_lib(require("freeplay"))
handler.add_lib(require("welcome"))
handler.add_lib(require("reset"))

if script.active_mods["space-age"] then
  handler.add_lib(require("space-finish-script"))
else
  handler.add_lib(require("silo-script"))
end

commands.add_command("reset", "Resets map", function(command)
    local player = game.get_player(command.player_index)
    if player.admin == true then
        reset()
        log(player.name .. ' used reset command ')
    end
end)

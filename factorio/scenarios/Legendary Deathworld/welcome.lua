-- Info window shown to players when they first join,
-- with a top bar button to bring it back up at any time.
-- (Similar to the map intro in the Biter Battles scenario.)

local groups = require("groups")
local register = require("register")

local Public = {}

-- The GUI is not ready while a joining client is still syncing: elements
-- created during on_player_joined_game come back invalid. Show the window
-- one tick later via a self-disarming one-shot, re-armed by each join.
register.nth_tick("welcome-show", 2, function()
    register.disarm("welcome-show")
    for index in pairs(storage.welcome_pending or {}) do
        local player = game.get_player(index)
        if player and player.valid then
            Public.show(player)
        end
    end
    storage.welcome_pending = nil
end)

local FRAME_NAME = "ld_welcome_frame"
local BUTTON_NAME = "ld_welcome_button"
local CLOSE_NAME = "ld_welcome_close"

local function close(player)
  -- Release player.opened first: once the frame is destroyed the reference is
  -- invalid, so a post-destroy check can never match and player.opened would
  -- be left pointing at a dead element -- which is what made E / ESC stop
  -- closing the window. player.opened is not always a GUI element (an
  -- equipment grid, entity, item stack or player can hold the slot), and only
  -- GUI elements have a name, so check the type before reading it.
  local opened = player.opened
  if opened and opened.valid and opened.object_name == "LuaGuiElement"
      and opened.name == FRAME_NAME then
    player.opened = nil
  end
  local frame = player.gui.screen[FRAME_NAME]
  if frame then
    frame.destroy()
  end
end

function Public.show(player)
  close(player)

  local frame = player.gui.screen.add
  {
    type = "frame",
    name = FRAME_NAME,
    direction = "vertical"
  }
  if not frame.valid then
    -- Broken GUI (seen on some joins): creating the frame yielded an invalid
    -- element; bail instead of crashing on it.
    return
  end
  frame.auto_center = true
  -- Make the frame behave like a native window: E / ESC close it.
  player.opened = frame

  -- Draggable title bar with close button
  local title_flow = frame.add{type = "flow"}
  title_flow.drag_target = frame
  title_flow.add{type = "label", caption = {"ld-welcome-title"}, style = "frame_title"}
  local spacer = title_flow.add{type = "empty-widget", style = "draggable_space_header"}
  spacer.style.horizontally_stretchable = true
  spacer.style.natural_height = 24
  spacer.drag_target = frame
  title_flow.add
  {
    type = "sprite-button",
    name = CLOSE_NAME,
    sprite = "utility/close_black",
    hovered_sprite = "utility/close_black",
    clicked_sprite = "utility/close_black",
    style = "frame_action_button",
    mouse_button_filter = {"left"},
    tooltip = {"ld-welcome-close-tooltip"}
  }

  -- Body
  local content = frame.add{type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  local flow = content.add{type = "flow", direction = "vertical"}
  flow.style.width = 520
  flow.style.padding = 12
  local label = flow.add{type = "label", caption = {"ld-welcome-text"}}
  label.style.single_line = false
end

local function toggle(player)
  if player.gui.screen[FRAME_NAME] then
    close(player)
  else
    Public.show(player)
  end
end

local function ensure_button(player)
  if player.gui.top[BUTTON_NAME] then
    return
  end
  player.gui.top.add
  {
    type = "sprite-button",
    name = BUTTON_NAME,
    sprite = "utility/custom_tag_icon",
    tooltip = {"ld-welcome-button-tooltip"},
    style = "slot_button"
  }
end

Public.events =
{
  [defines.events.on_player_joined_game] = function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then
      return
    end
    ensure_button(player)
    -- Spectator mode leaves Default unable to walk, build, craft or open
    -- anything; say so, or a joiner just reads it as a broken game.
    if groups.is_spectate_on() then
      player.print{"ld-spectate-mode"}
    end
    -- The window is not shown on join: on some joins the player's GUI yields
    -- invalid elements even a tick later, crashing the server. It stays
    -- available via the top bar button.
  end,

  [defines.events.on_gui_closed] = function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then
      return
    end
    -- The engine names a closed element only when it held player.opened. If
    -- the player opens their armor or inventory over our frame, that slot is
    -- taken and the next close reports nothing that points at us, leaving the
    -- frame stranded. Any close while it is on screen dismisses it.
    if player.gui.screen[FRAME_NAME] then
      close(player)
    end
  end,

  [defines.events.on_gui_click] = function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then
      return
    end
    if event.element.name == BUTTON_NAME then
      toggle(player)
    elseif event.element.name == CLOSE_NAME then
      close(player)
    end
  end
}

return Public

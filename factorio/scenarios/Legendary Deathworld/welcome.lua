-- Info window shown to players when they first join,
-- with a top bar button to bring it back up at any time.
-- (Similar to the map intro in the Biter Battles scenario.)

local Public = {}

local FRAME_NAME = "ld_welcome_frame"
local BUTTON_NAME = "ld_welcome_button"
local CLOSE_NAME = "ld_welcome_close"

local function close(player)
  local frame = player.gui.screen[FRAME_NAME]
  if frame then
    frame.destroy()
  end
  -- Release player.opened only if it is still our frame; anything else
  -- belongs to another GUI and must be left alone.
  local opened = player.opened
  if opened and opened.valid and opened.name == FRAME_NAME then
    player.opened = nil
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
    Public.show(player)
  end,

  [defines.events.on_gui_closed] = function(event)
    -- Fired when the player closes our opened frame with E / ESC
    local gui = event.element
    if not (gui and gui.valid and gui.name == FRAME_NAME) then
      return
    end
    local player = game.get_player(event.player_index)
    if player and player.valid then
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

-- Info window shown to players when they first join,
-- with a top bar button to bring it back up at any time.
-- (Similar to the map intro in the Biter Battles scenario.)

local groups = require("groups")
local reset = require("reset")
local mod_gui = require("mod-gui")

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

  local inner_frame = frame.add{type = "frame", style = "inside_deep_frame", name = "inner_frame", direction = "vertical"}
  local tabbed_pane = inner_frame.add{type = "tabbed-pane", name = "tabbed_pane"}
  tabbed_pane.style.horizontally_stretchable = true

  local vote = tabbed_pane.add{type = "tab", caption = {"ld-tab-vote"}}
  local vote_content = tabbed_pane.add{type = "flow", style = "inset_frame_container_vertical_flow", name = "vote_tab", direction = "vertical"}
  vote_content.style.padding = 10
  vote_content.style.horizontally_stretchable = true
  vote_content.style.vertically_stretchable = true

  local about = tabbed_pane.add{type = "tab", caption = {"ld-tab-about"}}
  local about_content = tabbed_pane.add{type = "flow", style = "inset_frame_container_vertical_flow", name = "about_tab", direction = "vertical"}
  about_content.style.padding = 10
  local about_scroll = about_content.add{type = "scroll-pane", style = "deep_scroll_pane", name = "scroll_pane", horizontal_scroll_policy = "never"}
  about_scroll.style.horizontally_stretchable = true
  about_scroll.style.maximal_height = 360
  about_scroll.style.padding = 8
  local label = about_scroll.add{type = "label", caption = {"ld-welcome-text"}}
  label.style.single_line = false
  label.style.width = 500

  tabbed_pane.add_tab(vote, vote_content)
  tabbed_pane.add_tab(about, about_content)
  tabbed_pane.selected_tab_index = reset.is_reroll_active() and 1 or 2

  local bottom_buttons = frame.add{type = "flow", style = "dialog_buttons_horizontal_flow", name = "bottom_buttons"}
  local filler = bottom_buttons.add{type = "empty-widget", style = "draggable_space"}
  filler.style.horizontally_stretchable = true
  filler.style.vertically_stretchable = true
  filler.drag_target = frame
  local vote_buttons = bottom_buttons.add{type = "flow", direction = "horizontal", name = "vote_buttons"}
  reset.fill_vote_window(player, vote_content, vote_buttons)
  bottom_buttons.visible = tabbed_pane.selected_tab_index == 1
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
    player.gui.top[BUTTON_NAME].destroy()
  end
  local flow = mod_gui.get_button_flow(player)
  if flow[BUTTON_NAME] then
    return
  end
  flow.add
  {
    type = "sprite-button",
    name = BUTTON_NAME,
    sprite = "utility/custom_tag_icon",
    tooltip = {"ld-welcome-button-tooltip"},
    style = "slot_button",
    index = 1
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

  [defines.events.on_gui_selected_tab_changed] = function(event)
    local tabbed_pane = event.element
    if not (tabbed_pane and tabbed_pane.valid and tabbed_pane.name == "tabbed_pane") then
      return
    end
    local frame = tabbed_pane.parent and tabbed_pane.parent.parent
    if not (frame and frame.name == FRAME_NAME) then
      return
    end
    frame.bottom_buttons.visible = tabbed_pane.selected_tab_index == 1
  end,

  [defines.events.on_gui_click] = function(event)
    if not (event.element and event.element.valid) then
      return
    end
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

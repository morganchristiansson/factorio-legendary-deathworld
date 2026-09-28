local jail = require("jail")

local Public = {}

local TRUSTED_GROUP_NAME = "trusted"
local ALLOWED_ACTIONS = {
    "change_active_item_group_for_filters",
    "change_active_quick_bar",
    "clear_cursor",
    "gui_checked_state_changed",
    "gui_click",
    "gui_confirmed",
    "gui_elem_changed",
    "gui_hover",
    "gui_leave",
    "gui_location_changed",
    "gui_selected_tab_changed",
    "gui_selection_state_changed",
    "gui_switch_state_changed",
    "gui_text_changed",
    "gui_value_changed",
    "open_character_gui",
    "quick_bar_pick_slot",
    "quick_bar_set_selected_page",
    "quick_bar_set_slot",
    "remote_view_surface",
    "set_filter",
    "set_player_color",
    "spectator_change_surface",
    "toggle_show_entity_info",
    "write_to_console",
}

local function get_default_group()
    return game.permissions.get_group("Default")
end

-- The trusted group is the baseline "Default is not spectating" permissions,
-- so it must not be derived from Default's current state: a snapshot taken
-- while spectate mode was on captured the stripped set, and restoring from it
-- left Default deny-all with no way back (the group lives in the save, so the
-- bad snapshot outlived restarts). Full permissions are the baseline instead;
-- /trust is admin-only, so granting them is the admin's explicit choice.
local function get_trusted_group()
    local group = game.permissions.get_group(TRUSTED_GROUP_NAME)
    if not group then
        group = game.permissions.create_group(TRUSTED_GROUP_NAME)
        if not group then
            error("Could not create trusted permission group")
        end
    end
    for action_name in pairs(defines.input_action) do
        group.set_allows_action(defines.input_action[action_name], true)
    end
    return group
end

local function set_spectator_permissions()
    local default = get_default_group()
    for action_name in pairs(defines.input_action) do
        default.set_allows_action(defines.input_action[action_name], false)
    end
    for _, action_name in ipairs(ALLOWED_ACTIONS) do
        default.set_allows_action(defines.input_action[action_name], true)
    end
end

local function restore_default_permissions()
    local trusted = get_trusted_group()
    local default = get_default_group()
    for action_name in pairs(defines.input_action) do
        local action = defines.input_action[action_name]
        default.set_allows_action(action, trusted.allows_action(action))
    end
end

local function get_target(name)
    local player = game.get_player(name)
    if not player then
        return nil, "No such player: " .. tostring(name)
    end
    if jail.is_jailed(player.name) then
        return nil, player.name .. " is jailed and cannot change trust status"
    end
    return player
end

local function set_group(player, group)
    if player.permission_group == group then
        return false, player.name .. " is already in that permission group"
    end
    group.add_player(player.name)
    return true
end

local function set_default_spectate(enabled)
    if enabled then
        get_trusted_group()
        set_spectator_permissions()
    else
        restore_default_permissions()
    end
    log("event=default-spectate, enabled=" .. tostring(enabled))
end

Public.set_default_spectate = function(enabled)
    set_default_spectate(enabled)
end

-- Same check as disable_default_spectate, exposed for the join message.
Public.is_spectate_on = function()
    return not get_default_group().allows_action(defines.input_action.open_gui)
end

Public.disable_default_spectate = function()
    if Public.is_spectate_on() then
        set_default_spectate(false)
    end
end

Public.trust = function(name)
    local player, err = get_target(name)
    if not player then
        return false, err
    end
    local ok, change_err = set_group(player, get_trusted_group())
    if not ok then
        return false, change_err
    end

    game.print(player.name .. " is now trusted.")
    log("event=trust, target=" .. player.name)
    return true
end

Public.untrust = function(name)
    local player, err = get_target(name)
    if not player then
        return false, err
    end
    local ok, change_err = set_group(player, get_default_group())
    if not ok then
        return false, change_err
    end

    game.print(player.name .. " is now untrusted.")
    log("event=untrust, target=" .. player.name)
    return true
end

return Public

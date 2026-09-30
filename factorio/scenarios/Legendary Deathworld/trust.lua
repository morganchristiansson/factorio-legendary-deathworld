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
-- bad snapshot outlived restarts). Full permissions minus ALWAYS_DENIED are
-- the baseline instead; /trust is admin-only, so granting them is the admin's
-- explicit choice. The editor and cheat belong to the built-in server group:
-- game.permissions.get_group("server").add_player("<name>") from the console.
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

-- Permissions only, no controller switch: start_walking is absent, so
-- spectator mode also freezes the character, and nothing here lets a player
-- toggle themselves into a ghost (spectator_change_surface stays denied).
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
    Public.restrict_players()
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

local function enqueue_permission_op(op)
    storage.permission_ops = storage.permission_ops or {}
    table.insert(storage.permission_ops, op)
    log("event=permission-request, op=" .. (op.spectate ~= nil and "spectate" or "group")
        .. ", value=" .. tostring(op.spectate ~= nil and op.spectate or op.group)
        .. ", target=" .. tostring(op.player or "Default"))
end

local function set_group(player, group)
    if player.permission_group == group then
        return false, player.name .. " is already in that permission group"
    end
    -- Deferred, see apply_permission_ops: a direct add here is rolled back
    -- when the command came from a player's client.
    enqueue_permission_op({group = group.name, player = player.name})
    return true
end

-- Actions no player group ever gets. The map editor, cheat and permission
-- editing stay with the built-in server group -- two tiers, players in the
-- server group are the devs who need them. Without this the trusted baseline
-- below hands out the editor and cheat along with everything else.
local ALWAYS_DENIED = {
    "add_permission_group",
    "delete_permission_group",
    "edit_permission_group",
    "import_permissions_string",
    "map_editor_action",
    "toggle_map_editor",
    "change_multiplayer_config",
    "cheat",
}

-- Idempotent: safe to call after any group change. Trusted and Default end up
-- with the same permissions -- trusted exists to be immune to spectate mode,
-- not to hand out anything extra. Editor, cheat and permission editing stay
-- with the server group.
Public.restrict_players = function()
    for _, group in ipairs{get_trusted_group(), get_default_group()} do
        for _, action_name in ipairs(ALWAYS_DENIED) do
            group.set_allows_action(defines.input_action[action_name], false)
        end
    end
end

local function apply_default_spectate(enabled)
    if enabled then
        get_trusted_group()
        set_spectator_permissions()
    else
        restore_default_permissions()
    end
    log("event=spectate-mode, enabled=" .. tostring(enabled))
end

-----------------------------------------------------------------------
-- Permission changes made while a command from a player's client is being
-- processed are rolled back by the engine. Two independent sightings, same
-- signature -- the call returns, the log says it worked, nothing changed:
--   /spectate-mode on  -> event=spectate-mode enabled=true, Default left
--                          at its previous 271/279
--   /jail from another admin -> event=jail actual_group=server right after a
--                          successful add_player
-- The console path sticks, and so does a tick, which is why the gulag is
-- enforced from jail.lua's tick. So nothing here mutates permissions
-- directly: requests are queued and applied one tick later by the driver.
local apply_permission_ops = function()
    local ops = storage.permission_ops
    if not ops or #ops == 0 then return end
    storage.permission_ops = {}
    for _, op in ipairs(ops) do
        if op.spectate ~= nil then
            apply_default_spectate(op.spectate)
        else
            local group = game.permissions.get_group(op.group)
            local player = game.get_player(op.player)
            if group and player and player.valid then
                group.add_player(player.name)
                log(string.format("event=permission-applied, op=group, target=%s, group=%s, actual=%s",
                    player.name, op.group, player.permission_group and player.permission_group.name or "none"))
            end
        end
    end
end
script.on_nth_tick(1, apply_permission_ops)

Public.set_default_spectate = function(enabled)
    enqueue_permission_op({spectate = enabled and true or false})
end

-- Same check as disable_default_spectate, exposed for the join message.
Public.is_spectate_on = function()
    return not get_default_group().allows_action(defines.input_action.open_gui)
end

Public.disable_default_spectate = function()
    if Public.is_spectate_on() then
        enqueue_permission_op({spectate = false})
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

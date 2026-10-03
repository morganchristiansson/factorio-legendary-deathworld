-- Permission groups and who is in them.
--
-- Two kinds of membership. Baseline: Default for players, trusted for admins who
-- play (the same permissions, immune to spectate mode), server for the devs who
-- want the editor, cheat and permission editing. Temporary: freeze for a frozen
-- player, gulag for a jailed one -- both remembered in storage.temporary_group so
-- the player lands back where they came from, even through the other one.
--
-- The two temporary groups are the same idea at two strengths: the gulag is a
-- freeze that also loses the remote view, so a prisoner has the chat and
-- nothing to look at.
--
-- Nothing a player's command does may edit a group or move a player:
-- edit_permission_group is denied in every group an admin can be in, and
-- create_group returns nil for the same reason. Every change is therefore
-- queued and applied from a tick, where there is no acting player to be refused
-- by -- that is also where the restrictive groups get created in a save that
-- predates them. add_player reports whether a write landed, which the log
-- records: it is the only signal a failed write leaves.
-----------------------------------------------------------------------
local Public = {}

local DEFAULT_GROUP_NAME = "Default"
local TRUSTED_GROUP_NAME = "trusted"
local SERVER_GROUP_NAME = "server"
local GULAG_GROUP_NAME = "gulag"
local FREEZE_GROUP_NAME = "freeze"

-- What a frozen player may still do, and what /spectate-mode leaves in Default:
-- talk, read and click GUIs. start_walking is absent, so a frozen character is
-- stuck where it stands, and spectator_change_surface stays denied so nobody
-- becomes a ghost. One list for both -- spectate mode is Default stripped to
-- what a frozen player may do, so they cannot drift apart.
Public.FROZEN_ACTIONS = {
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

-- trusted and server are built by allowing everything, so they read as the
-- negation of SERVER_ONLY below rather than as another hand-kept list.
local ALL_ACTIONS = {}
for action_name in pairs(defines.input_action) do
    ALL_ACTIONS[#ALL_ACTIONS + 1] = action_name
end

-- Only the server group, the dev tier, ever gets these: the map editor, cheat,
-- and creating, deleting or editing groups -- the last of which is why no
-- command here writes a group itself.
local SERVER_ONLY = {
    "add_permission_group",
    "delete_permission_group",
    "edit_permission_group",
    "import_permissions_string",
    "map_editor_action",
    "toggle_map_editor",
    "change_multiplayer_config",
    "cheat",
}

-----------------------------------------------------------------------
-- Deny everything, then allow the listed actions. The policy is re-applied on
-- every call because a group made from the console arrives with the engine's own
-- permissions, and set_allows_action reports whether each value took, so the
-- refusals are counted rather than left to a later read.
local function make_group(name, allowed)
    local group = game.permissions.get_group(name) or game.permissions.create_group(name)
    if not group then
        log("event=permission-warning, reason=create-group-refused, group=" .. name)
        return nil
    end
    local refused = 0
    for action_name in pairs(defines.input_action) do
        if not group.set_allows_action(defines.input_action[action_name], false) then
            refused = refused + 1
        end
    end
    for _, action_name in ipairs(allowed) do
        if not group.set_allows_action(defines.input_action[action_name], true) then
            refused = refused + 1
        end
    end
    if refused > 0 then
        log(string.format("event=permission-warning, reason=set-action-refused, group=%s, count=%d", name, refused))
    end
    return group
end

local get_default_group = function()
    return game.permissions.get_group(DEFAULT_GROUP_NAME)
end

-- The trusted group is the baseline player permissions -- everything except
-- SERVER_ONLY -- built from scratch rather than copied out of Default, so
-- spectate mode has nothing to strip and the two cannot drift. It is a marker
-- for "an admin who plays", not extra power.
local get_trusted_group = function()
    return make_group(TRUSTED_GROUP_NAME, ALL_ACTIONS)
end

-- The admin tier. A fresh 2.0 save has no server group at all, so this creates
-- it -- which is why the console line that promotes a dev needs the group to
-- exist first:
--   game.permissions.get_group("server").add_player("<name>")
local get_server_group = function()
    return make_group(SERVER_GROUP_NAME, ALL_ACTIONS)
end

-- Chat and nothing else: a freeze that also loses the remote view, so there is
-- nothing in the pit to look at.
local get_gulag_group = function()
    return make_group(GULAG_GROUP_NAME, {"write_to_console"})
end

local get_freeze_group = function()
    return make_group(FREEZE_GROUP_NAME, Public.FROZEN_ACTIONS)
end

-- Both restrictive groups: on_init for a new save, the reset hook for the rest.
-- A save that ran the earlier name keeps its frozen players through the rename
-- rather than through a membership move, which would strand anyone mid-freeze
-- in a group nothing restores them from.
Public.ensure_groups = function()
    local old = game.permissions.get_group("spectate")
    if old then
        old.name = FREEZE_GROUP_NAME
        log("event=group-renamed, from=spectate, to=" .. FREEZE_GROUP_NAME)
    end
    get_gulag_group()
    get_freeze_group()
end

-- Idempotent: safe to call after any group change, and called on every reset so
-- a change to this list reaches saves that already had their first round.
Public.restrict_players = function()
    for _, group in ipairs{get_trusted_group(), get_default_group()} do
        for _, action_name in ipairs(SERVER_ONLY) do
            group.set_allows_action(defines.input_action[action_name], false)
        end
    end
end

-----------------------------------------------------------------------
-- Membership. One table for every temporary group a player passes through: the
-- group to put them back into, set on the way in and consumed on the way out.
-- /trust and /untrust are permanent and leave nothing behind.
local function set_group(player_name, group_name)
    storage.group_ops = storage.group_ops or {}
    table.insert(storage.group_ops, {player = player_name, group = group_name})
end
Public.set_group = set_group

local apply_group_changes = function()
    local ops = storage.group_ops
    if not ops or #ops == 0 then return end
    storage.group_ops = {}
    for _, op in ipairs(ops) do
        local group = game.permissions.get_group(op.group)
            or (op.group == GULAG_GROUP_NAME and get_gulag_group())
            or (op.group == FREEZE_GROUP_NAME and get_freeze_group())
        local player = game.get_player(op.player)
        if player and player.valid and group then
            local added = group.add_player(op.player)
            log(string.format("event=group-applied, target=%s, group=%s, added=%s",
                op.player, op.group, tostring(added)))
        end
    end
end
script.on_nth_tick(1, apply_group_changes)

local function get_temporary_table()
    storage.temporary_group = storage.temporary_group or {}
    return storage.temporary_group
end

local TEMPORARY_GROUPS = {[GULAG_GROUP_NAME] = true, [FREEZE_GROUP_NAME] = true}

Public.save_group = function(name, group_name)
    get_temporary_table()[name] = group_name
end

-- The way into a temporary group, from either command: remember where the
-- player is now, then move them. Only the way *in* is remembered -- entering one
-- temporary group from the other leaves the saved group alone, so freeze then
-- jail then /free lands back in freeze, and jail then freeze then /unfreeze
-- lands where they were taken from.
Public.enter_temporary = function(name, group_name)
    local player = game.get_player(name)
    if not player then
        return nil, "No such player: " .. tostring(name)
    end
    local group = player.permission_group and player.permission_group.name
    if not TEMPORARY_GROUPS[group] then
        Public.save_group(name, group or DEFAULT_GROUP_NAME)
    end
    set_group(name, group_name)
    return group
end

Public.restore_group = function(name)
    local previous = get_temporary_table()[name] or DEFAULT_GROUP_NAME
    get_temporary_table()[name] = nil
    set_group(name, previous)
    return previous
end

-----------------------------------------------------------------------
-- Freeze: the frozen permissions without leaving the map. A jailed player may
-- be frozen, and the gulag handler sends them back out of the pit -- one
-- handler owns every physical consequence of a group change, and this only
-- changes the group.
Public.is_frozen = function(name)
    local player = game.get_player(name)
    return player ~= nil and player.valid and player.permission_group ~= nil
        and player.permission_group.name == FREEZE_GROUP_NAME
end

Public.freeze = function(name)
    local target = game.get_player(name)
    if not target then
        return false, "No such player: " .. tostring(name)
    end
    if Public.is_frozen(name) then
        return false, name .. " is already frozen"
    end
    local previous = Public.enter_temporary(name, FREEZE_GROUP_NAME)
    game.print(name .. " is now frozen.")
    log(string.format("event=freeze, target=%s, source_group=%s", name, previous or "none"))
    return true
end

-- The way out of either temporary group: put the player back where they came
-- from. What that does to their body is not this module's business -- leaving
-- the gulag is what walks them out of the pit, and the gulag handler is the
-- only place that knows about the pit. Which group they were in only decides
-- how it is announced.
Public.release = function(actor, name)
    local target = game.get_player(name)
    if not target then
        return false, "No such player: " .. tostring(name)
    end
    local group = target.permission_group and target.permission_group.name
    if group == FREEZE_GROUP_NAME then
        local previous = Public.restore_group(name)
        game.print(name .. " is no longer frozen.")
        log(string.format("event=unfreeze, target=%s, actor=%s, restored_group=%s", name, actor, previous))
        return true
    end
    if group ~= GULAG_GROUP_NAME then
        return false, name .. " is neither jailed nor frozen"
    end
    local previous = Public.restore_group(name)
    game.print(string.format("%s was released from jail by %s.", name, actor))
    log(string.format("event=release, target=%s, actor=%s, restored_group=%s", name, actor, previous))
    return true
end

-- /trust and /untrust are permanent moves between the two baseline groups and
-- nothing else. A player in a temporary group, or in the server group, is
-- refused, so no stale entry is left behind for /free or /unfreeze to undo.
local function baseline_player(name, group_name)
    local player = game.get_player(name)
    if not player then
        return nil, "No such player: " .. tostring(name)
    end
    if not player.permission_group or player.permission_group.name ~= group_name then
        return nil, player.name .. " is not in the " .. group_name .. " group"
    end
    return player
end

Public.trust = function(name)
    local player, err = baseline_player(name, DEFAULT_GROUP_NAME)
    if not player then
        return false, err
    end
    set_group(player.name, TRUSTED_GROUP_NAME)
    game.print(player.name .. " is now trusted.")
    log("event=trust, target=" .. player.name)
    return true
end

Public.untrust = function(name)
    local player, err = baseline_player(name, TRUSTED_GROUP_NAME)
    if not player then
        return false, err
    end
    set_group(player.name, DEFAULT_GROUP_NAME)
    game.print(player.name .. " is now untrusted.")
    log("event=untrust, target=" .. player.name)
    return true
end

-----------------------------------------------------------------------
-- Spectate mode edits Default's permissions in place rather than moving
-- anyone: everybody who is not trusted or jailed gets the frozen set, new
-- joiners included, and /freeze is the per-player version of the same thing.
local function set_spectator_permissions()
    local default = get_default_group()
    for action_name in pairs(defines.input_action) do
        default.set_allows_action(defines.input_action[action_name], false)
    end
    for _, action_name in ipairs(Public.FROZEN_ACTIONS) do
        default.set_allows_action(defines.input_action[action_name], true)
    end
end

local function apply_default_spectate(enabled)
    if enabled then
        get_trusted_group() -- the baseline spectate mode restores from
        set_spectator_permissions()
    else
        local trusted = get_trusted_group()
        local default = get_default_group()
        for action_name in pairs(defines.input_action) do
            local action = defines.input_action[action_name]
            default.set_allows_action(action, trusted.allows_action(action))
        end
        Public.restrict_players()
    end
    log("event=spectate-mode, enabled=" .. tostring(enabled))
end

Public.set_default_spectate = function(enabled)
    apply_default_spectate(enabled == true)
end

-- Spectate mode is on exactly when Default can no longer open a GUI, which is
-- why it needs no flag of its own. Exposed for the join message.
Public.is_spectate_on = function()
    return not get_default_group().allows_action(defines.input_action.open_gui)
end

Public.disable_default_spectate = function()
    apply_default_spectate(false)
end

-----------------------------------------------------------------------
-- The single-player host is the only admin there, and in Default they have
-- neither the editor nor permission editing. on_player_created does not fire
-- when a save is loaded and on_singleplayer_init does not fire for a game that
-- was never multiplayer, so both hooks call this.
local function put_host_in_server_group(host)
    if game.is_multiplayer() or not (host and host.valid and host.admin) then
        return
    end
    if host.permission_group and host.permission_group.name == SERVER_GROUP_NAME then
        return
    end
    local server = get_server_group()
    if server then
        local added = server.add_player(host.name)
        log(string.format("event=host-in-server-group, target=%s, added=%s", host.name, tostring(added)))
    end
end

Public.on_init = function()
    Public.ensure_groups()
    get_server_group()
end

Public.events =
{
    [defines.events.on_player_created] = function(event)
        put_host_in_server_group(game.get_player(event.player_index))
    end,

    [defines.events.on_singleplayer_init] = function()
        put_host_in_server_group(game.player)
    end,
}

return Public
-- Run: lua5.4 test/permissions.lua  (from the repository root)
--
-- Exercises the permission-group round trips against a stub of the engine's
-- permission API: freeze, unfreeze, the gulag, and the temporary-group table
-- the two share. Guards the class of bug this file exists to prevent -- saving
-- the wrong group, leaving a stale entry, restoring the group a player was in
-- *before* a temporary one -- because getting it wrong locks an admin out of
-- their own server.
--
-- The stub raises on_permission_group_edited when a player is added to or
-- removed from a group, exactly as the engine does, so the gulag's teleports
-- are driven by the same event that drives them in the game rather than by the
-- commands that cause it.
local failures = 0
local function check(what, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", what, tostring(got), tostring(want)))
    end
end

-- Engine stubs -------------------------------------------------------------
-- add_player refuses when the caller lacks edit_permission_group, which is the
-- failure the commands have to survive; stub.refuse_adds turns that on.
local stub = {refuse_adds = false}
local stub_groups = {}
local players = {}
local event_handlers = {}
local nth_tick_handlers = {}

local function make_group(name)
    local group = {name = name, members = {}, allows = {}}
    function group.set_allows_action(action, value) group.allows[action] = value end
    function group.allows_action(action) return group.allows[action] == true end
    -- The engine moves the player's group pointer, raises the edit event and
    -- reports whether the write landed. The stub does all three, or nothing
    -- downstream sees the change and set_group has nothing to check.
    function group.add_player(player_name)
        if stub.refuse_adds then
            return false
        end
        group.members[player_name] = true
        local player = players[player_name]
        if not player then
            return true
        end
        player.permission_group = group
        local handler = event_handlers[defines.events.on_permission_group_edited]
        if handler then
            handler{type = "add-player", group = group, other_player_index = player.index}
        end
        return true
    end
    function group.remove_player(player_name)
        group.members[player_name] = nil
        local player = players[player_name]
        if not player then
            return true
        end
        if player.permission_group == group then
            player.permission_group = stub_groups["Default"]
        end
        local handler = event_handlers[defines.events.on_permission_group_edited]
        if handler then
            handler{type = "remove-player", group = group, other_player_index = player.index}
        end
        return true
    end
    stub_groups[name] = group
    return group
end
make_group("Default").allows = {walk = true, build = true, open_gui = true, write_to_console = true}

local next_index = 0
local function add_player(name, group_name)
    stub_groups[group_name] = stub_groups[group_name] or make_group(group_name)
    next_index = next_index + 1
    local player
    player = {
        index = next_index,
        name = name, valid = true, connected = true,
        permission_group = stub_groups[group_name],
        -- the gulag teleports move the player itself: no character, so
        -- player.teleport is the path taken
        physical_surface_index = 1,
        physical_position = {x = 3, y = 4},
        surface = {index = 1, name = 'nauvis'},
        teleport = function(_, surface_name) player.teleported_to = surface_name end,
        exit_remote_view = function() player.left_remote_view = true end,
        print = function() end,
    }
    players[name] = player
    stub_groups[group_name].members[name] = true
    return player
end

_G.defines = {
    input_action = {
        walk = "walk", build = "build", open_gui = "open_gui", write_to_console = "write_to_console",
        -- the actions restrict_players keeps off the baseline groups
        add_permission_group = "add_permission_group",
        delete_permission_group = "delete_permission_group",
        edit_permission_group = "edit_permission_group",
        import_permissions_string = "import_permissions_string",
        map_editor_action = "map_editor_action",
        toggle_map_editor = "toggle_map_editor",
        change_multiplayer_config = "change_multiplayer_config",
        cheat = "cheat",
    },
    gui_type = {none = 0},
    events = {
        on_tick = 1, on_player_joined_game = 2, on_player_changed_surface = 3,
        on_singleplayer_init = 4, on_player_created = 5,
        on_permission_group_edited = 6,
    },
}
_G.storage = {}
_G.log = function() end
_G.script = {
    on_nth_tick = function(tick, handler)
        nth_tick_handlers[tick] = nth_tick_handlers[tick] or {}
        table.insert(nth_tick_handlers[tick], handler)
    end,
    on_event = function(event, handler) event_handlers[event] = handler end,
    set_event_filter = function() end,
    active_mods = {},
}
-- The pit already exists, so ensure_gulag_surface returns it instead of
-- building tiles, walls and the song rig.
local nauvis = {index = 1, name = "nauvis", find_non_colliding_position = function() return {5, 5} end}
local gulag = {index = 2, name = "gulag", find_non_colliding_position = function() return {0, 0} end}
_G.game = {
    permissions = {
        get_group = function(name)
            local group = stub_groups[name]
            if group then
                return group
            end
            for _, candidate in pairs(stub_groups) do
                if candidate.name == name then
                    return candidate
                end
            end
        end,
        create_group = function(name) return make_group(name) end,
    },
    get_player = function(who)
        if type(who) == "number" then
            for _, player in pairs(players) do
                if player.index == who then
                    return player
                end
            end
            return nil
        end
        return players[who]
    end,
    print = function() end,
    is_multiplayer = function() return false end,
    surfaces = {[1] = nauvis, ["gulag"] = gulag},
    forces = {player = {get_spawn_position = function() return {0, 0} end}},
}

-- The scenario modules. In-game they all sit in one flat directory, so their
-- internal requires ("groups", "jail", "jail-song") resolve; here they load by
-- repo path, so those names are handed over instead. jail gets the groups module
-- we already loaded so both see the same instance.
package.preload["jail-song"] = function() return "" end

local groups = require("factorio/scenarios/Legendary Deathworld/groups")
package.loaded["groups"] = groups
local jail = require("factorio/scenarios/Legendary Deathworld/jail")

for _, module in ipairs{groups, jail} do
    for event, handler in pairs(module.events or {}) do
        event_handlers[event] = handler
    end
end

-- The stub above only knows a handful of actions; the frozen list names more.
-- set_allows_action is left strict, so a name that is not an input_action
-- still fails loudly here.
for _, name in ipairs(groups.FROZEN_ACTIONS) do
    defines.input_action[name] = name
end

-- Group changes are queued and land on a tick -- a command's client may not
-- edit a group -- so the tests drive one, exactly like the game does. That tick
-- is what raises on_permission_group_edited, which is what moves the players.
local function run_tick()
    for _, handler in ipairs(nth_tick_handlers[1] or {}) do
        handler()
    end
end

-- A save from the first version has the group as "spectate". Renaming it in
-- place keeps anyone frozen frozen, and keeps /unfreeze able to find them --
-- moving them to a new group instead would strand them in permissions nothing
-- restores out of.
make_group("spectate")
groups.ensure_groups()
check("gulag group created", stub_groups.gulag ~= nil, true)
check("the old spectate group was renamed in place", stub_groups.spectate.name, "freeze")

-- Freeze / unfreeze --------------------------------------------------------
add_player("bob", "Default")
check("freeze succeeds", groups.freeze("bob"), true)
run_tick()
check("frozen into the freeze group", players.bob.permission_group.name, "freeze")
check("saved home group", storage.temporary_group.bob, "Default")
check("freeze is idempotent-refused", groups.freeze("bob"), false)
check("trust is refused while frozen", groups.trust("bob"), false)
check("unfreeze", groups.unfreeze("bob"), true)
run_tick()
check("bob back to Default", players.bob.permission_group.name, "Default")
check("entry cleared", storage.temporary_group.bob, nil)
check("freezing moves nobody", players.bob.teleported_to, nil)
check("but it does close the map", players.bob.left_remote_view, true)

add_player("admin2", "trusted")
check("freeze a trusted player", groups.freeze("admin2"), true)
run_tick()
check("saved trusted", storage.temporary_group.admin2, "trusted")
check("unfreeze", groups.unfreeze("admin2"), true)
run_tick()
check("trusted restored", players.admin2.permission_group.name, "trusted")
check("entry cleared", storage.temporary_group.admin2, nil)
check("unfreeze is refused twice", groups.unfreeze("admin2"), false)

check("frozen group keeps console chat", stub_groups.spectate.allows_action("write_to_console"), true)
check("frozen group denies walking", stub_groups.spectate.allows_action("walk"), false)

-- The gulag: the group change lands, and the event is what puts them in the pit
add_player("dave", "trusted")
check("jail dave", jail.jail("morganc", "dave", "testing"), true)
check("nothing has moved yet", players.dave.teleported_to, nil)
run_tick()
check("jailed into the gulag group", players.dave.permission_group.name, "gulag")
check("and into the pit", players.dave.teleported_to, "gulag")
check("the record is kept until they leave", storage.jailed.dave ~= nil, true)

-- /free announces immediately and the event does the walking
check("free dave", jail.free("morganc", "dave"), true)
check("still in the pit until the group lands", players.dave.teleported_to, "gulag")
run_tick()
check("back to trusted", players.dave.permission_group.name, "trusted")
check("back to where they were taken from", players.dave.teleported_to, "nauvis")
check("the record is cleared on the way out", storage.jailed.dave, nil)
check("free is refused twice", jail.free("morganc", "dave"), false)

-- The admin tier survives a jail round trip, which is what the temporary-group
-- table is for: a jailed admin comes back as an admin, never as a player.
add_player("erin", "server")
storage.jailed = {erin = {surface_index = 1, position = {x = 3, y = 4}}}
storage.temporary_group.erin = "server"
check("free erin", jail.free("server", "erin"), true)
run_tick()
check("server group restored", players.erin.permission_group.name, "server")

-- The two temporary groups compose, in both directions ---------------------
-- Frozen, then jailed: /free puts them back in freeze, because only the way
-- *into* a temporary group is remembered.
add_player("frank", "Default")
storage.jailed = {}
check("freeze frank", groups.freeze("frank"), true)
run_tick()
check("frank starts frozen", players.frank.permission_group.name, "freeze")
storage.jailed = {}
check("jail frank", jail.jail("morganc", "frank", "griefer"), true)
run_tick()
check("jailed over the top of the freeze", players.frank.permission_group.name, "gulag")
check("and put in the pit", players.frank.teleported_to, "gulag")
check("freeze into jail kept the original group", storage.temporary_group.frank, "Default")
check("free frank", jail.free("morganc", "frank"), true)
run_tick()
check("out of the pit", players.frank.teleported_to, "nauvis")
check("back to Default, the group they came from", players.frank.permission_group.name, "Default")

-- Jailed, then frozen: freezing a prisoner walks them out of the pit, and the
-- jail record goes with them.
add_player("grace", "trusted")
check("jail grace", jail.jail("morganc", "grace", "griefer"), true)
run_tick()
check("grace is in the pit", players.grace.teleported_to, "gulag")
check("freezing a prisoner is allowed now", groups.freeze("grace"), true)
run_tick()
check("frozen instead of jailed", players.grace.permission_group.name, "freeze")
check("and out of the pit", players.grace.teleported_to, "nauvis")
check("with the jail record cleared", storage.jailed.grace, nil)
check("the group to restore is untouched", storage.temporary_group.grace, "trusted")
check("unfreeze returns them to trusted", groups.unfreeze("grace"), true)
run_tick()
check("grace back to trusted", players.grace.permission_group.name, "trusted")

-- Spectate mode edits Default in place -------------------------------------
groups.set_default_spectate(true)
check("spectate mode strips walking", stub_groups.Default.allows_action("walk"), false)
check("spectate mode keeps console", stub_groups.Default.allows_action("write_to_console"), true)
check("spectate mode flag", groups.is_spectate_on(), true)

groups.set_default_spectate(false)
check("spectate mode restores walking", stub_groups.Default.allows_action("walk"), true)
check("spectate mode flag clears", groups.is_spectate_on(), false)

-- /trust only applies to the baseline groups -------------------------------
check("trust bob", groups.trust("bob"), true)
run_tick()
check("bob is trusted", players.bob.permission_group.name, "trusted")
check("untrust bob", groups.untrust("bob"), true)
run_tick()
check("bob back in Default", players.bob.permission_group.name, "Default")
check("untrust is refused for a Default player", groups.untrust("bob"), false)

-- A refused write is visible only in the log: the command has already told the
-- admin it worked, because a queued write cannot report back. The apply
-- records added=false instead.
stub.refuse_adds = true
check("freeze still reports success", groups.freeze("bob"), true)
check("a refused freeze still saves the group to restore", storage.temporary_group.bob, "Default")
run_tick()
check("a refused freeze moves nobody", players.bob.permission_group.name, "Default")
stub.refuse_adds = false
check("and the entry is still there to restore", storage.temporary_group.bob, "Default")

print(failures == 0 and "ok" or (failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
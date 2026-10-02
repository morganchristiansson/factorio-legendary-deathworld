-- Run: lua5.4 test/permissions.lua  (from the repository root)
--
-- Exercises the permission-group round trips against a stub of the engine's
-- permission API: freeze/unfreeze, and the temporary-group table the gulag
-- shares with them. Guards the class of bug this file exists to prevent --
-- saving the wrong group, leaving a stale entry, restoring the group a player
-- was in *before* a temporary one -- because getting it wrong locks an admin
-- out of their own server.
--
-- Jail and spectate-mode are covered; the surface building in jail.lua is
-- not reachable from here and stays uncovered.
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
local function make_group(name)
    local group = {name = name, members = {}, allows = {}}
    function group.set_allows_action(action, value) group.allows[action] = value end
    function group.allows_action(action) return group.allows[action] == true end
    -- The engine moves the player's group pointer and reports whether the
    -- write landed; the stub has to do both, or nothing downstream sees the
    -- change and set_group has nothing to check.
    function group.add_player(player_name)
        if stub.refuse_adds then
            return false
        end
        group.members[player_name] = true
        local player = players[player_name]
        if player then player.permission_group = group end
        return true
    end
    function group.remove_player(player_name)
        group.members[player_name] = nil
        local player = players[player_name]
        if player and player.permission_group == group then player.permission_group = stub_groups["Default"] end
    end
    stub_groups[name] = group
    return group
end
make_group("Default").allows = {walk = true, build = true, open_gui = true, write_to_console = true}

local function add_player(name, group_name)
    stub_groups[group_name] = stub_groups[group_name] or make_group(group_name)
    players[name] = {
        name = name, valid = true, connected = true,
        permission_group = stub_groups[group_name],
        teleport = function() end,
    }
    stub_groups[group_name].members[name] = true
    return players[name]
end

local nth_tick_handlers = {}
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
    },
}
_G.storage = {}
_G.log = function() end
_G.script = {
    on_nth_tick = function(tick, handler)
        nth_tick_handlers[tick] = nth_tick_handlers[tick] or {}
        table.insert(nth_tick_handlers[tick], handler)
    end,
    on_event = function() end,
    set_event_filter = function() end,
    active_mods = {},
}
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
    get_player = function(name) return players[name] end,
    print = function() end,
    surfaces = {},
    forces = {player = {get_spawn_position = function() return {0, 0} end}},
}
-- The scenario modules. In-game they all sit in one flat directory, so their
-- internal requires ("groups", "jail", "jail-song") resolve; here they load by
-- repo path, so those names are handed over instead. jail gets the groups
-- module we already loaded so both see the same instance.
package.preload["jail-song"] = function() return "" end

local groups = require("factorio/scenarios/Legendary Deathworld/groups")
package.loaded["groups"] = groups
local jail = require("factorio/scenarios/Legendary Deathworld/jail")
-- The stub above only knows a handful of actions; the frozen list names more.
-- set_allows_action is left strict, so a name that is not an input_action
-- still fails loudly here.
for _, name in ipairs(groups.FROZEN_ACTIONS) do
    defines.input_action[name] = name
end

-- Group changes are queued and land on a tick -- a command's client may not
-- edit a group -- so the tests drive one, exactly like the game does.
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
check("the old spectate group was renamed in place", stub_groups.spectate.name, "freeze")
check("and is the freeze group the commands use", stub_groups.spectate.name, "freeze")
check("gulag group created", stub_groups.gulag ~= nil, true)

-- Freeze / unfreeze --------------------------------------------------------
add_player("bob", "Default")
check("freeze succeeds", groups.freeze("bob"), true)
run_tick()
check("frozen into the freeze group", players.bob.permission_group.name, "freeze")
check("saved home group", storage.temporary_group.bob, "Default")
check("freeze is idempotent-refused", groups.freeze("bob"), false)
run_tick()
check("trust is refused while frozen", groups.trust("bob"), false)
check("unfreeze", groups.unfreeze("bob"), true)
run_tick()
check("bob back to Default", players.bob.permission_group.name, "Default")
check("entry cleared", storage.temporary_group.bob, nil)

add_player("admin2", "trusted")
check("freeze a trusted player", groups.freeze("admin2"), true)
run_tick()
check("saved trusted", storage.temporary_group.admin2, "trusted")
check("unfreeze", groups.unfreeze("admin2"), true)
run_tick()
check("trusted restored", players.admin2.permission_group.name, "trusted")
check("entry cleared", storage.temporary_group.admin2, nil)
check("unfreeze is refused twice", groups.unfreeze("admin2"), false)

-- The gulag outranks spectate, and that is a statement about the group a
-- player is in, not about the jail record: groups.lua never looks at it.
add_player("carol", "gulag")
check("jailed players are not freezable", groups.freeze("carol"), false)
check("frozen group keeps console chat", stub_groups.spectate.allows_action("write_to_console"), true)
check("frozen group denies walking", stub_groups.spectate.allows_action("walk"), false)

-- /free restores whatever group the jail saved --------------------------------
-- jail.jail itself also builds the pit, so the saved state is seeded the way
-- it would be: a jail record plus the temporary-group entry.
game.surfaces = {[1] = {index = 1, name = "nauvis", find_non_colliding_position = function() return {5, 5} end}}
add_player("dave", "trusted")
storage.jailed = {dave = {surface_index = 1, position = {0, 0}}}
storage.temporary_group.dave = "trusted"
check("free dave", jail.free("server", "dave"), true)
run_tick()
check("trusted restored from the gulag", players.dave.permission_group.name, "trusted")
check("free clears the saved group", storage.temporary_group.dave, nil)
check("free clears the jail record", storage.jailed.dave, nil)

-- The admin tier survives a jail round trip, which is what the temporary-group
-- table is for: a jailed admin comes back as an admin, never as a player.
add_player("erin", "server")
storage.jailed = {erin = {surface_index = 1, position = {0, 0}}}
storage.temporary_group.erin = "server"
check("free erin", jail.free("server", "erin"), true)
run_tick()
check("server group restored", players.erin.permission_group.name, "server")

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

-- A refused write leaves nothing behind --------------------------------------
-- The admin groups may move players, anyone else is refused by the engine, and
-- a refused write must not half-do the thing it was asked for.
-- A refused write is visible only in the log: the command has already told
-- the admin it worked, because a queued write cannot report back. The apply
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
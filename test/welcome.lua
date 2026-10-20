-- Run: lua5.4 test/welcome.lua  (from the repository root)
--
-- Guards the welcome window's teardown against the two ways it has broken:
--
--   * player.opened is not always a GUI element. An equipment grid, entity,
--     item stack or player can hold the slot, and only GUI elements have a
--     name -- reading .name from any of the others raised "LuaEquipmentGrid
--     doesn't contain key name" inside on_player_joined_game and killed the
--     server.
--   * player.opened must be cleared *before* the frame is destroyed. After
--     destroy the reference is invalid, so a post-destroy check never matches
--     and the stale reference stops E / ESC from closing later windows.
--
-- The stubs mirror the engine on those points: destroying an element removes
-- it from its container and invalidates it, and destroy() records what
-- player.opened was at the moment it ran.
local failures = 0
local function check(what, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", what, tostring(got), tostring(want)))
    end
end

_G.defines = {
    events = {
        on_player_joined_game = 51,
        on_gui_closed = 52,
        on_gui_click = 53,
    },
}

package.preload["groups"] = function()
    return {is_spectate_on = function() return false end}
end

-- Engine objects are userdata: reading a key they don't have raises, which is
-- exactly how reading `.name` off an equipment grid killed the join handler.
local function strict_object(object_name, fields)
    return setmetatable(fields, {
        __index = function(_, key)
            error("Lua" .. object_name .. " doesn't contain key " .. tostring(key))
        end,
    })
end

local players = {}
_G.game = {
    get_player = function(index) return players[index] end,
}

-- Engine stubs -------------------------------------------------------------
local function new_element(name, container)
    local el = {
        name = name,
        valid = true,
        object_name = "LuaGuiElement",
        style = {},
        children = {},
    }
    function el.add(spec)
        local child = new_element(spec.name)
        el.children[#el.children + 1] = child
        return child
    end
    function el.destroy()
        if not el.valid then
            error("attempt to use a destroyed element: " .. tostring(name))
        end
        el.valid = false
        el.destroyed_with_opened = el.owner and el.owner.opened
        if container and container[name] == el then
            container[name] = nil
        end
    end
    return el
end

local function new_container()
    local c = {}
    function c.add(spec)
        local el = new_element(spec.name, c)
        if spec.name then
            c[spec.name] = el
        end
        return el
    end
    return c
end

local function make_player(name, index)
    local player = {
        name = name,
        index = index,
        valid = true,
        gui = {screen = new_container(), top = new_container()},
        printed = {},
    }
    function player.print(message) player.printed[#player.printed + 1] = message end
    players[index] = player
    return player
end

local welcome = require("factorio/scenarios/Legendary Deathworld/welcome")
local join = welcome.events[defines.events.on_player_joined_game]
local closed = welcome.events[defines.events.on_gui_closed]

local FRAME_NAME = "ld_welcome_frame"
local BUTTON_NAME = "ld_welcome_button"

-- Opening the window must not crash when the slot holds a non-GUI object ----
local grid = strict_object("LuaEquipmentGrid", {valid = true, object_name = "LuaEquipmentGrid"})
local player = make_player("armor", 1)
player.opened = grid

local ok, err = pcall(join, {player_index = 1})
check("joining with an equipment grid opened does not error", ok, true)
check("the error is not the name lookup", tostring(err):find("doesn't contain key name") == nil, true)
local frame = player.gui.screen[FRAME_NAME]
check("the window is shown", frame ~= nil and frame.valid, true)
check("the window takes the opened slot", player.opened, frame)
check("the top-bar button is added", player.gui.top[BUTTON_NAME] ~= nil, true)

-- player.opened is cleared before the frame is destroyed ---------------------
frame = player.gui.screen[FRAME_NAME]
frame.owner = player
closed{player_index = 1}
check("closing clears player.opened", player.opened, nil)
check("closing destroys the frame", player.gui.screen[FRAME_NAME], nil)
check("destroy saw no opened reference", frame.destroyed_with_opened, nil)

-- ESC / E with no element still dismisses the window -------------------------
player = make_player("escape", 2)
join{player_index = 2}
frame = player.gui.screen[FRAME_NAME]
check("a fresh join shows the window", frame ~= nil and frame.valid, true)
-- The engine reports no element when another window held the slot; the frame
-- must still be dismissed rather than stranded.
closed{player_index = 2}
check("an element-less close dismisses the window", player.gui.screen[FRAME_NAME], nil)

-- A non-GUI object in the slot is left alone --------------------------------
player = make_player("chest", 3)
join{player_index = 3}
local entity = strict_object("LuaEntity", {valid = true, object_name = "LuaEntity", name = "wooden-chest"})
player.opened = entity
closed{player_index = 3}
check("another window's object is not cleared", player.opened, entity)
check("our frame is still dismissed", player.gui.screen[FRAME_NAME], nil)

-- An entity named like our frame (it has .name too) is not mistaken for it ---
player = make_player("decoy", 4)
join{player_index = 4}
local decoy = strict_object("LuaGuiElement", {valid = true, object_name = "LuaGuiElement", name = "some-other-frame"})
player.opened = decoy
closed{player_index = 4}
check("a foreign GUI element is not cleared", player.opened, decoy)

-- The window is recreated, not stacked, on a repeat join ---------------------
player = make_player("rejoin", 5)
join{player_index = 5}
local first = player.gui.screen[FRAME_NAME]
join{player_index = 5}
local second = player.gui.screen[FRAME_NAME]
check("a repeat join destroys the old frame", first.valid, false)
check("and replaces it", second ~= nil and second ~= first and second.valid, true)
check("the reopened frame takes the opened slot", player.opened, second)

print(failures == 0 and "ok" or (failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)

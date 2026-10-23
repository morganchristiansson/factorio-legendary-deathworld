-- Run: lua5.4 test/offline-corpse.lua  (from the repository root)
--
-- Exercises the offline corpse against a stub of the engine: a player who
-- stays away past the timeout leaves a corpse with their gear and an empty
-- inventory, a player who comes back in time keeps everything, and a player
-- with nothing to carry leaves nothing behind.
local failures = 0
local function check(what, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", what, tostring(got), tostring(want)))
    end
end

-- Engine stubs -------------------------------------------------------------
local printed = {}
local created = {}
local players = {}
local next_index = 0

local function make_inventory(items)
    local inv = {items = items or {}, valid = true}
    function inv.clear() inv.items = {} end
    -- The engine's inventory is indexable and has a length; the stub answers
    -- both from the items it holds.
    return setmetatable(inv, {
        __index = function(self, i) return self.items[i] end,
        __len = function(self) return #self.items end,
    })
end

-- The corpse holds one stack: anything beyond that is refused, so the test
-- can check that the overflow lands on the ground.
local corpse_items = {}
local corpse_inventory = make_inventory(corpse_items)
function corpse_inventory.insert(stack)
    if #corpse_items >= 1 then return 0 end
    table.insert(corpse_items, stack)
    return stack.count
end

local nauvis = {name = "nauvis", valid = true}
function nauvis.create_entity(args)
    table.insert(created, args)
    if args.name == "character-corpse" then
        return {active = true, get_inventory = function() return corpse_inventory end}
    end
    return {active = true}
end

_G.defines = {
    inventory = {
        character_main = 1, character_guns = 2, character_ammo = 3,
        character_armor = 4, character_trash = 5, character_corpse = 6,
    },
    events = {on_pre_player_left_game = 1},
}
_G.storage = {}
_G.prototypes = {entity = {["character-corpse"] = {}}}
_G.log = function() end
_G.game = {
    tick = 0,
    get_player = function(who)
        if type(who) == "number" then
            for _, player in pairs(players) do
                if player.index == who then return player end
            end
            return nil
        end
        return players[who]
    end,
    print = function(message) table.insert(printed, message) end,
    surfaces = {nauvis = nauvis, ["nauvis"] = nauvis},
}

local function add_player(name, items)
    local inventories = {
        [defines.inventory.character_main] = make_inventory(items or {}),
        [defines.inventory.character_guns] = make_inventory({}),
        [defines.inventory.character_ammo] = make_inventory({}),
        [defines.inventory.character_armor] = make_inventory({}),
        [defines.inventory.character_trash] = make_inventory({}),
    }
    local player = {
        index = next_index + 1,
        name = name, valid = true, connected = true,
        physical_position = {x = 10, y = 20},
        physical_surface = nauvis,
        -- The engine exposes get_inventory as a closure, so the module calls it
        -- with a dot.
        get_inventory = function(id) return inventories[id] end,
        inventories = inventories,
    }
    next_index = next_index + 1
    players[name] = player
    return player
end

-- register.lua's module scope is engine-free; the module only arms and
-- disarms the worker at runtime, so the stub keeps the worker and lets the
-- test fire it.
local register_stub = {defined = {}, armed = {}}
package.preload["register"] = function()
    return {
        nth_tick = function(key, cadence, fn) register_stub.defined[key] = fn end,
        arm = function(key) register_stub.armed[key] = true end,
        disarm = function(key) register_stub.armed[key] = nil end,
    }
end

local offline_corpse = require("factorio/scenarios/Legendary Deathworld/offline_corpse")
offline_corpse.on_init()
local leave = offline_corpse.events[defines.events.on_pre_player_left_game]

local function run_worker()
    local fn = register_stub.defined["offline-corpse"]
    if fn then fn() end
end

-- The player leaves -------------------------------------------------------
local bob = add_player("bob", {{name = "pistol", count = 1, valid_for_read = true}})
leave{player_index = bob.index}
check("the worker is armed", register_stub.armed["offline-corpse"], true)
check("the pending table has the player", storage.offline_corpse[bob.index] ~= nil, true)

-- Back before the timeout: the gear is still theirs.
game.tick = 60 * 60
bob.connected = true
run_worker()
check("no corpse for a player who came back", #created, 0)
check("the gear is still theirs", #bob.inventories[defines.inventory.character_main].items, 1)

-- Away past the timeout: the corpse appears, the gear goes into it.
corpse_items = {}
bob.connected = false
game.tick = 20 * 60 * 60
run_worker()
check("a corpse is left behind", #created, 1)
check("it is a character-corpse", created[1] and created[1].name, "character-corpse")
check("it lies where the player left", created[1] and created[1].position.x, 10)
check("it is the player's corpse", created[1] and created[1].player_index, bob.index)
check("the gear is in the corpse", #corpse_items, 1)
check("the inventory is empty", #bob.inventories[defines.inventory.character_main].items, 0)
check("the pending entry is cleared", storage.offline_corpse[bob.index], nil)
check("the worker disarms itself", register_stub.armed["offline-corpse"], nil)
check("the corpse is announced", #printed, 1)

-- A player with nothing to carry leaves nothing behind ---------------------
corpse_items = {}
local erin = add_player("erin", {})
leave{player_index = erin.index}
erin.connected = false
game.tick = 40 * 60 * 60
run_worker()
check("no corpse without gear", #created, 1)
check("the worker disarms again", register_stub.armed["offline-corpse"], nil)

-- A corpse that cannot hold everything drops the rest on the ground --------
corpse_items = {}
local frank = add_player("frank", {
    {name = "pistol", count = 1, valid_for_read = true},
    {name = "firearm-magazine", count = 10, valid_for_read = true},
})
leave{player_index = frank.index}
frank.connected = false
game.tick = 60 * 60 * 60
run_worker()
check("the corpse holds what fits", #corpse_items, 1)
check("the rest lies on the ground", created[#created].name, "item-on-ground")
check("and the inventory is empty", #frank.inventories[defines.inventory.character_main].items, 0)

print(failures == 0 and "ok" or (failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)

local reset = require("reset")

local Public = {}

local SHALLOW = {
    ["water"] = "water-shallow",
    ["water-green"] = "water-shallow",
    ["deepwater"] = "water-mud",
    ["deepwater-green"] = "water-mud",
    ["gleba-deep-lake"] = "water-mud",
}
local DEEP_NAMES = {}
for name in pairs(SHALLOW) do
    DEEP_NAMES[#DEEP_NAMES + 1] = name
end

local on_chunk_generated = function(event)
    local surface = event.surface
    if not reset.is_round_surface(surface) then
        return
    end
    local tiles = {}
    for _, tile in pairs(surface.find_tiles_filtered{area = event.area, name = DEEP_NAMES}) do
        tiles[#tiles + 1] = {name = SHALLOW[tile.name], position = tile.position}
    end
    if #tiles > 0 then
        surface.set_tiles(tiles)
    end
end

Public.events = {
    [defines.events.on_chunk_generated] = on_chunk_generated,
}

return Public

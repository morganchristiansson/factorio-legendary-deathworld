local Public = {}

Public.set_enabled = function(enabled)
    storage.ied_biters = enabled
    log("event=ied-biters, enabled=" .. tostring(enabled))
end

Public.on_unit_died = function(event)
    if not storage.ied_biters or math.random(1, 2) ~= 1 then
        return
    end
    local surface = game.surfaces[event.surface_index]
    local tile = {x = math.floor(event.position.x) + 0.5, y = math.floor(event.position.y) + 0.5}
    if surface.can_place_entity{name = "land-mine", position = tile, force = "enemy"} then
        surface.create_entity{name = "land-mine", position = tile, force = "enemy"}
    end
end

return Public

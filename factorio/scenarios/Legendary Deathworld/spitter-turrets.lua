local Public = {}

local AMMO = {
    ["small-spitter"] = {name = "firearm-magazine", count = 10},
    ["medium-spitter"] = {name = "firearm-magazine", count = 20},
    ["big-spitter"] = {name = "piercing-rounds-magazine", count = 10},
    ["behemoth-spitter"] = {name = "uranium-rounds-magazine", count = 20},
}

Public.set_enabled = function(enabled)
    storage.spitter_turrets = enabled
    log("event=spitter-turrets, enabled=" .. tostring(enabled))
end

Public.on_unit_died = function(event)
    local ammo = AMMO[event.prototype.name]
    if not storage.spitter_turrets or not ammo or math.random(1, 10) ~= 1 then
        return
    end
    local surface = game.surfaces[event.surface_index]
    local position = surface.find_non_colliding_position("gun-turret", event.position, 4, 0.5)
    if not position then
        return
    end
    local turret = surface.create_entity{name = "gun-turret", position = position, force = "enemy", quality = event.quality}
    if turret then
        turret.insert{name = ammo.name, count = ammo.count}
    end
end

return Public

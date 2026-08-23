-- Adds/updates unit spawn curves in biter-spawner and spitter-spawner.
-- Startup settings hold semicolon-separated entries:
--   "<unit-name> <evo=weight,evo=weight,...>"
-- A unit present in the spawner's result_units gets its curve replaced;
-- others are appended. Empty setting = no changes. Curves are used as
-- written (piecewise-linear, same semantics as vanilla result_units).

local function set_curve(spawner_name, value)
  if value:match("^%s*$") then return end
  local spawner = data.raw["unit-spawner"][spawner_name]
  for entry in value:gmatch("[^;]+") do
    local unit_name, curve_str = entry:match("^%s*(%S+)%s+(.-)%s*$")
    local points = {}
    for evo, weight in curve_str:gmatch("(%d+%.?%d*)=(%d+%.?%d*)") do
      points[#points + 1] = { tonumber(evo), tonumber(weight) }
    end
    assert(#points > 0, 'ldw-server: no valid evo=weight pairs in "' .. entry .. '"')
    local replaced = false
    for _, unit in ipairs(spawner.result_units) do
      if unit[1] == unit_name then
        unit[2] = points
        replaced = true
      end
    end
    if replaced then
      log('ldw-server: updated "' .. unit_name .. '" in ' .. spawner_name)
    else
      spawner.result_units[#spawner.result_units + 1] = { unit_name, points }
      log('ldw-server: added "' .. unit_name .. '" to ' .. spawner_name)
    end
  end
end

set_curve("biter-spawner", settings.startup["ldw-server-biter-pentapods"].value)
set_curve("spitter-spawner", settings.startup["ldw-server-spitter-pentapods"].value)

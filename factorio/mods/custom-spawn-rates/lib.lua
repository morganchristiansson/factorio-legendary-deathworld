-- Shared logic for Custom Spawn Rates.
-- Parses spawn-rate settings and applies them to unit-spawner prototypes.
-- Deliberately free of Factorio API calls except the global log(), so the
-- test suite (tests/) can exercise it with plain Lua and stubs.
--
-- Two kinds of startup settings feed this module:
--
-- 1. One setting per well-known spawner (KNOWN_SPAWNERS). Its value holds
--    semicolon-separated entries for that nest only:
--      <unit-name> <evo=rate,evo=rate,...>   add or override the rates
--      -<unit-name>                          remove the unit from the nest
--
-- 2. One free-form "extra" setting for modded spawners, made of sections:
--      some-modded-spawner: <entry>;<entry>
--    A '<spawner-name>:' header starts a new section; subsequent entries
--    belong to it until the next header. Blank value means no changes.
--
-- Rate-table semantics (vanilla result_units): the engine interpolates
-- linearly between pairs and normalises shares across the nest at every
-- evolution level. Rate is 0 below the first pair's evolution factor —
-- no leading 0=0 pair is needed to delay a unit's appearance.

local SETTING_PREFIX = "custom-spawn-rates-"
local EXTRA_SETTING_NAME = "custom-spawn-rates-extra"

local SpawnRates = {}

SpawnRates.SETTING_PREFIX = SETTING_PREFIX
SpawnRates.EXTRA_SETTING_NAME = EXTRA_SETTING_NAME

-- Spawners that get their own dedicated startup setting. The settings
-- stage cannot read data.raw, so this list is hardcoded; settings for
-- absent prototypes are harmless and skipped by data-final-fixes. Any
-- other (modded) spawner is reachable through EXTRA_SETTING_NAME.
-- Defaults are blank (nest untouched): a non-blank default naming a
-- Space Age unit would hard-fail map load on base-only installs, and the
-- data stage cannot tell a default from an explicit user value.
-- Gleba nests are 'gleba-spawner' / 'gleba-spawner-small' as of 2.0.77
-- ('egg-raft' names appear nowhere in the dumped data.raw).
SpawnRates.KNOWN_SPAWNERS = {
    { name = "biter-spawner", default = "" },
    { name = "spitter-spawner", default = "" },
    { name = "gleba-spawner-small", default = "" },
    { name = "gleba-spawner", default = "" },
}

-- Parse "0.2=0.00,0.6=0.40" into {{0.2, 0.0}, {0.6, 0.4}}, sorted by evo.
-- Returns points, nil on success or nil, error_message on failure.
function SpawnRates.parse_rate(rate_str)
    local points = {}
    for evo_str, rate_str_pair in rate_str:gmatch("(%d+%.?%d*)%s*=%s*(%d+%.?%d*)") do
        local evo, rate = tonumber(evo_str), tonumber(rate_str_pair)
        if evo > 1 then
            return nil, "evolution factor " .. evo .. " is above 1"
        end
        points[#points + 1] = { evo, rate }
    end
    if #points == 0 then
        return nil, "no valid evo=rate pairs"
    end
    table.sort(points, function(a, b) return a[1] < b[1] end)
    return points
end

-- Parse one entry. On success returns mode ("set"/"remove"), unit_name
-- and points; on failure returns nil and an error message.
function SpawnRates.parse_entry(entry)
    local remove = entry:match("^%s*-")
    local body = entry:gsub("^%s*-%s*", "")
    local unit_name, rest = body:match("^%s*(%S+)%s*(.-)$")
    if not unit_name then
        return nil, "empty entry"
    end
    if remove then
        return "remove", unit_name, nil
    end
    if rest == "" then
        return nil, "missing rate table after '" .. unit_name .. "'"
    end
    local points, err = SpawnRates.parse_rate(rest)
    if not points then
        return nil, err .. " ('" .. rest .. "')"
    end
    return "set", unit_name, points
end

-- Split the extra setting's value into {spawner_name = entry_text}.
-- Entries before any header are returned separately as orphans so callers
-- can warn about them: a headerless entry would otherwise be silently
-- dropped, which reads as "the mod does nothing". Blank value yields
-- empty map and no orphans.
function SpawnRates.parse_overrides(value)
    -- '#' starts a comment (to ';' or end of line); '#' is illegal in
    -- prototype names and values, so this never eats real input.
    value = value:gsub("#[^;\n]*", "")
    local overrides = {}
    local orphans = {}
    local current = nil
    for token in value:gmatch("[^;]+") do
        local spawner_name = token:match("^%s*([%w%-%_.]+)%s*:")
        if spawner_name then
            current = spawner_name
            token = token:gsub("^%s*[%w%-%_.]+%s*:%s*", "", 1)
            overrides[current] = ""
        elseif current == nil then
            local orphan = token:match("^%s*(.-)%s*$")
            if orphan ~= "" then orphans[#orphans + 1] = orphan end
            token = ""
        end
        if current then
            local entry = token:match("^%s*(.-)%s*$")
            if entry ~= "" then
                if overrides[current] == "" then
                    overrides[current] = entry
                else
                    overrides[current] = overrides[current] .. ";" .. entry
                end
            end
        end
    end
    return overrides, orphans
end

-- Apply one parsed entry to a spawner's result_units. Invalid unit
-- references are deliberately left in place: the engine rejects them at
-- prototype load with a hard error naming the spawner, which surfaces
-- typos instead of silently dropping entries.
function SpawnRates.apply_entry(spawner, spawner_name, mode, unit_name, points)
    if mode == "set" then
        local replaced = false
        for _, unit in ipairs(spawner.result_units) do
            if unit[1] == unit_name then
                unit[2] = points
                replaced = true
                break
            end
        end
        if replaced then
            log(SETTING_PREFIX .. 'updated "' .. unit_name .. '" in ' .. spawner_name)
        else
            spawner.result_units[#spawner.result_units + 1] = { unit_name, points }
            log(SETTING_PREFIX .. 'added "' .. unit_name .. '" to ' .. spawner_name)
        end
    elseif mode == "remove" then
        local kept = {}
        local removed = false
        for _, unit in ipairs(spawner.result_units) do
            if unit[1] == unit_name then
                removed = true
            else
                kept[#kept + 1] = unit
            end
        end
        if removed then
            spawner.result_units = kept
            log(SETTING_PREFIX .. 'removed "' .. unit_name .. '" from ' .. spawner_name)
        else
            log(SETTING_PREFIX .. '"' .. unit_name .. '" not present in ' ..
                spawner_name .. " — nothing to remove")
        end
    end
end

-- Apply one spawner's entry text ("<entry>;<entry>;...") to its prototype.
-- Malformed entries are logged and skipped rather than asserted: bad user
-- input must not block map loading.
function SpawnRates.apply_setting(spawner, spawner_name, value)
    value = value:gsub("#[^;\n]*", "")
    if value:match("^%s*$") then return end
    for entry in value:gmatch("[^;]+") do
        if entry:match("%S") then
            local mode, second, third = SpawnRates.parse_entry(entry)
            if not mode then
                log(SETTING_PREFIX .. 'bad entry "' .. entry .. '" for ' ..
                    spawner_name .. ": " .. tostring(second))
            else
                SpawnRates.apply_entry(spawner, spawner_name, mode, second, third)
            end
        end
    end
end

return SpawnRates

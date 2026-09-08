-- Applies the spawn-rate and tech settings to prototypes. Runs in
-- data-final-fixes so units/techs added by other mods' updates/final-fixes
-- are already defined.

local SpawnRates = require("lib")
local Tech = require("tech")

local PREFIX = SpawnRates.SETTING_PREFIX

-- Applies a free-form section setting ("name: <entry>;<entry>") to
-- prototypes. find(name) returns the prototype or nil; apply(proto, name,
-- entry_text) performs the change. Unknown names and headerless entries
-- are logged and skipped. Per-op change lines go to the print() report
-- inside apply(); warnings stay on log(). No echo of the raw value here.
local function apply_sections(value, noun, header_hint, find, apply)
    local sections, orphans = SpawnRates.parse_overrides(value or "")
    for _, orphan in ipairs(orphans) do
        -- Almost always a missing colon after the section name.
        log(PREFIX .. 'entry "' .. orphan .. '" is outside any "' ..
            header_hint .. '" section and was ignored' ..
            " (missing colon after the " .. noun .. " name?)")
    end
    for name, entry_text in pairs(sections) do
        local proto = find(name)
        if not proto then
            log(PREFIX .. noun .. ' "' .. name .. '" does not exist — skipping')
        else
            apply(proto, name, entry_text)
        end
    end
end

local function find_spawner(name)
    local spawner = data.raw["unit-spawner"][name]
    -- Absent on this install (e.g. Gleba nests without Space Age), or
    -- nothing to override.
    if spawner and spawner.result_units then return spawner end
    return nil
end

local function find_tech(name)
    if data.raw["technology"] then return data.raw["technology"][name] end
    return nil
end

-- Dedicated per-nest settings for the known spawners.
for _, known in ipairs(SpawnRates.KNOWN_SPAWNERS) do
    local spawner_name = known.name
    local setting = settings.startup[PREFIX .. spawner_name]
    if setting and not setting.value:match("^%s*$") then
        local spawner = find_spawner(spawner_name)
        if not spawner then
            log(PREFIX .. 'spawner "' .. spawner_name ..
                '" does not exist — skipping')
        else
            SpawnRates.apply_setting(spawner, spawner_name, setting.value)
        end
    end
end

-- Free-form sections for modded spawners.
local extra = settings.startup[SpawnRates.EXTRA_SETTING_NAME]
apply_sections(extra and extra.value or "", "spawner", "spawner-name:",
    find_spawner, SpawnRates.apply_setting)

-- Free-form tech sections.
local tech_value = settings.startup[Tech.TECH_SETTING_NAME]
apply_sections(tech_value and tech_value.value or "", "technology", "tech-name:",
    find_tech, Tech.apply_setting)

-- Applies the spawn-rate settings to unit-spawner prototypes. Runs in
-- data-final-fixes so units added by other mods' updates/final-fixes are
-- already defined and can be validated against data.raw["unit"].

local SpawnRates = require("lib")

-- Dedicated per-nest settings for the known spawners.
for _, known in ipairs(SpawnRates.KNOWN_SPAWNERS) do
    local spawner_name = known.name
    local setting = settings.startup[SpawnRates.SETTING_PREFIX .. spawner_name]
    if setting and not setting.value:match("^%s*$") then
        local spawner = data.raw["unit-spawner"][spawner_name]
        if not spawner or not spawner.result_units then
            -- Prototype is absent or has nothing to override (e.g. the
            -- Space Age rafts on a base-only install).
            log(SpawnRates.SETTING_PREFIX .. 'spawner "' .. spawner_name ..
                '" does not exist — skipping')
        else
            log(SpawnRates.SETTING_PREFIX .. spawner_name .. ': applying "' ..
                setting.value .. '"')
            SpawnRates.apply_setting(spawner, spawner_name, setting.value)
        end
    end
end

-- Free-form sections for modded spawners.
local extra = settings.startup[SpawnRates.EXTRA_SETTING_NAME]
local overrides, orphans = SpawnRates.parse_overrides(extra and extra.value or "")
for _, orphan in ipairs(orphans) do
    -- Almost always a missing colon after the spawner name.
    log(SpawnRates.SETTING_PREFIX .. 'entry "' .. orphan ..
        '" is outside any "spawner-name:" section and was ignored' ..
        " (missing colon after the spawner name?)")
end
for spawner_name, entry_text in pairs(overrides) do
    local spawner = data.raw["unit-spawner"][spawner_name]
    if not spawner or not spawner.result_units then
        log(SpawnRates.SETTING_PREFIX .. 'spawner "' .. spawner_name ..
            '" does not exist — skipping')
    else
        SpawnRates.apply_setting(spawner, spawner_name, entry_text)
    end
end

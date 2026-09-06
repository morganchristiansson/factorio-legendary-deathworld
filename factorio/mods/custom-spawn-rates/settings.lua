-- Defines this mod's startup string-settings.
--
-- The settings stage has no access to data.raw, so spawners cannot be
-- enumerated dynamically here. Instead every well-known vanilla/Space Age
-- nest gets its own dedicated setting (see KNOWN_SPAWNERS), plus one
-- free-form setting whose section syntax reaches any modded spawner.
-- Settings for absent prototypes are harmless; data-final-fixes skips
-- spawners that do not exist or lack result_units.

local SpawnRates = require("lib")
local Tech = require("tech")

for _, known in ipairs(SpawnRates.KNOWN_SPAWNERS) do
    data:extend({
        {
            type = "string-setting",
            name = SpawnRates.SETTING_PREFIX .. known.name,
            -- Label is the raw prototype name: the syntax everywhere else
            -- (entries, extra-nest headers) also uses prototype names.
            localised_name = known.name,
            localised_description = { "custom-spawn-rates.setting-tooltip" },
            setting_type = "startup",
            default_value = known.default,
            allow_blank = true,
        },
    })
end

data:extend({
    {
        type = "string-setting",
        name = Tech.TECH_SETTING_NAME,
        localised_name = { "custom-spawn-rates.tech-name" },
        localised_description = { "custom-spawn-rates.tech-tooltip" },
        setting_type = "startup",
        default_value = "",
        allow_blank = true,
    },
    {
        type = "string-setting",
        name = SpawnRates.EXTRA_SETTING_NAME,
        localised_name = { "custom-spawn-rates.extra-name" },
        localised_description = { "custom-spawn-rates.extra-tooltip" },
        setting_type = "startup",
        default_value = "",
        allow_blank = true,
    },
})

-- Shared logic for tech-tree tweaks.
-- Parses the tech setting and applies it to technology prototypes.
-- Deliberately free of Factorio API calls except the global log(), so the
-- test suite (tests/) can exercise it with plain Lua and stubs.
--
-- One free-form startup setting holds sections:
--   biolab: <op>;<op>
-- A '<tech-name>:' header starts a new section; subsequent entries belong
-- to it until the next header. Blank value means no changes. Later entries
-- win within a section. Outer shape mirrors lib.lua on purpose:
-- set is '<field> <value>', remove is '-<field>', '=' only inside values.
-- Section splitting is shared: callers use SpawnRates.parse_overrides.

local PREFIX = "custom-spawn-rates-"
local TECH_SETTING_NAME = "custom-spawn-rates-tech"

local Tech = {}

Tech.PREFIX = PREFIX
Tech.TECH_SETTING_NAME = TECH_SETTING_NAME

-- Parse a comma-separated name list ("a,b,c") into an array. Empty/blank
-- yields an empty list (clears). Returns list or nil, error.
local function parse_name_list(rest)
    local list = {}
    if rest:match("^%s*$") then return list end
    for token in rest:gmatch("[^,]+") do
        local name = token:match("^%s*(.-)%s*$")
        if name == "" or not name:match("^[%w%-%_.]+$") then
            return nil, "bad technology name '" .. token .. "'"
        end
        list[#list + 1] = name
    end
    if #list == 0 then
        return nil, "no valid technology names"
    end
    return list
end

-- Parse "type=craft-item,count=200" (no braces) into a table.
-- 'type' is required. 'count' must be numeric; other values that look
-- numeric become numbers (modifiers), the rest stay strings.
-- Returns table or nil, error.
local function parse_pairs(inner, what)
    local fields = {}
    if inner:match("^%s*$") then
        return nil, "missing " .. what .. " definition"
    end
    for token in inner:gmatch("[^,]+") do
        local k, v = token:match("^%s*([%w_%-]+)%s*=%s*(%S+)%s*$")
        if not k then
            return nil, "bad " .. what .. " pair '" .. token .. "' (want key=value)"
        end
        if k == "type" then
            fields[k] = v
        elseif k == "count" then
            local n = tonumber(v)
            if not n then
                return nil, "bad " .. what .. " count '" .. v .. "'"
            end
            fields[k] = n
        else
            fields[k] = tonumber(v) or v
        end
    end
    if not fields.type then
        return nil, what .. " is missing 'type='"
    end
    return fields
end

local function parse_fields(rest, what)
    return parse_pairs(rest, what)
end

-- Parse an effect argument into a list of structs: either bare pairs
-- (one struct) or brace groups (one struct each, braces required for
-- more than one). Mixing bare and braced is rejected. Returns list
-- or nil, error.
local function parse_effect_list(rest)
    rest = rest:match("^%s*(.-)%s*$")
    if rest:sub(1, 1) ~= "{" then
        local one, err = parse_pairs(rest, "effect")
        if not one then return nil, err end
        return { one }
    end
    local structs, pos = {}, 1
    while true do
        local s, e = rest:find("%b{}", pos)
        if not s then break end
        local gap = rest:sub(pos, s - 1)
        if gap:gsub("[,%s]", "") ~= "" then
            return nil, "expected ',' between effect {...} groups"
        end
        local st, err = parse_pairs(rest:sub(s + 1, e - 1), "effect")
        if not st then return nil, err end
        structs[#structs + 1] = st
        pos = e + 1
    end
    local tail = rest:sub(pos)
    if tail:gsub("[,%s]", "") ~= "" then
        return nil, "expected ',' between effect {...} groups"
    end
    if #structs == 0 then
        return nil, "missing effect definition"
    end
    return structs
end

-- Parse one op. Returns an op table or nil, error_message.
function Tech.parse_entry(entry)
    if entry:match("^%s*$") then
        return nil, "empty entry"
    end
    local remove = entry:match("^%s*-") ~= nil
    local body = entry:gsub("^%s*-%s*", "")
    local field, rest = body:match("^%s*(%S+)%s*(.-)$")
    if not field then
        return nil, "empty entry"
    end
    field = field:lower()
    rest = rest:match("^%s*(.-)%s*$") or ""

    if remove then
        if field == "trigger" then
            if rest ~= "" then
                return nil, "extra text after '-trigger'"
            end
            return { kind = "trigger_clear" }
        elseif field == "prereq" then
            if rest:match("^%s*$") then return nil, "want '-prereq <tech-name,...>'" end
            local names, err = parse_name_list(rest)
            if not names then return nil, err end
            return { kind = "prereq_remove", names = names }
        elseif field == "ingredient" then
            if rest:match("^%s*$") then return nil, "want '-ingredient <pack-name,...>'" end
            local names, err = parse_name_list(rest)
            if not names then return nil, err end
            return { kind = "ingredient_remove", names = names }
        else
            return nil, "unknown remove '-" .. field .. "'"
        end
    end

    if field == "prerequisites" then
        local list, err = parse_name_list(rest)
        if not list then return nil, err end
        return { kind = "prerequisites", list = list }
    elseif field == "prereq" then
        if rest:match("^%s*$") then return nil, "want 'prereq <tech-name,...>'" end
        local names, err = parse_name_list(rest)
        if not names then return nil, err end
        return { kind = "prereq_add", names = names }
    elseif field == "count" then
        local n = tonumber(rest)
        if not n or n <= 0 or n ~= math.floor(n) then
            return nil, "bad count '" .. rest .. "' (want a positive integer)"
        end
        return { kind = "count", n = n }
    elseif field == "time" then
        local n = tonumber(rest)
        if not n or n <= 0 then
            return nil, "bad time '" .. rest .. "' (want a positive number)"
        end
        return { kind = "time", n = n }
    elseif field == "trigger" then
        local trigger, err = parse_fields(rest, "trigger")
        if not trigger then return nil, err end
        return { kind = "trigger_set", trigger = trigger }
    elseif field == "effect" then
        local effects, err = parse_effect_list(rest)
        if not effects then return nil, err end
        return { kind = "effect_add", effects = effects }
    else
        return nil, "unknown field '" .. field .. "'"
    end
end

-- Apply one parsed op. Unknown tech/prereq names are left verbatim so the
-- engine hard-fails on typos instead of hiding them.
function Tech.apply_op(tech, tech_name, op)
    if op.kind == "prerequisites" then
        tech.prerequisites = op.list
        log(PREFIX .. tech_name .. ": prerequisites set")
    elseif op.kind == "prereq_add" then
        tech.prerequisites = tech.prerequisites or {}
        local present = {}
        for _, p in ipairs(tech.prerequisites) do present[p] = true end
        for _, name in ipairs(op.names) do
            if not present[name] then
                tech.prerequisites[#tech.prerequisites + 1] = name
                present[name] = true
            end
        end
        log(PREFIX .. tech_name .. ': added prereq "' ..
            table.concat(op.names, ",") .. '"')
    elseif op.kind == "prereq_remove" then
        if not tech.prerequisites then return end
        local drop = {}
        for _, name in ipairs(op.names) do drop[name] = true end
        local kept, removed = {}, false
        for _, p in ipairs(tech.prerequisites) do
            if drop[p] then
                removed = true
            else
                kept[#kept + 1] = p
            end
        end
        if removed then
            tech.prerequisites = kept
            log(PREFIX .. tech_name .. ': removed prereq "' ..
                table.concat(op.names, ",") .. '"')
        else
            log(PREFIX .. tech_name .. ': prereq "' ..
                table.concat(op.names, ",") .. '" not present — nothing to remove')
        end
    elseif op.kind == "count" then
        if not tech.unit then
            log(PREFIX .. tech_name .. ': no unit to set count on — skipping')
            return
        end
        tech.unit.count = op.n
        log(PREFIX .. tech_name .. ": count set to " .. op.n)
    elseif op.kind == "time" then
        if not tech.unit then
            log(PREFIX .. tech_name .. ': no unit to set time on — skipping')
            return
        end
        tech.unit.time = op.n
        log(PREFIX .. tech_name .. ": time set to " .. op.n)
    elseif op.kind == "ingredient_remove" then
        local ingredients = tech.unit and tech.unit.ingredients
        if not ingredients then
            log(PREFIX .. tech_name .. ": no ingredients to remove from — skipping")
            return
        end
        local drop = {}
        for _, name in ipairs(op.names) do drop[name] = true end
        local kept, removed = {}, false
        for _, ing in ipairs(ingredients) do
            local name = ing.name or ing[1]
            if drop[name] then
                removed = true
            else
                kept[#kept + 1] = ing
            end
        end
        if removed then
            tech.unit.ingredients = kept
            log(PREFIX .. tech_name .. ': removed ingredient "' ..
                table.concat(op.names, ",") .. '"')
        else
            log(PREFIX .. tech_name .. ': ingredient "' ..
                table.concat(op.names, ",") .. '" not present — nothing to remove')
        end
    elseif op.kind == "effect_add" then
        tech.effects = tech.effects or {}
        local types = {}
        for _, e in ipairs(op.effects) do
            tech.effects[#tech.effects + 1] = e
            types[#types + 1] = e.type
        end
        if #op.effects == 1 then
            log(PREFIX .. tech_name .. ": added effect (" .. types[1] .. ")")
        else
            log(PREFIX .. tech_name .. ": added " .. #op.effects ..
                " effects (" .. table.concat(types, ",") .. ")")
        end
    elseif op.kind == "trigger_set" then
        tech.research_trigger = op.trigger
        tech.unit = nil
        log(PREFIX .. tech_name .. ": research trigger set")
    elseif op.kind == "trigger_clear" then
        if not tech.research_trigger then
            log(PREFIX .. tech_name .. ": no trigger to clear — nothing to do")
        elseif not tech.unit then
            -- Clearing would leave neither unit nor trigger: skip.
            log(PREFIX .. tech_name ..
                ": clearing the trigger would leave neither unit nor trigger — skipping")
        else
            tech.research_trigger = nil
            log(PREFIX .. tech_name .. ": research trigger cleared")
        end
    end
end

-- Apply one tech's entry text ("<op>;<op>;..."). Malformed entries are
-- logged and skipped; one bad entry never blocks the others.
function Tech.apply_setting(tech, tech_name, value)
    -- '#' starts a comment (to ';' or end of line); see parse_overrides.
    value = value:gsub("#[^;\n]*", "")
    if value:match("^%s*$") then return end
    for entry in value:gmatch("[^;]+") do
        if entry:match("%S") then
            local op, err = Tech.parse_entry(entry)
            if not op then
                log(PREFIX .. 'bad entry "' .. entry .. '" for ' ..
                    tech_name .. ": " .. tostring(err))
            else
                Tech.apply_op(tech, tech_name, op)
            end
        end
    end
end

return Tech

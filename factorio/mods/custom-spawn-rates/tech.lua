-- Shared logic for tech-tree tweaks.
-- Parses the tech setting and applies it to technology prototypes.
-- Deliberately free of Factorio API calls except log()/print(), so the
-- test suite (tests/) can exercise it with plain Lua and stubs.
--
-- One free-form startup setting holds sections:
--   biolab: <op>;<op>
-- A '<tech-name>:' header starts a new section; subsequent entries belong
-- to it until the next header. Blank value means no changes. Later entries
-- win within a section. Outer shape mirrors lib.lua on purpose.
--
-- Ops name real prototype attribute paths: '<path> <value>' sets,
-- '+<path> <value>' adds to a list, '-<path> <value>' removes from a
-- list (or clears a singleton). Supported paths: prerequisites,
-- unit.count, unit.time, unit, unit.ingredients, research_trigger,
-- effects (append-only, so only '+effects' applies). Section splitting
-- is shared: callers use SpawnRates.parse_overrides.

local PREFIX = "custom-spawn-rates-"
local TECH_SETTING_NAME = "custom-spawn-rates-tech"

local Tech = {}

Tech.PREFIX = PREFIX
Tech.TECH_SETTING_NAME = TECH_SETTING_NAME

-- Attribute registry: user-facing path -> value shape. The table is
-- dispatch, not validation: `k=v` text cannot tell a unit-merge from a
-- trigger-struct from ingredient-pairs, so the target selects the
-- parser. A new attribute of a known shape is one row here plus a
-- small apply branch; only genuinely new value shapes need new code.
-- Paths outside the table fail only because no parser knows their
-- shape (data-stage prototypes are plain tables, so a blind set would
-- silently do nothing).
local PATHS = {
    prerequisites = { type = "names" },
    ["unit.count"] = { type = "int" },
    ["unit.time"] = { type = "number" },
    ["unit.ingredients"] = { type = "ingredients" },
    unit = { type = "unit_table" },
    research_trigger = { type = "trigger_struct" },
    effects = { type = "effect_list" },
}

local SUPPORTED = "supported paths: prerequisites, unit, unit.count, " ..
    "unit.ingredients, unit.time, research_trigger, " ..
    "effects (append-only: use '+effects')"

-- Change report: plain print(), no prefix. The test harness overrides
-- this hook to capture the report; warnings and skips stay on log()
-- with the prefix.
Tech.report = function(msg) print(msg) end

local function report(msg) Tech.report(msg) end

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

-- Parse "count=500,time=30" into {count=, time=}. At least one of the
-- two is required; anything else is rejected.
local function parse_unit_spec(rest)
    local spec = {}
    if rest:match("^%s*$") then
        return nil, "missing unit definition (want count= and/or time=)"
    end
    for token in rest:gmatch("[^,]+") do
        local k, v = token:match("^%s*([%w_%-]+)%s*=%s*(%S+)%s*$")
        if not k or (k ~= "count" and k ~= "time") then
            return nil, "bad unit pair '" .. token ..
                "' (want count= and/or time=)"
        end
        local n = tonumber(v)
        if not n or n <= 0 or (k == "count" and n ~= math.floor(n)) then
            return nil, "bad unit " .. k .. " '" .. v .. "'"
        end
        spec[k] = n
    end
    if spec.count == nil and spec.time == nil then
        return nil, "missing unit definition (want count= and/or time=)"
    end
    return spec
end

-- Parse "automation-science-pack=1,logistic-science-pack=1" into
-- {{name=, amount=}, ...}. Replaces the whole ingredient list.
local function parse_ingredient_list(rest)
    local list = {}
    if rest:match("^%s*$") then
        return nil, "missing ingredients definition (want <pack>=<amount>,...)"
    end
    for token in rest:gmatch("[^,]+") do
        local name, amount = token:match("^%s*([%w%-%_.]+)%s*=%s*(%S+)%s*$")
        local n = tonumber(amount or "")
        if not name or not n or n <= 0 then
            return nil, "bad ingredient '" .. token ..
                "' (want <pack>=<amount>)"
        end
        list[#list + 1] = { name = name, amount = n }
    end
    return list
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
    local sigil = entry:match("^%s*([-+])")
    local body = entry:gsub("^%s*[-+]%s*", "")
    local path, rest = body:match("^%s*(%S+)%s*(.-)$")
    if not path then
        return nil, "empty entry"
    end
    path = path:lower()
    rest = rest:match("^%s*(.-)%s*$") or ""
    local pre = sigil or ""

    local spec = PATHS[path]
    if not spec then
        return nil, "unknown attribute '" .. pre .. path .. "' (" ..
            SUPPORTED .. ")"
    end

    if sigil == "+" then
        if spec.type == "names" then
            if rest:match("^%s*$") then
                return nil, "want '+prerequisites <tech-name,...>'"
            end
            local names, err = parse_name_list(rest)
            if not names then return nil, err end
            return { kind = "prereq_add", names = names }
        elseif spec.type == "ingredients" then
            local list, err = parse_ingredient_list(rest)
            if not list then return nil, err end
            return { kind = "ingredient_add", list = list }
        elseif spec.type == "effect_list" then
            local effects, err = parse_effect_list(rest)
            if not effects then return nil, err end
            return { kind = "effect_add", effects = effects }
        else
            return nil, "cannot add to '" .. path ..
                "' (only '+prerequisites', '+unit.ingredients' and '+effects' add)"
        end
    end

    if sigil == "-" then
        if spec.type == "names" or spec.type == "ingredients" then
            if rest:match("^%s*$") then
                return nil, "want '-" .. path .. " <name,...>'"
            end
            local names, err = parse_name_list(rest)
            if not names then return nil, err end
            if spec.type == "names" then
                return { kind = "prereq_remove", names = names }
            end
            return { kind = "ingredient_remove", names = names }
        elseif path == "research_trigger" then
            if rest ~= "" then
                return nil, "extra text after '-research_trigger'"
            end
            return { kind = "trigger_clear" }
        elseif path == "unit" then
            if rest ~= "" then
                return nil, "extra text after '-unit'"
            end
            return { kind = "unit_clear" }
        else
            return nil, "cannot remove '" .. path ..
                "' (patch lists with '-<path> <name,...>'," ..
                " clear with '-research_trigger' or '-unit')"
        end
    end

    -- Bare path: set.
    if spec.type == "names" then
        local list, err = parse_name_list(rest)
        if not list then return nil, err end
        return { kind = "prerequisites", list = list }
    elseif spec.type == "int" or spec.type == "number" then
        local n = tonumber(rest)
        if not n or n <= 0 or (spec.type == "int" and n ~= math.floor(n)) then
            local want = spec.type == "int" and "a positive integer"
                or "a positive number"
            return nil, "bad " .. path .. " '" .. rest .. "' (want " ..
                want .. ")"
        end
        if spec.type == "int" then return { kind = "count", n = n } end
        return { kind = "time", n = n }
    elseif spec.type == "unit_table" then
        local unit_spec, err = parse_unit_spec(rest)
        if not unit_spec then return nil, err end
        return { kind = "unit_set", count = unit_spec.count, time = unit_spec.time }
    elseif spec.type == "ingredients" then
        local list, err = parse_ingredient_list(rest)
        if not list then return nil, err end
        return { kind = "ingredients_set", list = list }
    elseif spec.type == "trigger_struct" then
        local trigger, err = parse_fields(rest, "trigger")
        if not trigger then return nil, err end
        return { kind = "trigger_set", trigger = trigger }
    else -- effect_list
        return nil, "bare 'effects' sets nothing (use '+effects ...' to append)"
    end
end

-- One-line summaries for the startup report: what each op changed from
-- what. Tables compare by summary string, which holds for the flat
-- shapes here (name lists, rate pairs, triggers, ingredients).
local function name_list_to_string(list)
    if list == nil or #list == 0 then return "(none)" end
    return table.concat(list, ",")
end

local function trigger_to_string(trigger)
    if not trigger then return "(none)" end
    local keys = {}
    for k in pairs(trigger) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if a == "type" then return true end
        if b == "type" then return false end
        return a < b
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(trigger[k])
    end
    return table.concat(parts, ",")
end

local function ingredient_name(ing) return ing.name or ing[1] end

local function ingredients_to_string(ingredients)
    if not ingredients or #ingredients == 0 then return "(none)" end
    local parts = {}
    for _, ing in ipairs(ingredients) do
        parts[#parts + 1] = ingredient_name(ing) .. "=" ..
            tostring(ing.amount or ing[2])
    end
    return table.concat(parts, ",")
end

local function unit_to_string(unit)
    if not unit then return "(none)" end
    return "count=" .. tostring(unit.count) .. ",time=" ..
        tostring(unit.time) .. ",ingredients=" ..
        ingredients_to_string(unit.ingredients)
end

-- Apply one parsed op. Unknown tech/prereq names are left verbatim so the
-- engine hard-fails on typos instead of hiding them.
function Tech.apply_op(tech, tech_name, op)
    if op.kind == "prerequisites" then
        local before = name_list_to_string(tech.prerequisites)
        tech.prerequisites = op.list
        local after = name_list_to_string(op.list)
        if before == after then
            report(tech_name .. ": prerequisites already " ..
                after .. " — no change")
        else
            report(tech_name .. ": prerequisites " ..
                before .. " → " .. after)
        end
    elseif op.kind == "prereq_add" then
        tech.prerequisites = tech.prerequisites or {}
        local before = name_list_to_string(tech.prerequisites)
        local present = {}
        for _, p in ipairs(tech.prerequisites) do present[p] = true end
        local added = {}
        for _, name in ipairs(op.names) do
            if not present[name] then
                tech.prerequisites[#tech.prerequisites + 1] = name
                present[name] = true
                added[#added + 1] = name
            end
        end
        if #added == 0 then
            report(tech_name .. ': +prerequisites "' ..
                table.concat(op.names, ",") ..
                '" already present — no change')
        else
            report(tech_name .. ': +prerequisites "' ..
                table.concat(added, ",") .. '" (' .. before ..
                " → " .. name_list_to_string(tech.prerequisites) .. ")")
        end
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
            report(tech_name .. ': -prerequisites "' ..
                table.concat(op.names, ",") .. '" (now: ' ..
                name_list_to_string(kept) .. ")")
        else
            log(PREFIX .. tech_name .. ': -prerequisites "' ..
                table.concat(op.names, ",") .. '" not present — nothing to remove')
        end
    elseif op.kind == "count" then
        if not tech.unit then
            log(PREFIX .. tech_name .. ': no unit to set count on — skipping')
            return
        end
        local before = tech.unit.count
        tech.unit.count = op.n
        if before == op.n then
            report(tech_name .. ": unit.count already " .. op.n ..
                " — no change")
        else
            report(tech_name .. ": unit.count set to " .. op.n ..
                " (was " .. tostring(before) .. ")")
        end
    elseif op.kind == "time" then
        if not tech.unit then
            log(PREFIX .. tech_name .. ': no unit to set time on — skipping')
            return
        end
        local before = tech.unit.time
        tech.unit.time = op.n
        if before == op.n then
            report(tech_name .. ": unit.time already " .. op.n ..
                " — no change")
        else
            report(tech_name .. ": unit.time set to " .. op.n ..
                " (was " .. tostring(before) .. ")")
        end
    elseif op.kind == "unit_set" then
        -- Mirror of trigger_set: setting the lab cost clears any research
        -- trigger, so trigger-only techs convert in one op.
        local before = unit_to_string(tech.unit)
        local had_trigger = tech.research_trigger ~= nil
        tech.unit = tech.unit or { ingredients = {} }
        if op.count ~= nil then tech.unit.count = op.count end
        if op.time ~= nil then tech.unit.time = op.time end
        tech.unit.ingredients = tech.unit.ingredients or {}
        tech.research_trigger = nil
        local after = unit_to_string(tech.unit)
        if before == after and not had_trigger then
            report(tech_name .. ": unit already " .. after ..
                " — no change")
        else
            report(tech_name .. ": unit set: " .. before ..
                " → " .. after ..
                (had_trigger and " (research_trigger cleared)" or ""))
        end
    elseif op.kind == "ingredients_set" then
        if not tech.unit then
            log(PREFIX .. tech_name ..
                ": no unit to set ingredients on — skipping")
            return
        end
        local before = ingredients_to_string(tech.unit.ingredients)
        local fresh = {}
        for _, ing in ipairs(op.list) do
            fresh[#fresh + 1] = { ing.name, ing.amount }
        end
        tech.unit.ingredients = fresh
        local after = ingredients_to_string(fresh)
        if before == after then
            report(tech_name .. ": unit.ingredients already " .. after ..
                " — no change")
        else
            report(tech_name .. ": unit.ingredients set: " .. before ..
                " → " .. after)
        end
    elseif op.kind == "ingredient_add" then
        if not tech.unit then
            log(PREFIX .. tech_name ..
                ": no unit to add ingredients to — skipping")
            return
        end
        local before = ingredients_to_string(tech.unit.ingredients)
        tech.unit.ingredients = tech.unit.ingredients or {}
        local at = {}
        for i, ing in ipairs(tech.unit.ingredients) do
            at[ingredient_name(ing)] = i
        end
        for _, ing in ipairs(op.list) do
            if at[ing.name] then
                tech.unit.ingredients[at[ing.name]] = { ing.name, ing.amount }
            else
                at[ing.name] = #tech.unit.ingredients + 1
                tech.unit.ingredients[#tech.unit.ingredients + 1] =
                    { ing.name, ing.amount }
            end
        end
        local after = ingredients_to_string(tech.unit.ingredients)
        if before == after then
            report(tech_name .. ": +unit.ingredients already " .. after ..
                " — no change")
        else
            local added = {}
            for _, ing in ipairs(op.list) do
                added[#added + 1] = ing.name .. "=" .. ing.amount
            end
            report(tech_name .. ': +unit.ingredients "' ..
                table.concat(added, ",") .. '" (' .. before ..
                " → " .. after .. ")")
        end
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
            report(tech_name .. ': -unit.ingredients "' ..
                table.concat(op.names, ",") .. '" (now: ' ..
                ingredients_to_string(kept) .. ")")
        else
            log(PREFIX .. tech_name .. ': -unit.ingredients "' ..
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
            report(tech_name .. ": +effects (" .. types[1] .. ")")
        else
            report(tech_name .. ": +effects " .. #op.effects ..
                " effects (" .. table.concat(types, ",") .. ")")
        end
    elseif op.kind == "trigger_set" then
        local had_unit = tech.unit ~= nil
        local before = trigger_to_string(tech.research_trigger)
        tech.research_trigger = op.trigger
        tech.unit = nil
        local after = trigger_to_string(op.trigger)
        if before == after and not had_unit then
            report(tech_name .. ": research_trigger already " ..
                after .. " — no change")
        else
            report(tech_name .. ": research_trigger set: " ..
                before .. " → " .. after ..
                (had_unit and " (unit cleared)" or ""))
        end
    elseif op.kind == "trigger_clear" then
        if not tech.research_trigger then
            log(PREFIX .. tech_name .. ": no trigger to clear — nothing to do")
        elseif not tech.unit then
            -- Clearing would leave neither unit nor trigger: skip.
            log(PREFIX .. tech_name ..
                ": clearing the trigger would leave neither unit nor trigger — skipping")
        else
            local was = trigger_to_string(tech.research_trigger)
            tech.research_trigger = nil
            report(tech_name .. ": research_trigger cleared (was: " ..
                was .. ")")
        end
    elseif op.kind == "unit_clear" then
        if not tech.unit then
            log(PREFIX .. tech_name .. ": no unit to clear — nothing to do")
        elseif not tech.research_trigger then
            -- Clearing would leave neither unit nor trigger: skip.
            log(PREFIX .. tech_name ..
                ": clearing the unit would leave neither unit nor trigger — skipping")
        else
            local was = unit_to_string(tech.unit)
            tech.unit = nil
            report(tech_name .. ": unit cleared (was: " .. was .. ")")
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

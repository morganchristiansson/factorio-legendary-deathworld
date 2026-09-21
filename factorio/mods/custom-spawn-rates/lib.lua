-- Custom Spawn Rates + Tech Changes — one generic table manipulator.
--
-- The whole mod is one engine: settings text is a mini language over real
-- prototype tables.
--
--   <path> <value>    set        +<path> <value>   add/merge
--   -<path> <value>   remove     -<path>           clear
--
-- Paths are lua-style addresses (unit.count, result_units["small-biter"],
-- unit.ingredients). Values are one generic literal grammar:
--
--   300                 -> 300            (scalar)
--   a,b,c               -> {"a","b","c"}  (names)
--   k=1,v=2             -> k=v pairs      (a map for map fields, a sorted
--                                           pair list for list fields)
--   {k=1},{k=2}         -> {{k=1},{k=2}}  (struct list)
--
-- There is no schema: the engine inspects the live prototype table at apply
-- time and shapes the literal to fit (a field that holds pairs gets k=v text
-- turned into pairs, a map field keeps a map, a scalar field wants a number).
-- Absent fields default to the shape the literal itself expresses, with a
-- two-entry override for the genuinely ambiguous ones (unit.ingredients and
-- effects, which are lists but take k=v text). Unknown paths apply verbatim,
-- so the engine works on anything; the deliberate shorthands (unit names,
-- tech names) are left in place and hard-fail prototype load, same as
-- vanilla.
--
-- The two feature surfaces are alias configs over the same engine:
--   spawn  bare name -> result_units.<name>  (entry addresses a nest's unit)
--   tech   ingredients -> unit.ingredients; unit and research_trigger are
--          exclusive (setting one clears the other; clearing one is skipped
--          when it would leave neither).
-- Only log()/print() from the Factorio API; tests stub those hooks.

local SETTING_PREFIX = "custom-spawn-rates-"
local EXTRA_SETTING_NAME = "custom-spawn-rates-extra"
local TECH_SETTING_NAME = "custom-spawn-rates-tech"

local Mod = {}

-- ---------------------------------------------------------------------------
-- Literal grammar

local function trim(value)
    return (value:gsub("^%s+", "")):gsub("%s+$", "")
end

local function parse_pairs(text, what)
    local map = {}
    for token in text:gmatch("[^,]+") do
        local k, v = token:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
        if not k then
            return nil, "bad " .. what .. " '" .. trim(token) .. "' (want key=value)"
        end
        map[k] = tonumber(v) or v
    end
    if next(map) == nil then return nil, "empty " .. what end
    return map
end

function Mod.parse_literal(text)
    text = trim(text)
    if text == "" then return nil end
    if text:sub(1, 1) == "{" then
        local list, pos = {}, 1
        while true do
            local s = text:find("{", pos)
            if not s then break end
            local e = text:find("}", s)
            if not e then return nil, "unbalanced '{'" end
            local gap = text:sub(pos, s - 1)
            if gap:gsub("[,%s]", "") ~= "" then
                return nil, "expected ',' between {...} groups"
            end
            local struct, err = parse_pairs(text:sub(s + 1, e - 1), "group")
            if not struct then return nil, err end
            list[#list + 1] = struct
            pos = e + 1
        end
        if text:sub(pos):gsub("[,%s]", "") ~= "" then
            return nil, "expected ',' between {...} groups"
        end
        return list
    end
    local tokens = {}
    for token in text:gmatch("[^,]+") do tokens[#tokens + 1] = token end
    local has_pairs = false
    for _, token in ipairs(tokens) do
        if token:find("=") then has_pairs = true break end
    end
    if #tokens == 1 and not has_pairs then
        local n = tonumber(tokens[1])
        if n then return n end
        return { tokens[1] }
    end
    if not has_pairs then
        local names = {}
        for _, token in ipairs(tokens) do names[#names + 1] = trim(token) end
        return names
    end
    return parse_pairs(text, "value")
end

-- ---------------------------------------------------------------------------
-- Paths

local function parse_key(text)
    text = trim(text)
    local quote = text:sub(1, 1)
    if quote == '"' or quote == "'" then
        if text:sub(-1) ~= quote then return nil, "unterminated quoted key" end
        return text:sub(2, -2):gsub("\\(.)", "%1")
    end
    local n = tonumber(text)
    if n then return n end
    return text
end

function Mod.parse_path(path)
    path = trim(path)
    if path == "" then return nil, "empty path" end
    local segments = {}
    local pos = 1
    while pos <= #path do
        local char = path:sub(pos, pos)
        if char == "." then
            pos = pos + 1
        elseif char == "[" then
            local close = path:find("]", pos + 1)
            if not close then return nil, "unterminated bracket key" end
            local key, err = parse_key(path:sub(pos + 1, close - 1))
            if not key then return nil, err end
            segments[#segments + 1] = key
            pos = close + 1
        else
            local key = path:match("^([^.%[%]]+)", pos)
            if not key then return nil, "bad path '" .. path .. "'" end
            segments[#segments + 1] = key
            pos = pos + #key
        end
    end
    return segments
end

-- A container is treated as a list when it has items or is empty. (Empty
-- maps are indistinguishable from empty arrays in Lua, and every empty
-- container this engine addresses is a list.)
local function is_list(v)
    return type(v) == "table" and (v[1] ~= nil or next(v) == nil)
end

-- Walk to the addressed field. Returns parent, final_key, list_index,
-- payload, err. A list address (parent is a list) resolves the final key
-- against item[1]; payload is the item's second element. A plain field
-- address has payload = the field value. missing (a segment name) means a
-- path element did not exist.
local function lookup(root, segments)
    local parent = root
    for i = 1, #segments - 1 do
        if type(parent) ~= "table" or parent[segments[i]] == nil then
            return nil, nil, nil, nil, segments[i]
        end
        parent = parent[segments[i]]
    end
    local key = segments[#segments]
    if is_list(parent) and #segments > 1 then
        local index = nil
        for i, item in ipairs(parent) do
            if item[1] == key then index = i break end
        end
        if index then return parent, key, index, parent[index][2], nil end
        return parent, key, nil, nil, nil
    end
    if type(parent) ~= "table" then
        return nil, nil, nil, nil, segments[#segments - 1]
    end
    return parent, key, nil, parent[key], nil
end

-- ---------------------------------------------------------------------------
-- Value shaping

-- Classify a live value: names / pair_list / struct_list / map / scalar.
local function classify(v)
    if type(v) ~= "table" then return "scalar" end
    if v[1] ~= nil then
        if type(v[1]) == "table" then
            return v[1][2] ~= nil and "pair_list" or "struct_list"
        end
        return "names"
    end
    return "map"
end

-- The kind a literal itself expresses (used when the field is absent or
-- empty).
local function kind_of(literal)
    if type(literal) ~= "table" then return "scalar" end
    if literal[1] ~= nil then
        return type(literal[1]) == "table" and "struct_list" or "names"
    end
    return "map"
end

local function map_to_pairs(map)
    local pairs_list = {}
    for k, v in pairs(map) do
        -- Numeric keys become numbers (rate evos); name keys stay strings
        -- (ingredient packs). An evo above 1 is invalid for any rate table,
        -- and numeric keys only ever mean evos, so the check applies to all
        -- pair lists safely.
        local nk = tonumber(k)
        if nk then
            if nk > 1 then return nil, "evolution factor " .. nk .. " is above 1" end
            k = nk
        end
        pairs_list[#pairs_list + 1] = { k, v }
    end
    table.sort(pairs_list, function(a, b)
        local na, nb = tonumber(a[1]), tonumber(b[1])
        if na and nb then return na < nb end
        return a[1] < b[1]
    end)
    return pairs_list
end

-- Shape a literal for a field of the given kind.
local function shape(literal, kind)
    if kind == "scalar" then
        if type(literal) ~= "number" then
            return nil, "bad value '" .. tostring(literal) .. "' (want a number)"
        end
        if literal <= 0 then return nil, "bad value '" .. literal .. "' (want > 0)" end
        return literal
    end
    if kind == "names" then
        if type(literal) == "table" and literal[1] ~= nil
            and type(literal[1]) ~= "table" then return literal end
        return nil, "bad value (want a name list)"
    end
    if kind == "pair_list" then
        if type(literal) == "table" and literal[1] == nil then
            return map_to_pairs(literal)
        end
        if type(literal) == "table" and type(literal[1]) == "table" then
            return literal
        end
        return nil, "bad value (want key=value pairs)"
    end
    if kind == "struct_list" then
        if type(literal) == "table" and type(literal[1]) == "table" then
            return literal
        end
        if type(literal) == "table" and literal[1] == nil then return { literal } end
        return nil, "bad value (want key=value pairs or {...} groups)"
    end
    -- map
    if type(literal) == "table" and literal[1] == nil then return literal end
    return nil, "bad value (want key=value pairs)"
end

-- ---------------------------------------------------------------------------
-- Ops

local function eqv(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not eqv(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function fmt(value)
    if value == nil then return "(none)" end
    local t = type(value)
    if t ~= "table" then return tostring(value) end
    local parts = {}
    if value[1] ~= nil then
        for _, v in ipairs(value) do
            if type(v) == "table" then
                if v[2] ~= nil and type(v[2]) ~= "table" then
                    parts[#parts + 1] = v[1] .. "=" .. tostring(v[2])
                else
                    parts[#parts + 1] = fmt(v)
                end
            else
                parts[#parts + 1] = tostring(v)
            end
        end
        return table.concat(parts, ",")
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(value[k])
    end
    return table.concat(parts, ",")
end

-- List add/remove helpers shared by every list kind.
local function list_add(list, value, kind)
    if kind == "names" then
        for _, name in ipairs(value) do
            local has = false
            for _, cur in ipairs(list) do
                if cur == name then has = true break end
            end
            if not has then list[#list + 1] = name end
        end
    elseif kind == "pair_list" then
        local at = {}
        for i, item in ipairs(list) do at[item[1]] = i end
        for _, item in ipairs(value) do
            if at[item[1]] then
                list[at[item[1]]][2] = item[2]
            else
                at[item[1]] = #list + 1
                list[#list + 1] = item
            end
        end
    else -- struct_list
        for _, item in ipairs(value) do list[#list + 1] = item end
    end
    return list
end

local function list_remove(list, names, kind)
    local removed = false
    if kind == "map" then
        for _, name in ipairs(names) do
            if list[name] ~= nil then list[name] = nil removed = true end
        end
        return removed
    end
    local keep = {}
    for _, cur in ipairs(list) do
        local drop = false
        for _, name in ipairs(names) do
            local key = type(cur) == "table" and cur[1] or cur
            if key == name then drop = true removed = true break end
        end
        if not drop then keep[#keep + 1] = cur end
    end
    for i = #list, 1, -1 do list[i] = nil end
    for i, item in ipairs(keep) do list[i] = item end
    return removed
end

-- Apply one (path, op, literal) to root.
local function do_op(root, path, op, literal, ctx)
    local segments, perr = Mod.parse_path(path)
    if not segments then return nil, nil, perr end
    local parent, key, index, payload, missing = lookup(root, segments)
    if missing then
        return nil, nil, "'" .. missing .. "' does not exist on this object"
    end
    local is_item = #segments > 1 and is_list(parent)

    if op == "clear" then
        if is_item then
            if index == nil then return nil, nil, "not present" end
            local before = parent[index][2]
            table.remove(parent, index)
            return before, nil, nil
        end
        if payload == nil then return nil, nil, "not present" end
        local after = is_list(payload) and {} or nil
        parent[key] = after
        return payload, after, nil
    end

    if is_item then
        if index == nil and op == "add" then op = "set" end
        if op == "set" then
            local value, err = shape(literal, "pair_list")
            if not value then return nil, nil, err end
            if index then
                local before = parent[index][2]
                parent[index][2] = value
                return before, value, nil
            end
            parent[#parent + 1] = { key, value }
            return nil, value, nil
        end
        if index == nil then return nil, nil, "not present" end
        local before = parent[index][2]
        table.remove(parent, index)
        return before, nil, nil
    end

    local kind = classify(payload)
    local empty = type(payload) == "table" and next(payload) == nil
    if payload ~= nil and not empty and (kind == "scalar" or kind == "map") then
        local value, err = shape(literal, kind)
        if not value then return nil, nil, err end
        if op == "add" then
            if kind == "scalar" then
                return nil, nil, "cannot add to '" .. path .. "'"
            end
            parent[key] = parent[key] or {}
            for k, v in pairs(value) do parent[key][k] = v end
            return payload, parent[key], nil
        end
        if op == "remove" then
            return nil, nil, "cannot remove from '" .. path .. "'"
        end
        -- Map set: replace, unless the context says maps at this path patch
        -- in place (tech's `unit` op keeps count-less fields like existing
        -- ingredients when only count/time are given).
        if ctx.set_merge and ctx.set_merge[path] then
            local merged = {}
            for k, v in pairs(parent[key]) do merged[k] = v end
            for k, v in pairs(value) do merged[k] = v end
            parent[key] = merged
            return payload, merged, nil
        end
        parent[key] = value
        return payload, value, nil
    end

    -- List field, or absent/empty field: adopt the context hint or the
    -- literal's own shape.
    if payload == nil or empty then
        if op == "remove" then return nil, nil, "not present" end
        kind = ctx.default_shape and ctx.default_shape[path] or kind_of(literal)
    end

    if op == "remove" then
        -- Remove takes names (or map keys) straight from the literal; no
        -- pair/struct shaping.
        local names = {}
        if type(literal) == "table" then
            if literal[1] ~= nil then
                for _, v in ipairs(literal) do
                    names[#names + 1] = type(v) == "table" and v[1] or v
                end
            else
                for k in pairs(literal) do names[#names + 1] = tostring(k) end
            end
        else
            names[1] = literal
        end
        if kind == "map" then
            local removed = false
            for _, name in ipairs(names) do
                if parent[key][name] ~= nil then
                    parent[key][name] = nil
                    removed = true
                end
            end
            if not removed then return nil, nil, "not present" end
            return payload, parent[key], nil
        end
        if not list_remove(parent[key], names, kind) then
            return nil, nil, "not present"
        end
        return payload, parent[key], nil
    end

    local value, err = shape(literal, kind)
    if not value then return nil, nil, err end

    if op == "set" then
        parent[key] = value
        return payload, value, nil
    end

    -- add
    parent[key] = parent[key] or {}
    if kind == "map" then
        for k, v in pairs(value) do parent[key][k] = v end
    else
        list_add(parent[key], value, kind)
    end
    return payload, parent[key], nil
end

-- ---------------------------------------------------------------------------
-- Sections and entry application

-- "a: e1;e2;b: e3" -> {a="e1;e2", b="e3"}; headerless entries are returned
-- as orphans. '#' starts a comment (to ';' or newline).
function Mod.sections(value)
    value = value:gsub("#[^;\n]*", "")
    local bag, orphans = {}, {}
    local current = nil
    for token in value:gmatch("[^;]+") do
        local name = token:match("^%s*([%w%-%_.]+)%s*:")
        if name then
            current = name
            token = token:gsub("^%s*[%w%-%_.]+%s*:%s*", "", 1)
            bag[current] = ""
        elseif current == nil then
            local orphan = token:match("^%s*(.-)%s*$")
            if orphan ~= "" then orphans[#orphans + 1] = orphan end
            token = ""
        end
        if current then
            local entry = token:match("^%s*(.-)%s*$")
            if entry ~= "" then
                bag[current] = bag[current] == "" and entry
                    or bag[current] .. ";" .. entry
            end
        end
    end
    return bag, orphans
end

Mod.report = function(msg) print(msg) end
Mod.logfn = function(msg) log(msg) end

-- Apply one entry ("[+|-]<path-or-alias> <value>") to target.
function Mod.apply_entry(target, entry, ctx)
    local sigil, head, rest = entry:match("^%s*([-+]?)%s*(%S+)%s*(.-)%s*$")
    if not head then return nil, "empty entry" end

    local path, err = ctx.resolve(head)
    if not path then return nil, err end

    -- Is this an item address (a key into a list)? Drives the value-less
    -- entry rule below.
    local segments = Mod.parse_path(path)
    local item_addr = false
    if #segments > 1 then
        local parent = target
        local ok = true
        for i = 1, #segments - 1 do
            if type(parent) ~= "table" or parent[segments[i]] == nil then
                ok = false break
            end
            parent = parent[segments[i]]
        end
        item_addr = ok and is_list(parent)
    end

    local op
    if sigil == "+" then
        if rest == "" then return nil, "want '+<path> <value>'" end
        op = "add"
    elseif sigil == "-" then
        op = rest == "" and "clear" or "remove"
    elseif rest == "" then
        -- A value-less set on an item address is a dropped value (spawn
        -- shorthand: "medium-biter" alone means a missing rate table), not
        -- a clear; on a whole field it clears (bare "prerequisites").
        if item_addr then return nil, "missing value after '" .. head .. "'" end
        op = "clear"
    else
        op = "set"
    end

    -- Per-surface guard: some fields have no bare-set meaning (effects only
    -- ever appends). This is the one remaining "validation" in the engine.
    if op == "set" and ctx.set_guard and ctx.set_guard[path] then
        return nil, ctx.set_guard[path]
    end

    local literal
    if rest ~= "" then
        literal, err = Mod.parse_literal(rest)
        if not literal then return nil, err end
    end

    -- tech rule: clearing unit (or the trigger) when the other is absent
    -- would leave a tech with neither — skip it.
    if ctx.exclusive and op == "clear" then
        for i, a in ipairs(ctx.exclusive) do
            if a == path and target[ctx.exclusive[3 - i]] == nil then
                return nil, "clearing '" .. a .. "' would leave neither unit " ..
                    "nor " .. ctx.exclusive[3 - i] .. " — skipping"
            end
        end
    end

    local before, after, oerr = do_op(target, path, op, literal, ctx)
    if oerr then return nil, oerr end

    -- tech rule: setting unit (or the trigger) clears the other.
    local note = ""
    if ctx.exclusive and (op == "set" or op == "add") then
        for i, a in ipairs(ctx.exclusive) do
            if a == path and target[ctx.exclusive[3 - i]] ~= nil then
                target[ctx.exclusive[3 - i]] = nil
                note = " (" .. ctx.exclusive[3 - i] .. " cleared)"
            end
        end
    end

    local label = ctx.obj_label or path
    if op == "clear" or op == "remove" then
        Mod.report(label .. ": " .. (after == nil and "removed (was " ..
            fmt(before) .. ")" or fmt(before) .. " → " .. fmt(after)) .. note)
    elseif note ~= "" then
        Mod.report(label .. ": " .. fmt(before) .. " → " .. fmt(after) .. note)
    elseif eqv(before, after) then
        Mod.report(label .. ": already " .. fmt(after) .. " — no change")
    else
        Mod.report(label .. ": " .. fmt(before) .. " → " .. fmt(after))
    end
    return true, nil, label
end

-- Apply an entry list to one object. ctx.resolve(head) -> path; per-feature
-- extras (exclusive, default_shape, noun) come from the config.
local function apply_text(target, noun, text, ctx)
    if not text or text:match("^%s*$") then return end
    text = text:gsub("#[^;\n]*", "")
    for entry in text:gmatch("[^;]+") do
        if entry:match("%S") then
            local entry_ctx = {}
            for k, v in pairs(ctx) do entry_ctx[k] = v end
            entry_ctx.obj_label = noun .. "." .. ctx.label_path(entry)
            local ok, err, label = Mod.apply_entry(target, entry, entry_ctx)
            if not ok then
                -- Silent skips (absent field/item) get a plain warning;
                -- malformed entries are flagged as such so one bad entry
                -- never looks like a successful no-op.
                local where = label or noun .. "." .. ctx.label_path(entry)
                if err == "not present" then
                    Mod.logfn(SETTING_PREFIX .. where .. ": not present — nothing to remove")
                elseif err:find("does not exist", 1, true) then
                    Mod.logfn(SETTING_PREFIX .. where .. ": " .. err .. " — skipping")
                else
                    Mod.logfn(SETTING_PREFIX .. 'bad entry "' .. trim(entry) .. '" for ' ..
                        noun .. ": " .. tostring(err))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Spawn surface: bare name -> result_units.<name>; root attrs loot/result_units.

local SPAWN_CONTEXT = {
    noun = "spawner",
    resolve = function(head)
        if head:match("^[%w%-%_.]+%.[%w%-%_.]+$") then return head end
        if head == "result_units" or head == "loot" then return head end
        return "result_units." .. head
    end,
    label_path = function(entry)
        local head = entry:match("^%s*[-+]?%s*(%S+)")
        if head and head ~= "result_units" and head ~= "loot" then
            return "result_units." .. head
        end
        return head
    end,
}

Mod.SpawnRates = {}
local SpawnRates = Mod.SpawnRates

SpawnRates.SETTING_PREFIX = SETTING_PREFIX
SpawnRates.EXTRA_SETTING_NAME = EXTRA_SETTING_NAME
SpawnRates.KNOWN_SPAWNERS = {
    { name = "biter-spawner", default = "" },
    { name = "spitter-spawner", default = "" },
    { name = "gleba-spawner-small", default = "" },
    { name = "gleba-spawner", default = "" },
}
SpawnRates.report = Mod.report
SpawnRates.sections = Mod.sections
SpawnRates.parse_literal = Mod.parse_literal
SpawnRates.apply_setting = function(spawner, name, value)
    apply_text(spawner, name, value, SPAWN_CONTEXT)
end

-- ---------------------------------------------------------------------------
-- Tech surface: known heads only; unit / research_trigger are exclusive.

local TECH_HEADS = {
    prerequisites = true, ["unit.count"] = true, ["unit.time"] = true,
    unit = true, ["unit.ingredients"] = true, research_trigger = true,
    effects = true, ingredients = true,
}
local SUPPORTED = "supported paths: prerequisites, unit, unit.count, " ..
    "unit.time, unit, unit.ingredients, research_trigger, effects, ingredients"

local TECH_CONTEXT = {
    noun = "technology",
    exclusive = { "unit", "research_trigger" },
    default_shape = { ["unit.ingredients"] = "pair_list", effects = "struct_list" },
    set_merge = { unit = true },
    set_guard = { effects = "bare 'effects' sets nothing (use '+effects ...' to append)" },
    resolve = function(head)
        if head == "ingredients" then head = "unit.ingredients" end
        if not TECH_HEADS[head] then
            return nil, "unknown attribute '" .. head .. "' (" .. SUPPORTED .. ")"
        end
        return head
    end,
    label_path = function(entry)
        local head = entry:match("^%s*[-+]?%s*(%S+)")
        return head == "ingredients" and "unit.ingredients" or head
    end,
}

Mod.Tech = {}
local Tech = Mod.Tech

Tech.PREFIX = SETTING_PREFIX
Tech.TECH_SETTING_NAME = TECH_SETTING_NAME
Tech.report = Mod.report
Tech.sections = Mod.sections
Tech.parse_literal = Mod.parse_literal
Tech.apply_setting = function(tech, name, value)
    apply_text(tech, name, value, TECH_CONTEXT)
end

return Mod

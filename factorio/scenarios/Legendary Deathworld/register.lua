-- Transient registrations that stay consistent across save/load.
-----------------------------------------------------------------------
-- Dynamic on_tick/on_nth_tick handlers and event filters don't survive a
-- save, and re-registering them ad hoc in on_load is a foot-gun: a
-- registration that was not present when the save was taken trips the
-- script-event mismatch check when a player joins a restarted server. This
-- module owns the dynamic pieces in one place, with an API that mirrors
-- script.on_event / script.on_nth_tick / script.set_event_filter:
--
--   * declarations run at module scope -- register.on_tick(key, fn) or
--     register.nth_tick(key, cadence, fn) -- so the callback exists again
--     after a load; a delayed one-shot is a declared worker that disarms
--     itself on its first fire (see groups.lua);
--   * register.arm(key) / register.disarm(key) toggle it at runtime; the
--     active set is stored, and one on_load re-registers exactly the keys
--     that were active when the save was taken;
--   * register.set_filter(event_id, filter) stores and re-applies dynamic
--     filters.
--
-- Two rules keep it safe: the cadence is never 1 (on_nth_tick(1) does not
-- survive a save, so re-arming it in on_load mismatches -- probe-verified),
-- and the on_tick slot has a single owner (the map reveal), enforced here.
-- Static registrations (the pre-gen and per-second drivers, the entity-died
-- handlers and their baseline filters) run at module scope every session and
-- stay direct.
-----------------------------------------------------------------------
local Public = {}

local active_key = "register_active"

-- key -> {fn = fn, cadence = N} or {fn = fn, on_tick = true}, populated at
-- module scope by the declare-style calls below.
local specs = {}

local function register_spec(key)
    local spec = specs[key]
    if not spec then
        error("register: no declaration for '" .. key .. "'", 3)
    end
    if spec.on_tick then
        script.on_event(defines.events.on_tick, spec.fn)
    else
        script.on_nth_tick(spec.cadence, spec.fn)
    end
end

local function unregister_spec(key)
    local spec = specs[key]
    if not spec then return end
    if spec.on_tick then
        script.on_event(defines.events.on_tick, nil)
    else
        script.on_nth_tick(spec.cadence, nil)
    end
end

-- The single on_tick slot owner. Call at module scope.
Public.on_tick = function(key, fn)
    specs[key] = {on_tick = true, fn = fn}
end

-- A dynamic periodic worker. Call at module scope; cadence must never be 1.
Public.nth_tick = function(key, cadence, fn)
    assert(cadence ~= 1, "register: cadence 1 does not survive a save")
    specs[key] = {cadence = cadence, fn = fn}
end

-- Activate a declared handler; the state is stored and re-applied on load.
Public.arm = function(key)
    if specs[key] and specs[key].on_tick then
        -- Only the map reveal may own the on_tick slot.
        for other, spec in pairs(specs) do
            if spec.on_tick and other ~= key and storage[active_key] and storage[active_key][other] then
                error("register: on_tick already active for '" .. other .. "'", 3)
            end
        end
    end
    local active = storage[active_key]
    if not active then
        active = {}
        storage[active_key] = active
    end
    active[key] = true
    register_spec(key)
end

Public.disarm = function(key)
    local active = storage[active_key]
    if active then
        active[key] = nil
        if not next(active) then
            storage[active_key] = nil
        end
    end
    unregister_spec(key)
end

-- A dynamic event filter; the stored filter is re-applied on load.
Public.set_filter = function(event_id, filter)
    local filters = storage.register_filters
    if not filters then
        filters = {}
        storage.register_filters = filters
    end
    filters[event_id] = filter
    script.set_event_filter(event_id, filter)
end

-- Dynamic registrations don't survive saves: re-register the stored active
-- keys and re-apply the stored filters. Reads storage only, as on_load
-- requires.
Public.on_load = function()
    for key in pairs(storage[active_key] or {}) do
        if specs[key] then
            register_spec(key)
        end
    end
    for event_id, filter in pairs(storage.register_filters or {}) do
        script.set_event_filter(event_id, filter)
    end
end

return Public
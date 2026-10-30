local reconcile

local function snapshot(ctx)
    return ctx.data.calendar
end

local function events(ctx)
    return ctx.select("calendar", "events") or {}
end

local function key(event)
    return event.id .. ":" .. tostring(event.start)
end

local function cancel(instance)
    local state = instance.state
    if state.timer then state.timer:cancel(); state.timer = nil end
    state.attempt = nil
end

local function save(instance)
    local state = instance.state
    local saved, err = omniwm.store.set("calendar-seen", state.seen)
    state.saveError = not saved and "Alert history not saved: " .. tostring(err) or nil
end

local function initialize(instance)
    local seen = omniwm.store.get("calendar-seen")
    instance.state.seen = {}
    if type(seen) == "table" and #seen <= 100 then
        for index = 1, #seen do
            local id = seen[index]
            if type(id) == "string" and not table.find(instance.state.seen, id) then table.insert(instance.state.seen, id) end
        end
    end
end

local function announce(instance, id)
    local state = instance.state
    if table.find(state.seen, id) then return end
    state.seen[#state.seen + 1] = id
    state.alert = { id = id, seconds = math.clamp(instance.options.alertSeconds or 4, 1, 10) }
    save(instance)
end

reconcile = function(instance)
    local state = instance.state
    local data = state.calendar
    if not data or data.access ~= "full" or instance.options.alerts == false then
        cancel(instance)
        state.alert = nil
        state.error = nil
        return
    end
    local now = os.time()
    local upcoming
    local valid = {}
    for _, event in data.events do
        if not event.allDay and event.start > now then
            valid[key(event)] = true
            if not upcoming or event.start < upcoming.start or event.start == upcoming.start and event.id < upcoming.id then upcoming = event end
        end
    end
    local seen = {}
    for _, id in state.seen do if valid[id] then seen[#seen + 1] = id end end
    state.seen = seen
    if not upcoming then cancel(instance); state.error = nil; return end
    local id = key(upcoming)
    local lead = math.clamp(instance.options.leadMinutes or 5, 0, 1440) * 60
    local announced = table.find(seen, id) ~= nil
    local deadline = if announced then upcoming.start else upcoming.start - lead
    if not announced and deadline <= now then
        announce(instance, id)
        deadline = upcoming.start
    end
    local attempt = id .. ":" .. tostring(deadline)
    if state.attempt == attempt then return end
    cancel(instance)
    state.attempt = attempt
    local timer, err = omniwm.after(math.max(0.01, deadline - now), function()
        if state.attempt ~= attempt then return end
        state.timer = nil
        state.attempt = nil
        local fired = os.time()
        if not announced and fired >= deadline and fired < upcoming["end"] then announce(instance, id) end
        reconcile(instance)
    end)
    state.timer = timer
    state.error = not timer and "Calendar alerts paused: " .. tostring(err) or nil
end

local function activity(ctx)
    local state = ctx.instance.state
    state.calendar = snapshot(ctx)
    reconcile(ctx.instance)
    local list = state.calendar and state.calendar.events or {}
    return { priority = #list > 0 and 10 or 0, label = list[1] and list[1].title, alert = state.alert }
end

local function retry(instance)
    instance.state.attempt = nil
    reconcile(instance)
    if instance.state.saveError or omniwm.store.status.error then save(instance) end
end

return table.freeze({ snapshot = snapshot, events = events, initialize = initialize, cancel = cancel,
    activity = activity, retry = retry, options = function(instance) cancel(instance); reconcile(instance) end,
    error = function(instance) return instance.state.error or instance.state.saveError or omniwm.store.status.error end,
    authorize = function() omniwm.run("calendar authorize") end,
    settings = function() omniwm.run("calendar settings") end,
    open = function(id) omniwm.run("calendar open" .. (if id then " " .. id else "")) end })

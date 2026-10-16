local maximum = 86400
local arm

local function number(value, low, high)
    return type(value) == "number" and value == value and value % 1 == 0 and value >= low and value <= high
end

local function label(value)
    if type(value) ~= "string" or not utf8.len(value) then return "Timer" end
    local ending = utf8.offset(value, 81)
    value = ending and string.sub(value, 1, ending - 1) or value
    return value ~= "" and value or "Timer"
end

local function duration(text)
    if type(text) ~= "string" or #text > 7 then return nil end
    local minutes, seconds = string.match(text, "^(%d+):(%d%d)$")
    if not minutes or tonumber(seconds) > 59 then return nil end
    local value = tonumber(minutes) * 60 + tonumber(seconds)
    return number(value, 1, maximum) and value or nil
end

local function format(seconds)
    seconds = math.max(0, math.ceil(seconds))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function save(instance)
    local saved, err = omniwm.store.set("timer", instance.state.record)
    instance.state.saveError = not saved and "Not saved: " .. tostring(err) or nil
    return saved
end

local function cancel(instance)
    if instance.state.timer then instance.state.timer:cancel(); instance.state.timer = nil end
end

local function finish(instance)
    cancel(instance)
    local record = instance.state.record
    record.status = "done"
    record.remaining = nil
    instance.state.error = nil
    save(instance)
end

arm = function(instance)
    local state = instance.state
    local record = state.record
    if state.timer or record.status ~= "running" then return end
    local remaining = record.deadline - os.time()
    if remaining <= 0 then finish(instance); return end
    local timer, err = omniwm.after(math.max(0.01, remaining), function()
        if state.record ~= record then return end
        state.timer = nil
        arm(instance)
    end)
    state.timer = timer
    state.error = not timer and "Completion paused: " .. tostring(err) or nil
end

local function initialize(instance)
    local options = instance.options
    local defaultDuration = number(options.duration, 1, maximum) and options.duration or 300
    local record = { label = label(options.label), duration = defaultDuration, status = "idle", serial = 0 }
    local cached = omniwm.store.get("timer")
    if type(cached) == "table" and number(cached.duration, 1, maximum) and number(cached.serial, 0, 2147483647) then
        local running = cached.status == "running" or cached.status == "done"
        local valid = cached.status == "idle"
            or cached.status == "paused" and number(cached.remaining, 1, maximum) and number(cached.startedAt, 1, 9007199254740991)
            or running and number(cached.deadline, 1, 9007199254740991) and number(cached.startedAt, 1, 9007199254740991)
        if valid then
            record = { label = label(cached.label), duration = cached.duration, status = cached.status,
                serial = cached.serial, deadline = running and cached.deadline or nil,
                startedAt = cached.status ~= "idle" and cached.startedAt or nil, remaining = cached.status == "paused" and cached.remaining or nil }
        end
    end
    instance.state.record = record
    instance.state.error = nil
    instance.state.saveError = nil
    arm(instance)
end

local function start(instance, title, text)
    local seconds = duration(text)
    if not seconds then return false, "Use m:ss between 0:01 and 1440:00" end
    cancel(instance)
    local now = os.time()
    local record = instance.state.record
    instance.state.record = { label = label(title), duration = seconds, status = "running",
        deadline = now + seconds, startedAt = now, serial = record.serial % 2147483647 + 1 }
    arm(instance)
    save(instance)
    return true
end

local function pause(instance)
    local record = instance.state.record
    if record.status ~= "running" then return end
    local remaining = record.deadline - os.time()
    if remaining <= 0 then finish(instance); return end
    cancel(instance)
    record.status = "paused"
    record.remaining = math.min(maximum, remaining)
    record.deadline = nil
    instance.state.error = nil
    save(instance)
end

local function resume(instance)
    local record = instance.state.record
    if record.status ~= "paused" then return end
    record.status = "running"
    record.deadline = os.time() + record.remaining
    record.remaining = nil
    arm(instance)
    save(instance)
end

local function clear(instance)
    cancel(instance)
    local record = instance.state.record
    record.status = "idle"
    record.deadline = nil
    record.remaining = nil
    record.startedAt = nil
    instance.state.error = nil
    save(instance)
end

local function rename(instance, title)
    local record = instance.state.record
    title = label(title)
    if title ~= record.label then record.label = title; save(instance) end
end

local function retry(instance)
    arm(instance)
    if instance.state.saveError or omniwm.store.status.error then save(instance) end
end

local function remaining(instance, now)
    local record = instance.state.record
    if record.status == "running" then return math.max(0, record.deadline - now) end
    if record.status == "paused" then return record.remaining end
    return record.status == "done" and 0 or record.duration
end

local function activity(instance)
    local record = instance.state.record
    return { priority = record.status == "done" and 80 or record.status == "running" and 60 or record.status == "paused" and 20 or 0,
        since = record.startedAt or 0, label = record.label,
        alert = record.status == "done" and { id = tostring(record.serial) .. ":" .. tostring(record.deadline), seconds = 4 } or nil }
end

return table.freeze({ initialize = initialize, cancel = cancel, start = start, pause = pause, resume = resume,
    clear = clear, rename = rename, retry = retry, remaining = remaining, format = format, activity = activity })

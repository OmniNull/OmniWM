-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local READY, FOCUSING, PAUSED, DONE = 0, 1, 2, 3
local lengths = table.freeze({ 15, 30, 45, 60 })
local names = table.freeze({ [READY] = "READY", [FOCUSING] = "FOCUSING", [PAUSED] = "PAUSED", [DONE] = "DONE" })
local arm

local function whole(value, low, high)
    return type(value) == "number" and value == value and value % 1 == 0 and value >= low and value <= high
end

local function allowed(minutes)
    return table.find(lengths, minutes) ~= nil
end

local function save(instance)
    local saved, err = omniwm.store.set("focus", instance.state.record)
    instance.state.saveError = if saved then nil else "Not saved: " .. tostring(err)
end

local function cancel(instance)
    local timer = instance.state.timer
    if timer then
        timer:cancel()
        instance.state.timer = nil
    end
end

local function finish(instance)
    cancel(instance)
    local record = instance.state.record
    record.state = DONE
    record.left = 0
    record.ends = nil
    save(instance)
end

arm = function(instance)
    local state = instance.state
    local record = state.record
    if state.timer or record.state ~= FOCUSING then return end
    local left = record.ends - os.time()
    if left <= 0 then
        finish(instance)
        return
    end
    local timer, err = omniwm.after(left, function()
        if state.record ~= record then return end
        state.timer = nil
        arm(instance)
    end)
    state.timer = timer
    state.error = if timer then nil else "Timer paused: " .. tostring(err)
end

local function restored(cached)
    if type(cached) ~= "table" or not allowed(cached.length) or not whole(cached.state, READY, DONE)
        or not whole(cached.total, 1, 3600) or not whole(cached.left, 0, cached.total)
    then
        return nil
    end
    local running = cached.state == FOCUSING
    if running and not whole(cached.ends, 1, 9007199254740991) then return nil end
    return { length = cached.length, state = cached.state, total = cached.total, left = cached.left,
        ends = if running then cached.ends else nil }
end

local function init(instance)
    instance.state.record = restored(omniwm.store.get("focus"))
        or { length = 30, state = READY, total = 30 * 60, left = 30 * 60 }
    instance.state.error = nil
    instance.state.saveError = nil
    arm(instance)
end

local function set(instance, minutes)
    local record = instance.state.record
    if (record.state ~= READY and record.state ~= DONE) or not allowed(minutes) then return end
    record.length = minutes
    record.total = minutes * 60
    record.left = record.total
    record.state = READY
    save(instance)
end

local function toggle(instance)
    local record = instance.state.record
    local now = os.time()
    if record.state == FOCUSING then
        cancel(instance)
        record.left = math.clamp(record.ends - now, 0, record.total)
        record.ends = nil
        record.state = PAUSED
    elseif record.state == PAUSED then
        record.ends = now + record.left
        record.state = FOCUSING
    else
        record.total = record.length * 60
        record.left = record.total
        record.ends = now + record.left
        record.state = FOCUSING
    end
    arm(instance)
    save(instance)
end

local function reset(instance)
    local record = instance.state.record
    if record.state ~= FOCUSING and record.state ~= PAUSED then return end
    cancel(instance)
    record.state = READY
    record.left = record.total
    record.ends = nil
    save(instance)
end

local function remaining(instance, now)
    local record = instance.state.record
    if record.state == FOCUSING then return math.clamp(record.ends - now, 0, record.total) end
    return record.left
end

local function fraction(instance, now)
    local total = instance.state.record.total
    return if total > 0 then remaining(instance, now) / total else 1
end

local function clock(seconds)
    local value = math.max(0, math.ceil(seconds))
    return string.format("%02d:%02d", value // 60, value % 60)
end

return table.freeze({
    READY = READY,
    FOCUSING = FOCUSING,
    PAUSED = PAUSED,
    DONE = DONE,
    lengths = lengths,
    names = names,
    init = init,
    cancel = cancel,
    set = set,
    toggle = toggle,
    reset = reset,
    remaining = remaining,
    fraction = fraction,
    clock = clock,
})

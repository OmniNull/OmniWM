local notice = require("./notice")

local function snapshot(ctx)
    return ctx.data.bluetooth
end

local function connected(data)
    local result = {}
    if not data or data.access ~= "granted" or not data.power then return result end
    for _, device in data.devices do
        if device.connected then result[#result + 1] = device end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

local function activity(ctx)
    local data = snapshot(ctx)
    local state = ctx.instance.state
    local current = {}
    local added = false
    local count = 0
    local ready = data and data.access == "granted" and data.power
    for _, device in (ready and data.devices) or {} do
        if device.connected then
            current[device.id] = true
            count += 1
            if state.connected and not state.connected[device.id] then added = true end
        end
    end
    if added and ctx.instance.options.alerts ~= false then
        notice.emit(ctx.instance, "connected")
    end
    if not ready or ctx.instance.options.alerts == false then state.notice = nil end
    state.connected = if ready then current else nil
    return { priority = if count > 0 then 5 else 0, label = tostring(count) .. " connected", alert = state.notice }
end

return table.freeze({ snapshot = snapshot, connected = connected, activity = activity,
    authorize = function() omniwm.run("bluetooth authorize") end,
    settings = function() omniwm.run("bluetooth settings") end })

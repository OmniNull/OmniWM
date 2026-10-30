local notice = require("./notice")

local function snapshot(ctx)
    return { level = ctx.data.battery, charging = ctx.data.charging, power = ctx.data.power }
end

local function label(battery)
    return battery.level and string.format("%.0f%%", battery.level) or "AC"
end

local function activity(ctx)
    local battery = snapshot(ctx)
    local state = ctx.instance.state
    local previous = state.battery
    local source = battery.power and battery.power.source
    local low = battery.level ~= nil and battery.level <= (ctx.instance.options.lowThreshold or 20)
        and not battery.charging and source ~= "ac"
    if ctx.instance.options.alerts ~= false then
        if low and (not previous or not previous.low) then
            notice.emit(ctx.instance, "battery-low")
        elseif previous and source and previous.source and source ~= previous.source then
            notice.emit(ctx.instance, "power")
        elseif previous and battery.charging and not previous.charging then
            notice.emit(ctx.instance, "charging")
        end
    else state.notice = nil end
    state.battery = { low = low, charging = battery.charging, source = source }
    return { priority = if low then 60 else 0, label = if low then "Low battery: " .. label(battery) else if battery.charging then "Charging: " .. label(battery) else label(battery), alert = state.notice }
end

return table.freeze({ snapshot = snapshot, label = label, activity = activity })

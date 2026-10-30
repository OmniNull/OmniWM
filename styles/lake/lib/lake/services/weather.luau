local function snapshot(ctx)
    return ctx.data.weather
end

local function status(weather)
    if not weather then return "Weather unavailable" end
    if weather.access == "off" then return omniwm.l10n("Turned off in Settings") end
    if weather.access == "blocked" then return omniwm.l10n("Blocked by your organization") end
    return if weather.status == "stale" then "Showing the last weather update" else weather.condition
end

return table.freeze({ snapshot = snapshot, status = status })

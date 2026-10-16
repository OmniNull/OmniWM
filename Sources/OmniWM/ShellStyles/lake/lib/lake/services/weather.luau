local function snapshot(ctx)
    return ctx.data.weather
end

local function status(weather)
    if not weather then return "Weather unavailable" end
    return if weather.status == "stale" then "Showing the last weather update" else weather.condition
end

return table.freeze({ snapshot = snapshot, status = status })

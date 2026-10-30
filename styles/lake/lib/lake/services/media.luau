local function snapshot(ctx)
    local title = ctx.select("media", "title")
    local bundle = ctx.select("media", "bundle")
    return { title = if title and title ~= "" then title else "Nothing playing",
        artist = ctx.select("media", "artist") or "", album = ctx.select("media", "album") or "",
        artwork = ctx.select("media", "artwork"), playing = ctx.select("media", "playing") == true,
        bundle = bundle, available = (title ~= nil and title ~= "") or (bundle ~= nil and bundle ~= "") }
end

local function position(ctx)
    local duration = ctx.select("media", "duration")
    local elapsed = ctx.select("media", "elapsed")
    if not duration or duration <= 0 or not elapsed then return nil end
    if ctx.select("media", "playing") == true then
        elapsed += math.max(0, ctx.data.seconds - ctx.select("media", "sampledAt")) * ctx.select("media", "rate")
    end
    local current = math.clamp(elapsed, 0, duration)
    return { elapsed = current, duration = duration, fraction = current / duration }
end

return table.freeze({ snapshot = snapshot, position = position,
    seek = function(seconds) omniwm.run(string.format("media seek %.1f", seconds)) end,
    button = require("../view").button, toggle = function() omniwm.run("media toggle") end,
    previous = function() omniwm.run("media previous") end, next = function() omniwm.run("media next") end })

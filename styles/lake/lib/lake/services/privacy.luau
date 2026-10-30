local function snapshot(ctx)
    return ctx.data.privacy
end

local function label(data)
    if not data then return "Privacy status unavailable" end
    if data.microphone and data.camera then return "Microphone and camera in use" end
    if data.microphone then return "Microphone in use" end
    if data.camera then return "Camera in use" end
    return "Microphone and camera idle"
end

return table.freeze({ snapshot = snapshot, label = label, activity = function(ctx)
    local data = snapshot(ctx)
    return { priority = if data and (data.microphone or data.camera) then 75 else 0, label = label(data) }
end })

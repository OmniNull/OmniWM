local kinds = table.freeze({ "file", "url", "text", "image" })

local function dismiss(state)
    if state.alertTimer then state.alertTimer:cancel(); state.alertTimer = nil end
    state.alertActive = nil
    state.alertQueue = {}
end

local function update(ctx, entries)
    local state = ctx.state
    state.alertSeen = state.alertSeen or {}
    state.alertQueue = state.alertQueue or {}
    local enabled = {}
    local offered = {}
    for _, entry in entries do
        enabled[entry.id] = true
        local activity = entry.activity
        for _, kind in (activity and activity.dropTypes) or {} do
            if table.find(kinds, kind) then offered[kind] = true end
        end
        local alert = activity and activity.alert
        if type(alert) == "table" and type(alert.id) == "string" and #alert.id <= 256
            and state.alertSeen[entry.id] ~= alert.id then
            state.alertSeen[entry.id] = alert.id
            local seconds = if type(alert.seconds) == "number" then math.clamp(alert.seconds, 0.1, 10) else 4
            for index = #state.alertQueue, 1, -1 do
                if state.alertQueue[index].id == entry.id then table.remove(state.alertQueue, index) end
            end
            if seconds == seconds and #state.alertQueue < 8 then
                state.alertQueue[#state.alertQueue + 1] = { id = entry.id, seconds = seconds }
            end
        end
    end
    for id in state.alertSeen do if not enabled[id] then state.alertSeen[id] = nil end end
    for index = #state.alertQueue, 1, -1 do
        if not enabled[state.alertQueue[index].id] then table.remove(state.alertQueue, index) end
    end
    if state.alertActive and not enabled[state.alertActive] then
        if state.alertTimer then state.alertTimer:cancel(); state.alertTimer = nil end
        state.alertActive = nil
    end
    if not state.alertActive and #state.alertQueue > 0 then
        local alert = table.remove(state.alertQueue, 1)
        local timer, err = omniwm.after(alert.seconds, function()
            state.alertTimer = nil
            state.alertActive = nil
            state.motion = "mode"
        end)
        if timer then
            state.alertTimer = timer
            state.alertActive = alert.id
            state.alertError = nil
            state.motion = "promotion"
        else state.alertError = "Alert could not be scheduled: " .. tostring(err) end
    end
    local accepts = {}
    for _, kind in kinds do if offered[kind] then accepts[#accepts + 1] = kind end end
    local drag = ctx.data.island and ctx.data.island.drag
    if drag and drag.active then
        for _, entry in entries do
            for _, kind in (entry.activity and entry.activity.dropTypes) or {} do
                if table.find(drag.types, kind) then return entry.id, "expanded", accepts end
            end
        end
    end
    if not state.expanded and state.alertActive then return state.alertActive, "peek", accepts end
    return nil, nil, accepts
end

return table.freeze({ update = update, dismiss = dismiss })

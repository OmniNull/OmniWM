local function hold(state, reason)
    state.holds = state.holds or {}
    state.holds[reason] = true
end

local function release(state, reason)
    if state.holds then state.holds[reason] = nil end
end

local function active(state)
    return state.holds ~= nil and next(state.holds) ~= nil
end

return table.freeze({ hold = hold, release = release, active = active })

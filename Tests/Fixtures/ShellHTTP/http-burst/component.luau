local function cancel(instance)
    for _, handle in instance.state.requests or {} do handle:cancel() end
    instance.state.requests = {}
end

local function start(ctx)
    local instance = ctx.instance
    cancel(instance)
    local state = instance.state
    state.accepted, state.rejected, state.finished, state.failed = 0, 0, 0, 0
    for index = 1, 32 do
        local request, failure = omniwm.http({
            url = instance.options.endpoint .. (index <= 4 and "/stall" or "/ok"),
            response = "json", timeout = instance.options.timeout, maxBytes = 262144,
        }, function(result)
            state.requests[index] = nil
            state.finished += 1
            if not result.ok then state.failed += 1; state.error = result.error end
        end)
        if request then
            state.requests[index] = request
            state.accepted += 1
        else
            state.rejected += 1
            state.error = failure
        end
    end
end

local function render(ctx)
    local state = ctx.instance.state
    return ui.column{ gap = 8, pad = 8,
        ui.text{ text = "Accepted " .. tostring(state.accepted or 0) .. " · Rejected " .. tostring(state.rejected or 0) },
        ui.text{ text = "Finished " .. tostring(state.finished or 0) .. " · Failed " .. tostring(state.failed or 0) },
        ui.text{ text = state.error or "Start 32 requests, including 4 stalled responses" },
        ui.box{ pad = 8, radius = 8, hover = "#ffffff22", pressScale = 0.96, onClick = start,
            ui.text{ text = "Run burst" } } }
end

return { init = function(instance) instance.state.requests = {} end,
    deinit = cancel, options = cancel, views = { compact = render, expanded = render } }

local service = require("../lib/lake/services/timer")
local view = require("../lib/lake/view")
local digits = require("../lib/lake/digits")

local function remaining(ctx)
    local instance = ctx.instance
    return service.remaining(instance, instance.state.record.status == "running" and ctx.data.seconds or 0)
end

local function start(ctx, text)
    local record = ctx.instance.state.record
    local ok, err = service.start(ctx.instance, ctx.state.label or record.label, text or ctx.state.duration or service.format(record.duration))
    ctx.state.formError = err
    if ok then ctx.state.label = nil; ctx.state.duration = nil; ctx.state.editingLabel = false; ctx.state.editingDuration = false end
end

local function primary(ctx)
    local status = ctx.instance.state.record.status
    if status == "running" then service.pause(ctx.instance)
    elseif status == "paused" then service.resume(ctx.instance)
    else start(ctx) end
end

local function controls(ctx)
    local status = ctx.instance.state.record.status
    return ui.row{ gap = 8,
        view.button(status == "running" and "pause.fill" or "play.fill", primary),
        status ~= "idle" and view.button(status == "done" and "checkmark" or "stop.fill", function(next)
            service.clear(next.instance)
        end) or nil }
end

local function compact(ctx)
    local record = ctx.instance.state.record
    local failed = ctx.instance.state.error ~= nil
    local text = failed and "Retry" or record.status == "done" and "Done" or service.format(remaining(ctx))
    return view.compact(ctx, failed and "exclamationmark.circle" or record.status == "paused" and "pause.circle" or "timer", text, "#fbbf24")
end

local function peek(ctx)
    return ui.row{ gap = 12, dy = (ctx.view.props or {}).top or 0,
        ui.column{ gap = 4, center = false,
            ui.text{ text = ctx.instance.state.record.label, size = 12, color = view.foreground, maxWidth = 230 },
            ui.text{ text = service.format(remaining(ctx)), size = 16, style = "mono", color = "#fbbf24" } },
        controls(ctx) }
end

local function expanded(ctx)
    local instance = ctx.instance
    local record = instance.state.record
    local state = ctx.state
    local inactive = record.status == "idle" or record.status == "done"
    local retry = instance.state.error or instance.state.saveError or omniwm.store.status.error
    local error = state.formError or retry
    local rows = { gap = 10, align = "top", dy = (ctx.view.props or {}).top or 0,
        ui.input{ key = state.labelReset and "label:1" or "label:0", text = state.label or record.label, placeholder = "Timer label", w = 300, h = 28, maxLength = 80,
            focus = state.editingLabel, onChange = function(next, event) next.state.label = event.text end,
            onFocus = function(next, event) next.state.editingLabel = event.focused end,
            onCommit = function(next, event)
                service.rename(next.instance, event.text); next.state.label = nil; next.state.editingLabel = false
            end,
            onCancel = function(next)
                next.state.label = nil; next.state.editingLabel = false; next.state.labelReset = not next.state.labelReset
            end },
        digits.render(service.format(remaining(ctx)), { size = 40, key = "countdown", color = "#fbbf24" }) }
    if inactive then
        rows[#rows + 1] = ui.row{ gap = 8,
            ui.text{ text = "Duration (m:ss)", size = 12, color = view.secondary },
            ui.input{ key = state.durationReset and "duration:1" or "duration:0", text = state.duration or service.format(record.duration), w = 110, h = 28, maxLength = 7,
                focus = state.editingDuration, onChange = function(next, event) next.state.duration = event.text; next.state.formError = nil end,
                onFocus = function(next, event) next.state.editingDuration = event.focused end,
                onCommit = function(next, event) start(next, event.text) end,
                onCancel = function(next)
                    next.state.duration = nil; next.state.editingDuration = false; next.state.durationReset = not next.state.durationReset
                end } }
    end
    rows[#rows + 1] = controls(ctx)
    if record.status == "done" then rows[#rows + 1] = ui.text{ text = "Timer complete", size = 13, color = "#fbbf24" } end
    if error then rows[#rows + 1] = ui.text{ text = error, size = 11, color = "#fda4af", maxWidth = 340 } end
    if retry then
        rows[#rows + 1] = ui.box{ key = "retry", pad = 6, radius = 7, hover = "#ffffff18", pressScale = 0.97,
            onClick = function(next) service.retry(next.instance) end,
            ui.text{ text = "Retry", size = 12, color = view.foreground } }
    end
    return ui.column(rows)
end

return { init = service.initialize, deinit = service.cancel,
    activity = function(ctx) return service.activity(ctx.instance) end,
    views = { compact = compact, peek = peek, expanded = expanded } }

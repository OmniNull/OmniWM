local note = require("../lib/lake/services/note")
local view = require("../lib/lake/view")

local function expanded(ctx)
    local instance = ctx.instance
    local text = ctx.state.draft or instance.state.text or ""
    local problem = instance.state.error or omniwm.store.status.error
    return ui.column{ gap = 10, align = "top", dy = (ctx.view.props or {}).top or 0,
        ui.text{ text = "Quick note", size = 17, color = view.foreground },
        ui.input{ key = ctx.state.reset and "note-b" or "note-a", w = math.max(120, (ctx.view.w or 400) - 40), h = 110,
            text = instance.state.text or "", placeholder = "Write a note…", multiline = true,
            maxLength = 16384, size = 13, color = view.foreground,
            onChange = function(next, event) next.state.draft = event.text end,
            onCommit = function(next, event) note.save(next.instance, event.text); next.state.draft = nil end,
            onCancel = function(next) next.state.draft = nil; next.state.reset = not next.state.reset end },
        ui.row{ gap = 12,
            view.button("square.and.arrow.down", function(next) note.save(next.instance, next.state.draft or next.instance.state.text or ""); next.state.draft = nil end),
            view.button("doc.on.doc", function() note.copy(instance, text) end),
            ui.text{ text = if problem then tostring(problem) else if ctx.state.draft then "Unsaved changes" else if omniwm.store.status.state == "pending" then "Saving…" else "Saved", size = 11, maxWidth = 300, color = view.secondary } } }
end

return {
    init = note.init,
    views = {
        compact = function(ctx) return view.compact(ctx, "note.text", "Note") end,
        expanded = expanded,
    },
}

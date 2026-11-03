local function apply(ctx)
    ctx.state.result = if (ctx.state.draft or "") == "" then "Type something first." else "You wrote: " .. ctx.state.draft
end

return {
    views = {
        window = function(ctx)
            local pad = 20
            local width = math.max(0, ctx.view.w - 2 * pad)
            local wide = width >= 440
            local field = ui.input{
                key = "draft", w = if wide then width - 112 else width, h = 36,
                text = ctx.state.draft or "", placeholder = "Type a message", color = "foreground",
                onChange = function(next, event) next.state.draft = event.text or "" end,
                onCommit = apply,
            }
            local button = ui.box{ w = 100, h = 36, color = "accent", radius = 8, onClick = apply,
                ui.text{ text = "Apply", color = "foreground", size = 14 } }
            local entry = if wide then ui.row{ gap = 12, field, button } else ui.column{ gap = 12, field, button }
            return ui.column{ w = ctx.view.w, h = ctx.view.h, pad = pad, gap = 16, center = false, color = "background",
                ui.text{ text = "OmniShell Example", size = 22, color = "foreground" },
                ui.text{ text = string.format("Content: %.0f × %.0f", ctx.view.w, ctx.view.h),
                    size = 13, color = "secondaryForeground" },
                entry,
                ui.text{ key = "result", text = ctx.state.result or "Resize the window, then type and press Apply.",
                    w = width, wrap = true, size = 15, color = "foreground" },
            }
        end,
    },
}

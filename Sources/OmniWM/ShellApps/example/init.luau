local function apply(ctx)
    ctx.instance.state.result = if (ctx.state.draft or "") == "" then "Type something first." else "You wrote: " .. ctx.state.draft
end

return {
    views = {
        window = function(ctx)
            local pad = 20
            local width = math.max(0, ctx.view.w - 2 * pad)
            local wide = width >= 440
            local actionWidth = math.min(100, (width - 24) / 3)
            local field = ui.input{
                key = "draft", w = if wide then width - (3 * actionWidth + 36) else width, h = 36,
                text = ctx.state.draft or "", placeholder = "Type a message", color = "foreground",
                onChange = function(next, event) next.state.draft = event.text or "" end,
                onCommit = apply,
            }
            local button = ui.stack{ w = actionWidth, h = 36, fill = "accent", radius = 8, onClick = apply,
                ui.text{ text = "Apply", color = "foreground", size = 14 } }
            local delete = ui.stack{ key = "delete", w = actionWidth, h = 36, fill = "accent", radius = 8,
                onClick = function(next)
                    omniwm.windows.open("confirm", function(result)
                        next.state.dialogError = result.error
                    end)
                end,
                ui.text{ text = "Delete", color = "foreground", size = 14 } }
            local preferences = ui.stack{ key = "preferences", w = actionWidth, h = 36, fill = "elevatedSurface", radius = 8,
                onClick = function(next)
                    omniwm.windows.open("preferences", function(result)
                        next.state.dialogError = result.error
                    end)
                end,
                ui.text{ text = "Preferences", color = "foreground", size = 12 } }
            local actions = ui.row{ gap = 12, button, delete, preferences }
            local entry = if wide then ui.row{ gap = 12, field, actions } else ui.column{ gap = 12, field, actions }
            return ui.column{ w = ctx.view.w, h = ctx.view.h, pad = pad, gap = 16, center = false, fill = "background",
                ui.text{ text = ctx.instance.state.heading or "OmniShell Example", size = 22, color = "foreground" },
                ui.text{ text = string.format("Content: %.0f × %.0f", ctx.view.w, ctx.view.h),
                    size = 13, color = "secondaryForeground" },
                entry,
                ui.text{ key = "result", text = ctx.state.dialogError or ctx.instance.state.result or "Resize the window, then type and press Apply.",
                    w = width, wrap = true, size = 15, color = "foreground" },
            }
        end,
        preferences = function(ctx)
            return ui.column{ w = ctx.view.w, h = ctx.view.h, pad = 16, gap = 12, fill = "background",
                ui.text{ text = "Preferences", size = 20, color = "foreground" },
                ui.text{ text = "Edit the heading while the main window stays usable.",
                    w = ctx.view.w - 32, wrap = true, color = "secondaryForeground" },
                ui.input{ key = "heading", w = ctx.view.w - 32, h = 36,
                    text = ctx.instance.state.heading or "OmniShell Example", color = "foreground",
                    onChange = function(next, event) next.instance.state.heading = event.text or "" end },
                ui.stack{ key = "close-preferences", w = 120, h = 36, fill = "elevatedSurface", radius = 8,
                    onClick = function() omniwm.windows.close("preferences") end,
                    ui.text{ text = "Close", color = "foreground" } },
            }
        end,
        confirm = function(ctx)
            return ui.column{ w = ctx.view.w, h = ctx.view.h, pad = 16, gap = 12, fill = "background",
                ui.text{ text = "Delete the result?", size = 20, color = "foreground" },
                ui.text{ text = "Your draft stays in the main window.", wrap = true, color = "secondaryForeground" },
                ui.input{ key = "note", w = ctx.view.w - 32, h = 28,
                    text = ctx.state.note or "", placeholder = "Optional note", color = "foreground",
                    onChange = function(next, event) next.state.note = event.text or "" end },
                ui.row{ gap = 12,
                    ui.stack{ key = "confirm", w = 120, h = 36, fill = "accent", radius = 8,
                        onClick = function(next)
                            next.instance.state.result = "Deleted."
                            omniwm.windows.close("confirm")
                        end,
                        ui.text{ text = "Confirm", color = "foreground" } },
                    ui.stack{ key = "cancel", w = 120, h = 36, fill = "surface", radius = 8,
                        onClick = function() omniwm.windows.close("confirm") end,
                        ui.text{ text = "Cancel", color = "foreground" } },
                },
            }
        end,
    },
}

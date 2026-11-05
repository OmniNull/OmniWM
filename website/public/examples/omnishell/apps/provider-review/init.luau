local function button(key, label, onClick)
    return ui.stack{ key = key, w = 150, h = 36, fill = "elevatedSurface", radius = 8, onClick = onClick,
        ui.text{ text = label, color = "foreground", size = 14 } }
end

return {
    receive = function(instance, event)
        if event.name == "confirm-delete" then
            instance.state.itemId = event.value.itemId
        end
    end,
    views = {
        window = function(ctx)
            local provider = ctx.instance.provider
            local itemId = ctx.instance.state.itemId
            return ui.column{ w = ctx.view.w, h = ctx.view.h, pad = 20, gap = 12, center = false, fill = "background",
                ui.text{ text = provider.state.summary or provider.status, size = 15, color = "foreground" },
                ui.text{ text = ctx.instance.state.result or "Nothing deleted yet.", color = "secondaryForeground" },
                button("check", "Check for work", function() omniwm.provider.send("check") end),
                if itemId then button("review", "Review " .. itemId, function()
                    omniwm.windows.open("confirm")
                end) else nil,
            }
        end,
        confirm = function(ctx)
            return ui.column{ w = ctx.view.w, h = ctx.view.h, pad = 16, gap = 12, fill = "background",
                ui.text{ text = "Delete " .. (ctx.instance.state.itemId or "this item") .. "?", size = 18, color = "foreground" },
                ui.row{ gap = 12,
                    button("confirm", "Delete", function(next)
                        next.instance.state.result = "Deleted " .. next.instance.state.itemId .. "."
                        next.instance.state.itemId = nil
                        omniwm.windows.close("confirm")
                    end),
                    button("cancel", "Cancel", function() omniwm.windows.close("confirm") end),
                },
            }
        end,
    },
}

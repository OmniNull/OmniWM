return {
    views = {
        compact = function(ctx)
            return ui.row{ gap = 8,
                ui.symbol{ name = "clock", size = 13, color = "#ffffff" },
                ui.text{ text = ctx.instance.options.label .. ": " .. ctx.data.clock, size = 12, color = "#ffffff" } }
        end,
        expanded = function(ctx)
            return ui.column{ gap = 8,
                ui.text{ text = ctx.instance.options.label, color = "#a1a1aa", size = 12 },
                ui.text{ text = ctx.data.clock, size = 32, style = "bold", color = "#ffffff" },
                ui.text{ text = ctx.data.date, color = "#d4d4d8", size = 13 } }
        end,
    },
}

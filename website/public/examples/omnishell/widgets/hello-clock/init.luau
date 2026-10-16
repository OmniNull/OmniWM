interval = 60

function render(ctx)
    local content = { key = "clock", gap = 8, pad = 6, radius = 8, fill = "surface" }
    content[#content + 1] = ui.symbol{ name = "clock", color = "accent", size = 14 }
    content[#content + 1] = ui.text{ text = ctx.data.clock, style = "bold", reserve = "00:00 PM" }
    if ctx.select("settings", "date") ~= false then
        content[#content + 1] = ui.text{ text = ctx.data.date, color = "secondaryForeground", size = 11 }
    end
    return ui.row(content)
end

-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

function render(ctx)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local fill = style.backgrounds and "surface" or nil
    local edge = style.backgrounds and "border/0.6" or nil
    if style.vertical then
        return ui.column{ w = size, gap = 0, radius = size / 2 - 1, fill = fill, border = edge, borderWidth = 1,
            ui.box{ w = 1, h = 6 },
            ui.text{ text = os.date("%H"), size = 14 * scale, weight = "bold", color = "accent" },
            ui.text{ text = os.date("%M"), size = 14 * scale, weight = "medium" },
            ui.box{ w = 1, h = 6 } }
    end
    local settings = ctx.data.settings or {}
    local row = { h = size, gap = 7, radius = size / 2 - 1, fill = fill, border = edge, borderWidth = 1,
        ui.box{ w = 3, h = 1 } }
    if settings.date ~= false then
        row[#row + 1] = ui.text{ text = ctx.data.date, size = 12 * scale, weight = "medium", color = "secondaryForeground" }
        row[#row + 1] = ui.box{ w = 3, h = 3, radius = 1.5, fill = "mutedForeground" }
    end
    row[#row + 1] = ui.text{ text = ctx.data.clock, size = 14 * scale, weight = "bold", color = "accent", reserve = "00:00 PM" }
    row[#row + 1] = ui.box{ w = 3, h = 1 }
    return ui.row(row)
end

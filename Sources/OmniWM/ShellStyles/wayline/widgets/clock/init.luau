-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local HUE = "accent"

local function block(size: number, radius: number, vertical: boolean)
    return ui.stack{ w = size, h = size,
        ui.box{ w = size, h = size, radius = radius, fill = HUE },
        ui.box{ align = vertical and "bottom" or "trailing", w = vertical and size or radius,
            h = vertical and radius or size, fill = HUE },
        ui.symbol{ name = "clock.fill", size = math.floor(size * 0.54), weight = "semibold", color = "accentForeground" } }
end

function render(ctx)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local radius = math.floor(size * 0.24)
    if style.vertical then
        return ui.column{ w = size, gap = 2, radius = radius, fill = "elevatedSurface",
            block(size, radius, true),
            ui.text{ text = os.date("%H"), style = "mono", size = 14 * scale, weight = "bold", color = HUE },
            ui.text{ text = os.date("%M"), style = "mono", size = 14 * scale, weight = "semibold", color = HUE },
            ui.box{ w = 1, h = 3 } }
    end
    local settings = ctx.data.settings or {}
    local row = { h = size, gap = 0, radius = radius, fill = "elevatedSurface", block(size, radius, false),
        ui.box{ w = 8, h = 1 } }
    if settings.date ~= false then
        row[#row + 1] = ui.text{ text = ctx.data.date, size = 12 * scale, weight = "medium", color = HUE }
        row[#row + 1] = ui.box{ w = 6, h = 1 }
    end
    row[#row + 1] = ui.text{ text = ctx.data.clock, style = "mono", size = 14 * scale, weight = "bold", color = HUE,
        reserve = "00:00 PM" }
    row[#row + 1] = ui.box{ w = 9, h = 1 }
    return ui.row(row)
end

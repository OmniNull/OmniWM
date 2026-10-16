-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local function symbol(level: number, charging: boolean): string
    if charging then
        return "battery.100percent.bolt"
    end
    if level > 85 then
        return "battery.100percent"
    end
    if level > 60 then
        return "battery.75percent"
    end
    if level > 35 then
        return "battery.50percent"
    end
    if level > 10 then
        return "battery.25percent"
    end
    return "battery.0percent"
end

local function block(size: number, radius: number, vertical: boolean, hue: string, name: string)
    return ui.stack{ w = size, h = size,
        ui.box{ w = size, h = size, radius = radius, fill = hue },
        ui.box{ align = vertical and "bottom" or "trailing", w = vertical and size or radius,
            h = vertical and radius or size, fill = hue },
        ui.symbol{ name = name, size = math.floor(size * 0.52), weight = "semibold", color = "accentForeground" } }
end

function render(ctx)
    local level = ctx.data.battery
    if not level then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local radius = math.floor(size * 0.24)
    local low = level <= 20 and not ctx.data.charging
    local hue = low and "red" or (ctx.data.charging and "green" or "yellow")
    local glyph = block(size, radius, style.vertical, hue, symbol(level, ctx.data.charging))
    if style.vertical then
        return ui.column{ w = size, gap = 2, radius = radius, fill = "elevatedSurface", glyph,
            ui.text{ text = tostring(level), style = "mono", size = 14 * scale, weight = "semibold", color = hue },
            ui.box{ w = 1, h = 3 } }
    end
    return ui.row{ h = size, gap = 0, radius = radius, fill = "elevatedSurface", glyph,
        ui.box{ w = 8, h = 1 },
        ui.text{ text = ctx.format.percent(level / 100), style = "mono", size = 14 * scale, weight = "semibold", color = hue,
            reserve = ctx.format.percent(1) },
        ui.box{ w = 9, h = 1 } }
end

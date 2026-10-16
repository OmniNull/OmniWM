-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local function cell(level: number, charging: boolean, low: boolean, scale: number)
    local w, h = 24 * scale, 13 * scale
    local inner = w - 4 * scale
    local tint = low and "error" or (charging and "success" or "foreground")
    local body = ui.stack{ w = w, h = h, radius = 3.5 * scale, border = low and "error/0.8" or "foreground/0.45",
        borderWidth = 1.2 * scale,
        ui.box{ align = "leading", dx = 2 * scale, w = math.max(2 * scale, inner * math.clamp(level, 0, 100) / 100), h = h - 4 * scale,
            radius = 1.5 * scale, fill = tint } }
    if charging then
        body = ui.stack{ w = w, h = h, body,
            ui.symbol{ name = "bolt.fill", size = 8 * scale, weight = "black", color = "background" } }
    end
    return ui.row{ gap = scale, body,
        ui.box{ w = 1.5 * scale, h = 4 * scale, radius = 0.75 * scale, fill = low and "error/0.8" or "foreground/0.45" } }
end

function render(ctx)
    local level = ctx.data.battery
    if not level then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local charging = ctx.data.charging
    local low = level <= 20 and not charging
    local fill = style.backgrounds and "surface" or nil
    local edge = style.backgrounds and "border/0.6" or nil
    if style.vertical then
        return ui.column{ w = size, gap = 3, radius = size / 2 - 1, fill = fill, border = edge, borderWidth = 1,
            ui.box{ w = 1, h = 3 },
            cell(level, charging, low, scale),
            ui.text{ text = tostring(level), style = "mono", size = 14 * scale, weight = "semibold",
                color = low and "error" or "foreground" },
            ui.box{ w = 1, h = 3 } }
    end
    return ui.row{ h = size, gap = 6, radius = size / 2 - 1, fill = fill, border = edge, borderWidth = 1,
        ui.box{ w = 2, h = 1 },
        cell(level, charging, low, scale),
        ui.text{ text = ctx.format.percent(level / 100), size = 14 * scale, weight = "semibold",
            color = low and "error" or "foreground", reserve = ctx.format.percent(1) },
        ui.box{ w = 2, h = 1 } }
end

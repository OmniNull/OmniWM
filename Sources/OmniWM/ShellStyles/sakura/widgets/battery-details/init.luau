-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")
local WIDTH = style.width

local function tint(level: number, charging: boolean): string
    if charging then
        return "success"
    end
    if level <= 10 then
        return "error"
    end
    return if level <= 20 then "warning" else "foreground"
end

local function cell(level: number, charging: boolean, w: number, h: number, inside: string?)
    local inner = w - 4
    local color = tint(level, charging)
    local body = { w = w, h = h, radius = h * 0.3, border = "foreground/0.45", borderWidth = 1,
        ui.box{ align = "leading", dx = 2, w = math.max(1.5, inner * level / 100), h = h - 4, radius = (h - 4) * 0.3,
            fill = if inside then color .. "/0.22" else color } }
    if inside then
        body[#body + 1] = ui.text{ text = inside, size = h * 0.72, weight = "semibold" }
    elseif charging then
        body[#body + 1] = ui.symbol{ name = "bolt.fill", size = h * 0.78, color = "foreground" }
    end
    return ui.row{ gap = 1,
        ui.stack(body),
        ui.box{ w = math.max(1.5, h * 0.14), h = h * 0.4, radius = h * 0.07, fill = "foreground/0.45" } }
end

local function duration(minutes: number): string
    return omniwm.l10n("%lldh %lldm", minutes // 60, minutes % 60)
end

local function status(ctx: Context, state): string
    if state.charged then
        return omniwm.l10n("Fully charged")
    end
    if ctx.data.charging then
        return omniwm.l10n("Charging")
    end
    return if state.source == "ac" then omniwm.l10n("Not charging") else omniwm.l10n("On battery")
end

local function line(label: string, value: string)
    return ui.row{ w = WIDTH - 24, gap = 8,
        ui.text{ text = label, size = 13, color = "secondaryForeground", grow = 1, maxWidth = 170 },
        ui.text{ text = value, size = 13, weight = "medium", maxWidth = 118 } }
end

function render(ctx: Context)
    local level = ctx.data.battery
    if not level then
        return ui.box{ w = 0, h = 0 }
    end
    local charging = ctx.data.charging
    local scale = style.scale(ctx)
    local settings = ctx.data.settings or {}
    local percent = settings.percent or "beside"
    local item = { onClick = ui.popout, help = ctx.format.percent(level / 100) }
    if ctx.data.bar.style.vertical then
        item.gap = scale
        item.pad = 2 * scale
        item[#item + 1] = cell(level, charging, 17 * scale, 10 * scale)
        item[#item + 1] = ui.text{ text = tostring(level), size = 10 * scale }
        return style.bar(ctx, item)
    end
    if percent == "inside" then
        item[#item + 1] = cell(level, charging, 30 * scale, 15 * scale, tostring(level))
    else
        item[#item + 1] = cell(level, charging, 23 * scale, 12 * scale)
        if percent == "beside" then
            item[#item + 1] = ui.text{ text = ctx.format.percent(level / 100), size = 13 * scale,
                reserve = ctx.format.percent(1) }
        end
    end
    return style.bar(ctx, item)
end

function popout(ctx: Context)
    local level = ctx.data.battery
    if not level then
        return ui.box{ w = 0, h = 0 }
    end
    local state = ctx.data.power or {}
    local charging = ctx.data.charging
    local rows = { style.heading(omniwm.l10n("Battery"), WIDTH),
        style.group{ w = WIDTH,
            ui.row{ w = WIDTH - 24, gap = 16,
                cell(level, charging, 58, 28),
                ui.column{ gap = 3, center = false,
                    ui.text{ text = ctx.format.percent(level / 100), size = 28, weight = "medium" },
                    ui.text{ text = status(ctx, state), size = 13, color = "secondaryForeground",
                        maxWidth = WIDTH - 108 } } } } }
    local details = { w = WIDTH }
    if state.source then
        details[#details + 1] = line(omniwm.l10n("Power Source"),
            if state.source == "ac" then omniwm.l10n("Power Adapter") else omniwm.l10n("Battery"))
    end
    if not charging and state.remaining then
        details[#details + 1] = line(omniwm.l10n("Time Remaining"), duration(state.remaining))
    elseif charging and state.full then
        details[#details + 1] = line(omniwm.l10n("Time to Full"), duration(state.full))
    end
    if state.lowPower ~= nil then
        details[#details + 1] = line(omniwm.l10n("Low Power Mode"),
            if state.lowPower then omniwm.l10n("On") else omniwm.l10n("Off"))
    end
    if #details > 0 then
        rows[#rows + 1] = style.group(details)
    end
    rows[#rows + 1] = ui.row{ w = WIDTH, gap = 8, pad = 6, radius = 8, hover = style.hover,
        onClick = "battery settings",
        ui.symbol{ name = "gearshape", w = 16, h = 16, color = "secondaryForeground" },
        ui.text{ text = omniwm.l10n("Battery Settings…"), size = 13 } }
    return style.panel(rows)
end

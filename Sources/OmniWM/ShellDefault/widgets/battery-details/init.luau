-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local WIDTH = 272

local function power(ctx: Context)
    return ctx.data.power or {}
end

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
        body[#body + 1] = ui.text{ text = inside, size = h * 0.72, weight = "bold", style = "rounded" }
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
        ui.text{ text = label, color = "secondaryForeground", grow = 1 },
        ui.text{ text = value, weight = "medium" } }
end

local function panel(style: BarStyle, props)
    if style.transparent and style.backgrounds then
        props.material = "clear"
        props.fill = "background"
        props.border = "border"
        props.borderWidth = 1
        props.radius = 14
    end
    return ui.column(props)
end

function render(ctx: Context)
    local level = ctx.data.battery
    if not level then
        return ui.box{ w = 0, h = 0 }
    end
    local charging = ctx.data.charging
    local style = ctx.data.bar.style
    local settings = ctx.data.settings or {}
    local percent = settings.percent or "beside"
    local size = math.max(16, style.height - 4)
    local capsule = style.transparent and style.backgrounds
    local item = { gap = 6, radius = if capsule then size / 2 else 4, hover = "foreground/0.12", onClick = ui.popout,
        help = ctx.format.percent(level / 100),
        fill = if capsule then "surface" else nil, border = if capsule then "border" else nil, borderWidth = 0.5 }
    if style.vertical then
        item.w = size
        item.gap = 2
        item[#item + 1] = ui.box{ w = 1, h = 4 }
        item[#item + 1] = cell(level, charging, size * 0.62, size * 0.32)
        item[#item + 1] = ui.text{ text = tostring(level), style = "mono", size = 9 }
        item[#item + 1] = ui.box{ w = 1, h = 4 }
        return ui.column(item)
    end
    item.h = size
    item[#item + 1] = ui.box{ w = if capsule then 4 else 0, h = 1 }
    if percent == "inside" then
        item[#item + 1] = cell(level, charging, 30, 15, tostring(level))
    else
        item[#item + 1] = cell(level, charging, 23, 12)
        if percent == "beside" then
            item[#item + 1] = ui.text{ text = ctx.format.percent(level / 100), style = "mono", size = 12,
                reserve = ctx.format.percent(1) }
        end
    end
    item[#item + 1] = ui.box{ w = if capsule then 4 else 0, h = 1 }
    return ui.row(item)
end

function popout(ctx: Context)
    local level = ctx.data.battery
    if not level then
        return ui.box{ w = 0, h = 0 }
    end
    local state = power(ctx)
    local charging = ctx.data.charging
    local rows = { w = WIDTH, gap = 10, pad = 12, center = false,
        ui.row{ w = WIDTH - 24, gap = 14,
            cell(level, charging, 58, 28),
            ui.column{ gap = 1, center = false,
                ui.text{ text = ctx.format.percent(level / 100), style = "rounded", size = 24, weight = "semibold" },
                ui.text{ text = status(ctx, state), style = "small", color = "secondaryForeground",
                    maxWidth = WIDTH - 120 } } },
        ui.box{ w = WIDTH - 24, h = 1, fill = "border" } }
    if state.source then
        rows[#rows + 1] = line(omniwm.l10n("Power Source"),
            if state.source == "ac" then omniwm.l10n("Power Adapter") else omniwm.l10n("Battery"))
    end
    if not charging and state.remaining then
        rows[#rows + 1] = line(omniwm.l10n("Time Remaining"), duration(state.remaining))
    elseif charging and state.full then
        rows[#rows + 1] = line(omniwm.l10n("Time to Full"), duration(state.full))
    end
    if state.lowPower ~= nil then
        rows[#rows + 1] = line(omniwm.l10n("Low Power Mode"),
            if state.lowPower then omniwm.l10n("On") else omniwm.l10n("Off"))
    end
    rows[#rows + 1] = ui.row{ w = WIDTH - 24, gap = 10, pad = 6, radius = 8, hover = "foreground/0.12",
        onClick = "battery settings",
        ui.symbol{ name = "gearshape", w = 14, h = 14, color = "secondaryForeground" },
        ui.text{ text = omniwm.l10n("Battery Settings…") } }
    return panel(ctx.data.bar.style, rows)
end

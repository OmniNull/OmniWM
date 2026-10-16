-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

interval = 30

local WIDTH = 272
local ZONES = {
    { label = "London", zone = "Europe/London" },
    { label = "Tokyo", zone = "Asia/Tokyo" },
}

type Moment = { time: string, day: number, hour: number, minutes: number }

local function moment(ctx: Context, zone: string?): Moment?
    local now = ctx.data.seconds
    local offset = ctx.format.offset(now, zone)
    if not offset then
        return nil
    end
    local parts = os.date("!*t", math.floor(now + offset))
    return { time = ctx.format.date(now, "jmm", zone) or "", minutes = offset // 60, hour = parts.hour,
        day = parts.year * 10000 + parts.month * 100 + parts.day }
end

local function relative(here: Moment, there: Moment): string
    local day = if there.day > here.day then omniwm.l10n("Tomorrow")
        elseif there.day < here.day then omniwm.l10n("Yesterday")
        else omniwm.l10n("Today")
    local minutes = there.minutes - here.minutes
    if minutes == 0 then
        return day
    end
    local sign = if minutes > 0 then "+" else "−"
    local whole = math.abs(minutes)
    local shift = if whole % 60 == 0 then string.format("%s%d h", sign, whole // 60)
        else string.format("%s%d:%02d h", sign, whole // 60, whole % 60)
    return day .. ", " .. shift
end

local function zones(ctx: Context)
    local settings = ctx.data.settings or {}
    return if type(settings.zones) == "table" and #settings.zones > 0 then settings.zones else ZONES
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
    local style = ctx.data.bar.style
    local settings = ctx.data.settings or {}
    local size = math.max(16, style.height - 4)
    local capsule = style.transparent and style.backgrounds
    local shown = math.max(1, tonumber(settings.bar) or 1)
    local list = {}
    for _, entry in zones(ctx) do
        local there = moment(ctx, entry.zone)
        if there then
            list[#list + 1] = { label = entry.label, moment = there }
        end
    end
    if #list == 0 then
        return ui.box{ w = 0, h = 0 }
    end
    local item = { gap = 6, radius = if capsule then size / 2 else 4, hover = "foreground/0.12", onClick = ui.popout,
        fill = if capsule then "surface" else nil, border = if capsule then "border" else nil, borderWidth = 0.5 }
    if style.vertical then
        item.w = size
        item.gap = 1
        item.help = list[1].label .. " " .. list[1].moment.time
        item[#item + 1] = ui.symbol{ name = "globe", size = 11, color = if capsule then "accent" else "foreground" }
        item[#item + 1] = ui.text{ text = string.format("%02d", list[1].moment.hour), style = "mono", size = 9 }
        return ui.column(item)
    end
    item.h = size
    item[#item + 1] = ui.box{ w = if capsule then 4 else 0, h = 1 }
    item[#item + 1] = ui.symbol{ name = "globe", size = 12, weight = "semibold",
        color = if capsule then "accent" else "foreground" }
    for index = 1, math.min(shown, #list) do
        local entry = list[index]
        if index > 1 then
            item[#item + 1] = ui.box{ w = 1, h = size * 0.45, fill = "border" }
        end
        item[#item + 1] = ui.text{ text = string.upper(string.sub(entry.label, 1, 3)), size = 10, weight = "semibold",
            color = "secondaryForeground" }
        item[#item + 1] = ui.text{ text = entry.moment.time, weight = "semibold", reserve = "00:00 PM" }
    end
    item[#item + 1] = ui.box{ w = if capsule then 4 else 0, h = 1 }
    return ui.row(item)
end

function popout(ctx: Context)
    local here = moment(ctx, nil)
    if not here then
        return ui.box{ w = 0, h = 0 }
    end
    local rows = { w = WIDTH, gap = 4, pad = 8, center = false,
        ui.row{ w = WIDTH - 16, pad = 6,
            ui.text{ text = omniwm.l10n("World Clock"), style = "bold" } } }
    for _, entry in zones(ctx) do
        local there = moment(ctx, entry.zone)
        if not there then
            continue
        end
        local day = there.hour >= 6 and there.hour < 19
        rows[#rows + 1] = ui.row{ w = WIDTH - 16, gap = 10, pad = 6, radius = 10, fill = "surface",
            ui.stack{ w = 30, h = 30, radius = 15, fill = if day then "yellow/0.2" else "indigo/0.22",
                ui.symbol{ name = if day then "sun.max.fill" else "moon.fill", w = 15, h = 15,
                    color = if day then "orange" else "indigo" } },
            ui.column{ gap = 1, center = false, grow = 1,
                ui.text{ text = entry.label, weight = "semibold", maxWidth = 120 },
                ui.text{ text = relative(here, there), style = "small", color = "secondaryForeground",
                    maxWidth = 120 } },
            ui.text{ text = there.time, style = "rounded", size = 18, weight = "semibold" } }
    end
    return panel(ctx.data.bar.style, rows)
end

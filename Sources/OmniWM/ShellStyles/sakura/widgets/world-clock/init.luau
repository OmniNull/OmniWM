-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

interval = 30

local style = require("../lib/style")
local WIDTH = style.width
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

function render(ctx: Context)
    local settings = ctx.data.settings or {}
    local scale = style.scale(ctx)
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
    local item = { onClick = ui.popout,
        ui.symbol{ name = "globe", size = 14 * scale, weight = "medium" } }
    if ctx.data.bar.style.vertical then
        item.gap = scale
        item.pad = 2 * scale
        item.help = list[1].label .. " " .. list[1].moment.time
        item[#item + 1] = ui.text{ text = string.format("%02d", list[1].moment.hour), size = 10 * scale }
        return style.bar(ctx, item)
    end
    for index = 1, math.min(shown, #list) do
        local entry = list[index]
        if index > 1 then
            item[#item + 1] = ui.box{ w = 1, h = 12 * scale, fill = "border" }
        end
        item[#item + 1] = ui.text{ text = string.upper(string.sub(entry.label, 1, 3)), size = 11 * scale,
            color = "secondaryForeground" }
        item[#item + 1] = ui.text{ text = entry.moment.time, size = 13 * scale, reserve = "00:00 PM" }
    end
    return style.bar(ctx, item)
end

function popout(ctx: Context)
    local here = moment(ctx, nil)
    if not here then
        return ui.box{ w = 0, h = 0 }
    end
    local rows = { style.heading(omniwm.l10n("World Clock"), WIDTH) }
    local clocks = { w = WIDTH }
    for _, entry in zones(ctx) do
        local there = moment(ctx, entry.zone)
        if not there then
            continue
        end
        local day = there.hour >= 6 and there.hour < 19
        clocks[#clocks + 1] = ui.row{ w = WIDTH - 24, gap = 10, pad = 4,
            ui.symbol{ name = if day then "sun.max.fill" else "moon.fill", w = 22, h = 22,
                color = "secondaryForeground" },
            ui.column{ gap = 3, center = false, grow = 1,
                ui.text{ text = entry.label, size = 13, weight = "medium", maxWidth = 134 },
                ui.text{ text = relative(here, there), size = 11, color = "secondaryForeground", maxWidth = 134 } },
            ui.text{ text = there.time, size = 22, weight = "medium", maxWidth = 106 } }
    end
    rows[#rows + 1] = style.group(clocks)
    return style.panel(rows)
end

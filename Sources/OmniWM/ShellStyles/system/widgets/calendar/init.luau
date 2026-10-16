-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

interval = 60

local style = require("../lib/style")
local WIDTH = style.width
local CELL = (WIDTH - 24) / 7
local AGENDA = 6
local SOON = 12 * 3600

local function nextEvent(ctx, calendar)
    local now = ctx.data.seconds
    for _, event in calendar.events do
        if not event.allDay and event["end"] > now then
            return event
        end
    end
    return nil
end

local function countdown(ctx, event): string
    local minutes = math.ceil((event.start - ctx.data.seconds) / 60)
    if minutes <= 0 then
        return omniwm.l10n("Now")
    end
    if minutes < 60 then
        return omniwm.l10n("In %lld min", minutes)
    end
    return event.time
end

local function grid(month)
    local marked = {}
    for _, day in month.marked do
        marked[day] = true
    end
    local rows = { gap = 2, center = false }
    local header = { gap = 0 }
    for _, symbol in month.weekdays do
        header[#header + 1] = ui.stack{ w = CELL, h = 22,
            ui.text{ text = symbol, size = 11, color = "secondaryForeground" } }
    end
    rows[#rows + 1] = ui.row(header)
    local week = { gap = 0 }
    for _ = 1, month.offset do
        week[#week + 1] = ui.box{ w = CELL, h = 34 }
    end
    for day = 1, month.days do
        local today = day == month.today
        week[#week + 1] = ui.column{ w = CELL, h = 34, gap = 2, center = true,
            ui.stack{ w = 26, h = 26, radius = 13, fill = if today then "accent" else nil,
                ui.text{ text = tostring(day), size = 13, weight = if today then "semibold" else nil,
                    color = if today then "accentForeground" else "foreground" } },
            ui.box{ w = 4, h = 4, radius = 2, fill = if marked[day] then "secondaryForeground" else nil } }
        if #week == 7 then
            rows[#rows + 1] = ui.row(week)
            week = { gap = 0 }
        end
    end
    if #week > 0 then
        rows[#rows + 1] = ui.row(week)
    end
    return ui.column(rows)
end

local function agendaRow(event)
    local when = if event.allDay then omniwm.l10n("All day") else event.time
    return ui.row{ w = WIDTH - 24, gap = 8, pad = 4, radius = 6, hover = style.hover,
        onClick = "calendar open " .. event.id,
        ui.box{ w = 3, h = 34, radius = 1.5, fill = event.color },
        ui.column{ gap = 3, center = false,
            ui.text{ text = event.title, size = 13, weight = "medium", maxWidth = WIDTH - 48 },
            ui.text{ text = event.day .. " · " .. when, size = 11, color = "secondaryForeground",
                maxWidth = WIDTH - 48 } } }
end

local function action(symbol: string, text: string, command: string)
    return ui.row{ w = WIDTH, gap = 8, pad = 6, radius = 8, hover = style.hover, onClick = command,
        ui.symbol{ name = symbol, w = 16, h = 16, color = "secondaryForeground" },
        ui.text{ text = text, size = 13, maxWidth = WIDTH - 40, lines = 2 } }
end

function render(ctx)
    local calendar = ctx.data.calendar
    if not calendar then
        return ui.box{ w = 0, h = 0 }
    end
    local scale = style.scale(ctx)
    local row = { onClick = ui.popout, ui.symbol{ name = "calendar", size = 14 * scale } }
    local event = if calendar.access == "full" then nextEvent(ctx, calendar) else nil
    if ctx.data.bar.style.vertical then
        if event and event.start - ctx.data.seconds < SOON then
            row.gap = 2 * scale
            row[#row + 1] = ui.box{ w = 5 * scale, h = 5 * scale, radius = 2.5 * scale, fill = event.color }
        end
        return style.bar(ctx, row)
    end
    if event and event.start - ctx.data.seconds < SOON then
        row[#row + 1] = ui.box{ w = 5 * scale, h = 5 * scale, radius = 2.5 * scale, fill = event.color }
        row[#row + 1] = ui.text{ text = event.title, size = 13 * scale, maxWidth = 140 * scale }
        row[#row + 1] = ui.text{ text = countdown(ctx, event), size = 13 * scale, color = "secondaryForeground" }
    end
    return style.bar(ctx, row)
end

function popout(ctx)
    local calendar = ctx.data.calendar
    if not calendar or not calendar.month then
        return ui.box{ w = 0, h = 0 }
    end
    local month = calendar.month
    local rows = {
        ui.row{ w = WIDTH, gap = 4,
            ui.text{ text = month.title, size = 14, weight = "semibold", grow = 1, maxWidth = WIDTH - 104 },
            style.button("chevron.left", "calendar month previous"),
            style.button("circle.fill", "calendar month today"),
            style.button("chevron.right", "calendar month next") },
        style.group{ w = WIDTH, grid(month) } }
    if calendar.access == "full" then
        local now = ctx.data.seconds
        local agenda = { w = WIDTH }
        for _, event in calendar.events do
            if event["end"] > now then
                agenda[#agenda + 1] = agendaRow(event)
                if #agenda == AGENDA then
                    break
                end
            end
        end
        if #agenda == 0 then
            agenda[#agenda + 1] = ui.text{ text = omniwm.l10n("No upcoming events"), size = 13,
                color = "secondaryForeground", maxWidth = WIDTH - 24 }
        end
        rows[#rows + 1] = style.group(agenda)
    elseif calendar.access == "notDetermined" then
        rows[#rows + 1] = action("calendar.badge.plus", omniwm.l10n("Allow Calendar Access"), "calendar authorize")
    else
        rows[#rows + 1] = action("lock.fill", omniwm.l10n("Open Calendar Privacy Settings"), "calendar settings")
    end
    rows[#rows + 1] = action("arrow.up.forward.app", omniwm.l10n("Open Calendar"), "calendar open")
    return style.panel(rows)
end

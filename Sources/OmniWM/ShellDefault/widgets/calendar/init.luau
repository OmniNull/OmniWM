-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

interval = 60

local HOVER = "foreground/0.12"
local CELL = 28
local WIDTH = CELL * 7
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

local function button(name: string, command: string)
    return ui.box{ pad = 4, radius = 6, hover = HOVER, onClick = command, ui.symbol{ name = name, w = 12, h = 12 } }
end

local function grid(month)
    local marked = {}
    for _, day in month.marked do
        marked[day] = true
    end
    local rows = { gap = 2, center = false }
    local header = { gap = 0 }
    for _, symbol in month.weekdays do
        header[#header + 1] = ui.box{ w = CELL, h = 18, center = true,
            ui.text{ text = symbol, style = "small", color = "secondaryForeground" } }
    end
    rows[#rows + 1] = ui.row(header)
    local week = { gap = 0 }
    for _ = 1, month.offset do
        week[#week + 1] = ui.box{ w = CELL, h = CELL }
    end
    for day = 1, month.days do
        local today = day == month.today
        week[#week + 1] = ui.column{ w = CELL, h = CELL, gap = 1, center = true,
            ui.box{ w = 22, h = 20, radius = 10, center = true, fill = if today then "accent" else nil,
                ui.text{ text = tostring(day), style = if today then "bold" else "body",
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
    return ui.row{ w = WIDTH, gap = 8, pad = 4, radius = 6, hover = HOVER, onClick = "calendar open " .. event.id,
        ui.box{ w = 3, h = 30, radius = 1.5, fill = event.color },
        ui.column{ gap = 1, center = false,
            ui.text{ text = event.title, maxWidth = 170 },
            ui.text{ text = event.day .. " · " .. when, style = "small", color = "secondaryForeground",
                maxWidth = 170 } } }
end

function render(ctx)
    local calendar = ctx.data.calendar
    if not calendar then
        return ui.box{ w = 0, h = 0 }
    end
    local row = { gap = 5, pad = 2, radius = 4, hover = HOVER, onClick = ui.popout, ui.symbol{ name = "calendar" } }
    local event = if calendar.access == "full" then nextEvent(ctx, calendar) else nil
    if ctx.data.bar.style.vertical then
        if event and event.start - ctx.data.seconds < SOON then
            row.gap = 2
            row[#row + 1] = ui.box{ w = 6, h = 6, radius = 3, fill = event.color }
        end
        return ui.column(row)
    end
    if event and event.start - ctx.data.seconds < SOON then
        row[#row + 1] = ui.box{ w = 6, h = 6, radius = 3, fill = event.color }
        row[#row + 1] = ui.text{ text = event.title, maxWidth = 140 }
        row[#row + 1] = ui.text{ text = countdown(ctx, event), color = "secondaryForeground" }
    end
    return ui.row(row)
end

function popout(ctx)
    local calendar = ctx.data.calendar
    if not calendar or not calendar.month then
        return ui.box{ w = 0, h = 0 }
    end
    local month = calendar.month
    local rows = { gap = 10, pad = 12, center = false,
        ui.row{ w = WIDTH, gap = 4,
            ui.text{ text = month.title, style = "bold", grow = 1 },
            button("chevron.left", "calendar month previous"),
            button("circle.fill", "calendar month today"),
            button("chevron.right", "calendar month next") },
        grid(month) }
    if calendar.access == "full" then
        local now = ctx.data.seconds
        local shown = 0
        for _, event in calendar.events do
            if event["end"] > now then
                rows[#rows + 1] = agendaRow(event)
                shown += 1
                if shown == AGENDA then
                    break
                end
            end
        end
        if shown == 0 then
            rows[#rows + 1] = ui.text{ text = omniwm.l10n("No upcoming events"), color = "secondaryForeground" }
        end
    elseif calendar.access == "notDetermined" then
        rows[#rows + 1] = ui.row{ w = WIDTH, gap = 6, pad = 5, radius = 6, hover = HOVER, onClick = "calendar authorize",
            ui.symbol{ name = "calendar.badge.plus", w = 14, h = 14 },
            ui.text{ text = omniwm.l10n("Allow Calendar Access") } }
    else
        rows[#rows + 1] = ui.row{ w = WIDTH, gap = 6, pad = 5, radius = 6, hover = HOVER, onClick = "calendar settings",
            ui.symbol{ name = "lock.fill", w = 14, h = 14 },
            ui.text{ text = omniwm.l10n("Open Calendar Privacy Settings"), maxWidth = 200, lines = 2 } }
    end
    rows[#rows + 1] = ui.row{ w = WIDTH, gap = 6, pad = 5, radius = 6, hover = HOVER, onClick = "calendar open",
        ui.symbol{ name = "arrow.up.forward.app", w = 14, h = 14 },
        ui.text{ text = omniwm.l10n("Open Calendar") } }
    return ui.column(rows)
end

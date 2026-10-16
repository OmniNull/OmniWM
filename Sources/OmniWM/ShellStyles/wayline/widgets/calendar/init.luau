-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

interval = 60

local HUE = "accent"
local HOVER = "foreground/0.07"
local CELL = 38
local GRID = CELL * 7
local WIDTH = GRID + 16 + 32
local INNER = WIDTH - 32
local CARD = INNER - 20
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

local function block(size: number, radius: number, vertical: boolean, alone: boolean)
    local node = { w = size, h = size, ui.box{ w = size, h = size, radius = radius, fill = HUE } }
    if not alone then
        node[#node + 1] = ui.box{ align = vertical and "bottom" or "trailing", w = vertical and size or radius,
            h = vertical and radius or size, fill = HUE }
    end
    node[#node + 1] = ui.symbol{ name = "calendar", size = math.floor(size * 0.52), weight = "semibold",
        color = "accentForeground" }
    return ui.stack(node)
end

local function button(name: string, command: string)
    return ui.stack{ w = 26, h = 26, radius = 7, hover = HOVER, onClick = command,
        ui.symbol{ name = name, size = 11, weight = "bold", color = "secondaryForeground" } }
end

local function grid(month)
    local marked = {}
    for _, day in month.marked do
        marked[day] = true
    end
    local rows = { w = GRID + 16, gap = 0, pad = 8, radius = 9, fill = "elevatedSurface", center = false }
    local header = { gap = 0 }
    for _, symbol in month.weekdays do
        header[#header + 1] = ui.stack{ w = CELL, h = 22,
            ui.text{ text = symbol, size = 12, weight = "bold", color = "mutedForeground" } }
    end
    rows[#rows + 1] = ui.row(header)
    local week = { gap = 0 }
    for _ = 1, month.offset do
        week[#week + 1] = ui.box{ w = CELL, h = CELL }
    end
    for day = 1, month.days do
        local today = day == month.today
        week[#week + 1] = ui.stack{ w = CELL, h = CELL,
            ui.stack{ w = 28, h = 28, radius = 7, fill = if today then HUE else nil,
                ui.text{ text = tostring(day), style = "mono", size = 14, weight = if today then "bold" else "semibold",
                    color = if today then "accentForeground" else "secondaryForeground" } },
            if marked[day]
                then ui.box{ align = "bottom", dy = -3, w = 4, h = 4, radius = 2,
                    fill = if today then "accentForeground" else HUE }
                else nil }
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
    return ui.row{ w = CARD, gap = 10, pad = 0, radius = 7, hover = HOVER, onClick = "calendar open " .. event.id,
        ui.box{ w = 1, h = 44 },
        ui.box{ w = 3, h = 28, radius = 1.5, fill = event.color },
        ui.column{ gap = 2, center = false,
            ui.text{ text = event.title, size = 14, weight = "semibold", color = "foreground", maxWidth = CARD - 24 },
            ui.text{ text = event.day .. " · " .. when, size = 12, weight = "medium", color = "mutedForeground",
                maxWidth = CARD - 24 } } }
end

local function card(rows)
    local column = { w = INNER, gap = 0, pad = 0, radius = 9, fill = "elevatedSurface", center = true }
    for index, row in rows do
        if index > 1 then
            column[#column + 1] = ui.box{ w = CARD, h = 1, fill = "foreground/0.07" }
        end
        column[#column + 1] = row
    end
    return ui.column(column)
end

local function action(symbol: string, text: string, command: string, color: string)
    return ui.row{ w = CARD, h = 40, gap = 10, radius = 7, hover = HOVER, onClick = command,
        ui.stack{ w = 24, h = 24, radius = 6, fill = color .. "/0.16",
            ui.symbol{ name = symbol, size = 11, weight = "semibold", color = color } },
        ui.text{ text = text, size = 14, weight = "semibold", color = "foreground", maxWidth = CARD - 40, lines = 2 } }
end

function render(ctx)
    local calendar = ctx.data.calendar
    if not calendar then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local radius = math.floor(size * 0.24)
    local event = if calendar.access == "full" then nextEvent(ctx, calendar) else nil
    local soon = event ~= nil and event.start - ctx.data.seconds < SOON
    local row = { gap = 0, radius = radius, fill = "elevatedSurface", hoverOpacity = 0.9, onClick = ui.popout,
        block(size, radius, style.vertical, not soon) }
    if style.vertical then
        row.w = size
        if soon then
            row.gap = 3
            row[#row + 1] = ui.box{ w = 6, h = 6, radius = 3, fill = event.color }
            row[#row + 1] = ui.box{ w = 1, h = 2 }
        end
        return ui.column(row)
    end
    row.h = size
    if soon then
        row[#row + 1] = ui.box{ w = 8, h = 1 }
        row[#row + 1] = ui.box{ w = 6, h = 6, radius = 3, fill = event.color }
        row[#row + 1] = ui.box{ w = 6, h = 1 }
        row[#row + 1] = ui.text{ text = event.title, size = 14 * scale, weight = "semibold", color = HUE, maxWidth = 130 }
        row[#row + 1] = ui.box{ w = 6, h = 1 }
        row[#row + 1] = ui.text{ text = countdown(ctx, event), size = 12 * scale, weight = "medium",
            color = "secondaryForeground" }
        row[#row + 1] = ui.box{ w = 9, h = 1 }
    end
    return ui.row(row)
end

function popout(ctx)
    local calendar = ctx.data.calendar
    if not calendar or not calendar.month then
        return ui.box{ w = 0, h = 0 }
    end
    local month = calendar.month
    local frame = { w = WIDTH, gap = 0, material = "clear", radius = 12, fill = "surface", border = "border",
        borderWidth = 1, center = false,
        ui.stack{ w = WIDTH, h = 44,
            ui.box{ w = WIDTH, h = 44, radius = 12, fill = "elevatedSurface" },
            ui.box{ align = "bottom", w = WIDTH, h = 12, fill = "elevatedSurface" },
            ui.row{ w = INNER, gap = 2,
                ui.symbol{ name = "calendar", size = 13, weight = "semibold", color = "accent" },
                ui.box{ w = 6, h = 1 },
                ui.text{ text = month.title, size = 14, weight = "bold", color = "foreground", grow = 1 },
                button("chevron.left", "calendar month previous"),
                button("circle.fill", "calendar month today"),
                button("chevron.right", "calendar month next") } },
        ui.box{ w = WIDTH, h = 1, fill = "border" } }
    local body = { w = WIDTH, pad = 16, gap = 10, center = false, grid(month) }
    if calendar.access == "full" then
        local now = ctx.data.seconds
        local rows = {}
        for _, event in calendar.events do
            if event["end"] > now then
                rows[#rows + 1] = agendaRow(event)
                if #rows == AGENDA then
                    break
                end
            end
        end
        if #rows == 0 then
            rows[1] = ui.row{ w = CARD, h = 40,
                ui.text{ text = omniwm.l10n("No upcoming events"), size = 14, weight = "medium",
                    color = "mutedForeground" } }
        end
        rows[#rows + 1] = action("arrow.up.forward.app", omniwm.l10n("Open Calendar"), "calendar open", "accent")
        body[#body + 1] = card(rows)
    elseif calendar.access == "notDetermined" then
        body[#body + 1] = card({
            action("calendar.badge.plus", omniwm.l10n("Allow Calendar Access"), "calendar authorize", "accent"),
            action("arrow.up.forward.app", omniwm.l10n("Open Calendar"), "calendar open", "accent") })
    else
        body[#body + 1] = card({
            action("lock.fill", omniwm.l10n("Open Calendar Privacy Settings"), "calendar settings", "warning"),
            action("arrow.up.forward.app", omniwm.l10n("Open Calendar"), "calendar open", "accent") })
    end
    frame[#frame + 1] = ui.column(body)
    return ui.column(frame)
end

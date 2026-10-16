-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local panel = require("../lib/panel")

interval = 60

local HOVER = "focus/0.14"
local WIDTH = 320
local INNER = WIDTH - 2 - 24
local CARD = INNER - 20
local CELL = math.floor(CARD / 7)
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

local function tag(text: string, scale: number?)
    scale = scale or 1
    return ui.row{ h = 18 * scale, radius = 9 * scale, fill = "blue/0.2",
        ui.box{ w = 7 * scale, h = 1 },
        ui.text{ text = text, size = 12 * scale, weight = "semibold", color = "blue" },
        ui.box{ w = 7 * scale, h = 1 } }
end

local function button(name: string, command: string)
    return ui.stack{ w = 26, h = 26, radius = 13, hover = HOVER, onClick = command,
        ui.symbol{ name = name, size = 11, weight = "bold", color = "secondaryForeground" } }
end

local function card(props)
    props.w = INNER
    props.pad = 10
    props.radius = 14
    props.fill = "surface"
    props.border = "border"
    props.borderWidth = 1
    props.center = false
    return ui.column(props)
end

local function grid(month)
    local marked = {}
    for _, day in month.marked do
        marked[day] = true
    end
    local rows = { gap = 0, center = false }
    local header = { gap = 0 }
    for _, symbol in month.weekdays do
        header[#header + 1] = ui.box{ w = CELL, h = 20,
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
            ui.stack{ w = CELL - 5, h = CELL - 5, radius = (CELL - 5) / 2, fill = if today then "accent" else nil,
                ui.text{ text = tostring(day), size = 14, weight = if today then "bold" else "medium",
                    color = if today then "accentForeground" else "foreground" } },
            if marked[day] then ui.box{ align = "bottom", dy = -2, w = 4, h = 4, radius = 2,
                fill = if today then "accentForeground" else "blue" } else nil }
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

local function agendaRow(ctx, event)
    local when = if event.allDay then omniwm.l10n("All day") else event.time
    local minutes = (event.start - ctx.data.seconds) / 60
    local row = { w = CARD, gap = 9, pad = 4, radius = 10, hover = HOVER, onClick = "calendar open " .. event.id,
        ui.box{ w = 4, h = 30, radius = 2, fill = event.color },
        ui.column{ gap = 2, center = false,
            ui.text{ text = event.title, size = 14, weight = "semibold", maxWidth = CARD - 96 },
            ui.text{ text = event.day .. " · " .. when, size = 12, color = "secondaryForeground",
                maxWidth = CARD - 96 } },
        ui.box{ grow = 1, h = 1 } }
    if not event.allDay and minutes < 60 then
        row[#row + 1] = tag(countdown(ctx, event))
    end
    return ui.row(row)
end

local function action(symbol: string, text: string, command: string)
    return ui.row{ w = INNER, gap = 8, pad = 6, radius = 10, hover = HOVER, onClick = command,
        ui.stack{ w = 24, h = 24, radius = 12, fill = "elevatedSurface",
            ui.symbol{ name = symbol, size = 11, weight = "semibold", color = "secondaryForeground" } },
        ui.text{ text = text, size = 14, weight = "medium", maxWidth = INNER - 50, lines = 2 } }
end

function render(ctx)
    local calendar = ctx.data.calendar
    if not calendar then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local event = if calendar.access == "full" then nextEvent(ctx, calendar) else nil
    if event and event.start - ctx.data.seconds >= SOON then
        event = nil
    end
    local glyph = ui.symbol{ name = "calendar", w = 20 * scale, h = 20 * scale, size = 18 * scale,
        weight = "semibold", color = "foreground" }
    local node = { gap = 6, radius = size / 2 - 1, fill = style.backgrounds and "surface" or nil,
        border = style.backgrounds and "border/0.6" or nil, borderWidth = 1, hover = HOVER, onClick = ui.popout,
        help = event and event.title or nil }
    if style.vertical then
        node.w = size
        node.gap = 3
        node[1] = ui.box{ w = 1, h = 5 }
        node[2] = glyph
        if event then
            node[3] = ui.box{ w = 6, h = 6, radius = 3, fill = event.color }
        end
        node[#node + 1] = ui.box{ w = 1, h = 5 }
        return ui.column(node)
    end
    node.h = size
    if not event then
        node.w = size
        node[1] = glyph
        return ui.stack(node)
    end
    node[1] = ui.box{ w = 2, h = 1 }
    node[2] = glyph
    node[3] = ui.box{ w = 3, h = 14, radius = 1.5, fill = event.color }
    node[4] = tag(countdown(ctx, event), scale)
    node[5] = ui.box{ w = 0, h = 1 }
    return ui.row(node)
end

function popout(ctx)
    local calendar = ctx.data.calendar
    if not calendar or not calendar.month then
        return ui.box{ w = 0, h = 0 }
    end
    local month = calendar.month
    local rows = { w = WIDTH - 2, pad = 12, gap = 8, center = false,
        ui.row{ w = INNER, gap = 2,
            ui.box{ w = 2, h = 1 },
            ui.text{ text = month.title, size = 15, weight = "bold", grow = 1 },
            button("chevron.left", "calendar month previous"),
            button("smallcircle.filled.circle", "calendar month today"),
            button("chevron.right", "calendar month next") },
        card{ grid(month) } }
    if calendar.access == "full" then
        local now = ctx.data.seconds
        local agenda = { gap = 2 }
        for _, event in calendar.events do
            if event["end"] > now then
                agenda[#agenda + 1] = agendaRow(ctx, event)
                if #agenda == AGENDA then
                    break
                end
            end
        end
        if #agenda == 0 then
            agenda[1] = ui.text{ text = omniwm.l10n("No upcoming events"), size = 14, color = "secondaryForeground" }
        end
        rows[#rows + 1] = card(agenda)
    elseif calendar.access == "notDetermined" then
        rows[#rows + 1] = action("calendar.badge.plus", omniwm.l10n("Allow Calendar Access"), "calendar authorize")
    else
        rows[#rows + 1] = action("lock.fill", omniwm.l10n("Open Calendar Privacy Settings"), "calendar settings")
    end
    rows[#rows + 1] = action("arrow.up.forward.app", omniwm.l10n("Open Calendar"), "calendar open")
    return panel(ctx.data.bar.style, WIDTH, ui.column(rows))
end

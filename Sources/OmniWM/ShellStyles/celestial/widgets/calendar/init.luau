-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

interval = 60

local dash = require("../lib/dash")
local status = require("../lib/status")
local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

local AGENDA = 6
local SOON = 12 * 3600
local WIDTH = dash.calendarWidth

local function nextEvent(ctx: Context, calendar: Calendar)
    for _, event in calendar.events do
        if not event.allDay and event["end"] > ctx.data.seconds then
            return event
        end
    end
    return nil
end

local function countdown(ctx: Context, event): string
    local minutes = math.ceil((event.start - ctx.data.seconds) / 60)
    if minutes <= 0 then
        return omniwm.l10n("Now")
    end
    if minutes < 60 then
        return omniwm.l10n("In %lld min", minutes)
    end
    return event.time
end

function render(ctx: Context)
    local calendar = ctx.data.calendar
    if not calendar then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local vertical = style.vertical
    local scale = style.height / 60
    local items = { surface.icon("calendar_month", { size = tokens.icon.medium * scale, color = "secondaryAccent" }) }
    local event = if calendar.access == "full" then nextEvent(ctx, calendar) else nil
    if event and event.start - ctx.data.seconds < SOON then
        items[#items + 1] = ui.box{ w = 6, h = 6, radius = 3, fill = event.color }
        if not vertical then
            items[#items + 1] = ui.text{ text = event.title, font = "sans", size = tokens.label.large * scale,
                weight = "medium", maxWidth = 130 }
            items[#items + 1] = ui.text{ text = countdown(ctx, event), font = "sans", size = tokens.label.medium * scale,
                weight = "semibold", color = "accent" }
        end
    end
    return surface.pill(style, items, { hover = status.hover, onClick = ui.popout })
end

local function agendaRow(event, first: boolean)
    local when = if event.allDay then omniwm.l10n("All day") else event.time
    return ui.row{ key = event.id, w = WIDTH, gap = tokens.spacing.medium, pad = tokens.padding.small,
        radius = tokens.rounding.large, hover = status.hover, onClick = "calendar open " .. event.id,
        fill = if first then "secondaryContainer" else nil,
        ui.box{ w = 4, h = 30, radius = 2, fill = event.color },
        ui.column{ gap = 2, center = false,
            ui.text{ text = event.title, font = "sans", size = tokens.body.small, weight = "medium",
                maxWidth = WIDTH - 40 },
            ui.text{ text = event.day .. " · " .. when, font = "sans", size = tokens.label.medium,
                color = "secondaryForeground", maxWidth = WIDTH - 40 } } }
end

local function button(text: string, command: string)
    return ui.row{ w = WIDTH, h = 40, radius = 20, fill = "secondaryContainer",
        hover = "secondaryContainerForeground/0.08", onClick = command,
        ui.box{ grow = 1, h = 1 },
        ui.text{ text = text, font = "sans", size = tokens.label.large, weight = "medium",
            color = "secondaryContainerForeground", maxWidth = WIDTH - 32 },
        ui.box{ grow = 1, h = 1 } }
end

function popout(ctx: Context)
    local calendar = ctx.data.calendar
    if not calendar then
        return ui.box{ w = 0, h = 0 }
    end
    local rows = { dash.calendar(ctx) }
    if calendar.access == "full" then
        for _, event in calendar.events do
            if event["end"] > ctx.data.seconds then
                rows[#rows + 1] = agendaRow(event, #rows == 1)
                if #rows > AGENDA then
                    break
                end
            end
        end
        if #rows == 1 then
            rows[2] = ui.text{ text = omniwm.l10n("No upcoming events"), font = "sans", size = tokens.body.small,
                color = "secondaryForeground" }
        end
    elseif calendar.access == "notDetermined" then
        rows[#rows + 1] = button(omniwm.l10n("Allow Calendar Access"), "calendar authorize")
    else
        rows[#rows + 1] = button(omniwm.l10n("Open Calendar Privacy Settings"), "calendar settings")
    end
    rows[#rows + 1] = button(omniwm.l10n("Open Calendar"), "calendar open")
    return status.panel(WIDTH + 2 * tokens.padding.large, rows)
end

-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

local TINT = "tertiaryAccent"

local function digits(text: string, size: number)
    return ui.text{ text = text, font = "sans", size = size, weight = "medium", color = TINT }
end

function render(ctx: Context)
    local data = ctx.data
    local style = data.bar.style
    local scale = style.height / 60
    local settings = data.settings or {}
    local size = tokens.body.small * 1.1 * scale
    local hour, minute = string.match(data.clock, "(%d+)%D+(%d+)")
    local meridiem = string.match(data.clock, "(%a+)%s*$")
    local icon = settings.icon ~= false and surface.icon("calendar_month", { size = tokens.icon.small * scale, color = TINT })
        or nil
    if style.vertical then
        local column = { w = tokens.bar.inner * scale, gap = tokens.spacing.extraSmall * scale, pad = tokens.padding.extraSmall * scale,
            onClick = "shell toggle dashboard" }
        column[#column + 1] = icon
        if settings.date == true then
            column[#column + 1] = ui.text{ text = string.match(data.date, "^(%a+)") or data.date, font = "sans",
                size = tokens.body.small * 0.9 * scale, color = TINT }
        end
        column[#column + 1] = ui.column{ gap = 0, digits(hour and string.format("%02d", tonumber(hour) or 0) or data.clock, size), digits(minute or "", size),
            meridiem and ui.text{ text = string.lower(meridiem), font = "sans", size = tokens.body.small * 0.9 * scale,
                color = TINT } or nil }
        return ui.column(column)
    end
    local row = { h = tokens.bar.inner * scale, gap = tokens.spacing.small * scale, pad = tokens.padding.small * scale,
        onClick = "shell toggle dashboard" }
    row[#row + 1] = icon
    if settings.date == true then
        row[#row + 1] = ui.text{ text = data.date, font = "sans", size = size, color = TINT }
    end
    row[#row + 1] = ui.text{ text = data.clock, font = "sans", size = size, weight = "medium", color = TINT,
        reserve = "00:00 PM" }
    return ui.row(row)
end

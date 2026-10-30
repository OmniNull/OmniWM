-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

local ACTIONS = {
    { command = "session lock", icon = "lock", label = function() return omniwm.l10n("Lock") end },
    { command = "session sleep", icon = "bedtime", label = function() return omniwm.l10n("Sleep") end },
    { command = "session logout", icon = "logout", label = function() return omniwm.l10n("Log Out…") end },
    { command = "session restart", icon = "restart_alt", label = function() return omniwm.l10n("Restart…") end },
    { command = "session shutdown", icon = "power_settings_new", label = function() return omniwm.l10n("Shut Down…") end },
}

function render(ctx: Context)
    local scale = ctx.data.bar.style.height / 60
    local size = (tokens.icon.small + tokens.padding.small * 2) * scale
    return ui.stack{ w = size, h = size, radius = size / 2, hover = "error/0.12", popout = true,
        help = omniwm.l10n("Shut Down…"),
        surface.icon("power_settings_new", { size = tokens.icon.small * scale, color = "error", weight = "bold" }) }
end

function popout(ctx: Context)
    local column = { pad = tokens.padding.large, gap = tokens.spacing.large, radius = tokens.rounding.extraLarge,
        fill = "background", shadow = "shadow/0.35", shadowRadius = 10 }
    for index, action in ACTIONS do
        local primary = action.command == "session shutdown"
        column[#column + 1] = ui.stack{ key = action.command, w = 80, h = 80, radius = tokens.rounding.extraLarge,
            fill = primary and "accent" or "secondaryContainer",
            hover = (primary and "accentForeground" or "secondaryContainerForeground") .. "/0.1",
            onClick = action.command, help = action.label(),
            enter = { opacity = 0, scale = 0.8, from = (index - 1) * 0.08, to = 0.6 + (index - 1) * 0.08,
                curve = "fastSpatial" },
            surface.icon(action.icon, { size = tokens.icon.large,
                color = primary and "accentForeground" or "secondaryContainerForeground", filled = true }) }
    end
    return ui.column{ material = "clear", pad = tokens.padding.small, ui.column(column) }
end

-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local system = require("../lib/style")
local WIDTH = 292

local function badge(text: string, selected: boolean)
    return ui.stack{ w = 30, h = 22, radius = 5, fill = "foreground/0.08",
        ui.text{ text = text, size = 11, weight = "medium", color = selected and "accent" or "secondaryForeground",
            maxWidth = 28 } }
end

function render(ctx: Context)
    local source = ctx.data.inputSource
    if not source then
        return ui.box{ w = 0, h = 0 }
    end
    local scale = system.scale(ctx)
    return system.bar(ctx, { pad = 2 * scale, onClick = ui.popout, help = source.name,
        ui.stack{ w = 23 * scale, h = 18 * scale, radius = 4 * scale, fill = "foreground/0.09",
            ui.text{ text = source.short, size = 11 * scale, weight = "medium", maxWidth = 22 * scale } } })
end

function popout(ctx: Context)
    local source = ctx.data.inputSource
    if not source then
        return ui.box{ w = 0, h = 0 }
    end
    local rows = { gap = 3 }
    for _, entry in source.sources do
        local selected = entry.id == source.id
        rows[#rows + 1] = ui.row{ w = WIDTH - 24, gap = 10, pad = 3, radius = 7, hover = system.hover,
            onClick = "input-source select " .. entry.id,
            badge(entry.short, selected),
            ui.text{ text = entry.name, size = 13, grow = 1, maxWidth = WIDTH - 98,
                weight = selected and "medium" or nil },
            ui.symbol{ name = "checkmark", w = 12, h = 12, color = "accent", opacity = selected and 1 or 0 } }
    end
    return system.panel{ system.heading(omniwm.l10n("Input Sources"), WIDTH),
        system.group(rows),
        ui.row{ w = WIDTH, gap = 10, pad = 6, radius = 7, hover = system.hover, onClick = "input-source settings",
            ui.symbol{ name = "keyboard", size = 14, color = "secondaryForeground" },
            ui.text{ text = omniwm.l10n("Keyboard Settings…"), size = 13, grow = 1 },
            ui.symbol{ name = "chevron.right", size = 10, color = "secondaryForeground" } } }
end

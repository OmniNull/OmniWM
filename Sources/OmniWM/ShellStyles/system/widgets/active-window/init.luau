-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local system = require("../lib/style")

function render(ctx: Context)
    local data = ctx.data
    if data.app == "" then
        return ui.box{ w = 0, h = 0 }
    end
    local settings = data.settings or {}
    local display = settings.display or "icon_and_text"
    local scale = system.scale(ctx)
    local text = display ~= "icon_only" and not data.bar.style.vertical
    local item = { onClick = "open-command-palette windows",
        help = if data.title ~= "" then data.app .. " — " .. data.title else data.app }
    if display ~= "text_only" or not text then
        item[#item + 1] = ui.icon{ app = data.bundle, w = 18 * scale, h = 18 * scale, placeholder = "app.dashed" }
    end
    if text then
        item[#item + 1] = ui.text{ text = if data.title ~= "" then data.title else data.app,
            size = 13 * scale, weight = "medium", maxWidth = tonumber(settings.maxWidth) or 260 }
    end
    return system.bar(ctx, item)
end

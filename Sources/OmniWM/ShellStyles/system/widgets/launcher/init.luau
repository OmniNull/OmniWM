-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local system = require("../lib/style")

function render(ctx: Context)
    local settings = ctx.data.settings or {}
    return system.bar(ctx, {
        onClick = if settings.mode then "open-command-palette " .. settings.mode else "open-command-palette",
        help = omniwm.l10n("Toggle Command Palette"),
        ui.symbol{ name = settings.symbol or "magnifyingglass", size = 14 * system.scale(ctx), weight = "medium" } })
end

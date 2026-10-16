-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

function render(ctx: Context)
    local style = ctx.data.bar.style
    local settings = ctx.data.settings or {}
    local item = math.max(16, style.height - 4)
    local capsule = style.transparent and style.backgrounds
    return ui.stack{ w = item, h = item, radius = if capsule then item / 2 else 6,
        fill = if capsule then "surface" else nil, border = if capsule then "border" else nil, borderWidth = 0.5,
        hover = "foreground/0.12",
        onClick = if settings.mode then "open-command-palette " .. settings.mode else "open-command-palette",
        help = omniwm.l10n("Toggle Command Palette"),
        ui.symbol{ name = settings.symbol or "magnifyingglass", size = math.max(11, item * 0.42), weight = "semibold",
            color = if capsule then "accent" else "foreground" } }
end

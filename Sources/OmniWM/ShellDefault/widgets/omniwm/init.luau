-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

function render(ctx: Context)
    local style = ctx.data.bar.style
    local item = math.max(16, style.height - 4)
    local capsule = style.transparent and style.backgrounds
    local icon = math.max(12, item - (if capsule then 8 else 6))
    local locked = style.secureInput
    return ui.stack{ w = item, h = item, onClick = "shell menu", onRightClick = "shell menu",
        radius = if capsule then item / 2 else nil, fill = if capsule then "surface" else nil,
        border = if capsule then "border" else nil, borderWidth = 0.5, hover = if capsule then "foreground/0.12" else nil,
        help = locked and omniwm.l10n("Secure Input is on: Option shortcuts are paused")
            or omniwm.l10n("Window manager controls"),
        ui.symbol{ name = locked and "omniwm.lock" or "omniwm", size = icon, w = icon, h = icon,
            color = if capsule then "accent" else "foreground" } }
end

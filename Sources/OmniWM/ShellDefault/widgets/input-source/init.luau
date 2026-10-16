-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local HOVER = "foreground/0.12"
local WIDTH = 248

local function inputSource(ctx: Context)
    return ctx.data.inputSource
end

local function panel(style: BarStyle, props)
    if style.transparent and style.backgrounds then
        props.material = "clear"
        props.fill = "background"
        props.border = "border"
        props.borderWidth = 1
        props.radius = 14
    end
    return ui.column(props)
end

local function badge(text: string, selected: boolean, size: number)
    return ui.stack{ w = size * 1.5, h = size, radius = size * 0.28,
        fill = if selected then "accent" else "foreground/0.08",
        ui.text{ text = text, size = size * 0.5, weight = "bold",
            color = if selected then "accentForeground" else "secondaryForeground", maxWidth = size * 1.4 } }
end

function render(ctx: Context)
    local source = inputSource(ctx)
    if not source then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local size = math.max(16, style.height - 4)
    local capsule = style.transparent and style.backgrounds
    local label = ui.text{ text = source.short, size = 11, weight = "bold", reserve = "ABC",
        color = if capsule then "accent" else "foreground" }
    if not capsule then
        return ui.stack{ pad = 2, radius = 4, hover = HOVER, onClick = ui.popout, help = source.name,
            ui.stack{ h = 16, radius = 4, border = "foreground/0.55", borderWidth = 1,
                ui.row{ ui.box{ w = 4, h = 1 }, label, ui.box{ w = 4, h = 1 } } } }
    end
    return ui.stack{ h = if style.vertical then nil else size, w = if style.vertical then size else nil,
        radius = size / 2, fill = "surface", border = "border", borderWidth = 0.5, hover = HOVER,
        onClick = ui.popout, help = source.name,
        ui.row{ ui.box{ w = 10, h = 1 }, label, ui.box{ w = 10, h = 1 } } }
end

function popout(ctx: Context)
    local source = inputSource(ctx)
    if not source then
        return ui.box{ w = 0, h = 0 }
    end
    local rows = { w = WIDTH, gap = 2, pad = 8, center = false,
        ui.row{ w = WIDTH - 16, pad = 6,
            ui.text{ text = omniwm.l10n("Input Sources"), style = "bold" } } }
    for _, entry in source.sources do
        local selected = entry.id == source.id
        rows[#rows + 1] = ui.row{ w = WIDTH - 16, gap = 10, pad = 6, radius = 8, hover = HOVER,
            fill = if selected then "accent/0.12" else nil,
            onClick = "input-source select " .. entry.id,
            badge(entry.short, selected, 20),
            ui.text{ text = entry.name, grow = 1, maxWidth = 150, weight = if selected then "semibold" else nil },
            ui.symbol{ name = "checkmark", w = 12, h = 12, color = "accent", opacity = if selected then 1 else 0 } }
    end
    rows[#rows + 1] = ui.box{ w = WIDTH - 28, h = 1, fill = "border" }
    rows[#rows + 1] = ui.row{ w = WIDTH - 16, gap = 10, pad = 6, radius = 8, hover = HOVER,
        onClick = "input-source settings",
        ui.stack{ w = 30, h = 20, ui.symbol{ name = "keyboard", w = 16, h = 16, color = "secondaryForeground" } },
        ui.text{ text = omniwm.l10n("Keyboard Settings…") } }
    return panel(ctx.data.bar.style, rows)
end

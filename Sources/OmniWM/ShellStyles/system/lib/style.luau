-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = {}

style.hover = "foreground/0.08"
style.width = 320

function style.batterySymbol(level: number, charging: boolean?): string
    if charging then
        return "battery.100percent.bolt"
    end
    if level > 85 then
        return "battery.100percent"
    end
    if level > 60 then
        return "battery.75percent"
    end
    if level > 35 then
        return "battery.50percent"
    end
    if level > 10 then
        return "battery.25percent"
    end
    return "battery.0percent"
end

function style.scale(ctx): number
    return ctx.data.bar.style.height / 32
end

function style.bar(ctx, props)
    local bar = ctx.data.bar.style
    local scale = style.scale(ctx)
    props.gap = props.gap or 5 * scale
    props.pad = props.pad or 4 * scale
    props.radius = 6 * scale
    if props.onClick or props.onRightClick then
        props.hover = props.hover or style.hover
    end
    if bar.backgrounds then
        props.fill = props.fill or "foreground/0.06"
    end
    if bar.vertical then
        props.w = props.w or bar.height - 4
        return ui.column(props)
    end
    props.h = props.h or bar.height - 4
    return ui.row(props)
end

function style.panel(props)
    props.pad = props.pad or 14
    props.gap = props.gap or 12
    props.radius = 20
    props.material = "glass"
    props.center = false
    return ui.column(props)
end

function style.group(props)
    props.pad = props.pad or 12
    props.gap = props.gap or 8
    props.radius = 12
    props.fill = "surface"
    props.center = false
    return ui.column(props)
end

function style.heading(text: string, width: number?)
    return ui.row{ w = width, ui.text{ text = text, size = 14, weight = "semibold" } }
end

function style.button(name: string, action, props)
    props = props or {}
    props.w = props.w or 28
    props.h = props.h or 28
    props.radius = props.radius or 7
    props.hover = style.hover
    props.onClick = action
    props[#props + 1] = ui.symbol{ name = name, size = 14, weight = "medium" }
    return ui.stack(props)
end

return style

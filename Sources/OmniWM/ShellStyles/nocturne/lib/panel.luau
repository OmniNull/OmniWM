-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local SHOULDER = 14
local CORNER = 18

local function shoulder(right: boolean, flip: boolean)
    local s = SHOULDER
    local r = s + 0.5
    local fill, stroke
    if flip then
        fill = right and string.format("M0 %g L0 0 A%g %g 0 0 0 %g %g Z", s, s, s, s, s)
            or string.format("M%g %g L%g 0 A%g %g 0 0 1 0 %g Z", s, s, s, s, s, s)
        stroke = right and string.format("M-0.5 0 A%g %g 0 0 0 %g %g", r, r, s, r)
            or string.format("M%g 0 A%g %g 0 0 1 0 %g", r, r, r, r)
    else
        fill = right and string.format("M0 0 L%g 0 A%g %g 0 0 0 0 %g Z", s, s, s, s)
            or string.format("M0 0 L%g 0 L%g %g A%g %g 0 0 0 0 0 Z", s, s, s, s, s)
        stroke = right and string.format("M%g -0.5 A%g %g 0 0 0 -0.5 %g", s, r, r, s)
            or string.format("M%g %g A%g %g 0 0 0 0 -0.5", r, s, r, r)
    end
    return ui.stack{ align = right and "trailing" or "leading", w = s, h = s,
        ui.path{ w = s, h = s, d = fill, fill = "background" },
        ui.path{ w = s, h = s, d = stroke, border = "border", borderWidth = 1 } }
end

local function panel(style: BarStyle, width: number, content)
    local attached = not style.vertical
    local flip = style.position == "bottom"
    local edge = flip and "bottom" or "top"
    local inner = { w = width - 2, radius = CORNER - 1, fill = "background" }
    local outer = { w = width, radius = CORNER, fill = "border" }
    if attached then
        inner[1] = ui.box{ align = edge, w = width - 2, h = CORNER, fill = "background" }
        outer[1] = ui.box{ align = edge, w = width, h = CORNER, fill = "border" }
    end
    inner[#inner + 1] = content
    local framed = { gap = 0, ui.row{ gap = 0, ui.box{ w = 1, h = 1 }, ui.stack(inner), ui.box{ w = 1, h = 1 } } }
    if not attached or flip then
        table.insert(framed, 1, ui.box{ w = width, h = 1 })
    end
    if not attached or not flip then
        framed[#framed + 1] = ui.box{ w = width, h = 1 }
    end
    outer[#outer + 1] = ui.column(framed)
    if not attached then
        return ui.stack{ material = "clear", ui.stack(outer) }
    end
    local body = ui.row{ gap = 0, ui.box{ w = SHOULDER, h = 1 }, ui.stack(outer), ui.box{ w = SHOULDER, h = 1 } }
    local shoulders = ui.stack{ w = width + SHOULDER * 2, h = SHOULDER,
        ui.box{ w = width, h = SHOULDER, fill = "background" }, shoulder(false, flip), shoulder(true, flip) }
    return ui.column{ material = "clear", attach = true, gap = 0,
        flip and body or shoulders, flip and shoulders or body }
end

return panel

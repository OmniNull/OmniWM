-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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

local function square(width, flip, fill)
    return ui.box{ align = flip and "bottom" or "top", w = width, h = CORNER, fill = fill }
end

local function edge(width, flip, squared)
    local props = { w = width + SHOULDER * 2, h = SHOULDER }
    if squared then
        props[#props + 1] = square(width, flip, "border")
        props[#props + 1] = square(width - 2, flip, "background")
    end
    props[#props + 1] = ui.box{ w = width, h = SHOULDER, fill = "background" }
    props[#props + 1] = shoulder(false, flip)
    props[#props + 1] = shoulder(true, flip)
    return ui.stack(props)
end

return table.freeze({ shoulder = SHOULDER, corner = CORNER, square = square, edge = edge })

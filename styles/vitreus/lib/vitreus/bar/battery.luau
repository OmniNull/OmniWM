-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("../kit")
local palette = require("../palette")

local share = 0.28
local cycle = 5
local crossing = 0.6
local slices = 14

local function none()
    return nil
end

local function hovered(ctx): boolean
    local marks = ctx.state.marks
    return ctx.state.barHovered == true or ctx.state.barHot ~= nil or (marks ~= nil and marks.hover ~= nil)
end

local function body(key: string, spec, shapes)
    local props = {
        key = key, align = "topLeading", dx = spec.x, dy = spec.y, w = spec.w, h = spec.h, backdrop = false,
        fill = spec.fill, gradient = spec.gradient, rim = spec.rim, opacity = spec.opacity, blend = 0, shadow = 0,
        animate = spec.animate,
    }
    for index, shape in shapes do
        props[index] = ui.shape(shape)
    end
    return ui.glass(props)
end

local function glint(g, bu: number)
    local pill = g.pill
    local band = 130 * bu
    local strip = {
        key = "battery-glint-band", decorative = true, align = "topLeading", dx = -band - 1, dy = 0, w = band + 1,
        h = pill.h, loop = { dx = { 0, (pill.w + band) * cycle / crossing, cycle } },
    }
    for index = 0, slices - 1 do
        strip[#strip + 1] = ui.box({
            decorative = true, align = "topLeading", dx = index * band / slices, dy = 0, w = band / slices + 1,
            h = pill.h, fill = palette.alpha("mint", 0.15 * math.sin((index + 0.5) / slices * math.pi)),
        })
    end
    return ui.stack({
        key = "battery-glint", decorative = true, align = "topLeading", dx = pill.x, dy = pill.y, w = pill.w,
        h = pill.h,
        ui.path({ mask = true, w = pill.w, h = pill.h, d = kit.roundedRect(0, 0, pill.w, pill.h, pill.radius) }),
        ui.stack(strip),
    })
end

local function vertical(ctx, g, level: number, low: number, show: number)
    local strip, bu = g.frame.strip, g.k.bu
    local margin, thickness = 7 * bu, 8 * g.k.u
    local width = strip.w - 2 * margin
    local bottom = g.size.h - thickness - margin
    local full = g.size.h - 2 * (thickness + margin) - 6.6 * bu
    local len = math.max(0.1, full * math.clamp(level / 100, 0, 1))
    local lead = len * share / (1 - share)
    local color = if low == 1 then "#e0655a" else palette.alpha("mint", 1)
    local radius = math.min(width / 2, math.max(0.5, 14 * bu - margin))
    local nub = 0.56 * width
    local strength = (0.19 + 0.09 * low) * show
    local x = strip.x + margin
    return {
        body("battery-track", {
            x = x, y = bottom - full - 6.6 * bu, w = width, h = full + 6.6 * bu,
            fill = color, rim = 0.1, opacity = 0.1 * show, animate = g.calm,
        }, {
            { key = "battery-track-shape", align = "topLeading", dx = 0, dy = 6.6 * bu,
                w = width, h = full, radius = radius, animate = g.calm },
            { key = "battery-track-nub", align = "topLeading", dx = (width - nub) / 2, dy = 0,
                w = nub, h = 7 * bu, radius = 2.6 * bu, animate = g.calm },
        }),
        body("battery-fill", {
            x = x, y = bottom - len, w = width, h = len + lead, rim = 0.18, opacity = strength,
            gradient = { from = color, to = palette.roles.tint, angle = 90 }, animate = g.calm,
        }, {
            { key = "battery-fill-shape", align = "topLeading", dx = 0, dy = 0,
                w = width, h = len, radius = radius, animate = g.calm },
        }),
        body("battery-nub", {
            x = strip.cx - nub / 2, y = bottom - full - 6.6 * bu, w = nub, h = 6.6 * bu,
            fill = color, rim = 0, opacity = strength, animate = g.calm,
        }, {
            { key = "battery-nub-shape", align = "topLeading", dx = 0, dy = 0,
                w = nub, h = 6.6 * bu, radius = 2.6 * bu, animate = g.calm },
        }),
    }
end

local function content(ctx, g)
    local pill = g.pill
    local level = ctx.data.battery
    if not pill or type(level) ~= "number" then return nil end
    local bu = g.k.bu
    local charging = ctx.data.charging == true
    local low = if level < 20 and not charging then 1 else 0
    local show = if hovered(ctx) or level < 20 then 1 else 0
    if g.frame and g.frame.vertical then return vertical(ctx, g, level, low, show) end
    local margin = 7 * bu
    local x = pill.x + margin
    local mid = pill.cy
    local full = pill.w - 2 * margin - 6.6 * bu
    local hh = (pill.h - 2 * margin) * (0.7 + 0.3 * show)
    local len = math.max(0.1, full * math.clamp(level / 100, 0, 1))
    local span = math.max(1, len)
    local lead = span * share / (1 - share)
    local color = if low == 1 then "#e0655a" else palette.alpha("mint", 1)
    local radius = math.min(hh / 2, math.max(0.5, (if g.frame then 14 * bu else pill.radius) - margin))
    local nub = 0.56 * hh
    local strength = (0.19 + 0.09 * low) * show
    local top = mid - hh / 2
    local items = {
        body("battery-track", {
            x = x, y = top, w = full + 6.6 * bu, h = hh, fill = color, rim = 0.1, opacity = 0.1 * show,
            animate = g.calm,
        }, {
            { key = "battery-track-shape", align = "topLeading", dx = 0, dy = 0, w = full, h = hh, radius = radius,
                animate = g.calm },
            { key = "battery-track-nub", align = "topLeading", dx = full - 0.4 * bu, dy = (hh - nub) / 2,
                w = 7 * bu, h = nub, radius = 2.6 * bu, animate = g.calm },
        }),
        body("battery-fill", {
            x = x - lead, y = top, w = lead + span, h = hh, rim = 0.18, opacity = strength, animate = g.calm,
            gradient = { from = palette.roles.tint, to = color, angle = 0 },
        }, {
            { key = "battery-fill-shape", align = "topLeading", dx = lead, dy = 0, w = len, h = hh, radius = radius,
                animate = g.calm },
        }),
        body("battery-nub", {
            x = x + full, y = top, w = 6.6 * bu, h = hh, fill = color, rim = 0, opacity = strength,
            animate = g.calm,
        }, {
            { key = "battery-nub-shape", align = "topLeading", dx = 0, dy = (hh - nub) / 2,
                w = 6.6 * bu, h = nub, radius = 2.6 * bu, animate = g.calm },
        }),
    }
    if charging and level < 98 then items[#items + 1] = glint(g, bu) end
    return items
end

return table.freeze({ shapes = none, content = content })

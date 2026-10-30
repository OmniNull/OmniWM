-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local function band(f: number): number
    return 43 + (f - 43) % 31
end

local function wave(fr: number, f: number, seed: number): number
    return math.sin(math.rad(fr * f + seed))
end

local function number(value: number): string
    return string.format("%.3f", value)
end

local function tooth(n: number)
    local angle = math.rad(45 * n)
    local x, y = math.sin(angle), -math.cos(angle)
    local points = { { 4.9 * x, 4.9 * y }, { 7.3 * x, 7.3 * y } }
    return { width = 2, f = band(58 + 11 * n), s = 21730 + 53 * n, points = points }
end

local gear = {
    { r = 3.6, width = 1.7, x = 0, y = 0, f = 48, s = 21297, rs = 12400 },
    { r = 1.2, x = 0, y = 0, f = 59, s = 21350, rs = 12431 },
}
for n = 0, 7 do
    gear[#gear + 1] = tooth(n)
end

local icons = table.freeze({
    gear = table.freeze({ offset = { 0.5, 0.4 }, strokes = gear }),
    search = table.freeze({ offset = { 0.5, 0.4 }, strokes = {
        { r = 4, width = 1.7, x = -1.2, y = -1.2, f = 51, s = 22357, rs = 13020 },
        { width = 1.9, f = 55, s = 22313, points = { { 1.8, 1.8 }, { 5, 5 } } },
    } }),
    controls = table.freeze({ offset = { 0.5, 0.4 }, strokes = {
        { width = 1.6, f = 61, s = 22790, points = { { -6.5, -3.5 }, { 6.5, -3.5 } } },
        { width = 1.6, f = 72, s = 22843, points = { { -6.5, 3.5 }, { 6.5, 3.5 } } },
        { r = 2.6, x = 2.5, y = -3.5, f = 59, s = 22993, rs = 13392 },
        { r = 2.6, x = -2.5, y = 3.5, f = 70, s = 23046, rs = 13423 },
    } }),
    overview = table.freeze({ offset = { 0.4, 0.3 }, strokes = {
        { tone = 1, f = 47, s = 23320,
            points = { { -0.25, 0.15 }, { -0.41, 0.15 }, { -0.41, -0.35 }, { 0.25, -0.35 }, { 0.25, -0.15 } } },
        { tone = 2, f = 58, s = 23373, close = true,
            points = { { -0.25, -0.15 }, { 0.41, -0.15 }, { 0.41, 0.35 }, { -0.25, 0.35 } } },
        { tone = 3, f = 69, s = 23426, points = { { -0.25, -0.01 }, { 0.41, -0.01 } } },
    } }),
})

local function ellipse(stroke, cx: number, cy: number, k: number, jt: number, fr: number, faint: boolean): string
    local f = if faint then band(stroke.f + 15) else stroke.f
    local s = if faint then stroke.s + 371 else stroke.s
    local x = cx + stroke.x * k + jt * wave(fr, f, s)
    local y = cy + stroke.y * k + jt * wave(fr, band(f + 12), s + 157)
    local r = stroke.r * k * (1 + 0.04 * wave(fr, 47, stroke.rs + (if faint then 70 else 0)))
    local radius = number(r)
    return table.concat({
        "M", number(x), number(y - r),
        "A", radius, radius, "0 1 1", number(x), number(y + r),
        "A", radius, radius, "0 1 1", number(x), number(y - r),
        "Z",
    }, " ")
end

local function polyline(stroke, cx: number, cy: number, k: number, jt: number, fr: number, faint: boolean): string
    local f = if faint then band(stroke.f + 15) else stroke.f
    local s = if faint then stroke.s + 371 else stroke.s
    local parts = {}
    for index, point in stroke.points do
        local i = index - 1
        local fx = band(f + 7 * i)
        parts[#parts + 1] = if i == 0 then "M" else "L"
        parts[#parts + 1] = number(cx + point[1] * k + jt * wave(fr, fx, s + 97 * i))
        parts[#parts + 1] = number(cy + point[2] * k + jt * wave(fr, band(fx + 5), s + 97 * i + 60))
    end
    if stroke.close then parts[#parts + 1] = "Z" end
    return table.concat(parts, " ")
end

local function icon(name: string, cx: number, cy: number, k: number, a: number, fr: number, unit: number?, sw: number?)
    local spec = icons[name]
    local j = unit or k
    local jt = (0.1 + 0.3 * a) * j
    local dx, dy = spec.offset[1] * j, spec.offset[2] * j
    local list = {}
    for _, stroke in spec.strokes do
        local w = if stroke.width then stroke.width * k else sw
        local build = if stroke.r then ellipse else polyline
        local filled = stroke.r ~= nil and stroke.width == nil
        list[#list + 1] = {
            d = build(stroke, cx, cy, k, jt, fr, false), width = if filled then nil else w,
            alpha = 1, tone = stroke.tone,
        }
        list[#list + 1] = {
            d = build(stroke, cx + dx, cy + dy, k, jt, fr, true), width = if filled then nil else w and w * 0.7,
            alpha = 0.34, tone = stroke.tone,
        }
    end
    return list
end

local function sketch(points, closed: boolean, f0: number, s0: number, je: number, jm: number, fr: number): string
    local parts = {}
    local count = #points
    for index = 1, count + (if closed then 1 else 0) do
        local i = index - 1
        local point = points[(i % count) + 1]
        local fx = band(f0 + 7 * i)
        local x = point[1] + je * wave(fr, fx, s0 + 97 * i)
        local y = point[2] + je * wave(fr, fx + 5, s0 + 97 * i + 60)
        if i == 0 then
            parts[#parts + 1] = "M " .. number(x) .. " " .. number(y)
        else
            local px = band(f0 + 7 * (i - 1))
            local via = point.via
            local seed = s0 + 97 * (i - 1) + 3007
            parts[#parts + 1] = table.concat({
                "Q", number(via[1] + jm * wave(fr, px, seed)), number(via[2] + jm * wave(fr, px + 5, seed + 60)),
                number(x), number(y),
            }, " ")
        end
    end
    if closed then parts[#parts + 1] = "Z" end
    return table.concat(parts, " ")
end

local function passes(points, closed: boolean, spec, a: number, fr: number)
    local je = (spec.je[1] + spec.je[2] * a) * spec.bu
    local jm = (spec.jm[1] + spec.jm[2] * a) * spec.bu
    local shifted = {}
    for index, point in points do
        shifted[index] = {
            point[1] + spec.offset[1] * spec.bu, point[2] + spec.offset[2] * spec.bu,
            via = point.via and { point.via[1] + spec.offset[1] * spec.bu, point.via[2] + spec.offset[2] * spec.bu },
        }
    end
    return {
        { d = sketch(points, closed, spec.f, spec.s, je, jm, fr), width = spec.width[1] * spec.bu, alpha = 1 },
        {
            d = sketch(shifted, closed, band(spec.f + 6), spec.s + 477, je, jm, fr), width = spec.width[2] * spec.bu,
            alpha = 0.4,
        },
    }
end

local function outline(cx: number, cy: number, w: number, h: number, bu: number, a: number, fr: number)
    local c = 0.3 * math.min(w, h)
    local l, r, t, b = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    local points = {
        { l + c, t, via = { l, t } },
        { r - c, t, via = { cx, t } }, { r, t + c, via = { r, t } }, { r, b - c, via = { r, cy } },
        { r - c, b, via = { r, b } }, { l + c, b, via = { cx, b } }, { l, b - c, via = { l, b } },
        { l, t + c, via = { l, cy } },
    }
    return passes(points, true, {
        bu = bu, f = 55, s = 37100, je = { 0.08, 0.47 }, jm = { 0.25, 1.1 },
        width = { 1.3, 0.9 }, offset = { 0.35, 0.3 },
    }, a, fr)
end

local function line(cx: number, cy: number, len: number, bu: number, a: number, fr: number)
    local points = {
        { cx - len / 2, cy },
        { cx, cy, via = { cx - len / 4, cy - 0.8 * bu } },
        { cx + len / 2, cy, via = { cx + len / 4, cy + 0.8 * bu } },
    }
    return passes(points, false, {
        bu = bu, f = 70, s = 42400, je = { 0.15, 0.25 }, jm = { 0.5, 0.5 }, width = { 1.5, 1 }, offset = { 0.4, 0.5 },
    }, a, fr)
end

local function draw(w: number, h: number, list, color: string, opacity: (number | { number })?)
    local items = {}
    for index, pass in list do
        local amount = if type(opacity) == "table" then opacity[pass.tone or 1] else opacity or 1
        items[index] = ui.path({
            decorative = true, w = w, h = h, d = pass.d, opacity = amount * pass.alpha,
            fill = if pass.width then 0 else color, border = if pass.width then color else nil,
            borderWidth = pass.width,
        })
    end
    return items
end

return table.freeze({ band = band, wave = wave, icon = icon, outline = outline, line = line, draw = draw })

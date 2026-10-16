-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local function at(cx: number, cy: number, radius: number, degrees: number): (number, number)
    local angle = math.rad(degrees)
    return cx + radius * math.cos(angle), cy + radius * math.sin(angle)
end

local function circle(size: number, inset: number): string
    local middle = size / 2
    local radius = middle - inset
    return string.format("M %.2f %.2f A %.2f %.2f 0 1 1 %.2f %.2f A %.2f %.2f 0 1 1 %.2f %.2f Z", middle,
        middle - radius, radius, radius, middle, middle + radius, radius, radius, middle, middle - radius)
end

local function band(cx: number, cy: number, radius: number, width: number, start: number, sweep: number): string
    local span = math.clamp(sweep, 0.01, 359.9)
    local large = span > 180 and 1 or 0
    local outer, inner, cap = radius + width / 2, radius - width / 2, width / 2
    local ax, ay = at(cx, cy, outer, start)
    local bx, by = at(cx, cy, outer, start + span)
    local cx2, cy2 = at(cx, cy, inner, start + span)
    local dx, dy = at(cx, cy, inner, start)
    return string.format(
        "M %.2f %.2f A %.2f %.2f 0 %d 1 %.2f %.2f A %.2f %.2f 0 0 1 %.2f %.2f A %.2f %.2f 0 %d 0 %.2f %.2f A %.2f %.2f 0 0 1 %.2f %.2f Z",
        ax, ay, outer, outer, large, bx, by, cap, cap, cx2, cy2, inner, inner, large, dx, dy, cap, cap, ax, ay)
end

export type Gauge = { value: string?, track: string?, dot: { x: number, y: number }? }

local function gauge(size: number, width: number, fraction: number, start: number?, sweep: number?, gap: number?): Gauge
    local from = start or -90
    local full = sweep or 360
    local amount = math.clamp(fraction, 0, 1)
    local middle = size / 2
    local radius = middle - width / 2
    local spacing = math.deg(((gap or 8) + width) / radius)
    local result: Gauge = {}
    local filled = full * amount
    if amount > 0.003 then
        result.value = band(middle, middle, radius, width, from, filled)
    end
    local remaining = full - filled - spacing * (full < 360 and 1 or 2)
    if remaining > 1 then
        result.track = band(middle, middle, radius, width, from + filled + spacing, remaining)
    end
    if full < 360 then
        local x, y = at(middle, middle, radius, from + full)
        result.dot = { x = x, y = y }
    end
    return result
end

local function sector(cx: number, cy: number, radius: number, start: number, sweep: number): string
    local span = math.clamp(sweep, 0.01, 359.9)
    local ax, ay = at(cx, cy, radius, start)
    local bx, by = at(cx, cy, radius, start + span)
    return string.format("M %.2f %.2f L %.2f %.2f A %.2f %.2f 0 %d 1 %.2f %.2f Z", cx, cy, ax, ay, radius, radius,
        span > 180 and 1 or 0, bx, by)
end

local function smooth(xs: { number }, ys: { number }, closed: boolean): string
    local count = #xs
    local parts = table.create(count + 1)
    parts[1] = string.format("M %.2f %.2f", xs[1], ys[1])
    local last = closed and count or count - 1
    for index = 1, last do
        local function wrap(i: number): number
            if closed then
                return (i - 1) % count + 1
            end
            return math.clamp(i, 1, count)
        end
        local before, after, beyond = wrap(index - 1), wrap(index + 1), wrap(index + 2)
        parts[#parts + 1] = string.format("C %.2f %.2f %.2f %.2f %.2f %.2f",
            xs[index] + (xs[after] - xs[before]) / 6, ys[index] + (ys[after] - ys[before]) / 6,
            xs[after] - (xs[beyond] - xs[index]) / 6, ys[after] - (ys[beyond] - ys[index]) / 6, xs[after], ys[after])
    end
    if closed then
        parts[#parts + 1] = "Z"
    end
    return table.concat(parts, " ")
end

local function wavyRing(size: number, radius: number, amplitude: number, waves: number): string
    local count = waves * 8
    local xs, ys = table.create(count), table.create(count)
    local middle = size / 2
    for index = 1, count do
        local degrees = (index - 1) * 360 / count
        xs[index], ys[index] = at(middle, middle, radius + amplitude * math.sin(math.rad(degrees * waves)), degrees)
    end
    return smooth(xs, ys, true)
end

local function wavyLine(length: number, height: number, wavelength: number, amplitude: number): string
    local count = math.max(2, math.ceil(length / wavelength * 8) + 1)
    local xs, ys = table.create(count), table.create(count)
    for index = 1, count do
        local x = (index - 1) * length / (count - 1)
        xs[index], ys[index] = x, height / 2 + amplitude * math.sin(x / wavelength * 2 * math.pi)
    end
    return smooth(xs, ys, false)
end

local function sparkline(values: { number }, width: number, height: number, maximum: number, area: boolean?): string?
    local count = #values
    if count < 2 then
        return nil
    end
    local top = math.max(maximum, 1e-9)
    local xs, ys = table.create(count), table.create(count)
    for index, value in values do
        xs[index] = (index - 1) * width / (count - 1)
        ys[index] = height - math.clamp(value / top, 0, 1) * height
    end
    local line = smooth(xs, ys, false)
    if not area then
        return line
    end
    return string.format("%s L %.2f %.2f L 0 %.2f Z", line, width, height, height)
end

local function drawer(width: number, height: number, fillet: number, radius: number): string
    local outer = width + 2 * fillet
    local corner = math.min(radius, width / 2, height - fillet)
    return string.format(
        "M 0 0 H %.2f A %.2f %.2f 0 0 0 %.2f %.2f V %.2f A %.2f %.2f 0 0 1 %.2f %.2f H %.2f A %.2f %.2f 0 0 1 %.2f %.2f V %.2f A %.2f %.2f 0 0 0 0 0 Z",
        outer, fillet, fillet, outer - fillet, fillet, height - corner, corner, corner, outer - fillet - corner, height,
        fillet + corner, corner, corner, fillet, height - corner, fillet, fillet, fillet)
end

return table.freeze({
    at = at,
    circle = circle,
    band = band,
    gauge = gauge,
    sector = sector,
    smooth = smooth,
    wavyRing = wavyRing,
    wavyLine = wavyLine,
    sparkline = sparkline,
    drawer = drawer,
})

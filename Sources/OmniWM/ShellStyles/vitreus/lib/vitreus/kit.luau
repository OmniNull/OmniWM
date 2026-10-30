-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("./palette")
local pencil = require("./pencil")

local font = "Space Grotesk"
local still = table.freeze({ x = 0, y = 0 })
local boilFrame = 0.2

local function spring(response: number, bounce: number)
    return table.freeze({ response = response, bounce = bounce })
end

local springs = table.freeze({
    slide = spring(0.424, 0.19),
    drip = spring(0.482, 0.31),
    dripl = spring(0.926, 0.41),
    splash = spring(0.307, 0.68),
    pop = spring(0.363, 0.65),
    gentle = spring(0.456, 0.13),
    desk = spring(0.363, 0.42),
    touch = spring(2 * math.pi * 0.14 / 6.64, 0),
    fd0 = spring(0.360, 0),
    fd1 = spring(0.530, 0),
    fd2 = spring(0.643, 0),
    fd3 = spring(0.738, 0),
    fd4 = spring(0.833, 0),
    close = spring(0.076, 0),
})

local passes = table.freeze({
    table.freeze({
        seed = 71000, width = 1.3, alpha = 0.6, x = 0, y = 0,
        f = table.freeze({ 57, 64, 71, 72, 47, 48, 54, 61, 62, 68, 69, 51, 58 }),
    }),
    table.freeze({
        seed = 72300, width = 0.9, alpha = 0.2, x = 0.35, y = 0.28,
        f = table.freeze({ 72, 48, 55, 56, 63, 64, 70, 46, 47, 53, 54, 73, 49 }),
    }),
})

local function springState(spec, from: number, velocity: number, elapsed: number, target: number): (number, number)
    if elapsed <= 0 then
        return from, velocity
    end
    local frequency = 2 * math.pi / spec.response
    local decay = (1 - spec.bounce) * frequency
    local offset = from - target
    local drift = velocity + decay * offset
    local envelope = math.exp(-decay * elapsed)
    if spec.bounce == 0 then
        return target + envelope * (offset + drift * elapsed),
            envelope * (velocity - (decay * velocity + frequency * frequency * offset) * elapsed)
    end
    local oscillation = math.sqrt((frequency - decay) * (frequency + decay))
    local phase = oscillation * elapsed
    local cosine, sine = math.cos(phase), math.sin(phase)
    return target + envelope * (offset * cosine + drift * sine / oscillation),
        envelope * (velocity * cosine - (decay * velocity + frequency * frequency * offset) * sine / oscillation)
end

local function springSettle(spec, from: number, velocity: number, target: number, residual: number?, speed: number?): number
    local tolerance, speedLimit = residual or 0.001, speed or 0.001
    local frequency = 2 * math.pi / spec.response
    local decay = (1 - spec.bounce) * frequency
    local offset = from - target
    local reach = 2 / (math.exp(1) * decay)
    local drift = velocity + decay * offset
    local restoring = decay * velocity + frequency * frequency * offset
    local excess = math.max(1, (math.abs(offset) + reach * math.abs(drift)) / tolerance,
        (math.abs(velocity) + reach * math.abs(restoring)) / speedLimit)
    local limit = 2 * math.log(excess) / decay
    if limit <= 0 then
        return 0
    end
    for index = 1, 512 do
        local elapsed = limit * index / 512
        local position, speedAt = springState(spec, from, velocity, elapsed, target)
        if math.abs(position - target) < tolerance and math.abs(speedAt) < speedLimit then
            return elapsed
        end
    end
    return limit
end

local function springCrossing(spec, from: number, velocity: number, target: number, threshold: number,
    rising: boolean?, after: number?): number?
    local start = math.max(0, after or 0)
    local frequency = 2 * math.pi / spec.response
    local decay = (1 - spec.bounce) * frequency
    local offset = from - target
    local restoring = decay * velocity + frequency * frequency * offset
    local boundaries = { start }
    if spec.bounce == 0 then
        local drift = velocity + decay * offset
        if threshold == target then
            local zero = if drift ~= 0 then -offset / drift else -1
            if zero >= start then
                local _, direction = springState(spec, from, velocity, zero, target)
                if rising == nil or (direction > 0) == rising then
                    return zero
                end
            end
            return nil
        end
        local turn = if restoring ~= 0 then velocity / restoring else -1
        if turn > start then
            table.insert(boundaries, turn)
        end
        local limit = springSettle(spec, from, velocity, target, math.abs(threshold - target) / 2, 0.001)
        table.insert(boundaries, math.max(start + 1, limit))
    else
        local oscillation = math.sqrt((frequency - decay) * (frequency + decay))
        local phase = math.atan2(velocity * oscillation, restoring)
        local turn = phase / oscillation
        local period = math.pi / oscillation
        turn += math.max(0, math.floor((start - turn) / period) + 1) * period
        for index = 0, 2 do
            table.insert(boundaries, turn + index * period)
        end
    end
    for index = 2, #boundaries do
        local low, high = boundaries[index - 1], boundaries[index]
        local left = springState(spec, from, velocity, low, target) - threshold
        local right = springState(spec, from, velocity, high, target) - threshold
        local ascending = right > left
        if (rising == nil or ascending == rising) and (left == 0 or left * right <= 0) then
            if left == 0 then
                return low
            end
            for _ = 1, 48 do
                local middle = (low + high) / 2
                local value = springState(spec, from, velocity, middle, target) - threshold
                if (value > 0) == ascending then
                    high = middle
                else
                    low = middle
                end
            end
            return (low + high) / 2
        end
    end
    return nil
end

local function impulse(spec, velocity: number, elapsed: number): number
    local position = springState(spec, 0, velocity, elapsed, 0)
    return position
end

local function sampleImpulse(spec, velocity: number, duration: number, count: number?): { number }
    local length = math.clamp(math.floor(count or 256), 2, 256)
    local samples = table.create(length)
    for index = 1, length - 1 do
        samples[index] = impulse(spec, velocity, duration * (index - 1) / (length - 1))
    end
    samples[length] = 0
    return samples
end

local function bellSwing(elapsed: number): number
    local phase = math.max(elapsed, 0) * 6.64 / 2.4
    local q = 1 - math.exp(-phase) * (1 + phase)
    return 24 * (1 - q) * math.sin(math.rad(q * 2000))
end

local function sampleBell(count: number?): { number }
    local length = math.clamp(math.floor(count or 256), 2, 256)
    local samples = table.create(length)
    for index = 1, length - 1 do
        samples[index] = bellSwing(2.4 * (index - 1) / (length - 1))
    end
    samples[length] = 0
    return samples
end

local function canvas(w: number, h: number, du: number, rs: number)
    return table.freeze({ w = w, h = h, du = du, rs = rs })
end

local function at(c, props, x: number, y: number)
    props.dx = x - c.w / 2
    props.dy = y - c.h / 2
    return props
end

local function children(props, spec)
    for index, child in ipairs(spec) do
        props[index] = child
    end
    return props
end

local function label(c, spec)
    local props = {
        key = spec.key,
        text = spec.text,
        font = font,
        size = spec.size * c.rs,
        weight = spec.weight,
        color = spec.color or "foreground",
        opacity = spec.opacity,
        animate = spec.animate,
        maxWidth = spec.maxWidth,
        lines = spec.lines,
        decorative = spec.decorative,
        shadow = spec.shadow,
        shadowRadius = spec.shadowRadius,
        shadowOffset = spec.shadowOffset,
        pulse = spec.pulse,
    }
    if spec.x == nil then
        return ui.text(props)
    end
    if spec.align == "leading" then
        props.align = "leading"
        props.dx = spec.x
        props.dy = spec.y - c.h / 2
        return ui.text(props)
    end
    return ui.text(at(c, props, spec.x, spec.y))
end

local function zone(c, spec)
    local rest, hover = spec.rest or 1, spec.hover or 1
    local active = spec.active ~= false
    local props = at(c, {
        key = spec.key,
        w = spec.w,
        h = spec.h,
        opacity = if hover > 0 then rest / hover else rest,
        hoverOpacity = if active and rest ~= hover then 1 else nil,
        animate = spec.animate,
        hoverAnimate = spec.hoverAnimate,
        onClick = if active then spec.onClick else nil,
        cursor = if active then spec.cursor else nil,
        gesture = spec.gesture,
        onGesture = spec.onGesture,
        pulse = spec.pulse,
    }, spec.x, spec.y)
    return ui.stack(children(props, spec))
end

local function section(c, spec, reveal: boolean?)
    local rise = 12 * c.du
    return ui.stack(children({
        key = spec.key,
        w = c.w,
        h = c.h,
        appear = if reveal then { opacity = 0, dy = rise, animate = spec.animate, delay = 0.2 } else nil,
        exit = { opacity = 0, dy = rise, animate = springs.close },
    }, spec))
end

local function plate(c, x: number, y: number, w: number, h: number, radius: number, amount: number)
    return ui.box(at(c, { w = w, h = h, radius = radius, fill = palette.alpha("ink", amount) }, x, y))
end

local function number(value: number): string
    return string.format("%.3f", value)
end

local function roundedRect(x: number, y: number, w: number, h: number, r: number): string
    local radius = math.clamp(r, 0, math.min(w, h) / 2)
    local right, bottom = x + w, y + h
    return table.concat({
        "M", number(x + radius), number(y),
        "H", number(right - radius),
        "A", number(radius), number(radius), "0 0 1", number(right), number(y + radius),
        "V", number(bottom - radius),
        "A", number(radius), number(radius), "0 0 1", number(right - radius), number(bottom),
        "H", number(x + radius),
        "A", number(radius), number(radius), "0 0 1", number(x), number(bottom - radius),
        "V", number(y + radius),
        "A", number(radius), number(radius), "0 0 1", number(x + radius), number(y),
        "Z",
    }, " ")
end

local function stroke(c, d: string, color: string, width: number, key: string?)
    return ui.path({
        key = key, decorative = true, w = c.w, h = c.h, d = d, fill = 0, border = color, borderWidth = width,
    })
end

local function sketch(pass, x0: number, y0: number, x1: number, y1: number, r: number, jt: number, fr: number): string
    local points = {
        { x0 + r, y0 }, { x1 - r, y0 }, { x1, y0 + r }, { x1, y0 }, { x1, y1 - r }, { x1 - r, y1 }, { x1, y1 },
        { x0 + r, y1 }, { x0, y1 - r }, { x0, y1 }, { x0, y0 + r }, { x0 + r, y0 }, { x0, y0 },
    }
    local p = {}
    for index, point in points do
        local f, s = pass.f[index], pass.seed + 100 * (index - 1)
        p[index] = number(point[1] + jt * pencil.wave(fr, f, s)) .. " "
            .. number(point[2] + jt * pencil.wave(fr, f + 5, s + 60))
    end
    return table.concat({
        "M", p[1], "L", p[2], "Q", p[4], p[3], "L", p[5], "Q", p[7], p[6],
        "L", p[8], "Q", p[10], p[9], "L", p[11], "Q", p[13], p[12],
    }, " ")
end

local function outline(c, spec)
    local du = c.du
    local jt = (0.18 + 0.25 * (spec.hot or 0)) * du
    local items = { key = spec.key, decorative = true, w = c.w, h = c.h }
    for index, pass in passes do
        local left, top = spec.x - spec.w / 2 + pass.x * du, spec.y - spec.h / 2 + pass.y * du
        local path = stroke(c, sketch(pass, left, top, left + spec.w, top + spec.h, spec.radius, jt, spec.frame or 0),
            palette.alpha("ink", pass.alpha), pass.width * du, spec.key and spec.key .. "-" .. index)
        if spec.track then path.morph = { track = spec.track } end
        items[index] = path
    end
    return ui.stack(items)
end

local function settle(state)
    local entry = state.boil
    if entry and entry.timer then entry.timer:cancel() end
    state.boil = nil
end

local function stir(state, entry)
    entry.timer = omniwm.after(boilFrame, function()
        if state.boil ~= entry then return end
        entry.timer = nil
        if entry.drawn ~= entry.frame then
            state.boil = nil
            return
        end
        entry.frame += 1
        stir(state, entry)
    end)
end

local function boil(key: string)
    return function(next, event)
        local state = next.state
        if event.phase == "began" then
            settle(state)
            local entry = { key = key, frame = 1 }
            state.boil = entry
            stir(state, entry)
        elseif state.boil and state.boil.key == key then
            settle(state)
        end
    end
end

local function boiling(ctx, key: string): (number, number)
    local entry = ctx.state.boil
    if not entry or entry.key ~= key then return 0, 0 end
    entry.drawn = entry.frame
    return 1, entry.frame
end

local function body(c, spec)
    return ui.glass({
        key = spec.key, w = c.w, h = c.h, backdrop = false, blend = 0, rim = spec.rim,
        fill = spec.fill, gradient = spec.gradient, shadow = spec.shadow, shadowRadius = spec.glow,
        shadowOffset = still, animate = spec.animate,
        ui.shape({
            key = spec.key .. "-shape", align = "topLeading", dx = spec.x - spec.w / 2, dy = spec.y - spec.h / 2,
            w = spec.w, h = spec.h, radius = spec.radius, morph = spec.morph,
        }),
    })
end

local function thumb(c, spec)
    return ui.stack(at(c, {
        key = spec.key,
        w = spec.w,
        h = spec.h,
        radius = spec.radius,
        fill = "accent",
        shadow = palette.alpha("mint", spec.alpha or 0.48),
        shadowRadius = spec.glow,
        border = "foreground/0.160",
        borderWidth = 1,
        animate = springs.slide,
    }, spec.x, spec.y))
end

local function point(cx: number, cy: number, radius: number, angle: number): (string, string)
    return number(cx + radius * math.sin(angle)), number(cy - radius * math.cos(angle))
end

local function circle(cx: number, cy: number, radius: number): string
    local r = number(radius)
    return table.concat({
        "M", number(cx), number(cy - radius),
        "A", r, r, "0 1 1", number(cx), number(cy + radius),
        "A", r, r, "0 1 1", number(cx), number(cy - radius),
        "Z",
    }, " ")
end

local function ringPath(cx: number, cy: number, r: number, width: number, progress: number): (string, boolean)
    local outer, inner, cap = r + width / 2, r - width / 2, width / 2
    if progress >= 1 then
        return circle(cx, cy, outer) .. " " .. circle(cx, cy, inner), true
    end
    local fraction = math.max(progress, 0.002)
    local angle = fraction * 2 * math.pi
    local large = if fraction > 0.5 then "1" else "0"
    local endOuterX, endOuterY = point(cx, cy, outer, angle)
    local endInnerX, endInnerY = point(cx, cy, inner, angle)
    return table.concat({
        "M", number(cx), number(cy - outer),
        "A", number(outer), number(outer), "0", large, "1", endOuterX, endOuterY,
        "A", number(cap), number(cap), "0 0 1", endInnerX, endInnerY,
        "A", number(inner), number(inner), "0", large, "0", number(cx), number(cy - inner),
        "A", number(cap), number(cap), "0 0 1", number(cx), number(cy - outer),
        "Z",
    }, " "), false
end

local function arc(cx: number, cy: number, radius: number, from: number, to: number): string
    local startX, startY = point(cx, cy, radius, math.rad(from))
    local endX, endY = point(cx, cy, radius, math.rad(to))
    local large = if to - from > 180 then "1" else "0"
    return table.concat(
        { "M", startX, startY, "A", number(radius), number(radius), "0", large, "1", endX, endY },
        " "
    )
end

local function cross(cx: number, cy: number, arm: number): string
    return table.concat({
        "M", number(cx - arm), number(cy - arm), "L", number(cx + arm), number(cy + arm),
        "M", number(cx + arm), number(cy - arm), "L", number(cx - arm), number(cy + arm),
    }, " ")
end

local function tick(cx: number, cy: number, du: number): string
    return table.concat({
        "M", number(cx - 3.6 * du), number(cy + 0.2 * du),
        "L", number(cx - 1.1 * du), number(cy + 2.8 * du),
        "L", number(cx + 3.8 * du), number(cy - 2.6 * du),
    }, " ")
end

local function play(cx: number, cy: number, du: number): string
    return table.concat({
        "M", number(cx - 3.4 * du), number(cy - 5 * du),
        "L", number(cx + 5.4 * du), number(cy),
        "L", number(cx - 3.4 * du), number(cy + 5 * du),
        "Z",
    }, " ")
end

return table.freeze({
    font = font,
    hover = 0.14,
    springs = springs,
    springState = springState,
    springSettle = springSettle,
    springCrossing = springCrossing,
    impulse = impulse,
    sampleImpulse = sampleImpulse,
    bellSwing = bellSwing,
    sampleBell = sampleBell,
    canvas = canvas,
    at = at,
    label = label,
    zone = zone,
    section = section,
    plate = plate,
    roundedRect = roundedRect,
    stroke = stroke,
    outline = outline,
    boil = boil,
    boiling = boiling,
    body = body,
    thumb = thumb,
    circle = circle,
    ringPath = ringPath,
    arc = arc,
    cross = cross,
    tick = tick,
    play = play,
})

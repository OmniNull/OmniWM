-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("../kit")
local palette = require("../palette")
local pencil = require("../pencil")
local units = require("../units")
local buttons = require("./buttons")

local shadow = palette.alpha("deep", 0.4)
local lift = table.freeze({ x = 0, y = 1 })
local wait = table.freeze({ response = 2 * math.pi * 0.28 / 6.64, bounce = 0 })
local enter = kit.springCrossing(wait, 0, 0, 1, 0.3, true)
local leave = kit.springCrossing(wait, 1, 0, 0, 0.3, false)
local fill = table.freeze({ { 4.5, -3.5 }, { -1, 0 }, { 4.5, 3.5 } })
local forward = table.freeze({ { -4.5, -3.5 }, { 1, 0 }, { -4.5, 3.5 } })
local arrow = table.freeze({ { -3, -4.5 }, { 7, 0 }, { -3, 4.5 } })
local strokes = table.freeze({
    previous = {
        { w = 1.4, f = 64, s = 23850, p = { { -2, -3.5 }, { -2, 3.5 } } },
        { fill = 0.4, f = 55, s = 23956, close = true, p = fill },
        { w = 1.3, f = 66, s = 24009, close = true, p = fill },
    },
    next = {
        { fill = 0.4, f = 50, s = 24380, close = true, p = forward },
        { w = 1.3, f = 61, s = 24433, close = true, p = forward },
        { w = 1.4, f = 72, s = 24486, p = { { 2, -3.5 }, { 2, 3.5 } } },
    },
    pause = {
        { w = 2.2, f = 67, s = 24910, p = { { -3, -4.5 }, { -3, 4.5 } } },
        { w = 2.2, f = 47, s = 24963, p = { { 3, -4.5 }, { 3, 4.5 } } },
    },
    play = {
        { fill = 0.4, f = 58, s = 25016, close = true, p = arrow },
        { w = 1.3, f = 69, s = 25069, close = true, p = arrow },
    },
})
local transport = table.freeze({
    { key = "previous", side = -1, command = "media previous", rest = 0.65 },
    { key = "play", side = 0, command = "media toggle", rest = 0.85 },
    { key = "next", side = 1, command = "media next", rest = 0.65 },
})
local least = 48
local function minimum(ctx, k): number
    return (if ctx.data.media then 72 else least) * k.bu
end
local last
local verticalLast

local function mix(from: number, to: number, amount: number): number
    return from + (to - from) * amount
end

local function clamp(value: number, low: number, high: number): number
    return math.min(math.max(value, low), high)
end

local function round(value: number): number
    return math.floor(value + 0.5)
end

local function trace(stroke, cx: number, cy: number, k: number, jt: number, fr: number, faint: boolean): string
    local f = if faint then pencil.band(stroke.f + 15) else stroke.f
    local s = if faint then stroke.s + 371 else stroke.s
    local parts = {}
    for index, point in stroke.p do
        local i = index - 1
        local fx = pencil.band(f + 7 * i)
        parts[#parts + 1] = if i == 0 then "M" else "L"
        local seed = s + 97 * i
        parts[#parts + 1] = string.format("%.3f", cx + point[1] * k + jt * pencil.wave(fr, fx, seed))
        local dy = jt * pencil.wave(fr, pencil.band(fx + 5), seed + 60)
        parts[#parts + 1] = string.format("%.3f", cy + point[2] * k + dy)
    end
    if stroke.close then parts[#parts + 1] = "Z" end
    return table.concat(parts, " ")
end

local function glyph(name: string, cx: number, cy: number, k: number, a: number, fr: number)
    local jt = (0.1 + 0.3 * a) * k
    local passes = {}
    for _, stroke in strokes[name] do
        passes[#passes + 1] = { d = trace(stroke, cx, cy, k, jt, fr, false), width = stroke.w and stroke.w * k,
            alpha = stroke.fill or 1 }
        if stroke.w then
            passes[#passes + 1] = { d = trace(stroke, cx + 0.5 * k, cy + 0.4 * k, k, jt, fr, true),
                width = 0.7 * stroke.w * k, alpha = 0.34 }
        end
    end
    return passes
end

local function measure(ctx, bz: number)
    local app, title = ctx.data.app or "", ctx.data.title or ""
    local key = table.concat({ app, title, bz }, "\0")
    if last and last.key == key then return last end
    local cw, ch = ctx.format.measure(app, { font = kit.font, size = 17 * bz, weight = "semibold" })
    local tw, th = ctx.format.measure(title, { font = kit.font, size = 13.5 * bz, weight = "medium" })
    last = table.freeze({ key = key, app = app, title = title, cw = cw, ch = ch, tw = tw, th = th })
    return last
end

local function metrics(ctx, k)
    local app, title = ctx.data.app or "", ctx.data.title or ""
    local key = table.concat({ app, title, k.bz }, "\0")
    if verticalLast and verticalLast.key == key then
        return verticalLast
    end
    local cw, ch = ctx.format.measure(app, { font = kit.font, size = 15 * k.bz, weight = "semibold" })
    local tw, th = ctx.format.measure(title, { font = kit.font, size = 14 * k.bz, weight = "medium" })
    verticalLast = table.freeze({ key = key, app = app, title = title, cw = cw, ch = ch, tw = tw, th = th })
    return verticalLast
end

local function place(ctx, g, slot)
    local k = g.k
    local bu, u = k.bu, units.u
    local pill = g.pill
    local m = measure(ctx, k.bz)
    local media = ctx.data.media
    local shown = if media then 1 else 0
    local seg = g.layout == "seg"
    local w = if seg then slot.w else math.max(0, slot.w - pill.gap * shown)
    local control = 54 * bu * shown
    local hw = if seg then w else clamp(math.max(m.cw + control, m.tw) + 12 * bu, least * bu, w)
    local cm = if g.frame and not seg
        then clamp(g.size.w / 2, slot.x + 24 * bu, math.max(slot.x + 24 * bu, slot.x + w - 24 * bu))
        else slot.x + w / 2
    local xs = if seg then slot.x + 6 * bu elseif g.frame then clamp(g.size.w / 2 - hw / 2 + 6 * bu, slot.x,
        math.max(slot.x, slot.x + w - hw + 6 * bu)) else slot.x
    local widest = math.max(m.cw, m.tw)
    local have = clamp(widest / (6 * bu), 0, 1)
    local tab = clamp(widest + 12 * u, 52 * u, math.max(52 * u, w - 12 * u))
    return {
        m = m, media = media, shown = shown, control = control, hw = hw, have = have, xs = xs,
        zc = mix(cm, xs - 6 * bu + hw / 2, have), zw = mix(math.max(least * bu, w - 12 * bu), hw, have),
        mcx = mix(cm, xs - 6 * bu + hw - 27.5 * bu, have), mcy = mix(pill.cy, pill.cy - 6.5 * bu, have),
        tab = tab, tx = mix(cm, xs - 6 * u + tab / 2, clamp(widest / (6 * u), 0, 1)),
    }
end

local function player(ctx, g)
    local slot = g.pill.slots.title
    if slot and ctx.data.media then return place(ctx, g, slot).mcx end
    return (slot or g.pill).cx
end

local function shapes(ctx, g, slot)
    local state = ctx.state
    if g.layout == "seg" or state.barHot ~= "title" or state.drawerPanel == "player" then return nil end
    local pill, u = g.pill, units.u
    if g.frame and g.frame.vertical then
        local span = g.frame.lv.span
        local depth = 6 * u + 3.5 * u
        local left = if g.frame.edge == "right" then pill.x - 3.5 * u else pill.x + pill.w - 6 * u
        return { ui.shape({ key = "title-tab", align = "topLeading", dx = left,
            dy = g.frame.lv.tm - span / 2, w = depth, h = span, radius = 5 * u, animate = g.calm,
            reveal = { response = g.calm.response, bounce = g.calm.bounce, delay = enter, hold = leave },
            morph = { anchor = { x = if g.frame.edge == "right" then 1 else 0, y = 0.5 },
                stops = { { at = 0, w = 0 }, { at = 1, w = 1 } } },
        }) }
    end
    local p = place(ctx, g, slot)
    return { ui.shape({
        key = "title-tab", align = "topLeading", dx = p.tx - p.tab / 2,
        dy = if g.frame and g.frame.edge == "fbottom" then pill.cy - pill.h / 2 - 3.5 * u else pill.cy, w = p.tab,
        h = pill.h / 2 + 3.5 * u, radius = 5 * u, animate = g.calm,
        reveal = { response = g.calm.response, bounce = g.calm.bounce, delay = enter, hold = leave },
        morph = { anchor = { x = 0.5, y = if g.frame and g.frame.edge == "fbottom" then 1 else 0 },
            stops = { { at = 0, h = 0 }, { at = 1, h = 1 } } },
    }) }
end

local function text(key: string, value: string, size: number, weight: string, color: string, opacity: number,
    limit: number, x: number, y: number, h: number)
    if limit <= 0 or value == "" then return nil end
    return ui.text({
        key = key, text = value, font = kit.font, size = size, weight = weight, color = color, opacity = opacity,
        maxWidth = limit, lines = 1, decorative = true, align = "topLeading", dx = x, dy = y - h / 2,
        shadow = shadow, shadowRadius = 3, shadowOffset = lift,
    })
end

local function control(ctx, spec, p, bu: number, ox: number, oy: number)
    local a, fr = buttons.sketch(ctx, spec.key)
    local name = if spec.key == "play" then (if p.media.playing then "pause" else "play") else spec.key
    local size = 24 * bu
    local passes = glyph(name, size / 2, size / 2, bu, a, fr)
    local icon = buttons.append(buttons.glow({
        key = "title-" .. spec.key .. "-icon", decorative = true, w = size, h = size, dx = 1.5 * bu * spec.side,
        scale = 1 + 0.14 * a, opacity = spec.rest + (1 - spec.rest) * a, animate = buttons.touch,
    }, bu), pencil.draw(size, size, passes, palette.alpha("ink", 1)))
    return ui.stack({
        key = "title-" .. spec.key, align = "topLeading", w = 17 * bu, h = 18 * bu,
        dx = p.mcx + 17 * bu * spec.side - 8.5 * bu - ox, dy = p.mcy - 9 * bu - oy,
        cursor = "pointer", onClick = spec.command, onHover = buttons.hover(spec.key, true),
        ui.stack(icon),
    })
end

local function verticalControl(ctx, spec, g)
    local cu = g.k.bcu
    local a, fr = buttons.sketch(ctx, spec.key)
    local media = ctx.data.media
    local name = if spec.key == "play" then (if media.playing then "pause" else "play") else spec.key
    local size = 24 * cu
    local passes = glyph(name, size / 2, size / 2, cu, a, fr)
    local icon = buttons.append(buttons.glow({
        key = "title-" .. spec.key .. "-icon", decorative = true, w = size, h = size,
        rotate = -90, scale = 1 + 0.14 * a, opacity = spec.rest + (1 - spec.rest) * a, animate = buttons.touch,
        dy = 1.5 * cu * -spec.side,
    }, g.k.bu), pencil.draw(size, size, passes, palette.alpha("ink", 1)))
    return ui.stack({ key = "title-" .. spec.key, align = "topLeading", w = 30 * cu, h = 17 * cu,
        dx = g.pill.cx - 15 * cu, dy = g.frame.lv.mid - spec.side * 17 * cu - 8.5 * cu,
        cursor = "pointer", onClick = spec.command, onHover = buttons.hover(spec.key, true), ui.stack(icon),
    })
end

local function vertical(ctx, g)
    local bu, bz = g.k.bu, g.k.bz
    local m, lv = metrics(ctx, g.k), g.frame.lv
    local hovered = if ctx.state.barHot == "title" then 1 else 0
    local items = {}
    local function rotated(key, value, size, weight, opacity, x)
        if value == "" then return nil end
        return ui.text({ key = key, text = value, font = kit.font, size = size * bz, weight = weight,
            color = palette.roles.ink, opacity = opacity, maxWidth = lv.span, lines = 1, rotate = -90,
            decorative = true, align = "center", dx = x - g.size.w / 2, dy = lv.tm - g.size.h / 2,
            shadow = shadow, shadowRadius = 3, shadowOffset = lift })
    end
    items[#items + 1] = rotated("title-app", m.app, 15, "semibold", 0.55, g.pill.cx - 7.5 * bu)
    items[#items + 1] = rotated("title-text", m.title, 14, "medium", 1, g.pill.cx + 8 * bu)
    if math.max(m.cw, m.tw) < 1 and not ctx.data.media then
        for index = -1, 1 do
            items[#items + 1] = ui.box({ key = "title-dot-" .. index + 2, decorative = true, align = "topLeading",
                dx = g.pill.cx - 1.9 * bu, dy = lv.tm + index * 8 * bu - 1.9 * bu,
                w = 3.8 * bu, h = 3.8 * bu, radius = 1.9 * bu, fill = palette.roles.faint,
                opacity = 0.7 + 0.3 * hovered, animate = buttons.touch })
        end
    end
    items[#items + 1] = ui.stack({ key = "title-button", align = "topLeading",
        dx = g.pill.x + 3 * bu, dy = lv.tm - lv.span / 2, w = g.pill.w - 6 * bu, h = math.max(1, lv.span),
        cursor = "pointer", onClick = "shell trigger vitreus drawer-player " .. ctx.data.bar.monitorId,
        onHover = buttons.hover("title") })
    if ctx.data.media then
        for _, spec in transport do items[#items + 1] = verticalControl(ctx, spec, g) end
    end
    return items
end

local function content(ctx, g, slot)
    if g.frame and g.frame.vertical then return vertical(ctx, g) end
    local k = g.k
    local bu, bz = k.bu, k.bz
    local pill = g.pill
    local p = place(ctx, g, slot)
    local m = p.m
    local ox = if slot.x <= pill.left + 0.001 then pill.x else slot.x - pill.gap / 2
    local oy = pill.y
    local hovered = if ctx.state.barHot == "title" then 1 else 0
    local region = {
        key = "title-region", align = "topLeading", dx = ox, dy = oy, w = pill.x + pill.w - ox, h = pill.h,
        onHover = buttons.hover("bar"),
    }
    local faint = palette.alpha("faint", 1)
    region[#region + 1] = text("title-app", m.app, 17 * bz, "semibold", faint, 0.55,
        p.hw - 12 * bu - p.control, round(p.xs) - ox, round(pill.cy - 6.5 * bu) - oy, m.ch)
    region[#region + 1] = text("title-text", m.title, 13.5 * bz, "medium", palette.alpha("ink", 1), 1,
        p.hw - 12 * bu, round(p.xs) - ox, round(pill.cy + 8.75 * bu) - oy, m.th)
    local dots = (1 - p.have) * (1 - p.shown)
    if dots > 0 then
        for index = -1, 1 do
            region[#region + 1] = ui.box({
                key = "title-dot-" .. index + 2, decorative = true, align = "topLeading",
                dx = p.zc + index * 8 * bu - 1.9 * bu - ox, dy = pill.cy - 1.9 * bu - oy, w = 3.8 * bu, h = 3.8 * bu,
                radius = 1.9 * bu, fill = faint, opacity = (0.7 + 0.3 * hovered) * dots, animate = buttons.touch,
            })
        end
    end
    region[#region + 1] = ui.stack({
        key = "title-button", align = "topLeading", dx = p.zc - p.zw / 2 - ox, dy = 0, w = p.zw, h = pill.h,
        cursor = "pointer", onClick = "shell trigger vitreus drawer-player " .. ctx.data.bar.monitorId,
        onHover = buttons.hover("title"),
    })
    if p.media then
        for _, spec in transport do
            region[#region + 1] = control(ctx, spec, p, bu, ox, oy)
        end
    end
    return { ui.stack(region) }
end

return table.freeze({ shapes = shapes, content = content, metrics = metrics, least = least, minimum = minimum, player = player })

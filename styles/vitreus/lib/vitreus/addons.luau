-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("./kit")
local palette = require("./palette")
local pencil = require("./pencil")
local buttons = require("./bar/buttons")
local docks = require("./docks")

local drip = kit.springs.drip
local follow = docks.spring(300, 20)
local corners = table.freeze({ { "nw", 0, 0 }, { "ne", 1, 0 }, { "sw", 0, 1 }, { "se", 1, 1 } })
local steps = table.freeze({ 0, 0.0625, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1, 1.125, 1.25 })

local function lift(at: number): number
    return math.min(1, 1.6 * at) + math.max(0, at - 1) * 0.6
end

local function bell(at: number): number
    local p = math.min(1, at)
    return 4 * p * (1 - p)
end

local function morph(anchor, glass: boolean)
    local stops = table.create(#steps)
    for index, at in steps do
        stops[index] = if glass
            then { at = at, scale = lift(at), w = 1 - 0.07 * bell(at), round = math.clamp(1.6 * at - 0.1, 0, 1) }
            else { at = at, scale = math.max(lift(at), 0.05), opacity = math.clamp(2 * at - 1, 0, 1) }
    end
    return { anchor = anchor, stops = stops }
end

local function list(ctx)
    local icons, installed = {}, {}
    for _, entry in ctx.data.catalog or {} do
        if table.find(entry.views or {}, "addon") then icons[entry.widget] = entry.icon end
    end
    for _, info in ctx.data.components or {} do
        installed[info.id] = info
    end
    local result, seen = {}, {}
    for _, id in docks.listed(ctx.data.settings, "addons") do
        local info = installed[id]
        if #result < 12 and info and not seen[id] and info.enabled and not info.error and icons[info.widget] then
            seen[id] = true
            result[#result + 1] = { id = id, title = info.title, icon = icons[info.widget], index = #result }
        end
    end
    return result
end

local function close(state)
    state.addonOpen = nil
    state.addonPlace = nil
    state.addonHeld = nil
end

local function toggle(next, id: string)
    local state = next.state
    if state.addonOpen == id then
        close(state)
        return
    end
    state.addonOpen = id
    state.addonHeld = nil
    omniwm.run("shell trigger vitreus addon-opened " .. next.data.bar.monitorId)
end

local function home(p, w: number, h: number): (number, number)
    local a = p.area
    return if p.ax > 0 then a.xe - w else a.xs, if p.ay > 0 then a.ye - h else a.yt
end

local function fraction(value: number, low: number, span: number): number
    return math.clamp((value - low) / span, 0, 1)
end

local function panel(ctx, g, addons, p)
    local addon
    for _, entry in addons do
        if entry.id == ctx.state.addonOpen then addon = entry end
    end
    if not addon then return nil end
    local k, a = g.k, p.area
    local cu = k.cu
    local size = (ctx.state.addonSizes or {})[addon.id] or {}
    local w = math.clamp(size.w or 300 * cu, 240, math.max(240, a.xe - a.xs))
    local h = math.clamp(size.h or 280 * cu, 160, math.max(160, a.ye - a.yt))
    local hx, hy = home(p, w, h)
    local place = ctx.state.addonPlace
    local x = math.max(a.xs, math.min(hx + (if place then place.dx else 0), a.xe - w))
    local y = math.max(a.yt, math.min(hy + (if place then place.dy else 0), a.ye - h))
    local held = ctx.state.addonHeld == true
    local function near(gap: number, reach: number): number
        return if held then 0 else math.clamp(1 - (gap - 14 * cu) / (50 * cu), 0, 1) * math.max(0, reach + 26 * cu)
    end
    local left, right = near(x - a.xs, x), near(a.xe - x - w, g.size.w - x - w)
    local top, bottom = near(y - a.yt, y), near(a.ye - y - h, g.size.h - y - h)
    local shape = { x = x - left, y = y - top, w = w + left + right, h = h + top + bottom }
    local t, margin, bar = 34 * k.bu, 14 * cu, 38 * cu
    local above = if not p.vertical and p.ay < 0 then math.max(bar, t) else bar
    local below = if not p.vertical and p.ay > 0 then t else 0
    local beside = if p.vertical then t else 0
    local clear = if p.vertical and p.ay < 0 then t else 0
    return {
        addon = addon, x = x, y = y, w = w, h = h, hx = hx, hy = hy, shape = shape, clear = clear,
        xl = if p.ax < 0 then clear else 0, xr = if p.ax > 0 then clear else 0,
        bounds = { x = a.xs, y = a.yt, w = a.xe - a.xs, h = a.ye - a.yt },
        content = { x = margin + (if p.ax < 0 then beside else 0), y = above,
            w = w - 2 * margin - beside, h = h - above - below - margin },
        glass = { x = fraction(p.cx, shape.x, shape.w), y = fraction(p.cy, shape.y, shape.h) },
        inner = { x = fraction(p.cx, x, w), y = fraction(p.cy, y, h) },
    }
end

local function release(d, p, resizing: boolean)
    return function(next, event)
        local state, phase, rect = next.state, event.phase, event.rect
        if phase == "began" then
            state.addonHeld = true
            return
        end
        if phase ~= "ended" and phase ~= "cancelled" then return end
        state.addonHeld = nil
        if phase == "cancelled" or not rect then return end
        local hx, hy = d.hx, d.hy
        if resizing then
            local sizes = state.addonSizes or {}
            sizes[d.addon.id] = { w = rect.w, h = rect.h }
            state.addonSizes = sizes
            hx, hy = home(p, rect.w, rect.h)
        end
        local dx, dy = rect.x - hx, rect.y - hy
        state.addonPlace = if math.sqrt(dx * dx + dy * dy) < (if resizing then 0.5 else 60) then nil else { dx = dx, dy = dy }
        state.addonCommit = event.transaction
    end
end

local function pin(ctx, g, addon, slot, size: number, held: boolean)
    local bu = g.k.bu
    local key = "addon-pin-" .. addon.id
    local a, fr = buttons.sketch(ctx, key)
    if held then a = 0 end
    local i, jitter = addon.index, 0.7 * bu * a
    local function pass(x: number, y: number, opacity: number)
        return ui.symbol({
            decorative = true, align = "topLeading", dx = 3.5 * bu + x, dy = 4.5 * bu + y, w = size, h = size,
            name = addon.icon, size = 0.8 * size, color = "foreground", opacity = opacity,
        })
    end
    return ui.stack({
        key = key, align = "topLeading", dx = slot.x - 3.5 * bu, dy = slot.y - 4.5 * bu, w = 31 * bu, h = 33 * bu,
        cursor = "pointer", onHover = buttons.hover(key, true), onClick = function(next) toggle(next, addon.id) end,
        ui.box({
            key = key .. "-plate", decorative = true, w = 33 * bu, h = 33 * bu, radius = 10 * bu,
            fill = palette.alpha("ink", 0.16), opacity = a, animate = buttons.touch,
        }),
        ui.stack(buttons.glow({
            key = key .. "-icon", decorative = true, w = 31 * bu, h = 33 * bu, scale = 1 + 0.16 * a, animate = buttons.touch,
            pass(jitter * pencil.wave(fr, 61, i * 50), jitter * pencil.wave(fr, 67, i * 30), 0.88 + 0.12 * a),
            pass(1.1 * bu + jitter * pencil.wave(fr, 47, i * 70), -0.8 * bu + jitter * pencil.wave(fr, 43, i * 110),
                0.12 + 0.24 * a),
        }, bu)),
    })
end

local function drawer(ctx, g, d, p)
    local k = g.k
    local cu = k.cu
    local c = kit.canvas(d.w, d.h, cu, k.rs)
    local function track(spec)
        spec.target = "addon-drawer"
        spec.bounds = d.bounds
        return { axis = "free", threshold = 1, track = spec }
    end
    local items = {
        ui.component({
            id = d.addon.id, view = "addon", align = "topLeading", dx = d.content.x, dy = d.content.y,
            w = d.content.w, h = d.content.h, props = { u = k.u, cu = cu, rs = k.rs },
        }),
        kit.label(c, {
            key = "addon-title", text = d.addon.title, x = 26 * cu + d.xl, y = 24 * cu, align = "leading", size = 20,
            weight = "bold", maxWidth = d.w - 90 - d.clear, lines = 1,
        }),
        kit.zone(c, {
            key = "addon-grip", x = d.w / 2 - 20 + (d.xl - d.xr) / 2, y = 22 * cu, w = d.w - 74 - d.xl - d.xr,
            h = 44 * cu, rest = if ctx.state.addonHeld then 0.55 else 0.2, hover = 0.55, cursor = "pointer",
            gesture = track({ mode = "move", min = { w = d.w, h = d.h }, max = { w = d.w, h = d.h } }),
            onGesture = release(d, p, false),
            ui.box({
                dx = 20 - (d.xl - d.xr) / 2, dy = -11 * cu, w = 34 * cu, h = 4 * cu, radius = 2 * cu,
                fill = palette.alpha("ink", 0.55),
            }),
        }),
    }
    for _, corner in corners do
        items[#items + 1] = kit.zone(c, {
            key = "addon-resize-" .. corner[1], x = if corner[2] == 1 then d.w - 14 * cu else 14 * cu,
            y = if corner[3] == 1 then d.h - 14 * cu else 14 * cu, w = 28 * cu, h = 28 * cu, cursor = "grab",
            gesture = track({
                mode = "resize", edge = corner[1], min = { w = 240, h = 160 }, max = { w = d.bounds.w, h = d.bounds.h },
                outline = false,
            }),
            onGesture = release(d, p, true),
        })
    end
    local button = kit.canvas(28 * cu, 28 * cu, cu, k.rs)
    items[#items + 1] = kit.zone(c, {
        key = "addon-close", x = d.w - 28 * cu - d.xr, y = 24 * cu, w = 28 * cu, h = 28 * cu, rest = 0.7, hover = 1,
        cursor = "pointer", onClick = function(next) close(next.state) end,
        ui.box({
            w = 26 * cu, h = 26 * cu, radius = 13 * cu, fill = palette.alpha("ink", 0.08 / 0.7),
            hover = palette.alpha("ink", 0.2),
        }),
        kit.stroke(button, kit.cross(14 * cu, 14 * cu, 3.4 * cu), "foreground", 1.5 * cu),
    })
    local inner = { key = "addon-drawer-reveal", w = d.w, h = d.h, morph = morph(d.inner, false) }
    for index, item in items do
        inner[index] = item
    end
    return ui.stack({
        key = "addon-drawer", align = "topLeading", dx = d.x, dy = d.y, w = d.w, h = d.h,
        reveal = drip, manipulationFollow = follow, manipulationCommit = ctx.state.addonCommit,
        ui.stack(inner),
    })
end

local function shapes(ctx, g, budget: number?)
    local room = budget or 2
    if room < 1 or not docks.shown(ctx) then return nil end
    local addons = list(ctx)
    if #addons == 0 then return nil end
    local p = docks.pill(g, #addons, 1 - docks.side(ctx), ctx.state.addonPillHeld)
    local d = if room >= 2 then panel(ctx, g, addons, p) else nil
    local result = {}
    if d then
        result[1] = ui.shape({
            key = "addon-drawer-glass", follow = "addon-drawer", align = "topLeading", dx = d.shape.x, dy = d.shape.y,
            w = d.shape.w, h = d.shape.h, radius = 26 * g.k.u, animate = g.calm, reveal = drip, morph = morph(d.glass, true),
        })
    end
    result[#result + 1] = docks.glass(g, p, "addon-pill")
    return result
end

local function content(ctx, g)
    local addons = if docks.shown(ctx) then list(ctx) else {}
    local held = ctx.state.addonPillHeld == true
    local p = if #addons > 0 then docks.pill(g, #addons, 1 - docks.side(ctx), held) else nil
    local d = if p then panel(ctx, g, addons, p) else nil
    if not d and ctx.state.addonOpen then close(ctx.state) end
    if not p then return nil end
    local places, size = docks.slots(g, p, #addons)
    local items = {}
    for index, addon in addons do
        items[index] = pin(ctx, g, addon, places[index], size, held)
    end
    local pill = docks.frame(g, p, "addon-pill", ctx.state.addonPillCommit,
        docks.drag(g, "addonPillCommit", "addonPillHeld", true), items)
    return if d then { drawer(ctx, g, d, p), pill } else { pill }
end

local function trigger(ctx, event)
    if event.name == "addon-opened" and event.value ~= (ctx.data.bar and ctx.data.bar.monitorId) then close(ctx.state) end
end

return table.freeze({ shapes = shapes, content = content, trigger = trigger })

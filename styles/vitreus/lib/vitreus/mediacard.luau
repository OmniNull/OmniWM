-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("./kit")
local palette = require("./palette")
local units = require("./units")
local media = require("./media")
local drawer = require("./drawer")
local windows = require("./windows")
local cards = require("./cards")

local drip = kit.springs.drip
local carry = kit.springs.desk
local rise = table.freeze({ response = 2 * math.pi * 0.52 / 6.64, bounce = 0 })
local flick = table.freeze({ response = 2 * math.pi * 0.016 / 6.64, bounce = 0 })
local settle = table.freeze({ response = 2 * math.pi * 0.7 / 6.64, bounce = 0 })
local corners = table.freeze({ { "nw", -1, -1 }, { "ne", 1, -1 }, { "sw", -1, 1 }, { "se", 1, 1 } })
local grow = table.freeze({ stops = table.freeze({
    table.freeze({ at = -0.5, scale = 0 }), table.freeze({ at = 0, scale = 0 }),
    table.freeze({ at = 1, scale = 1 }), table.freeze({ at = 1.5, scale = 1 }),
}) })

local function lift(at: number): number
    return math.min(1, 1.6 * at) + math.max(0, at - 1) * 0.6
end

local function swing()
    local rotate, scale = table.create(96), table.create(96)
    local from, velocity = kit.springState(flick, 1, 0, 0.03, 0)
    for index = 1, 95 do
        local elapsed = 0.73 * (index - 1) / 95
        local swap = if elapsed < 0.03 then kit.springState(flick, 1, 0, elapsed, 0)
            else kit.springState(settle, from, velocity, elapsed - 0.03, 1)
        rotate[index], scale[index] = -12 * (1 - swap), -0.3 * (1 - swap)
    end
    rotate[96], scale[96] = 0, 0
    return table.freeze(rotate), table.freeze(scale)
end

local swapRotate, swapScale = swing()

local function placement(ctx, g)
    if not g.island or not ctx.data.media then return nil end
    if not g.frame then
        local spec = cards.entry(ctx, "player-album")
        if not spec or not spec.shown then return nil end
        local p, item = spec.panel, cards.record(ctx, "player-album")
        return { out = item.location ~= "home" or item.held == true, s = p.cu / g.k.bcu,
            base = g.k.bcu, cu = p.cu, rs = p.rs, w = p.w, h = p.h, bounds = g.room,
            x = p.x, y = p.y, panel = spec.parent, contract = p,
            clip = if spec.nested and not item.held then { x = (spec.parent.bodyX or spec.parent.x) - p.x,
                y = (spec.parent.bodyY or spec.parent.top) - p.y, w = spec.parent.bodyW or spec.parent.w, h = spec.parent.bodyH } else nil }
    end
    local cu = g.k.bcu
    local bounds = units.desk(g.island, nil, nil, g.frame).bounds
    local item = cards.record(ctx, "player-album")
    local card = if item.location ~= "home" and item.location ~= "drawer" and item.rect then
        { x = item.rect.x, y = item.rect.y, s = item.scale } else nil
    if card then
        local s = math.clamp(card.s or 1, 0.5, 1.6)
        local w, h = 308 * cu * s, 168 * cu * s
        return { out = true, s = s, base = cu, cu = cu * s, rs = cu * s / units.cu, w = w, h = h, bounds = bounds,
            x = math.clamp(card.x, bounds.x, math.max(bounds.x, bounds.x + bounds.w - w)),
            y = math.clamp(card.y, bounds.y, math.max(bounds.y, bounds.y + bounds.h - h)) }
    end
    if not windows.visible(ctx, "player") or windows.held(ctx, "player") then return nil end
    local panel = drawer.geometry(ctx, g, "player")
    if not panel then return nil end
    cu = panel.cu
    local x, y = panel.x + panel.w / 2 - 154 * cu, panel.y + (panel.header or 0) - 2 * cu
    return { out = false, s = 1, base = cu, cu = cu, rs = cu / units.cu, w = 308 * cu, h = 168 * cu, bounds = bounds,
        x = x, y = y, panel = panel,
        clip = { x = (panel.bodyX or panel.x) - x, y = (panel.bodyY or panel.top) - y,
            w = panel.bodyW or panel.w, h = panel.bodyH } }
end

local function docking(ctx, g, rect, grab): boolean
    if not windows.visible(ctx, "player") or not g.pill then return false end
    local panel = drawer.geometry(ctx, g, "player")
    if not panel then return false end
    local x = rect.x + (if grab then grab.x else rect.w / 2)
    local y = rect.y + (if grab then grab.y else rect.h / 2)
    if panel.frame then
        return x >= panel.bodyX and x <= panel.bodyX + panel.bodyW
            and y >= panel.bodyY and y <= panel.bodyY + panel.bodyH
    end
    return x >= panel.x and x <= panel.x + panel.w
        and y >= (if panel.loose then panel.y else g.pill.y) and y <= panel.y + panel.h
end

local function observe(ctx, shown: boolean)
    local state, m = ctx.state, ctx.data.media
    local identity = if m then table.concat({ m.bundle, m.title, m.artist }, "\0") else nil
    if identity == state.mediaTrack then return end
    local bursts = state.mediaBursts or {}
    local swaps = identity ~= nil and state.mediaTrack ~= nil and shown
    while #bursts > (if swaps then 1 else 0) do
        table.remove(bursts, 1).timer:cancel()
    end
    if swaps then
        local entry = { serial = (state.mediaSwaps or 0) + 1 }
        state.mediaSwaps = entry.serial
        entry.timer = omniwm.after(1.1, function()
            local index = table.find(bursts, entry)
            if index then table.remove(bursts, index) end
        end)
        if entry.timer then bursts[#bursts + 1] = entry end
    end
    state.mediaBursts = bursts
    state.mediaTrack = identity
end

local function moved(g)
    return function(next, event)
        local state, phase, rect = next.state, event.phase, event.rect
        if not g.frame then
            local item = cards.record(next, "player-album")
            if phase == "ended" or phase == "cancelled" then
                item.held, state.mediaCardHeld, state.mediaCardGrab = nil, nil, nil
                if phase == "cancelled" or not rect then item.grab = nil return end
            end
            local spec = cards.entry(next, "player-album")
            if not spec then item.grab = nil return end
            local p = spec.panel
            if phase == "began" then
                item.held, item.scale, state.mediaCardHeld = true, p.cardScale, true
                local grab = state.mediaCardGrab
                item.grab = { x = (grab and grab.x or p.w / 2) / p.w, y = (grab and grab.y or p.h / 2) / p.h }
                return
            end
            if phase ~= "ended" and phase ~= "cancelled" then return end
            local drop = table.clone(event)
            drop.x, drop.y = (event.x or p.w / 2) + 10 * p.cu, (event.y or p.h / 2) + 10 * p.cu
            local grab = item.grab and { x = item.grab.x * rect.w, y = item.grab.y * rect.h }
            if docking(next, g, rect, grab) then item.location, item.rect, item.side = "home", nil, nil
            else windows.resolve(item, drop, p, p.w) end
            item.grab = nil
            p.onRelease(item, event)
            item.commit = event.transaction
            return
        end
        if phase == "began" then
            state.mediaCardHeld = true
            local item = cards.record(next, "player-album")
            if item.location == "home" and rect then
                item.location, item.rect, item.scale = "floating", { x = rect.x, y = rect.y }, math.clamp(rect.w / (308 * g.k.bcu), 0.5, 1.6)
            end
            return
        end
        if phase ~= "ended" and phase ~= "cancelled" then return end
        local grab = state.mediaCardGrab
        state.mediaCardHeld, state.mediaCardGrab = nil, nil
        if phase == "cancelled" or not rect then return end
        local item = cards.record(next, "player-album")
        if docking(next, g, rect, grab) then cards.home(next, "player-album", event.transaction)
        else item.location, item.rect, item.commit = "floating", { x = rect.x, y = rect.y }, event.transaction end
    end
end

local function scaled(base: number)
    return function(next, event)
        local rect = event.rect
        if event.phase ~= "ended" or not rect then return end
        local item = cards.record(next, "player-album")
        item.rect, item.scale, item.commit = { x = rect.x, y = rect.y }, math.clamp(rect.w / base, 0.5, 1.6), event.transaction
    end
end

local function pinned(next)
    local state, bar = next.state, next.data.bar
    state.mediaCardPins = (state.mediaCardPins or 0) + 1
    if windows.stored(next, "player") then windows.redock(next, "player") end
    cards.home(next, "player-album", "pin-" .. state.mediaCardPins)
    if not windows.visible(next, "player") and bar then drawer.open(next, "player") end
end

local function pressed(inset: number)
    return function(next, event)
        if event.phase == "down" then
            next.state.mediaCardGrab = { x = inset + (event.x or 0), y = inset + (event.y or 0) }
        elseif event.phase == "up" then
            next.state.mediaCardGrab = nil
        end
    end
end

local function hovered(next, event)
    next.state.mediaCardHot = event.phase == "began"
end

local function cover(playing: boolean, swap)
    return function(c, m, key)
        local size = 72 * c.du
        return ui.stack(kit.at(c, { key = key .. "-cover", w = size, h = size,
            pulse = if swap then { key = swap.serial, duration = 0.73, rotate = swapRotate, scale = swapScale } else nil,
            ui.stack({ key = key .. "-cover-fx", w = size, h = size,
                effect = { source = "vitreus-cover.metal", fps = 0, bleed = 12 * c.du,
                    values = { if playing then 1 else 0.3, 12 * c.du, 0.6 } },
                ui.image({ key = key .. "-art-" .. m.artwork, image = m.artwork, w = size, h = size, radius = 15 * c.du }),
            }),
        }, 48 * c.du, 50 * c.du))
    end
end

local function wave(playing: boolean)
    return function(c, key: string, width: number, hot: boolean, live: boolean)
        return ui.shader({ key = key .. "-seek-wave", source = "vitreus-seek.metal", decorative = true,
            fps = if playing then 60 else 0, values = { c.du, width, if hot then 1 else 0, if live then 1 else 0 },
            align = "topLeading", dx = 44 * c.du, dy = 124 * c.du, w = 200 * c.du, h = 20 * c.du })
    end
end

local function handles(c, place)
    local items, cu, base, bounds = {}, place.cu, place.base, place.bounds
    for _, corner in corners do
        items[#items + 1] = kit.zone(c, {
            key = "media-card-resize-" .. corner[1], x = place.w / 2 + corner[2] * 140 * cu,
            y = place.h / 2 + corner[3] * 70 * cu, w = 28 * cu, h = 28 * cu, cursor = "grab",
            gesture = { axis = "free", threshold = 1, track = {
                mode = "scale", target = "media-card", edge = corner[1], bounds = bounds,
                min = { w = 154 * base, h = 84 * base },
                max = { w = math.min(492.8 * base, bounds.w), h = math.min(268.8 * base, bounds.h) },
            } },
            onGesture = scaled(308 * base),
        })
    end
    return items
end

local function pin(c, place)
    local cu = place.cu
    local glyph = kit.canvas(20 * cu, 20 * cu, cu, place.rs)
    local stem = string.format(" M %.3f %.3f L %.3f %.3f", 10 * cu, 10.6 * cu, 10 * cu, 15 * cu)
    return ui.stack(kit.at(c, { key = "media-card-pin", w = 20 * cu, h = 20 * cu, cursor = "pointer",
        opacity = 0.7, hoverOpacity = 1, hoverAnimate = kit.hover, onClick = pinned,
        appear = { opacity = 0, animate = drip }, exit = { opacity = 0, animate = drip },
        ui.box({ w = 16 * cu, h = 16 * cu, radius = 8 * cu, fill = palette.alpha("ink", 0.08 / 0.7),
            hover = palette.alpha("ink", 0.22) }),
        kit.stroke(glyph, kit.circle(10 * cu, 8 * cu, 2.6 * cu) .. stem, palette.roles.ink, 1.2 * cu),
    }, 282 * cu, 21 * cu))
end

local function grip(c, place, hot: boolean)
    local cu = place.cu
    return ui.box(kit.at(c, { key = "media-card-grip", decorative = true, w = 34 * cu, h = 4 * cu, radius = 2 * cu,
        fill = palette.roles.ink, opacity = if hot then 0.55 else 0.2,
        appear = { opacity = 0, animate = drip }, exit = { opacity = 0, animate = drip },
    }, 154 * cu, 15 * cu))
end

local function sparks(c, g, place, bursts)
    local clip = place.clip
    local items = { key = "media-card-sparks", decorative = true, w = place.w, h = place.h }
    if clip then
        items[#items + 1] = ui.path({ key = "media-card-sparks-clip", mask = true, align = "topLeading",
            dx = clip.x, dy = clip.y, w = clip.w, h = clip.h, d = drawer.outline(g, clip.w, clip.h) })
    end
    for _, swap in bursts do
        items[#items + 1] = ui.shader(kit.at(c, { key = "media-card-sparks-" .. swap.serial,
            source = "vitreus-sparks.metal", decorative = true, fps = 60, values = { place.rs, swap.serial },
            w = 260 * place.rs, h = 260 * place.rs }, 58 * place.cu, 60 * place.cu))
    end
    return ui.stack(items)
end

local function docked(cu: number, rest: boolean, header: number)
    local stops = {}
    for index, at in { 0, 0.03125, 0.625, 1, 1.5 } do
        local scale = math.max(lift(at), 0.05)
        stops[index] = { at = at, scale = scale,
            dy = (2 * cu - header) * (1 - scale) - (if rest then 125 * cu * (1 - at) else 0) }
    end
    return { anchor = { x = 0.5, y = 0 }, stops = stops }
end

local function grabArea(ctx, g, place, swap)
    local m, cu, out = ctx.data.media, place.cu, place.out
    local size = { w = place.w, h = place.h }
    return ui.stack({ key = "media-card-grab", w = 288 * cu, h = 148 * cu, cursor = "grab",
        gesture = { axis = "free", threshold = if out then 4 else 16 * cu, track = {
            mode = "move", target = "media-card",
            bounds = if g.frame then place.bounds else { x = -place.w, y = -place.h, w = g.size.w + 2 * place.w, h = g.size.h + 2 * place.h },
            min = size, max = size,
        } },
        onGesture = moved(g), onPress = pressed(10 * cu), onHover = if out then hovered else nil,
        media.plate(ctx, { key = "player-media", cu = cu, rs = place.rs, veil = if out then 0 else 1,
            veilMotion = drip, cover = cover(m.playing, swap), wave = wave(m.playing) }),
    })
end

local function card(ctx, g, place)
    local state = ctx.state
    local cu, out, bursts = place.cu, place.out, state.mediaBursts or {}
    local c = kit.canvas(place.w, place.h, cu, place.rs)
    local body = { w = place.w, h = place.h, grabArea(ctx, g, place, bursts[#bursts]) }
    if out then
        for _, item in handles(c, place) do body[#body + 1] = item end
        body[#body + 1] = pin(c, place)
        body[#body + 1] = grip(c, place, state.mediaCardHeld == true or state.mediaCardHot == true)
    end
    if #bursts > 0 then body[#body + 1] = sparks(c, g, place, bursts) end
    return ui.stack({
        key = "media-card", align = "topLeading", dx = place.x, dy = place.y, w = place.w, h = place.h,
        reveal = if place.panel and place.panel.frame then
            { response = drip.response, bounce = drip.bounce, delay = place.panel.delay } else drip,
        manipulationFollow = carry, manipulationCommit = cards.record(ctx, "player-album").commit,
        ui.stack({ key = "media-card-dock", w = place.w, h = place.h,
            morph = if out or place.panel.loose then nil elseif place.panel.frame then drawer.contentMorph(ctx, place.panel, place)
                else docked(cu, state.drawerRest == true, place.panel.header or 0),
            ui.stack({ key = "media-card-rise", w = place.w, h = place.h,
                appear = if out then { opacity = 0, animate = drip }
                    else { opacity = 0, dy = 12 * cu, delay = 0.2 + (if place.panel.frame then place.panel.wait else 0), animate = rise },
                exit = if out then { opacity = 0, animate = drip }
                    else { opacity = 0, dy = 12 * cu, animate = kit.springs.close },
                ui.stack(body),
            }),
        }),
    })
end

local function frameShape(g, place)
    local binding, reach = units.edgeSource(g, "media-card", g.k.u, {})
    return ui.shape({
        key = "media-card-glass", align = "topLeading", dx = -reach, dy = -reach,
        w = g.size.w + 2 * reach, h = g.size.h + 2 * reach, radius = 26 * place.cu, reveal = drip,
        morph = { source = binding, stops = { { at = 0 }, { at = 1 } } },
    })
end

local function shapes(ctx, g, budget: number?)
    if not g.frame then return cards.shapes(ctx, g, budget, "player-album") end
    if (budget or 1) < 1 then return nil end
    local place = placement(ctx, g)
    if not place or not place.out then return nil end
    return { frameShape(g, place) }
end

local function content(ctx, g)
    if not g.island then return nil end
    local place = placement(ctx, g)
    if not g.frame then observe(ctx, place ~= nil) return nil end
    observe(ctx, place ~= nil)
    if not place then return nil end
    return { card(ctx, g, place) }
end

local function section(ctx, g, panel)
    return { id = "player-album", target = "media-card", shapeKey = "media-card-glass", ownMorph = true, ownClip = true, radius = 26, fixed = true, morph = grow, x = 10, y = (panel.header or 0) / panel.cu - 2, w = 308, h = 168,
        content = function(next, p)
            local place = placement(next, g)
            observe(next, place ~= nil)
            if not place then return { ui.text({ text = "No music is playing. Start a song to show its album here.",
                font = kit.font, size = 13 * p.rs, color = palette.roles.faint, maxWidth = p.w - 32 * p.cu,
                w = p.w - 32 * p.cu, lines = 3 }) } end
            return { card(next, g, place)[1] }
        end }
end

return table.freeze({ shapes = shapes, content = content, section = section })

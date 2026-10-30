-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local u = 1.35
local cu = 1.5525
local inset = 6.5 / 353
local edge = 8

local function zoom(size: number?): number
    local value = if type(size) == "number" and size == size then size else 1
    return math.floor(math.clamp(value, 0.7, 1) * 100 + 0.5) / 100
end

local function of(island, size: number?)
    local rs = math.clamp(island.size.h / 1350, 0.55, 1)
    local bz = zoom(size)
    return table.freeze({ u = u, cu = cu, rs = rs, du = cu * rs, bz = bz, bu = u * bz, bcu = cu * bz })
end

local function fit(value: number, low: number, high: number): number
    return math.max(low, math.min(value, high))
end

local function desk(island, given, place, frame)
    local base = given or of(island)
    local bu = base.du
    local size, usable = island.size, island.usableRect
    local inner = frame and frame.inner
    local right = if inner then inner.x + inner.w else math.min(size.w, usable.x + usable.w) - 7.5 * bu
    local low = if inner then inner.y else usable.y
    local high = if inner then inner.y + inner.h else usable.y + usable.h
    local top = math.max(low, math.min(size.h / 2 - 230 * bu, high - 460 * bu))
    local bounds = table.freeze(if inner then table.clone(inner)
        else { x = 8 * bu, y = 8 * bu, w = right - 14.5 * bu, h = size.h - 16 * bu })
    local hx, hy = right - (if frame then 340 else 346.5) * bu, top
    local s = fit(if place then place.s else 1, 0.5, 1)
    local x = fit(hx + (if place then place.dx else 0), bounds.x, bounds.x + bounds.w - 340 * bu * s)
    local y = fit(hy + (if place then place.dy else 0), bounds.y, bounds.y + bounds.h - 460 * bu * s)
    local du = bu * s
    local w, h = 353 * du, 460 * du
    local cx = w / 2
    return table.freeze({
        k = table.freeze({ u = u * s, cu = cu, rs = base.rs * s, du = du }),
        base = base,
        s = s,
        place = table.freeze({ dx = x - hx, dy = y - hy, s = s }),
        home = table.freeze({ x = right - (if frame then 340 else 353) * bu,
            y = top, w = (if frame then 340 else 353) * bu, h = 460 * bu }),
        bounds = bounds,
        framed = frame ~= nil,
        inset = if frame then 0 else inset,
        drawing = table.freeze({ x = if frame then -6.5 * du else 0, w = w }),
        envelope = table.freeze({ x = x - (if frame then 0 else 6.5 * du), y = y,
            w = if frame then 340 * du else w, h = h }),
        content = table.freeze({ x = 6.5 * du, y = 0, w = 340 * du, h = 460 * du }),
        clip = table.freeze({ x = 2 * s, y = 2 * s, w = w - 4 * s, h = h - 4 * s, radius = (26 * bu - 2) * s }),
        bodyRadius = 26 * u * s,
        cx = cx,
        grip = table.freeze({ x = cx, y = 11 * du, w = 34 * du, h = 4 * du, zoneW = 294 * du, zoneH = 22 * du }),
        tabs = table.freeze({ x = cx - 18 * du, y = 40 * du, w = 268 * du, h = 34 * du }),
        close = table.freeze({ x = cx + 143 * du, y = 40 * du, r = 13 * du, zone = 28 * du }),
    })
end

local function placed(g, rect)
    if g.framed then return { dx = rect.x - g.home.x, dy = rect.y - g.home.y, s = rect.w / g.home.w } end
    return { dx = rect.x + rect.w * inset - g.home.x - 6.5 * g.base.du, dy = rect.y - g.home.y, s = rect.w / g.home.w }
end

local function near(g, rect): boolean
    local reach = rect.x + rect.w * (1 - g.inset) - (g.home.x + g.home.w * (1 - g.inset))
    return math.sqrt(reach * reach + (rect.y - g.home.y) ^ 2) < 80 * g.base.du
end

local function edgeSource(g, target: string, unit: number, pads)
    local room = g.room
    local source = { target = target, edge = "right", from = g.size.w - room.x - room.w + 14 * unit,
        span = 50 * unit, pads = pads }
    if pads then
        source.adhere = { left = room.x + 14 * unit, top = room.y + 14 * unit,
            bottom = g.size.h - room.y - room.h + 14 * unit }
    end
    return source, 26 * unit
end

return table.freeze({ u = u, cu = cu, edge = edge, zoom = zoom, of = of, desk = desk, placed = placed, near = near,
    edgeSource = edgeSource })

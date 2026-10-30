-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("./kit")

local steps = table.freeze({ 0, 0.0625, 0.125, 1 / 6, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1 })
local retract = table.freeze({ 0, 0.125, 0.25, 0.375, 0.5, 0.625, 1 })
local ripple = table.freeze({ response = 2 * math.pi * 1.1 / 6.64, bounce = 0 })
local returnRipple = table.freeze({ response = 2 * math.pi * 0.6 / 6.64, bounce = 0 })
local stray = table.freeze({ response = 2 * math.pi * 0.7 / 6.64, bounce = 0 })
local sides = table.freeze({ "left", "right", "top", "bottom" })
local inward = table.freeze({ left = 1, right = -1, top = 1, bottom = -1 })

local function vertical(side: string): boolean
    return side == "left" or side == "right"
end

local function margins(g)
    local room = g.room
    return { left = room.x, right = g.size.w - room.x - room.w, top = room.y, bottom = g.size.h - room.y - room.h }
end

local function source(g, target: string, unit: number, side: string, pads)
    local away = margins(g)
    local value = { target = target, edge = side, from = away[side] + 14 * unit, span = 50 * unit, pads = pads }
    if pads then
        local adhere = {}
        for _, other in sides do
            if other ~= side then adhere[other] = away[other] + 14 * unit end
        end
        value.adhere = adhere
    end
    return value, 26 * unit
end

local function line(g, side: string): number
    local room = g.room
    return if side == "left" then room.x elseif side == "right" then room.x + room.w
        elseif side == "top" then room.y else room.y + room.h
end

local function key(prefix: string, side: string, name: string): string
    return prefix .. (if side == "right" then "" else "-" .. side) .. "-" .. name
end

local function centred(g, place, side: string, size: number, length: number?)
    local along, edge, rect = length or size, line(g, side), place.rect
    if vertical(side) then return edge - size / 2, rect.y + rect.h / 2 - along / 2, size, along end
    return rect.x + rect.w / 2 - along / 2, edge - size / 2, along, size
end

local function bound(g, place, side: string, target: string)
    local binding = source(g, target, place.du, side)
    binding.contact = true
    return binding
end

local function bulge(g, place, side: string, target: string, prefix: string, flared: boolean?)
    local u = g.k.u
    local rest = if flared then 0 else 0.3 / u / 30
    local normal = if vertical(side) then "w" else "h"
    local stops = table.create(#steps)
    for index, p in steps do
        local stop = { at = p }
        if p == 0 then
            stop.w, stop.h = rest, rest
        else
            stop[normal] = 24 * 4 * p * (1 - p) * (1 - 0.5 * p) / 30
        end
        stops[index] = stop
    end
    local function kick(at: number, rising: boolean, velocity: number)
        local impulse = { at = at, rising = rising, spring = kit.springs.splash, velocity = velocity, pivot = "centre" }
        impulse[normal] = 2 * u
        return impulse
    end
    local x, y, w, h = centred(g, place, side, 60 * u)
    return ui.shape({
        key = key(prefix, side, "bulge"), shape = "ellipse", align = "topLeading", hit = false,
        dx = x, dy = y, w = w, h = h, reveal = kit.springs.drip,
        morph = { source = bound(g, place, side, target), stops = stops,
            impulses = { kick(0.7, true, -280), kick(0.7, false, 80), kick(0.05, false, -200) } },
    })
end

local function crest(g, place, side: string, sign: number, returning: boolean, prefix: string)
    local u = g.k.u
    local normal, travel = if vertical(side) then "w" else "h", if vertical(side) then "dy" else "dx"
    local stops = table.create(#steps)
    for index, p in steps do
        local stop = { at = p }
        stop[normal] = if p == 0 or p == 1 then 0 else 20 * (1 - p) * math.min(6 * p, 1) / 9
        stop[travel] = sign * (12 + 90 * p) * u
        stops[index] = stop
    end
    local x, y, w, h = centred(g, place, side, 18 * u)
    return ui.shape({
        key = key(prefix, side, "ripple-" .. (if returning then "return-" else "break-") .. (if sign < 0 then "top" else "bottom")),
        shape = "ellipse", align = "topLeading", hit = false, dx = x, dy = y, w = w, h = h,
        reveal = if returning then returnRipple else ripple,
        morph = { trigger = { shape = key(prefix, side, "bulge"), at = if returning then 0.05 else 0.7,
            rising = not returning, contact = true }, stops = stops },
    })
end

local function drop(g, place, side: string, prefix: string)
    local u = g.k.u
    local shift = { at = 0.02 }
    shift[if vertical(side) then "dx" else "dy"] = inward[side] * 7 * u
    local x, y, w, h = centred(g, place, side, 20 * u)
    return ui.shape({
        key = key(prefix, side, "stray"), shape = "ellipse", align = "topLeading", hit = false,
        dx = x, dy = y, w = w, h = h, reveal = stray,
        morph = { trigger = { shape = key(prefix, side, "bulge"), at = 0.7, rising = true, contact = true },
            stops = { { at = 0, scale = 0 }, shift, { at = 1, scale = 0 } } },
    })
end

local function lip(g, place, side: string, target: string, prefix: string)
    local u = g.k.u
    local axis = if vertical(side) then "h" else "w"
    local stops = table.create(#retract)
    for index, p in retract do
        local stop = { at = p }
        stop[axis] = math.max(0, 1 - 1.6 * p) ^ 2
        stops[index] = stop
    end
    local along = (if vertical(side) then place.rect.h else place.rect.w) + 60 * u
    local x, y, w, h = centred(g, place, side, 6 * u, along)
    return ui.shape({
        key = key(prefix, side, "lip"), align = "topLeading", hit = false,
        dx = x, dy = y, w = w, h = h, radius = 3 * u, reveal = kit.springs.drip,
        morph = { source = bound(g, place, side, target), stops = stops },
    })
end

local function pieces(g, place, side: string, target: string, prefix: string, budget: number, flared: boolean?, resting: boolean?)
    if budget <= 0 then return {} end
    if resting then
        local items = { lip(g, place, side, target, prefix) }
        if budget > 1 then items[2] = bulge(g, place, side, target, prefix, true) end
        return items
    end
    local all = { bulge(g, place, side, target, prefix, flared),
        crest(g, place, side, -1, false, prefix), crest(g, place, side, 1, false, prefix), drop(g, place, side, prefix),
        crest(g, place, side, -1, true, prefix), crest(g, place, side, 1, true, prefix) }
    if flared then table.insert(all, 1, lip(g, place, side, target, prefix)) end
    local items = {}
    for _, shape in all do
        if #items < budget then items[#items + 1] = shape end
    end
    return items
end

local function nearest(rect, room, current: string?, reach: number): string?
    local away = { left = rect.x - room.x, right = room.x + room.w - rect.x - rect.w,
        top = rect.y - room.y, bottom = room.y + room.h - rect.y - rect.h }
    local best, gap = nil, math.huge
    for _, side in sides do
        if away[side] < gap then best, gap = side, away[side] end
    end
    if current and away[current] <= reach and away[current] <= gap + reach / 2 then return current end
    return if gap <= reach then best else nil
end

local function snap(rect, room, side: string)
    return {
        x = if side == "left" then room.x elseif side == "right" then room.x + room.w - rect.w
            else math.clamp(rect.x, room.x, math.max(room.x, room.x + room.w - rect.w)),
        y = if side == "top" then room.y elseif side == "bottom" then room.y + room.h - rect.h
            else math.clamp(rect.y, room.y, math.max(room.y, room.y + room.h - rect.h)),
    }
end

return table.freeze({ sides = sides, source = source, pieces = pieces, nearest = nearest, snap = snap })

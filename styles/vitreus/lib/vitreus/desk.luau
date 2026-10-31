-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("./palette")
local kit = require("./kit")
local units = require("./units")
local cards = require("./cards")

local order = table.freeze({ "desk-pad", "desk-shelf", "desk-clip", "desk-focus" })
local rank = {}
for index, widget in order do
    rank[widget] = index
end
table.freeze(rank)

local corners = table.freeze({ { "nw", -1, -1 }, { "ne", 1, -1 }, { "sw", -1, 1 }, { "se", 1, 1 } })

local function lift(at: number): number
    return math.min(1, 1.6 * at) + math.max(0, at - 1) * 0.6
end

local function bell(at: number): number
    local p = math.min(1, at)
    return 4 * p * (1 - p)
end

local stops = {}
for _, at in { 0, 0.0625, 0.125, 0.25, 0.375, 0.5, 0.625, 0.6875, 0.75, 0.875, 1, 1.25 } do
    stops[#stops + 1] = table.freeze({
        at = at, scale = lift(at), w = 1 - 0.07 * bell(at), h = 1, round = math.clamp(1.6 * at - 0.1, 0, 1),
    })
end
local shapeMorph = table.freeze({
    anchor = table.freeze({ x = 1, y = 0.5 }),
    stops = table.freeze(stops),
    stretch = table.freeze({ gain = 0.07, max = 0.5, w = 1, h = -0.5 }),
})
local contentMorph = table.freeze({
    anchor = table.freeze({ x = 1, y = 0.5 }),
    stops = table.freeze({
        { at = 0, scale = 0.05, opacity = 0 }, { at = 0.02, scale = 0.05, opacity = 0 },
        { at = 0.0201, scale = 0.05 }, { at = 0.03125, scale = 0.05 }, { at = 0.625 }, { at = 1 },
        { at = 1.25, scale = 1.15 },
    }),
})

local function pages(ctx)
    local tabs, failed = {}, {}
    for _, entry in ctx.data.components or {} do
        if entry.enabled and entry.error then
            failed[#failed + 1] = entry
        elseif entry.enabled and rank[entry.widget] then
            tabs[#tabs + 1] = entry
        end
    end
    table.sort(tabs, function(a, b) return rank[a.widget] < rank[b.widget] end)
    return tabs, failed
end

local function selection(ctx, tabs)
    local fallback
    for index, entry in tabs do
        if entry.id == ctx.state.tab then return index end
        if not fallback and entry.widget == "desk-focus" then fallback = index end
    end
    return fallback or (if #tabs > 0 then 1 else nil)
end

local function strip(c, g, tabs, selected)
    local du = c.du
    local track = g.tabs
    local count = #tabs
    local slot = if count > 0 then track.w / count else 0
    local items = { kit.plate(c, track.x, track.y, track.w, track.h, 17 * du, palette.veil) }
    for index = 1, count - 1 do
        items[#items + 1] = ui.box(kit.at(c, {
            w = du, h = 10 * du, radius = 0.5 * du, fill = palette.alpha("ink", 0.12),
        }, track.x - track.w / 2 + index * slot, track.y))
    end
    if selected then
        items[#items + 1] = kit.thumb(c, {
            key = "tab-thumb", x = track.x + (selected - 1 - (count - 1) / 2) * slot, y = track.y,
            w = slot - 8 * du, h = 26 * du, radius = 10 * du, glow = 10 * du,
        })
    end
    for index, entry in tabs do
        local chosen = index == selected
        local zone = kit.canvas(slot, track.h, du, c.rs)
        items[#items + 1] = kit.zone(c, {
            key = "tab-" .. entry.id,
            x = track.x + (index - 1 - (count - 1) / 2) * slot, y = track.y, w = slot, h = track.h,
            rest = if chosen then 1 else 0.62, hover = if chosen then 1 else 0.92, cursor = "pointer",
            animate = kit.springs.slide, hoverAnimate = kit.hover,
            onClick = function(next)
                next.state.tab = entry.id
                next.state.reveal = nil
            end,
            kit.label(zone, {
                text = entry.title, size = 12.5, weight = "semibold",
                color = if chosen then "border" else "foreground", opacity = if chosen then 1 else 0.92,
                animate = kit.springs.slide,
            }),
        })
    end
    return items
end

local function notices(c, g, tabs, failed)
    local du = c.du
    local lines = {}
    for index, entry in failed do
        lines[#lines + 1] = kit.label(c, {
            key = "failed-" .. entry.id, text = entry.title .. " could not load: " .. tostring(entry.error),
            x = g.cx, y = 72 * du + (index - 1) * 16 * du, size = 11, color = "error", opacity = 0.8,
            maxWidth = 300 * du, lines = 1,
        })
    end
    if #tabs == 0 then
        lines[#lines + 1] = kit.label(c, {
            key = "empty", text = "No pages to show", x = g.cx, y = c.h / 2, size = 13,
            color = "secondaryForeground", opacity = 0.8,
        })
    end
    return lines
end

local function close(c, g, display)
    local du = c.du
    local button = g.close
    local zone = kit.canvas(button.zone, button.zone, du, c.rs)
    return kit.zone(c, {
        key = "close", x = button.x, y = button.y, w = button.zone, h = button.zone, rest = 0.7, hover = 1,
        cursor = "pointer", onClick = "shell trigger vitreus desk-close " .. display,
        ui.box({
            w = 2 * button.r, h = 2 * button.r, radius = button.r,
            fill = palette.alpha("ink", 0.08 / 0.7), hover = palette.alpha("ink", 0.2),
        }),
        kit.stroke(zone, kit.cross(button.zone / 2, button.zone / 2, 3.4 * du), "foreground", 1.5 * du),
    })
end

local function commit(next, transaction: string, place)
    next.state.place = place
    next.state.commit = transaction
end

local function track(g, spec)
    spec.target = "desk"
    spec.inset = { x = g.inset, y = 0 }
    spec.bounds = g.bounds
    return { axis = "free", threshold = 1, track = spec }
end

local function grip(c, g, held: boolean)
    local du = c.du
    local size = { w = g.envelope.w, h = g.envelope.h }
    return kit.zone(c, {
        key = "grip", x = g.grip.x, y = g.grip.y, w = g.grip.zoneW, h = g.grip.zoneH,
        rest = if held then 0.55 else 0.2, hover = 0.55, cursor = "grab",
        gesture = track(g, { mode = "move", min = size, max = size }),
        onGesture = function(next, event)
            if event.phase == "began" then
                next.state.gripHeld = true
            elseif event.phase == "ended" then
                next.state.gripHeld = nil
                commit(next, event.transaction, if units.near(g, event.rect) then nil else units.placed(g, event.rect))
            elseif event.phase == "cancelled" then
                next.state.gripHeld = nil
            end
        end,
        onClick = function(next)
            if not next.state.place or not units.near(g, g.envelope) then return end
            next.state.snaps = (next.state.snaps or 0) + 1
            commit(next, "snap-" .. next.state.snaps, nil)
        end,
        ui.box({ w = g.grip.w, h = g.grip.h, radius = 2 * du, fill = palette.alpha("ink", 0.55) }),
    })
end

local function handles(c, g)
    local du = c.du
    local home = g.home
    local items = {}
    for _, corner in corners do
        local edge, sx, sy = corner[1], corner[2], corner[3]
        items[#items + 1] = kit.zone(c, {
            key = "resize-" .. edge,
            x = g.content.x + (if sx > 0 then g.content.w - 7.5 * du else 7.5 * du),
            y = if sy > 0 then g.content.h - 14 * du else 14 * du,
            w = 28 * du, h = 28 * du, cursor = "grab",
            gesture = track(g, {
                mode = "scale", edge = edge, min = { w = home.w / 2, h = home.h / 2 }, max = { w = home.w, h = home.h },
            }),
            onGesture = function(next, event)
                if event.phase == "ended" then commit(next, event.transaction, units.placed(g, event.rect)) end
            end,
        })
    end
    return items
end

local function claim()
end

local function render(ctx, g)
    local k = g.k
    local du = k.du
    local env = g.envelope
    local c = kit.canvas(g.drawing.w, env.h, du, k.rs)
    local display = ctx.data.bar.monitorId
    local tabs, failed = pages(ctx)
    local selected = selection(ctx, tabs)
    local page = if selected then ui.stack({
        key = "page", w = c.w, h = env.h,
        if not g.framed and cards.entry(ctx, "page-" .. tabs[selected].id) ~= nil then
            kit.label(c, { key = "page-on-shelf", text = tabs[selected].title .. " is " .. cards.location(ctx, tabs[selected].id),
                x = c.w / 2, y = env.h / 2, size = 13, color = "secondaryForeground", maxWidth = 300 * du, lines = 2 })
        else ui.component({
            id = tabs[selected].id, view = "desk", w = g.content.w, h = g.content.h,
            align = "topLeading", dx = g.content.x, dy = g.content.y,
            props = { du = du, rs = k.rs, u = k.u, reveal = ctx.state.reveal == true },
        }),
    }) else nil
    local band = kit.canvas(c.w, 60 * du, du, k.rs)
    local rise = { opacity = 0, dy = 12 * du, animate = kit.springs.fd0, delay = 0.2 }
    local fall = { opacity = 0, dy = 12 * du, animate = kit.springs.close }
    local frame = { key = "desk-frame", w = band.w, h = band.h, align = "top", appear = rise, exit = fall }
    for _, item in strip(band, g, tabs, selected) do
        frame[#frame + 1] = item
    end
    local lines = { key = "desk-notices", w = c.w, h = env.h, decorative = true, appear = rise, exit = fall }
    for _, item in notices(c, g, tabs, failed) do
        lines[#lines + 1] = item
    end
    local clip = { key = "desk-clip", align = "topLeading", dx = g.drawing.x,
        w = c.w, h = env.h, morph = contentMorph,
        ui.path({ mask = true, w = c.w, h = env.h,
            d = kit.roundedRect(g.clip.x, g.clip.y, g.clip.w, g.clip.h, g.clip.radius) }),
        ui.box({ key = "desk-band", w = c.w, h = env.h, onPress = claim }),
    }
    if page then clip[#clip + 1] = page end
    clip[#clip + 1] = ui.stack(frame)
    if #lines > 0 then clip[#clip + 1] = ui.stack(lines) end
    clip[#clip + 1] = grip(c, g, ctx.state.gripHeld == true)
    for _, item in handles(c, g) do
        clip[#clip + 1] = item
    end
    clip[#clip + 1] = close(c, g, display)
    return ui.stack({
        key = "desk", align = "topLeading", dx = env.x, dy = env.y, w = env.w, h = env.h,
        reveal = kit.springs.drip, manipulationFollow = kit.springs.desk, manipulationCommit = ctx.state.commit,
        exit = {
            dx = g.home.x - env.x, dy = g.home.y - env.y, scale = 1 / g.s, anchor = { x = 0, y = 0 },
            animate = kit.springs.desk,
        },
        ui.stack(clip),
    })
end

local function shape(g)
    local env = g.envelope
    return ui.shape({
        key = "desk-shape", align = "topLeading", dx = env.x, dy = env.y, w = env.w, h = env.h,
        radius = g.bodyRadius, follow = "desk", reveal = kit.springs.drip, morph = shapeMorph,
    })
end

local function opener(ctx, at)
    local bar = ctx.data.bar
    local scale = if at then at.scale or 1 else math.min(1, ((bar.style and bar.style.height) or 32) / (32 * units.cu))
    local cu = units.cu * scale
    local lit = if ctx.state.expanded then 1 else 0
    local hover = if ctx.state.openerHover then 1 else 0
    local tone = if lit == 1 then "mint" else "ink"
    local size = 32 * cu
    local tile = function(w, h, radius, dx, dy, amount)
        return ui.box({ w = w * cu, h = h * cu, radius = radius * cu, dx = dx * cu, dy = dy * cu,
            fill = palette.alpha(tone, amount), animate = kit.springs.drip })
    end
    return ui.stack({
        key = "desk-opener", w = size, h = size, cursor = "pointer",
        align = if at then "topLeading" else nil, dx = if at then at.x - size / 2 else nil,
        dy = if at then at.y - size / 2 else nil,
        onClick = "shell trigger vitreus " .. (if lit == 1 then "desk-close " else "desk-open ") .. bar.monitorId,
        onHover = function(next, event) next.state.openerHover = event.phase == "began" end,
        ui.box({ w = 28 * cu, h = 28 * cu, radius = 14 * cu,
            fill = palette.alpha(tone, 0.07 + 0.12 * hover + 0.12 * lit), animate = kit.springs.drip }),
        tile(7, 14, 2, -5, 0, 0.7 + 0.3 * hover),
        tile(7, 5.5, 1.8, 5, -4.25, 0.7 + 0.3 * hover),
        tile(7, 5.5, 1.8, 5, 4.25, 0.55 + 0.45 * hover),
    })
end

local function geometry(ctx, g)
    return units.desk(g.island, nil, ctx.state.place, g.frame)
end

return table.freeze({ geometry = geometry, render = render, shape = shape, opener = opener })

-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("./palette")
local buttons = require("./bar/buttons")

local function spring(stiffness: number, damping: number)
    local root = math.sqrt(stiffness)
    return table.freeze({ response = 2 * math.pi / root, bounce = 1 - damping / (2 * root) })
end

local carry = spring(380, 30)
local opposite = table.freeze({ left = "right", right = "left", ftop = "bottom", fbottom = "top" })
local fade = table.freeze({ stops = table.freeze({
    table.freeze({ at = 0, opacity = 0 }), table.freeze({ at = 0.5, opacity = 0 }), table.freeze({ at = 1, opacity = 1 }),
}) })
local commits = table.freeze({ "dockCommit", "addonPillCommit", "addonCommit" })

local function shown(ctx): boolean
    local bar = ctx.data.bar
    return bar ~= nil and bar.style ~= nil
end

local function side(ctx): number
    return if ctx.state.dockCorner == 1 then 1 else 0
end

local function area(g)
    local f = g.frame
    local inner = if f then f.inner else { x = 0, y = 0, w = g.size.w, h = g.size.h }
    local edge = if f then opposite[f.edge] else "bottom"
    return table.freeze({ edge = edge, vertical = edge == "left" or edge == "right",
        xs = inner.x, xe = inner.x + inner.w, yt = inner.y, ye = inner.y + inner.h })
end

local function listed(settings, key: string)
    local given = (settings or {})[key]
    return if type(given) == "table" then given else {}
end

local function pins(ctx)
    local list, seen = {}, {}
    for _, bundle in listed(ctx.data.settings, "pins") do
        if #list < 8 and type(bundle) == "string" and #bundle <= 255 and not seen[bundle]
            and string.match(bundle, "^[%w%.%-_]+$") then
            seen[bundle] = true
            list[#list + 1] = bundle
        end
    end
    return list
end

local function pill(g, count: number, corner: number, held: boolean?)
    local bu = g.k.bu
    local a = area(g)
    local thick, long = 34 * bu, count * 30 * bu + 8 * bu
    local w, h = if a.vertical then thick else long, if a.vertical then long else thick
    local ax = if a.vertical then (if a.edge == "right" then 1 else -1) else 2 * corner - 1
    local ay = if a.vertical then 2 * corner - 1 else (if a.edge == "bottom" then 1 else -1)
    local x, y = if ax > 0 then a.xe - w else a.xs, if ay > 0 then a.ye - h else a.yt
    local reach = if held then 0 else 12 * bu
    return table.freeze({
        x = x, y = y, w = w, h = h, cx = x + w / 2, cy = y + h / 2, ax = ax, ay = ay, long = long, area = a,
        vertical = a.vertical, radius = math.min(thick / 2, 26 * g.k.u),
        shape = table.freeze({ x = x + math.min(0, ax) * reach, y = y + math.min(0, ay) * reach,
            w = w + reach, h = h + reach, reach = reach }),
    })
end

local function slots(g, p, count: number)
    local bu = g.k.bu
    local size = math.floor(24 * bu + 0.5)
    local step = size + math.floor(6 * bu + 0.5)
    local start = math.floor((if p.vertical then p.cy else p.cx) - p.long / 2 + 7 * bu + 0.5)
    local across = math.floor((if p.vertical then p.cx else p.cy) - 12 * bu + 0.5)
    local result = table.create(count)
    for index = 1, count do
        local along = start + (index - 1) * step
        result[index] = if p.vertical then { x = across - p.x, y = along - p.y } else { x = along - p.x, y = across - p.y }
    end
    return result, size
end

local function turn(state, corner: number, own: string?, transaction: string?): boolean
    local changed = (if state.dockCorner == 1 then 1 else 0) ~= corner
    state.dockCorner = corner
    if changed then
        state.dockSwaps = (state.dockSwaps or 0) + 1
        for _, name in commits do
            state[name] = "dock-swap-" .. state.dockSwaps
        end
    end
    if own then state[own] = transaction end
    return changed
end

local function drag(g, own: string, held: string, mirrored: boolean)
    return function(next, event)
        local state, phase, rect = next.state, event.phase, event.rect
        if phase == "began" then
            state[held] = true
            return
        end
        if phase ~= "ended" and phase ~= "cancelled" then return end
        state[held] = nil
        if phase == "cancelled" or not rect then return end
        local far = if area(g).vertical then rect.y + rect.h / 2 > g.size.h / 2 else rect.x + rect.w / 2 > g.size.w / 2
        local corner = if far ~= mirrored then 1 else 0
        if turn(state, corner, own, event.transaction) then
            omniwm.run("shell trigger vitreus dock-corner " .. corner)
        end
    end
end

local function frame(g, p, key: string, commit: string?, onGesture, items)
    local grab = {
        key = key .. "-grab", w = p.w, h = p.h, cursor = "pointer", onGesture = onGesture,
        gesture = { axis = "free", threshold = 8, track = {
            mode = "move", target = key, bounds = { x = -p.w / 2, y = -p.h / 2, w = g.size.w + p.w, h = g.size.h + p.h },
            min = { w = p.w, h = p.h }, max = { w = p.w, h = p.h },
        } },
    }
    for index, item in items do
        grab[index] = item
    end
    return ui.stack({
        key = key, align = "topLeading", dx = p.x, dy = p.y, w = p.w, h = p.h,
        reveal = g.calm, manipulationFollow = carry, manipulationCommit = commit,
        ui.stack({ key = key .. "-fade", w = p.w, h = p.h, morph = fade, ui.stack(grab) }),
    })
end

local function glass(g, p, key: string)
    local s = p.shape
    local field = if p.vertical then "h" else "w"
    local full = if p.vertical then s.h else s.w
    local stops = {}
    for index, at in { 0, 1, 1.5 } do
        local stop = { at = at }
        stop[field] = (s.reach + p.long * at) / full
        stops[index] = stop
    end
    return ui.shape({
        key = key .. "-glass", follow = key, align = "topLeading", dx = s.x, dy = s.y, w = s.w, h = s.h,
        radius = p.radius, animate = g.calm, reveal = g.calm, morph = { stops = stops },
    })
end

local function unpin(next, bundle: string)
    local kept = {}
    for _, value in listed(next.data.settings, "pins") do
        if value ~= bundle then kept[#kept + 1] = value end
    end
    local function report(problem)
        omniwm.log("vitreus: could not unpin " .. bundle .. ": " .. tostring(problem))
    end
    local _, problem = omniwm.config.set("pins", kept, function(result)
        if not result.ok then report(result.error) end
    end)
    if problem then report(problem) end
end

local function icon(ctx, g, bundle: string, slot, size: number, held: boolean)
    local bu = g.k.bu
    local key = "dock-pin-" .. bundle
    local a = if not held and ctx.state.barHot == key then 1 else 0
    return ui.stack({
        key = key, align = "topLeading", dx = slot.x - 3.5 * bu, dy = slot.y - 4.5 * bu, w = 31 * bu, h = 33 * bu,
        cursor = "pointer", onHover = buttons.hover(key), onClick = "notifications open " .. bundle,
        onRightClick = function(next) unpin(next, bundle) end,
        ui.box({
            key = key .. "-plate", decorative = true, w = 33 * bu, h = 33 * bu, radius = 10 * bu,
            fill = palette.alpha("ink", 0.16), opacity = a, animate = buttons.touch,
        }),
        ui.stack(buttons.glow({
            key = key .. "-icon", decorative = true, align = "topLeading", dx = 3.5 * bu, dy = 4.5 * bu, w = size, h = size,
            scale = 1 + 0.16 * a, opacity = 0.88 + 0.12 * a, animate = buttons.touch,
            ui.icon({ app = bundle, w = size, h = size, placeholder = "app.dashed" }),
        }, bu)),
    })
end

local function shapes(ctx, g, budget: number?)
    if (budget or 1) < 1 or not shown(ctx) then return nil end
    local list = pins(ctx)
    if #list == 0 then return nil end
    return { glass(g, pill(g, #list, side(ctx), ctx.state.dockHeld), "dock-pill") }
end

local function content(ctx, g)
    if not shown(ctx) then return nil end
    local list = pins(ctx)
    if #list == 0 then return nil end
    local held = ctx.state.dockHeld == true
    local p = pill(g, #list, side(ctx), held)
    local places, size = slots(g, p, #list)
    local items = {}
    for index, bundle in list do
        items[index] = icon(ctx, g, bundle, places[index], size, held)
    end
    return { frame(g, p, "dock-pill", ctx.state.dockCommit, drag(g, "dockCommit", "dockHeld", false), items) }
end

local function trigger(ctx, event)
    if event.name ~= "dock-corner" then return end
    local corner = tonumber(event.value)
    if corner == 0 or corner == 1 then turn(ctx.state, corner) end
end

return table.freeze({
    spring = spring, shown = shown, side = side, listed = listed, pill = pill, slots = slots, drag = drag, frame = frame,
    glass = glass, shapes = shapes, content = content, trigger = trigger,
})

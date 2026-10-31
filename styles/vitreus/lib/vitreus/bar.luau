-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("./palette")
local units = require("./units")
local menus = require("./bar/menus")
local marks = require("./bar/marks")
local title = require("./bar/title")
local tray = require("./bar/tray")
local buttons = require("./bar/buttons")
local clock = require("./bar/clock")
local battery = require("./bar/battery")
local frame = require("./frame")
local drawer = require("./drawer")
local cards = require("./cards")
local windows = require("./windows")
local liquid = require("./liquid")
local panes = require("./panes")
local notches = require("./notches")
local docks = require("./docks")
local addons = require("./addons")
local visualiser = require("./visualiser")

local calm = table.freeze({ response = 0.513, bounce = 0.06 })
local beat = table.freeze({ response = 2 * math.pi / math.sqrt(480), bounce = 1 - 15 / (2 * math.sqrt(480)) })
local swellWidth, swellHeight = 10, 6
local defaults = table.freeze({ "apple", "app", "workspaces", "title", "tray", "search", "omniwm", "controls", "clock" })
local owners = table.freeze({
    apple = menus, app = menus, workspaces = marks, title = title, tray = tray, privacy = tray, search = buttons,
    omniwm = buttons, controls = buttons, clock = clock,
})
local pieces = table.freeze({ menus, marks, title, tray, buttons, clock })
local under = table.freeze({ battery })
local layers = table.freeze({ drawer, liquid, cards, panes, notches, docks, addons, visualiser })

local function order(list)
    local seen, names = {}, {}
    local given = if type(list) == "table" then list else defaults
    for _, name in given do
        if type(name) == "string" and name ~= "privacy" and owners[name] and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    if not seen.omniwm then names[#names + 1] = "omniwm" end
    return table.freeze(names)
end

local function prefix(k, names, widths, split, slots, ranges)
    local gap = 12 * k.bu
    local side, x, last = 1, ranges[1].x, 1
    local ends = { ranges[1].x, ranges[2].x }
    local function take(width: number, reserve: number, gap: number?)
        local from = x + (gap or 0)
        if side == 1 and from + width > ranges[1].to then
            side, x = 2, ranges[2].x
            from = x
        end
        if from + width > ranges[side].to - (if side == 2 then reserve else 0) then return nil end
        x = from + width
        ends[side], last = x, side
        return from
    end
    for index = 1, split - 1 do
        local name = names[index]
        local width, cells = widths[name].w, widths[name].flow
        local reserve = 0
        for next = index + 1, split - 1 do
            local later = widths[names[next]]
            if later.w > 0 then
                reserve += (if names[next] == "tray" and later.flow then later.flow[1].w else later.w) + gap
            end
        end
        local from = x
        if cells then
            local positions = {}
            local lead = 0
            for _, cell in cells do
                local at = take(cell.w, reserve, lead)
                if not at then break end
                positions[cell.key] = at + cell.at
                lead = cell.gap or 0
            end
            slots[name] = table.freeze({ x = from, w = x - from, cx = (from + x) / 2,
                positions = table.freeze(positions), hidden = next(positions) == nil })
        else
            local at = take(width, reserve)
            slots[name] = table.freeze({ x = at or x, w = width, cx = (at or x) + width / 2, hidden = at == nil })
        end
        if width > 0 and not slots[name].hidden then x += gap ends[side] = x end
    end
    return ends, last
end

local function place(k, cx: number, top: number, names, widths, givenWidth: number?, givenHeight: number?, band,
    tail: number?)
    local bu = k.bu
    local gap = 12 * bu
    local split = table.find(names, "title") or #names + 1
    local minimum = widths.title and widths.title.minimum or title.least * bu
    local grow, pre, post, used, count = 0, 0, 0, 0, 0
    for index, name in names do
        local width = widths[name].w
        grow += widths[name].grow
        if width > 0 and index < split then pre += width + gap end
        if width > 0 and index > split then post, used, count = post + width + gap, used + width, count + 1 end
    end
    local w = givenWidth or 450 * bu + grow
    local stretch = if names[split] then math.max(0, w - 32 * bu - pre - post) else 0
    local filled = band ~= nil and not givenWidth
    if tail then post, used, count = post + tail + gap, used + tail, count + 1 end
    if filled then
        cx = (band.x0 + band.x1) / 2
        w = band.x1 - band.x0 + 32 * bu + 2 * math.max(pre + stretch, post - gap)
    end
    local left, right = cx - w / 2 + 16 * bu, cx + w / 2 - 16 * bu
    local slots = {}
    local x = left
    local limit, full
    if filled then
        local spacing = if count > 1 then (right - band.x1 - used) / (count - 1) else 0
        x = if count > 1 then band.x1 else right - used
        for index = split + 1, #names do
            local width = widths[names[index]].w
            slots[names[index]] = table.freeze({ x = x, w = width, cx = x + width / 2 })
            if width > 0 then x += width + spacing end
        end
        if tail then slots.opener = table.freeze({ x = x, w = tail, cx = x + tail / 2 }) end
    else
        x = right
        if tail then
            slots.opener = table.freeze({ x = x - tail, w = tail, cx = x - tail / 2 })
            x -= tail + gap
        end
        local index = #names
        while index > split do
            local width = widths[names[index]].w
            if band and width > 0 and x - width < band.x1 then break end
            slots[names[index]] = table.freeze({ x = x - width, w = width, cx = x - width / 2 })
            if width > 0 then x -= width + gap end
            index -= 1
        end
        if index > split then
            full, limit = true, band.x0
            local room = limit - left - pre - (if names[split] then title.least * bu + gap else 0)
            for spill = split + 1, index do
                local width = widths[names[spill]].w
                if names[spill] ~= "tray" and width > 0 then room -= width + gap end
            end
            for spill = index, split + 1, -1 do
                local name, width = names[spill], widths[names[spill]].w
                if name == "tray" then
                    local count = widths[name].cells or 0
                    local inner = if spill == index then math.min(count, tray.capacity(x - band.x1, bu)) else 0
                    local outer = math.min(count - inner, tray.capacity(room, bu))
                    local size = tray.span(inner, bu)
                    slots[name] = table.freeze({ x = band.x1, w = size, cx = band.x1 + size / 2, parts = table.freeze({
                        table.freeze({ x = limit - tray.span(outer, bu), first = 1, count = outer }),
                        table.freeze({ x = band.x1, first = outer + 1, count = inner }),
                    }) })
                    if outer > 0 then limit -= tray.span(outer, bu) + gap end
                else
                    slots[name] = table.freeze({ x = limit - width, w = width, cx = limit - width / 2 })
                    if width > 0 then limit -= width + gap end
                end
            end
        end
    end
    local flowFrom, flowTo
    if band and givenWidth and pre > (limit or band.x0) - left then
        local rightFrom, rightTo = band.x1, if slots.opener then slots.opener.x - gap else right
        for index = split + 1, #names do
            local slot = slots[names[index]]
            if slot and slot.parts then
                for _, part in slot.parts do
                    if part.count > 0 and part.x >= band.x1 then
                        rightFrom = math.max(rightFrom, part.x + tray.span(part.count, bu) + gap)
                    end
                end
            elseif slot and slot.w > 0 and slot.x >= band.x1 then
                rightTo = math.min(rightTo, slot.x - gap)
            end
        end
        local ends = { limit or band.x0, rightTo }
        local ranges = { { x = left, to = ends[1] }, { x = rightFrom, to = ends[2] } }
        local reserve = if names[split] then minimum + gap else 0
        if rightTo - rightFrom >= reserve then ranges[2].to -= reserve else ranges[1].to -= reserve end
        local used, side = prefix(k, names, widths, split, slots, ranges)
        flowFrom, flowTo = used[side], ends[side]
        if flowTo - flowFrom < minimum then
            local other = 3 - side
            if ends[other] - used[other] > flowTo - flowFrom then flowFrom, flowTo = used[other], ends[other] end
        end
    else
        x = left
        for index = 1, split - 1 do
            local width = widths[names[index]].w
            slots[names[index]] = table.freeze({ x = x, w = width, cx = x + width / 2 })
            if width > 0 then x += width + gap end
        end
    end
    if names[split] then
        local from, to = left + pre, right - post
        if flowFrom then
            from, to = flowFrom, flowTo
        elseif full then
            to = limit
        elseif band and givenWidth then
            if band.x0 - from >= title.least * bu then to = band.x0 else from = band.x1 end
        elseif band then
            to = band.x0
        end
        local width = math.max(0, to - from)
        slots.title = table.freeze({ x = from, w = width, cx = from + width / 2,
            hidden = flowFrom ~= nil and width < minimum })
    end
    return table.freeze({
        x = cx - w / 2, y = top, w = w, h = givenHeight or 40 * bu, cx = cx,
        cy = top + (givenHeight or 40 * bu) / 2, radius = 14 * bu, gap = gap,
        left = left, right = right, slots = table.freeze(slots),
    })
end

local function islandPill(k, island, style, names, widths)
    local gap, notch, tail = 12 * k.bu, island.notch, 30 * k.bu
    local band = if notch then { x0 = notch.x - gap, x1 = notch.x + notch.w + gap } else nil
    local right = island.size.w - units.edge
    if not style.fullWidth then
        local pill = place(k, island.size.w / 2, units.edge, names, widths, nil, nil, band, if band then tail else nil)
        if not band or pill.w <= right - units.edge then return pill end
    end
    return place(k, (units.edge + right) / 2, units.edge, names, widths, right - units.edge, nil, band, tail)
end

local function geometry(ctx, island)
    local settings = ctx.data.settings or {}
    local k = units.of(island, settings.size)
    local style = ctx.data.bar and ctx.data.bar.style
    local layout = if frame.framed(settings) then settings.layout else "island"
    local names = table.clone(order(settings.pieces))
    if style and not table.find(names, "tray") then
        local privacy = ctx.data.privacy
        if privacy and (privacy.microphone or privacy.camera) then
            table.insert(names, table.find(names, "search") or table.find(names, "omniwm") or #names + 1, "privacy")
        end
    end
    local widths = {}
    local islandLayout = layout == "island"
    local split = table.find(names, "title") or #names + 1
    for index, name in names do
        local owner = owners[name]
        local w, grow, cells = 0, 0, nil
        if owner.width then w, grow, cells = owner.width(ctx, k, name) end
        widths[name] = { w = w, grow = grow or 0, cells = cells, extent = owner.extent and owner.extent(ctx, k),
            minimum = owner.minimum and owner.minimum(ctx, k),
            flow = if islandLayout and island.notch and index < split and w > 0 and owner.flow
                then owner.flow(ctx, k, name) else nil }
    end
    local metrics = if (layout == "left" or layout == "right") and table.find(names, "title")
        then title.metrics(ctx, k) else { cw = 0, tw = 0 }
    local frameGeometry = frame.geometry(ctx, k, island.size, names, widths, place, metrics)
    local opener = { x = island.size.w - 41 * k.cu, y = units.edge + 20 * k.u }
    local usable = island.usableRect
    local pill = if islandLayout and style then islandPill(k, island, style, names, widths)
        elseif frameGeometry then frameGeometry.pill else nil
    local docked = islandLayout and pill and pill.slots.opener
    if docked then opener = { x = docked.cx, y = pill.cy, scale = docked.w / (32 * k.cu) } end
    local g = {
        island = island,
        calm = calm,
        k = k,
        layout = layout,
        size = island.size,
        pieces = table.freeze(names),
        frame = frameGeometry,
        pill = pill,
        opener = if islandLayout then table.freeze(opener) else nil,
        room = if frameGeometry then frameGeometry.inner else table.freeze({ x = usable.x, y = usable.y,
            w = math.min(island.size.w, usable.x + usable.w) - usable.x, h = usable.h }),
    }
    if pill then g.title = title.resolve(ctx, g, pill.slots.title) end
    return table.freeze(g)
end

local function append(list, items)
    for _, item in items or {} do
        list[#list + 1] = item
    end
end

local function compose(ctx, g, list, body, content, auxiliary)
    for _, layer in list do
        local destination = if auxiliary and (layer == docks or layer == addons) then auxiliary else body
        append(destination, layer.shapes(ctx, g, math.max(0, 64 - #destination)))
        if g.frame or (layer ~= drawer and layer ~= cards) then append(content, layer.content(ctx, g)) end
    end
end

local function hoverContent(g, children, area)
    local strip = area or (if g.frame then g.frame.strip else g.pill)
    local drawing = { w = g.size.w, h = g.size.h, align = "topLeading", dx = -strip.x, dy = -strip.y }
    append(drawing, children)
    return ui.stack({ key = if area then "bar-hover-" .. area.name else "bar-hover", w = strip.w, h = strip.h,
        align = "topLeading", dx = strip.x, dy = strip.y,
        onHover = function(next, event) next.state.barHovered = event.phase == "began" end,
        ui.stack(drawing),
    })
end

local function swell(ctx, g)
    if not visualiser.plan(ctx, g, 0) then return nil end
    local bu = g.k.bu
    return { swell = { w = swellWidth * bu, h = swellHeight * bu }, gain = if ctx.state.drawerPanel then 0 else 1,
        response = beat.response, bounce = beat.bounce }
end

local function render(ctx, g)
    for _, owner in pieces do
        if owner.prepare then owner.prepare(ctx, g) end
    end
    local shadow, shadowRadius, shadowOffset, shadowMotion = drawer.shadow(ctx)
    local body = {
        key = "bar", w = g.size.w, h = g.size.h, align = "topLeading",
        fill = palette.alpha("tint", 0.36), rim = 0.1, blend = if g.frame then g.frame.blend else 26 * units.u,
        shadow = shadow, shadowRadius = shadowRadius, shadowOffset = shadowOffset, animate = shadowMotion,
    }
    local auxiliary = if not g.frame then table.clone(body) else nil
    if auxiliary then auxiliary.key = "corner-glass" end
    local content = { key = "bar-content", w = g.size.w, h = g.size.h, align = "topLeading" }
    append(body, frame.shapes(ctx, g))
    local barContent = {}
    compose(ctx, g, under, body, barContent)
    local pill = g.pill
    if pill then
        if not g.frame then
            local beating = swell(ctx, g)
            body[#body + 1] = ui.shape({
                key = "shell", align = "topLeading", dx = pill.x, dy = pill.y, w = pill.w, h = pill.h,
                radius = pill.radius, animate = if beating then nil else calm, spectrum = beating,
            })
            local notch = g.island.notch
            if notch then
                body[#body + 1] = ui.shape({
                    key = "notch-melt", align = "topLeading", dx = notch.x, dy = -pill.radius, w = notch.w,
                    h = notch.h + pill.radius, radius = pill.radius,
                })
            end
        end
        local split = g.frame and g.frame.pieces
        local groups = { [pill] = barContent }
        for _, name in g.pieces do
            local owner, slot = owners[name], pill.slots[name]
            if slot and slot.hidden and not (name == "title" and g.title) then continue end
            local piece = if split and slot then slot.piece else pill
            local view = g
            if piece ~= pill then
                view = table.clone(g)
                view.pill = piece
            end
            groups[piece] = groups[piece] or {}
            append(body, owner.shapes(ctx, view, slot, name))
            append(groups[piece], owner.content(ctx, view, slot, name))
        end
        if split then
            for _, piece in split do
                content[#content + 1] = hoverContent(g, groups[piece], piece)
            end
        else
            content[#content + 1] = hoverContent(g, barContent)
        end
    end
    append(content, frame.content(ctx, g))
    compose(ctx, g, layers, body, content, auxiliary)
    local items = {}
    if #body > 0 then items[#items + 1] = ui.glass(body) end
    if auxiliary and #auxiliary > 0 then items[#items + 1] = ui.glass(auxiliary) end
    if #content > 0 then items[#items + 1] = ui.stack(content) end
    return items
end

local function overlay(ctx, g)
    if g.frame then return nil end
    local items, entries = {}, {}
    append(items, drawer.content(ctx, g))
    append(items, cards.content(ctx, g))
    for index, node in items do
        local id = string.match(node.key or "", "^drawer%-content%-(%a+)$")
        local rank = if id then
            (if windows.held(ctx, id) or cards.held(ctx, id) then 50
            elseif windows.stored(ctx, id) then 10 else 20)
            else cards.priority(ctx, node.key)
        entries[#entries + 1] = { node = node, rank = rank, index = index }
    end
    table.sort(entries, function(a, b) return if a.rank == b.rank then a.index < b.index else a.rank < b.rank end)
    local shelf, front = {}, {}
    for _, entry in entries do
        local group = if entry.rank < 20 then shelf else front
        group[#group + 1] = entry.node
    end
    return shelf, front
end

local function trigger(ctx, event)
    for _, list in { pieces, under, layers } do
        for _, owner in list do
            if owner.trigger then owner.trigger(ctx, event) end
        end
    end
end

return table.freeze({
    calm = calm, defaults = defaults, order = order, place = place, geometry = geometry, render = render,
    trigger = trigger, overlay = overlay,
})

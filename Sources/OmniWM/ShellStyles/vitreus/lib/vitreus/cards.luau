-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("./kit")
local palette = require("./palette")
local windows = require("./windows")
local stick = require("./stick")

local views = setmetatable({}, { __mode = "k" })

local function record(ctx, id)
    if not ctx.state.cards then ctx.state.cards = {} end
    if not ctx.state.cards[id] then ctx.state.cards[id] = { location = "home" } end
    return ctx.state.cards[id]
end

local function reset(ctx, g)
    local arrivals = {}
    for id, item in ctx.state.cards or {} do
        arrivals[id], item.arrive = item.arrive, nil
    end
    views[ctx.state] = { entries = {}, space = g, arrive = arrivals }
end

local function add(ctx, owner, specs)
    local entries = views[ctx.state].entries
    for _, spec in specs or {} do
        spec.owner, spec.target = owner, spec.target or "drawer-content-" .. spec.id
        entries[#entries + 1] = spec
        local item = record(ctx, spec.id)
        if spec.page and not item.initialized then item.location, item.initialized = "drawer", true end
    end
end

local function measures(ctx)
    local view = views[ctx.state]
    local entries, space = view.entries, view.space
    local result = {}
    for _, spec in entries do
        if record(ctx, spec.id).location == "drawer" then
            result[#result + 1] = { id = spec.id, w = spec.w * space.k.bcu, h = spec.h * space.k.bcu }
        end
    end
    return result
end

local function arrival(rect, parent)
    return { x = rect.x, y = rect.y, w = rect.w, h = rect.h,
        px = if parent and parent.visible then parent.x else nil,
        py = if parent and parent.visible then parent.y else nil }
end

local function layout(ctx, storage, parents)
    local view = views[ctx.state]
    local entries, space = view.entries, view.space
    for _, spec in entries do
        local item = record(ctx, spec.id)
        local wasStored = item.location == "drawer"
        local fromShelf = wasStored or item.location == "home" and windows.stored(ctx, spec.owner)
        local parent = parents[spec.owner]
        local cu = if parent then parent.cu else space.k.bcu
        local home = { x = (parent and parent.x or 0) + spec.x * cu,
            y = (parent and parent.y or 0) + spec.y * cu, w = spec.w * cu, h = spec.h * cu }
        local slot = storage and storage.slots[spec.id]
        if spec.page and slot then
            home = { x = slot.x, y = slot.y, w = spec.w * space.k.bcu * slot.scale, h = spec.h * space.k.bcu * slot.scale }
        end
        local rect = table.clone(home)
        if item.location == "drawer" and slot then
            cu = space.k.bcu * slot.scale
            rect = { x = slot.x, y = slot.y, w = spec.w * cu, h = spec.h * cu }
        elseif item.location ~= "home" then
            cu = space.k.bcu * (item.scale or 1)
            rect.w, rect.h = spec.w * cu, spec.h * cu
            rect.x = math.clamp(item.rect and item.rect.x or home.x, space.room.x, math.max(space.room.x, space.room.x + space.room.w - rect.w))
            local y = item.rect and item.rect.y or home.y
            if item.rect and item.rect.above and y + rect.h > space.room.y + space.room.h then y = item.rect.above - rect.h end
            rect.y = math.clamp(y, space.room.y, math.max(space.room.y, space.room.y + space.room.h - rect.h))
            if item.side then
                local snap = stick.snap(rect, space.room, item.side)
                rect.x, rect.y = snap.x, snap.y
            end
        end
        spec.panel = { id = spec.id, window = spec.id, target = spec.target, x = rect.x, y = rect.y,
            w = rect.w, h = rect.h, cu = cu, rs = cu / 1.5525, home = home, bounds = space.room,
            storage = storage, commit = item.commit, calm = space.calm, close = parent and parent.dismiss,
            cardScale = cu / space.k.bcu, gripY = (spec.gripY or 0) * cu, gripH = spec.gripH,
            onRelease = function(value, event)
                if fromShelf and value.location ~= "drawer" then value.scale = nil end
                value.arrive = if value.location == "home" then arrival(event.rect, parent) else nil
            end,
            homeLocation = if spec.page then "drawer" else "home", homeEnabled = parent and parent.visible,
            homePriority = true,
            homeParent = if parent and parent.visible then { x = parent.x, y = if parent.loose then parent.y else space.pill.y,
                w = parent.w, h = parent.y + parent.h - (if parent.loose then parent.y else space.pill.y) } else nil,
            help = "Drag this card to a screen edge, its panel, or the top shelf." }
        spec.parent = parent
        spec.nested = not spec.page and item.location == "home"
        spec.shown = if spec.nested then parent ~= nil and parent.visible else item.location ~= "drawer" or storage ~= nil
    end
end

local function entry(ctx, id)
    local view = views[ctx.state]
    if not view then return nil end
    for _, spec in view.entries do if spec.id == id then return spec end end
    return nil
end

local function home(ctx, id, commit)
    local value, spec = record(ctx, id), entry(ctx, id)
    value.arrive = if spec and not spec.nested then arrival(spec.panel, spec.parent) else nil
    value.location, value.side, value.rect, value.held, value.scale, value.grab = "home", nil, nil, nil, nil, nil
    value.serial = (value.serial or 0) + 1
    value.commit = commit or "card-home-" .. id .. "-" .. value.serial
end

local function redock(ctx, owner)
    for id, value in ctx.state.cards or {} do
        if string.sub(id, 1, #owner + 1) == owner .. "-" and value.location ~= "home" then home(ctx, id) end
    end
end

local function onShelf(ctx, id)
    return ctx.state.cards ~= nil and ctx.state.cards["page-" .. id] ~= nil
end

local function expose(ctx, id, near, height)
    local spec = entry(ctx, near)
    local value = record(ctx, id)
    if not spec or value.location ~= "home" then return end
    value.location, value.side = "floating", nil
    local space = views[ctx.state].space
    local gap = 12 * space.k.u
    local below = spec.panel.y + (if height then height * spec.panel.cu else spec.panel.h) + gap
    value.rect = { x = spec.panel.x, y = below, above = spec.panel.y - gap }
end

local function out(ctx, id)
    return record(ctx, id).location ~= "home"
end

local function anyOut(ctx, owner, visibleOnly)
    for id, value in ctx.state.cards or {} do
        if string.sub(id, 1, #owner + 1) == owner .. "-" and value.location ~= "home"
            and (not visibleOnly or value.location ~= "drawer" or ctx.data.island and ctx.data.island.drawer == "shelf") then return true end
    end
    return false
end

local function content(ctx, spec, morph)
    local p, item = spec.panel, record(ctx, spec.id)
    local view = views[ctx.state]
    local arrive = if spec.shown then view.arrive[spec.id] else nil
    view.arrive[spec.id] = nil
    local travelX = if spec.nested and arrive and arrive.px and not spec.parent.loose then arrive.px - spec.parent.x else 0
    local travelY = if spec.nested and arrive and arrive.py and not spec.parent.loose then arrive.py - spec.parent.y else 0
    local nodes = spec.content(ctx, p) or {}
    local clip = { key = "card-content-" .. spec.id, w = p.w, h = p.h,
        morph = if not item.held and not spec.ownMorph then morph else nil,
        if not spec.ownClip then ui.path({ mask = true, w = p.w, h = p.h, d = kit.roundedRect(0, 0, p.w, p.h, 14 * p.cu) }) else nil }
    local rise = { key = "card-rise-" .. spec.id, w = p.w, h = p.h,
        appear = if morph and spec.delay and not arrive then { opacity = 0, dy = 12 * p.cu, delay = spec.delay, animate = spec.spring } else nil }
    for _, node in nodes do rise[#rise + 1] = node end
    clip[#clip + 1] = ui.stack(rise)
    local children = { ui.stack(clip), windows.grip(ctx, p, record) }
    local x, y = p.x, p.y
    if spec.nested then x -= spec.parent.x y -= spec.parent.y end
    if not spec.shown then x, y = -p.w - 64, -p.h - 64 end
    return ui.stack({ key = spec.target, align = "topLeading", dx = x, dy = y, w = p.w, h = p.h,
        opacity = if spec.shown then 1 else 0,
        animate = if spec.nested and not spec.parent.loose then spec.parent.calm else nil,
        manipulationFollow = if spec.shown then kit.springs.desk else nil, manipulationCommit = item.commit,
        appear = if arrive then { dx = arrive.x - p.x - travelX, dy = arrive.y - p.y - travelY,
            scale = arrive.w / p.w, anchor = { x = 0, y = 0 }, animate = kit.springs.desk } else nil,
        onPress = if spec.id ~= "player-album" then function() end else nil,
        table.unpack(children),
    })
end

local function nested(ctx, owner, morph)
    local entries = views[ctx.state].entries
    local result = {}
    for _, spec in entries do
        if spec.owner == owner and spec.nested and spec.shown then
            result[#result + 1] = content(ctx, spec, if morph then morph(spec.panel) else nil)
        end
    end
    return result
end

local function placeholder(p, id, x, y, w, h)
    return ui.box({ key = "card-slot-" .. id, align = "topLeading", dx = x * p.cu, dy = y * p.cu,
        w = w * p.cu, h = h * p.cu, radius = 14 * p.cu,
        decorative = true, fill = palette.alpha("ink", 0.025), border = palette.alpha("ink", 0.09), borderWidth = p.cu })
end

local function plate(spec, g, item)
    local p = spec.panel
    local props = { key = spec.shapeKey or "card-glass-" .. spec.id, follow = spec.target,
        followRadius = if spec.fixed then "fixed" else nil,
        align = "topLeading", dx = p.x, dy = p.y, w = p.w, h = p.h,
        radius = (spec.radius or 14) * (if spec.fixed then g.k.bcu else p.cu), reveal = kit.springs.drip, morph = spec.morph }
    if not spec.fixed then
        local source, reach = stick.source(g, spec.target, p.cu, item.side or "right", {})
        props.follow, props.dx, props.dy = nil, -reach, -reach
        props.w, props.h = g.size.w + 2 * reach, g.size.h + 2 * reach
        props.morph = { source = source, stops = { { at = 0 }, { at = 1 } } }
    end
    return ui.shape(props)
end

local function shapes(ctx, g, budget, target)
    if g.frame then return nil end
    local body, shown, limit = {}, {}, budget or 64
    for _, spec in views[ctx.state].entries do
        local item = record(ctx, spec.id)
        if (if target then spec.id == target else spec.id ~= "player-album")
            and spec.shown and (not spec.nested or item.held) and (item.location ~= "drawer" or item.held) then
            shown[#shown + 1] = spec
            if #body < limit then body[#body + 1] = plate(spec, g, item) end
        end
    end
    for _, held in { true, false } do
        for _, spec in shown do
            local p, item = spec.panel, record(ctx, spec.id)
            if (item.held == true) ~= held then continue end
            local place = { rect = { x = p.x, y = p.y, w = p.w, h = p.h }, du = p.cu }
            for _, side in (if held then stick.sides elseif item.side then { item.side } else {}) do
                for _, shape in stick.pieces(g, place, side, spec.target, spec.id .. "-card", math.max(0, limit - #body), true, not held) do
                    body[#body + 1] = shape
                end
            end
        end
    end
    return body
end

local function held(ctx, owner)
    for id, item in ctx.state.cards or {} do
        if item.held and string.sub(id, 1, #owner + 1) == owner .. "-" then return true end
    end
    return false
end

local function priority(ctx, key)
    for _, spec in views[ctx.state].entries do
        if spec.target == key then
            local item = record(ctx, spec.id)
            return if item.held then 50 elseif item.location == "drawer" then 5 else 30
        end
    end
    return 0
end

local function location(ctx, id)
    local item = record(ctx, "page-" .. id)
    return if item.location == "drawer" then "on the top shelf"
        elseif item.location == "edge" then "on the " .. (item.side or "screen") .. " edge"
        else "in a floating card"
end

local function render(ctx, g)
    if g.frame then return nil end
    local entries = views[ctx.state].entries
    local result = {}
    for _, spec in entries do
        if not spec.nested and (spec.shown or spec.page) then result[#result + 1] = content(ctx, spec) end
    end
    return result
end

return table.freeze({ reset = reset, add = add, measures = measures, layout = layout,
    shapes = shapes, content = render, nested = nested, placeholder = placeholder, out = out, redock = redock, record = record, expose = expose, onShelf = onShelf, anyOut = anyOut, entry = entry, home = home, held = held, priority = priority, location = location })

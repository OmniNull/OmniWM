-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("./palette")
local frame = require("./frame")
local stick = require("./stick")
local order = table.freeze({ "calendar", "controls", "player" })
local homes = table.freeze({ calendar = "clock", controls = "controls", player = "title" })
local dockHints = table.freeze({ calendar = "Click the clock to dock it.",
    controls = "Click the controls button to dock it.", player = "Click the window title to dock it." })

local function record(ctx, id: string)
    local values = ctx.state.windows
    if not values then values = {} ctx.state.windows = values end
    if not values[id] then values[id] = { location = "home", home = homes[id] } end
    return values[id]
end

local function detached(ctx, id: string): boolean
    if frame.framed(ctx.data.settings) then return false end
    local value = (ctx.state.windows or {})[id]
    return value ~= nil and value.location ~= "home"
end

local function stored(ctx, id: string): boolean
    return detached(ctx, id) and record(ctx, id).location == "drawer"
end

local function held(ctx, id: string): boolean
    return not frame.framed(ctx.data.settings) and record(ctx, id).held == true
end

local function visible(ctx, id: string): boolean
    if stored(ctx, id) then return ctx.data.island and ctx.data.island.drawer == "shelf" end
    return ctx.state.drawerPanel == id or detached(ctx, id)
end

local function redock(ctx, id: string)
    local value = record(ctx, id)
    value.location, value.rect, value.held, value.side, value.grab = "home", nil, nil, nil, nil
    value.serial = (value.serial or 0) + 1
    value.commit = "window-home-" .. id .. "-" .. value.serial
end

local function dismiss(ctx, id: string?)
    if id and not detached(ctx, id) then record(ctx, id).glass = nil end
end

local function shelf(ctx, g, panels)
    if g.frame or not ctx.data.island or ctx.data.island.drawer ~= "shelf" then return nil end
    local gap, padding = 12 * g.k.u, 16 * g.k.u
    local top = math.max(56 * g.k.u, g.pill and g.pill.y + g.pill.h + 40 * g.k.u or 0)
    local columns = math.min(3, math.max(1, #panels))
    local rows, width, height = {}, 0, 0
    for index, panel in panels do
        local row = math.floor((index - 1) / columns) + 1
        rows[row] = rows[row] or { w = 0, h = 0, items = {} }
        local line = rows[row]
        line.w += panel.w
        line.h = math.max(line.h, panel.h)
        line.items[#line.items + 1] = panel
    end
    for _, row in rows do width = math.max(width, row.w) height += row.h end
    local maximum = math.max(1, g.size.w - 2 * padding)
    local scale = if #panels > 0 then math.min(1,
        math.max(1, maximum - 2 * padding - gap * (columns - 1)) / width,
        math.max(1, math.min(g.room.y + g.room.h, 0.65 * g.size.h) - top - padding - gap * (#rows - 1)) / math.max(1, height)) else 1
    local w = math.min(maximum, math.max(900, width * scale + 2 * padding + gap * (columns - 1)))
    local x = (g.size.w - w) / 2
    local slots, nextY = {}, top
    for _, row in rows do
        local nextX = x + padding
        for _, panel in row.items do
            slots[panel.id] = { x = nextX, y = nextY, scale = scale }
            nextX += panel.w * scale + gap
        end
        nextY += row.h * scale + gap
    end
    return { x = x, y = 0, w = w, h = if #panels == 0 then top + 64 * g.k.u else nextY - gap + padding,
        slots = slots, empty = #panels == 0 }

end

local function geometry(ctx, id: string, home, g, storage)
    local value = record(ctx, id)
    local panel = table.clone(home)
    panel.home = { x = home.x, y = home.y, w = home.w, h = home.h }
    panel.window, panel.loose = id, value.location ~= "home" or value.held == true
    panel.held = value.held == true
    panel.side = if value.location == "edge" then value.side else nil
    panel.commit, panel.bounds, panel.storage = value.commit, g.room, storage
    panel.close = function(next)
        redock(next, id)
        dismiss(next, id)
        if next.state.drawerPanel == id then home.close(next) end
    end
    if not value.glass then
        value.glass = "drawer"
        for other, item in ctx.state.windows do
            if other ~= id and item.glass == "drawer" and detached(ctx, other) then value.glass = "drawer-" .. id end
        end
    end
    panel.key = value.glass
    if value.location == "drawer" and storage and storage.slots[id] then
        local slot = storage.slots[id]
        panel.x, panel.y = slot.x, slot.y
        panel.w, panel.h, panel.cu, panel.rs = home.w * slot.scale, home.h * slot.scale, home.cu * slot.scale, home.rs * slot.scale
        panel.header = (home.header or 0) * slot.scale
    elseif value.rect then
        panel.x = math.clamp(value.rect.x, g.room.x, math.max(g.room.x, g.room.x + g.room.w - panel.w))
        panel.y = math.clamp(value.rect.y, g.room.y, math.max(g.room.y, g.room.y + g.room.h - panel.h))
        if panel.side then
            local snapped = stick.snap({ x = panel.x, y = panel.y, w = panel.w, h = panel.h }, g.room, panel.side)
            panel.x, panel.y = snapped.x, snapped.y
        end
    end
    if panel.loose then panel.top, panel.bodyH = panel.y, panel.h end
    return panel
end

local function resolve(item, event, panel, width)
    local cu = panel.cu
    local rect, home, bounds = event.rect, panel.home, panel.bounds
    local storage = panel.storage
    local grab = item.grab
    local x = rect.x + (if grab then rect.w * grab.x else (panel.w - width) / 2 + (event.x or width / 2))
    local y = rect.y + (if grab then rect.h * grab.y else (panel.gripY or 0) + (event.y or 5 * cu))
    local distance = if panel.homePriority and grab
        then math.sqrt((x - home.x - home.w * grab.x) ^ 2 + (y - home.y - home.h * grab.y) ^ 2)
        else math.sqrt((rect.x - home.x) ^ 2 + (rect.y - home.y) ^ 2)
    local parent = panel.homeParent
    local insideParent = parent and x >= parent.x and x <= parent.x + parent.w and y >= parent.y and y <= parent.y + parent.h
    local nearHome = panel.homeEnabled ~= false and panel.homeLocation ~= "drawer" and (insideParent or distance <= 60 * cu)
    if storage and x >= storage.x and x <= storage.x + storage.w and y >= storage.y and y <= storage.y + storage.h
        and not (panel.homePriority and nearHome) then
        item.location, item.rect, item.side = "drawer", nil, nil
    elseif nearHome then
        item.location, item.rect, item.side = panel.homeLocation or "home", nil, nil
    else
        local side = stick.nearest(rect, bounds, item.side, 40 * cu)
        item.side = side
        item.location = if side then "edge" else "floating"
        item.rect = if side then stick.snap({ x = rect.x, y = rect.y, w = home.w, h = home.h }, bounds, side)
            else { x = rect.x, y = rect.y }
    end
end

local function grip(ctx, panel, access)
    local read = access or record
    local id, cu = panel.window, panel.cu
    local value = read(ctx, id)
    local width = math.min(panel.w, math.max(60, 120 * cu))
    local height = if panel.gripH then panel.gripH * cu else math.max(10, 10 * cu)
    local bounds = panel.bounds
    return ui.stack({ key = "window-grip-" .. id, align = "topLeading",
        dx = (panel.w - width) / 2, dy = panel.gripY, w = width, h = height, cursor = "grab",
        help = panel.help or ("Drag to move or store in the top shelf. " .. dockHints[id]),
        gesture = { axis = "free", threshold = 4, track = {
            mode = "move", target = panel.target or "drawer-content-" .. id,
            bounds = { x = bounds.x - panel.w, y = -panel.h,
                w = bounds.w + 2 * panel.w, h = bounds.y + bounds.h + 2 * panel.h },
            min = { w = panel.w, h = panel.h }, max = { w = panel.w, h = panel.h },
        } },
        onPress = function(next, event)
            if event.phase == "down" then
                read(next, id).grab = { x = ((panel.w - width) / 2 + (event.x or width / 2)) / panel.w,
                    y = ((panel.gripY or 0) + (event.y or height / 2)) / panel.h }
            end
        end,
        onGesture = function(next, event)
            local item = read(next, id)
            if event.phase == "began" then
                item.held = true
                if panel.cardScale then item.scale = panel.cardScale end
                return
            end
            if event.phase ~= "ended" and event.phase ~= "cancelled" then return end
            item.held = nil
            if event.phase == "cancelled" or not event.rect then item.grab = nil return end
            resolve(item, event, panel, width)
            item.grab = nil
            if panel.onRelease then panel.onRelease(item, event) end
            item.commit = event.transaction
        end,
        ui.box({ key = "window-grip-line-" .. id, decorative = true, w = math.max(24, 48 * cu), h = math.max(2, 3 * cu),
            radius = 1.5 * cu, fill = palette.alpha("ink", if value.held then 0.8 else 0.5) }),
    })
end

return table.freeze({ order = order, detached = detached, stored = stored, held = held, visible = visible,
    redock = redock, dismiss = dismiss, shelf = shelf, geometry = geometry, grip = grip, resolve = resolve })

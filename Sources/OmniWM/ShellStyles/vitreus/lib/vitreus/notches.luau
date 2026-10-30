-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local order = table.freeze({ "left", "middle", "right" })
local sides = table.freeze({
    apple = "left", app = "left", workspaces = "left", clock = "middle", title = "middle", tray = "middle",
    privacy = "middle", search = "right", gear = "right", controls = "right",
})

local function below(island): number
    local notch = island and island.notch
    return if notch then notch.h else 0
end

local function geometry(k, size, widths, island)
    local bu = k.bu
    local pad, inset, gap, lift, depth, slope = 14 * bu, 12 * bu, 12 * bu, 12 * bu, 36 * bu, 12 * bu
    local function span(name: string): number
        return if widths[name] then widths[name].w else 0
    end
    local function room(name: string): number
        return if span(name) > 0 then span(name) + gap else 0
    end
    local tray = span("tray") + span("privacy")
    local trayRoom = if tray > 0 then tray + gap else 0
    local lead, title = if widths.title then 14 * bu else 0, if widths.title then 150 * bu else 0
    local clock = span("clock")
    local cl = size.w / 2 - (lead + title + trayRoom) / 2 - clock / 2
    local te = cl + clock + lead + title
    local right = size.w - inset - pad
    local trayX = te + trayRoom - tray
    local start = inset + pad
    local x = {
        apple = start, app = start + room("apple"), workspaces = start + room("apple") + room("app"),
        clock = cl, title = te - title, tray = trayX, privacy = trayX,
        controls = right - span("controls"), gear = right - room("controls") - span("gear"),
        search = right - room("controls") - room("gear") - span("search"),
    }
    local function piece(name: string, from: number, to: number, top: number?)
        local y = top or 0
        local cy = y + depth / 2
        return {
            name = name, x = from, y = y, w = to - from, h = depth, cx = (from + to) / 2, cy = cy,
            radius = 14 * bu, gap = gap, left = from, right = to, corner = (depth + lift) * 0.34,
            box = table.freeze({ x = if name == "left" then -lift else from, y = -lift,
                w = to - from + (if name == "middle" then 0 else lift), h = y + depth + lift }),
            strip = table.freeze({ x = 0, y = cy - 28 * bu, w = size.w, h = 56 * bu, cx = size.w / 2, cy = cy,
                reach = cy + lift }),
        }
    end
    local pieces = {
        middle = piece("middle", cl - pad - slope, te + trayRoom + pad + slope, below(island)),
        right = piece("right", right - room("controls") - room("gear") - room("search") + gap - pad - slope, size.w),
    }
    local marks = widths.workspaces
    local reach = if marks then x.workspaces + (marks.extent or marks.w) - 9 * bu else x.workspaces - gap
    if reach > start then pieces.left = piece("left", 0, reach + pad + slope) end
    local slots = {}
    for name, side in sides do
        if widths[name] and pieces[side] then
            local w = if name == "title" then title elseif name == "tray" or name == "privacy" then tray else span(name)
            slots[name] = table.freeze({ x = x[name], w = w, cx = x[name] + w / 2, piece = pieces[side] })
        end
    end
    table.freeze(slots)
    local list = {}
    for _, side in order do
        local value = pieces[side]
        if value then
            value.slots = slots
            list[#list + 1] = table.freeze(value)
        end
    end
    return table.freeze({ pieces = table.freeze(list), pill = pieces.middle, strip = pieces.middle.strip })
end

local function shapes(_, g)
    local f = g.frame
    if not f or not f.pieces then return nil end
    local items = {}
    for _, piece in f.pieces do
        local box = piece.box
        local rest = math.clamp((f.thickness - box.y) / box.h, 0, 1)
        items[#items + 1] = ui.shape({ key = "notch-" .. piece.name, align = "topLeading",
            dx = box.x, dy = box.y, w = box.w, h = box.h, radius = piece.corner, animate = g.calm, reveal = g.calm,
            morph = { stops = { { at = 0, h = rest, dy = (rest - 1) * box.h / 2 }, { at = 1, h = 1 } } },
        })
    end
    return items
end

local function none()
    return nil
end

return table.freeze({ below = below, geometry = geometry, shapes = shapes, content = none })

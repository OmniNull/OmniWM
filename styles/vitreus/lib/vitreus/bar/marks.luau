-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("../../look")
local palette = require("../palette")
local pencil = require("../pencil")
local kit = require("../kit")
local buttons = require("./buttons")

local edges = table.freeze({ lead = { response = 0.142, bounce = 0 }, trail = { response = 0.378, bounce = 0 } })
local quick = table.freeze({ response = 2 * math.pi / math.sqrt(420), bounce = 1 - 40 / (2 * math.sqrt(420)) })
local frequencies = table.freeze({ 67, 54, 73, 62, 52, 69, 59, 47 })
local mostIcons, iconSide, iconStep, iconLead, iconRoom = 4, 16, 18, 3, 0.4
local nameSize, namePadding = 8, 3
local nameWidths = {}
local arm

local function state(ctx)
    if not ctx.state.marks then ctx.state.marks = { frame = 0 } end
    return ctx.state.marks
end

local function cancel(s)
    if s.timer then s.timer:cancel() s.timer = nil end
    s.frame = 0
end

arm = function(s)
    if s.timer or not s.enabled or not (s.hover or s.special) then return end
    local timer
    timer = omniwm.after(0.2, function()
        if s.timer ~= timer then return end
        s.timer = nil
        s.frame += 1
        arm(s)
    end)
    s.timer = timer
end

local function sync(s)
    if s.enabled and (s.hover or s.special) then arm(s) else cancel(s) end
end

local function nameWidth(ctx, name: string, u: number): number
    local size = nameSize * u
    local key = name .. "\0" .. size
    local width = nameWidths[key]
    if not width then
        width = ctx.format.measure(name, { font = kit.font, size = size, weight = "semibold" })
        nameWidths[key] = width
    end
    return width
end

local function fitted(ctx, workspace, least: number, u: number, vertical: boolean?): number
    if vertical or not ctx.data.bar.style.labels then return least end
    return math.max(least, nameWidth(ctx, workspace.name, u) + 2 * namePadding * u)
end

local function markSpan(ctx, workspace, u: number, vertical: boolean?): number
    return fitted(ctx, workspace, (if workspace.focused then 29 else 12.5) * u, u, vertical)
end

local function iconRun(workspace, cap: number, u: number): number
    local count = #workspace.windows
    return if cap > 0 and count > 0 then (iconLead + math.min(count, cap + 1) * iconStep) * u else 0
end

local function iconCap(ctx, workspaces, vertical: boolean, u: number): number
    local island = ctx.data.island
    if not island or not island.size then return mostIcons end
    local room = if vertical then iconRoom * island.size.h
        elseif island.notch then island.notch.x else iconRoom * island.size.w
    for cap = mostIcons, 1, -1 do
        local length = 0
        for _, workspace in workspaces do
            length += markSpan(ctx, workspace, u, vertical) + 9 * u + iconRun(workspace, cap, u)
        end
        if length <= room then return cap end
    end
    return 0
end

local function model(ctx, k)
    local bar = ctx.data.bar
    local layout = (ctx.data.settings or {}).layout
    local vertical = layout == "left" or layout == "right"
    local u = if vertical then k.bcu else k.bu
    local rows, special = {}, nil
    if not bar or not bar.style then return { rows = rows, w = 128 * u } end
    for _, pad in bar.scratchpads or {} do
        if pad.visible then special = pad break end
    end
    local length = 0
    if not special then
        local cap = iconCap(ctx, bar.workspaces or {}, vertical, u)
        for _, workspace in bar.workspaces or {} do
            local span = markSpan(ctx, workspace, u, vertical)
            local run = iconRun(workspace, cap, u)
            rows[#rows + 1] = { workspace = workspace, busy = #workspace.windows > 0, x = length + span / 2, w = span,
                run = run, cap = cap }
            length += span + 9 * u + run
        end
    end
    local row = if special then 35 * u else length
    return {
        rows = rows, special = special,
        w = math.max(128 * u, row),
        row = row,
        available = special ~= nil or #(bar.workspaces or {}) > 0,
    }
end

local function width(ctx, k): (number, number)
    local w = model(ctx, k).w
    return w, w - 128 * k.bu
end

local function extent(ctx, k): number?
    return model(ctx, k).row
end

local function flow(ctx, k)
    local m, u = model(ctx, k), k.bu
    if m.special then return { { key = "special", w = 26 * u, at = 13 * u } } end
    local cells = {}
    for _, row in m.rows do
        local width = row.w + 9 * u
        cells[#cells + 1] = { key = "workspace-" .. row.workspace.id, w = width + row.run, at = width / 2,
            focused = row.workspace.focused }
    end
    return cells
end

local function prepare(ctx, g)
    local s, m = state(ctx), model(ctx, g.k)
    local slot = g.pill and g.pill.slots.workspaces
    local positions = slot and slot.positions
    local function placed(key: string): boolean
        return not positions or positions[key] ~= nil
    end
    s.enabled = g.island.visible ~= false and slot ~= nil and not slot.hidden and m.available == true
    s.special = if s.enabled and m.special and placed("special") then m.special.id else nil
    local valid = {}
    if s.special then valid["workspace-special"] = true end
    for _, row in m.rows do
        if placed("workspace-" .. row.workspace.id) then valid["workspace-hit-" .. row.workspace.id] = true end
    end
    if not s.enabled or not valid[s.hover] then s.hover = nil end
    sync(s)
end

local function hovered(ctx, key: string)
    return function(next, event)
        local s = state(next)
        if event.phase == "began" then s.hover = key elseif s.hover == key then s.hover = nil end
        sync(s)
    end
end

local function zone(ctx, g, key: string, x: number, w: number, command: string)
    local vertical = g.frame and g.frame.vertical
    local h = if vertical then 40 * g.k.bu else g.pill.h
    return ui.box({ key = key, w = if vertical then h else w, h = if vertical then w else h,
        dx = if vertical then g.pill.cx - h / 2 else x - w / 2,
        dy = if vertical then x - w / 2 else g.pill.cy - h / 2, align = "topLeading",
        cursor = "pointer", onClick = command, onHover = hovered(ctx, key) })
end

local function dropArea(g, row, x: number, u: number)
    local vertical = g.frame and g.frame.vertical
    local across = if vertical then 40 * g.k.bu else g.pill.h
    local mark = row.w + 9 * u
    local along = mark + row.run
    return ui.box({ key = "workspace-drop-" .. row.workspace.id, align = "topLeading",
        target = "workspace " .. row.workspace.id, drop = true,
        w = if vertical then across else along, h = if vertical then along else across,
        dx = if vertical then g.pill.cx - across / 2 else x - mark / 2,
        dy = if vertical then x - mark / 2 else g.pill.cy - across / 2 })
end

local function listed(list, value): boolean
    return list ~= nil and table.find(list, value) ~= nil
end

local function dropTarget(ctx, id: string): boolean
    local drag = ctx.data.bar.drag
    return drag ~= nil and listed(drag.workspaces, id)
end

local function gapBefore(drag, id: string): number?
    for _, gap in drag.gaps do
        if gap.workspace == id then return gap.before end
    end
    return nil
end

local function append(list, items)
    for _, item in items do list[#list + 1] = item end
end

local function outline(ctx, g, key: string, cx: number, w: number, h: number, hot: number, active: boolean, amount: number)
    local vertical = g.frame and g.frame.vertical
    local centerX, centerY = if vertical then g.pill.cx else cx, if vertical then cx else g.pill.cy
    if vertical then w, h = h, w end
    local margin = math.max(w, h) / 2 + 4 * g.k.bu
    local frame = if hot > 0 then state(ctx).frame else 0
    if active then
        local paths = pencil.draw(g.size.w, g.size.h,
            pencil.outline(centerX, centerY, w, h, g.k.bu, hot, frame), palette.roles.mint, amount)
        for index, path in paths do
            path.key = key .. "-" .. index
            path.morph = { track = "workspace-pill-shape" }
        end
        return ui.stack({ key = key, w = g.size.w, h = g.size.h, align = "topLeading", decorative = true,
            table.unpack(paths) })
    end
    local paths = pencil.draw(2 * margin, 2 * margin,
        pencil.outline(margin, margin, w, h, g.k.bu, hot, frame), palette.roles.ink, amount)
    for index, path in paths do path.key = key .. "-" .. index path.animate = kit.springs.pop end
    local props = { key = key, dx = centerX - margin, dy = centerY - margin, w = 2 * margin, h = 2 * margin,
        align = "topLeading", decorative = true, animate = g.calm }
    append(props, paths)
    return ui.stack(props)
end

local function mark(ctx, g, row, cx: number)
    local vertical = g.frame and g.frame.vertical
    local id, u = row.workspace.id, if vertical then g.k.bcu else g.k.bu
    local hot = if state(ctx).hover == "workspace-hit-" .. id or dropTarget(ctx, id) then 1 else 0
    local grow = 1 + 0.35 * hot
    local least = (if row.busy or ctx.data.bar.style.labels then 12.5 else 8) * u
    local w, h = grow * fitted(ctx, row.workspace, least, u, vertical), grow * least
    local amount = math.min(1, (if row.busy then 0.85 else 0.30) + 0.35 * hot)
    if row.workspace.focused then amount = 0 end
    local extent = 24 * u
    local wide = math.max(extent, w + 7 * u)
    local body = ui.glass({ key = "workspace-mark-" .. id, w = wide, h = extent,
        dx = 0, dy = 0, align = "topLeading", backdrop = false,
        fill = palette.roles.ink, opacity = 0.55 * amount, rim = 0.40, blend = 0, animate = quick,
        ui.shape({ key = "workspace-square-" .. id, w = w, h = h, dx = (wide - w) / 2,
            dy = (extent - h) / 2, align = "topLeading", radius = 0.3 * h, animate = kit.springs.pop }),
    })
    local localG = { k = g.k, pill = { cy = extent / 2 } }
    return ui.stack(buttons.glow({ key = "workspace-mark-halo-" .. id, w = wide, h = extent,
        dx = (if vertical then g.pill.cx else cx) - wide / 2,
        dy = (if vertical then cx else g.pill.cy) - extent / 2, align = "topLeading", decorative = true,
        body, outline(ctx, localG, "workspace-outline-" .. id, wide / 2, w, h, hot, false, amount),
    }, g.k.bu))
end

local function name(ctx, g, row, cx: number)
    if not ctx.data.bar.style.labels then return nil end
    local vertical = g.frame and g.frame.vertical
    local id, u = row.workspace.id, if vertical then g.k.bcu else g.k.bu
    local focused = row.workspace.focused
    local hot = if state(ctx).hover == "workspace-hit-" .. id or dropTarget(ctx, id) then 1 else 0
    local w, h = if vertical then (if focused then 15 else 12.5) * u else row.w, 15 * u
    return ui.stack({ key = "workspace-name-" .. id, w = w, h = h, align = "topLeading", decorative = true,
        dx = (if vertical then g.pill.cx else cx) - w / 2, dy = (if vertical then cx else g.pill.cy) - h / 2,
        ui.text({ key = "workspace-name-text-" .. id, text = row.workspace.name, font = kit.font, size = nameSize * u,
            weight = "semibold", maxWidth = w, lines = 1,
            color = if focused then palette.roles.onmint else palette.roles.ink, animate = kit.springs.slide,
            opacity = if focused then 1 else math.min(1, (if row.busy then 0.85 else 0.5) + 0.35 * hot) }),
    })
end

local function iconOpacity(item, workspace): number
    if item.count > 0 and item.hidden == item.count then return 0.4 end
    if item.focused then return 1 end
    return if workspace.focused then 0.75 else 0.55
end

local function countBadge(count: number, u: number)
    local size = 10 * u
    return ui.row({ align = "topTrailing", dx = 3 * u, dy = -2 * u, h = size, radius = size / 2, fill = "surface",
        ui.box({ w = 2 * u, h = 1 }),
        ui.text({ text = tostring(count), font = kit.font, size = 8 * u, weight = "semibold", color = palette.roles.ink }),
        ui.box({ w = 2 * u, h = 1 }) })
end

local function icons(ctx, g, row, centre: number)
    local vertical = g.frame and g.frame.vertical
    local u = if vertical then g.k.bcu else g.k.bu
    local side, items = iconSide * u, {}
    local workspace, badges, drag = row.workspace, ctx.data.bar.badges, ctx.data.bar.drag
    local at = centre + row.w / 2 + iconLead * u
    local metrics = { icon = side, slot = side, margin = 0, scale = u }
    local gap = drag and gapBefore(drag, workspace.id)
    local function located(props, index: number)
        local along = at + (if gap then (if index < gap then -0.2 else 0.2) * side else 0)
        props.align = "topLeading"
        props.dx = if vertical then g.pill.cx - side / 2 else along
        props.dy = if vertical then along else g.pill.cy - side / 2
        if drag then props.animate = quick end
        at += iconStep * u
        return props
    end
    for index, item in workspace.windows do
        if row.cap == 0 then break end
        if index > row.cap then
            items[#items + 1] = ui.stack(located({ key = "workspace-more-" .. workspace.id, w = side, h = side,
                decorative = true,
                ui.text({ text = "+" .. tostring(#workspace.windows - row.cap), font = kit.font, size = 11 * u,
                    weight = "semibold", color = palette.roles.ink }) }, index))
            break
        end
        local node = { key = "workspace-icon-" .. workspace.id .. "-" .. item.id, w = side, h = side,
            cursor = "pointer", help = item.name, onClick = "window focus " .. item.id,
            target = "window " .. item.id, menu = true, preview = true, drag = true, hoverScale = 1.1,
            hoverAnimate = 0.1,
            ui.icon({ key = "workspace-glyph-" .. workspace.id .. "-" .. item.id, window = item.id,
                placeholder = "app.dashed", w = side, h = side,
                opacity = if drag and listed(drag.sources, item.id) then 0.35 else iconOpacity(item, workspace) }) }
        if drag and listed(drag.icons, item.id) then
            node.border = palette.roles.mint
            node.borderWidth = 1.5 * u
            node.radius = 0.3 * side
        end
        if item.count > 1 then node[#node + 1] = countBadge(item.count, u) end
        if badges ~= "off" and item.badge ~= "" then
            node[#node + 1] = look.notificationBadge(item, badges, metrics)
        end
        items[#items + 1] = ui.stack(located(node, index))
    end
    return items
end

local function pill(ctx, g, span: number, cx: number)
    local vertical = g.frame and g.frame.vertical
    local u = if vertical then g.k.bcu else g.k.bu
    return ui.glass({ key = "workspace-pill", w = if vertical then 15 * u else g.size.w,
        h = if vertical then g.size.h else 15 * u,
        dx = if vertical then g.pill.cx - 7.5 * u else 0, dy = if vertical then 0 else g.pill.cy - 7.5 * u,
        align = "topLeading", backdrop = false, rim = 0.55, blend = 0, opacity = 0.55, animate = g.calm,
        gradient = { from = palette.roles.minthi, to = palette.roles.mintlo, angle = if vertical then 0 else 90 },
        shadow = palette.alpha("mint", 0.30), shadowRadius = 7 * g.k.bu, shadowOffset = { x = 0, y = 0 },
        ui.shape({ key = "workspace-pill-shape", w = if vertical then 15 * u else span,
            h = if vertical then span else 15 * u, dx = if vertical then 0 else cx - span / 2,
            dy = if vertical then cx - span / 2 else 0, align = "topLeading", radius = 4.5 * u,
            morph = { edges = { lead = edges.lead, trail = edges.trail, thin = 0.18, unit = 29.75 * u } } }),
    })
end

local function specialPaths(g, pad, frame: number, scale: number?)
    local u = g.k.u
    local k = 9 * (scale or 1) * (if g.frame and g.frame.vertical then g.k.bcu else g.k.bu)
    local kind = string.lower(pad.name)
    local seed = if kind == "music" then 41037 elseif kind == "private" then 42221 else 31037
    local n, list = 0, {}
    local function point(x: number, y: number, ox: number, oy: number)
        local values = {}
        for axis, value in { x, y } do
            values[axis] = value * k + (if axis == 1 then ox else oy)
                + 0.4 * u * pencil.wave(frame, frequencies[n % #frequencies + 1], seed + 37 * n)
            n += 1
        end
        return string.format("%.3f %.3f", values[1], values[2])
    end
    local function stroke(parts, width: number, opacity: number, ox: number?, oy: number?)
        for pass = 0, 1 do
            local x, y = (ox or 0) + pass * 0.5 * u, (oy or 0) + pass * 0.4 * u
            local words = {}
            for _, part in parts do
                if part[1] == "Q" then
                    local target = point(part[2], part[3], x, y)
                    words[#words + 1] = "Q " .. point(part[4], part[5], x, y) .. " " .. target
                elseif part[1] == "Z" then words[#words + 1] = "Z"
                else words[#words + 1] = part[1] .. " " .. point(part[2], part[3], x, y) end
            end
            list[#list + 1] = { d = table.concat(words, " "), width = width * u * (if pass == 0 then 1 else 0.7),
                alpha = opacity * (if pass == 0 then 1 else 0.34) }
        end
    end
    local function disc(x: number, y: number, radius: number)
        for pass = 0, 1 do
            local centre = point(x, y, pass * 0.5 * u, pass * 0.4 * u)
            local xy = string.split(centre, " ")
            local cx, cy, r = tonumber(xy[1]), tonumber(xy[2]), radius * k
            list[#list + 1] = { d = string.format("M %.3f %.3f A %.3f %.3f 0 1 1 %.3f %.3f A %.3f %.3f 0 1 1 %.3f %.3f Z",
                cx, cy - r, r, r, cx, cy + r, r, r, cx, cy - r), alpha = if pass == 0 then 1 else 0.34 }
        end
    end
    if kind == "music" then
        stroke({ { "M", -0.4, 0.45 }, { "L", -0.4, -0.75 } }, 1.5, 1)
        stroke({ { "M", 0.6, 0.25 }, { "L", 0.6, -0.95 } }, 1.5, 1)
        stroke({ { "M", -0.4, -0.75 }, { "L", 0.6, -0.95 } }, 2.2, 1)
        disc(-0.65, 0.55, 0.3)
        disc(0.35, 0.35, 0.3)
    elseif kind == "private" then
        stroke({ { "M", -1, 0 }, { "Q", 1, 0, 0, -1.15 }, { "Q", -1, 0, 0, 1.15 }, { "Z" } }, 1.5, 1)
        stroke({ { "M", -0.75, 0.85 }, { "L", 0.75, -0.85 } }, 1.8, 1)
        disc(0, 0, 0.24)
    else
        stroke({ { "M", 0, -1 }, { "Q", 1, 0, 0.12, -0.12 }, { "Q", 0, 1, 0.12, 0.12 },
            { "Q", -1, 0, -0.12, 0.12 }, { "Q", 0, -1, -0.12, -0.12 }, { "Z" } }, 1.5, 1)
        stroke({ { "M", 0, -0.36 }, { "Q", 0.36, 0, 0.043, -0.043 }, { "Q", 0, 0.36, 0.043, 0.043 },
            { "Q", -0.36, 0, -0.043, 0.043 }, { "Q", 0, -0.36, -0.043, -0.043 }, { "Z" } },
            1.2, 0.8, 0.95 * k, -0.8 * k)
    end
    return list
end

local function content(ctx, g, slot)
    if not g.pill or not slot then return nil end
    local vertical = g.frame and g.frame.vertical
    local m, s, u = model(ctx, g.k), state(ctx), if vertical then g.k.bcu else g.k.bu
    if not s.enabled then return nil end
    local items = {}
    local origin = if vertical then 8 * g.k.u + 14 * g.k.bcu else slot.x
    if m.special then
        local centre = if slot.positions then slot.positions.special else origin + 13 * u
        if not centre then return items end
        local paths = pencil.draw(40 * u, 40 * u, specialPaths(g, m.special, s.frame), palette.roles.mint)
        local props = { key = "workspace-special-glyph", w = 40 * u, h = 40 * u,
            dx = if vertical then g.pill.cx else centre, dy = if vertical then centre else g.pill.cy,
            align = "topLeading", decorative = true }
        append(props, paths)
        items[#items + 1] = ui.stack(buttons.glow(props, g.k.bu))
        items[#items + 1] = zone(ctx, g, "workspace-special", centre, 26 * u, "scratchpad toggle " .. m.special.id)
        return items
    end
    for _, row in m.rows do
        local centre = if slot.positions then slot.positions["workspace-" .. row.workspace.id] else origin + row.x
        if not centre then continue end
        items[#items + 1] = mark(ctx, g, row, centre)
        if row.workspace.focused then
            items[#items + 1] = pill(ctx, g, row.w, centre)
            local hoveredAny = if (s.hover and string.sub(s.hover, 1, 14) == "workspace-hit-")
                or dropTarget(ctx, row.workspace.id) then 1 else 0
            items[#items + 1] = outline(ctx, g, "workspace-pill-outline", centre, row.w, 15 * u, hoveredAny, true, 1)
        end
        items[#items + 1] = name(ctx, g, row, centre)
        items[#items + 1] = zone(ctx, g, "workspace-hit-" .. row.workspace.id, centre, row.w + 9 * u,
            "switch-workspace " .. row.workspace.id)
        items[#items + 1] = dropArea(g, row, centre, u)
        append(items, icons(ctx, g, row, centre))
    end
    return items
end

local function shapes()
    return nil
end

return table.freeze({ width = width, extent = extent, flow = flow, prepare = prepare, shapes = shapes, content = content,
    specialPaths = specialPaths })

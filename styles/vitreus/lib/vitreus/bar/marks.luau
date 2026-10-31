-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("../palette")
local pencil = require("../pencil")
local kit = require("../kit")
local buttons = require("./buttons")

local edges = table.freeze({ lead = { response = 0.142, bounce = 0 }, trail = { response = 0.378, bounce = 0 } })
local quick = table.freeze({ response = 2 * math.pi / math.sqrt(420), bounce = 1 - 40 / (2 * math.sqrt(420)) })
local frequencies = table.freeze({ 67, 54, 73, 62, 52, 69, 59, 47 })
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

local function model(ctx, k)
    local bar = ctx.data.bar
    local layout = (ctx.data.settings or {}).layout
    local u = if layout == "left" or layout == "right" then k.bcu else k.bu
    local rows, active, empty, special = {}, nil, nil, nil
    if not bar or not bar.style then return { rows = rows, w = 128 * u } end
    for _, pad in bar.scratchpads or {} do
        if pad.visible then special = pad break end
    end
    local length = 0
    for _, workspace in bar.workspaces or {} do
        local busy = #workspace.windows > 0
        if workspace.focused then active = workspace end
        if not busy and not workspace.focused and not empty then empty = workspace end
        if not special and (busy or workspace.focused) then
            local span = (if workspace.focused then 29 else 12.5) * u
            rows[#rows + 1] = { workspace = workspace, busy = busy, x = length + span / 2, w = span }
            length += span + 9 * u
        end
    end
    local row = 25.5 * u + (if special then 9 * u else length + 14 * u)
    return {
        rows = rows, active = active, special = special,
        plus = if not special and active and #active.windows > 0 then empty else nil,
        plusX = length + 7 * u,
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
    local cells = { { key = "overview", w = 25.5 * u, at = 10 * u } }
    if m.special then
        cells[#cells + 1] = { key = "special", w = 26 * u, at = 13 * u }
    else
        for _, row in m.rows do
            local width = row.w + 9 * u
            cells[#cells + 1] = { key = "workspace-" .. row.workspace.id, w = width, at = width / 2 }
        end
        if m.plus then cells[#cells + 1] = { key = "plus", w = 23 * u, at = 11.5 * u } end
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
    local valid = { ["workspace-overview"] = true }
    if s.special then valid["workspace-special"] = true end
    if m.plus and placed("plus") then valid["workspace-new"] = true end
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

local function zone(ctx, g, key: string, x: number, w: number, command: string, height: number?)
    local vertical = g.frame and g.frame.vertical
    local h = height or (if vertical then 40 * g.k.bu else g.pill.h)
    return ui.box({ key = key, w = if vertical then h else w, h = if vertical then w else h,
        dx = if vertical then g.pill.cx - h / 2 else x - w / 2,
        dy = if vertical then x - w / 2 else g.pill.cy - h / 2, align = "topLeading",
        cursor = "pointer", onClick = command, onHover = hovered(ctx, key) })
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
    local hot = if state(ctx).hover == "workspace-hit-" .. id then 1 else 0
    local side = (if row.busy then 12.5 else 8) * u * (1 + 0.35 * hot)
    local amount = math.min(1, (if row.busy then 0.85 else 0.30) + 0.35 * hot)
    if row.workspace.focused then amount = 0 end
    local extent = 24 * u
    local body = ui.glass({ key = "workspace-mark-" .. id, w = extent, h = extent,
        dx = 0, dy = 0, align = "topLeading", backdrop = false,
        fill = palette.roles.ink, opacity = 0.55 * amount, rim = 0.40, blend = 0, animate = quick,
        ui.shape({ key = "workspace-square-" .. id, w = side, h = side, dx = (extent - side) / 2,
            dy = (extent - side) / 2, align = "topLeading", radius = 0.3 * side, animate = kit.springs.pop }),
    })
    local localG = { k = g.k, pill = { cy = extent / 2 } }
    return ui.stack(buttons.glow({ key = "workspace-mark-halo-" .. id, w = extent, h = extent,
        dx = (if vertical then g.pill.cx else cx) - extent / 2,
        dy = (if vertical then cx else g.pill.cy) - extent / 2, align = "topLeading", decorative = true,
        body, outline(ctx, localG, "workspace-outline-" .. id, extent / 2, side, side, hot, false, amount),
    }, g.k.bu))
end

local function pill(ctx, g, slot, cx: number)
    local vertical = g.frame and g.frame.vertical
    local u = if vertical then g.k.bcu else g.k.bu
    return ui.glass({ key = "workspace-pill", w = if vertical then 15 * u else g.size.w,
        h = if vertical then g.size.h else 15 * u,
        dx = if vertical then g.pill.cx - 7.5 * u else 0, dy = if vertical then 0 else g.pill.cy - 7.5 * u,
        align = "topLeading", backdrop = false, rim = 0.55, blend = 0, opacity = 0.55, animate = g.calm,
        gradient = { from = palette.roles.minthi, to = palette.roles.mintlo, angle = if vertical then 0 else 90 },
        shadow = palette.alpha("mint", 0.30), shadowRadius = 7 * g.k.bu, shadowOffset = { x = 0, y = 0 },
        ui.shape({ key = "workspace-pill-shape", w = if vertical then 15 * u else 29 * u,
            h = if vertical then 29 * u else 15 * u, dx = if vertical then 0 else cx - 14.5 * u,
            dy = if vertical then cx - 14.5 * u else 0, align = "topLeading", radius = 4.5 * u,
            morph = { edges = { lead = edges.lead, trail = edges.trail, thin = 0.18, unit = 29.75 * u } } }),
    })
end

local function plus(ctx, g, cx: number)
    local vertical = g.frame and g.frame.vertical
    local u = if vertical then g.k.bcu else g.k.bu
    local hot = if state(ctx).hover == "workspace-new" then 1 else 0
    local extent, length = 20 * u, 14 * 0.62 * u * (1 + 0.3 * hot)
    local body = ui.glass({ key = "workspace-plus", w = extent, h = extent, dx = 0,
        dy = 0, align = "topLeading", backdrop = false, fill = palette.roles.ink,
        opacity = 0.55 + 0.40 * hot, rim = 0.30, blend = 0, animate = kit.springs.pop,
        ui.shape({ key = "workspace-plus-h", w = length, h = 1.6 * u, radius = 0.8 * u,
            dx = (extent - length) / 2, dy = (extent - 1.6 * u) / 2, align = "topLeading",
            animate = kit.springs.pop }),
        ui.shape({ key = "workspace-plus-v", w = 1.6 * u, h = length, radius = 0.8 * u,
            dx = (extent - 1.6 * u) / 2, dy = (extent - length) / 2, align = "topLeading",
            animate = kit.springs.pop }),
    })
    return ui.stack(buttons.glow({ key = "workspace-plus-halo", w = extent, h = extent,
        dx = (if vertical then g.pill.cx else cx) - extent / 2,
        dy = (if vertical then cx else g.pill.cy) - extent / 2, align = "topLeading", decorative = true, body,
    }, g.k.bu))
end

local function specialPaths(g, pad, frame: number)
    local u = g.k.u
    local k = 9 * (if g.frame and g.frame.vertical then g.k.bcu else g.k.bu)
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
    local hot = if s.hover == "workspace-overview" then 1 else 0
    local cx = if slot.positions then slot.positions.overview
        elseif vertical then 8 * g.k.u + 24 * g.k.bcu else slot.x + 10 * u
    local overview = pencil.draw(40 * u, 40 * u,
        pencil.icon("overview", 20 * u, 20 * u, 18 * u * (1 + 0.2 * hot), hot, if hot > 0 then s.frame else 0, u, 1.3 * u),
        palette.roles.ink, { 0.45 + 0.35 * hot, 0.7 + 0.3 * hot, 0.7 + 0.3 * hot })
    items[#items + 1] = ui.stack(buttons.glow(buttons.append({ key = "workspace-overview-icon",
        w = 40 * u, h = 40 * u, dx = (if vertical then g.pill.cx else cx) - 20 * u,
        dy = (if vertical then cx else g.pill.cy) - 20 * u,
        align = "topLeading", decorative = true,
    }, overview), g.k.bu))
    local overviewZone = zone(ctx, g, "workspace-overview", cx, 26 * u, "toggle-overview", 26 * u)
    local origin = if vertical then cx + 15.5 * u else slot.x + 25.5 * u
    if m.special then
        local centre = if slot.positions then slot.positions.special else origin + 9 * u
        if not centre then items[#items + 1] = overviewZone return items end
        local paths = pencil.draw(40 * u, 40 * u, specialPaths(g, m.special, s.frame), palette.roles.mint)
        local props = { key = "workspace-special-glyph", w = 40 * u, h = 40 * u,
            dx = if vertical then g.pill.cx else centre, dy = if vertical then centre else g.pill.cy,
            align = "topLeading", decorative = true }
        append(props, paths)
        items[#items + 1] = ui.stack(buttons.glow(props, g.k.bu))
        items[#items + 1] = zone(ctx, g, "workspace-special", centre, 26 * u, "scratchpad toggle " .. m.special.id)
        items[#items + 1] = overviewZone
        return items
    end
    for _, row in m.rows do
        local centre = if slot.positions then slot.positions["workspace-" .. row.workspace.id] else origin + row.x
        if not centre then continue end
        items[#items + 1] = mark(ctx, g, row, centre)
        if row.workspace.focused then
            items[#items + 1] = pill(ctx, g, slot, centre)
            local hoveredAny = if s.hover and string.sub(s.hover, 1, 14) == "workspace-hit-" then 1 else 0
            items[#items + 1] = outline(ctx, g, "workspace-pill-outline", centre, 29 * u, 15 * u, hoveredAny, true, 1)
        end
        items[#items + 1] = zone(ctx, g, "workspace-hit-" .. row.workspace.id, centre, row.w + 9 * u,
            "switch-workspace " .. row.workspace.id)
    end
    if m.plus then
        local centre = if slot.positions then slot.positions.plus else origin + m.plusX
        if centre then
            items[#items + 1] = plus(ctx, g, centre)
            items[#items + 1] = zone(ctx, g, "workspace-new", centre, 23 * u, "switch-workspace " .. m.plus.id)
        end
    end
    items[#items + 1] = overviewZone
    return items
end

local function shapes()
    return nil
end

return table.freeze({ width = width, extent = extent, flow = flow, prepare = prepare, shapes = shapes, content = content })

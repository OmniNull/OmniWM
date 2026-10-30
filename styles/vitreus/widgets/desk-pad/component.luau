-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local tasks = require("../lib/vitreus/tasks")
local kit = require("../lib/vitreus/kit")
local palette = require("../lib/vitreus/palette")
local units = require("../lib/vitreus/units")

local removal = table.freeze({ duration = 0.2, curve = "easeOut" })

local function hover(id)
    return function(next, event)
        if event.phase == "began" then
            next.state.hovered = id
        elseif next.state.hovered == id then
            next.state.hovered = nil
        end
    end
end

local function row(c, item, index, hovered)
    local du = c.du
    local w, h = 312 * du, 28 * du
    local line = kit.canvas(w, h, du, c.rs)
    local delete = kit.canvas(22 * du, 24 * du, du, c.rs)
    local id = item.id
    return ui.stack(kit.at(c, {
        key = "task-" .. id, w = w, h = h, radius = 11 * du, hover = palette.alpha("ink", 0.05),
        animate = kit.springs.slide, exit = { dx = 70 * du, opacity = 0, animate = removal },
        onClick = function(next) tasks.toggle(next.instance, id) end,
        onHover = hover(id), cursor = "pointer",
        ui.stack(kit.at(line, { w = 17 * du, h = 17 * du, radius = 6 * du,
            fill = if item.done then "accent" else palette.alpha("ink", 0.14),
            if item.done then kit.stroke(kit.canvas(17 * du, 17 * du, du, c.rs), kit.tick(8.5 * du, 8.5 * du, du), "border", 1.8 * du) else nil,
        }, 20 * du, h / 2)),
        kit.label(line, { text = item.text, x = 38 * du, y = h / 2, align = "leading", size = 12.5, weight = "medium",
            maxWidth = 226 * du, lines = 1, opacity = if item.done then 0.4 else 0.92 }),
        kit.zone(line, {
            key = "delete", x = w - 14 * du, y = h / 2, w = 22 * du, h = 24 * du, rest = 0.6, hover = 1,
            cursor = "pointer", onClick = function(next) tasks.remove(next.instance, id) end,
            ui.box({ w = 16 * du, h = 16 * du, radius = 8 * du, fill = 0, hover = palette.alpha("ink", 0.14) }),
            if hovered then kit.stroke(delete, kit.cross(11 * du, 12 * du, 2.6 * du), "foreground", 1.4 * du) else nil,
        }),
    }, c.w / 2, (176 + (index - 1) * 29) * du))
end

local function desk(ctx)
    local props = ctx.view.props
    local du, rs = props.du, props.rs
    local s = props.u / units.u
    local c = kit.canvas(340 * du, 460 * du, du, rs)
    local cx = c.w / 2
    local state = ctx.state
    local items = ctx.instance.state.items
    local tree = {
        key = "fd2", animate = kit.springs.fd2,
        ui.stack(kit.at(c, {
            key = "task-entry", w = 312 * du, h = 36 * du, radius = 14 * du,
            fill = palette.alpha("ink", palette.veil), hover = palette.alpha("ink", palette.veil + 0.04),
            ui.input({
                key = "task-entry-" .. (state.entry or 0), w = 270 * du, h = 22 * s, align = "leading", dx = 14 * du,
                text = state.draft or "", font = kit.font, size = 13 * s, color = "foreground",
                placeholder = "Add a task and press Enter", maxLength = 200,
                focus = if state.entry then true else nil,
                onChange = function(next, event) next.state.draft = event.text end,
                onCommit = function(next, event)
                    if tasks.add(next.instance, event.text) then
                        next.state.draft = nil
                        next.state.entry = (next.state.entry or 0) + 1
                    end
                end,
            }),
        }, cx, 128 * du)),
    }
    if #items == 0 then
        tree[#tree + 1] = kit.label(c, { key = "empty", text = "Nothing to do. Nice.", x = cx, y = 260 * du, size = 13,
            color = "secondaryForeground" })
    end
    for index, item in items do
        tree[#tree + 1] = row(c, item, index, state.hovered == item.id)
    end
    local problem = ctx.instance.state.error or omniwm.store.status.error
    if problem then
        tree[#tree + 1] = kit.label(c, { key = "problem", text = tostring(problem), x = cx, y = 96 * du, size = 11,
            color = "error", opacity = 0.8, maxWidth = 300 * du, lines = 1, decorative = true })
    end
    return ui.stack({ key = "pad", w = c.w, h = c.h, kit.section(c, tree, props.reveal) })
end

return { init = tasks.init, views = { desk = desk } }

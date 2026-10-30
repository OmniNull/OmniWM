-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("../palette")
local pencil = require("../pencil")

local widths = table.freeze({ search = 12, gear = 15, controls = 13 })
local zones = table.freeze({ search = 24, gear = 24, controls = 26 })
local pivots = table.freeze({ search = 2, gear = 0, controls = 0 })
local touch = table.freeze({ response = 2 * math.pi * 0.14 / 6.64, bounce = 0 })
local halo = palette.alpha("deep", 1)
local still = table.freeze({ x = 0, y = 0 })
local frame = 0.2

local arm

local function tick(state)
    state.pencilTimer = nil
    if not state.pencilHot then return end
    state.pencilFrame = (state.pencilFrame or 0) + 1
    arm(state)
end

arm = function(state)
    state.pencilTimer = omniwm.after(frame, function() tick(state) end)
end

local function hover(key: string, sketched: boolean?)
    return function(next, event)
        local state = next.state
        if event.phase == "began" then
            state.barHot = key
            if sketched then
                state.pencilHot = key
                state.pencilFrame = 1
                if not state.pencilTimer then arm(state) end
            end
            return
        end
        if state.barHot == key then state.barHot = nil end
        if state.pencilHot ~= key then return end
        state.pencilHot = nil
        state.pencilFrame = 0
        if state.pencilTimer then
            state.pencilTimer:cancel()
            state.pencilTimer = nil
        end
    end
end

local function sketch(ctx, key: string): (number, number)
    if ctx.state.pencilHot ~= key then return 0, 0 end
    return 1, ctx.state.pencilFrame or 0
end

local function append(list, items)
    for _, item in items do
        list[#list + 1] = item
    end
    return list
end

local function glow(props, bu: number)
    props.shadow = halo
    props.shadowRadius = 2.4 * bu
    props.shadowOffset = still
    return props
end

local function command(ctx, name: string): string
    if name == "search" then return "open-command-palette" end
    if name == "gear" then return "shell menu" end
    return "shell trigger vitreus drawer-controls " .. ctx.data.bar.monitorId
end

local function width(_, k, name: string): (number, number)
    return widths[name] * k.bu, 0
end

local function none()
    return nil
end

local function content(ctx, g, slot, name: string)
    local bu = g.k.bu
    local pill = g.pill
    local a, fr = sketch(ctx, name)
    local sel = if name == "controls" and ctx.state.drawerPanel == "controls" then 1 else 0
    local vertical = g.frame and g.frame.vertical
    local zone = (if vertical then 36 else zones[name]) * bu
    local height = if vertical then 30 * bu else pill.h
    local pivot = pivots[name] * bu
    local size = 30 * bu
    local passes = pencil.icon(name, size / 2 - pivot, size / 2 - pivot, bu, a, fr)
    local icon = append(glow({
        key = "bar-" .. name .. "-icon", decorative = true, w = size, h = size, dx = pivot, dy = pivot,
        scale = 1 + 0.14 * a, opacity = 0.65 + 0.35 * math.max(a, sel), animate = touch,
    }, bu), pencil.draw(size, size, passes, palette.alpha(if sel == 1 then "mint" else "ink", 1)))
    return { ui.stack({
        key = "bar-" .. name, align = "topLeading", dx = slot.cx - zone / 2,
        dy = if vertical then slot.cy - height / 2 else pill.y, w = zone, h = height,
        cursor = "pointer", onClick = command(ctx, name), onHover = hover(name, true),
        ui.stack(icon),
    }) }
end

return table.freeze({
    width = width, shapes = none, content = content, hover = hover, sketch = sketch, append = append, glow = glow,
    touch = touch,
})

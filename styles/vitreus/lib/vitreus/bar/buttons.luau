-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local keyboardMode = require("../../keyboard-mode")
local palette = require("../palette")
local pencil = require("../pencil")

local widths = table.freeze({ search = 12, omniwm = 15, controls = 13 })
local zones = table.freeze({ search = 24, omniwm = 24, controls = 26 })
local pivots = table.freeze({ search = 2, omniwm = 0, controls = 0 })
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
    if name == "omniwm" then return "shell menu" end
    return "shell trigger vitreus drawer-controls " .. ctx.data.bar.monitorId
end

local function badge(ctx, vertical: boolean?)
    local style = ctx.data.bar and ctx.data.bar.style
    if not style or style.keyboardMode == "normal" then return nil end
    return { keyboardMode = style.keyboardMode, vertical = vertical }
end

local function width(ctx, k, name: string): (number, number)
    local mode = if name == "omniwm" then badge(ctx, false) else nil
    local grow = if mode then 4 * k.bu + keyboardMode.width(ctx, mode, 20 * k.bu) else 0
    return widths[name] * k.bu + grow, grow
end

local function chip(ctx, g, slot, mode)
    local bu = g.k.bu
    local logo = widths.omniwm * bu
    local size = (if mode.vertical then 12 else 20) * bu
    local result = keyboardMode.chip(mode, size)
    result.key, result.align = "bar-omniwm-mode", "topLeading"
    if mode.vertical then
        result.dx = slot.cx + logo / 2 - keyboardMode.width(ctx, mode, size) / 2
        result.dy = slot.cy + logo / 2 - size / 2
    else
        result.dx = slot.x + logo + 4 * bu
        result.dy = g.pill.cy - size / 2
    end
    return result
end

local function none()
    return nil
end

local function content(ctx, g, slot, name: string)
    local bu = g.k.bu
    local pill = g.pill
    local logo = name == "omniwm"
    local a, fr = sketch(ctx, name)
    if logo then a = if ctx.state.barHot == name then 1 else 0 end
    local sel = if name == "controls" and ctx.state.drawerPanel == "controls" then 1 else 0
    local vertical = g.frame and g.frame.vertical
    local mode = if logo then badge(ctx, vertical) else nil
    local cx = if mode and not vertical then slot.x + widths[name] * bu / 2 else slot.cx
    local zone = (if vertical then 36 else zones[name]) * bu
    local height = if vertical then 30 * bu else pill.h
    local pivot = pivots[name] * bu
    local size = 30 * bu
    local icon = glow({
        key = "bar-" .. name .. "-icon", decorative = true, w = size, h = size, dx = pivot, dy = pivot,
        scale = 1 + 0.14 * a, opacity = if logo then 1 else 0.65 + 0.35 * math.max(a, sel), animate = touch,
    }, bu)
    local help
    if logo then
        local locked = ctx.data.bar.style.secureInput
        icon[1] = ui.symbol({
            name = if locked then "omniwm.lock" else "omniwm", size = 15 * bu, w = 15 * bu, h = 15 * bu,
            color = "#B66545FF",
        })
        help = if locked then omniwm.l10n("Secure Input is on: Option shortcuts are paused")
            else omniwm.l10n("Window manager controls")
    else
        local passes = pencil.icon(name, size / 2 - pivot, size / 2 - pivot, bu, a, fr)
        append(icon, pencil.draw(size, size, passes, palette.alpha(if sel == 1 then "mint" else "ink", 1)))
    end
    local click = command(ctx, name)
    return { ui.stack({
        key = "bar-" .. name, align = "topLeading", dx = cx - zone / 2,
        dy = if vertical then slot.cy - height / 2 else pill.y, w = zone, h = height,
        cursor = "pointer", help = help, onClick = click, onRightClick = if logo then click else nil,
        onHover = hover(name, not logo),
        ui.stack(icon),
    }), if mode then chip(ctx, g, slot, mode) else nil }
end

return table.freeze({
    width = width, shapes = none, content = content, hover = hover, sketch = sketch, append = append, glow = glow,
    touch = touch,
})

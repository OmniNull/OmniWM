-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local focus = require("../lib/vitreus/focus")
local kit = require("../lib/vitreus/kit")
local palette = require("../lib/vitreus/palette")

local actions = table.freeze({ [focus.READY] = "Start", [focus.FOCUSING] = "Pause", [focus.PAUSED] = "Resume", [focus.DONE] = "Again" })
local lead = table.freeze({ response = 0.378, bounce = 0.19 })
local trail = table.freeze({ response = 0.472, bounce = 0.19 })

local function ring(c, cx, cy, du, fraction, paused)
    local glowPath, glowFull = kit.ringPath(cx, cy, 70 * du, 16 * du, fraction)
    local barPath, barFull = kit.ringPath(cx, cy, 70 * du, 8 * du, fraction)
    return {
        kit.stroke(c, kit.circle(cx, cy, 70 * du), palette.alpha("ink", 0.09), 8 * du, "ring-track"),
        ui.path({ key = "ring-glow", decorative = true, w = c.w, h = c.h, d = glowPath, evenOdd = glowFull,
            fill = palette.alpha("mint", 0.14) }),
        ui.path({ key = "ring", decorative = true, w = c.w, h = c.h, d = barPath, evenOdd = barFull,
            fill = if paused then palette.alpha("mint", 0.45) else "accent" }),
    }
end

local function chips(c, cx, du, record, busy)
    local width = 58 * du
    local group = kit.canvas(4 * width + 4 * du, 32 * du, du, c.rs)
    local selected = table.find(focus.lengths, record.length) or 2
    local thumb = { x = group.w / 2 + (selected - 2.5) * width, y = group.h / 2, w = width - 6 * du, h = 24 * du,
        radius = 10 * du }
    local items = {
        key = "chips", w = group.w, h = group.h, opacity = if busy then 0.55 else 1,
        kit.plate(group, group.w / 2, group.h / 2, group.w, group.h, 16 * du, palette.veil),
        kit.outline(group, { key = "chips-outline", x = group.w / 2, y = group.h / 2, w = group.w, h = group.h,
            radius = 16 * du }),
        kit.body(group, {
            key = "chip-thumb", x = thumb.x, y = thumb.y, w = thumb.w, h = thumb.h, radius = thumb.radius,
            fill = "accent", rim = 0.16, shadow = palette.alpha("mint", 0.42), glow = 9 * du,
            morph = { edges = { lead = lead, trail = trail, thin = 3 * du / thumb.h, unit = 8 * du } },
        }),
        kit.outline(group, { key = "chip-thumb-outline", x = thumb.x, y = thumb.y, w = thumb.w, h = thumb.h,
            radius = thumb.radius, track = "chip-thumb-shape" }),
    }
    for index, minutes in focus.lengths do
        local chosen = index == selected
        items[#items + 1] = kit.zone(group, {
            key = "chip-" .. minutes, x = group.w / 2 + (index - 2.5) * width, y = group.h / 2, w = width, h = 32 * du,
            rest = if chosen then 1 else 0.62, hover = if chosen then 1 else 0.92, active = not busy,
            cursor = "pointer", animate = kit.springs.slide, hoverAnimate = kit.hover,
            onClick = function(next) focus.set(next.instance, minutes) end,
            kit.label(kit.canvas(width, 32 * du, du, c.rs), {
                text = tostring(minutes), size = 14.5, weight = "semibold",
                color = if chosen then "border" else "foreground", opacity = if chosen then 1 else 0.92,
                animate = kit.springs.slide,
            }),
        })
    end
    return ui.stack(kit.at(c, items, cx, 302 * du))
end

local function start(ctx, c, cx, du, record)
    local w, h = 144 * du, 40 * du
    local button = kit.canvas(w, h, du, c.rs)
    local running = record.state == focus.FOCUSING
    local hot, frame = kit.boiling(ctx, "start")
    local icon = if running then ui.stack({ w = w, h = h,
        ui.box(kit.at(button, { w = 2.8 * du, h = 10 * du, radius = du, fill = palette.alpha("off", 0.85) }, w / 2 - 28.6 * du, h / 2)),
        ui.box(kit.at(button, { w = 2.8 * du, h = 10 * du, radius = du, fill = palette.alpha("off", 0.85) }, w / 2 - 23.4 * du, h / 2)),
    }) else ui.path({ w = w, h = h, d = kit.play(w / 2 - 26 * du, h / 2, du), fill = palette.alpha("off", 0.85) })
    return ui.stack(kit.at(c, {
        key = "start", w = w, h = h, radius = 14 * du,
        pressScale = 0.94, pressAnimate = kit.springs.pop, cursor = "pointer",
        onClick = function(next) focus.toggle(next.instance) end,
        onHover = kit.boil("start"),
        kit.body(button, {
            key = "start-glass", x = w / 2, y = h / 2, w = w, h = h, radius = 14 * du, rim = 0.2,
            gradient = { from = palette.roles.minthi, to = palette.roles.mintlo, angle = 90 },
            shadow = palette.alpha("mint", 0.42 + 0.22 * hot), glow = (8 + 6 * hot) * du, animate = kit.springs.touch,
        }),
        kit.outline(button, { key = "start-outline", x = w / 2, y = h / 2, w = w, h = h, radius = 14 * du, hot = hot,
            frame = frame }),
        icon,
        kit.label(button, { text = actions[record.state], x = w / 2 + 8 * du, y = h / 2, size = 15.5, weight = "bold",
            color = "border" }),
    }, cx - 38 * du, 363 * du))
end

local function reset(ctx, c, cx, du, busy)
    local w, h = 76 * du, 40 * du
    local button = kit.canvas(w, h, du, c.rs)
    local arcRadius = 5.2 * du
    local side = 2 * arcRadius + 2 * du
    local hot, frame = kit.boiling(ctx, "reset")
    return ui.stack(kit.at(c, {
        key = "reset", w = w, h = h, radius = 14 * du,
        fill = palette.alpha("ink", 0.09), hover = palette.alpha("ink", 0.19), hoverAnimate = kit.hover,
        pressScale = 0.92, pressAnimate = kit.springs.pop, cursor = "pointer",
        onClick = if busy then function(next) focus.reset(next.instance) end else nil,
        onHover = kit.boil("reset"),
        kit.outline(button, { key = "reset-outline", x = w / 2, y = h / 2, w = w, h = h, radius = 14 * du, hot = hot,
            frame = frame }),
        ui.path(kit.at(button, {
            key = "reset-arc", decorative = true, w = side, h = side, rotate = 90 * hot,
            animate = kit.hover, d = kit.arc(side / 2, side / 2, arcRadius, -95, 175), fill = 0,
            border = palette.alpha("ink", 0.85), borderWidth = 1.5 * du,
        }, w / 2 - 18 * du, h / 2 + du)),
        kit.label(button, { text = "Reset", x = w / 2 + 8 * du, y = h / 2, size = 14.5, weight = "semibold",
            opacity = 0.88 }),
    }, cx + 80 * du, 363 * du))
end

local function desk(ctx)
    local props = ctx.view.props
    local du, rs = props.du, props.rs
    local c = kit.canvas(340 * du, 460 * du, du, rs)
    local cx = c.w / 2
    local instance = ctx.instance
    local record = instance.state.record
    local running = record.state == focus.FOCUSING
    local paused = record.state == focus.PAUSED
    local now = if running then ctx.data.seconds else 0
    local dial = { key = "fd1", animate = kit.springs.fd1 }
    for _, item in ring(c, cx, 188 * du, du, focus.fraction(instance, now), paused) do
        dial[#dial + 1] = item
    end
    dial[#dial + 1] = kit.label(c, { key = "time", text = focus.clock(focus.remaining(instance, now)),
        x = cx, y = 182 * du, size = 38, weight = "bold" })
    dial[#dial + 1] = kit.label(c, { key = "state", text = focus.names[record.state], x = cx, y = 214 * du,
        size = 11, weight = "bold", color = if running then "accent" else "secondaryForeground" })
    local problem = instance.state.error or instance.state.saveError or omniwm.store.status.error
    if problem then
        dial[#dial + 1] = kit.label(c, { key = "problem", text = tostring(problem), x = cx, y = 100 * du, size = 11,
            color = "error", opacity = 0.8, maxWidth = 300 * du, lines = 1, decorative = true })
    end
    return ui.stack({
        key = "focus", w = c.w, h = c.h,
        kit.section(c, dial, props.reveal),
        kit.section(c, {
            key = "fd2", animate = kit.springs.fd2,
            chips(c, cx, du, record, running or paused),
            kit.label(c, { key = "minutes", text = "minutes", x = cx, y = 326 * du, size = 10,
                color = "secondaryForeground", opacity = 0.8 }),
        }, props.reveal),
        kit.section(c, {
            key = "fd3", animate = kit.springs.fd3,
            start(ctx, c, cx, du, record),
            reset(ctx, c, cx, du, running or paused),
        }, props.reveal),
    })
end

return { init = focus.init, deinit = focus.cancel, views = { desk = desk } }

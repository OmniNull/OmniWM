-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("../palette")
local pencil = require("../pencil")
local buttons = require("./buttons")
local marks = require("./marks")

local shownIcons, glyphLength, glyphScale, iconSide, iconStep, spacing = 3, 24, 0.72, 16, 18, 6

local function list(ctx)
    local bar = ctx.data.bar
    return if bar and bar.style then bar.scratchpads or {} else {}
end

local function unit(ctx, k): number
    local layout = (ctx.data.settings or {}).layout
    return if layout == "left" or layout == "right" then k.bcu else k.bu
end

local function length(scratchpad, u: number): number
    return (glyphLength + math.min(#scratchpad.windows, shownIcons) * iconStep) * u
end

local function width(ctx, k): (number, number)
    local u, total = unit(ctx, k), 0
    for index, scratchpad in list(ctx) do
        total += length(scratchpad, u) + (if index > 1 then spacing * u else 0)
    end
    return total, if total > 0 then total + 12 * k.bu else 0
end

local function none()
    return nil
end

local function row(ctx, g, scratchpad, at: number, u: number)
    local vertical = g.frame and g.frame.vertical
    local run, thickness = length(scratchpad, u), (if vertical then 30 else 26) * u
    local active = scratchpad.visible or scratchpad.revealed or scratchpad.focused
    local key = "scratchpad-" .. tostring(scratchpad.id)
    local glyph = { key = key .. "-glyph", w = 40 * u, h = 40 * u, align = "topLeading", decorative = true,
        dx = if vertical then thickness / 2 else glyphLength * u / 2, dy = if vertical then glyphLength * u / 2 else thickness / 2 }
    buttons.append(glyph, pencil.draw(40 * u, 40 * u, marks.specialPaths(g, scratchpad, 0, glyphScale),
        if active then palette.roles.mint else palette.roles.ink))
    local node = { key = key, align = "topLeading", w = if vertical then thickness else run,
        h = if vertical then run else thickness, cursor = "pointer", help = scratchpad.name,
        dx = if vertical then g.pill.cx - thickness / 2 else at, dy = if vertical then at else g.pill.cy - thickness / 2,
        radius = 8 * u, hover = palette.alpha("ink", 0.08), onClick = "scratchpad toggle " .. tostring(scratchpad.id),
        target = "scratchpad " .. tostring(scratchpad.id), menu = true, ui.stack(buttons.glow(glyph, g.k.bu)) }
    for index, item in scratchpad.windows do
        if index > shownIcons then break end
        local along = (glyphLength + (index - 1) * iconStep) * u
        local across = (thickness - iconSide * u) / 2
        node[#node + 1] = ui.icon({ window = item.id, placeholder = "app.dashed", align = "topLeading", decorative = true,
            w = iconSide * u, h = iconSide * u, dx = if vertical then across else along, dy = if vertical then along else across,
            opacity = if item.focused then 1 elseif active then 0.75 else 0.55 })
    end
    return ui.stack(node)
end

local function content(ctx, g, slot)
    if not slot or slot.w == 0 then return nil end
    local vertical = g.frame and g.frame.vertical
    local u, items = if vertical then g.k.bcu else g.k.bu, {}
    local at = if vertical then slot.y else slot.x
    for _, scratchpad in list(ctx) do
        items[#items + 1] = row(ctx, g, scratchpad, at, u)
        at += length(scratchpad, u) + spacing * u
    end
    return items
end

return table.freeze({ width = width, shapes = none, content = content })

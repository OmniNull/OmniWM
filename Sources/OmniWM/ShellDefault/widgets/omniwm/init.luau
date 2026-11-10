-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local keyboardMode = require("../lib/keyboard-mode")
local layoutMark = require("../lib/layout-mark")
local look = require("../lib/look")

local TERRACOTTA = "#B66545FF"

local function iconColor(settings): string
    local color = settings.iconColor
    if type(color) == "string" and (#color == 7 or #color == 9) and string.match(color, "^#%x+$") then
        return color
    end
    return TERRACOTTA
end

function render(ctx: Context)
    local style = ctx.data.bar.style
    local locked = style.secureInput
    local item = style.height - 4
    local glyph = { size = look.px(ctx, "glyph") }
    local frame, size
    if look.omniwmButton then
        frame, size = look.omniwmButton(ctx, glyph, locked)
    end
    glyph.name = locked and "omniwm.lock" or "omniwm"
    glyph.color = iconColor(ctx.data.settings or {})
    glyph.w, glyph.h = glyph.size, glyph.size
    local symbol, name = layoutMark(ctx.data.bar)
    local mark = symbol
        and look.barGlyph(ctx, { name = symbol, size = look.px(ctx, "symbol"), help = omniwm.l10n(name) })
    local behaviour = { onClick = "shell menu", onRightClick = "shell menu",
        help = locked and omniwm.l10n("Secure Input is on: Option shortcuts are paused")
            or omniwm.l10n("Window manager controls") }
    local button
    if frame then
        frame[1] = ui.symbol(glyph)
        if mark then
            local line = { pad = (size - glyph.size) / 2, gap = 5 * look.scale(ctx), center = true, frame[1], mark }
            if style.vertical then
                frame.h, frame[1] = nil, ui.column(line)
            else
                frame.w, frame[1] = nil, ui.row(line)
            end
        end
        button = ui.stack(frame)
    else
        local props = table.clone(behaviour)
        glyph = look.barSymbolProps(ctx, glyph)
        if not style.vertical then
            glyph.w, glyph.h = glyph.size, glyph.size
        end
        props.w, props.h = item, item
        if mark and style.vertical then
            props.h = nil
        elseif mark then
            props.w = nil
        end
        props[1] = ui.symbol(glyph)
        props[2] = mark
        button, size = look.bar(ctx, props), item
    end
    for key, value in behaviour do
        button[key] = value
    end
    return keyboardMode.wrap(style, button, size)
end

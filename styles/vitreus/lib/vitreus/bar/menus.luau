-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("../palette")
local buttons = require("./buttons")

local widths = table.freeze({ apple = 12, app = 16 })
local zones = table.freeze({ apple = 24, app = 26 })
local sizes = table.freeze({ apple = 15, app = 20 })

local function shown(ctx, name: string): boolean
    local bar = ctx.data.bar
    return bar ~= nil and bar.style ~= nil and bar.style.hidesMenuBar == true
        and (name == "apple" or ctx.data.menuApp ~= nil)
end

local function width(ctx, k, name: string): (number, number)
    if not shown(ctx, name) then return 0, 0 end
    local w = widths[name] * k.bu
    return w, w + 12 * k.bu
end

local function none()
    return nil
end

local function menu(ctx, name: string, size: number)
    if name == "apple" then
        return omniwm.l10n("Apple Menu"),
            ui.symbol({ name = "applelogo", size = size, w = size, h = size, color = palette.roles.ink })
    end
    local app = ctx.data.menuApp
    local bundle = if app.bundle ~= "" then app.bundle else nil
    return app.name, ui.icon({
        app = bundle, pid = if bundle then nil else app.pid, w = size, h = size, placeholder = "app.dashed",
    })
end

local function content(ctx, g, slot, name: string)
    if not slot or not shown(ctx, name) then return nil end
    local bu = g.k.bu
    local pill = g.pill
    local vertical = g.frame and g.frame.vertical
    local zone = (if vertical then 36 else zones[name]) * bu
    local height = if vertical then 30 * bu else pill.h
    local size = sizes[name] * bu
    local a = if ctx.state.barHot == name then 1 else 0
    local help, picture = menu(ctx, name, size)
    return { ui.stack({
        key = "bar-" .. name, align = "topLeading", dx = slot.cx - zone / 2,
        dy = if vertical then slot.cy - height / 2 else pill.y, w = zone, h = height,
        cursor = "pointer", help = help, onClick = "menu " .. name, onHover = buttons.hover(name),
        ui.stack(buttons.glow({
            key = "bar-" .. name .. "-icon", decorative = true, w = size, h = size,
            scale = 1 + 0.14 * a, opacity = if name == "app" then 0.88 + 0.12 * a else 0.65 + 0.35 * a,
            animate = buttons.touch, picture,
        }, bu)),
    }) }
end

return table.freeze({ width = width, shapes = none, content = content })

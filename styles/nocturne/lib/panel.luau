-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local frame = require("./panel-frame")

local SHOULDER = frame.shoulder
local CORNER = frame.corner

local function panel(style: BarStyle, width: number, content)
    local attached = not style.vertical
    local flip = style.position == "bottom"
    local inner = { w = width - 2, radius = CORNER - 1, fill = "background" }
    local outer = { w = width, radius = CORNER, fill = "border" }
    if attached then
        inner[1] = frame.square(width - 2, flip, "background")
        outer[1] = frame.square(width, flip, "border")
    end
    inner[#inner + 1] = content
    local framed = { gap = 0, ui.row{ gap = 0, ui.box{ w = 1, h = 1 }, ui.stack(inner), ui.box{ w = 1, h = 1 } } }
    if not attached or flip then
        table.insert(framed, 1, ui.box{ w = width, h = 1 })
    end
    if not attached or not flip then
        framed[#framed + 1] = ui.box{ w = width, h = 1 }
    end
    outer[#outer + 1] = ui.column(framed)
    if not attached then
        return ui.stack{ material = "clear", ui.stack(outer) }
    end
    local body = ui.row{ gap = 0, ui.box{ w = SHOULDER, h = 1 }, ui.stack(outer), ui.box{ w = SHOULDER, h = 1 } }
    local shoulders = frame.edge(width, flip)
    return ui.column{ material = "clear", attach = true, gap = 0,
        flip and body or shoulders, flip and shoulders or body }
end

return panel

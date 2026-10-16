-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local CELL = 28
local HOVER = "foreground/0.07"

local function caps(text: string): string
    return if string.find(text, "[\128-\255]") then text else string.upper(text)
end

function render(ctx)
    return ui.row{}
end

local function menuRow(item, width)
    if item.separator then
        return ui.box{ w = width, h = 9, pad = 4,
            ui.box{ h = 1, grow = 1, fill = "foreground/0.08" } }
    end
    local color = if item.enabled then "foreground" else "mutedForeground"
    return ui.row{ key = item.id, w = width, h = CELL, pad = 5, gap = 6, radius = 7,
        hover = if item.enabled then HOVER else nil,
        onClick = if item.enabled then "hidden-bar-menu " .. item.id else nil,
        ui.text{ text = item.mark, w = 14, size = 12, weight = "bold", color = "accent" },
        ui.text{ text = item.title, grow = 1, maxWidth = width - 120, size = 12, weight = "medium", color = color },
        ui.text{ text = item.shortcut, maxWidth = 80, style = "mono", size = 11, weight = "medium",
            color = "mutedForeground" },
        if item.submenu then ui.symbol{ name = "chevron.right", w = 10, h = 10, weight = "bold", color = "mutedForeground" }
            else ui.box{ w = 10, h = 10 } }
end

function popout(ctx)
    local hidden = ctx.data.hiddenBar
    local page = hidden.menu
    local width = math.min(320, hidden.maxWidth > 0 and hidden.maxWidth or 320)
    local rows = { w = width, pad = 5, radius = 12, scroll = true, material = "clear", fill = "surface",
        border = "border", borderWidth = 1 }
    local height = 10
    if not page then
        rows[#rows + 1] = ui.text{ text = omniwm.l10n("Unavailable"), size = 12, color = "mutedForeground" }
        height += CELL
    else
        if page.backID and page.backID ~= "" then
            rows[#rows + 1] = ui.row{ w = width - 10, h = CELL, pad = 5, gap = 6, radius = 7,
                hover = HOVER, onClick = "hidden-bar-menu " .. page.backID,
                ui.symbol{ name = "chevron.left", w = 14, h = 12, weight = "bold", color = "accent" },
                ui.text{ text = omniwm.l10n("Back"), grow = 1, size = 12, weight = "semibold", color = "accent" } }
            height += CELL
        end
        if page.title ~= "" then
            rows[#rows + 1] = ui.box{ w = width - 10, h = CELL, pad = 5,
                ui.text{ text = caps(page.title), size = 10, weight = "bold", color = "mutedForeground",
                    maxWidth = width - 20 } }
            height += CELL
        end
        for _, item in page.rows do
            rows[#rows + 1] = menuRow(item, width - 10)
            height += if item.separator then 9 else CELL
        end
        if #page.rows == 0 then
            rows[#rows + 1] = ui.box{ h = CELL, pad = 5,
                ui.text{ text = omniwm.l10n("No menu items available"), size = 12, color = "mutedForeground" } }
            height += CELL
        end
    end
    rows.h = math.min(height, hidden.maxHeight > 0 and hidden.maxHeight or height)
    return ui.column(rows)
end

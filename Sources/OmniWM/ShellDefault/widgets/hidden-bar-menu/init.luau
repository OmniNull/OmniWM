-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local CELL = 28

function render(ctx)
    return ui.row{}
end

local function menuRow(item, width)
    if item.separator then
        return ui.box{ w = width, h = 9, pad = 4,
            ui.box{ h = 1, grow = 1, fill = "foreground/0.12" } }
    end
    local color = if item.enabled then "foreground" else "secondaryForeground"
    return ui.row{ key = item.id, w = width, h = CELL, pad = 5, gap = 6, radius = 5,
        hover = if item.enabled then "foreground/0.12" else nil,
        onClick = if item.enabled then "hidden-bar-menu " .. item.id else nil,
        ui.text{ text = item.mark, w = 14, color = color },
        ui.text{ text = item.title, grow = 1, maxWidth = width - 120, color = color },
        ui.text{ text = item.shortcut, maxWidth = 80, style = "small", color = "secondaryForeground" },
        if item.submenu then ui.symbol{ name = "chevron.right", w = 10, h = 10, color = color }
            else ui.box{ w = 10, h = 10 } }
end

function popout(ctx)
    local hidden = ctx.data.hiddenBar
    local page = hidden.menu
    local width = math.min(320, hidden.maxWidth > 0 and hidden.maxWidth or 320)
    local rows = { w = width, pad = 5, radius = 9, scroll = true }
    local height = 10
    if not page then
        rows[#rows + 1] = ui.text{ text = omniwm.l10n("Unavailable"), color = "secondaryForeground" }
        height += CELL
    else
        if page.backID and page.backID ~= "" then
            rows[#rows + 1] = ui.row{ w = width - 10, h = CELL, pad = 5, gap = 6, radius = 5,
                hover = "foreground/0.12", onClick = "hidden-bar-menu " .. page.backID,
                ui.symbol{ name = "chevron.left", w = 14, h = 12 },
                ui.text{ text = omniwm.l10n("Back"), grow = 1 } }
            height += CELL
        end
        if page.title ~= "" then
            rows[#rows + 1] = ui.box{ w = width - 10, h = CELL, pad = 5,
                ui.text{ text = page.title, style = "small", color = "secondaryForeground", maxWidth = width - 20 } }
            height += CELL
        end
        for _, item in page.rows do
            rows[#rows + 1] = menuRow(item, width - 10)
            height += if item.separator then 9 else CELL
        end
        if #page.rows == 0 then
            rows[#rows + 1] = ui.box{ h = CELL, pad = 5,
                ui.text{ text = omniwm.l10n("No menu items available"), color = "secondaryForeground" } }
            height += CELL
        end
    end
    rows.h = math.min(height, hidden.maxHeight > 0 and hidden.maxHeight or height)
    return ui.column(rows)
end

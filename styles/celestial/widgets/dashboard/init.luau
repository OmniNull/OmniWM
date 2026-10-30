-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

require("../lib/calendar")
require("../lib/media")
require("../lib/weather")
local dash = require("../lib/dash")
local mediatab = require("../lib/mediatab")
local performance = require("../lib/performance")
local weathertab = require("../lib/weathertab")
local geometry = require("../lib/geometry")
local motion = require("../lib/motion")
local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

local FILLET = 20
local CORNER = 28
local PAD = tokens.padding.large
local TAB = tokens.icon.medium + tokens.body.medium * 1.25 + 2 * tokens.dashboard.indicatorGap
local TAB_BAR = TAB + tokens.dashboard.indicatorGap + tokens.dashboard.indicator + 1

type Size = { w: number, h: number }
type Tab = { id: string, icon: string, label: () -> string, pane: { size: Size | (Context) -> Size, tab: (Context) -> any } }

local function tabs(): { Tab }
    return {
        { id = "dashboard", icon = "dashboard", label = function() return omniwm.l10n("Dashboard") end, pane = dash },
        { id = "media", icon = "queue_music", label = function() return omniwm.l10n("Media") end, pane = mediatab },
        { id = "performance", icon = "speed", label = function() return omniwm.l10n("Performance") end,
            pane = performance },
        { id = "weather", icon = "cloud", label = function() return omniwm.l10n("Weather") end, pane = weathertab },
    }
end

function render(ctx: Context)
    return ui.box{ w = 0, h = 0 }
end

local function tabBar(list: { Tab }, current: number, width: number)
    local tabWidth = width / #list
    local row = { w = width, h = TAB, gap = 0 }
    for index, entry in list do
        local active = index == current
        row[index] = ui.column{ key = entry.id, w = tabWidth, h = TAB, gap = 0, radius = tokens.rounding.medium,
            hover = (active and "accent" or "foreground") .. "/0.08",
            onClick = function(ctx) ctx.state.tab = index end,
            onScroll = function(ctx, event)
                ctx.state.tab = math.clamp((ctx.state.tab or 1) + (event.dy < 0 and 1 or -1), 1, #list)
            end,
            surface.icon(entry.icon, { size = tokens.icon.medium, color = active and "accent" or "secondaryForeground",
                filled = active }),
            ui.text{ text = entry.label(), font = "sans", size = tokens.body.medium,
                color = active and "accent" or "secondaryForeground" } }
    end
    local indicator = math.min(tabWidth - 2 * tokens.padding.large, 120)
    return ui.column{ w = width, h = TAB_BAR, gap = 0,
        ui.row(row),
        ui.stack{ w = width, h = tokens.dashboard.indicatorGap + tokens.dashboard.indicator,
            ui.box{ key = "indicator", align = "bottomLeading", dx = tabWidth * (current - 1) + (tabWidth - indicator) / 2,
                w = indicator, h = tokens.dashboard.indicator, radius = tokens.dashboard.indicator / 2, fill = "accent",
                animate = motion.normal } },
        ui.box{ w = width, h = 1, fill = "border" } }
end

function popout(ctx: Context)
    local list = tabs()
    local current = math.clamp(ctx.state.tab or 1, 1, #list)
    local entry = list[current]
    local size = entry.pane.size
    if type(size) == "function" then
        size = size(ctx)
    end
    local width = size.w + 2 * PAD
    local height = PAD + TAB_BAR + PAD + size.h + PAD
    return ui.stack{ material = "clear", w = width + 2 * FILLET, h = height, animate = motion.normal,
        enter = { dy = -height, curve = "spatial", stretch = 0.1 },
        ui.path{ d = geometry.drawer(width, height, FILLET, CORNER), w = width + 2 * FILLET, h = height,
            fill = "background", animate = motion.normal },
        ui.column{ w = width, h = height, pad = PAD, gap = PAD, center = false,
            tabBar(list, current, size.w),
            ui.stack{ key = entry.id, w = size.w, h = size.h, entry.pane.tab(ctx) } } }
end

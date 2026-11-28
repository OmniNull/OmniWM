-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

return {
    theme = "vitreus",
    leading = {},
    center = {},
    trailing = {},
    workspaceBar = {
        position = "overlappingMenuBar",
        height = 1,
        fullWidth = true,
        reserveLayoutSpace = false,
        hideEmptyWorkspaces = false,
        transparentBackground = true,
        backgroundOpacity = 0,
    },
    widgets = {
        vitreus = { layout = "island", size = 1, pins = {}, addons = {}, dockOverlap = false },
    },
    island = {
        root = "vitreus",
        drawsSystemStats = true,
        displays = "all",
        sizing = "display",
        fullscreen = "hide",
        room = {
            setting = "layout",
            size = "size",
            variants = {
                island = { top = { base = 8, scaled = 54, mode = "add" }, dock = "bottom" },
                left = {
                    top = { base = 24, mode = "total" },
                    left = { base = 14, scaled = 62.1, mode = "total" },
                    right = { base = 24, mode = "total" },
                    bottom = { base = 24, mode = "total" },
                    dock = "right",
                },
                right = {
                    top = { base = 24, mode = "total" },
                    left = { base = 24, mode = "total" },
                    right = { base = 14, scaled = 62.1, mode = "total" },
                    bottom = { base = 24, mode = "total" },
                    dock = "left",
                },
                ftop = {
                    top = { base = 14, scaled = 62.1, mode = "total" },
                    left = { base = 24, mode = "total" },
                    right = { base = 24, mode = "total" },
                    bottom = { base = 24, mode = "total" },
                    dock = "bottom",
                },
                fbottom = {
                    top = { base = 24, mode = "total" },
                    left = { base = 24, mode = "total" },
                    right = { base = 24, mode = "total" },
                    bottom = { base = 14, scaled = 62.1, mode = "total" },
                    dock = "top",
                },
                seg = {
                    top = { base = 10, scaled = 48.6, mode = "total", clear = "notch" },
                    left = { base = 24, mode = "total" },
                    right = { base = 24, mode = "total" },
                    bottom = { base = 24, mode = "total" },
                    dock = "bottom",
                },
            },
            dock = {
                base = 23.8,
                scaled = 45.9,
                when = { "pins", "addons" },
                unless = "dockOverlap",
            },
        },
        components = { { id = "pad", widget = "desk-pad" }, { id = "focus", widget = "desk-focus" } },
    },
    drawer = {
        shelf = { edge = "top", present = "island", hover = true, close = "leave", width = 900 },
    },
}

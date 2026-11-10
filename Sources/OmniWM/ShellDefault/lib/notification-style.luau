-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("./look")

return require("./notification-presentation")({
    scale = look.scale,
    bar = look.bar,
    icon = function(issue, size, ctx)
        return look.barGlyph(ctx, { name = if issue then "bell.badge" else "bell", size = size })
    end,
    hover = look.hover,
    buttonRadius = 7,
    group = look.group,
    panel = look.panel,
})

-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("../lib/look")
local wallpaper = require("../lib/wallpaper")

local WIDTH = 600

function render(ctx)
    return look.bar(ctx, { onClick = ui.popout, help = omniwm.l10n("Wallpaper"),
        look.barGlyph(ctx, { name = "photo.on.rectangle", size = look.px(ctx, "symbol") }) })
end

function popout(ctx)
    return look.panel(ctx, { w = WIDTH + 28, wallpaper.panel(ctx, wallpaper.roles, WIDTH) })
end

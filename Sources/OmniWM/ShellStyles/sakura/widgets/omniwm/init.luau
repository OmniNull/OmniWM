-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local system = require("../lib/style")

function render(ctx: Context)
    local locked = ctx.data.bar.style.secureInput
    local size = 18 * system.scale(ctx)
    return system.bar(ctx, { onClick = "shell menu", onRightClick = "shell menu",
        help = locked and omniwm.l10n("Secure Input is on: Option shortcuts are paused")
            or omniwm.l10n("Window manager controls"),
        if locked then ui.symbol{ name = "omniwm.lock", size = size, w = size, h = size }
            else system.blossom(size) })
end

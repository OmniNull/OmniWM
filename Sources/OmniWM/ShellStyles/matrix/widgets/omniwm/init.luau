-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local system = require("../lib/style")

function render(ctx: Context)
    local locked = ctx.data.bar.style.secureInput
    return system.bar(ctx, { onClick = "shell menu", onRightClick = "shell menu",
        help = locked and omniwm.l10n("Secure Input is on: Option shortcuts are paused")
            or omniwm.l10n("Window manager controls"),
        ui.text{ style = "caption", text = locked and "[ ! ]" or "[ M ]", size = 13 * system.scale(ctx),
            weight = "semibold", color = locked and "warning" or "accent" } })
end

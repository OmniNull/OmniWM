-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local button = require("../lib/menu-button")

function render(ctx: Context)
    return button.render(ctx, { symbol = "applelogo", action = "menu apple", help = omniwm.l10n("Apple Menu") })
end

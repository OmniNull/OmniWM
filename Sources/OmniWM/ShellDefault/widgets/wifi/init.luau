-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local wifi = require("../lib/wifi")

function render(ctx)
    return wifi.bar(ctx)
end

function popout(ctx)
    return wifi.popout(ctx)
end

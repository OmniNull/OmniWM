-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local MARKS = table.freeze({
    niri = table.freeze({ symbol = "rectangle.split.3x1", name = "Niri (Scrolling)" }),
    dwindle = table.freeze({ symbol = "rectangle.split.2x2", name = "Dwindle (BSP)" }),
})

return function(bar: Bar?): (string?, string?)
    local mark = bar and bar.layout and MARKS[bar.layout]
    if mark == nil then
        return nil, nil
    end
    return mark.symbol, mark.name
end

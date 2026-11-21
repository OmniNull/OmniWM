-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

return require("./skin")({
    capsules = true,
    commandPalettePanel = function(_, props)
        props.radius = 28
        props.material = "glass"
        props.center = false
        return ui.column(props)
    end,
})

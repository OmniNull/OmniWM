-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

return {
    options = {
        display = {
            type = "choice",
            title = "Show",
            default = "icon_and_text",
            choices = { "icon_and_text", "icon_only", "text_only" },
        },
        maxWidth = {
            type = "number",
            title = "Maximum title width",
            default = 260,
            min = 40,
            max = 1000,
            step = 10,
        },
    },
}

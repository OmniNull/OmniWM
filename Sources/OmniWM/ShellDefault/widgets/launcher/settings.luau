-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

return {
    options = {
        mode = {
            type = "choice",
            title = "Open",
            choices = { "commands", "windows", "menu", "clipboard", "applications", "files" },
        },
        symbol = {
            type = "string",
            title = "Symbol",
            default = "magnifyingglass",
            maxLength = 128,
        },
    },
}

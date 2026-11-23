-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

return {
    options = {
        audio = {
            type = "boolean",
            title = "Show audio",
            default = false,
        },
        keyboard = {
            type = "boolean",
            title = "Show input source",
            default = false,
        },
        network = {
            type = "boolean",
            title = "Show Wi-Fi",
            default = true,
        },
        bluetooth = {
            type = "boolean",
            title = "Show Bluetooth",
            default = true,
        },
        battery = {
            type = "boolean",
            title = "Show battery",
            default = true,
        },
    },
}

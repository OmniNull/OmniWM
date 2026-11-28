return {
    title = "Clock",
    icon = "globe",
    views = { "compact", "expanded" },
    options = {
        label = {
            type = "string",
            default = "Local",
            maxLength = 48,
        },
        zone = {
            type = "string",
            default = "UTC",
            maxLength = 128,
        },
        seconds = {
            type = "boolean",
            default = false,
        },
        rollDigits = {
            type = "boolean",
            default = false,
        },
    },
}

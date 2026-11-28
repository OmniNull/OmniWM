return {
    title = "Provider Review",
    icon = "app",
    views = { "window", "confirm" },
    capabilities = {
        provider = true,
    },
    provider = {
        command = { "provider" },
    },
    window = {
        width = 520,
        height = 280,
        minWidth = 320,
        minHeight = 220,
        children = {
            confirm = {
                kind = "sheet",
                view = "confirm",
                title = "Confirm deletion",
                width = 360,
                height = 180,
                minWidth = 280,
                minHeight = 160,
            },
        },
    },
}

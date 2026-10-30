local motion = require("./motion")
local preferences = require("./preferences")

local foreground = "#ffffff"
local secondary = "#a1a1aa"
local panes = table.freeze({ "Widgets", "Appearance", "Interaction", "Motion" })
local rootKeys = table.freeze({ Appearance = { "appearance", "width", "radius", "backgroundColor", "highlightColor" },
    Interaction = { "hoverPreview", "hoverDelay", "hoverGrace", "clickTarget", "rightClickTarget",
        "swipeTarget", "swipeDirection", "swipeSource", "swipeDistance" }, Motion = { "springResponse", "springBounce" } })
local regionTitles = table.freeze({ auto = "Automatic", main = "Main", side = "Side", expanded = "Expanded only" })
local rowHeight = 40
local pageSize = 12

local function button(key, title, action, selected, help)
    return ui.box{ key = key, h = 28, pad = 7, radius = 8, onClick = action,
        fill = if selected then "#ffffff22" else "#ffffff0a", hover = "#ffffff18",
        opacity = if action then 1 else 0.4, pressScale = 0.96, pressFill = "#ffffff30",
        pressAnimate = motion.feedback, help = help,
        ui.text{ text = title, size = 11, color = foreground, maxWidth = 160 } }
end

local function pageControls(ctx, key, count, width)
    local pages = math.max(1, math.ceil(count / pageSize))
    local page = math.clamp(ctx.state[key] or 1, 1, pages)
    local controls = if pages > 1 then ui.row{ key = key, w = width, gap = 6,
        button("previous", "‹", if page > 1 then function(root) root.state[key] = page - 1 end else nil),
        ui.text{ text = tostring(page) .. " / " .. tostring(pages), size = 10, color = secondary, grow = 1 },
        button("next", "›", if page < pages then function(root) root.state[key] = page + 1 end else nil) } else nil
    return page, controls
end

local function request(ctx, invoke)
    local state = ctx.state
    state.settingsError = nil
    state.settingsRequests = (state.settingsRequests or 0) + 1
    local handle, err = invoke(function(result)
        state.settingsRequests -= 1
        if not result.ok then state.settingsError = result.error or "Could not save this change" end
        if result.ok and result.id then state.settingsSelection = result.id; state.settingsAdding = false end
    end)
    if not handle then
        state.settingsRequests -= 1
        state.settingsError = err or "Could not accept this change"
    end
end

local function setRoot(ctx, key, value)
    local error = preferences.validate(ctx, key, value)
    if error then ctx.state.settingsError = error; return end
    request(ctx, function(done) return omniwm.config.set(key, value, done) end)
end

local function move(ctx, id, delta)
    local components = ctx.data.components or {}
    for index, component in components do
        if component.id == id then
            local target = math.clamp(index + delta, 1, #components)
            if target ~= index then
                request(ctx, function(done) return omniwm.components.move(id, target, done) end)
            end
            return
        end
    end
end

local function stringInput(ctx, key, title, value, maximum, width, write)
    return ui.input{ key = key .. ":" .. tostring(ctx.state.settingsTextRevision or 0), text = value, placeholder = title, w = width, h = 48,
        multiline = true, maxLength = maximum or 4096, size = 11, color = foreground,
        fill = "#ffffff0a", radius = 8, help = "Edit " .. title,
        onCommit = function(root, event) write(root, event.text) end,
        onCancel = function(root) root.state.settingsTextRevision = 1 - (root.state.settingsTextRevision or 0) end }
end

local function stringList(ctx, token, key, option, value, write, width)
    local values = if type(value) == "table" then value else {}
    local title = option.title or key
    local expanded = ctx.state.settingsList == token
    local rows = { key = "option:" .. key, w = width, gap = 4, center = false }
    rows[1] = ui.row{ w = width, h = 38, gap = 8,
        ui.text{ text = title, size = 11, color = secondary, grow = 1, maxWidth = math.max(48, width - 166) },
        button("list", if expanded then "Done" else tostring(#values) .. " values ›", function(root)
            root.state.settingsList = if expanded then nil else token
            root.state.settingsListPage = 1
        end, expanded, "Edit " .. title .. " values") }
    if not expanded then return ui.column(rows) end
    local page, controls = pageControls(ctx, "settingsListPage", #values, width)
    if controls then rows[#rows + 1] = controls end
    for index = (page - 1) * pageSize + 1, math.min(page * pageSize, #values) do
        local position = index
        rows[#rows + 1] = ui.row{ key = "entry:" .. position, w = width, gap = 6,
            stringInput(ctx, "value", title .. " " .. position, values[position], option.maxLength, math.max(1, width - 42), function(root, text)
                local updated = table.clone(values)
                updated[position] = text
                write(root, key, updated)
            end),
            button("remove", "−", function(root)
                local updated = table.clone(values)
                table.remove(updated, position)
                write(root, key, updated)
            end, false, "Remove " .. title .. " " .. position) }
    end
    rows[#rows + 1] = button("add-value", "Add value", if #values < 256 then function(root)
        local updated = table.clone(values)
        updated[#updated + 1] = ""
        write(root, key, updated)
        root.state.settingsListPage = math.ceil(#updated / pageSize)
    end else nil, false, "Add " .. title .. " value")
    return ui.column(rows)
end

local function rootOptionKeys(page, schema)
    local keys = table.clone(rootKeys[page] or {})
    if page == "Appearance" then
        local extras = {}
        for key, option in schema do
            if key ~= "regions" and (option.type == "string" or option.type == "strings") then
                local included = false
                for _, declared in rootKeys do
                    if table.find(declared, key) then included = true; break end
                end
                if not included then extras[#extras + 1] = key end
            end
        end
        table.sort(extras)
        for _, key in extras do keys[#keys + 1] = key end
    end
    return keys
end

local function settingRow(ctx, key, option, values, write, width, scope)
    local value = values[key]
    if value == nil then value = option.default end
    if option.type == "strings" then return stringList(ctx, scope .. ":" .. key, key, option, value, write, width) end
    local controls
    if option.type == "string" then
        controls = stringInput(ctx, "value", option.title or key, if type(value) == "string" then value else "", option.maxLength, 154, function(root, text)
            write(root, key, text)
        end)
    elseif option.type == "boolean" then
        controls = button("value", if value then "On" else "Off",
            function(root) write(root, key, not value) end, value == true, option.title)
    elseif option.type == "number" then
        local amount = if type(value) == "number" then value else option.min or 0
        local step = option.step or 1
        local previous = math.max(option.min or -math.huge, amount - step)
        local nextValue = math.min(option.max or math.huge, amount + step)
        controls = ui.row{ gap = 4,
            button("less", "−", if previous ~= amount then function(root) write(root, key, previous) end else nil,
                false, "Decrease " .. option.title),
            ui.text{ text = string.format("%.2f", amount):gsub("0+$", ""):gsub("%.$", ""), w = 48, size = 11,
                style = "mono", color = foreground },
            button("more", "+", if nextValue ~= amount then function(root) write(root, key, nextValue) end else nil,
                false, "Increase " .. option.title) }
    elseif option.type == "choice" then
        local choices = option.choices or {}
        local index = table.find(choices, value) or 0
        controls = button("value", tostring(value or "Choose") .. " ›", if #choices > 0 then function(root)
            write(root, key, choices[index % #choices + 1])
        end else nil, false, "Next " .. option.title)
    end
    return ui.row{ key = "option:" .. key, w = width, h = if option.type == "string" then 54 else 38, gap = 8,
        ui.text{ text = option.title or key, size = 11, color = secondary, grow = 1, maxWidth = math.max(48, width - 166) },
        controls }
end

local function catalogEntry(ctx, widget)
    for _, entry in ctx.data.catalog or {} do
        if entry.widget == widget then return entry end
    end
    return nil
end

local function componentList(ctx, width, height, close)
    local rows = { w = width, h = height, gap = 2, scroll = true, center = false }
    local selected = ctx.state.settingsSelection or ((ctx.data.components or {})[1] or {}).id
    for _, component in ctx.data.components or {} do
        local id = component.id
        rows[#rows + 1] = ui.row{ key = id, w = width, h = rowHeight - 2, gap = 7, pad = 6, radius = 8,
            fill = if selected == id then "#ffffff16" else nil, hover = "#ffffff0c",
            onClick = function(root)
                root.state.settingsSelection = id
                root.state.settingsAdding = false
                root.state.settingsOptionPage = 1
            end,
            focusable = true, keys = { "up", "down", "escape" },
            onKey = function(root, event)
                if event.key == "escape" then close(root)
                elseif event.key == "up" then move(root, id, -1)
                elseif event.key == "down" then move(root, id, 1) end
            end,
            ui.box{ w = 20, h = 28, help = "Drag to reorder " .. component.title,
                gesture = { axis = "y", source = "pointer", threshold = 5,
                    commit = { distance = rowHeight / 2 }, track = { scale = { 1, 1.08 }, opacity = { 1, 0.7 } } },
                onGesture = function(root, event)
                    if event.phase == "ended" and event.committed then
                        local delta = math.round((event.dy or 0) / rowHeight)
                        if delta ~= 0 then move(root, id, delta) end
                    end
                end,
                ui.symbol{ name = "line.3.horizontal", size = 11, color = secondary } },
            ui.column{ grow = 1, gap = 2, center = false,
                ui.text{ text = component.title, size = 11, color = if component.enabled then foreground else secondary,
                    maxWidth = math.max(40, width - 85) },
                ui.text{ text = id, size = 9, color = secondary, maxWidth = math.max(40, width - 85) } },
            button("enabled", if component.enabled then "On" else "Off", function(root)
                request(root, function(done) return omniwm.components.enable(id, not component.enabled, done) end)
            end, false, (if component.enabled then "Disable " else "Enable ") .. component.title) }
    end
    return ui.column(rows)
end

local function componentDetails(ctx, width, height)
    if ctx.state.settingsAdding then
        local rows = { key = "catalog", w = width, h = height, gap = 6, scroll = true, center = false }
        rows[#rows + 1] = ui.text{ text = "Add a widget", size = 13, weight = "semibold", color = foreground }
        local catalog = ctx.data.catalog or {}
        local page, controls = pageControls(ctx, "settingsCatalogPage", #catalog, width)
        if controls then rows[#rows + 1] = controls end
        for index = (page - 1) * pageSize + 1, math.min(page * pageSize, #catalog) do
            local entry = catalog[index]
            rows[#rows + 1] = ui.row{ key = entry.widget, w = width, h = 34, gap = 8,
                ui.symbol{ name = entry.icon, size = 15, color = secondary },
                ui.text{ text = entry.title, grow = 1, size = 11, color = foreground, maxWidth = math.max(40, width - 92) },
                button("add", if entry.error then "Unavailable" else "Add", if not entry.error then function(root)
                    request(root, function(done) return omniwm.components.add(entry.widget, {}, done) end)
                end else nil, false, entry.error or "Add " .. entry.title) }
        end
        if #(ctx.data.catalog or {}) == 0 then
            rows[#rows + 1] = ui.text{ text = "Copy a component folder into shell/widgets to add it here.",
                size = 11, color = secondary, maxWidth = width, lines = 3 }
        end
        return ui.column(rows)
    end
    local selected
    for _, component in ctx.data.components or {} do
        if component.id == ctx.state.settingsSelection then selected = component; break end
    end
    selected = selected or (ctx.data.components or {})[1]
    if not selected then
        return ui.column{ w = width, h = height, gap = 8,
            ui.symbol{ name = "square.grid.2x2", size = 25, color = secondary },
            ui.text{ text = "Build your island", size = 13, color = foreground },
            ui.text{ text = "Add a widget to begin.", size = 11, color = secondary } }
    end
    local id = selected.id
    local descriptor = catalogEntry(ctx, selected.widget)
    local rows = { key = "details:" .. id, w = width, h = height, gap = 6, scroll = true, center = false }
    rows[#rows + 1] = ui.row{ w = width, gap = 6,
        ui.text{ text = selected.title, size = 13, weight = "semibold", color = foreground, grow = 1 },
        button("show", "Show", if selected.enabled then function(root)
            root.state.primary = id
            root.state.navigationPage = nil
            root.state.expanded = true
            root.state.settingsOpen = false
            root.state.motion = "promotion"
        end else nil, false, "Show " .. selected.title),
        button("remove", "Remove", function(root)
            request(root, function(done) return omniwm.components.remove(id, done) end)
        end, false, "Remove " .. selected.title) }
    local placement = preferences.region(ctx, id)
    rows[#rows + 1] = ui.row{ w = width, h = 34, gap = 8,
        ui.text{ text = "Region", size = 11, color = secondary, grow = 1 },
        button("region", regionTitles[placement] .. " ›", function(root)
            local current = preferences.region(root, id)
            local index = table.find(preferences.regions, current) or 1
            setRoot(root, "regions", preferences.assigningRegion(root, id, preferences.regions[index % #preferences.regions + 1]))
        end, false, "Choose where this component appears") }
    if selected.error then rows[#rows + 1] = ui.text{ text = selected.error, size = 10, color = "#fca5a5", maxWidth = width, lines = 3 } end
    local options = descriptor and descriptor.options or {}
    local keys = {}
    for key in options do keys[#keys + 1] = key end
    table.sort(keys)
    local page, controls = pageControls(ctx, "settingsOptionPage", #keys, width)
    if controls then rows[#rows + 1] = controls end
    for index = (page - 1) * pageSize + 1, math.min(page * pageSize, #keys) do
        local key = keys[index]
        rows[#rows + 1] = settingRow(ctx, key, options[key], selected.options or {}, function(root, name, value)
            request(root, function(done) return omniwm.components.set(id, name, value, done) end)
        end, width, "component:" .. id)
    end
    if #keys == 0 then rows[#rows + 1] = ui.text{ text = "This widget has no additional options.", size = 11, color = secondary, maxWidth = width, lines = 2 } end
    return ui.column(rows)
end

local function render(ctx, island, close)
    local width = math.max(1, math.min(620, island.size.w - 24))
    local top = island.notch and island.notch.h or 10
    local height = math.max(1, math.min(340, island.size.h))
    local page = ctx.state.settingsPage or "Widgets"
    local tabs = { w = width - 24, gap = 4 }
    for _, name in panes do
        tabs[#tabs + 1] = button(name, name, function(root) root.state.settingsPage = name end, page == name, name .. " settings")
    end
    tabs[#tabs + 1] = ui.box{ grow = 1 }
    tabs[#tabs + 1] = button("done", "Done", close)
    local contentHeight = math.max(1, height - top - 78)
    local content
    if page == "Widgets" then
        local listWidth = math.min(230, width * 0.42)
        content = ui.row{ w = width - 24, h = contentHeight, gap = 14, center = false,
            ui.column{ w = listWidth, h = contentHeight, gap = 4, center = false,
                ui.row{ w = listWidth, h = 28,
                    ui.text{ text = "Your widgets", size = 11, color = secondary, grow = 1 },
                    button("add-component", "+ Add", function(root) root.state.settingsAdding = true end, false, "Add widget") },
                componentList(ctx, listWidth, math.max(1, contentHeight - 32), close) },
            componentDetails(ctx, math.max(1, width - listWidth - 38), contentHeight) }
    else
        local rows = { w = width - 24, h = contentHeight, gap = 6, scroll = true, center = false }
        local schema = ctx.data.settingsSchema or {}
        local keys = rootOptionKeys(page, schema)
        local optionPage, controls = pageControls(ctx, "settingsRootOptionPage:" .. page, #keys, width - 24)
        if controls then rows[#rows + 1] = controls end
        for index = (optionPage - 1) * pageSize + 1, math.min(optionPage * pageSize, #keys) do
            local key = keys[index]
            if schema[key] then
                rows[#rows + 1] = settingRow(ctx, key, schema[key], ctx.data.settings or {}, setRoot, width - 24, "root")
            end
        end
        if #rows == 0 then rows[1] = ui.text{ text = "Edit this profile’s settings in shell.toml.", size = 11, color = secondary } end
        content = ui.column(rows)
    end
    local notice = ctx.state.settingsError or ctx.state.alertError or (if (ctx.state.settingsRequests or 0) > 0 then "Saving…" else "Command + Return saves text · Escape cancels")
    return ui.stack{ w = island.size.w, h = island.size.h, align = "top",
        ui.column{ key = "lake-settings", w = width, h = height, pad = 12, gap = 8, align = "top", fill = "#08080a", radius = 28,
            animate = motion.shape.expanded, appear = motion.appear, exit = motion.exit,
            focusable = true, focusRing = false, keys = { "escape" }, onKey = function(root, event) if event.key == "escape" then close(root) end end,
            onOutsidePress = close,
            ui.box{ h = math.max(0, top - 12), w = 1 },
            ui.row(tabs), content,
            ui.text{ text = notice, size = 10, color = if ctx.state.settingsError or ctx.state.alertError then "#fca5a5" else secondary,
                maxWidth = width - 24, lines = 2 } } }
end

return table.freeze({ render = render, request = request, move = move })

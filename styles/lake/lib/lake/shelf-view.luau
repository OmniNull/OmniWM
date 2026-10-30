local service = require("./services/shelf")
local view = require("./view")

local function button(text, action, key)
    return ui.box{ key = key, pad = 6, radius = 7, fill = "#ffffff12", hover = "#ffffff22", pressOpacity = 0.7,
        onClick = action, ui.text{ text = text, size = 10, color = view.foreground } }
end

local function row(ctx, item)
    local width = math.max(140, math.min(380, (ctx.view.w or 400) - 20))
    local resource = item.resource
    local ready = resource and resource.state == "ready"
    local file = resource and (resource.kind == "file" or resource.kind == "image")
    local key = "shelf:" .. ctx.view.name .. ":" .. tostring(item.id)
    local detail = item.error or (resource and resource.error)
    if not detail then
        if not resource then detail = "Unavailable"
        elseif resource.state ~= "ready" then detail = "Preparing…"
        elseif not item.token then detail = "Waiting to save…"
        elseif resource.persistence and resource.persistence.state ~= "durable" then
            detail = resource.persistence.error or "Saving…"
        else detail = resource.kind end
    end
    local actions = {}
    local function action(label, name)
        actions[#actions + 1] = button(label, function(next) service.action(next.instance, item, name, key) end)
    end
    if ready then
        if resource.kind == "file" or resource.kind == "url" then action("Open", "open") end
        if resource.kind == "file" then action("Reveal", "reveal") end
        if file then action("Preview", "preview") end
        action("Copy", "copy")
        action("Share", "share")
        action("AirDrop", "airdrop")
    end
    if item.error or (resource and resource.state == "failed") then
        actions[#actions + 1] = button("Retry", function(next) service.retry(next.instance, item.id) end)
    end
    actions[#actions + 1] = button("Remove", function(next) service.remove(next.instance, item.id) end)
    return ui.column{ key = key, gap = 5, pad = 7, radius = 9, fill = "#ffffff09",
        ui.row{ gap = 8,
            ui.box{ key = "drag:" .. tostring(item.id), w = 38, h = 38, radius = 7, fill = "#ffffff12",
                dragItems = if ready then { resource } else nil,
                onDragOut = if ready then function(next, event)
                    next.state.shelfDragging = if event.phase == "began" then item.id else nil
                end else nil,
                if ready and file then ui.image{ image = resource, thumbnail = 64, w = 34, h = 34 }
                else ui.symbol{ name = resource and resource.kind == "url" and "link" or "doc", size = 18, color = view.secondary } },
            ui.column{ gap = 3, align = "left",
                ui.input{ key = "name:" .. tostring(item.id) .. ":" .. tostring(ctx.state.renameResetID == item.id and ctx.state.renameReset or 0),
                    text = item.name, w = width - 72, h = 28, maxLength = 128,
                    onCommit = function(next, event)
                        local ok, err = service.rename(next.instance, item.id, event.text)
                        next.state.shelfFormError = if ok then nil else err
                    end,
                    onCancel = function(next)
                        next.state.renameResetID = item.id
                        next.state.renameReset = (next.state.renameReset or 0) + 1
                        next.state.shelfFormError = nil
                    end },
                ui.text{ text = detail, size = 10, color = item.error and "#fca5a5" or view.secondary, maxWidth = width - 72 } } },
        ui.row{ gap = 4, table.unpack(actions, 1, math.min(4, #actions)) },
        #actions > 4 and ui.row{ gap = 4, table.unpack(actions, 5) } or nil }
end

local function rows(ctx)
    local items = service.items(ctx.instance)
    local pages = math.max(1, math.ceil(#items / 4))
    local page = math.clamp(ctx.state.shelfPage or 1, 1, pages)
    local children = {}
    for index = (page - 1) * 4 + 1, math.min(page * 4, #items) do children[#children + 1] = row(ctx, items[index]) end
    if #items == 0 then children[#children + 1] = ui.text{ text = "Drop files, images, links or text", size = 12, color = view.secondary } end
    if pages > 1 then
        children[#children + 1] = ui.row{ gap = 8,
            button("Previous", function(next) next.state.shelfPage = math.max(1, page - 1) end),
            ui.text{ text = tostring(page) .. " / " .. tostring(pages), size = 11, color = view.secondary },
            button("Next", function(next) next.state.shelfPage = math.min(pages, page + 1) end) }
    end
    return ui.column{ gap = 7, table.unpack(children) }
end

return table.freeze({ rows = rows, button = button })

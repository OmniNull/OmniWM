local limit = 32

local function state(instance)
    return instance.state.shelf
end

local function save(instance)
    local shelf = state(instance)
    local items = {}
    for _, item in shelf.items do
        items[#items + 1] = { id = item.id, name = item.name, token = item.token,
            error = item.error or (not item.token and "Item was not saved; add it again") }
    end
    local ok, err = omniwm.store.set("shelf", { next = shelf.next, items = items })
    shelf.saveError = if ok then nil else tostring(err)
    return ok
end

local function contains(shelf, item)
    return table.find(shelf.items, item) ~= nil
end

local pump
pump = function(instance)
    local shelf = state(instance)
    if not shelf.alive or shelf.persisting then return end
    for _, item in shelf.items do
        if item.resource and not item.token and not item.error then
            shelf.persisting = item
            local token, err = omniwm.resources.persist(item.resource, function(result)
                if not shelf.alive then return end
                shelf.persisting = nil
                if contains(shelf, item) then
                    item.error = if result.ok then nil else tostring(result.error)
                    save(instance)
                end
                pump(instance)
            end)
            if token then
                item.token = token
                save(instance)
                return
            end
            shelf.persisting = nil
            item.error = tostring(err)
        end
    end
    save(instance)
end

local function initialize(instance)
    local shelf = { items = {}, next = 0, alive = true }
    instance.state.shelf = shelf
    local saved = omniwm.store.get("shelf")
    if saved == nil then return end
    if type(saved) ~= "table" or type(saved.items) ~= "table" or #saved.items > limit
        or type(saved.next) ~= "number" or saved.next < 0 or saved.next % 1 ~= 0 or saved.next > 1000000000 then
        shelf.loadError = "Saved shelf is invalid"
        return
    end
    local ids = {}
    local entries = 0
    for key, item in saved.items do
        entries += 1
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #saved.items
            or type(item) ~= "table" or type(item.id) ~= "number" or item.id % 1 ~= 0
            or item.id < 1 or item.id > saved.next or ids[item.id]
            or type(item.name) ~= "string" or #item.name > 1024
            or (item.token ~= nil and (type(item.token) ~= "string" or #item.token ~= 36)) then
            shelf.loadError = "Saved shelf is invalid"
            return
        end
        ids[item.id] = true
    end
    if entries ~= #saved.items then shelf.loadError = "Saved shelf is invalid"; return end
    shelf.next = saved.next
    for _, item in saved.items do
        local resource, err
        if item.token then resource, err = omniwm.resources.restore(item.token) end
        shelf.items[#shelf.items + 1] = { id = item.id, name = item.name, token = item.token,
            resource = resource, error = err or (not resource and "Item was not saved; add it again") }
    end
end

local function add(instance, resources)
    local shelf = state(instance)
    if shelf.loadError then return false, shelf.loadError end
    local known = {}
    for _, item in shelf.items do if item.resource then known[item.resource.id] = true end end
    local added = 0
    for _, resource in resources do
        if not known[resource.id] then
            if #shelf.items == limit then shelf.error = "Shelf is full (32 items)"; break end
            shelf.next += 1
            shelf.items[#shelf.items + 1] = { id = shelf.next, name = resource.name, resource = resource }
            known[resource.id] = true
            added += 1
        end
    end
    if added > 0 then shelf.error = if #shelf.items == limit and #resources > added then "Shelf is full (32 items)" else nil end
    pump(instance)
    return added > 0, shelf.error
end

local function remove(instance, id)
    local shelf = state(instance)
    for index, item in shelf.items do
        if item.id == id then table.remove(shelf.items, index); save(instance); return end
    end
end

local function rename(instance, id, text)
    local name = string.match(text, "^%s*(.-)%s*$")
    local count = utf8.len(name)
    if not count or count < 1 or count > 128 or #name > 512 then return false, "Use a name of 1–128 characters" end
    for _, item in state(instance).items do
        if item.id == id then item.name = name; save(instance); return true end
    end
    return false, "Item was removed"
end

local function retry(instance, id)
    local shelf = state(instance)
    if shelf.loadError then return end
    for _, item in shelf.items do
        if not id or item.id == id then
            if item.token and (not item.resource or item.resource.state == "failed") then
                local resource, err = omniwm.resources.restore(item.token)
                item.resource = resource
                item.error = err
            elseif item.resource and item.error and shelf.persisting ~= item then
                item.token = nil
                item.error = nil
            end
        end
    end
    pump(instance)
end

local function desktop(instance, start, receive)
    local shelf = state(instance)
    if shelf.desktop then shelf.error = "Another file action is pending"; return false, shelf.error end
    shelf.error = nil
    local handle, err = start(function(result)
        shelf.desktop = nil
        if not shelf.alive then return end
        if result.ok then
            shelf.error = nil
            if receive then receive(result) end
        else shelf.error = tostring(result.error) end
    end)
    shelf.desktop = handle
    if not handle then shelf.error = tostring(err) end
    return handle ~= nil, err
end

local function pick(instance)
    return desktop(instance, function(callback) return omniwm.pick({ files = true, multiple = true }, callback) end,
        function(result) add(instance, result.items or {}) end)
end

local function paste(instance)
    return desktop(instance, function(callback) return omniwm.clipboard.read(callback) end,
        function(result) add(instance, result.items or {}) end)
end

local function action(instance, item, name, anchor)
    if not item.resource or item.resource.state ~= "ready" then state(instance).error = "Item is not ready"; return false, "Item is not ready" end
    return desktop(instance, function(callback)
        local resource = item.resource
        if name == "open" then return omniwm.open(resource, callback)
        elseif name == "reveal" then return omniwm.reveal(resource, callback)
        elseif name == "copy" then return omniwm.clipboard.copy(resource, callback)
        elseif name == "preview" then return omniwm.quicklook({ resource }, 1, callback)
        elseif name == "share" then return omniwm.share({ resource }, anchor, nil, callback)
        elseif name == "airdrop" then return omniwm.share({ resource }, anchor, "airdrop", callback) end
        return nil, "Unknown action"
    end)
end

local function cancel(instance)
    local shelf = state(instance)
    if not shelf then return end
    shelf.alive = false
    if shelf.desktop then shelf.desktop:cancel(); shelf.desktop = nil end
end

local function error(instance)
    local shelf = state(instance)
    return shelf.loadError or shelf.error or shelf.saveError
        or (omniwm.store.status.state == "failed" and omniwm.store.status.error)
end

local function clear(instance)
    local shelf = state(instance)
    shelf.items = {}
    shelf.loadError = nil
    shelf.error = nil
    save(instance)
end

return table.freeze({ initialize = initialize, add = add, remove = remove, rename = rename, retry = retry,
    pick = pick, paste = paste, action = action, cancel = cancel, error = error, clear = clear,
    items = function(instance) return state(instance).items end,
    pending = function(instance) return state(instance).persisting ~= nil end })

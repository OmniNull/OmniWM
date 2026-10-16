local shelf = require("./shelf")
local formats = { png = true, jpeg = true, tiff = true }
local extensions = { png = true, jpg = true, jpeg = true, tif = true, tiff = true, gif = true, heic = true, heif = true, bmp = true, jp2 = true }
local utis = { ["public.png"] = true, ["public.jpeg"] = true, ["public.tiff"] = true,
    ["com.compuserve.gif"] = true, ["public.heic"] = true, ["public.heif"] = true,
    ["com.microsoft.bmp"] = true, ["public.bmp"] = true, ["public.jpeg-2000"] = true }

local function initialize(instance)
    shelf.initialize(instance)
    instance.state.convert = { inputs = {}, serial = 0 }
end

local function start(instance)
    local state = instance.state.convert
    if state.request then return false, "Conversion is already pending" end
    if #state.inputs == 0 then state.error = "Drop image files first"; return false, state.error end
    local format = instance.options.format or "png"
    if not formats[format] then state.error = "Unsupported output format"; return false, state.error end
    state.error = nil
    local request, err = omniwm.provider.send("convert", { format = format }, { files = state.inputs }, function(result)
        state.request = nil
        if result.ok then
            if not result.files or #result.files == 0 then state.error = "Converter returned no files"; return end
            local added, failure = shelf.add(instance, result.files)
            state.error = failure
            if added then
                state.serial += 1
                state.alert = { id = "converted:" .. tostring(state.serial), seconds = 4 }
            end
        else state.error = tostring(result.error) end
    end)
    state.request = request
    if not request then state.error = tostring(err) end
    return request ~= nil, err
end

local function accept(instance, resources)
    local state = instance.state.convert
    if state.request then state.error = "Conversion is already pending"; return false, state.error end
    if #resources < 1 or #resources > 32 then state.error = "Use 1–32 image files"; return false, state.error end
    local inputs = {}
    local ids = {}
    for _, resource in resources do
        local suffix = string.lower(string.match(resource.name, "%.([^.]+)$") or "")
        if (resource.kind ~= "file" and resource.kind ~= "image") or (not utis[resource.uti] and not extensions[suffix]) then
            state.error = "Only supported image files can be converted"
            return false, state.error
        end
        if resource.state == "failed" then state.error = resource.error or "Input failed"; return false, state.error end
        if not ids[resource.id] then inputs[#inputs + 1] = resource; ids[resource.id] = true end
    end
    state.inputs = inputs
    return start(instance)
end

local function options(instance)
    local state = instance.state.convert
    if state.request then state.request:cancel(); state.request = nil; state.error = "Options changed; retry conversion" end
end

local function cancel(instance)
    options(instance)
    shelf.cancel(instance)
end

local function status(instance)
    if not instance.state.convert.request then return "Drop images to make " .. string.upper(instance.options.format or "png") .. " copies" end
    local progress = instance.provider.state.conversion
    if type(progress) == "table" and progress.active == true and type(progress.total) == "number"
        and progress.total >= 1 and progress.total <= 32 and progress.total % 1 == 0
        and type(progress.completed) == "number" and progress.completed >= 0 and progress.completed <= progress.total
        and progress.completed % 1 == 0 then
        return "Converting " .. tostring(progress.completed) .. " / " .. tostring(progress.total)
    end
    return "Waiting for images or converting…"
end

local function activity(ctx)
    local state = ctx.instance.state.convert
    return { priority = state.request and 35 or 0, label = state.request and "Converting images" or "Image converter", alert = state.alert, dropTypes = { "image" } }
end

return table.freeze({ initialize = initialize, accept = accept, retry = start, options = options, cancel = cancel,
    activity = activity, status = status, outputs = shelf.items, error = function(instance) return instance.state.convert.error or shelf.error(instance) end,
    pending = function(instance) return instance.state.convert.request ~= nil end })

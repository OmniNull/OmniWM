local view = require("../lib/lake/view")
local poll

local function validRepo(repo)
    if type(repo) ~= "string" then return false end
    local owner, name = string.match(repo, "^([%w%-]+)/([%w%._%-]+)$")
    return owner ~= nil and #owner <= 39 and #name <= 100
        and string.sub(owner, 1, 1) ~= "-" and string.sub(owner, -1) ~= "-"
        and name ~= "." and name ~= ".."
end

local function prefix(text, length)
    local ending = utf8.offset(text, length + 1)
    return ending and string.sub(text, 1, ending - 1) or text
end

local function runsFrom(value)
    if type(value) ~= "table" then return nil end
    local count = #value
    local entries = 0
    for key in value do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then return nil end
        entries += 1
    end
    if entries ~= count then return nil end
    if count == 0 then return json.encode(value) == "[]" and value or nil end
    local runs = {}
    for index = 1, math.min(5, count) do
        local run = value[index]
        if type(run) ~= "table" or type(run.id) ~= "number" or run.id <= 0 or run.id % 1 ~= 0
            or type(run.name) ~= "string" or type(run.status) ~= "string" then return nil end
        local attempt = run.run_attempt or run.attempt or 1
        if type(attempt) ~= "number" or attempt < 1 or attempt % 1 ~= 0 then return nil end
        runs[index] = { id = run.id, name = prefix(run.name, 160), status = prefix(run.status, 32),
            conclusion = type(run.conclusion) == "string" and prefix(run.conclusion, 32) or nil, attempt = attempt }
    end
    return runs
end

local function cancel(instance)
    local state = instance.state
    if state.request then state.request:cancel(); state.request = nil end
    if state.timer then state.timer:cancel(); state.timer = nil end
end

local function schedule(instance)
    local state = instance.state
    if state.request or state.timer then return end
    local timer, err = omniwm.after(math.clamp(instance.options.interval or 60, 15, 3600), function()
        state.timer = nil
        poll(instance)
    end)
    state.timer = timer
    state.paused = timer == nil
    if not timer then state.error = "Polling paused: " .. tostring(err) end
end

poll = function(instance)
    local state = instance.state
    if state.request or state.timer then return end
    if not validRepo(instance.options.repo) then
        state.error = "Use a repository in owner/name format"
        state.paused = true
        return
    end
    state.paused = false
    local request, err = omniwm.http({
        url = "https://api.github.com/repos/" .. instance.options.repo .. "/actions/runs?per_page=5",
        headers = { Accept = "application/vnd.github+json", ["X-GitHub-Api-Version"] = "2022-11-28" },
        response = "json", maxBytes = 262144, timeout = 30,
    }, function(result)
        state.request = nil
        local runs = result.ok and type(result.json) == "table" and runsFrom(result.json.workflow_runs) or nil
        if runs then
            state.runs = runs
            state.error = nil
            state.alert = nil
            local latest = runs[1]
            if latest and (latest.conclusion == "failure" or latest.conclusion == "timed_out") then
                local id = tostring(latest.id) .. ":" .. tostring(latest.attempt)
                if id ~= state.lastAlert then
                    state.alert = { id = id, seconds = 4 }
                    state.lastAlert = id
                end
            end
            local saved, failure = omniwm.store.set("snapshot", {
                repo = instance.options.repo, runs = runs, lastAlert = state.lastAlert,
            })
            state.saveError = not saved and tostring(failure) or nil
        else
            state.error = result.error or (result.ok and "Invalid workflow response" or "HTTP " .. tostring(result.status))
        end
        schedule(instance)
    end)
    state.request = request
    if not request then
        state.error = tostring(err)
        schedule(instance)
    end
end

local function initialize(instance)
    local state = instance.state
    state.runs = {}
    state.error = nil
    state.saveError = nil
    state.alert = nil
    state.lastAlert = nil
    local cached = omniwm.store.get("snapshot")
    if type(cached) == "table" and cached.repo == instance.options.repo then
        state.runs = runsFrom(cached.runs) or {}
        state.lastAlert = type(cached.lastAlert) == "string" and cached.lastAlert or nil
    end
    poll(instance)
end

local function refresh(ctx)
    local instance = ctx.instance
    if instance.state.request then return end
    if instance.state.timer then instance.state.timer:cancel(); instance.state.timer = nil end
    poll(instance)
end

local function appearance(run)
    if not run then return "clock", "No runs", view.secondary end
    if run.conclusion == "success" then return "checkmark.circle.fill", "Passed", "#86efac" end
    if run.conclusion == "failure" or run.conclusion == "timed_out" then return "xmark.circle.fill", "Failed", "#fda4af" end
    if run.status ~= "completed" then return "clock.arrow.circlepath", "Running", "#fde68a" end
    return "minus.circle", run.conclusion or "Completed", view.secondary
end

local function compact(ctx)
    local state = ctx.instance.state
    local icon, label, color = appearance(state.runs[1])
    if state.paused then icon, label, color = "pause.circle", "Paused", "#fde68a"
    elseif state.error then icon, label, color = "wifi.exclamationmark", "Offline", "#fde68a" end
    return view.compact(ctx, icon, label, color)
end

local function expanded(ctx)
    local state = ctx.instance.state
    local width = math.max(1, math.min(430, (ctx.view.w or 520) - 48))
    local rows = { gap = 8, align = "top", dy = (ctx.view.props or {}).top or 0,
        ui.text{ text = ctx.instance.options.repo, color = view.foreground, size = 13, maxWidth = width } }
    for _, run in state.runs do
        local icon, label, color = appearance(run)
        rows[#rows + 1] = ui.row{ gap = 8, w = width,
            ui.symbol{ name = icon, size = 13, color = color },
            ui.text{ text = run.name, color = view.foreground, size = 12, maxWidth = math.max(1, width - 119), grow = 1 },
            ui.text{ text = label, color = color, size = 11, maxWidth = 90 } }
    end
    if #state.runs == 0 then
        rows[#rows + 1] = ui.text{ text = state.request and "Loading workflows…" or "No workflow runs", size = 12, color = view.secondary, maxWidth = width }
    end
    local error = state.error or state.saveError or omniwm.store.status.error
    if error then rows[#rows + 1] = ui.text{ text = error, size = 11, color = "#fde68a", maxWidth = width } end
    rows[#rows + 1] = ui.box{ key = "refresh", pad = 6, radius = 7, hover = "#ffffff18",
        pressScale = 0.97, onClick = not state.request and refresh or nil,
        ui.text{ text = state.paused and "Retry polling" or state.request and "Refreshing…" or "Refresh", size = 11, color = view.secondary } }
    return ui.column(rows)
end

return {
    init = initialize,
    deinit = cancel,
    options = function(instance) cancel(instance); initialize(instance) end,
    activity = function(ctx)
        local state = ctx.instance.state
        local latest = state.runs[1]
        local failed = latest and (latest.conclusion == "failure" or latest.conclusion == "timed_out")
        return { priority = failed and 70 or latest and latest.status ~= "completed" and 30 or 0,
            label = latest and latest.name or state.error, alert = state.alert }
    end,
    views = { compact = compact, expanded = expanded },
}

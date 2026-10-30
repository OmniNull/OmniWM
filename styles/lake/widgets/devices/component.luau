local service = require("../lib/lake/services/devices")
local view = require("../lib/lake/view")
local symbols = table.freeze({ headphones = "headphones", keyboard = "keyboard", mouse = "computermouse", gamepad = "gamecontroller", phone = "iphone", computer = "desktopcomputer" })

local function levels(device)
    local parts = {}
    if device.battery then parts[#parts + 1] = string.format("%.0f%%", device.battery) end
    for _, field in { {"left", "L"}, {"right", "R"}, {"case", "Case"} } do
        if device[field[1]] then parts[#parts + 1] = string.format("%s %.0f%%", field[2], device[field[1]]) end
    end
    return #parts > 0 and table.concat(parts, " · ") or "Battery unavailable"
end

return { views = { compact = function(ctx)
    local data = service.snapshot(ctx)
    local devices = service.connected(data)
    return view.compact(ctx, "headphones", if not data then "—" else tostring(#devices), "#93c5fd")
end, expanded = function(ctx)
    local data = service.snapshot(ctx)
    local rows = { gap = 12, align = "top", dy = (ctx.view.props or {}).top or 0 }
    if not data then rows[1] = ui.text{ text = "Bluetooth unavailable", color = view.secondary }
    elseif data.access ~= "granted" then
        rows[1] = ui.text{ text = "Bluetooth access: " .. data.access, color = view.secondary }
        rows[2] = view.button("lock.open", if data.access == "notDetermined" then service.authorize else service.settings)
    elseif not data.power then rows[1] = ui.text{ text = "Bluetooth is off", color = view.secondary }; rows[2] = view.button("gearshape", service.settings)
    else
        local devices = service.connected(data)
        for index, device in devices do
            if index > 5 then break end
            rows[#rows + 1] = ui.row{ key = device.id, gap = 14,
                ui.symbol{ name = symbols[device.kind] or "antenna.radiowaves.left.and.right", size = 24, color = "#93c5fd" },
                ui.column{ center = false, gap = 4,
                    ui.text{ text = device.name, size = 13, maxWidth = 330, color = view.foreground },
                    ui.text{ text = levels(device), size = 11, color = view.secondary } } }
        end
        if #devices == 0 then rows[1] = ui.text{ text = "No connected devices", color = view.secondary } end
        if #devices > 5 then rows[#rows + 1] = ui.text{ text = "+" .. tostring(#devices - 5) .. " more connected", size = 11, color = view.secondary } end
    end
    return ui.column(rows)
end }, activity = service.activity }

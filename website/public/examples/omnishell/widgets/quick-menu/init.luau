local function item(key, symbol, label, action)
    return ui.row{ key = key, w = 260, pad = 10, gap = 10, radius = 8,
        hover = "accent/0.15", onClick = action,
        ui.symbol{ name = symbol, size = 14, color = "accent" },
        ui.text{ text = label, grow = 1, align = "leading" } }
end

function render(ctx)
    return ui.row{ gap = 6, pad = 6, onClick = ui.popout,
        ui.symbol{ name = "line.3.horizontal", size = 14 },
        ui.text{ text = "Quick menu" } }
end

function popout(ctx)
    local rows = { gap = 4, pad = 8, radius = 12, fill = "surface" }
    if ctx.state.page == "audio" then
        rows[#rows + 1] = item("back", "chevron.left", "Back", function(next)
            next.state.page = "main"
        end)
        rows[#rows + 1] = item("volume-up", "speaker.plus", "Volume +5%", function()
            omniwm.run("volume up 5")
        end)
        rows[#rows + 1] = item("mute", "speaker.slash", "Mute output", function()
            omniwm.run("volume mute")
        end)
    else
        rows[#rows + 1] = item("audio", "speaker.wave.2", "Audio…", function(next)
            next.state.page = "audio"
        end)
        rows[#rows + 1] = item("omniwm-menu", "menubar.rectangle", "OmniWM menu", function()
            omniwm.run("shell menu")
        end)
    end
    rows[#rows + 1] = item("close", "xmark", "Close", ui.popout)
    return ui.column(rows)
end

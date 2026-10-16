// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

struct ShellSystemDisplay: Equatable, Sendable {
    let width: Int
    let height: Int
    let refresh: Int
}

struct ShellSystemData: Equatable, Sendable {
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var pressure: MemoryPressureLevel?
    var diskUsed: Int64 = 0
    var diskTotal: Int64 = 0
    var uptime = 0.0
    let host: SystemStatsHostInfo
    let displays: [ShellSystemDisplay]

    func write(into writer: inout ShellValueWriter) {
        writer.map(5)
        writer.key("memory")
        writer.map(3)
        writer.key("used")
        writer.number(Double(memoryUsed))
        writer.key("total")
        writer.number(Double(memoryTotal))
        writer.key("pressure")
        if let pressure {
            writer.string(pressure.rawValue)
        } else {
            writer.null()
        }
        writer.key("disk")
        writer.map(2)
        writer.key("used")
        writer.number(Double(diskUsed))
        writer.key("total")
        writer.number(Double(diskTotal))
        writer.key("uptime")
        writer.number(uptime)
        writer.key("host")
        writer.map(4)
        writer.key("name")
        writer.string(host.hostname)
        writer.key("chip")
        writer.string(host.chip)
        writer.key("model")
        writer.string(host.modelIdentifier)
        writer.key("os")
        writer.string(host.osVersion)
        writer.key("displays")
        writer.array(displays.count)
        for display in displays {
            writer.map(3)
            writer.key("w")
            writer.number(Double(display.width))
            writer.key("h")
            writer.number(Double(display.height))
            writer.key("hz")
            writer.number(Double(display.refresh))
        }
    }
}

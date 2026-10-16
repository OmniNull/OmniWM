// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellWorldClockEntry: Codable, Equatable, Identifiable {
    var id: UUID = .init()
    var label: String
    var zone: String

    enum CodingKeys: String, CodingKey {
        case label, zone
    }
}

enum ShellWidgetSettingsModel {
    static func fields(widget: String, config: ShellConfig) -> [String: ShellServiceValue] {
        guard let bytes = config.widgetSettings[widget] else { return [:] }
        return (try? ShellServiceValue.decode(bytes).fields) ?? [:]
    }

    static func values(widget: String, config: ShellConfig) -> [String: ShellComponentValue] {
        fields(widget: widget, config: config).compactMapValues(\.componentValue)
    }

    static func clocks(config: ShellConfig) -> [ShellWorldClockEntry] {
        let entries = fields(widget: "world-clock", config: config)["zones"]?.values ?? []
        let clocks = entries.compactMap { value -> ShellWorldClockEntry? in
            guard let fields = value.fields, let label = fields["label"]?.string,
                  let zone = fields["zone"]?.string else { return nil }
            return ShellWorldClockEntry(label: label, zone: zone)
        }
        return clocks.isEmpty ? [
            ShellWorldClockEntry(label: "London", zone: "Europe/London"),
            ShellWorldClockEntry(label: "Tokyo", zone: "Asia/Tokyo")
        ] : clocks
    }

    static func validClocks(_ clocks: [ShellWorldClockEntry]) -> Bool {
        !clocks.isEmpty && clocks.count <= 64 && clocks.allSatisfy {
            !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.label.count <= 128 && TimeZone(identifier: $0.zone) != nil
        }
    }

    static func title(_ value: String) -> String {
        switch value {
        case "icon_and_text": String(localized: "Icon and Title")
        case "icon_only": String(localized: "Icon Only")
        case "text_only": String(localized: "Title Only")
        case "meters": String(localized: "Meters")
        case "gauge": String(localized: "Gauges")
        case "graph": String(localized: "Graphs")
        case "beside": String(localized: "Beside Icon")
        case "inside": String(localized: "Inside Icon")
        case "off",
             "none": String(localized: "Off")
        case "auto": String(localized: "Automatic")
        case "main": String(localized: "Main")
        case "side": String(localized: "Side")
        case "expanded": String(localized: "Expanded Only")
        case "toggle": String(localized: "Toggle Expansion")
        case "expand": String(localized: "Expand")
        case "collapse": String(localized: "Collapse")
        case "settings": String(localized: "Settings")
        case "next": String(localized: "Next Widget")
        case "previous": String(localized: "Previous Widget")
        default: ShellBarLayout.title(of: value)
        }
    }

    static func description(_ widget: String) -> String {
        switch widget {
        case "workspaces": String(localized: "Workspaces, app icons, and window navigation.")
        case "active-window": String(localized: "The focused app and window title.")
        case "clock": String(localized: "Local time and an optional date.")
        case "world-clock": String(localized: "Time in the places you choose.")
        case "stats",
             "system-stats": String(localized: "CPU, memory, and system activity.")
        case "volume": String(localized: "Volume, audio devices, and per-app levels.")
        case "weather": String(localized: "Current weather and the forecast for your location.")
        case "media": String(localized: "Now Playing and playback controls.")
        case "calendar": String(localized: "Upcoming events and your calendar.")
        case "privacy": String(localized: "Microphone and camera activity.")
        case "control-center": String(localized: "Audio, media, calendar, weather, and system controls.")
        case "battery",
             "battery-details": String(localized: "Battery charge and power information.")
        case "launcher": String(localized: "Open the command palette.")
        case "apple-menu": String(localized: "Native Apple menu commands.")
        case "app-menu": String(localized: "Menus for the focused app.")
        case "scratchpads": String(localized: "Your scratchpad windows.")
        case "hidden-bar",
             "hidden-bar-menu": String(localized: "Show the menu-bar items you have hidden.")
        default: String(localized: "A widget from the selected style or your shell folder.")
        }
    }

    static func region(id: String, values: [String: ShellComponentValue]) -> String {
        guard case let .strings(regions)? = values["regions"] else { return "auto" }
        let prefix = id + ":"
        return regions.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? "auto"
    }

    static func regions(
        id: String, placement: String, components: [ShellComponentInstance], values: [String: ShellComponentValue]
    ) -> ShellComponentValue {
        .strings(components.compactMap { component in
            let region = component.id == id ? placement : region(id: component.id, values: values)
            return region == "auto" ? nil : component.id + ":" + region
        })
    }

    static func rgba(_ value: String) -> SIMD4<Double>? {
        guard value.hasPrefix("#"), value.count == 7 || value.count == 9,
              let integer = UInt64(value.dropFirst(), radix: 16) else { return nil }
        let bits = value.count == 7 ? integer << 8 | 255 : integer
        return SIMD4(
            Double((bits >> 24) & 255) / 255,
            Double((bits >> 16) & 255) / 255,
            Double((bits >> 8) & 255) / 255,
            Double(bits & 255) / 255
        )
    }
}

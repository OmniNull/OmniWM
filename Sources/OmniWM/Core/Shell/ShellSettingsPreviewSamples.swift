// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum ShellSettingsPreviewSamples {
    static func values(style: ShellBarStyle, islandSize: CGSize?, dark: Bool, scale: CGFloat) -> [String: [UInt8]] {
        var values: [String: ShellServiceValue] = [
            "clock": .text("16:42"), "date": .text("Tuesday, October 13"), "seconds": .number(1_791_924_120),
            "cpu": .number(18), "memory": .number(42), "gpu": .number(12), "disk": .number(34),
            "battery": .number(76), "charging": .bool(false), "volume": .number(45), "muted": .bool(false),
            "network": .object(["down": .number(1200000), "up": .number(240000)]),
            "workspace": .text("1"), "app": .text("Safari"), "bundle": .text("com.apple.Safari"),
            "title": .text("A quiet afternoon"), "vars": .object([:]),
            "menuApp": .object(["pid": .number(0), "name": .text("Safari"), "bundle": .text("com.apple.Safari")]),
            "appearance": .object(["dark": .bool(dark)]),
            "media": media,
            "weather": weather,
            "calendar": calendar,
            "wifi": .object([
                "power": .bool(true),
                "connected": .bool(true),
                "ssid": .text("Home"),
                "rssi": .number(-48),
                "noise": .number(-92),
                "rate": .number(866),
                "location": .text("authorized")
            ]),
            "privacy": .object(["microphone": .bool(false), "camera": .bool(false)]),
            "bluetooth": .object(["power": .bool(true), "access": .text("allowed"), "devices": .array([])]),
            "user": .object(["name": .text("Alex"), "account": .text("alex"), "avatar": .null]),
            "hiddenBar": .object(["items": .array([]), "hidden": .array([]), "visible": .bool(false)]),
            "workspaces": .array(["1", "2", "3"].map { .object([
                "id": .text($0), "name": .text($0), "focused": .bool($0 == "1"), "visible": .bool($0 == "1"),
                "windows": .number($0 == "1" ? 2 : $0 == "2" ? 1 : 0)
            ]) })
        ]
        if let size = islandSize {
            values["island"] = island(size: size, scale: scale)
        }
        var encoded = values.mapValues { value in
            var writer = ShellValueWriter()
            value.write(to: &writer)
            return writer.bytes
        }
        var writer = ShellValueWriter()
        bar(style: style).write(to: &writer)
        encoded["bar"] = writer.bytes
        return encoded
    }

    private static var windows: [ShellServiceValue] {
        [
            .object([
                "id": .text("sample-safari"),
                "bundle": .text("com.apple.Safari"),
                "name": .text("Safari"),
                "title": .text("A quiet afternoon"),
                "column": .number(1)
            ]),
            .object([
                "id": .text("sample-notes"),
                "bundle": .text("com.apple.Notes"),
                "name": .text("Notes"),
                "title": .text("Ideas for the weekend"),
                "column": .number(2)
            ]),
            .object([
                "id": .text("sample-terminal"),
                "bundle": .text("com.apple.Terminal"),
                "name": .text("Terminal"),
                "title": .text("Projects"),
                "column": .number(3)
            ])
        ]
    }

    private static var media: ShellServiceValue {
        .object([
            "title": .text("Golden Hour"),
            "artist": .text("Sample artist"),
            "album": .text("Afternoon"),
            "app": .text("Music"),
            "bundle": .text("com.apple.Music"),
            "pid": .number(0),
            "playing": .bool(true),
            "duration": .number(240),
            "elapsed": .number(78),
            "rate": .number(0),
            "sampledAt": .number(0),
            "artwork": .null,
            "shuffle": .bool(false),
            "repeatMode": .text("off")
        ])
    }

    private static var weather: ShellServiceValue {
        .object([
            "temp": .number(19),
            "feels": .number(18),
            "high": .number(21),
            "low": .number(12),
            "rain": .number(10),
            "wind": .number(9),
            "humidity": .number(48),
            "code": .number(1),
            "day": .bool(true),
            "unit": .text("°C"),
            "place": .text("Sample city"),
            "condition": .text("Partly cloudy"),
            "symbol": .text("cloud.sun"),
            "stale": .bool(false),
            "hours": .array([]),
            "days": .array([])
        ])
    }

    private static var calendar: ShellServiceValue {
        .object([
            "access": .text("fullAccess"),
            "events": .array([]),
            "month": .object([
                "title": .text("October 2026"),
                "year": .number(2026),
                "month": .number(10),
                "days": .number(31),
                "offset": .number(3),
                "today": .number(13),
                "weekdays": .array(["M", "T", "W", "T", "F", "S", "S"]
                    .map(ShellServiceValue.text)),
                "marked": .array([.number(13)])
            ])
        ])
    }

    private static func island(size: CGSize, scale: CGFloat) -> ShellServiceValue {
        .object([
            "display": .text("Sample display"), "size": .object([
                "w": .number(size.width),
                "h": .number(size.height)
            ]),
            "notch": .null, "menuBar": .number(24), "scale": .number(scale), "main": .bool(true),
            "visible": .bool(true), "fullscreen": .bool(false), "focused": .bool(false),
            "navigation": .object([
                "workspace": .text("1"),
                "name": .text("1"),
                "layout": .text("niri"),
                "focused": .text("sample-safari"),
                "windows": .array(windows)
            ])
        ])
    }

    static func bar(style: ShellBarStyle) -> ShellBarData {
        let items = [
            ShellBarItem(
                id: "sample-safari",
                bundle: "com.apple.Safari",
                name: "Safari",
                focused: true,
                count: 1,
                hidden: 0,
                windows: [.init(id: "sample-safari", title: "A quiet afternoon", focused: true, hidden: false)]
            ),
            ShellBarItem(
                id: "sample-notes",
                bundle: "com.apple.Notes",
                name: "Notes",
                focused: false,
                count: 1,
                hidden: 0,
                windows: [.init(id: "sample-notes", title: "Ideas for the weekend", focused: false, hidden: false)]
            ),
            ShellBarItem(
                id: "sample-terminal",
                bundle: "com.apple.Terminal",
                name: "Terminal",
                focused: false,
                count: 1,
                hidden: 0,
                windows: [.init(id: "sample-terminal", title: "Projects", focused: false, hidden: false)]
            )
        ]
        return ShellBarData(monitor: "Sample display", style: style, workspaces: [
            .init(id: "1", name: "1", focused: true, windows: Array(items.prefix(2))),
            .init(id: "2", name: "2", focused: false, windows: Array(items.suffix(1))),
            .init(id: "3", name: "3", focused: false, windows: [])
        ])
    }
}

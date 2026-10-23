// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ShellBundledWidgetTests: XCTestCase {
    private static let names = [
        "clock", "battery", "volume", "weather", "stats", "workspaces", "scratchpads", "omniwm", "system-stats",
        "hidden-bar", "media", "calendar", "launcher", "active-window", "input-source", "wifi", "bluetooth",
        "battery-details", "world-clock", "privacy", "control-center"
    ]

    private static let essentials = [
        "clock", "date", "seconds", "cpu", "memory", "charging", "bar", "workspace", "app", "bundle", "title"
    ]

    private func value(_ write: (inout ShellValueWriter) -> Void) -> [UInt8] {
        var writer = ShellValueWriter()
        write(&writer)
        return writer.bytes
    }

    private func fullData(
        island: WorkspaceBarIslandSlice = .all,
        vertical: Bool = false,
        capsule: Bool = false,
        configureBar: (inout ShellBarData) -> Void = { _ in }
    ) throws -> [(String, [UInt8])] {
        let weather = ShellWeather(
            temp: 21.4, feels: 20, high: 24, low: 13, rain: 30, wind: 9.5, humidity: 64, sunrise: 1_791_370_800,
            sunset: 1_791_411_000, code: 61, day: true, unit: "°C",
            place: "Toronto", stale: true,
            hours: (0 ..< 24).map { ShellWeatherHour(
                time: Double($0),
                label: "\($0)",
                temp: 20,
                code: 3,
                day: true,
                rain: 10
            ) },
            days: (0 ..< 7).map { ShellWeatherDay(
                time: Double($0),
                label: "D\($0)",
                high: 25,
                low: 12,
                code: 61,
                rain: nil
            ) }
        )
        let window = ShellBarWindow(id: "ow_a", title: "A", focused: true, hidden: false)
        let item = { (id: String, count: Int, hidden: Int, floating: Bool) in
            ShellBarItem(
                id: id, bundle: "com.apple.finder", name: "Finder", focused: id == "ow_a", count: count,
                hidden: hidden, badge: "3", floating: floating, windows: Array(repeating: window, count: count)
            )
        }
        var bar = ShellBarData(island: island, badges: "text")
        bar.style.statsButton = true
        bar.style.vertical = vertical
        bar.style.position = vertical ? "left" : "belowMenuBar"
        bar.style.transparent = capsule
        bar.workspaces = [
            ShellBarWorkspace(
                id: "1",
                name: "1",
                focused: true,
                windows: [item("ow_a", 1, 0, false), item("ow_b", 2, 2, true)]
            ),
            ShellBarWorkspace(id: "web", name: "Web", focused: false, windows: [item("ow_c", 3, 1, false)])
        ]
        bar.scratchpads = [
            ShellBarScratchpad(
                id: 1,
                name: "Notes",
                focused: true,
                revealed: true,
                visible: true,
                windows: (0 ..< 5).map { item("ow_s\($0)", 1, 0, false) }
            ),
            ShellBarScratchpad(
                id: 2,
                name: "Mail",
                focused: false,
                revealed: false,
                visible: false,
                windows: [item("ow_m", 1, 0, false)],
                compact: true
            )
        ]
        bar.drag = ShellBarDrag(
            sources: ["ow_a"],
            workspaces: ["web"],
            icons: ["ow_c"],
            gaps: [ShellBarDrag.Gap(workspace: "1", before: 1)]
        )
        configureBar(&bar)
        return [
            ("clock", value { $0.string("9:41 AM") }),
            ("date", value { $0.string("Tue 6 Oct") }),
            ("cpu", value { $0.number(42) }),
            ("memory", value { $0.number(91) }),
            ("battery", value { $0.number(15) }),
            ("charging", value { $0.bool(false) }),
            ("gpu", value { $0.number(12) }),
            ("disk", value { $0.number(55) }),
            ("network", value { writer in
                writer.map(2)
                writer.key("down")
                writer.number(1_250_000)
                writer.key("up")
                writer.number(20000)
            }),
            ("volume", value { $0.number(40) }),
            ("seconds", value { $0.number(1_000_030) }),
            ("calendar", value { writer in
                ShellCalendar(
                    access: "full",
                    events: [ShellCalendarEvent(
                        id: "e@1", title: "Standup", calendar: "Work", color: "#FF9500", start: 1_000_600,
                        end: 1_002_400, allDay: false, location: "Room", time: "9:30", day: "Today"
                    )],
                    month: ShellCalendarMonth(
                        title: "October 2026", year: 2026, month: 10, days: 31, offset: 4, today: 8,
                        weekdays: ["S", "M", "T", "W", "T", "F", "S"], marked: [8]
                    )
                ).write(into: &writer)
            }),
            ("media", value { writer in
                var media = ShellMedia()
                media.title = "Song"
                media.artist = "Artist"
                media.bundle = "com.apple.Music"
                media.playing = true
                media.duration = 200
                media.elapsed = 20
                media.rate = 1
                media.sampledAt = 1_000_000
                media.artwork = "media/abc"
                media.shuffle = true
                media.repeatMode = .all
                media.write(into: &writer)
            }),
            ("outputs", value { writer in
                writer.array(2)
                ShellAudioOutput(id: 42, name: "Speakers", transport: "builtin", isDefault: true).write(into: &writer)
                ShellAudioOutput(id: 7, name: "Display", transport: "hdmi", isDefault: false).write(into: &writer)
            }),
            ("muted", value { $0.bool(false) }),
            ("weather", value { weather.write(into: &$0) }),
            ("bar", value { bar.write(to: &$0) }),
            ("workspace", value { $0.string("1") }),
            ("app", value { $0.string("Finder") }),
            ("bundle", value { $0.string("com.apple.finder") }),
            ("title", value { $0.string("Documents") }),
            ("power", value { ShellPower(source: "battery", remaining: 252, lowPower: true).write(into: &$0) }),
            ("inputSource", value { writer in
                let abc = ShellInputSourceEntry(id: "com.apple.keylayout.ABC", name: "ABC", short: "ABC")
                let german = ShellInputSourceEntry(id: "com.apple.keylayout.German", name: "German", short: "DE")
                ShellInputSource(current: abc, sources: [abc, german]).write(into: &writer)
            }),
            ("privacy", value { ShellPrivacy(microphone: true, camera: true).write(into: &$0) }),
            ("wifi", value {
                ShellWiFi(
                    power: true, connected: true, ssid: "Harbourfront", rssi: -58, band: "5 GHz", channel: 149,
                    security: "WPA3 Personal", location: "authorized"
                ).write(into: &$0)
            }),
            ("bluetooth", value { writer in
                ShellBluetooth(power: true, access: "granted", devices: [
                    ShellBluetoothDevice(
                        id: "a1", name: "AirPods Pro", kind: "headphones", connected: true, battery: 82, left: 82,
                        right: 90, caseLevel: 40
                    ),
                    ShellBluetoothDevice(id: "m1", name: "MX Master", kind: "mouse", connected: false)
                ]).write(into: &writer)
            }),
            ("system", value { writer in
                var system = ShellSystemData(
                    host: SystemStatsHostInfo(
                        chip: "Apple M5",
                        modelIdentifier: "Mac17,1",
                        osVersion: "27.2",
                        hostname: "studio"
                    ),
                    displays: []
                )
                system.memoryUsed = 12 << 30
                system.memoryTotal = 32 << 30
                system.diskUsed = 400 << 30
                system.diskTotal = 1000 << 30
                system.uptime = 200_000
                system.write(into: &writer)
            }),
            ("user", value { ShellUser(name: "Ada Lovelace", account: "ada").write(into: &$0) }),
            ("thermal", value { ShellThermal(cpu: 61.5, gpu: 48, gpuName: "Apple M5").write(into: &$0) }),
            ("networkHistory", value {
                ShellNetworkHistory(
                    down: (0 ..< 31).map { Double($0 * 40000) },
                    up: (0 ..< 31).map { Double(($0 % 7) * 9000) },
                    received: 8 << 30,
                    sent: 1 << 30
                ).write(into: &$0)
            }),
            ("appearance", value { ShellAppearance(dark: true).write(into: &$0) }),
            ("lyrics", value {
                ShellLyrics(status: .synced, lines: (0 ..< 24).map {
                    ShellLyrics.Line(time: Double($0 * 5), text: "Line \($0 + 1) of the song")
                }).write(into: &$0)
            }),
            ("spectrum", value {
                ShellSpectrum(access: .granted, bars: (0 ..< 60).map { Float($0 % 10) / 10 }, bpm: 120)
                    .write(into: &$0)
            }),
            ("tempo", value { $0.number(120) }),
            ("hiddenBar", value { writer in
                ShellHiddenBarData(enabled: true, available: true, items: [
                    ShellHiddenBarItem(id: "com.example.a#0", name: "A", image: "hidden-bar/1", width: 22, height: 16),
                    ShellHiddenBarItem(id: "com.example.b#0", name: "B", image: nil, width: 16, height: 16)
                ]).write(into: &writer)
            })
        ]
    }

    private func message(_ error: [CChar]) -> String {
        String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func render(_ name: String, data: [(String, [UInt8])]) throws {
        try renderStyle("default", widget: name, data: data)
    }

    private func render(
        _ name: String,
        source: String,
        chunk: String,
        modules: [(path: String, source: String)] = [],
        data: [(String, [UInt8])],
        capture: ((omni_view, [UInt8], ShellTextStore) throws -> Void)? = nil,
        inspect: ((omni_view, [omni_wire_node], ShellTextStore) throws -> Void)? = nil
    ) throws {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 8 << 20))
        defer { _ = omni_vm_destroy(vm) }
        for module in modules {
            XCTAssertEqual(
                omni_vm_add_module(vm, module.path, module.path.utf8.count, module.source, module.source.utf8.count),
                OMNI_OK
            )
        }
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(
            omni_vm_load(vm, chunk, source, source.utf8.count, 1_000_000_000, &error, error.count),
            OMNI_OK,
            "\(name): \(message(error))"
        )
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        for (key, bytes) in data {
            _ = bytes.withUnsafeBufferPointer { omni_instance_set_value(instance, key, $0.baseAddress, $0.count) }
        }
        var views = [OMNI_VIEW_BAR]
        if source.contains("function popout") {
            views.append(OMNI_VIEW_POPOUT)
        }
        let text = ShellTextStore()
        for view in views {
            var stats = omni_render_stats()
            XCTAssertEqual(
                omni_instance_render(instance, view, 1_000_000_000, &stats, &error, error.count),
                OMNI_OK,
                "\(name) \(view): \(message(error))"
            )
            if inspect != nil || capture != nil {
                var size = 0
                let output = try XCTUnwrap(omni_instance_output(instance, view, &size))
                let bytes = Array(UnsafeBufferPointer(start: output, count: size))
                text.ingest(wire: bytes)
                let nodes = bytes.withUnsafeBytes { buffer in
                    let header = buffer.loadUnaligned(as: omni_wire_header.self)
                    return (0 ..< Int(header.node_count)).map { index in
                        buffer.loadUnaligned(
                            fromByteOffset: MemoryLayout<omni_wire_header>.stride
                                + index * MemoryLayout<omni_wire_node>.stride,
                            as: omni_wire_node.self
                        )
                    }
                }
                try inspect?(view, nodes, text)
                try capture?(view, bytes, text)
            }
        }
    }

    private func renderStyle(
        _ style: String,
        widget: String,
        data: [(String, [UInt8])],
        capture: ((omni_view, [UInt8], ShellTextStore) throws -> Void)? = nil,
        inspect: ((omni_view, [omni_wire_node], ShellTextStore) throws -> Void)? = nil
    ) throws {
        let defaults = try XCTUnwrap(ShellDefaults.bundled)
        let folder = style == "default" ? defaults
            : try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent(style)
        let path = "\(style)/widgets/\(widget)/init.luau"
        let profileSource = folder.appendingPathComponent("widgets/\(widget)/init.luau")
        let source = try ShellWidgetSourceLoader.build(.init(
            name: widget, shellDirectory: defaults.deletingLastPathComponent(),
            sourceURL: FileManager.default.fileExists(atPath: profileSource.path)
                ? profileSource : defaults.appendingPathComponent("widgets/\(widget)/init.luau"),
            directories: [folder, defaults], profile: style
        ))
        try render(
            path, source: source.main, chunk: source.chunk,
            modules: source.modules.map { ($0.path, $0.source) }, data: data, capture: capture, inspect: inspect
        )
    }

    func testStylesKeepWorkspaceInteractionContractAtEveryEdge() throws {
        for style in ["default", "wayline", "nocturne", "celestial", "system"] {
            for edge in ["top", "bottom", "left", "right"] {
                let data = try fullData { bar in
                    bar.style.height = style == "celestial" ? 60 : style == "system" ? 32 : 40
                    bar.style.position = edge
                    bar.style.vertical = edge == "left" || edge == "right"
                }
                try renderStyle(style, widget: "workspaces", data: data, inspect: { view, nodes, text in
                    guard view == OMNI_VIEW_BAR else { return }
                    let window = try XCTUnwrap(nodes.first { text.string($0.target) == "window ow_a" })
                    let interaction = OMNI_NODE_MENU | OMNI_NODE_PREVIEW | OMNI_NODE_DRAG
                    XCTAssertEqual(UInt32(window.flags) & interaction, interaction, "\(style) \(edge)")
                    XCTAssertEqual(text.string(window.action), "window focus ow_a")
                    let group = try XCTUnwrap(nodes.first { text.string($0.target) == "window ow_b" })
                    XCTAssertNotEqual(UInt32(group.flags) & OMNI_NODE_OPENS_POPOUT, 0)
                    let workspace = try XCTUnwrap(nodes.first { text.string($0.target) == "workspace 1" })
                    XCTAssertEqual(text.string(workspace.action), "switch-workspace 1")
                    XCTAssertNotEqual(UInt32(workspace.flags) & OMNI_NODE_DROP, 0)
                    XCTAssertTrue(nodes.contains { text.string($0.text) == "rectangle.on.rectangle" }, style)
                })
                try renderStyle(style, widget: "scratchpads", data: data, inspect: { view, nodes, text in
                    guard view == OMNI_VIEW_BAR else { return }
                    let scratchpad = try XCTUnwrap(nodes.first { text.string($0.target) == "scratchpad 1" })
                    XCTAssertEqual(text.string(scratchpad.action), "scratchpad toggle 1")
                    XCTAssertNotEqual(UInt32(scratchpad.flags) & OMNI_NODE_MENU, 0)
                    let visible = nodes.filter {
                        UInt32($0.flags) & OMNI_NODE_ICON_MASK == OMNI_NODE_ICON_WINDOW
                    }.count
                    let overflow = try XCTUnwrap(nodes.lazy.map { text.string($0.text) }.first { $0.hasPrefix("+") })
                    let hidden = try XCTUnwrap(Int(overflow.dropFirst()))
                    XCTAssertGreaterThan(visible, 0)
                    XCTAssertGreaterThan(hidden, 0)
                    XCTAssertEqual(visible + hidden, 5, "\(style) \(edge)")
                })
            }
        }
    }

    func testOmniWMButtonsShowTheKeyboardModeChip() throws {
        let modes = [
            ("paused", "pause.fill", "Paused"),
            ("prefix", "keyboard", "Prefix"),
            ("window", "keyboard", "Window Mode")
        ]
        for style in ["default", "wayline", "nocturne", "celestial", "system", "sakura", "matrix"] {
            for (mode, symbol, label) in modes {
                for vertical in [false, true] {
                    let data = try fullData(vertical: vertical) { bar in
                        bar.style.keyboardMode = mode
                    }
                    try renderStyle(style, widget: "omniwm", data: data, inspect: { view, nodes, text in
                        guard view == OMNI_VIEW_BAR else { return }
                        let strings = nodes.map { text.string($0.text) }
                        XCTAssertTrue(strings.contains(symbol), "\(style) \(mode)")
                        XCTAssertEqual(
                            strings.contains(ShellLocalizer.string(label, [])),
                            !vertical,
                            "\(style) \(mode)"
                        )
                    })
                }
            }
            try renderStyle(style, widget: "omniwm", data: fullData(), inspect: { view, nodes, text in
                guard view == OMNI_VIEW_BAR else { return }
                let strings = nodes.map { text.string($0.text) }
                XCTAssertFalse(strings.contains("pause.fill") || strings.contains("keyboard"), style)
            })
        }
    }

    func testStyleHeightScalesClockAndWorkspaceIconsTogether() throws {
        for style in ["wayline", "nocturne", "celestial", "system"] {
            let base = style == "celestial" ? 60.0 : style == "system" ? 32.0 : 40.0
            for scale in [1.0, 1.5] {
                let data = try fullData { $0.style.height = base * scale }
                try renderStyle(style, widget: "clock", data: data, inspect: { view, nodes, text in
                    guard view == OMNI_VIEW_BAR else { return }
                    let clock = try XCTUnwrap(nodes.first { text.string($0.text) == "9:41 AM" })
                    let pointSize = style == "celestial" ? 17.6 : style == "system" ? 13.0 : 14.0
                    XCTAssertEqual(Double(clock.text_size) / 100, pointSize * scale, accuracy: 0.02, style)
                })
                try renderStyle(style, widget: "workspaces", data: data, inspect: { view, nodes, _ in
                    guard view == OMNI_VIEW_BAR else { return }
                    let icons = nodes.filter { UInt32($0.flags) & OMNI_NODE_ICON_MASK == OMNI_NODE_ICON_WINDOW }
                    XCTAssertFalse(icons.isEmpty)
                    let size = style == "system" ? 18.0 : 24.0
                    for icon in icons {
                        XCTAssertEqual(Double(icon.width), size * scale, accuracy: 0.01, style)
                        XCTAssertEqual(Double(icon.height), size * scale, accuracy: 0.01, style)
                    }
                })
            }
        }
    }

    func testStylesRespectWorkspaceAppearanceOptions() throws {
        for style in ["wayline", "nocturne", "celestial", "system"] {
            let data = try fullData { bar in
                bar.style.height = style == "celestial" ? 60 : style == "system" ? 32 : 40
                bar.style.backgrounds = false
                bar.style.accents = false
                bar.style.textColor = "#12AB34"
                bar.style.inactive = 0.37
            }
            for widget in ["workspaces", "scratchpads", "system-stats"] {
                try renderStyle(style, widget: widget, data: data, inspect: { view, nodes, text in
                    guard view == OMNI_VIEW_BAR else { return }
                    let root = try XCTUnwrap(nodes.first)
                    XCTAssertEqual(root.fill, 0, "\(style)/\(widget)")
                    XCTAssertEqual(root.fill_role, 0, "\(style)/\(widget)")
                    let label = widget == "workspaces" ? "1" : widget == "scratchpads" ? "Notes" : nil
                    if let label {
                        let node = try XCTUnwrap(nodes.first { text.string($0.text) == label })
                        XCTAssertEqual(Int(node.color_role & 0xFF), ShellRole.foreground.rawValue + 1, style)
                    }
                    if widget != "system-stats" {
                        let reference = widget == "workspaces" ? "ow_c" : "ow_s0"
                        let icon = try XCTUnwrap(nodes.first {
                            UInt32($0.flags) & OMNI_NODE_ICON_MASK == OMNI_NODE_ICON_WINDOW
                                && text.string($0.icon_ref) == reference
                        })
                        XCTAssertEqual(icon.opacity, 0.37, accuracy: 0.001, style)
                    }
                })
            }
            let hiddenStats = try fullData { $0.style.statsButton = false }
            try renderStyle(style, widget: "system-stats", data: hiddenStats, inspect: { view, nodes, _ in
                guard view == OMNI_VIEW_BAR else { return }
                XCTAssertFalse(nodes.contains { UInt32($0.flags) & OMNI_NODE_OPENS_POPOUT != 0 }, style)
            })
        }
    }

    func testStylesExposeSystemHostAndStorageDetails() throws {
        let data = try fullData()
        for style in ["default", "wayline", "nocturne", "celestial", "system"] {
            try renderStyle(style, widget: "system-stats", data: data, inspect: { view, nodes, text in
                guard view == OMNI_VIEW_POPOUT else { return }
                let contents = nodes.map { text.string($0.text) }.joined(separator: "\n")
                for value in ["studio", "Mac17,1", "27.2", " / "] {
                    XCTAssertTrue(contents.contains(value), "\(style): \(value)")
                }
            })
        }
    }

    func testBundledWidgetsRenderWithMissingDataAndIslandLayouts() throws {
        let full = try fullData()
        let essentials = full.filter { Self.essentials.contains($0.0) }
        for name in Self.names {
            try render(name, data: essentials)
        }
        for island in [WorkspaceBarIslandSlice.active, .secondary] {
            for vertical in [false, true] {
                let data = try fullData(island: island, vertical: vertical)
                for name in ["workspaces", "scratchpads", "omniwm", "system-stats", "hidden-bar"] {
                    try render(name, data: data)
                }
            }
        }
    }

    func testWidgetVariantsRenderNativelyAndAsCapsules() throws {
        for capsule in [false, true] {
            for vertical in [false, true] {
                let data = try fullData(vertical: vertical, capsule: capsule)
                for indicator in ["pills", "underline", "dots", "numbers", "minimal"] {
                    try render("workspaces", data: data + [("settings", value { writer in
                        writer.map(1)
                        writer.key("indicator")
                        writer.string(indicator)
                    })])
                }
                for variant in ["meters", "gauge", "graph"] {
                    try render("stats", data: data + [("settings", value { writer in
                        writer.map(1)
                        writer.key("variant")
                        writer.string(variant)
                    })])
                }
                for name in Self.names {
                    try render(name, data: data)
                }
            }
        }
        let unknownZone = try fullData() + [("settings", value { writer in
            writer.map(1)
            writer.key("zones")
            writer.array(1)
            writer.map(2)
            writer.key("label")
            writer.string("Nowhere")
            writer.key("zone")
            writer.string("Mars/Olympus")
        })]
        try render("world-clock", data: unknownZone)
    }

    func testStyleWidgetsRenderAndKeepTheirDefaultsBehaviour() throws {
        let styles = try XCTUnwrap(ShellDefaults.bundledStyles)
        let variants = try [fullData(), fullData().filter { (Self.essentials + ["hiddenBar"]).contains($0.0) }]
            + [WorkspaceBarIslandSlice.active, .secondary].flatMap { island in
                try [false, true].map { try fullData(island: island, vertical: $0) }
            }
        for style in ["celestial", "nocturne", "system", "wayline"] {
            let widgets = styles.appendingPathComponent(style, isDirectory: true).appendingPathComponent("widgets")
            for name in try FileManager.default.contentsOfDirectory(atPath: widgets.path) {
                let source = try String(
                    contentsOf: widgets.appendingPathComponent("\(name)/init.luau"),
                    encoding: .utf8
                )
                for data in variants {
                    try renderStyle(style, widget: name, data: data)
                }
                guard let original = ShellConfig.bundledWidget(name) else { continue }
                XCTAssertEqual(
                    Self.declarations(source),
                    try Self.declarations(String(contentsOf: original, encoding: .utf8)),
                    "\(style)/\(name)"
                )
            }
        }
    }

    func testSystemWidgetsFitTheBarAndRenderEveryPopoutInBothAppearances() throws {
        let folder = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("system")
        let defaults = try XCTUnwrap(ShellDefaults.bundled)
        let widgets = try FileManager.default
            .contentsOfDirectory(atPath: defaults.appendingPathComponent("widgets").path)
        let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        for dark in [false, true] {
            let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false), windowIcon: { _ in finder })
            resources.palette.refresh(
                theme: .native,
                appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            )
            for vertical in [false, true] {
                let data = try fullData(vertical: vertical) {
                    $0.style.height = 32
                    $0.style.backgrounds = false
                    $0.style.position = vertical ? "left" : "belowMenuBar"
                }
                for widget in widgets {
                    try renderStyle("system", widget: widget, data: data, capture: { view, bytes, text in
                        let surface = ShellWidgetSurface(
                            scale: 2,
                            resources: resources,
                            directories: [folder, defaults]
                        )
                        XCTAssertTrue(surface.apply(bytes, text: text), widget)
                        let size = surface.size
                        let kind = view == OMNI_VIEW_BAR ? "bar" : "popout"
                        let direction = vertical ? "vertical" : "horizontal"
                        let name = "system-\(widget)-\(kind)-\(direction)-\(dark ? "dark" : "light")"
                        XCTAssertTrue(size.width.isFinite && size.height.isFinite, name)
                        XCTAssertGreaterThanOrEqual(size.width, 0, name)
                        XCTAssertGreaterThanOrEqual(size.height, 0, name)
                        if view == OMNI_VIEW_BAR {
                            XCTAssertLessThanOrEqual(vertical ? size.width : size.height, 32, name)
                        }
                        if size.width > 0, size.height > 0,
                           let directory = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"]
                        {
                            try Self.writeSnapshot(surface, name: name, dark: dark, directory: directory)
                        }
                    })
                }
            }
        }
    }

    static func writeSnapshot(
        _ surface: ShellWidgetSurface,
        name: String,
        dark: Bool,
        directory: String,
        background: CGColor? = nil
    ) throws {
        ShellLayerScene.engineQueue.sync {}
        let inset: CGFloat = 12
        let size = surface.size
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil((size.width + inset * 2) * 2)),
            height: Int(ceil((size.height + inset * 2) * 2)), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(background ?? CGColor(gray: dark ? 0.12 : 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(context.width), height: CGFloat(context.height)))
        context.translateBy(x: inset * 2, y: CGFloat(context.height) - inset * 2)
        context.scaleBy(x: 2, y: -2)
        try XCTUnwrap(surface.view.layer).render(in: context)
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            folder.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), name)
    }

    private func writeAppearanceSnapshots(_ bytes: [UInt8], text: ShellTextStore, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { return }
        for dark in [false, true] {
            let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
            resources.palette.refresh(
                theme: .native,
                appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            )
            let surface = ShellWidgetSurface(scale: 2, resources: resources, directories: [])
            XCTAssertTrue(surface.apply(bytes, text: text), name)
            try Self.writeSnapshot(
                surface,
                name: "\(name)-\(dark ? "dark" : "light")",
                dark: dark,
                directory: directory
            )
        }
    }

    func testSystemPopoutsUseOneNativeGlassSurfaceWithFullAndMissingData() throws {
        let full = try fullData { $0.style.height = 32 }
        let variants = [full, full.filter { (Self.essentials + ["hiddenBar"]).contains($0.0) }]
        let widgets = [
            "battery-details", "bluetooth", "calendar", "control-center", "hidden-bar", "hidden-bar-menu",
            "input-source", "media", "stats", "system-stats", "volume", "weather", "world-clock", "wifi"
        ]
        for widget in widgets {
            for data in variants {
                var original: [omni_wire_node] = []
                try renderStyle("default", widget: widget, data: data, inspect: { view, nodes, _ in
                    if view == OMNI_VIEW_POPOUT { original = nodes }
                })
                try renderStyle("system", widget: widget, data: data, inspect: { view, nodes, _ in
                    guard view == OMNI_VIEW_POPOUT else { return }
                    let empty = nodes.isEmpty || nodes.count == 1 && nodes[0].width == 0 && nodes[0].height == 0
                    let wasEmpty = original.isEmpty || original.count == 1 && original[0].width == 0 && original[0]
                        .height == 0
                    XCTAssertEqual(empty, wasEmpty, "\(widget) preserves the default empty-data contract")
                    if empty {
                        XCTAssertTrue([
                            "battery-details", "bluetooth", "calendar", "input-source", "weather", "wifi", "world-clock"
                        ].contains(widget), widget)
                        XCTAssertEqual(nodes.count, original.count, widget)
                        for node in nodes {
                            XCTAssertEqual(node.text, 0, widget)
                            XCTAssertEqual(node.action, 0, widget)
                            XCTAssertEqual(node.fill, 0, widget)
                            XCTAssertEqual(node.fill_role, 0, widget)
                            XCTAssertEqual(node.flags, 0, widget)
                        }
                        return
                    }
                    let root = try XCTUnwrap(nodes.first, widget)
                    let glass = OMNI_MATERIAL_GLASS << OMNI_NODE_MATERIAL_SHIFT
                    XCTAssertEqual(UInt32(root.flags) & OMNI_NODE_MATERIAL_MASK, glass, widget)
                    XCTAssertEqual(root.fill, 0, widget)
                    XCTAssertEqual(root.fill_role, 0, widget)
                    XCTAssertEqual(
                        nodes.filter { UInt32($0.flags) & OMNI_NODE_MATERIAL_MASK == glass }.count,
                        1,
                        widget
                    )
                })
            }
        }
    }

    func testSystemControlCenterTabsRenderWithFullAndMissingDataAndUnknownTabsShowOverview() throws {
        let full = try fullData { $0.style.height = 32 }
        let variants = [full, full.filter { Self.essentials.contains($0.0) }]
        let tabs = [
            ("overview", "Control Center"), ("audio", "Audio"), ("media", "Media"), ("calendar", "Calendar"),
            ("weather", "Weather"), ("system", "System"), ("unknown", "Control Center")
        ]
        for (index, data) in variants.enumerated() {
            for (tab, title) in tabs {
                let settings = value { writer in
                    writer.map(1)
                    writer.key("tab")
                    writer.string(tab)
                }
                try renderStyle(
                    "system",
                    widget: "control-center",
                    data: data + [("settings", settings)],
                    capture: { view, bytes, text in
                        guard view == OMNI_VIEW_POPOUT else { return }
                        try self.writeAppearanceSnapshots(
                            bytes, text: text,
                            name: "system-control-center-\(tab)-\(index == 0 ? "full" : "missing")"
                        )
                    },
                    inspect: { view, nodes, text in
                        guard view == OMNI_VIEW_POPOUT else { return }
                        let heading = try XCTUnwrap(nodes.first { $0.text != 0 }, tab)
                        XCTAssertEqual(text.string(heading.text), ShellLocalizer.string(title, []), tab)
                        let root = try XCTUnwrap(nodes.first, tab)
                        XCTAssertEqual(
                            UInt32(root.flags) & OMNI_NODE_MATERIAL_MASK,
                            OMNI_MATERIAL_GLASS << OMNI_NODE_MATERIAL_SHIFT,
                            tab
                        )
                    }
                )
            }
        }
    }

    func testSystemStatsVariantsKeepReadableGaugeTextAndRenderWithMissingData() throws {
        let full = try fullData { $0.style.height = 32 }
        let variants = [full, full.filter { Self.essentials.contains($0.0) }]
        for (index, data) in variants.enumerated() {
            for variant in ["meters", "gauge", "graph"] {
                let settings = value { writer in
                    writer.map(1)
                    writer.key("variant")
                    writer.string(variant)
                }
                try renderStyle(
                    "system", widget: "stats", data: data + [("settings", settings)],
                    capture: { view, bytes, text in
                        let kind = view == OMNI_VIEW_BAR ? "bar" : "popout"
                        try self.writeAppearanceSnapshots(
                            bytes, text: text,
                            name: "system-stats-\(variant)-\(kind)-\(index == 0 ? "full" : "missing")"
                        )
                    },
                    inspect: { view, nodes, text in
                        guard view == OMNI_VIEW_BAR, variant == "gauge" else { return }
                        for value in ["42", "91"] {
                            let reading = try XCTUnwrap(nodes.first { text.string($0.text) == value })
                            XCTAssertEqual(reading.text_size, 1000)
                        }
                    }
                )
            }
        }
    }

    func testCelestialDashboardTabsRenderWithFullAndMissingData() throws {
        let library = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("celestial/lib")
        let modules = try FileManager.default.contentsOfDirectory(atPath: library.path).map {
            try ("celestial/lib/\($0)", String(contentsOf: library.appendingPathComponent($0), encoding: .utf8))
        }
        let full = try fullData()
        for pane in ["dash", "mediatab", "performance", "weathertab"] {
            let source = """
            local pane = require("../lib/\(pane)")
            function render(ctx)
                return ui.box{ w = 0, h = 0 }
            end
            function popout(ctx)
                local weather = ctx.data.weather
                if weather and (weather.days[1].code ~= 61 or weather.hours[1].code ~= 3) then
                    error("forecast codes")
                end
                return pane.tab(ctx)
            end
            """
            for data in [full, full.filter { Self.essentials.contains($0.0) }] {
                try render(
                    "celestial/\(pane)",
                    source: source,
                    chunk: "@celestial/widgets/tabs/init.luau",
                    modules: modules,
                    data: data
                )
            }
        }
    }

    func testCelestialLibrariesBuildMorphableShapesAndGeometry() throws {
        let library = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("celestial/lib")
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 8 << 20))
        defer { _ = omni_vm_destroy(vm) }
        for file in try FileManager.default.contentsOfDirectory(atPath: library.path) {
            let source = try String(contentsOf: library.appendingPathComponent(file), encoding: .utf8)
            let path = "celestial/lib/\(file)"
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
        }
        let source = """
        local shapes = require("../lib/shapes")
        local geometry = require("../lib/geometry")
        local icons = require("../lib/icons")
        local surface = require("../lib/surface")
        local function check(condition, message)
            if not condition then error(message) end
        end
        function render(ctx)
            check(#shapes.names == 35, "35 shapes")
            for _, name in shapes.names do
                for _, rotation in { 0, 37 } do
                    local _, curves = string.gsub(shapes.path(name, rotation), "C ", "")
                    check(curves == 72, name .. " has " .. curves .. " curves")
                end
            end
            check(math.abs(shapes.radius("Circle", 123) - 0.5) < 0.002, "circle radius")
            check(shapes.radius("Cookie12Sided", 0) > shapes.radius("Cookie12Sided", 15), "cookie lobes")
            local gauge = geometry.gauge(100, 8, 0.25, 135, 270)
            check(gauge.value ~= nil and gauge.track ~= nil and gauge.dot ~= nil, "gauge parts")
            check(geometry.gauge(100, 8, 0).value == nil, "empty gauge")
            check(geometry.sparkline({ 1 }, 10, 10, 1) == nil, "one sample")
            check(icons.weather(2, false) == "partly_cloudy_night", "night weather")
            check(icons.wifi(-40, true) == "network_wifi_locked", "wifi")
            check(icons.battery(0.5, true) == "battery_charging_60", "battery")
            check(icons.volume(0, true) == "no_sound", "volume")
            return ui.stack{
                ui.path{ d = shapes.path("Gem"), viewBox = shapes.viewBox, w = 40, h = 40 },
                ui.path{ d = geometry.wavyRing(100, 40, 3, 8), w = 100, h = 100 },
                ui.path{ d = geometry.wavyLine(200, 10, 20, 3), w = 200, h = 10 },
                ui.path{ d = geometry.drawer(400, 300, 20, 28), w = 440, h = 300 },
                ui.path{ d = geometry.sector(50, 50, 50, -90, 120), w = 100, h = 100 },
                ui.path{ d = geometry.sparkline({ 1, 3, 2, 5 }, 100, 40, 5, true), w = 100, h = 40 },
                surface.button("play_arrow", "filled", { onClick = "media toggle" }),
            }
        end
        """
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(
            omni_vm_load(
                vm,
                "@celestial/widgets/check/init.luau",
                source,
                source.utf8.count,
                100_000_000,
                &error,
                error.count
            ),
            OMNI_OK,
            message(error)
        )
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        var stats = omni_render_stats()
        XCTAssertEqual(
            omni_instance_render(instance, OMNI_VIEW_BAR, 500_000_000, &stats, &error, error.count),
            OMNI_OK,
            message(error)
        )
    }

    private static func declarations(_ source: String) -> [String] {
        source.split(separator: "\n").filter {
            $0.hasPrefix("function popout") || $0.hasPrefix("function trigger") || $0.hasPrefix("spanIslands =")
                || $0.hasPrefix("interval =")
        }.map { $0.hasPrefix("function") ? String($0.prefix { $0 != "(" }) : String($0) }
    }
}

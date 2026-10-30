// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText
import ImageIO
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ShellStyleLayoutTests: XCTestCase {
    private let applications = ["com.apple.Safari", "com.apple.Terminal", "com.apple.finder", "com.apple.Notes"]

    private func barHostingProfiles(in shell: URL) throws -> [String] {
        var hosting: [String] = []
        var laneless: [String] = []
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            if config.leading.isEmpty, config.center.isEmpty, config.trailing.isEmpty {
                laneless.append(profile)
            } else {
                hosting.append(profile)
            }
        }
        XCTAssertEqual(laneless, ["vitreus"])
        return hosting
    }

    func testStyleEjectsStayInTheirProfileAndDefaultEjectsBecomeUserOverrides() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let celestial = ShellConfig.resolve(shellDirectory: shell)
        let profile = shell.appendingPathComponent(celestial.profile, isDirectory: true)
        XCTAssertEqual(
            try ShellProfiles.eject("workspaces", config: celestial, shellDirectory: shell),
            profile.appendingPathComponent("widgets/workspaces", isDirectory: true)
        )
        XCTAssertNil(try ShellProfiles.eject("workspaces", config: celestial, shellDirectory: shell))
        XCTAssertNotNil(celestial.file("lib/shapes.luau"))
        let copied = try XCTUnwrap(ShellProfiles.eject("privacy", config: celestial, shellDirectory: shell))
        XCTAssertEqual(copied, profile.appendingPathComponent("widgets/privacy", isDirectory: true))
        XCTAssertTrue(try ShellProfiles.create("custom", in: shell))
        XCTAssertNotNil(ShellConfig.resolve(shellDirectory: shell).widget("custom"))
        XCTAssertTrue(try ShellProfiles.select(ShellDefaults.profile, in: shell))
        let original = ShellConfig.resolve(shellDirectory: shell)
        let defaults = shell.appendingPathComponent(ShellDefaults.profile, isDirectory: true)
        XCTAssertEqual(original.widget("workspaces"), defaults.appendingPathComponent("widgets/workspaces/init.luau"))
        XCTAssertEqual(original.widget("privacy"), defaults.appendingPathComponent("widgets/privacy/init.luau"))
        XCTAssertNil(original.widget("custom"))
        XCTAssertNil(original.file("lib/shapes.luau"))
        XCTAssertEqual(
            try ShellProfiles.eject("workspaces", config: original, shellDirectory: shell),
            shell.appendingPathComponent("widgets/workspaces", isDirectory: true)
        )
        XCTAssertEqual(original.widget("workspaces"), shell.appendingPathComponent("widgets/workspaces/init.luau"))
    }

    func testStylesFitTheirThicknessAtBothBackingScalesAndOrientations() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let appearances = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] != nil ? [false, true] : [false]
        for profile in try barHostingProfiles(in: shell) {
            _ = try ShellProfiles.select(profile, in: shell)
            let config = ShellConfig.resolve(shellDirectory: shell)
            let base = config.barOverride?.settings.height ?? 24
            for height in [base, base * 1.5] {
                for vertical in [false, true] {
                    for scale in [CGFloat(1), 2] {
                        for dark in appearances {
                            try render(
                                config,
                                shell: shell,
                                height: height,
                                vertical: vertical,
                                scale: scale,
                                dark: dark
                            )
                        }
                    }
                }
            }
        }
    }

    func testExportWidgetRendersForEveryProfile() throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNIWM_STEP_RENDERS"] else {
            throw XCTSkip("Set OMNIWM_STEP_RENDERS to export per-profile widget renders")
        }
        let name = ProcessInfo.processInfo.environment["OMNIWM_STEP_WIDGET"] ?? "workspaces"
        let shared = ProcessInfo.processInfo.environment["OMNIWM_STEP_SHARED"] == "1"
        let tab = ProcessInfo.processInfo.environment["OMNIWM_STEP_TAB"] ?? "audio"
        let environment = ProcessInfo.processInfo.environment
        let shell = try stepShell(environment)
        defer { try? FileManager.default.removeItem(at: shell) }
        if !shared, let baseline = ProcessInfo.processInfo.environment["OMNIWM_STEP_BASE_SOURCE"] {
            try Data(contentsOf: URL(fileURLWithPath: baseline))
                .write(to: shell.appendingPathComponent("default/widgets/\(name)/init.luau"))
        }
        try useSharedLibraries(ProcessInfo.processInfo.environment["OMNIWM_STEP_SHARED_LIBS"] ?? "", in: shell)
        for profile in ShellProfiles.names(in: shell).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let height = config.barOverride?.settings.height ?? 32
            for dark in [false, true] {
                for vertical in [false, true] {
                    let resources = ShellResources(
                        motion: MotionPolicy(animationsEnabled: false),
                        windowIcon: { [applications] id in
                            guard let index = Int(id), applications.indices.contains(index),
                                  let url = NSWorkspace.shared
                                      .urlForApplication(withBundleIdentifier: applications[index])
                            else { return nil }
                            return NSWorkspace.shared.icon(forFile: url.path)
                        }
                    )
                    resources.palette.refresh(
                        theme: config.theme,
                        appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                    )
                    let widget = try makeWidget(
                        name, config: config, shell: shell, resources: resources,
                        source: shared ? shell.appendingPathComponent("default/widgets/\(name)/init.luau") : nil
                    )
                    if ["volume", "control-center"].contains(name) {
                        audioFixture(widget, access: .granted)
                    }
                    if name == "media" || (name == "control-center" && tab == "media") {
                        mediaFixture(widget)
                    }
                    if ["clock", "calendar"].contains(name) || (name == "control-center" && tab == "calendar") {
                        calendarFixture(widget)
                    }
                    if name == "weather" || (name == "control-center" && tab == "weather") {
                        weatherFixture(widget)
                    }
                    if name == "control-center", tab == "overview" {
                        wifiFixture(widget)
                        bluetoothFixture(widget)
                        batteryFixture(widget)
                        mediaFixture(widget)
                    }
                    if name == "control-center", tab == "system" {
                        systemStatsFixture(widget)
                    }
                    if ["battery", "battery-details"].contains(name) {
                        batteryFixture(widget)
                    }
                    if name == "wifi" {
                        wifiFixture(widget)
                        networkFixture(widget)
                    }
                    if name == "bluetooth" {
                        bluetoothFixture(widget)
                    }
                    if name == "active-window" {
                        widget.set("app") { $0.string("Safari") }
                        widget.set("bundle") { $0.string("com.apple.Safari") }
                        widget.set("title") { $0.string("A quiet afternoon") }
                    }
                    statusFixture(widget, name: name)
                    var bar = name == "scratchpads"
                        ? scratchpadFixture(config, height: height, vertical: vertical)
                        : fixture(config, height: height, vertical: vertical)
                    if environment["OMNIWM_STEP_CAPSULE"] == "1" {
                        bar.style.transparent = true
                        bar.style.backgrounds = true
                    }
                    widget.render(bar)
                    if ["hidden-bar", "hidden-bar-menu"].contains(name) {
                        let hidden = hiddenBarFixture(vertical: vertical, menu: name == "hidden-bar-menu")
                        widget.set("hiddenBar") { hidden.write(into: &$0) }
                        widget.layoutPopout()
                    }
                    let background = resources.palette.color(.clear, default: .background)
                    try ShellBundledWidgetTests.writeSnapshot(
                        widget.surface,
                        name: "\(name)-\(profile)-\(vertical ? "vertical" : "horizontal")-\(dark ? "dark" : "light")",
                        dark: dark, directory: directory, background: background
                    )
                    if name == "battery-details" {
                        for mode in ["inside", "off"] {
                            widget.set("settings") {
                                ShellServiceValue.object(["percent": .text(mode)]).write(to: &$0)
                            }
                            widget.render(bar)
                            try ShellBundledWidgetTests.writeSnapshot(
                                widget.surface,
                                name: "\(name)-\(profile)-\(vertical ? "vertical" : "horizontal")-\(mode)\(dark ? "-dark" : "")",
                                dark: dark, directory: directory, background: background
                            )
                        }
                        widget.set("settings") { ShellServiceValue.object([:]).write(to: &$0) }
                        widget.render(bar)
                    }
                    if ["volume", "control-center"].contains(name), !vertical {
                        audioFixture(widget, access: .granted)
                        if name == "control-center" {
                            widget.set("settings") { ShellServiceValue.object(["tab": .text(tab)]).write(to: &$0) }
                        }
                        widget.layoutPopout()
                        try ShellBundledWidgetTests.writeSnapshot(
                            widget.surface,
                            name: "\(name)-\(profile)-popout-\(dark ? "dark" : "light")",
                            dark: dark, directory: directory, background: background
                        )
                        if !dark {
                            audioFixture(widget, access: .denied)
                            widget.layoutPopout()
                            try ShellBundledWidgetTests.writeSnapshot(
                                widget.surface, name: "\(name)-\(profile)-popout-denied",
                                dark: false, directory: directory, background: background
                            )
                            if name == "control-center", tab == "overview" {
                                audioFixture(widget, access: .granted)
                                batteryFixture(widget, level: 80, power: ShellPower(source: "ac"))
                                widget.layoutPopout()
                                try ShellBundledWidgetTests.writeSnapshot(
                                    widget.surface, name: "\(name)-\(profile)-popout-ac",
                                    dark: false, directory: directory, background: background
                                )
                                batteryFixture(widget)
                            }
                            if name == "volume" {
                                audioFixture(widget, access: .granted)
                                for state in ["muted", "zero", "unavailable"] {
                                    widget.set("muted") { $0.bool(state == "muted") }
                                    widget.set("volume") {
                                        if state == "unavailable" { $0.null() }
                                        else { $0.number(state == "zero" ? 0 : 62) }
                                    }
                                    if state == "unavailable" {
                                        widget.set("outputs") { $0.null() }
                                        widget.set("audioApps") { $0.null() }
                                    }
                                    widget.layoutPopout()
                                    try ShellBundledWidgetTests.writeSnapshot(
                                        widget.surface, name: "volume-\(profile)-popout-\(state)",
                                        dark: false, directory: directory, background: background
                                    )
                                }
                            }
                        }
                    }
                    if name == "calendar" || (name == "clock" && shared)
                        || (name == "control-center" && tab == "calendar"), !vertical
                    {
                        widget.layoutPopout()
                        try ShellBundledWidgetTests.writeSnapshot(
                            widget.surface,
                            name: "\(name)-\(profile)-popout-\(dark ? "dark" : "light")",
                            dark: dark, directory: directory, background: background
                        )
                        if !dark {
                            for state in ["notDetermined", "denied", "nomonth", "loading"] {
                                if state == "loading" {
                                    widget.set("calendar") { $0.null() }
                                } else {
                                    calendarFixture(
                                        widget,
                                        access: state == "nomonth" ? "full" : state,
                                        month: state != "nomonth"
                                    )
                                }
                                widget.layoutPopout()
                                try ShellBundledWidgetTests.writeSnapshot(
                                    widget.surface, name: "\(name)-\(profile)-popout-\(state)",
                                    dark: false, directory: directory, background: background
                                )
                            }
                            calendarFixture(widget)
                        }
                    }
                    if ["wifi", "bluetooth"].contains(name), !vertical {
                        widget.layoutPopout()
                        try ShellBundledWidgetTests.writeSnapshot(
                            widget.surface,
                            name: "\(name)-\(profile)-popout-\(dark ? "dark" : "light")",
                            dark: dark, directory: directory, background: background
                        )
                        if !dark {
                            for state in radioStates(name).dropFirst() + ["unavailable"] {
                                radioFixture(widget, name: name, state: state)
                                widget.layoutPopout()
                                try ShellBundledWidgetTests.writeSnapshot(
                                    widget.surface, name: "\(name)-\(profile)-popout-\(state)",
                                    dark: false, directory: directory, background: background
                                )
                            }
                            if name == "wifi" { wifiFixture(widget) } else { bluetoothFixture(widget) }
                        }
                    }
                    if name == "battery-details", !vertical {
                        widget.layoutPopout()
                        try ShellBundledWidgetTests.writeSnapshot(
                            widget.surface,
                            name: "\(name)-\(profile)-popout-\(dark ? "dark" : "light")",
                            dark: dark, directory: directory, background: background
                        )
                        if !dark {
                            for state in ["charging", "low", "charged", "ac", "nopower", "unavailable"] {
                                switch state {
                                case "ac": batteryFixture(widget, level: 80, power: ShellPower(source: "ac"))
                                case "nopower":
                                    batteryFixture(widget)
                                    widget.set("power") { $0.null() }
                                case "charging": batteryFixture(
                                        widget,
                                        charging: true,
                                        power: ShellPower(source: "ac", full: 40)
                                    )
                                case "low":
                                    batteryFixture(
                                        widget,
                                        level: 12,
                                        power: ShellPower(source: "battery", remaining: 25, lowPower: true)
                                    )
                                case "unavailable": widget.set("battery") { $0.null() }
                                default: batteryFixture(
                                        widget,
                                        level: 100,
                                        power: ShellPower(source: "ac", charged: true)
                                    )
                                }
                                widget.layoutPopout()
                                try ShellBundledWidgetTests.writeSnapshot(
                                    widget.surface, name: "\(name)-\(profile)-popout-\(state)",
                                    dark: false, directory: directory, background: background
                                )
                            }
                            batteryFixture(widget)
                        }
                    }
                    if name == "weather" || (name == "control-center" && tab == "weather"), !vertical {
                        func writeScrolledWeatherSnapshot(_ suffix: String) throws {
                            guard name == "weather", shared, profile == "celestial" else { return }
                            let scroll = try XCTUnwrap(widget.surface.layout.core.elements { $0.scrolls }.first)
                            let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: scroll))
                            let point = CGPoint(x: frame.midX, y: frame.midY)
                            XCTAssertTrue(widget.surface.scroll(
                                at: point,
                                event: ShellEvent(button: .none),
                                content: CGPoint(x: 0, y: 10_000)
                            ))
                            try ShellBundledWidgetTests.writeSnapshot(
                                widget.surface,
                                name: "weather-celestial-popout-scrolled-\(suffix)",
                                dark: dark, directory: directory, background: background
                            )
                            XCTAssertTrue(widget.surface.scroll(
                                at: point,
                                event: ShellEvent(button: .none),
                                content: CGPoint(x: 0, y: -10_000)
                            ))
                        }
                        if name == "weather" {
                            widget.layoutPopout()
                            try ShellBundledWidgetTests.writeSnapshot(
                                widget.surface,
                                name: "\(name)-\(profile)-popout-\(dark ? "dark" : "light")",
                                dark: dark, directory: directory, background: background
                            )
                            try writeScrolledWeatherSnapshot(dark ? "dark" : "light")
                        }
                        if !dark {
                            for state in ["stale", "unavailable"] {
                                if state == "stale" {
                                    weatherFixture(widget, stale: true)
                                } else {
                                    widget.set("weather") { $0.null() }
                                }
                                widget.layoutPopout()
                                try ShellBundledWidgetTests.writeSnapshot(
                                    widget.surface, name: "\(name)-\(profile)-popout-\(state)",
                                    dark: false, directory: directory, background: background
                                )
                                if state == "stale" {
                                    try writeScrolledWeatherSnapshot(state)
                                }
                            }
                            weatherFixture(widget)
                        }
                    }
                    if name == "media", !vertical {
                        widget.layoutPopout()
                        try ShellBundledWidgetTests.writeSnapshot(
                            widget.surface,
                            name: "\(name)-\(profile)-popout-\(dark ? "dark" : "light")",
                            dark: dark, directory: directory, background: background
                        )
                        if !dark {
                            for state in ["paused", "loading", "nolyrics", "nothing"] {
                                switch state {
                                case "paused": mediaFixture(widget, playing: false)
                                case "loading": mediaFixture(widget, lyrics: .loading)
                                case "nolyrics": mediaFixture(widget, lyrics: .missing)
                                default:
                                    widget.set("media") { $0.null() }
                                    widget.set("lyrics") { $0.null() }
                                }
                                widget.layoutPopout()
                                try ShellBundledWidgetTests.writeSnapshot(
                                    widget.surface, name: "media-\(profile)-popout-\(state)",
                                    dark: false, directory: directory, background: background
                                )
                            }
                        }
                    }
                    try exportStatusVariants(
                        widget, name: name, profile: profile, bar: bar, vertical: vertical, dark: dark,
                        directory: directory, background: background
                    )
                    if name == "system-stats", !vertical {
                        systemStatsFixture(widget)
                        widget.layoutPopout()
                        try ShellBundledWidgetTests.writeSnapshot(
                            widget.surface,
                            name: "\(name)-\(profile)-popout-\(dark ? "dark" : "light")",
                            dark: dark, directory: directory, background: background
                        )
                    }
                    if name == "workspaces", ProcessInfo.processInfo.environment["OMNIWM_STEP_POPOUT"] == "1" {
                        let group = try XCTUnwrap(widget.tree()
                            .first { widget.text.string($0.content.target) == "window 1" })
                        widget.invoke(group.content.action)
                        widget.layoutPopout()
                        try ShellBundledWidgetTests.writeSnapshot(
                            widget.surface,
                            name: "\(name)-\(profile)-picker-\(vertical ? "vertical" : "horizontal")-\(dark ? "dark" : "light")",
                            dark: dark, directory: directory, background: background
                        )
                    }
                }
            }
        }
    }

    func testSharedInputSourceModelKeepsSelectionAndCommands() throws {
        let shell = try sharedLibraryShell("input-source")
        defer { try? FileManager.default.removeItem(at: shell) }
        let config = ShellConfig.resolve(shellDirectory: shell)
        let folder = shell.appendingPathComponent("default/widgets/input-model-probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        local library = require("../lib/input-source")
        function render(ctx)
            local state, m = library.state(ctx), library.model(ctx)
            if not m then return ui.text{ text = "nil" } end
            local rows = { ui.text{ text = state.id .. ":" .. state.name .. ":" .. state.short } }
            for _, entry in m.sources do
                rows[#rows + 1] = ui.text{ text = entry.id .. ":" .. entry.name .. ":" .. entry.short .. ":" .. tostring(entry.selected) }
                rows[#rows + 1] = ui.text{ text = entry.command }
            end
            rows[#rows + 1] = ui.text{ text = library.settings }
            return ui.column(rows)
        end
        """.write(to: folder.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        let widget = try makeWidget("input-model-probe", config: config, shell: shell)
        let entries = [
            ShellInputSourceEntry(id: "abc", name: "ABC", short: "EN"),
            ShellInputSourceEntry(id: "de", name: "German", short: "DE")
        ]
        for selected in entries {
            widget.set("inputSource") { ShellInputSource(current: selected, sources: entries).write(into: &$0) }
            widget.render(fixture(config, height: 32, vertical: false))
            let strings = widget.strings()
            XCTAssertEqual(strings.first, selected.id + ":" + selected.name + ":" + selected.short)
            for entry in entries {
                XCTAssertTrue(strings
                    .contains(entry.id + ":" + entry.name + ":" + entry.short + ":" + String(entry.id == selected.id)))
                XCTAssertTrue(strings.contains("input-source select " + entry.id))
                XCTAssertNotNil(ShellAction("input-source select " + entry.id))
            }
            XCTAssertTrue(strings.contains("input-source settings"))
            XCTAssertNotNil(ShellAction("input-source settings"))
        }
        widget.set("inputSource") { $0.null() }
        widget.render(fixture(config, height: 32, vertical: false))
        XCTAssertEqual(widget.strings(), ["nil"])
    }

    func testSharedWorldClockKeepsZonesRelativeDaysAndClamping() throws {
        let shell = try sharedLibraryShell("world-clock")
        defer { try? FileManager.default.removeItem(at: shell) }
        let config = ShellConfig.resolve(shellDirectory: shell)
        let folder = shell.appendingPathComponent("default/widgets/world-model-probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        local library = require("../lib/world-clock")
        function render(ctx)
            local state, m = library.state(ctx), library.model(ctx)
            local rows = { ui.text{ text = "model=" .. tostring(m ~= nil) } }
            if state then
                rows[#rows + 1] = ui.text{ text = "shown=" .. tostring(state.shown) }
                rows[#rows + 1] = ui.text{ text = "help=" .. state.help }
                for _, clock in state.clocks do
                    rows[#rows + 1] = ui.text{ text = "state=" .. clock.label .. ":" .. clock.short .. ":" .. clock.time .. ":" .. tostring(clock.daytime) }
                end
            end
            for _, clock in m and m.clocks or {} do
                rows[#rows + 1] = ui.text{ text = "model=" .. clock.label .. ":" .. clock.relative }
            end
            return ui.column(rows)
        end
        """.write(to: folder.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        let widget = try makeWidget("world-model-probe", config: config, shell: shell)
        useZeroLocalOffset(widget)
        let zones = [
            ("UTC", "GMT"),
            ("Honolulu", "Pacific/Honolulu"),
            ("Kathmandu", "Asia/Kathmandu"),
            ("Kiritimati", "Pacific/Kiritimati")
        ]
        let zoneValues = zones.map { ShellServiceValue.object(["label": .text($0.0), "zone": .text($0.1)]) }
        for (seconds, honoluluDay, kiritimatiDay) in [
            (1_735_689_600.0, "Yesterday", "Today"),
            (1_735_732_800.0, "Today", "Tomorrow")
        ] {
            widget.set("seconds") { $0.number(seconds) }
            for shown in [-4, 0, 1, 2, 64] {
                widget.set("settings") { ShellServiceValue.object([
                    "bar": .number(Double(shown)),
                    "zones": .array(zoneValues)
                ]).write(to: &$0) }
                widget.render(fixture(config, height: 32, vertical: false))
                let strings = widget.strings()
                XCTAssertTrue(strings.contains("shown=\(min(max(shown, 1), 4))"))
                for (label, zone) in zones {
                    let time = try XCTUnwrap(ShellFormatter.date(seconds, template: "jmm", zone: zone))
                    let offset = try XCTUnwrap(ShellFormatter.offset(seconds, zone: zone))
                    let hour = Int((Int64(seconds) + Int64(offset)) % 86400) / 3600
                    XCTAssertTrue(strings
                        .contains("state=\(label):\(label.prefix(3).uppercased()):\(time):\(hour >= 6 && hour < 19)"))
                }
                XCTAssertTrue(strings.contains("model=UTC:" + ShellLocalizer.string("Today", [])))
                XCTAssertTrue(strings.contains("model=Honolulu:" + ShellLocalizer.string(honoluluDay, []) + ", −10 h"))
                XCTAssertTrue(strings.contains("model=Kathmandu:" + ShellLocalizer.string("Today", []) + ", +5:45 h"))
                XCTAssertTrue(strings
                    .contains("model=Kiritimati:" + ShellLocalizer.string(kiritimatiDay, []) + ", +14 h"))
            }
        }
        for settings in [ShellServiceValue.object([:]), .object(["zones": .array([])])] {
            widget.set("settings") { settings.write(to: &$0) }
            widget.render(fixture(config, height: 32, vertical: false))
            XCTAssertEqual(
                widget.strings().filter { $0.hasPrefix("state=") }.map { $0.split(separator: ":")[0] },
                ["state=London", "state=Tokyo"]
            )
        }
        widget.set("settings") { ShellServiceValue.object(["zones": .array([.object([
            "label": .text("Bad"),
            "zone": .text("Not/AZone")
        ])])]).write(to: &$0) }
        widget.render(fixture(config, height: 32, vertical: false))
        XCTAssertEqual(widget.strings().filter { $0.hasPrefix("state=") }, [])
        widget.set("settings") { ShellServiceValue.object([:]).write(to: &$0) }
        useUnavailableLocalOffset(widget)
        widget.render(fixture(config, height: 32, vertical: false))
        XCTAssertTrue(widget.strings().contains("model=false"))
        XCTAssertEqual(widget.strings().filter { $0.hasPrefix("state=") }.count, 2)
    }

    func testSharedSmallStatsModelKeepsRowsAvailabilityAndGraphHistory() throws {
        let shell = try sharedLibraryShell("stats")
        defer { try? FileManager.default.removeItem(at: shell) }
        let config = ShellConfig.resolve(shellDirectory: shell)
        let folder = shell.appendingPathComponent("default/widgets/stats-model-probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        local library = require("../lib/stats")
        function render(ctx)
            local state, m = library.state(ctx), library.model(ctx)
            local rows = { ui.text{ text = "variant=" .. state.variant } }
            for _, entry in state.meters do
                rows[#rows + 1] = ui.text{ text = entry.key .. "=" .. tostring(entry.value) .. ":" .. tostring(entry.available) .. ":" .. tostring(entry.hot) .. ":" .. tostring(entry.history ~= nil) }
            end
            for _, entry in m.rows do
                rows[#rows + 1] = ui.text{ text = "row=" .. entry.key .. ":" .. entry.text .. ":" .. tostring(entry.history ~= nil) }
                rows[#rows + 1] = ui.text{ text = "row-hot=" .. entry.key .. ":" .. tostring(entry.hot) }
            end
            local values = ctx.state.history and ctx.state.history.cpu or {}
            rows[#rows + 1] = ui.text{ text = "history=" .. tostring(#values) .. ":" .. tostring(values[1]) .. ":" .. tostring(values[#values]) }
            return ui.column(rows)
        end
        """.write(to: folder.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        let widget = try makeWidget("stats-model-probe", config: config, shell: shell)
        widget.set("memory") { $0.number(64) }
        let bar = fixture(config, height: 32, vertical: false)
        for value in [nil, 0, 89, 90, 100] as [Double?] {
            widget.set("cpu") { if let value { $0.number(value) } else { $0.null() } }
            widget.render(bar)
            let strings = widget.strings()
            XCTAssertTrue(strings.contains("cpu=\(Int(value ?? 0)):\(value != nil):\((value ?? 0) >= 90):false"))
            XCTAssertTrue(strings.contains("row=cpu:" + (value.map { percent($0 / 100) } ?? "—") + ":false"))
            XCTAssertTrue(strings.contains("row-hot=cpu:\((value ?? 0) >= 90)"))
            XCTAssertTrue(strings.contains("history=0:nil:nil"))
        }
        for variant in ["gauge", "graph"] {
            widget.set("settings") { ShellServiceValue.object(["variant": .text(variant)]).write(to: &$0) }
            widget.set("gpu") { $0.number(0) }
            widget.set("disk") { $0.number(34) }
            networkFixture(widget)
            for value in 1 ... 35 {
                widget.set("cpu") { $0.number(Double(value)) }
                widget.render(bar)
            }
            let strings = widget.strings()
            XCTAssertEqual(
                strings.filter { $0.hasPrefix("row=") }.map { $0.split(separator: ":")[0] },
                ["row=cpu", "row=memory", "row=gpu", "row=disk", "row=down", "row=up"]
            )
            XCTAssertTrue(strings.contains("cpu=35:true:false:\(variant == "graph")"))
            XCTAssertTrue(strings.contains(variant == "graph" ? "history=30:6:35" : "history=0:nil:nil"))
        }
        for key in ["gpu", "disk", "network"] { widget.set(key) { $0.null() } }
        widget.set("settings") { ShellServiceValue.object(["variant": .text("meters")]).write(to: &$0) }
        widget.render(bar)
        XCTAssertEqual(widget.strings().filter { $0.hasPrefix("row=") }.count, 2)
        XCTAssertTrue(widget.strings().contains("history=30:6:35"))
        for (key, value) in [("cpu", 0.0), ("memory", 90), ("gpu", 100), ("disk", 89)] {
            widget.set(key) { $0.number(value) }
        }
        widget.render(bar)
        for row in ["cpu:false", "memory:true", "gpu:true", "disk:false"] {
            XCTAssertTrue(widget.strings().contains("row-hot=" + row))
        }
    }

    func testSharedStatusWidgetsKeepScaledHooksStatesHelpAndFreshActions() throws {
        let shell = try sharedLibraryShell("stats")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in try barHostingProfiles(in: shell) {
            _ = try ShellProfiles.select(profile, in: shell)
            let config = ShellConfig.resolve(shellDirectory: shell)
            for name in ["input-source", "launcher", "privacy", "world-clock", "stats"] {
                let widget = try makeWidget(
                    name,
                    config: config,
                    shell: shell,
                    source: shell.appendingPathComponent("default/widgets/\(name)/init.luau")
                )
                let variants = name == "stats" ? ["meters", "graph", "gauge"] : name == "launcher" ? [
                    "default",
                    "commands",
                    "windows",
                    "menu",
                    "clipboard",
                    "applications",
                    "files"
                ] : name == "privacy" ? ["dots", "icons"] : name == "world-clock" ? ["one", "two"] : ["default"]
                for height in Set([config.barOverride?.settings.height ?? 32, 32]).sorted() {
                    for vertical in [false, true] {
                        var firstTree: [String]?
                        var firstSize: CGSize?
                        for variant in variants {
                            let context = "\(profile)/\(name)/\(variant)/\(height)/\(vertical)"
                            statusFixture(widget, name: name)
                            let settings: ShellServiceValue = switch name {
                            case "stats": .object(["variant": .text(variant)])
                            case "launcher" where variant != "default": .object([
                                    "mode": .text(variant),
                                    "symbol": .text("macwindow")
                                ])
                            case "privacy": .object(["icons": .bool(variant == "icons")])
                            case "world-clock": .object(["bar": .number(variant == "two" ? 2 : 1)])
                            default: .object([:])
                            }
                            widget.set("settings") { settings.write(to: &$0) }
                            let bar = fixture(config, height: height, vertical: vertical)
                            if variant == "graph" {
                                feedStatsHistory(widget, bar: bar)
                            } else if name == "stats" {
                                widget.set("cpu") { $0.number(93) }
                            }
                            widget.render(bar)
                            let tree = widget.tree().map { node in
                                "\(node.kind) \(node.subtreeEnd) \(node.layout) \(node.paint)"
                                    + " text=\(widget.text.string(node.content.text)) style=\(node.content.style)"
                                    + " color=\(node.content.color) value=\(node.content.value)"
                            }
                            if let firstTree {
                                if vertical, name == "world-clock" || (name == "stats" && variant == "graph"
                                    && !["wayline", "nocturne", "celestial"].contains(profile))
                                {
                                    XCTAssertEqual(tree, firstTree, context)
                                } else {
                                    XCTAssertNotEqual(tree, firstTree, context)
                                }
                                if profile == "celestial", name == "launcher", let firstSize {
                                    XCTAssertEqual(widget.surface.size, firstSize, context)
                                }
                            } else {
                                firstTree = tree
                                firstSize = widget.surface.size
                            }
                            XCTAssertGreaterThan(widget.surface.size.width, 0, context)
                            XCTAssertGreaterThan(widget.surface.size.height, 0, context)
                            XCTAssertLessThanOrEqual(
                                vertical ? widget.surface.size.width : widget.surface.size.height,
                                height,
                                context
                            )
                            if name == "privacy" {
                                XCTAssertTrue(widget.tree().allSatisfy { $0.content.action == 0 }, context)
                            } else {
                                let action = try XCTUnwrap(
                                    widget.surface.layout.core.elements { $0.action != 0 }.first,
                                    context
                                )
                                let content = widget.surface.layout.core.content(of: action)
                                let expected: UInt32 = name == "launcher" ? content.action : OMNI_ACTION_POPOUT
                                let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: action))
                                if (profile == "nocturne" && ["input-source", "launcher"].contains(name))
                                    || (profile == "celestial" && name == "launcher" && variant != "default")
                                {
                                    let text = name == "input-source" ? "EN" : variant == "default" ?
                                        "magnifyingglass" : "macwindow"
                                    let glyph = try XCTUnwrap(widget.surface.layout.core.elements {
                                        widget.text.string($0.text) == text
                                    }.first, context)
                                    let glyphFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: glyph))
                                    XCTAssertEqual(glyphFrame.midX, frame.midX, accuracy: 0.01, context)
                                    XCTAssertEqual(glyphFrame.midY, frame.midY, accuracy: 0.01, context)
                                }
                                let point = CGPoint(x: frame.midX, y: frame.midY)
                                let count = widget.actions.count
                                widget.surface.press(at: point)
                                widget.surface.release(at: point)
                                XCTAssertEqual(widget.actions.count, count + 1, context)
                                XCTAssertEqual(widget.actions.last, expected, context)
                                if name == "launcher" {
                                    let command = variant == "default" ? "open-command-palette" :
                                        "open-command-palette " + variant
                                    XCTAssertEqual(widget.text.string(content.action), command, context)
                                    XCTAssertNotNil(ShellAction(command), context)
                                    if variant != "default" {
                                        XCTAssertTrue(widget.tree().contains {
                                            $0.kind == .symbol && widget.text.string($0.content.text) == "macwindow"
                                        }, context)
                                    }
                                }
                            }
                            if name == "world-clock" {
                                if vertical {
                                    let help = "London " + (ShellFormatter.date(
                                        1_791_924_120,
                                        template: "jmm",
                                        zone: "Europe/London"
                                    ) ?? "")
                                    XCTAssertTrue(
                                        widget.surface.layout.core.elements { widget.text.string($0.help) == help }
                                            .count > 0,
                                        context
                                    )
                                } else {
                                    XCTAssertTrue(widget.surface.layout.core.elements { $0.help != 0 }.isEmpty, context)
                                }
                            }
                            var stats = omni_render_stats()
                            var error = [CChar](repeating: 0, count: 256)
                            XCTAssertEqual(
                                omni_instance_render(
                                    widget.instance,
                                    OMNI_VIEW_BAR,
                                    100_000_000,
                                    &stats,
                                    &error,
                                    error.count
                                ),
                                OMNI_OK
                            )
                            let allowed: Set<ShellDataKey> = switch name {
                            case "input-source": [.inputSource]
                            case "privacy": [.privacy]
                            case "world-clock": [.seconds]
                            case "stats": [.cpu, .memory]
                            default: []
                            }
                            for key in [
                                ShellDataKey.cpu,
                                .memory,
                                .gpu,
                                .disk,
                                .network,
                                .inputSource,
                                .privacy,
                                .seconds
                            ] {
                                XCTAssertEqual(stats.deps & key.bit != 0, allowed.contains(key), context + key.rawValue)
                            }
                            if name == "world-clock", !vertical {
                                XCTAssertTrue(widget.strings().contains("LON"), context)
                                XCTAssertEqual(widget.strings().contains("TOK"), variant == "two", context)
                            }
                            let expectedHelp: String? = switch name {
                            case "input-source": "ABC"
                            case "launcher": ShellLocalizer.string("Toggle Command Palette", [])
                            case "privacy": ShellLocalizer.string("Microphone in use", []) + ", " + ShellLocalizer
                                .string(
                                    "Camera in use",
                                    []
                                )
                            case "stats" where profile == "celestial": ShellLocalizer.string("Performance", [])
                            default: nil
                            }
                            if let expectedHelp {
                                XCTAssertTrue(
                                    widget.surface.layout.core.elements { widget.text.string($0.help) == expectedHelp }
                                        .count > 0,
                                    context
                                )
                            }
                        }
                    }
                }
                if name == "privacy" {
                    for (microphone, camera, help) in [
                        (true, false, "Microphone in use"),
                        (false, true, "Camera in use")
                    ] {
                        for height in Set([config.barOverride?.settings.height ?? 32, 32]).sorted() {
                            for vertical in [false, true] {
                                for icons in [false, true] {
                                    let context = "\(profile)/privacy/\(height)/\(vertical)/\(icons)/\(help)"
                                    widget.set("settings") {
                                        ShellServiceValue.object(["icons": .bool(icons)]).write(to: &$0)
                                    }
                                    widget.set("privacy") {
                                        ShellPrivacy(microphone: microphone, camera: camera).write(into: &$0)
                                    }
                                    widget.render(fixture(config, height: height, vertical: vertical))
                                    XCTAssertGreaterThan(widget.surface.size.width, 0, context)
                                    XCTAssertTrue(widget.surface.layout.core.elements {
                                        widget.text.string($0.help) == ShellLocalizer.string(help, [])
                                    }.count > 0, context)
                                    if ["nocturne", "celestial"].contains(profile) {
                                        let expected = height * (profile == "celestial" ? 40.0 / 60 : 32.0 / 40)
                                        XCTAssertEqual(widget.surface.size.width, expected, accuracy: 0.01, context)
                                        XCTAssertEqual(widget.surface.size.height, expected, accuracy: 0.01, context)
                                    }
                                }
                            }
                        }
                    }
                }
                if name == "input-source", profile == "celestial" {
                    var bar = fixture(config, height: 32, vertical: false)
                    bar.style.textColor = "#123456"
                    widget.render(bar)
                    let label = try XCTUnwrap(widget.tree().first { $0.kind == .label })
                    XCTAssertEqual(label.content.color.role & 0xFF, UInt16(ShellRole.foreground.rawValue + 1))
                }
                if name == "stats", profile == "celestial" {
                    widget.set("settings") { ShellServiceValue.object([:]).write(to: &$0) }
                    widget.set("cpu") { $0.null() }
                    widget.render(fixture(config, height: 60, vertical: false))
                    XCTAssertTrue(widget.strings().contains("--"))
                    widget.set("cpu") { $0.number(0) }
                    widget.render(fixture(config, height: 60, vertical: false))
                    XCTAssertTrue(widget.strings().contains(percent(0)))
                    XCTAssertFalse(widget.strings().contains("--"))
                }
                if ["input-source", "privacy"].contains(name) {
                    widget.set(name == "privacy" ? "privacy" : "inputSource") { $0.null() }
                    widget.render(fixture(config, height: 32, vertical: false))
                    XCTAssertEqual(widget.surface.size, .zero, profile + name)
                }
            }
        }
    }

    func testSharedStatusPanelsKeepSelectionNilFeedbackAndSettingsActions() throws {
        let shell = try sharedLibraryShell("input-source")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            _ = try ShellProfiles.select(profile, in: shell)
            let config = ShellConfig.resolve(shellDirectory: shell)
            let widget = try makeWidget(
                "input-source",
                config: config,
                shell: shell,
                source: shell.appendingPathComponent("default/widgets/input-source/init.luau")
            )
            statusFixture(widget, name: "input-source")
            widget.render(fixture(config, height: 32, vertical: false))
            widget.layoutPopout()
            for text in ["ABC", "Pinyin – Simplified", "German"] { XCTAssertTrue(
                widget.strings(OMNI_VIEW_POPOUT).contains(text),
                profile + text
            ) }
            try clickCommand("input-source select com.apple.keylayout.German", widget: widget, context: profile)
            try clickCommand("input-source settings", widget: widget, context: profile)
            widget.set("inputSource") { $0.null() }
            widget.layoutPopout()
            XCTAssertGreaterThan(widget.surface.size.width, 0, profile)
            XCTAssertGreaterThan(widget.surface.size.height, 0, profile)
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])), profile)
            let clock = try makeWidget(
                "world-clock",
                config: config,
                shell: shell,
                source: shell.appendingPathComponent("default/widgets/world-clock/init.luau")
            )
            statusFixture(clock, name: "world-clock")
            clock.render(fixture(config, height: 32, vertical: false))
            clock.layoutPopout()
            XCTAssertTrue(clock.strings(OMNI_VIEW_POPOUT).contains("London"), profile)
            XCTAssertTrue(clock.strings(OMNI_VIEW_POPOUT).contains("Tokyo"), profile)
            useUnavailableLocalOffset(clock)
            clock.layoutPopout()
            XCTAssertGreaterThan(clock.surface.size.width, 0, profile)
            XCTAssertGreaterThan(clock.surface.size.height, 0, profile)
            XCTAssertTrue(clock.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])), profile)
            let small = try makeWidget(
                "stats",
                config: config,
                shell: shell,
                source: shell.appendingPathComponent("default/widgets/stats/init.luau")
            )
            statusFixture(small, name: "stats")
            small.render(fixture(config, height: 32, vertical: false))
            small.layoutPopout()
            for label in ["CPU", "Memory"] {
                XCTAssertTrue(
                    small.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(label, [])),
                    profile + label
                )
            }
            if ["default", "lake", "matrix", "sakura"].contains(profile) {
                small.set("settings") { ShellServiceValue.object(["variant": .text("graph")]).write(to: &$0) }
                feedStatsHistory(small, bar: fixture(config, height: 32, vertical: false))
                small.layoutPopout()
                let columns = try [0.93, 0.64, 0.12, 0.34].map { value in
                    let entry = try XCTUnwrap(small.surface.layout.core.elements {
                        small.text.string($0.text) == percent(value)
                    }.first, profile)
                    return CGRect(small.surface.layout.core.absoluteFrame(of: entry)).minX
                }
                for column in columns.dropFirst() {
                    XCTAssertEqual(column, columns[0], accuracy: 0.01, profile)
                }
            }
        }
    }

    func testCelestialKeyboardPaneKeepsSettingsWhenInputDataDisappears() throws {
        let shell = try sharedLibraryShell("input-source")
        defer { try? FileManager.default.removeItem(at: shell) }
        _ = try ShellProfiles.select("celestial", in: shell)
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget("status", config: config, shell: shell)
        statusFixture(widget, name: "input-source")
        widget.set("settings") { ShellServiceValue.object([
            "keyboard": .bool(true),
            "network": .bool(false),
            "bluetooth": .bool(false),
            "battery": .bool(false)
        ]).write(to: &$0) }
        widget.render(fixture(config, height: 60, vertical: false))
        let entry = try XCTUnwrap(widget.surface.layout.core.elements { widget.text.string($0.help) == "ABC" }.first)
        let content = widget.surface.layout.core.content(of: entry)
        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: entry))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let count = widget.actions.count
        widget.surface.press(at: point)
        widget.surface.release(at: point)
        XCTAssertEqual(widget.actions.count, count + 1)
        XCTAssertEqual(widget.invoke(content.action), [])
        widget.layoutPopout()
        try clickCommand("input-source select com.apple.keylayout.German", widget: widget, context: "keyboard full")
        widget.set("inputSource") { $0.null() }
        widget.layoutPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])))
        try clickCommand("input-source settings", widget: widget, context: "keyboard nil")
    }

    func testSharedWiFiModelKeepsSignalStatesDetailsAndActions() throws {
        let shell = try sharedLibraryShell("wifi")
        defer { try? FileManager.default.removeItem(at: shell) }
        let config = ShellConfig.resolve(shellDirectory: shell)
        let folder = shell.appendingPathComponent("default/widgets/wifi-model-probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        local wifi = require("../lib/wifi")
        function render(ctx)
            local m = wifi.model(ctx)
            if not m then return ui.text{ text = "nil" } end
            local rows = {}
            for _, key in {"power", "connected", "ssid", "rssi", "level", "help", "status", "name", "connectionStatus"} do
                rows[#rows + 1] = ui.text{ text = key .. "=" .. tostring(m[key]) }
            end
            for _, detail in m.details do
                rows[#rows + 1] = ui.text{ text = "detail=" .. detail.label .. ":" .. detail.value }
            end
            for _, entry in m.actions do
                rows[#rows + 1] = ui.text{ text = "action=" .. entry.command .. ":" .. tostring(entry.wrap) .. ":" .. tostring(entry.prompt) }
            end
            return ui.column(rows)
        end
        """.write(to: folder.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        let widget = try makeWidget("wifi-model-probe", config: config, shell: shell)
        let bar = fixture(config, height: 32, vertical: false)
        for (rssi, level, quality) in [
            (-81, 0, "Weak"),
            (-80, 1, "Fair"),
            (-71, 1, "Fair"),
            (-70, 2, "Good"),
            (-61, 2, "Good"),
            (-60, 3, "Excellent")
        ] {
            wifiFixture(
                widget,
                ShellWiFi(power: true, connected: true, ssid: "Harbour Home", rssi: rssi, location: "authorized")
            )
            widget.render(bar)
            let strings = widget.strings()
            XCTAssertTrue(strings.contains("level=\(level)"))
            XCTAssertTrue(strings.contains("help=Harbour Home"))
            XCTAssertTrue(strings
                .contains("detail=" + ShellLocalizer.string("Signal", []) + ":\(rssi) dBm · " + ShellLocalizer.string(
                    quality,
                    []
                )))
        }
        for connected in [false, true] {
            for power in [false, true] {
                for location in ["authorized", "notDetermined", "denied", "restricted"] {
                    wifiFixture(widget, ShellWiFi(power: power, connected: connected, location: location))
                    widget.render(bar)
                    let strings = widget.strings()
                    let help = !power ? "Wi-Fi: Off" : connected ? "Wi-Fi: Connected" : "Wi-Fi: Not Connected"
                    XCTAssertTrue(strings.contains("help=" + ShellLocalizer.string(help, [])))
                    XCTAssertTrue(strings.contains("name=" + ShellLocalizer.string("Network name hidden", [])))
                    XCTAssertTrue(strings.contains("level=\(connected ? 0 : -1)"))
                    XCTAssertTrue(strings.contains("status=" + ShellLocalizer.string(power ? "On" : "Off", [])))
                    XCTAssertEqual(strings.filter { $0.hasPrefix("detail=") }, [])
                    var expected = ["action=wifi settings:true:nil"]
                    if power, location != "authorized" { expected.insert("action=wifi authorize:true:true", at: 0) }
                    XCTAssertEqual(strings.filter { $0.hasPrefix("action=") }, expected)
                }
            }
        }
        for channel in [nil, 36] as [Int?] {
            wifiFixture(
                widget,
                ShellWiFi(
                    power: true,
                    connected: true,
                    band: "5 GHz",
                    channel: channel,
                    security: "WPA3 Personal",
                    location: "authorized"
                )
            )
            widget.render(bar)
            let strings = widget.strings()
            XCTAssertTrue(strings
                .contains("detail=" + ShellLocalizer.string("Band", []) + ":5 GHz" + (channel == nil ? "" : " · 36")))
            XCTAssertTrue(strings.contains("detail=" + ShellLocalizer.string("Security", []) + ":WPA3 Personal"))
        }
        networkFixture(widget)
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_instance_render(widget.instance, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count),
            OMNI_OK
        )
        XCTAssertEqual(stats.deps & ShellDataKey.network.bit, 0)
        widget.set("wifi") { $0.null() }
        widget.render(bar)
        XCTAssertEqual(widget.strings(), ["nil"])
    }

    func testSharedBluetoothModelKeepsDeviceKindsBatteriesAndAccessActions() throws {
        let shell = try sharedLibraryShell("bluetooth")
        defer { try? FileManager.default.removeItem(at: shell) }
        let config = ShellConfig.resolve(shellDirectory: shell)
        let folder = shell.appendingPathComponent("default/widgets/bluetooth-model-probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        local bluetooth = require("../lib/bluetooth")
        function render(ctx)
            local m = bluetooth.model(ctx)
            if not m then return ui.text{ text = "nil" } end
            local rows = {}
            for _, key in {"power", "granted", "connected", "help", "status"} do
                rows[#rows + 1] = ui.text{ text = key .. "=" .. tostring(m[key]) }
            end
            for _, entry in m.devices do
                rows[#rows + 1] = ui.text{ text = "device=" .. entry.id .. ":" .. entry.kind .. ":" .. entry.symbol }
                rows[#rows + 1] = ui.text{ text = "battery=" .. tostring(entry.battery) .. ":" .. tostring(entry.batteryText) .. ":" .. tostring(entry.lowBattery) }
            end
            for _, entry in m.actions do
                rows[#rows + 1] = ui.text{ text = "action=" .. entry.command .. ":" .. tostring(entry.wrap) .. ":" .. tostring(entry.prompt) }
            end
            rows[#rows + 1] = bluetooth.cell((ctx.data.settings or {}).level or 21)
            return ui.column(rows)
        end
        """.write(to: folder.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        let widget = try makeWidget("bluetooth-model-probe", config: config, shell: shell)
        let bar = fixture(config, height: 32, vertical: false)
        let kinds = ["headphones", "keyboard", "mouse", "gamepad", "phone", "computer", "unknown"]
        let symbols = [
            "headphones",
            "keyboard",
            "magicmouse",
            "gamecontroller",
            "iphone",
            "laptopcomputer",
            "dot.radiowaves.left.and.right"
        ]
        for (kind, symbol) in zip(kinds, symbols) {
            bluetoothFixture(
                widget,
                ShellBluetooth(
                    power: true,
                    access: "granted",
                    devices: [.init(id: "device", name: "Device", kind: kind, connected: true)]
                )
            )
            widget.render(bar)
            XCTAssertTrue(widget.strings().contains("device=device:\(kind):\(symbol)"))
            XCTAssertTrue(widget.strings().contains("battery=nil:nil:false"))
        }
        for level in [0, 20, 21, 100] {
            for connected in [false, true] {
                bluetoothFixture(
                    widget,
                    ShellBluetooth(
                        power: true,
                        access: "granted",
                        devices: [.init(
                            id: "device",
                            name: "Device",
                            kind: "headphones",
                            connected: connected,
                            battery: level
                        )]
                    )
                )
                widget.set("settings") { ShellServiceValue.object(["level": .number(Double(level))]).write(to: &$0) }
                widget.render(bar)
                let expected = connected ? "battery=\(level):\(percent(Double(level) / 100)):\(level <= 20)" : "battery=nil:nil:false"
                XCTAssertTrue(widget.strings().contains(expected))
                XCTAssertEqual(
                    widget.tree().filter { $0.paint.fill.role & 0xFF == UInt16(ShellRole.error.rawValue + 1) }.count,
                    level <= 20 ? 1 : 0
                )
            }
        }
        for power in [false, true] {
            for access in ["granted", "denied", "notDetermined", "restricted"] {
                bluetoothFixture(
                    widget,
                    ShellBluetooth(
                        power: power,
                        access: access,
                        devices: [
                            .init(id: "one", name: "One", kind: "keyboard", connected: true),
                            .init(id: "two", name: "Two", kind: "mouse", connected: false)
                        ]
                    )
                )
                widget.render(bar)
                let strings = widget.strings()
                XCTAssertTrue(strings.contains("connected=1"))
                let help = access != "granted" ? ShellLocalizer.string("Bluetooth", [])
                    : power ? ShellLocalizer.string("Bluetooth: %lld connected", [.number(1)])
                    : ShellLocalizer.string("Bluetooth: Off", [])
                XCTAssertTrue(strings.contains("help=" + help))
                XCTAssertEqual(strings.filter { $0.hasPrefix("device=") }.count, power ? 2 : 0)
                XCTAssertTrue(strings.contains("status=" + (access == "granted" ? ShellLocalizer.string(
                    power ? "On" : "Off",
                    []
                ) : "nil")))
                var expected = ["action=bluetooth settings:nil:nil"]
                if access != "granted" { expected.insert("action=bluetooth authorize:true:true", at: 0) }
                XCTAssertEqual(strings.filter { $0.hasPrefix("action=") }, expected)
            }
        }
        bluetoothFixture(widget, ShellBluetooth(power: true, access: "granted"))
        widget.render(bar)
        XCTAssertTrue(widget.strings().contains("connected=0"))
        XCTAssertEqual(widget.strings().filter { $0.hasPrefix("device=") }, [])
        widget.set("bluetooth") { $0.null() }
        widget.render(bar)
        XCTAssertEqual(widget.strings(), ["nil"])
    }

    func testSharedNetworkBarsKeepScaledHooksHelpFreshClicksAndDemand() throws {
        let shell = try sharedLibraryShell("wifi")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let base = config.barOverride?.settings.height ?? 32
            for name in ["wifi", "bluetooth"] {
                let widget = try makeWidget(
                    name,
                    config: config,
                    shell: shell,
                    source: shell.appendingPathComponent("default/widgets/\(name)/init.luau")
                )
                for height in Set([base, 32]).sorted() {
                    for vertical in [false, true] {
                        for backgrounds in [false, true] {
                            for state in radioStates(name) {
                                let context = "\(profile)/\(name)/\(state) \(height) vertical=\(vertical) backgrounds=\(backgrounds)"
                                radioFixture(widget, name: name, state: state)
                                var bar = fixture(config, height: height, vertical: vertical)
                                bar.style.backgrounds = backgrounds
                                widget.render(bar)
                                XCTAssertGreaterThan(widget.surface.size.width, 0, context)
                                XCTAssertGreaterThan(widget.surface.size.height, 0, context)
                                XCTAssertLessThanOrEqual(
                                    vertical ? widget.surface.size.width : widget.surface.size.height,
                                    height,
                                    context
                                )
                                if ["wayline", "nocturne"].contains(profile) {
                                    XCTAssertEqual(widget.surface.size.width, 32 * height / 40, accuracy: 0.01, context)
                                    XCTAssertEqual(
                                        widget.surface.size.height,
                                        32 * height / 40,
                                        accuracy: 0.01,
                                        context
                                    )
                                }
                                if profile == "celestial" {
                                    XCTAssertEqual(
                                        vertical ? widget.surface.size.width : widget.surface.size.height,
                                        40 * height / 60,
                                        accuracy: 0.01,
                                        context
                                    )
                                }
                                let button = try XCTUnwrap(
                                    widget.surface.layout.core.elements { $0.action == OMNI_ACTION_POPOUT }.first,
                                    context
                                )
                                let content = widget.surface.layout.core.content(of: button)
                                let help = radioHelp(name, state: state)
                                XCTAssertEqual(widget.text.string(content.help), help, context)
                                let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                                let point = CGPoint(x: frame.midX, y: frame.midY)
                                let count = widget.actions.count
                                widget.surface.press(at: point)
                                widget.surface.release(at: point)
                                XCTAssertEqual(widget.actions.count, count + 1, context)
                                XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT, context)
                                var stats = omni_render_stats()
                                var error = [CChar](repeating: 0, count: 256)
                                XCTAssertEqual(
                                    omni_instance_render(
                                        widget.instance,
                                        OMNI_VIEW_BAR,
                                        100_000_000,
                                        &stats,
                                        &error,
                                        error.count
                                    ),
                                    OMNI_OK,
                                    context
                                )
                                XCTAssertNotEqual(
                                    stats.deps & (name == "wifi" ? ShellDataKey.wifi.bit : ShellDataKey.bluetooth.bit),
                                    0,
                                    context
                                )
                                XCTAssertEqual(stats.deps & ShellDataKey.network.bit, 0, context)
                                XCTAssertEqual(stats.deps & ShellDataKey.seconds.bit, 0, context)
                                XCTAssertEqual(
                                    stats.deps & (name == "wifi" ? ShellDataKey.bluetooth.bit : ShellDataKey.wifi.bit),
                                    0,
                                    context
                                )
                            }
                        }
                    }
                }
                widget.set(name) { $0.null() }
                widget.render(fixture(config, height: base, vertical: false))
                XCTAssertEqual(widget.surface.size, .zero, profile + name)
                if name == "wifi" { wifiFixture(widget) } else { bluetoothFixture(widget) }
                XCTAssertTrue(
                    omni_instance_needs_render(
                        widget.instance,
                        OMNI_VIEW_BAR,
                        name == "wifi" ? ShellDataKey.wifi.bit : ShellDataKey.bluetooth.bit
                    ),
                    profile + name
                )
            }
        }
    }

    func testSharedNetworkPanelsKeepStateFeedbackAndDeliveredActions() throws {
        let shell = try sharedLibraryShell("wifi")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            for name in ["wifi", "bluetooth"] {
                let context = profile + "/" + name
                let widget = try makeWidget(
                    name,
                    config: config,
                    shell: shell,
                    source: shell.appendingPathComponent("default/widgets/\(name)/init.luau")
                )
                wifiFixture(widget)
                bluetoothFixture(widget)
                networkFixture(widget)
                widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
                widget.layoutPopout()
                let strings = widget.strings(OMNI_VIEW_POPOUT)
                if name == "wifi" {
                    for text in [
                        "Harbour Home",
                        ShellLocalizer.string("Signal", []),
                        ShellLocalizer.string("Band", []),
                        ShellLocalizer.string("Security", []),
                        "5 GHz · 36",
                        "WPA3 Personal"
                    ] {
                        XCTAssertTrue(strings.contains(text), context + " " + text)
                    }
                    if profile == "celestial" { XCTAssertTrue(
                        strings.contains(ShellLocalizer.string("Download", [])),
                        context
                    ) }
                    wifiFixture(widget, ShellWiFi(power: true, connected: true))
                } else {
                    for text in ["AirPods Pro", "Magic Keyboard", "Magic Mouse", percent(0.8), percent(0.15)] {
                        XCTAssertTrue(strings.contains(text), context + " " + text)
                    }
                    bluetoothFixture(widget, ShellBluetooth(power: true, access: "denied"))
                }
                widget.layoutPopout()
                try clickCommand(name + " settings", widget: widget, context: context)
                if name == "wifi" { XCTAssertTrue(
                    widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Network name hidden", [])),
                    context
                ) }
                try clickCommand(name + " authorize", widget: widget, context: context)
                for state in name == "wifi" ? ["off", "disconnected"] : ["off", "empty"] {
                    radioFixture(widget, name: name, state: state)
                    widget.layoutPopout()
                    let feedback = state == "off" ? "Off" : name == "wifi" ? "Not Connected" : "Devices"
                    if profile == "celestial", name == "bluetooth" {
                        XCTAssertTrue(
                            widget.strings(OMNI_VIEW_POPOUT).contains(radioHelp(name, state: state)),
                            context + state
                        )
                    } else {
                        XCTAssertTrue(
                            widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(feedback, [])),
                            context + state
                        )
                    }
                    try clickCommand(name + " settings", widget: widget, context: context + state)
                }
                widget.set(name) { $0.null() }
                widget.layoutPopout()
                XCTAssertGreaterThan(widget.surface.size.width, 0, context)
                XCTAssertGreaterThan(widget.surface.size.height, 0, context)
                XCTAssertTrue(
                    widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])),
                    context
                )
            }
        }
    }

    func testCelestialStatusNetworkPanelsUseTheSharedModels() throws {
        let shell = try sharedLibraryShell("wifi")
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        for part in ["network", "bluetooth"] {
            let widget = try makeWidget("status", config: config, shell: shell)
            widget.set("settings") {
                ShellServiceValue.object([
                    "network": .bool(part == "network"),
                    "bluetooth": .bool(part == "bluetooth"),
                    "battery": .bool(false)
                ]).write(to: &$0)
            }
            wifiFixture(widget)
            bluetoothFixture(widget)
            networkFixture(widget)
            widget.render(fixture(config, height: 60, vertical: false))
            let title = ShellLocalizer.string(part == "network" ? "Wi-Fi" : "Bluetooth", [])
            let entry = try XCTUnwrap(widget.surface.layout.core
                .elements { widget.text.string($0.help) == title && $0.action != 0 }.first)
            let content = widget.surface.layout.core.content(of: entry)
            let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: entry))
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let count = widget.actions.count
            widget.surface.press(at: point)
            widget.surface.release(at: point)
            XCTAssertEqual(widget.actions.count, count + 1, part)
            XCTAssertEqual(widget.actions.last, content.action, part)
            XCTAssertEqual(widget.invoke(content.action), [], part)
            widget.layoutPopout()
            let strings = widget.strings(OMNI_VIEW_POPOUT)
            XCTAssertTrue(strings.contains(part == "network" ? "Harbour Home" : "AirPods Pro"), part)
            if part == "network" { XCTAssertTrue(strings.contains(ShellLocalizer.string("Download", []))) }
            try clickCommand(part == "network" ? "wifi settings" : "bluetooth settings", widget: widget, context: part)
            if part == "network" {
                widget.set("wifi") { $0.null() }
                widget.layoutPopout()
                let missing = widget.strings(OMNI_VIEW_POPOUT)
                XCTAssertTrue(missing.contains(ShellLocalizer.string("Unavailable", [])))
                for (key, value) in [("Download", Int64(1_840_000)), ("Upload", Int64(312_000))] {
                    XCTAssertTrue(missing.contains(ShellLocalizer.string(key, [])))
                    XCTAssertTrue(missing
                        .contains(ByteCountFormatter.string(fromByteCount: value, countStyle: .file) + "/s"))
                }
                try clickCommand("wifi settings", widget: widget, context: "network unavailable")
                var stats = omni_render_stats()
                var error = [CChar](repeating: 0, count: 256)
                XCTAssertEqual(
                    omni_instance_render(widget.instance, OMNI_VIEW_POPOUT, 100_000_000, &stats, &error, error.count),
                    OMNI_OK
                )
                XCTAssertNotEqual(stats.deps & ShellDataKey.network.bit, 0)
            }
        }
    }

    func testSharedActionRowsKeepWrapping() throws {
        let shell = try sharedLibraryShell("wifi")
        defer { try? FileManager.default.removeItem(at: shell) }
        let folder = shell.appendingPathComponent("default/widgets/actions-probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        local actions = require("../lib/actions")
        function render(ctx)
            return ui.column{ actions.row("gearshape", "No wrap", "wifi settings", 240),
                actions.row("location.fill", "Wrap", "wifi authorize", 240, true) }
        end
        """.write(to: folder.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        let widget = try makeWidget("actions-probe", config: ShellConfig.resolve(shellDirectory: shell), shell: shell)
        widget.render(fixture(ShellConfig.resolve(shellDirectory: shell), height: 32, vertical: false))
        let labels = widget.tree().filter { $0.kind == .label }
        XCTAssertEqual(labels.map(\.content.maxWidth), [0, 200])
        XCTAssertEqual(labels.map(\.content.lines), [0, 2])
        try clickCommand("wifi authorize", widget: widget, context: "actions-probe")
    }

    func testSharedBatteryModelKeepsThresholdsPercentModesAndPowerStates() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let folder = shell.appendingPathComponent("default/widgets/battery-model-probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        local battery = require("../lib/battery")
        function render(ctx)
            local m = battery.model(ctx)
            if not m then return ui.text{ text = "nil" } end
            local rows = {}
            for _, key in {"level", "charging", "low", "tint", "symbol", "text", "percent", "reserve", "mode", "status", "settings"} do
                rows[#rows + 1] = ui.text{ text = key .. "=" .. tostring(m[key]) }
            end
            for _, detail in m.details do
                rows[#rows + 1] = ui.text{ text = detail.label .. "=" .. detail.value }
            end
            return ui.column(rows)
        end
        """.write(to: folder.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget("battery-model-probe", config: config, shell: shell)
        let bar = fixture(config, height: 32, vertical: false)
        let thresholds = [
            (0, "0", "error"),
            (10, "0", "error"),
            (11, "25", "warning"),
            (20, "25", "warning"),
            (21, "25", "foreground"),
            (35, "25", "foreground"),
            (36, "50", "foreground"),
            (60, "50", "foreground"),
            (61, "75", "foreground"),
            (85, "75", "foreground"),
            (86, "100", "foreground"),
            (100, "100", "foreground")
        ]
        for (level, symbol, tint) in thresholds {
            for charging in [false, true] {
                batteryFixture(widget, level: Double(level), charging: charging)
                widget.render(bar)
                let strings = widget.strings()
                XCTAssertTrue(strings.contains("level=\(level)"))
                XCTAssertTrue(strings.contains("text=\(level)"))
                XCTAssertTrue(strings.contains("charging=\(charging)"))
                XCTAssertTrue(strings.contains("low=\(level <= 20 && !charging)"))
                XCTAssertTrue(strings.contains("tint=\(charging ? "success" : tint)"))
                XCTAssertTrue(strings
                    .contains("symbol=\(charging ? "battery.100percent.bolt" : "battery.\(symbol)percent")"))
                XCTAssertTrue(strings.contains("percent=" + percent(Double(level) / 100)))
                XCTAssertTrue(strings.contains("reserve=" + percent(1)))
            }
        }
        for mode in ["beside", "inside", "off"] {
            widget.set("settings") { ShellServiceValue.object(["percent": .text(mode)]).write(to: &$0) }
            widget.render(bar)
            XCTAssertTrue(widget.strings().contains("mode=" + mode))
        }
        let states: [(ShellPower, Bool, String, String?, Double?)] = [
            (ShellPower(source: "battery", remaining: 254), false, "On battery", "Time Remaining", 254),
            (ShellPower(source: "ac"), false, "Not charging", nil, nil),
            (ShellPower(source: "ac", full: 40), true, "Charging", "Time to Full", 40),
            (ShellPower(source: "ac", charged: true), false, "Fully charged", nil, nil),
            (ShellPower(source: "battery", remaining: 0, lowPower: true), false, "On battery", "Time Remaining", 0)
        ]
        for (power, charging, status, timeKey, minutes) in states {
            batteryFixture(widget, charging: charging, power: power)
            widget.render(bar)
            let strings = widget.strings()
            XCTAssertTrue(strings.contains("status=" + ShellLocalizer.string(status, [])))
            XCTAssertTrue(strings.contains(ShellLocalizer.string("Power Source", []) + "=" + ShellLocalizer.string(
                power.source == "ac" ? "Power Adapter" : "Battery",
                []
            )))
            XCTAssertTrue(strings.contains(ShellLocalizer.string("Low Power Mode", []) + "=" + ShellLocalizer.string(
                power.lowPower ? "On" : "Off",
                []
            )))
            XCTAssertTrue(strings.contains("settings=battery settings"))
            if let timeKey, let minutes {
                let duration = ShellLocalizer.string(
                    "%lldh %lldm",
                    [.number(floor(minutes / 60)), .number(minutes.truncatingRemainder(dividingBy: 60))]
                )
                XCTAssertTrue(strings.contains(ShellLocalizer.string(timeKey, []) + "=" + duration))
            } else {
                XCTAssertFalse(strings
                    .contains {
                        $0.hasPrefix(ShellLocalizer.string("Time Remaining", []) + "=") || $0
                            .hasPrefix(ShellLocalizer.string(
                                "Time to Full",
                                []
                            ) + "=")
                    })
            }
        }
        widget.set("power") { $0.null() }
        widget.render(bar)
        XCTAssertTrue(widget.strings().contains("status=" + ShellLocalizer.string("On battery", [])))
        XCTAssertFalse(widget.strings().contains { $0.hasPrefix(ShellLocalizer.string("Low Power Mode", []) + "=") })
        widget.set("battery") { $0.null() }
        widget.render(bar)
        XCTAssertEqual(widget.strings(), ["nil"])
    }

    func testSharedBatteryBarsKeepModesScaledSkinsClicksAndDataDemand() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let hooked = ["wayline", "nocturne", "celestial"]
        for profile in try barHostingProfiles(in: shell) {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let base = config.barOverride?.settings.height ?? 32
            for name in ["battery", "battery-details"] {
                let widget = try makeWidget(
                    name,
                    config: config,
                    shell: shell,
                    source: shell.appendingPathComponent("default/widgets/\(name)/init.luau")
                )
                for height in Set([base, 32]).sorted() {
                    for vertical in [false, true] {
                        for mode in [nil, "beside", "inside", "off"] as [String?] {
                            let context = "\(profile)/\(name) h=\(height) vertical=\(vertical) \(mode ?? "default")"
                            widget.set("settings") {
                                ShellServiceValue.object(mode.map { ["percent": .text($0)] } ?? [:]).write(to: &$0)
                            }
                            batteryFixture(widget)
                            widget.render(fixture(config, height: height, vertical: vertical))
                            let tree = widget.tree()
                            let labels = tree.filter {
                                $0.kind == .label && ShellFontFamily(style: $0.content.style) != .symbols
                            }.map { widget.text.string($0.content.text) }
                            let effectiveMode = mode ?? "beside"
                            let showsText = name == "battery" || effectiveMode != "off" ||
                                (vertical && !hooked.contains(profile))
                            let expected = vertical || (name == "battery-details" && effectiveMode == "inside")
                                ? "76" : percent(0.76)
                            XCTAssertEqual(labels, showsText ? [expected] : [], context)
                            if profile == "nocturne", name == "battery-details", vertical, effectiveMode != "beside" {
                                let root = try XCTUnwrap(tree.first, context)
                                XCTAssertEqual(
                                    widget.surface.size.width,
                                    widget.surface.size.height,
                                    accuracy: 0.01,
                                    context
                                )
                                XCTAssertLessThanOrEqual(
                                    CGFloat(root.paint.cornerRadius),
                                    widget.surface.size.height / 2,
                                    context
                                )
                            }
                            if profile == "wayline", name == "battery-details", effectiveMode == "inside" {
                                let label = try XCTUnwrap(tree.first { $0.kind == .label }, context)
                                XCTAssertEqual(
                                    label.content.color.role & 0xFF,
                                    UInt16(ShellRole.accentForeground.rawValue + 1),
                                    context
                                )
                            }
                            XCTAssertGreaterThan(widget.surface.size.width, 0, context)
                            XCTAssertGreaterThan(widget.surface.size.height, 0, context)
                            XCTAssertLessThanOrEqual(
                                vertical ? widget.surface.size.width : widget.surface.size.height,
                                height,
                                context
                            )
                            if name == "battery-details" {
                                let button = try XCTUnwrap(
                                    widget.surface.layout.core.elements { $0.action == OMNI_ACTION_POPOUT }.first,
                                    context
                                )
                                let content = widget.surface.layout.core.content(of: button)
                                XCTAssertEqual(
                                    widget.text.string(content.help),
                                    percent(0.76),
                                    context
                                )
                                let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                                let point = CGPoint(x: frame.midX, y: frame.midY)
                                let count = widget.actions.count
                                widget.surface.press(at: point)
                                widget.surface.release(at: point)
                                XCTAssertEqual(widget.actions.count, count + 1, context)
                                XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT, context)
                            } else {
                                XCTAssertTrue(tree.allSatisfy { $0.content.action == 0 }, context)
                            }
                            var stats = omni_render_stats()
                            var error = [CChar](repeating: 0, count: 256)
                            XCTAssertEqual(
                                omni_instance_render(
                                    widget.instance,
                                    OMNI_VIEW_BAR,
                                    100_000_000,
                                    &stats,
                                    &error,
                                    error.count
                                ),
                                OMNI_OK,
                                context
                            )
                            XCTAssertNotEqual(stats.deps & ShellDataKey.battery.bit, 0, context)
                            XCTAssertEqual(stats.deps & ShellDataKey.power.bit, 0, context)
                            XCTAssertEqual(stats.deps & ShellDataKey.seconds.bit, 0, context)
                            if hooked.contains(profile), !vertical {
                                let design: Double = profile == "celestial" ? 60 : 40
                                let expected = (profile == "celestial" ? 40 : 32) * height / design
                                XCTAssertEqual(widget.surface.size.height, expected, accuracy: 0.01, context)
                            }
                        }
                    }
                }
                widget.set("battery") { $0.null() }
                widget.render(fixture(config, height: base, vertical: false))
                XCTAssertEqual(widget.surface.size, .zero, profile + name)
                batteryFixture(widget)
                XCTAssertTrue(
                    omni_instance_needs_render(widget.instance, OMNI_VIEW_BAR, ShellDataKey.battery.bit),
                    profile + name
                )
            }
        }
    }

    func testSharedBatteryPanelsKeepPowerFeedbackSettingsAndMissingData() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let duration = ShellLocalizer.string("%lldh %lldm", [.number(4), .number(14)])
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let widget = try makeWidget(
                "battery-details",
                config: config,
                shell: shell,
                source: shell
                    .appendingPathComponent("default/widgets/battery-details/init.luau")
            )
            batteryFixture(widget)
            widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
            widget.layoutPopout()
            let strings = widget.strings(OMNI_VIEW_POPOUT)
            for text in [
                percent(0.76),
                ShellLocalizer.string("Battery", []),
                ShellLocalizer.string("On battery", []),
                ShellLocalizer.string("Power Source", []),
                ShellLocalizer.string("Time Remaining", []),
                duration,
                ShellLocalizer.string("Low Power Mode", []),
                ShellLocalizer.string("Off", [])
            ] {
                XCTAssertTrue(strings.contains(text), profile + " " + text)
            }
            if profile == "wayline" {
                XCTAssertEqual(widget.renderPopout().filter {
                    $0.paint.cornerRadius == 9 && $0.paint.fill
                        .role & 0xFF == UInt16(ShellRole.elevatedSurface.rawValue + 1)
                }.count, 2)
            }
            try clickCommand("battery settings", widget: widget, context: profile)
            batteryFixture(widget, level: 80, power: ShellPower(source: "ac"))
            widget.layoutPopout()
            let ac = widget.strings(OMNI_VIEW_POPOUT)
            XCTAssertTrue(ac.contains(percent(0.8)), profile)
            XCTAssertTrue(ac.contains(ShellLocalizer.string("Not charging", [])), profile)
            XCTAssertTrue(ac.contains(ShellLocalizer.string("Power Adapter", [])), profile)
            XCTAssertEqual(
                ac.filter { $0 == ShellLocalizer.string("Battery", []) }.count,
                profile == "celestial" ? 0 : 1,
                profile
            )
            if profile == "celestial" {
                let source = try XCTUnwrap(widget.surface.layout.core.elements {
                    widget.text.string($0.text) == ShellLocalizer.string("Power Source", [])
                }.first)
                let adapter = try XCTUnwrap(widget.surface.layout.core.elements {
                    widget.text.string($0.text) == ShellLocalizer.string("Power Adapter", [])
                }.first)
                let sourceFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: source))
                let adapterFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: adapter))
                XCTAssertLessThanOrEqual(sourceFrame.maxX + 8, adapterFrame.minX)
                let bounds = CGRect(origin: .zero, size: widget.surface.size)
                XCTAssertTrue(bounds.contains(sourceFrame))
                XCTAssertTrue(bounds.contains(adapterFrame))
            }
            widget.set("battery") { $0.null() }
            widget.layoutPopout()
            XCTAssertGreaterThan(widget.surface.size.width, 0, profile)
            XCTAssertGreaterThan(widget.surface.size.height, 0, profile)
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])), profile)
            batteryFixture(widget, charging: true, power: ShellPower(source: "ac", full: 40, lowPower: true))
            widget.layoutPopout()
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Charging", [])), profile)
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Time to Full", [])), profile)
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("On", [])), profile)
            widget.set("power") { $0.null() }
            widget.layoutPopout()
            if profile == "wayline" {
                XCTAssertEqual(widget.renderPopout().filter {
                    $0.paint.cornerRadius == 9 && $0.paint.fill
                        .role & 0xFF == UInt16(ShellRole.elevatedSurface.rawValue + 1)
                }.count, 1)
            }
        }
    }

    func testCelestialStatusBatteryUsesTheSharedPowerModel() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget("status", config: config, shell: shell)
        widget.set("settings") {
            ShellServiceValue.object(["battery": .bool(true), "network": .bool(false), "bluetooth": .bool(false)])
                .write(to: &$0)
        }
        batteryFixture(widget, level: 80, power: ShellPower(source: "ac"))
        widget.render(fixture(config, height: 60, vertical: false))
        let entry = try XCTUnwrap(widget.surface.layout.core.elements {
            widget.text.string($0.help) == ShellLocalizer.string("Battery", []) && $0.action != 0
        }.first)
        let content = widget.surface.layout.core.content(of: entry)
        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: entry))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let count = widget.actions.count
        widget.surface.press(at: point)
        widget.surface.release(at: point)
        XCTAssertEqual(widget.actions.count, count + 1)
        XCTAssertEqual(widget.actions.last, content.action)
        XCTAssertEqual(widget.invoke(content.action), [])
        widget.layoutPopout()
        let strings = widget.strings(OMNI_VIEW_POPOUT)
        XCTAssertTrue(strings.contains(percent(0.8)))
        for key in ["Not charging", "Power Adapter", "Low Power Mode", "Off"] {
            XCTAssertTrue(strings.contains(ShellLocalizer.string(key, [])), key)
        }
        try clickCommand("battery settings", widget: widget, context: "celestial/status")
        widget.set("battery") { $0.null() }
        widget.layoutPopout()
        XCTAssertGreaterThan(widget.surface.size.width, 0)
        XCTAssertGreaterThan(widget.surface.size.height, 0)
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])))
    }

    func testSharedPanelsKeepDefaultCapsulesInEveryBackgroundSetting() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let config = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(config.profile, "default")
        let folder = shell.appendingPathComponent("default/widgets/panel-probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        local look = require("../lib/look")
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return look.panel(ctx, { w = 220, ui.text{ text = "Probe" } })
        end
        """.write(to: folder.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        let widget = try makeWidget("panel-probe", config: config, shell: shell)
        for transparent in [false, true] {
            for backgrounds in [false, true] {
                var bar = fixture(config, height: 32, vertical: false)
                bar.style.transparent = transparent
                bar.style.backgrounds = backgrounds
                widget.render(bar)
                let root = try XCTUnwrap(widget.renderPopout().first)
                let capsule = transparent && backgrounds
                XCTAssertEqual(root.paint.material, UInt8(capsule ? OMNI_MATERIAL_CLEAR : OMNI_MATERIAL_GLASS))
                XCTAssertEqual(root.paint.cornerRadius, capsule ? 14 : 20)
                if capsule {
                    XCTAssertEqual(root.paint.fill.role & 0xFF, UInt16(ShellRole.background.rawValue + 1))
                    XCTAssertEqual(root.paint.stroke.role & 0xFF, UInt16(ShellRole.border.rawValue + 1))
                    XCTAssertEqual(root.paint.strokeWidth, 1)
                }
            }
        }
    }

    func testSharedActiveWindowHonoursDisplayModesPresetsAndDeliveredClicks() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in try barHostingProfiles(in: shell) {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let height = config.barOverride?.settings.height ?? 32
            let presetWidth: Float = ["matrix": 160, "sakura": 160, "celestial": 320][profile] ?? 260
            let widget = try makeWidget(
                "active-window", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/active-window/init.luau")
            )
            widget.set("app") { $0.string("Safari") }
            widget.set("bundle") { $0.string("com.apple.Safari") }
            for mode in ["preset", "icon_and_text", "icon_only", "text_only"] {
                if mode != "preset" {
                    widget.set("settings") {
                        ShellServiceValue.object(["display": .text(mode), "maxWidth": .number(72)]).write(to: &$0)
                    }
                }
                let display = mode == "preset"
                    ? (["matrix", "sakura"].contains(profile) ? "text_only" : "icon_and_text") : mode
                let maximum = mode == "preset" ? presetWidth : 72
                for vertical in [false, true] {
                    for backgrounds in [false, true] {
                        let context = "\(profile) \(mode) vertical=\(vertical) backgrounds=\(backgrounds)"
                        var bar = fixture(config, height: height, vertical: vertical)
                        bar.style.backgrounds = backgrounds
                        widget.set("title") { $0.string("A quiet afternoon") }
                        widget.render(bar)
                        let tree = widget.tree()
                        let showsText = display != "icon_only" && (!vertical || profile == "celestial")
                        let showsIcon = display != "text_only" || (vertical && profile != "celestial")
                        let icons = tree
                            .filter { $0.kind == .image && widget.text.string($0.content.text) == "com.apple.Safari" }
                        let labels = tree.filter { $0.kind == .label }
                        XCTAssertEqual(icons.count, showsIcon ? 1 : 0, context)
                        XCTAssertEqual(labels.count, showsText ? 1 : 0, context)
                        if let label = labels.first {
                            XCTAssertEqual(
                                widget.text.string(label.content.text),
                                profile == "matrix" ? "~/Safari" : "A quiet afternoon", context
                            )
                            XCTAssertEqual(label.content.maxWidth, maximum, context)
                            XCTAssertEqual(label.paint.rotate, vertical ? 90 : 0, context)
                        }
                        XCTAssertLessThanOrEqual(
                            vertical ? widget.surface.size.width : widget.surface.size.height,
                            height,
                            context
                        )
                        let button = try XCTUnwrap(tree.first, context)
                        XCTAssertEqual(widget.text.string(button.content.help), "Safari — A quiet afternoon", context)
                        try clickCommand("open-command-palette windows", widget: widget, context: context)
                    }
                }
            }
            widget.set("settings") { ShellServiceValue.object(["display": .text("icon_and_text")]).write(to: &$0) }
            widget.set("title") { $0.string("") }
            widget.render(fixture(config, height: height, vertical: false))
            XCTAssertEqual(widget.text.string(try XCTUnwrap(widget.tree().first).content.help), "Safari", profile)
            XCTAssertTrue(widget.strings().contains(profile == "matrix" ? "~/Safari" : "Safari"), profile)
            widget.set("app") { $0.string("") }
            widget.render(fixture(config, height: height, vertical: false))
            XCTAssertEqual(widget.surface.size, .zero, profile)
            XCTAssertTrue(widget.tree().allSatisfy { $0.content.action == 0 }, profile)
        }
    }

    func testSharedActiveWindowKeepsEachCustomSkinAndTextOverride() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ["matrix", "celestial", "wayline", "nocturne"] {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let base = config.barOverride?.settings.height ?? 32
            let widget = try makeWidget(
                "active-window", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/active-window/init.luau")
            )
            widget.set("app") { $0.string("Safari") }
            widget.set("bundle") { $0.string("com.apple.Safari") }
            widget.set("title") { $0.string("A quiet afternoon") }
            for height in [base, 32] {
                let scale = height / (profile == "celestial" ? 60 : 40)
                for vertical in [false, true] {
                    let context = "\(profile) height=\(height) vertical=\(vertical)"
                    var bar = fixture(config, height: height, vertical: vertical)
                    bar.style.backgrounds = true
                    widget.render(bar)
                    let root = try XCTUnwrap(widget.tree().first, context)
                    let labels = widget.tree().filter { $0.kind == .label }
                    let icons = widget.tree().filter { $0.kind == .image }
                    XCTAssertEqual(icons.count, profile == "matrix" && !vertical ? 0 : 1, context)
                    XCTAssertEqual(labels.count, !vertical || profile == "celestial" ? 1 : 0, context)
                    let cross = vertical ? widget.surface.size.width : widget.surface.size.height
                    XCTAssertLessThanOrEqual(cross, height, context)
                    for icon in icons {
                        let designSize: Double = profile == "matrix" ? 18 : profile == "nocturne" ? 20 : 24
                        XCTAssertEqual(Double(icon.layout.width), designSize * scale, accuracy: 0.01, context)
                        XCTAssertEqual(Double(icon.layout.height), designSize * scale, accuracy: 0.01, context)
                    }
                    for label in labels {
                        let role: ShellRole = profile == "matrix" ? .secondaryForeground : profile == "celestial" ?
                            .accent : .foreground
                        let designSize: Double = profile == "matrix" ? 11 : profile == "celestial" ? 16 : 14
                        XCTAssertEqual(label.content.color.role & 0xFF, UInt16(role.rawValue + 1), context)
                        XCTAssertEqual(
                            CTFontGetSize(ShellTextStyle.font(for: label.content.style)),
                            designSize * scale,
                            accuracy: 0.01,
                            context
                        )
                    }
                    if profile == "matrix" {
                        XCTAssertEqual(cross, height - 4, accuracy: 0.01, context)
                    } else if profile == "wayline" {
                        XCTAssertEqual(cross, 32 * scale, accuracy: 0.01, context)
                        XCTAssertEqual(root.paint.cornerRadius, Float(floor(32 * scale * 0.24)), context)
                        XCTAssertEqual(
                            root.paint.fill.role & 0xFF,
                            UInt16(ShellRole.elevatedSurface.rawValue + 1),
                            context
                        )
                        XCTAssertEqual(root.content.hoverOpacity, 0.9, context)
                        if !vertical {
                            let label = try XCTUnwrap(widget.surface.layout.core.elements {
                                widget.text.string($0.text) == "A quiet afternoon"
                            }.first, context)
                            let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: label))
                            XCTAssertEqual(widget.surface.size.width - frame.maxX, 9 * scale, accuracy: 0.01, context)
                        }
                    } else if profile == "nocturne" {
                        XCTAssertEqual(cross, 32 * scale, accuracy: 0.01, context)
                        XCTAssertEqual(Double(root.paint.cornerRadius), 16 * scale - 1, accuracy: 0.01, context)
                        XCTAssertEqual(root.paint.fill.role & 0xFF, UInt16(ShellRole.surface.rawValue + 1), context)
                        XCTAssertEqual(root.paint.strokeWidth, 1, context)
                        XCTAssertTrue(root.content.hover.isVisible, context)
                    } else {
                        XCTAssertEqual(cross, (vertical ? 40 : 32) * scale, accuracy: 0.01, context)
                        XCTAssertEqual(Double(root.paint.cornerRadius), 16 * scale, accuracy: 0.01, context)
                        bar.style.textColor = "#123456"
                        widget.render(bar)
                        let overridden = try XCTUnwrap(widget.tree().first { $0.kind == .label }, context)
                        XCTAssertEqual(
                            overridden.content.color.role & 0xFF,
                            UInt16(ShellRole.foreground.rawValue + 1),
                            context
                        )
                    }
                    try clickCommand("open-command-palette windows", widget: widget, context: context)
                    if ["wayline", "nocturne"].contains(profile) {
                        bar.style.backgrounds = false
                        widget.render(bar)
                        let unfilled = try XCTUnwrap(widget.tree().first, context)
                        XCTAssertFalse(unfilled.paint.fill.isVisible, context)
                        XCTAssertFalse(unfilled.paint.stroke.isVisible, context)
                    }
                }
            }
        }
    }

    func testSharedBarCapsulesKeepTheirPaintAndContentInsideTheButton() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ["default", "lake"] {
            _ = try ShellProfiles.select(profile, in: shell)
            let config = ShellConfig.resolve(shellDirectory: shell)
            for name in [
                "active-window",
                "volume",
                "clock",
                "weather",
                "omniwm",
                "calendar",
                "system-stats",
                "battery",
                "battery-details",
                "wifi",
                "bluetooth",
                "input-source",
                "launcher",
                "privacy",
                "world-clock",
                "stats"
            ] {
                let widget = try makeWidget(name, config: config, shell: shell)
                widget.set("app") { $0.string("Safari") }
                widget.set("bundle") { $0.string("com.apple.Safari") }
                widget.set("title") { $0.string("A quiet afternoon") }
                widget.set("volume") { $0.number(62) }
                widget.set("muted") { $0.bool(false) }
                calendarFixture(widget)
                weatherFixture(widget)
                batteryFixture(widget)
                wifiFixture(widget)
                bluetoothFixture(widget)
                statusFixture(widget, name: name)
                for state in ["volume", "calendar"].contains(name) ? ["full", "empty"] : ["full"] {
                    if state == "empty" {
                        if name == "volume" { widget.set("volume") { $0.null() } }
                        else { widget.set("calendar") { ShellCalendar(access: "full", events: []).write(into: &$0) } }
                    }
                    for height in [24.0, 28, 32, 40] {
                        for vertical in [false, true] {
                            let context = "\(profile)/\(name) \(state) height=\(height) vertical=\(vertical)"
                            var bar = fixture(config, height: height, vertical: vertical)
                            bar.style.transparent = true
                            bar.style.backgrounds = true
                            widget.render(bar)
                            let root = try XCTUnwrap(widget.tree().first, context)
                            let cross = vertical ? widget.surface.size.width : widget.surface.size.height
                            let main = vertical ? widget.surface.size.height : widget.surface.size.width
                            XCTAssertGreaterThanOrEqual(main, cross, context)
                            if name == "omniwm" {
                                XCTAssertEqual(
                                    widget.surface.size.width,
                                    widget.surface.size.height,
                                    accuracy: 0.01,
                                    context
                                )
                            }
                            XCTAssertEqual(CGFloat(root.paint.cornerRadius), cross / 2, accuracy: 0.01, context)
                            XCTAssertEqual(root.paint.fill.role & 0xFF, UInt16(ShellRole.surface.rawValue + 1), context)
                            XCTAssertEqual(
                                root.paint.stroke.role & 0xFF,
                                UInt16(ShellRole.border.rawValue + 1),
                                context
                            )
                            XCTAssertEqual(root.paint.strokeWidth, 0.5, context)
                            let bounds = CGRect(origin: .zero, size: widget.surface.size).insetBy(dx: -0.01, dy: -0.01)
                            for element in widget.surface.layout.core.elements(matching: { _ in true }) {
                                let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: element))
                                XCTAssertTrue(bounds.contains(frame), context + " \(frame) outside \(bounds)")
                                if name == "omniwm",
                                   widget.text.string(widget.surface.layout.core.content(of: element).text) == "omniwm"
                                {
                                    XCTAssertEqual(frame.midX, bounds.midX, accuracy: 0.01, context)
                                    XCTAssertEqual(frame.midY, bounds.midY, accuracy: 0.01, context)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testSharedLibrarySelectionSkipsInvalidNamesAndRejectsUnknownLibraries() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ["default", "first", "second"] {
            let library = shell.appendingPathComponent("\(profile)/lib")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try Data("return \"\(profile)\"".utf8).write(to: library.appendingPathComponent("audio.luau"))
        }
        let privateAudio = ["first", "second"].map { shell.appendingPathComponent("\($0)/lib/audio.luau") }
        let before = try privateAudio.map { try Data(contentsOf: $0) }
        try useSharedLibraries(
            ",.,../audio,audio/child,audio..,nested\\audio,", in: shell
        )
        XCTAssertEqual(try privateAudio.map { try Data(contentsOf: $0) }, before)
        XCTAssertThrowsError(try useSharedLibraries("audio-typo", in: shell)) { error in
            XCTAssertEqual((error as NSError).code, CocoaError.fileNoSuchFile.rawValue)
        }
        XCTAssertEqual(try privateAudio.map { try Data(contentsOf: $0) }, before)
        let shared = shell.appendingPathComponent("default/lib/audio.luau")
        let sharedBefore = try Data(contentsOf: shared)
        try useSharedLibraries("audio", in: shell)
        XCTAssertTrue(privateAudio.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try Data(contentsOf: shared), sharedBefore)
    }

    func testSharedWeatherModelLimitsForecastsAndNormalizesRangesAndUnits() throws {
        let shell = try sharedLibraryShell("weather")
        defer { try? FileManager.default.removeItem(at: shell) }
        let folder = shell.appendingPathComponent("default/widgets/weather-model-probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        local weather = require("../lib/weather")
        function render(ctx)
            local m = weather.model(ctx, (ctx.data.settings or {}).compact)
            local rows = {
                ui.text{ text = "hours:" .. #m.hours },
                ui.text{ text = "days:" .. #m.days },
                ui.text{ text = "limit:" .. m.forecastHours },
                ui.text{ text = "wind:" .. m.windValue },
                ui.text{ text = "temperature:" .. m.temperature },
                ui.text{ text = "stale:" .. tostring(m.stale) },
                ui.text{ text = "condition:" .. m.condition } }
            for index, day in m.days do
                rows[#rows + 1] = ui.text{ text = string.format("range%d:%.4f:%.4f", index, day.from, day.to) }
            end
            return ui.column(rows)
        end
        """.write(to: folder.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget("weather-model-probe", config: config, shell: shell)
        weatherFixture(widget)
        let bar = fixture(config, height: 32, vertical: false)
        widget.set("settings") { ShellServiceValue.object([:]).write(to: &$0) }
        widget.render(bar)
        XCTAssertTrue(widget.strings().contains("hours:12"))
        XCTAssertTrue(widget.strings().contains("days:7"))
        XCTAssertTrue(widget.strings().contains("limit:12"))
        XCTAssertTrue(widget.strings().contains("stale:nil"))
        XCTAssertTrue(widget.strings().contains("range1:0.2500:0.8750"))
        XCTAssertTrue(widget.strings().contains("range3:0.3750:1.0000"))
        XCTAssertTrue(widget.strings().contains("range5:0.0000:0.5000"))
        XCTAssertTrue(widget.strings().contains("condition:" + ShellLocalizer.string("Partly cloudy", [])))
        for hours in 4 ... 12 {
            widget.set("settings") {
                ShellServiceValue.object(["forecastHours": .number(Double(hours))]).write(to: &$0)
            }
            widget.render(bar)
            XCTAssertTrue(widget.strings().contains("hours:\(hours)"))
            XCTAssertTrue(widget.strings().contains("limit:\(hours)"))
        }
        widget.set("settings") {
            ShellServiceValue.object(["compact": .bool(true), "forecastHours": .number(12)]).write(to: &$0)
        }
        widget.render(bar)
        XCTAssertTrue(widget.strings().contains("hours:8"))
        XCTAssertTrue(widget.strings().contains("days:5"))
        let number = { ShellFormatter.string(kind: OMNI_FORMAT_NUMBER, $0, digits: 0) }
        for (unit, windUnit) in [("°C", "km/h"), ("°F", "mph")] {
            weatherFixture(widget, stale: true, unit: unit, flatRange: true)
            widget.render(bar)
            XCTAssertTrue(widget.strings().contains("wind:\(number(14)) \(windUnit)"))
            XCTAssertTrue(widget.strings().contains("stale:" + ShellLocalizer.string("Last update failed", [])))
            XCTAssertEqual(widget.strings().filter { $0.hasPrefix("range") }, (1 ... 5).map {
                "range\($0):0.0000:0.0000"
            })
        }
        var weather = weatherFixture(widget)
        weather.temp = 12.5
        weather.wind = 12.5
        widget.set("weather") { weather.write(into: &$0) }
        widget.render(bar)
        XCTAssertTrue(widget.strings().contains("temperature:\(number(13))°C"))
        XCTAssertTrue(widget.strings().contains("wind:\(number(13)) km/h"))
        XCTAssertTrue(widget.strings().contains("stale:nil"))
    }

    func testSharedWeatherBarsKeepSelectionsAndFreshClicksThroughEverySkin() throws {
        let shell = try sharedLibraryShell("weather")
        defer { try? FileManager.default.removeItem(at: shell) }
        let base: [String: ShellServiceValue] = [
            "symbol": .text("cloud.sun"), "temp": .number(18.4), "condition": .text("Partly cloudy"),
            "code": .number(2), "day": .bool(true), "unit": .text("°C"), "place": .text("Toronto"),
            "hours": .array([]), "days": .array([]), "status": .text("ok")
        ]
        let ignored: [(String, ShellServiceValue)] = [
            ("hours", .array([.object(["label": .text("Later")])])),
            ("days", .array([.object(["label": .text("Tomorrow")])])),
            ("unit", .text("°F")), ("place", .text("Elsewhere")), ("status", .text("stale"))
        ]
        let selected: [(String, ShellServiceValue)] = [
            ("symbol", .text("moon.stars")), ("temp", .number(24)), ("condition", .text("Rain")),
            ("code", .number(61)), ("day", .bool(false))
        ]
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let height = config.barOverride?.settings.height ?? 32
            let widget = try makeWidget(
                "weather",
                config: config,
                shell: shell,
                source: shell.appendingPathComponent("default/widgets/weather/init.luau")
            )
            for vertical in [false, true] {
                for backgrounds in [false, true] {
                    let context = "\(profile) vertical=\(vertical) backgrounds=\(backgrounds)"
                    var bar = fixture(config, height: height, vertical: vertical)
                    bar.style.backgrounds = backgrounds
                    widget.set("weather") { ShellServiceValue.object(base).write(to: &$0) }
                    widget.render(bar)
                    var stats = omni_render_stats()
                    var error = [CChar](repeating: 0, count: 256)
                    XCTAssertEqual(omni_instance_render(
                        widget.instance,
                        OMNI_VIEW_BAR,
                        100_000_000,
                        &stats,
                        &error,
                        error.count
                    ), OMNI_OK, context)
                    XCTAssertNotEqual(stats.deps & ShellDataKey.weather.bit, 0, context)
                    XCTAssertEqual(stats.deps & ShellDataKey.seconds.bit, 0, context)
                    for (field, value) in ignored {
                        widget.set("weather") { ShellServiceValue.object(base).write(to: &$0) }
                        widget.render(bar)
                        var changed = base
                        changed[field] = value
                        widget.set("weather") { ShellServiceValue.object(changed).write(to: &$0) }
                        XCTAssertFalse(omni_instance_needs_render(
                            widget.instance,
                            OMNI_VIEW_BAR,
                            ShellDataKey.weather.bit
                        ), context + " " + field)
                    }
                    for (field, value) in selected {
                        widget.set("weather") { ShellServiceValue.object(base).write(to: &$0) }
                        widget.render(bar)
                        var changed = base
                        changed[field] = value
                        widget.set("weather") { ShellServiceValue.object(changed).write(to: &$0) }
                        XCTAssertTrue(omni_instance_needs_render(
                            widget.instance,
                            OMNI_VIEW_BAR,
                            ShellDataKey.weather.bit
                        ), context + " " + field)
                    }
                    widget.set("weather") { ShellServiceValue.object(base).write(to: &$0) }
                    widget.render(bar)
                    let button = try XCTUnwrap(widget.surface.layout.core.elements {
                        $0.action == OMNI_ACTION_POPOUT
                    }.first, context)
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                    let point = CGPoint(x: frame.midX, y: frame.midY)
                    let before = widget.actions.count
                    widget.surface.press(at: point)
                    widget.surface.release(at: point)
                    XCTAssertEqual(widget.actions.count, before + 1, context)
                    XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT, context)
                }
            }
            widget.set("weather") { $0.null() }
            widget.render(fixture(config, height: height, vertical: false))
            XCTAssertEqual(widget.surface.size, .zero, profile)
            var stats = omni_render_stats()
            var error = [CChar](repeating: 0, count: 256)
            XCTAssertEqual(omni_instance_render(
                widget.instance,
                OMNI_VIEW_BAR,
                100_000_000,
                &stats,
                &error,
                error.count
            ), OMNI_OK, profile)
            XCTAssertNotEqual(stats.deps & ShellDataKey.weather.bit, 0, profile)
            weatherFixture(widget)
            XCTAssertTrue(omni_instance_needs_render(widget.instance, OMNI_VIEW_BAR, ShellDataKey.weather.bit), profile)
            widget.render(fixture(config, height: height, vertical: false))
            XCTAssertGreaterThan(widget.surface.size.width, 0, profile)
            XCTAssertGreaterThan(widget.surface.size.height, 0, profile)
        }
    }

    func testSharedWeatherPanelsKeepForecastLimitsStaleFeedbackAndCompactContent() throws {
        let shell = try sharedLibraryShell("weather")
        defer { try? FileManager.default.removeItem(at: shell) }
        let hourLabels = (0 ..< 14).map { "Forecast hour \($0)" }
        let dayLabels = ["Today", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu"]
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            for name in ["weather", "control-center"] {
                let context = "\(profile)/\(name)"
                let widget = try makeWidget(
                    name,
                    config: config,
                    shell: shell,
                    source: name == "weather" ? shell
                        .appendingPathComponent("default/widgets/weather/init.luau") : nil
                )
                var weather = weatherFixture(widget)
                weather.hours = weather.hours.enumerated().map { index, hour in
                    ShellWeatherHour(
                        time: hour.time,
                        label: hourLabels[index],
                        temp: hour.temp,
                        code: hour.code,
                        day: hour.day,
                        rain: hour.rain
                    )
                }
                widget.set("weather") { weather.write(into: &$0) }
                widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
                for limit in [4, 12] {
                    widget.set("settings") {
                        ShellServiceValue.object(["tab": .text("weather"), "forecastHours": .number(Double(limit))])
                            .write(to: &$0)
                    }
                    _ = widget.renderPopout()
                    let strings = widget.strings(OMNI_VIEW_POPOUT)
                    XCTAssertTrue(strings.contains("Toronto"), context)
                    XCTAssertTrue(strings.contains(ShellLocalizer.string("Partly cloudy", [])), context)
                    XCTAssertEqual(strings.filter { hourLabels.contains($0) }, Array(hourLabels.prefix(
                        name == "control-center" ? 8 : limit
                    )), context)
                    XCTAssertEqual(strings.filter { dayLabels.contains($0) }, Array(dayLabels.prefix(
                        name == "control-center" ? 5 : 7
                    )), context)
                }
                if name == "weather" {
                    weather.stale = true
                    widget.set("weather") { weather.write(into: &$0) }
                    _ = widget.renderPopout()
                    let strings = widget.strings(OMNI_VIEW_POPOUT)
                    XCTAssertTrue(strings.contains(ShellLocalizer.string("Last update failed", [])), context)
                    XCTAssertTrue(
                        strings.contains(ShellLocalizer.string("Weather by %@", [.text("Open-Meteo.com")])),
                        context
                    )
                    let wind = ShellFormatter.string(kind: OMNI_FORMAT_NUMBER, 14, digits: 0) + " km/h"
                    XCTAssertTrue(strings.contains { $0.contains(wind) }, context)
                }
            }
        }
    }

    func testSharedWeatherPanelsRemainNonzeroAndDemandWeatherWithoutData() throws {
        let shell = try sharedLibraryShell("weather")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            for name in ["weather", "control-center"] {
                let context = "\(profile)/\(name)"
                let widget = try makeWidget(
                    name,
                    config: config,
                    shell: shell,
                    source: name == "weather" ? shell
                        .appendingPathComponent("default/widgets/weather/init.luau") : nil
                )
                widget.set("settings") { ShellServiceValue.object(["tab": .text("weather")]).write(to: &$0) }
                widget.set("weather") { $0.null() }
                widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
                widget.layoutPopout()
                XCTAssertGreaterThan(widget.surface.size.width, 0, context)
                XCTAssertGreaterThan(widget.surface.size.height, 0, context)
                XCTAssertTrue(
                    widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])),
                    context
                )
                if ["nocturne", "wayline"].contains(profile), name == "weather" {
                    let elements = widget.surface.layout.core.elements { _ in true }
                    let body = try XCTUnwrap(elements.first {
                        let paint = widget.surface.layout.core.paint(of: $0)
                        return paint.cornerRadius == (profile == "nocturne" ? 18 : 12)
                    }, context)
                    let label = try XCTUnwrap(elements.first {
                        widget.text.string(widget.surface.layout.core.content(of: $0).text)
                            == ShellLocalizer.string("Unavailable", [])
                    }, context)
                    let card = widget.surface.layout.core.parent(of: label)
                    let bounds = CGRect(widget.surface.layout.core.absoluteFrame(of: body))
                    let content = CGRect(widget.surface.layout.core.absoluteFrame(of: card))
                    XCTAssertTrue(bounds.contains(content), context + ": \(content) outside \(bounds)")
                }
                if profile == "celestial", name == "weather" {
                    let scroll = try XCTUnwrap(widget.surface.layout.core.elements { $0.scrolls }.first, context)
                    let viewport = CGRect(widget.surface.layout.core.absoluteFrame(of: scroll))
                    XCTAssertEqual(viewport.size, CGSize(width: 840, height: 530), context)
                }
                var stats = omni_render_stats()
                var error = [CChar](repeating: 0, count: 256)
                XCTAssertEqual(omni_instance_render(
                    widget.instance,
                    OMNI_VIEW_POPOUT,
                    100_000_000,
                    &stats,
                    &error,
                    error.count
                ), OMNI_OK, context)
                XCTAssertNotEqual(stats.deps & ShellDataKey.weather.bit, 0, context)
                XCTAssertEqual(stats.deps & ShellDataKey.seconds.bit, 0, context)
                weatherFixture(widget)
                _ = widget.renderPopout()
                XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Toronto"), context)
            }
        }
    }

    func testCelestialDashboardWeatherUsesTheSharedModelAndKeepsItsTabAndMissingState() throws {
        let shell = try sharedLibraryShell("weather")
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget("dashboard", config: config, shell: shell)
        calendarFixture(widget)
        weatherFixture(widget)
        widget.set("media") { $0.null() }
        widget.render(fixture(config, height: config.barOverride?.settings.height ?? 60, vertical: false))
        _ = widget.renderPopout()
        let temperature = ShellFormatter.string(kind: OMNI_FORMAT_NUMBER, 18, digits: 0)
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(temperature + "°C"))
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Partly cloudy", [])))
        let weather = weatherFixture(widget, stale: true, unit: "°F")
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(temperature + "°F"))
        widget.layoutPopout()
        let label = try XCTUnwrap(widget.surface.layout.core.elements {
            widget.text.string($0.text) == ShellLocalizer.string("Weather", [])
        }.first)
        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: label))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let before = widget.actions.count
        widget.surface.press(at: point)
        widget.surface.release(at: point)
        XCTAssertEqual(widget.actions.count, before + 1)
        XCTAssertEqual(widget.invoke(try XCTUnwrap(widget.actions.last), view: OMNI_VIEW_POPOUT), [])
        _ = widget.renderPopout()
        let strings = widget.strings(OMNI_VIEW_POPOUT)
        XCTAssertTrue(strings.contains("Toronto"))
        XCTAssertTrue(strings.contains(temperature + "°F"))
        let wind = ShellFormatter.string(kind: OMNI_FORMAT_NUMBER, 14, digits: 0) + " mph"
        XCTAssertTrue(strings.contains { $0.contains(wind) })
        XCTAssertTrue(strings.contains(ShellLocalizer.string("7-day forecast", [])))
        try assertCelestialWeatherLayout(widget, weather: weather, context: "dashboard")
        widget.set("weather") { $0.null() }
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])))
        widget.layoutPopout()
        let scroll = try XCTUnwrap(widget.surface.layout.core.elements { $0.scrolls }.first)
        XCTAssertEqual(
            CGRect(widget.surface.layout.core.absoluteFrame(of: scroll)).size,
            CGSize(width: 840, height: 530)
        )
    }

    func testCelestialWeatherPopoutKeepsExtrasReachableWithinItsViewport() throws {
        let shell = try sharedLibraryShell("weather")
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget(
            "weather",
            config: config,
            shell: shell,
            source: shell.appendingPathComponent("default/widgets/weather/init.luau")
        )
        let weather = weatherFixture(widget, stale: true)
        widget.render(fixture(config, height: config.barOverride?.settings.height ?? 60, vertical: false))
        try assertCelestialWeatherLayout(widget, weather: weather, context: "weather")
    }

    func testSharedClockBarsKeepOptionsTimeAndGesturesWithoutCalendarDemand() throws {
        let shell = try sharedLibraryShell("calendar")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let height = config.barOverride?.settings.height ?? 32
            let widget = try makeWidget(
                "clock", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/clock/init.luau")
            )
            calendarFixture(widget)
            for vertical in [false, true] {
                for date in [false, true] {
                    for icon in [false, true] {
                        let context = "\(profile) vertical=\(vertical) date=\(date) icon=\(icon)"
                        widget.set("settings") {
                            ShellServiceValue.object(["date": .bool(date), "icon": .bool(icon)]).write(to: &$0)
                        }
                        widget.render(fixture(config, height: height, vertical: vertical))
                        var stats = omni_render_stats()
                        var error = [CChar](repeating: 0, count: 256)
                        XCTAssertEqual(
                            omni_instance_render(
                                widget.instance,
                                OMNI_VIEW_BAR,
                                100_000_000,
                                &stats,
                                &error,
                                error.count
                            ),
                            OMNI_OK, context
                        )
                        XCTAssertEqual(stats.deps & (ShellDataKey.calendar.bit | ShellDataKey.seconds.bit), 0, context)
                        let strings = widget.strings()
                        XCTAssertEqual(
                            strings.contains("calendar") || strings.contains("calendar_month") || strings
                                .contains("clock.fill"),
                            icon, context
                        )
                        if vertical {
                            for value in ["09", "41", "am"] {
                                XCTAssertTrue(strings.contains(value), context + ": " + value)
                            }
                        } else {
                            XCTAssertTrue(strings.contains("9:41 AM"), context)
                            XCTAssertEqual(
                                strings.contains(profile == "matrix" ? "FRI OCT 23" : "Fri Oct 23"),
                                date,
                                context
                            )
                            if profile == "matrix" {
                                XCTAssertEqual(strings.contains("//"), date, context)
                            }
                        }
                        let element = try XCTUnwrap(widget.surface.layout.core.elements {
                            profile == "celestial"
                                ? widget.text.string($0.action) == "shell toggle dashboard"
                                : $0.action == OMNI_ACTION_POPOUT
                        }.first, context)
                        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: element))
                        let point = CGPoint(x: frame.midX, y: frame.midY)
                        let before = widget.actions.count
                        widget.surface.press(at: point)
                        widget.surface.release(at: point)
                        XCTAssertEqual(widget.actions.count, before + 1, context)
                        if profile == "celestial" {
                            XCTAssertEqual(widget.clicks.last?.action, "shell toggle dashboard", context)
                            let beforeRight = widget.actions.count
                            widget.surface.press(at: point, button: .right)
                            widget.surface.release(at: point, event: ShellEvent(button: .right))
                            XCTAssertEqual(widget.actions.count, beforeRight + 1, context)
                            XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT, context)
                        } else {
                            XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT, context)
                        }
                    }
                }
            }
            widget.set("clock") { $0.string("19:04") }
            widget.render(fixture(config, height: height, vertical: true))
            XCTAssertTrue(widget.strings().contains("19"), profile)
            XCTAssertTrue(widget.strings().contains("04"), profile)
            XCTAssertFalse(widget.strings().contains("am"), profile)
            XCTAssertFalse(widget.strings().contains("pm"), profile)
        }
    }

    func testSharedVerticalClocksParseSupportedFormatsAndFallbackForRegionalFormats() throws {
        let shell = try sharedLibraryShell("calendar")
        defer { try? FileManager.default.removeItem(at: shell) }
        let parsed = [
            ("4:05\u{202F}PM", ["04", "05", "pm"]),
            ("4:05 pm", ["04", "05", "pm"]),
            ("16.05", ["16", "05"]),
            ("19:04", ["19", "04"])
        ]
        let fallback = ["오후 4:05", "下午4:05", "4:05\u{202F}μμ", "٤:٠٥ م"]
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let bar = fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: true)
            let widget = try makeWidget(
                "clock", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/clock/init.luau")
            )
            calendarFixture(widget)
            widget.set("settings") {
                ShellServiceValue.object(["date": .bool(false), "icon": .bool(false)]).write(to: &$0)
            }
            for (clock, expected) in parsed {
                widget.set("clock") { $0.string(clock) }
                widget.render(bar)
                XCTAssertEqual(widget.strings(), expected, "\(profile) \(clock)")
            }
            for clock in fallback {
                widget.set("clock") { $0.string(clock) }
                widget.render(bar)
                let strings = widget.strings()
                XCTAssertEqual(strings.count, 2, "\(profile) \(clock)")
                XCTAssertTrue(strings.allSatisfy {
                    $0.range(of: "^[0-9]{2}$", options: .regularExpression) != nil
                }, "\(profile) \(clock): \(strings)")
            }
        }
    }

    func testSharedClockAndControlCenterKeepLoadingCalendarPanelsOpenAndDemandCalendarData() throws {
        let shell = try sharedLibraryShell("calendar")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            for name in ["clock", "control-center"] {
                let context = "\(profile)/\(name)"
                let widget = try makeWidget(
                    name, config: config, shell: shell,
                    source: name == "clock" ? shell.appendingPathComponent("default/widgets/clock/init.luau") : nil
                )
                widget.set("settings") { ShellServiceValue.object(["tab": .text("calendar")]).write(to: &$0) }
                calendarFixture(widget)
                widget.set("calendar") { $0.null() }
                widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
                widget.layoutPopout()
                XCTAssertGreaterThan(widget.surface.size.width, 0, context)
                XCTAssertGreaterThan(widget.surface.size.height, 0, context)
                XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(
                    ShellLocalizer.string("Loading…", [])
                ), context)
                var stats = omni_render_stats()
                var error = [CChar](repeating: 0, count: 256)
                XCTAssertEqual(
                    omni_instance_render(widget.instance, OMNI_VIEW_POPOUT, 100_000_000, &stats, &error, error.count),
                    OMNI_OK, context
                )
                XCTAssertNotEqual(stats.deps & ShellDataKey.calendar.bit, 0, context)
                XCTAssertEqual(stats.deps & ShellDataKey.seconds.bit, 0, context)
                calendarFixture(widget)
                _ = widget.renderPopout()
                let strings = widget.strings(OMNI_VIEW_POPOUT)
                XCTAssertFalse(strings.contains(ShellLocalizer.string("Loading…", [])), context)
                XCTAssertTrue(strings.contains("October 2026"), context)
                XCTAssertTrue(strings.contains("Team standup"), context)
            }
        }
    }

    func testCelestialDashboardCalendarDoesNotDemandSecondsWithoutMedia() throws {
        let shell = try sharedLibraryShell("calendar")
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget("dashboard", config: config, shell: shell)
        calendarFixture(widget)
        widget.set("media") { $0.null() }
        widget.render(fixture(config, height: config.barOverride?.settings.height ?? 60, vertical: false))
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("October 2026"))
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Nothing is playing", [])))
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_instance_render(widget.instance, OMNI_VIEW_POPOUT, 100_000_000, &stats, &error, error.count),
            OMNI_OK
        )
        XCTAssertNotEqual(stats.deps & ShellDataKey.calendar.bit, 0)
        XCTAssertEqual(stats.deps & ShellDataKey.seconds.bit, 0)
    }

    func testSharedCalendarPanelsDeliverNavigationAgendaAccessAndPreciseScroll() throws {
        let shell = try sharedLibraryShell("calendar")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            for name in ["clock", "calendar", "control-center"] {
                let context = "\(profile)/\(name)"
                let widget = try makeWidget(
                    name, config: config, shell: shell,
                    source: name == "control-center" ? nil : shell
                        .appendingPathComponent("default/widgets/\(name)/init.luau")
                )
                widget.set("settings") {
                    ShellServiceValue.object(["tab": .text("calendar"), "agendaEvents": .number(2)]).write(to: &$0)
                }
                calendarFixture(widget)
                widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
                _ = widget.renderPopout()
                for label in ["Team standup", "Design review", "Now"] {
                    XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(label, [])), context)
                }
                XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(
                    ShellLocalizer.string("In %lld min", [.number(25)])
                ), context)
                XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains("Team offsite"), context)
                for command in [
                    "calendar month previous", "calendar month today", "calendar month next",
                    "calendar open standup", "calendar open review", "calendar open"
                ] {
                    widget.layoutPopout()
                    try clickCommand(command, widget: widget, context: context)
                }
                widget.layoutPopout()
                let scrollElement = try XCTUnwrap(
                    widget.surface.layout.core.elements { $0.scrollAction != 0 }.first, context
                )
                let scrollAction = widget.surface.layout.core.content(of: scrollElement).scrollAction
                let scrollFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: scrollElement))
                var probe = ShellEvent(button: .none)
                probe.kind = .scroll
                let beforeScroll = widget.actions.count
                XCTAssertTrue(widget.surface.scroll(
                    at: CGPoint(x: scrollFrame.midX, y: scrollFrame.midY), event: probe
                ), context)
                XCTAssertEqual(widget.actions.count, beforeScroll + 1, context)
                XCTAssertEqual(widget.actions.last, scrollAction, context)
                let scroll = { (dy: Double, precise: Bool) in
                    var event = ShellEvent(button: .none)
                    event.kind = .scroll
                    event.dy = dy
                    event.precise = precise
                    return widget.invoke(scrollAction, view: OMNI_VIEW_POPOUT, event: event)
                }
                XCTAssertEqual(scroll(5, true), [], context)
                XCTAssertEqual(scroll(7, true), ["calendar month previous"], context)
                XCTAssertEqual(scroll(-6, true), [], context)
                XCTAssertEqual(scroll(-6, true), ["calendar month next"], context)
                XCTAssertEqual(scroll(0, false), [], context)
                XCTAssertEqual(scroll(-2, false), ["calendar month next", "calendar month next"], context)
                XCTAssertEqual(scroll(1, false), ["calendar month previous"], context)
                for (access, command) in [
                    ("notDetermined", "calendar authorize"), ("denied", "calendar settings"), ("full", "calendar open")
                ] {
                    calendarFixture(widget, access: access, month: false)
                    widget.layoutPopout()
                    try clickCommand(command, widget: widget, context: context + " " + access)
                    let nodes = widget.renderPopout()
                    let actions = nodes.map { widget.text.string($0.content.action) }
                    let celestialPanel = profile == "celestial" && name != "control-center"
                    XCTAssertEqual(actions.filter { $0 == command }.count, 1, context + " " + access)
                    XCTAssertEqual(
                        widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Open Calendar", [])),
                        !celestialPanel || access == "full", context
                    )
                    if access == "full" {
                        XCTAssertFalse(actions.contains("calendar authorize"), context)
                        XCTAssertEqual(actions.filter { $0.hasPrefix("calendar open ") }.count, 2, context)
                    } else if celestialPanel {
                        XCTAssertFalse(actions.contains("calendar open"), context + " " + access)
                    }
                }
            }
        }
    }

    func testSharedCalendarAgendaLimitAndBarCountdownFollowTheModel() throws {
        let shell = try sharedLibraryShell("calendar")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let widget = try makeWidget(
                "calendar", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/calendar/init.luau")
            )
            calendarFixture(widget)
            widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
            for (limit, expected) in [(1.0, 1), (2, 2), (2.7, 3), (12, 4)] {
                widget.set("settings") {
                    ShellServiceValue.object(["agendaEvents": .number(limit)]).write(to: &$0)
                }
                let events = widget.renderPopout()
                    .filter { widget.text.string($0.content.action).hasPrefix("calendar open ") }
                XCTAssertEqual(events.count, expected, "\(profile) agendaEvents=\(limit)")
            }
            widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
            XCTAssertTrue(widget.strings().contains("Team standup"), profile)
            XCTAssertTrue(widget.strings().contains(ShellLocalizer.string("Now", [])), profile)
            widget.set("seconds") { $0.number(1_000_901) }
            widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
            XCTAssertTrue(widget.strings().contains("Design review"), profile)
            XCTAssertTrue(widget.strings().contains(ShellLocalizer.string("In %lld min", [.number(10)])), profile)
        }
    }

    func testSharedMediaBarsKeepSelectionsAndInputThroughEverySkin() throws {
        let shell = try sharedLibraryShell("media")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in try barHostingProfiles(in: shell) {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let height = config.barOverride?.settings.height ?? 32
            let widget = try makeWidget(
                "media", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/media/init.luau")
            )
            for vertical in [false, true] {
                for backgrounds in [false, true] {
                    mediaFixture(widget)
                    var bar = fixture(config, height: height, vertical: vertical)
                    bar.style.backgrounds = backgrounds
                    widget.render(bar)
                    let context = "\(profile) vertical=\(vertical) backgrounds=\(backgrounds)"
                    var stats = omni_render_stats()
                    var error = [CChar](repeating: 0, count: 256)
                    XCTAssertEqual(
                        omni_instance_render(widget.instance, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count),
                        OMNI_OK, context
                    )
                    XCTAssertNotEqual(stats.deps & ShellDataKey.media.bit, 0, context)
                    XCTAssertEqual(stats.deps & (ShellDataKey.seconds.bit | ShellDataKey.lyrics.bit), 0, context)
                    mediaFixture(widget, elapsed: 120)
                    XCTAssertFalse(
                        omni_instance_needs_render(widget.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit),
                        context
                    )
                    XCTAssertFalse(
                        omni_instance_needs_render(widget.instance, OMNI_VIEW_BAR, ShellDataKey.seconds.bit),
                        context
                    )
                    mediaFixture(widget, title: "Changed track")
                    XCTAssertTrue(
                        omni_instance_needs_render(widget.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit),
                        context
                    )
                    mediaFixture(widget)
                    widget.render(bar)
                    XCTAssertLessThanOrEqual(
                        vertical ? widget.surface.size.width : widget.surface.size.height,
                        height,
                        context
                    )
                    let button = try XCTUnwrap(
                        widget.surface.layout.core.elements { $0.action == OMNI_ACTION_POPOUT }.first,
                        context
                    )
                    let content = widget.surface.layout.core.content(of: button)
                    XCTAssertEqual(widget.text.string(content.help), "Northern Lights — Sample Artist", context)
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                    let point = CGPoint(x: frame.midX, y: frame.midY)
                    let beforePopout = widget.actions.count
                    widget.surface.press(at: point)
                    widget.surface.release(at: point)
                    XCTAssertEqual(widget.actions.count, beforePopout + 1, context)
                    XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT, context)
                    let before = widget.clicks.count
                    widget.surface.press(at: point, button: .right)
                    widget.surface.release(at: point, event: ShellEvent(button: .right))
                    XCTAssertEqual(widget.clicks.count, before + 1, context)
                    XCTAssertEqual(widget.clicks.last?.action, "media toggle", context)
                }
            }
            widget.set("media") { $0.null() }
            widget.render(fixture(config, height: height, vertical: false))
            XCTAssertEqual(widget.surface.size, .zero, profile)
        }
    }

    func testSharedControlCenterDefaultsDemandAndNativeActionsAcrossProfiles() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            for capsule in [false, true] {
                for vertical in [false, true] {
                    let widget = try makeWidget(
                        "control-center", config: config, shell: shell,
                        source: shell.appendingPathComponent("default/widgets/control-center/init.luau")
                    )
                    widget.set("settings") { ShellServiceValue.object([:]).write(to: &$0) }
                    audioFixture(widget, access: .granted)
                    wifiFixture(widget)
                    bluetoothFixture(widget)
                    mediaFixture(widget)
                    var bar = fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: vertical)
                    if capsule {
                        bar.style.transparent = true
                        bar.style.backgrounds = true
                    }
                    widget.render(bar)
                    let context = "\(profile)/\(capsule)/\(vertical)"
                    let button = try XCTUnwrap(widget.surface.layout.core.elements {
                        $0.action == OMNI_ACTION_POPOUT
                    }.first, context)
                    let content = widget.surface.layout.core.content(of: button)
                    XCTAssertEqual(
                        widget.text.string(content.help),
                        ShellLocalizer.string("Control Center", []),
                        context
                    )
                    XCTAssertEqual(widget.strings().contains("SYS"), profile == "matrix" && !vertical, context)
                    let barFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                    let barCount = widget.actions.count
                    let point = CGPoint(x: barFrame.midX, y: barFrame.midY)
                    widget.surface.press(at: point)
                    widget.surface.release(at: point)
                    XCTAssertEqual(widget.actions.count, barCount + 1, context)
                    XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT, context)
                    for hasBattery in [true, false] {
                        if hasBattery {
                            batteryFixture(widget, level: 80, power: ShellPower(source: "ac"))
                        } else {
                            widget.set("battery") { $0.null() }
                        }
                        let context = "\(profile)/capsule=\(capsule)/vertical=\(vertical)/battery=\(hasBattery)"
                        if hasBattery {
                            for command in ["wifi settings", "bluetooth settings", "battery settings"] {
                                widget.layoutPopout()
                                try clickCommand(command, widget: widget, context: context)
                            }
                            widget.set("bluetooth") {
                                ShellBluetooth(power: true, access: "denied").write(into: &$0)
                            }
                            widget.layoutPopout()
                            try clickCommand("bluetooth authorize", widget: widget, context: context)
                            bluetoothFixture(widget)
                        }
                        widget.layoutPopout()
                        let nodes = widget.renderPopout()
                        let strings = widget.strings(OMNI_VIEW_POPOUT)
                        for key in ["Control Center", "Wi-Fi", "Bluetooth"] {
                            XCTAssertTrue(strings.contains(ShellLocalizer.string(key, [])), context + key)
                        }
                        XCTAssertEqual(strings.contains(ShellLocalizer.string("Not charging", [])), hasBattery, context)
                        XCTAssertEqual(nodes.filter { $0.kind == .slider }.count, 1, context)
                        let deps = renderDependencies(widget, view: OMNI_VIEW_POPOUT)
                        var expected: Set<ShellDataKey> = [
                            .settings,
                            .wifi,
                            .bluetooth,
                            .volume,
                            .muted,
                            .media,
                            .battery
                        ]
                        if hasBattery { expected.formUnion([.charging, .power]) }
                        XCTAssertEqual(deps & ~ShellDataKey.bar.bit, expected.reduce(0) { $0 | $1.bit }, context)
                        if profile == "matrix" {
                            XCTAssertTrue(strings.contains("matrix://"), context)
                            let close = try XCTUnwrap(widget.surface.layout.core.elements {
                                $0.action == OMNI_ACTION_POPOUT && widget.text.string($0.help) == ShellLocalizer.string(
                                    "Close",
                                    []
                                )
                            }.first, context)
                            let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: close))
                            let count = widget.actions.count
                            widget.surface.press(at: CGPoint(x: frame.midX, y: frame.midY))
                            widget.surface.release(at: CGPoint(x: frame.midX, y: frame.midY))
                            XCTAssertEqual(widget.actions.count, count + 1, context)
                            XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT, context)
                        }
                        if capsule && ["default", "lake"].contains(profile) {
                            let root = try XCTUnwrap(nodes.first, context)
                            XCTAssertEqual(root.paint.cornerRadius, 14, context)
                            XCTAssertEqual(root.paint.material, UInt8(OMNI_MATERIAL_CLEAR), context)
                            XCTAssertFalse(root.content.attaches, context)
                        }
                    }
                    widget.set("settings") { ShellServiceValue.object(["tab": .text("system")]).write(to: &$0) }
                    systemStatsFixture(widget)
                    widget.layoutPopout()
                    let system = renderDependencies(widget, view: OMNI_VIEW_POPOUT)
                    let expectedSystem: Set<ShellDataKey> = [.settings, .cpu, .gpu, .memory, .disk, .network, .system]
                    XCTAssertEqual(system & ~ShellDataKey.bar.bit, expectedSystem.reduce(0) { $0 | $1.bit }, profile)
                    XCTAssertEqual(widget.renderPopout().filter { $0.kind == .progress }.count, 4, profile)
                    if ["wayline", "nocturne", "celestial"].contains(profile) {
                        let first = try XCTUnwrap(widget.surface.layout.core.elements {
                            widget.text.string($0.help) == ShellLocalizer.string("Control Center", [])
                        }.first, profile)
                        let last = try XCTUnwrap(widget.surface.layout.core.elements {
                            widget.text.string($0.help) == ShellLocalizer.string("System", [])
                        }.first, profile)
                        let firstFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: first))
                        let lastFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: last))
                        XCTAssertEqual(
                            (firstFrame.minX + lastFrame.maxX) / 2,
                            widget.surface.size.width / 2,
                            accuracy: 0.01,
                            profile
                        )
                    }
                    let overview = try XCTUnwrap(widget.surface.layout.core.elements {
                        widget.text.string($0.help) == ShellLocalizer.string("Control Center", []) && $0.action != 0
                    }.first, profile)
                    let action = widget.surface.layout.core.content(of: overview).action
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: overview))
                    let count = widget.actions.count
                    widget.surface.press(at: CGPoint(x: frame.midX, y: frame.midY))
                    widget.surface.release(at: CGPoint(x: frame.midX, y: frame.midY))
                    XCTAssertEqual(widget.actions.count, count + 1, profile)
                    XCTAssertEqual(widget.actions.last, action, profile)
                    XCTAssertEqual(widget.invoke(action, view: OMNI_VIEW_POPOUT), [], profile)
                    widget.layoutPopout()
                    XCTAssertTrue(
                        widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Wi-Fi", [])),
                        profile
                    )
                }
            }
        }
    }

    func testWaylineControlCenterCardsHaveContrastAndSpaceAcrossTabs() throws {
        let shell = try stepShell([:])
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertTrue(try ShellProfiles.select("wayline", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget(
            "control-center", config: config, shell: shell,
            source: shell.appendingPathComponent("default/widgets/control-center/init.luau")
        )
        audioFixture(widget, access: .granted)
        wifiFixture(widget)
        bluetoothFixture(widget)
        batteryFixture(widget)
        mediaFixture(widget)
        calendarFixture(widget)
        weatherFixture(widget)
        systemStatsFixture(widget)
        for capsule in [false, true] {
            var bar = fixture(config, height: 40, vertical: false)
            if capsule {
                bar.style.transparent = true
                bar.style.backgrounds = true
            }
            widget.render(bar)
            for (tab, count) in [
                ("overview", 5),
                ("audio", 3),
                ("media", 2),
                ("calendar", 2),
                ("weather", 3),
                ("system", 2)
            ] {
                let context = "\(tab)/capsule=\(capsule)"
                widget.set("settings") { ShellServiceValue.object(["tab": .text(tab)]).write(to: &$0) }
                widget.layoutPopout()
                let cards = widget.surface.layout.core.elements { _ in true }.filter {
                    let paint = widget.surface.layout.core.paint(of: $0)
                    return paint.fill.role & 0xFF == UInt16(ShellRole.elevatedSurface.rawValue + 1)
                        && paint.cornerRadius == 9
                }
                XCTAssertEqual(cards.count, count, context)
                let tabs = widget.surface.layout.core.elements {
                    $0.help != 0 && $0.action != 0
                }.filter { widget.surface.layout.core.absoluteFrame(of: $0).height == 30 }
                XCTAssertEqual(tabs.count, 6, context)
                let tabBottom = try XCTUnwrap(tabs.map {
                    CGRect(widget.surface.layout.core.absoluteFrame(of: $0)).maxY
                }.max(), context)
                for card in cards {
                    XCTAssertGreaterThanOrEqual(
                        CGRect(widget.surface.layout.core.absoluteFrame(of: card)).minY,
                        tabBottom + 8,
                        context
                    )
                }
            }
        }
    }

    func testCelestialControlCenterTabIconsDoNotChangeSharedAudioGlyphs() throws {
        let shell = try stepShell([:])
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget(
            "control-center", config: config, shell: shell,
            source: shell.appendingPathComponent("default/widgets/control-center/init.luau")
        )
        audioFixture(widget, access: .granted)
        widget.render(fixture(config, height: 60, vertical: false))
        widget.set("settings") { ShellServiceValue.object(["tab": .text("audio")]).write(to: &$0) }
        for (volume, symbol) in [
            (0.0, "speaker.slash.fill"),
            (10.0, "speaker.wave.1.fill"),
            (50.0, "speaker.wave.2.fill"),
            (90.0, "speaker.wave.3.fill")
        ] {
            widget.set("volume") { $0.number(volume) }
            let nodes = widget.renderPopout()
            XCTAssertTrue(
                nodes.contains { $0.kind == .symbol && widget.text.string($0.content.text) == symbol },
                symbol
            )
            let speakers = nodes
                .filter { $0.kind == .symbol && widget.text.string($0.content.text).hasPrefix("speaker.") }
            XCTAssertEqual(speakers.count, 5, symbol)
            for tabIcon in [
                "dashboard",
                "volume_up",
                "music_note",
                "calendar_month",
                "partly_cloudy_day",
                "monitoring"
            ] {
                XCTAssertEqual(nodes.filter { widget.text.string($0.content.text) == tabIcon }.count, 1, tabIcon)
            }
        }
    }

    func testCelestialDashboardPreloadsAllModulesBeforeRendering() throws {
        try assertCelestialPreloads("dashboard", allModules: true)
    }

    func testCelestialDashboardPreloadsSharedModelsBeforeRendering() throws {
        try assertCelestialPreloads("dashboard", allModules: false)
    }

    func testCelestialStatusPreloadsAllModulesBeforeRendering() throws {
        try assertCelestialPreloads("status", allModules: true)
    }

    func testCelestialStatusPreloadsSharedModelsBeforeRendering() throws {
        try assertCelestialPreloads("status", allModules: false)
    }

    func testCelestialDashboardMediaCardUsesTheModelWithoutLyricsAndHasInertIdleControls() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget("dashboard", config: config, shell: shell)
        calendarFixture(widget)
        weatherFixture(widget)
        systemStatsFixture(widget)
        widget.render(fixture(config, height: 60, vertical: false))
        for state in ["playing", "paused", "idle"] {
            mediaFixture(widget, playing: state == "playing")
            if state == "idle" { widget.set("media") { $0.null() } }
            widget.layoutPopout()
            let deps = renderDependencies(widget, view: OMNI_VIEW_POPOUT)
            XCTAssertNotEqual(deps & ShellDataKey.media.bit, 0, state)
            XCTAssertEqual(deps & ShellDataKey.lyrics.bit, 0, state)
            let strings = widget.strings(OMNI_VIEW_POPOUT)
            XCTAssertTrue(strings.contains(state == "idle"
                    ? ShellLocalizer.string("Nothing is playing", []) : "Northern Lights"), state)
            if state == "idle" {
                let actions = widget.renderPopout().map { widget.text.string($0.content.action) }
                for command in ["media previous", "media toggle", "media next"] {
                    XCTAssertFalse(actions.contains(command), command)
                }
                for symbol in ["skip_previous", "play_arrow", "skip_next"] {
                    let glyph = try XCTUnwrap(widget.surface.layout.core.elements {
                        widget.text.string($0.text) == symbol
                    }.first, symbol)
                    let button = widget.surface.layout.core.parent(of: glyph)
                    XCTAssertEqual(widget.surface.layout.core.content(of: button).hover, .clear, symbol)
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: glyph))
                    let count = widget.actions.count
                    widget.surface.press(at: CGPoint(x: frame.midX, y: frame.midY))
                    widget.surface.release(at: CGPoint(x: frame.midX, y: frame.midY))
                    XCTAssertEqual(widget.actions.count, count, symbol)
                }
            } else {
                for command in ["media previous", "media toggle", "media next"] {
                    try clickCommand(command, widget: widget, context: state)
                }
            }
        }
    }

    func testExportCelestialDashboardMediaCardRenders() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["OMNIWM_STEP_DASHBOARD_RENDERS"] else {
            throw XCTSkip("Set OMNIWM_STEP_DASHBOARD_RENDERS to export Dashboard media states")
        }
        let shell = try stepShell(environment)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        for dark in [false, true] {
            let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
            resources.palette.refresh(
                theme: config.theme,
                appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            )
            let widget = try makeWidget("dashboard", config: config, shell: shell, resources: resources)
            weatherFixture(widget)
            systemStatsFixture(widget)
            calendarFixture(widget)
            widget.render(fixture(config, height: 60, vertical: false))
            for state in ["playing", "paused", "idle"] {
                mediaFixture(widget, playing: state == "playing")
                if state == "idle" { widget.set("media") { $0.null() } }
                widget.layoutPopout()
                try ShellBundledWidgetTests.writeSnapshot(
                    widget.surface, name: "dashboard-celestial-popout-\(state)-\(dark ? "dark" : "light")",
                    dark: dark, directory: directory, background: resources.palette.color(.clear, default: .background)
                )
            }
        }
    }

    func testSharedMediaPanelsDeliverControlsSeekAndLyricsThroughEverySkin() throws {
        let shell = try sharedLibraryShell("media")
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            for name in profile == "celestial" ? ["media", "control-center", "dashboard"] :
                ["media", "control-center"]
            {
                let context = "\(profile)/\(name)"
                let widget = try makeWidget(
                    name, config: config, shell: shell,
                    source: name == "dashboard" ? nil : shell
                        .appendingPathComponent("default/widgets/\(name)/init.luau")
                )
                mediaFixture(widget)
                widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
                try selectMediaTab(widget, name: name)
                let nodes = widget.renderPopout()
                if name == "control-center", ["wayline", "nocturne", "celestial"].contains(profile) {
                    let index = try XCTUnwrap(
                        nodes.firstIndex { widget.text.string($0.content.action) == "media toggle" },
                        context
                    )
                    let play = nodes[index]
                    XCTAssertEqual(play.paint.fill.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1), context)
                    XCTAssertEqual(play.paint.cornerRadius, 20, context)
                    let glyph = try XCTUnwrap(
                        nodes[(index + 1) ..< Int(play.subtreeEnd)].first { $0.kind == .symbol },
                        context
                    )
                    XCTAssertEqual(
                        glyph.content.color.role & 0xFF,
                        UInt16(ShellRole.accentForeground.rawValue + 1),
                        context
                    )
                    widget.layoutPopout()
                    let handle = try XCTUnwrap(
                        widget.surface.layout.core.elements { widget.text.string($0.action) == "media toggle" }.first,
                        context
                    )
                    let frame = widget.surface.layout.core.absoluteFrame(of: handle)
                    XCTAssertEqual(frame.width, 40, context)
                    XCTAssertEqual(frame.height, 40, context)
                }
                if profile == "wayline", name == "media" {
                    let current = try XCTUnwrap(
                        nodes.first { widget.text.string($0.content.text) == "Every window holds a song" },
                        context
                    )
                    XCTAssertEqual(current.content.color.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1), context)
                }
                for command in [
                    "media previous",
                    "media toggle",
                    "media next",
                    "media open",
                    "media shuffle",
                    "media repeat"
                ] {
                    widget.layoutPopout()
                    try clickCommand(command, widget: widget, context: context)
                }
                let sliders = nodes.filter { $0.kind == .slider }
                let slider = try XCTUnwrap(sliders.first, context)
                XCTAssertEqual(sliders.count, 1, context)
                XCTAssertEqual(slider.content.value, 407, context)
                var event = ShellEvent(button: .left)
                event.kind = .slider
                event.value = 0.5
                event.phase = .changed
                XCTAssertEqual(widget.invoke(slider.content.action, view: OMNI_VIEW_POPOUT, event: event), [], context)
                event.phase = .ended
                XCTAssertEqual(
                    widget.invoke(slider.content.action, view: OMNI_VIEW_POPOUT, event: event),
                    ["media seek 121.5"],
                    context
                )
                widget.layoutPopout()
                try clickCommand("media seek 98.0", widget: widget, context: context)
                var stats = omni_render_stats()
                var error = [CChar](repeating: 0, count: 256)
                XCTAssertEqual(
                    omni_instance_render(widget.instance, OMNI_VIEW_POPOUT, 100_000_000, &stats, &error, error.count),
                    OMNI_OK, context
                )
                let timing = ShellDataKey.seconds.bit | ShellDataKey.lyrics.bit
                XCTAssertEqual(stats.deps & timing, timing, context)
                mediaFixture(widget, shuffle: nil, repeatMode: nil)
                let unsupported = widget.renderPopout()
                let actions = unsupported.map { widget.text.string($0.content.action) }
                XCTAssertFalse(actions.contains("media shuffle"), context)
                XCTAssertFalse(actions.contains("media repeat"), context)
                mediaFixture(widget, playing: false, shuffle: true, repeatMode: .one)
                let paused = widget.renderPopout()
                let symbols = paused.filter { $0.kind == .symbol || $0.kind == .label }
                    .map { widget.text.string($0.content.text) }
                XCTAssertTrue(
                    symbols.contains(profile == "celestial" && name != "control-center" ? "play_arrow" : "play.fill"),
                    context
                )
                XCTAssertTrue(
                    symbols.contains(profile == "celestial" && name != "control-center" ? "repeat_one" : "repeat.1"),
                    context
                )
                for (lyrics, expected) in [(ShellLyrics.loading, "Loading lyrics…"), (
                    .missing,
                    "No lyrics found"
                )] {
                    mediaFixture(widget, lyrics: lyrics)
                    let state = widget.renderPopout()
                    XCTAssertTrue(
                        widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(expected, [])),
                        context
                    )
                    XCTAssertFalse(
                        state.contains { widget.text.string($0.content.action).hasPrefix("media seek ") },
                        context
                    )
                }
                widget.set("media") { $0.null() }
                widget.set("lyrics") { $0.null() }
                _ = widget.renderPopout()
                XCTAssertTrue(
                    widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Nothing is playing", [])),
                    context
                )
                if name == "media", profile == "nocturne" {
                    widget.layoutPopout()
                    let label = try XCTUnwrap(widget.surface.layout.core.elements {
                        widget.text.string($0.text) == ShellLocalizer.string("Nothing is playing", [])
                    }.first, context)
                    let frame = widget.surface.layout.core.absoluteFrame(of: label)
                    XCTAssertEqual(
                        CGFloat(frame.x + frame.width / 2),
                        widget.surface.size.width / 2,
                        accuracy: 0.5,
                        context
                    )
                }
                if name == "control-center" {
                    mediaFixture(widget)
                    widget.set("settings") { ShellServiceValue.object(["tab": .text("overview")]).write(to: &$0) }
                    let overview = widget.renderPopout()
                    XCTAssertFalse(
                        overview.contains { widget.text.string($0.content.action).hasPrefix("media seek ") },
                        context
                    )
                    XCTAssertEqual(
                        omni_instance_render(
                            widget.instance,
                            OMNI_VIEW_POPOUT,
                            100_000_000,
                            &stats,
                            &error,
                            error.count
                        ),
                        OMNI_OK, context
                    )
                    XCTAssertEqual(stats.deps & timing, 0, context)
                }
            }
        }
    }

    func testSharedMediaModelsClampProgressAndFormatLongDurations() throws {
        let shell = try sharedLibraryShell("media")
        defer { try? FileManager.default.removeItem(at: shell) }
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget("media", config: config, shell: shell)
        widget.render(fixture(config, height: 32, vertical: false))
        for (elapsed, playing, expected) in [(-50.0, false, 0), (5000.0, false, 1000), (20.0, false, 5)] {
            mediaFixture(widget, playing: playing, elapsed: elapsed, duration: 3661)
            let slider = try XCTUnwrap(widget.renderPopout().first { $0.kind == .slider })
            XCTAssertEqual(slider.content.value, UInt32(expected))
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("1:01:01"))
        }
        mediaFixture(widget, elapsed: nil)
        XCTAssertFalse(widget.renderPopout().contains { $0.kind == .slider })
        mediaFixture(widget, duration: nil)
        let unknownDuration = widget.renderPopout()
        XCTAssertFalse(unknownDuration.contains { $0.kind == .slider })
        XCTAssertEqual(
            unknownDuration.map { widget.text.string($0.content.action) }.filter { $0.hasPrefix("media seek ") },
            ["media seek 86.0", "media seek 92.0", "media seek 98.0", "media seek 104.0", "media seek 110.0"]
        )
    }

    func testSharedVolumeBarsKeepInputAndAvoidOutputAndAppDemand() throws {
        let shell = try sharedAudioShell()
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in try barHostingProfiles(in: shell) {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let height = config.barOverride?.settings.height ?? 32
            let widget = try makeWidget(
                "volume", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/volume/init.luau")
            )
            audioFixture(widget, access: .granted)
            for vertical in [false, true] {
                for backgrounds in [false, true] {
                    var bar = fixture(config, height: height, vertical: vertical)
                    bar.style.backgrounds = backgrounds
                    widget.render(bar)
                    let context = "\(profile) vertical=\(vertical) backgrounds=\(backgrounds)"
                    var stats = omni_render_stats()
                    var error = [CChar](repeating: 0, count: 256)
                    XCTAssertEqual(
                        omni_instance_render(widget.instance, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count),
                        OMNI_OK, context
                    )
                    XCTAssertEqual(stats.deps & (ShellDataKey.outputs.bit | ShellDataKey.audioApps.bit), 0, context)
                    XCTAssertEqual(
                        stats.deps & (ShellDataKey.volume.bit | ShellDataKey.muted.bit),
                        ShellDataKey.volume.bit | ShellDataKey.muted.bit, context
                    )
                    XCTAssertLessThanOrEqual(
                        vertical ? widget.surface.size.width : widget.surface.size.height,
                        height,
                        profile
                    )
                    let button = try XCTUnwrap(
                        widget.surface.layout.core.elements { $0.action == OMNI_ACTION_POPOUT }.first,
                        profile
                    )
                    let content = widget.surface.layout.core.content(of: button)
                    XCTAssertEqual(widget.text.string(content.help), ShellLocalizer.string("Volume", []), profile)
                    XCTAssertNotEqual(content.scrollAction, 0, profile)
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                    let point = CGPoint(x: frame.midX, y: frame.midY)
                    widget.surface.press(at: point)
                    widget.surface.release(at: point)
                    XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT, profile)
                }
            }
            let action = try XCTUnwrap(
                widget.tree().first { $0.content.scrollAction != 0 }?.content.scrollAction,
                profile
            )
            let scroll = { (dy: Double, precise: Bool) in
                var event = ShellEvent(button: .none)
                event.dy = dy
                event.precise = precise
                return widget.invoke(action, event: event)
            }
            let step = profile == "celestial" ? "5" : "6.25"
            XCTAssertEqual(scroll(5, true), [], profile)
            XCTAssertEqual(scroll(-14, true), ["volume down \(step)"], profile)
            XCTAssertEqual(scroll(8, true), [], profile)
            XCTAssertEqual(scroll(8, true), ["volume up \(step)"], profile)
            for volume in [0.0, 62.0] {
                widget.set("volume") { $0.number(volume) }
                widget.set("muted") { $0.bool(true) }
                widget.render(fixture(config, height: height, vertical: false))
                XCTAssertGreaterThan(widget.surface.size.width, 0, profile)
            }
            widget.set("volume") { $0.null() }
            widget.render(fixture(config, height: height, vertical: false))
            if profile == "celestial" {
                XCTAssertEqual(widget.surface.size, .zero, profile)
            } else {
                XCTAssertGreaterThan(widget.surface.size.width, 0, profile)
            }
        }
    }

    func testSharedAudioPanelsDeliverSlidersMutesOutputsAndPermissionThroughEverySkin() throws {
        let shell = try sharedAudioShell()
        defer { try? FileManager.default.removeItem(at: shell) }
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            for name in profile == "celestial" ? ["volume", "control-center", "status"] : ["volume", "control-center"] {
                let context = "\(profile)/\(name)"
                let widget = try makeWidget(
                    name, config: config, shell: shell,
                    source: name == "volume" ? shell.appendingPathComponent("default/widgets/volume/init.luau") : nil
                )
                if name == "control-center" {
                    widget.set("settings") { ShellServiceValue.object(["tab": .text("audio")]).write(to: &$0) }
                }
                widget.render(fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false))
                audioFixture(widget, access: .granted)
                let sliders = widget.renderPopout().filter { $0.kind == .slider }
                XCTAssertEqual(sliders.map(\.content.value), [620, 800, 1000, 450], context)
                for (slider, command) in zip(sliders, [
                    "volume set 0",
                    "volume app com.apple.Music set 0",
                    "volume app com.apple.Safari set 0",
                    "volume app com.apple.Podcasts set 0"
                ]) {
                    var event = ShellEvent(button: .left)
                    event.kind = .slider
                    event.phase = .changed
                    event.value = 0
                    XCTAssertEqual(
                        widget.invoke(slider.content.action, view: OMNI_VIEW_POPOUT, event: event),
                        [command],
                        context
                    )
                    event.value = 0.754
                    XCTAssertEqual(
                        widget.invoke(slider.content.action, view: OMNI_VIEW_POPOUT, event: event),
                        [command.replacingOccurrences(of: "set 0", with: "set 75")],
                        context
                    )
                }
                widget.layoutPopout()
                for command in [
                    "volume mute",
                    "volume output 41",
                    "volume output 42",
                    "volume output 43",
                    "volume app com.apple.Music mute",
                    "volume app com.apple.Safari mute",
                    "volume app com.apple.Podcasts mute"
                ] {
                    try clickCommand(command, widget: widget, context: context)
                }
                var stats = omni_render_stats()
                var error = [CChar](repeating: 0, count: 256)
                XCTAssertEqual(
                    omni_instance_render(widget.instance, OMNI_VIEW_POPOUT, 100_000_000, &stats, &error, error.count),
                    OMNI_OK
                )
                let demand = ShellDataKey.outputs.bit | ShellDataKey.audioApps.bit
                XCTAssertEqual(stats.deps & demand, demand, context)
                audioFixture(widget, access: .denied)
                XCTAssertEqual(widget.renderPopout().filter { $0.kind == .slider }.count, 1, context)
                widget.layoutPopout()
                try clickCommand("volume permission", widget: widget, context: context)
                widget.set("volume") { $0.null() }
                widget.set("outputs") { $0.null() }
                widget.set("audioApps") { $0.null() }
                XCTAssertFalse(widget.renderPopout().contains { $0.kind == .slider }, context)
                let unavailable = widget.strings(OMNI_VIEW_POPOUT)
                if profile == "nocturne", name == "volume" {
                    XCTAssertTrue(unavailable.contains("—"), context)
                    XCTAssertTrue(unavailable.contains(ShellLocalizer.string("Volume", [])), context)
                } else {
                    XCTAssertTrue(unavailable.contains(ShellLocalizer.string("Unavailable", [])), context)
                }
            }
        }
    }

    func testCelestialAudioPermissionTextFitsInsideItsAction() throws {
        let shell = try sharedAudioShell()
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        for name in ["volume", "status"] {
            let widget = try makeWidget(
                name, config: config, shell: shell,
                source: name == "volume" ? shell.appendingPathComponent("default/widgets/volume/init.luau") : nil
            )
            widget.render(fixture(config, height: 60, vertical: false))
            audioFixture(widget, access: .denied)
            widget.layoutPopout()
            let action = try XCTUnwrap(widget.surface.layout.core.elements {
                widget.text.string($0.action) == "volume permission"
            }.first, name)
            let label = try XCTUnwrap(widget.surface.layout.core.elements {
                widget.text.string($0.text) == ShellLocalizer.string(
                    "Allow System Audio Recording to set app volumes",
                    []
                )
            }.first, name)
            let actionFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: action))
            let labelFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: label))
            XCTAssertGreaterThanOrEqual(labelFrame.minX, actionFrame.minX, name)
            XCTAssertLessThanOrEqual(labelFrame.maxX, actionFrame.maxX, name)
            XCTAssertGreaterThanOrEqual(labelFrame.minY, actionFrame.minY, name)
            XCTAssertLessThanOrEqual(labelFrame.maxY, actionFrame.maxY, name)
            let content = widget.surface.layout.core.content(of: label)
            XCTAssertGreaterThanOrEqual(labelFrame.width, CGFloat(content.maxWidth), name)
            let font = ShellTextStyle.font(for: content.style)
            let text = NSAttributedString(
                string: widget.text.string(content.text),
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let lines = ShellTextStyle.wrappedLines(
                text, width: min(labelFrame.width, CGFloat(content.maxWidth)), limit: Int.max
            )
            XCTAssertLessThanOrEqual(lines.count, Int(content.lines), name)
            XCTAssertLessThanOrEqual(ShellTextStyle.wrappedSize(of: lines, font: font).height, labelFrame.height, name)
            try clickCommand("volume permission", widget: widget, context: name)
        }
    }

    func testSharedSystemStatsKeepsApprovedDataAndPartialLoadingThroughEverySkin() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let widget = try makeWidget(
                "system-stats", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/system-stats/init.luau")
            )
            widget.resources.palette.refresh(theme: config.theme, appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
            var bar = fixture(config, height: 32, vertical: false)
            bar.style.statsButton = false
            widget.render(bar)
            XCTAssertFalse(widget.tree().contains { $0.content.action == OMNI_ACTION_POPOUT }, profile)
            bar.style.statsButton = true
            for vertical in [false, true] {
                bar.style.vertical = vertical
                widget.render(bar)
                let button = try XCTUnwrap(
                    widget.surface.layout.core.elements { $0.action == OMNI_ACTION_POPOUT }.first,
                    profile
                )
                let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                XCTAssertLessThanOrEqual(frame.height, 32, profile)
                var popoutAction: UInt32 = 0
                widget.surface.onAction = { popoutAction = $0.action }
                let point = CGPoint(x: frame.midX, y: frame.midY)
                widget.surface.press(at: point, event: ShellEvent(button: .left))
                widget.surface.release(at: point, event: ShellEvent(button: .left))
                XCTAssertEqual(popoutAction, OMNI_ACTION_POPOUT, profile)
            }
            bar.style.vertical = false
            widget.render(bar)
            systemStatsFixture(widget)
            let tree = widget.renderPopout()
            let labels = tree.filter { $0.kind == .label }.map { widget.text.string($0.content.text) }
            let memory = { ShellFormatter.string(kind: OMNI_FORMAT_MEMORY, $0, digits: 0) }
            let file = { ShellFormatter.string(kind: OMNI_FORMAT_FILE, $0, digits: 0) }
            for value in [
                "studio", "Apple M4 Max", "Apple M4 Max GPU", "Mac16,9", "Version 27.2",
                "61°C", "48°C", percent(0.37), percent(0.18), percent(0.76),
                memory(Double(21 << 30)), memory(Double(36 << 30)),
                file(612_000_000_000), file(994_000_000_000),
                file(1_840_000) + "/s", file(312_000) + "/s", file(18_400_000_000), file(2_100_000_000),
                ShellLocalizer.string("%lldh %lldm", [.number(4), .number(14)])
            ] {
                XCTAssertTrue(labels.contains { $0.contains(value) }, "\(profile): missing \(value): \(labels)")
            }
            let paths = Set(tree.filter { $0.kind == .path }.map { widget.text.string($0.content.text) })
            widget.set("networkHistory") { $0.null() }
            let withoutHistory = widget.renderPopout()
            let remainingPaths = Set(withoutHistory.filter { $0.kind == .path }.map {
                widget.text.string($0.content.text)
            })
            XCTAssertGreaterThanOrEqual(
                paths.subtracting(remainingPaths).count,
                2,
                "\(profile): no graph paths removed"
            )
            XCTAssertTrue(remainingPaths.isSubset(of: paths), "\(profile): unrelated graph paint changed")
            XCTAssertFalse(labels.contains(ShellLocalizer.string("Collecting data…", [])), profile)
            XCTAssertTrue(
                widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Collecting data…", [])),
                profile
            )
            systemStatsFixture(widget)
            widget.set("thermal") { ShellThermal(cpu: 90, gpu: 48, gpuName: "Apple M4 Max GPU").write(into: &$0) }
            let cool = try XCTUnwrap(widget.renderPopout().first {
                widget.text.string($0.content.text) == (profile == "celestial" ? "thermometer" : "90°C")
            }, profile)
            widget.set("thermal") { ShellThermal(cpu: 91, gpu: 48, gpuName: "Apple M4 Max GPU").write(into: &$0) }
            let hot = try XCTUnwrap(widget.renderPopout().first {
                widget.text.string($0.content.text) == (profile == "celestial" ? "thermometer_alert" : "91°C")
            }, profile)
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("91°C"), profile)
            XCTAssertNotEqual(cool.content.color, hot.content.color, profile)
            widget.set("battery") { $0.null() }
            widget.layoutPopout()
            let noBattery = widget.strings(OMNI_VIEW_POPOUT)
            XCTAssertFalse(noBattery.contains(ShellLocalizer.string("Battery", [])), profile)
            if profile == "celestial" {
                XCTAssertEqual(widget.surface.naturalSize.width, 860, profile)
            }
            try exportSystemStatsState(widget, profile: profile, state: "no-battery-hot")
            for key in ["system", "gpu", "memory", "disk", "thermal", "networkHistory"] {
                widget.set(key) { $0.null() }
            }
            widget.layoutPopout()
            let partial = widget.strings(OMNI_VIEW_POPOUT)
            XCTAssertTrue(partial.contains(percent(0.37)), profile)
            XCTAssertTrue(partial.contains(profile == "celestial" ? percent(0) : "—"), profile)
            XCTAssertTrue(partial.contains(ShellLocalizer.string("Loading…", [])), profile)
            XCTAssertTrue(partial.contains(ShellLocalizer.string("Collecting data…", [])), profile)
            try exportSystemStatsState(widget, profile: profile, state: "partial")
        }
    }

    func testSharedCelestialStatsButtonKeepsTheSurfacePillGeometry() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        let probe = shell.appendingPathComponent("celestial/widgets/stats-pill-reference/init.luau")
        try FileManager.default.createDirectory(
            at: probe.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        local surface = require("../lib/surface")
        function render(ctx)
            local style = ctx.data.bar.style
            return surface.pill(style, { surface.icon("monitoring", { size = 24 * style.height / 60 }) })
        end
        """.write(to: probe, atomically: true, encoding: .utf8)
        let reference = try makeWidget("stats-pill-reference", config: config, shell: shell, source: probe)
        let widget = try makeWidget(
            "system-stats", config: config, shell: shell,
            source: shell.appendingPathComponent("default/widgets/system-stats/init.luau")
        )
        for height in [32.0, 60] {
            for vertical in [false, true] {
                let bar = fixture(config, height: height, vertical: vertical)
                widget.render(bar)
                reference.render(bar)
                XCTAssertEqual(widget.surface.size.width, reference.surface.size.width, accuracy: 0.001)
                XCTAssertEqual(widget.surface.size.height, reference.surface.size.height, accuracy: 0.001)
            }
        }
    }

    func testSharedStatsBatteryReflectsLevelAndChargingAndWaylineRingsAlign() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ["default", "wayline", "nocturne"] {
            _ = try ShellProfiles.select(profile, in: shell)
            let config = ShellConfig.resolve(shellDirectory: shell)
            XCTAssertEqual(config.profile, profile)
            let widget = try makeWidget(
                "system-stats", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/system-stats/init.luau")
            )
            widget.render(fixture(config, height: 32, vertical: false))
            systemStatsFixture(widget)
            var lowColor: Color?
            for (level, charging, symbol) in [
                (10.0, false, "battery.0percent"),
                (76.0, false, "battery.75percent"),
                (10.0, true, "battery.100percent.bolt")
            ] {
                widget.set("battery") { $0.number(level) }
                widget.set("charging") { $0.bool(charging) }
                let tree = widget.renderPopout()
                XCTAssertTrue(
                    tree.contains { $0.kind == .symbol && widget.text.string($0.content.text) == symbol },
                    profile
                )
                let bar = try XCTUnwrap(tree.last { $0.kind == .progress }, profile)
                XCTAssertEqual(bar.content.value, UInt32(level * 10), profile)
                if level == 10, !charging {
                    lowColor = bar.content.color
                } else {
                    XCTAssertNotEqual(lowColor, bar.content.color, profile)
                }
            }
            if profile == "wayline" {
                widget.layoutPopout()
                let positions = try ["CPU", "GPU", "Memory", "Disk"].map { title in
                    let labels = widget.surface.layout.core.elements {
                        widget.text.string($0.text) == ShellLocalizer.string(title, [])
                    }
                    return try XCTUnwrap(labels.map { widget.surface.layout.core.absoluteFrame(of: $0).y }.min(), title)
                }
                for position in positions.dropFirst() {
                    XCTAssertEqual(position, positions[0], accuracy: 0.001)
                }
            }
        }
    }

    func testSharedNocturneStatsKeepsUniformFrameInsets() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("nocturne", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        for position in ["top", "bottom", "left"] {
            let widget = try makeWidget(
                "system-stats", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/system-stats/init.luau")
            )
            var bar = fixture(config, height: 32, vertical: position == "left")
            bar.style.position = position
            widget.render(bar)
            systemStatsFixture(widget)
            widget.layoutPopout()
            let elements = widget.surface.layout.core.elements { _ in true }
            let body = try XCTUnwrap(elements.first {
                let paint = widget.surface.layout.core.paint(of: $0)
                return paint.cornerRadius == 18 && paint.strokeWidth == 1
            }, position)
            var bounds = CGRect(widget.surface.layout.core.absoluteFrame(of: body))
            if position == "top" {
                bounds.origin.y += 14
                bounds.size.height -= 14
            } else if position == "bottom" {
                bounds.size.height -= 14
            }
            let apple = try XCTUnwrap(elements
                .first { widget.text.string(widget.surface.layout.core.content(of: $0).text) == "applelogo" })
            let header = widget.surface.layout.core.parent(of: widget.surface.layout.core.parent(of: apple))
            let headerFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: header))
            XCTAssertEqual(headerFrame.minX - bounds.minX, 12, accuracy: 0.5, position)
            XCTAssertEqual(headerFrame.minY - bounds.minY, 12, accuracy: 0.5, position)
            var footer = try XCTUnwrap(elements.first {
                widget.text.string(widget.surface.layout.core.content(of: $0).text).hasPrefix("Mac16,9")
            })
            while footer.slot >= 0, widget.surface.layout.core.paint(of: footer).cornerRadius != 14 {
                footer = widget.surface.layout.core.parent(of: footer)
            }
            XCTAssertGreaterThanOrEqual(footer.slot, 0, position)
            let footerFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: footer))
            XCTAssertEqual(bounds.maxX - footerFrame.maxX, 12, accuracy: 0.5, position)
            XCTAssertEqual(bounds.maxY - footerFrame.maxY, 12, accuracy: 0.5, position)
        }
    }

    func testSharedSystemStatsKeepsItsFittedScrollingSurfaceThroughEverySkin() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            for position in ["top", "bottom", "left"] {
                let context = "\(profile) \(position)"
                let widget = try makeWidget(
                    "system-stats", config: config, shell: shell,
                    source: shell.appendingPathComponent("default/widgets/system-stats/init.luau")
                )
                widget.resources.palette.refresh(
                    theme: config.theme,
                    appearance: try XCTUnwrap(NSAppearance(named: .aqua))
                )
                var bar = fixture(config, height: 32, vertical: position == "left")
                bar.style.position = position
                widget.render(bar)
                systemStatsFixture(widget)
                widget.layoutPopout()
                if profile == "nocturne", position != "top" {
                    try exportSystemStatsState(widget, profile: profile, state: position)
                }
                let natural = widget.surface.naturalSize
                let fitted = CGSize(width: natural.width, height: 180)
                XCTAssertGreaterThan(natural.height, fitted.height, context)
                widget.surface.setRootLimit(fitted)
                XCTAssertEqual(widget.surface.size, fitted, context)
                let scroll = try XCTUnwrap(widget.surface.layout.core.elements { $0.scrolls }.first, context)
                let viewport = CGRect(widget.surface.layout.core.absoluteFrame(of: scroll))
                XCTAssertTrue(CGRect(origin: .zero, size: fitted).contains(viewport), context)
                XCTAssertTrue(widget.surface.scroll(
                    at: CGPoint(x: viewport.midX, y: viewport.midY), event: ShellEvent(button: .none),
                    content: CGPoint(x: 0, y: 10_000)
                ), context)
                ShellLayerScene.engineQueue.sync {}
                let scrolled = try XCTUnwrap(widget.layers().first { $0.bounds.origin.y > 0 }, context)
                let bottom = try XCTUnwrap(scrolled.sublayers?.map(\.frame.maxY).max(), context)
                XCTAssertEqual(scrolled.bounds.height, viewport.height, accuracy: 0.5, context)
                XCTAssertEqual(scrolled.bounds.origin.y, bottom + 16 - viewport.height, accuracy: 0.5, context)
            }
        }
    }

    func testEveryBundledProfileKeepsNativeWorkspaceContractsThroughItsEffectiveConfiguration() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let installed = ShellProfiles.names(in: shell)
        XCTAssertEqual(installed, [ShellDefaults.profile] + (try ShellStyleFixture.names()))
        for profile in Set(installed + ["default"]).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let height = config.barOverride?.settings.height ?? 32
            for vertical in [false, true] {
                for labels in [false, true] {
                    let context = "\(profile) vertical=\(vertical) labels=\(labels)"
                    let widget = try makeWidget("workspaces", config: config, shell: shell)
                    var bar = fixture(config, height: height, vertical: vertical)
                    bar.style.labels = labels
                    widget.render(bar)
                    for item in bar.workspaces.flatMap(\.windows) {
                        let icon = try XCTUnwrap(widget.surface.layout.core.elements {
                            $0.iconSource == .window && widget.text.string($0.iconRef) == item.id
                        }.first, "\(context): no window icon for \(item.id)")
                        var target = icon
                        while target.slot >= 0 {
                            let content = widget.surface.layout.core.content(of: target)
                            if widget.text.string(content.target) == "window \(item.id)",
                               content.menu, content.drag, content.preview || content.opensPopout { break }
                            target = widget.surface.layout.core.parent(of: target)
                        }
                        XCTAssertGreaterThanOrEqual(
                            target.slot,
                            0,
                            "\(context): icon \(item.id) lost its native controls"
                        )
                    }
                    for workspace in bar.workspaces {
                        let pill = try XCTUnwrap(widget.surface.layout.core.elements {
                            $0.menu && $0.drop && widget.text.string($0.target) == "workspace \(workspace.id)"
                        }.first, "\(context): no pill for workspace \(workspace.id)")
                        XCTAssertEqual(
                            widget.text.string(widget.surface.layout.core.content(of: pill).action),
                            "switch-workspace \(workspace.id)",
                            context
                        )
                    }
                }
            }
        }
    }

    func testScratchpadIconCountMatchesTheResolvedConfiguration() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let cases = [("nan", 0), ("\"4\"", 3), ("inf", 6), ("2.7", 2), ("9", 6), ("-1", 0), ("5", 5)]
        for (value, expected) in cases {
            try Data("[profiles.default.widgets.scratchpads]\nshownWindows = \(value)\n".utf8)
                .write(to: shell.appendingPathComponent("shell.toml"))
            let config = ShellConfig.resolve(shellDirectory: shell)
            XCTAssertEqual(config.scratchpadIcons, expected, value)
            let widget = try makeWidget("scratchpads", config: config, shell: shell)
            var bar = fixture(config, height: 32, vertical: false)
            bar.scratchpads = [ShellBarScratchpad(
                id: 1, name: "Notes", focused: false, revealed: false, visible: true,
                windows: (0 ..< 7).map { index in
                    ShellBarItem(
                        id: "\(index)", bundle: "", name: "App \(index)", focused: false, count: 1, hidden: 0,
                        windows: [ShellBarWindow(id: "w\(index)", title: "Window", focused: false, hidden: false)]
                    )
                }
            )]
            widget.render(bar)
            let tree = widget.tree()
            XCTAssertEqual(
                tree.filter { $0.kind == .image && $0.content.iconSource == .window }.count,
                config.scratchpadIcons,
                value
            )
            XCTAssertTrue(
                tree.contains { widget.text.string($0.content.text) == "+\(7 - config.scratchpadIcons)" },
                value
            )
        }
    }

    func testOmniWMButtonUsesAValidConfiguredIconColor() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let terracotta: UInt32 = 0xB665_45FF
        let cases: [String: UInt32] = [
            "\"#1E90FF\"": 0x1E90_FFFF, "\"#1E90FF80\"": 0x1E90_FF80, "\"#1E90F\"": terracotta,
            "\"#1E90FX\"": terracotta, "\"#GG90FF\"": terracotta, "\"blue\"": terracotta, "3": terracotta
        ]
        for (value, expected) in cases {
            try Data("[profiles.default.widgets.omniwm]\niconColor = \(value)\n".utf8)
                .write(to: shell.appendingPathComponent("shell.toml"))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let widget = try makeWidget("omniwm", config: config, shell: shell)
            widget.render(fixture(config, height: 32, vertical: false))
            let logo = try XCTUnwrap(widget.tree().first {
                $0.kind == .symbol && widget.text.string($0.content.text) == "omniwm"
            }, value)
            XCTAssertEqual(logo.content.color, Color(packed: expected), value)
        }
    }

    func testOccupiedHighlightReachesSkinnedWorkspacePills() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ["wayline", "nocturne"] {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let widget = try makeWidget(
                "workspaces", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/workspaces/init.luau")
            )
            var bar = fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: false)
            bar.style.backgrounds = true
            let fills = { (highlight: Bool) -> [String: Color] in
                widget.set("settings") {
                    $0.map(2)
                    $0.key("indicator")
                    $0.string("pills")
                    $0.key("occupiedBackground")
                    $0.bool(highlight)
                }
                widget.render(bar)
                return Dictionary(uniqueKeysWithValues: widget.tree().filter(\.content.drop).map {
                    (widget.text.string($0.content.target), $0.paint.fill)
                })
            }
            let off = fills(false)
            let on = fills(true)
            XCTAssertNotEqual(on["workspace 2"], off["workspace 2"], profile)
            XCTAssertEqual(on["workspace 1"], off["workspace 1"], profile)
            XCTAssertEqual(on["workspace 3"], off["workspace 3"], profile)
        }
    }

    func testSharedWorkspaceSkinsKeepInputFocusAndIndicatorContracts() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in try barHostingProfiles(in: shell) {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            for vertical in [false, true] {
                let widget = try makeWidget(
                    "workspaces", config: config, shell: shell,
                    source: shell.appendingPathComponent("default/widgets/workspaces/init.luau")
                )
                var bar = fixture(config, height: config.barOverride?.settings.height ?? 32, vertical: vertical)
                bar.style.accents = true
                for labels in [false, true] {
                    bar.style.labels = labels
                    for indicator in ["pills", "underline", "dots", "numbers", "minimal"] {
                        let context = "\(profile) vertical=\(vertical) labels=\(labels) indicator=\(indicator)"
                        widget.set("settings") {
                            $0.map(1)
                            $0.key("indicator")
                            $0.string(indicator)
                        }
                        widget.render(bar)
                        XCTAssertLessThanOrEqual(
                            vertical ? widget.surface.size.width : widget.surface.size.height,
                            bar.style.height,
                            context
                        )
                        let tree = widget.tree()
                        let focused = try XCTUnwrap(tree.first { widget.text.string($0.content.target) == "window 0" })
                        XCTAssertEqual(focused.paint.scale, 1.1, context)
                        let glyph = try XCTUnwrap(tree
                            .first { $0.content.iconSource == .window && widget.text.string($0.content.iconRef) == "0"
                            })
                        XCTAssertTrue(glyph.paint.shadow.isVisible, context)
                        for workspace in bar.workspaces {
                            let pill = try XCTUnwrap(tree
                                .first {
                                    $0.content.drop && widget.text.string($0.content.target) == "workspace \(workspace.id)"
                                })
                            XCTAssertTrue(pill.content.menu, context)
                            XCTAssertEqual(
                                widget.text.string(pill.content.action),
                                "switch-workspace \(workspace.id)",
                                context
                            )
                        }
                        let single = try XCTUnwrap(widget.surface.layout.core.elements {
                            $0.drag && widget.text.string($0.target) == "window 0"
                        }.first)
                        let singleFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: single))
                        let point = CGPoint(x: singleFrame.midX, y: singleFrame.midY)
                        widget.surface.press(at: point)
                        widget.surface.release(at: point)
                        XCTAssertEqual(widget.clicks.last?.action, "window focus 0", context)
                        let grouped = try XCTUnwrap(tree.first { widget.text.string($0.content.target) == "window 1" })
                        XCTAssertTrue(
                            grouped.content.menu && grouped.content.drag && grouped.content.preview && grouped.content
                                .opensPopout,
                            context
                        )
                        widget.invoke(grouped.content.action)
                        widget.layoutPopout()
                        let row = try XCTUnwrap(widget.surface.layout.core.elements {
                            widget.text.string($0.action) == "window focus 1_0"
                        }.first)
                        let rowFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: row))
                        let rowPoint = CGPoint(x: rowFrame.midX, y: rowFrame.midY)
                        widget.surface.press(at: rowPoint)
                        widget.surface.release(at: rowPoint)
                        XCTAssertEqual(widget.clicks.last?.action, "window focus 1_0", context)
                        let close = try XCTUnwrap(widget.surface.layout.core
                            .elements { $0.action == OMNI_ACTION_POPOUT }.first)
                        let closeFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: close))
                        let closePoint = CGPoint(x: closeFrame.midX, y: closeFrame.midY)
                        widget.surface.press(at: closePoint)
                        widget.surface.release(at: closePoint)
                        XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT, context)
                    }
                }
                widget.set("settings") {
                    $0.map(1)
                    $0.key("indicator")
                    $0.string("pills")
                }
                bar.style.backgrounds = false
                widget.render(bar)
                if profile == "wayline" {
                    XCTAssertTrue(try XCTUnwrap(widget.tree()
                            .first { $0.content.drop && widget.text.string($0.content.target) == "workspace 1" }).paint
                                                .stroke.isVisible)
                }
                bar.style.accents = false
                bar.drag = ShellBarDrag(sources: ["1"], workspaces: ["3"], icons: ["0"])
                widget.render(bar)
                let dragged = widget.tree()
                XCTAssertEqual(
                    try XCTUnwrap(dragged.first { widget.text.string($0.content.target) == "window 0" }).paint
                        .strokeWidth,
                    1.5
                )
                XCTAssertEqual(
                    try XCTUnwrap(dragged
                        .first { $0.content.drop && widget.text.string($0.content.target) == "workspace 3" }).paint
                                            .strokeWidth,
                    1.5
                )
                XCTAssertEqual(
                    try XCTUnwrap(dragged
                        .first { $0.content.iconSource == .window && widget.text.string($0.content.iconRef) == "1" })
                        .paint.opacity,
                    0.35
                )
                bar.drag = nil
                widget.set("settings") {
                    $0.map(1)
                    $0.key("compact")
                    $0.bool(true)
                }
                bar.style.labels = false
                widget.render(bar)
                XCTAssertFalse(widget.tree().contains { $0.content.iconSource == .window && $0.kind == .image })
                bar.island = .active
                widget.render(bar)
                XCTAssertEqual(
                    Set(widget.surface.targetFrames().map { widget.text.string($0.target) }),
                    ["workspace 1"]
                )
                bar.island = .secondary
                widget.render(bar)
                XCTAssertEqual(
                    Set(widget.surface.targetFrames().map { widget.text.string($0.target) }),
                    ["workspace 2", "workspace 3"]
                )
            }
        }
    }

    func testSharedScratchpadSkinsKeepToggleFocusLabelsAndBadges() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in try barHostingProfiles(in: shell) {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let base = config.barOverride?.settings.height ?? 32
            for vertical in [false, true] {
                let widget = try makeWidget(
                    "scratchpads", config: config, shell: shell,
                    source: shell.appendingPathComponent("default/widgets/scratchpads/init.luau")
                )
                var menuTargets: [String] = []
                let strings = widget.text
                widget.surface.onMenu = { menuTargets.append(strings.string($0.target)) }
                for height in [base, base * 1.5] {
                    for compact in [false, true] {
                        var bar = scratchpadFixture(config, height: height, vertical: vertical)
                        bar.style.inactive = 0.27
                        bar.scratchpads = bar.scratchpads.map {
                            ShellBarScratchpad(
                                id: $0.id,
                                name: $0.name,
                                focused: $0.focused,
                                revealed: $0.revealed,
                                visible: $0.visible,
                                windows: $0.windows,
                                compact: compact
                            )
                        }
                        var size: CGSize?
                        for mode in ["off", "dot", "text"] {
                            let context = "\(profile) vertical=\(vertical) compact=\(compact) height=\(height) badges=\(mode)"
                            bar.badges = mode
                            bar.style.accents = true
                            widget.render(bar)
                            let currentSize = widget.surface.size
                            XCTAssertGreaterThan(currentSize.width, 0, context)
                            XCTAssertGreaterThan(currentSize.height, 0, context)
                            XCTAssertLessThanOrEqual(vertical ? currentSize.width : currentSize.height, height, context)
                            if let size { XCTAssertEqual(currentSize, size, context) }
                            size = currentSize
                            let tree = widget.tree()
                            XCTAssertEqual(
                                Set(tree.filter { $0.content.menu }.map { widget.text.string($0.content.target) }),
                                ["scratchpad 1", "scratchpad 2", "scratchpad 3"],
                                context
                            )
                            for scratchpad in bar.scratchpads {
                                let button = try XCTUnwrap(widget.surface.layout.core.elements {
                                    widget.text.string($0.target) == "scratchpad \(scratchpad.id)"
                                }.first, context)
                                let content = widget.surface.layout.core.content(of: button)
                                XCTAssertTrue(content.menu, context)
                                XCTAssertFalse(widget.text.string(content.help).isEmpty, context)
                                XCTAssertEqual(
                                    widget.text.string(content.action),
                                    "scratchpad toggle \(scratchpad.id)",
                                    context
                                )
                                let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                                let point = CGPoint(x: frame.midX, y: frame.midY)
                                widget.surface.press(at: point)
                                widget.surface.release(at: point)
                                XCTAssertEqual(
                                    widget.clicks.last?.action,
                                    "scratchpad toggle \(scratchpad.id)",
                                    context
                                )
                                XCTAssertTrue(widget.surface.openContextMenu(at: point, option: false), context)
                                XCTAssertEqual(menuTargets.last, "scratchpad \(scratchpad.id)", context)
                            }
                            let focused = try XCTUnwrap(tree
                                .first { widget.text.string($0.content.target) == "scratchpad 1" })
                            XCTAssertEqual(focused.paint.scale, 1.04, context)
                            XCTAssertTrue(focused.paint.stroke.isVisible, context)
                            XCTAssertEqual(focused.paint.strokeWidth, 1.2, context)
                            let label = try XCTUnwrap(tree.first {
                                $0.kind == .label && widget.text
                                    .string($0.content.text) == (vertical ? "T" : "Terminal sessions")
                            }, context)
                            if compact, !vertical {
                                XCTAssertEqual(
                                    label.content.maxWidth,
                                    Float(WorkspaceBarScratchpadLayout.compactLabelMaximumWidth),
                                    context
                                )
                                let attributes: [NSAttributedString.Key: Any] = [
                                    NSAttributedString.Key(kCTFontAttributeName as String): ShellTextStyle
                                        .font(for: label.content.style)
                                ]
                                let line = CTLineCreateWithAttributedString(NSAttributedString(
                                    string: "Terminal sessions",
                                    attributes: attributes
                                ))
                                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(
                                    string: "…",
                                    attributes: attributes
                                ))
                                let truncated = try XCTUnwrap(
                                    CTLineCreateTruncatedLine(line, Double(label.content.maxWidth), .end, ellipsis),
                                    context
                                )
                                XCTAssertGreaterThan(
                                    CTLineGetGlyphCount(truncated),
                                    CTLineGetGlyphCount(ellipsis),
                                    context
                                )
                            }
                            let shown = config.scratchpadIcons
                            let shownIcons = (0 ..< min(shown, 5)).map(String.init) + (shown > 0 ? ["3", "4"] : [])
                            let labels = tree.filter { $0.kind == .label }.map { widget.text.string($0.content.text) }
                            XCTAssertTrue(labels.contains(compact ? "6" : "+\(5 - shown)"), context)
                            XCTAssertEqual(labels.contains("999+"), !compact && mode == "text" && shown > 2, context)
                            let icons = tree.filter { $0.kind == .image && $0.content.iconSource == .window }
                            XCTAssertEqual(icons.count, compact ? 0 : shownIcons.count, context)
                            if !compact {
                                XCTAssertEqual(
                                    icons.map { widget.text.string($0.content.iconRef) },
                                    shownIcons,
                                    context
                                )
                                XCTAssertEqual(
                                    icons.map(\.paint.opacity),
                                    [1] + Array(repeating: 0.27, count: shownIcons.count - 1),
                                    context
                                )
                            }
                        }
                        bar.style.accents = false
                        widget.render(bar)
                    }
                }
                var bar = scratchpadFixture(config, height: base, vertical: vertical)
                bar.island = .active
                widget.render(bar)
                XCTAssertEqual(widget.surface.size, .zero, profile)
                bar.island = .secondary
                widget.render(bar)
                XCTAssertFalse(widget.surface.layout.core.elements { $0.menu && $0.target != 0 }.isEmpty, profile)
                bar.scratchpads = []
                widget.render(bar)
                XCTAssertEqual(widget.surface.size, .zero, profile)
            }
        }
    }

    func testSharedOmniWMButtonsKeepMenuSecureInputAndKeyboardModeContracts() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let states: [(locked: Bool, backgrounds: Bool, mode: KeyboardModeKind)] = [
            (false, false, .normal), (true, false, .normal),
            (false, true, .normal), (true, true, .normal),
            (false, false, .prefix), (true, true, .paused), (false, true, .window)
        ]
        for profile in try barHostingProfiles(in: shell) {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let base = config.barOverride?.settings.height ?? 32
            for vertical in [false, true] {
                let widget = try makeWidget(
                    "omniwm", config: config, shell: shell,
                    source: shell.appendingPathComponent("default/widgets/omniwm/init.luau")
                )
                for height in [base, base * 1.5] {
                    for state in states {
                        let context = "\(profile) vertical=\(vertical) height=\(height) locked=\(state.locked) backgrounds=\(state.backgrounds) mode=\(state.mode.rawValue)"
                        var bar = fixture(config, height: height, vertical: vertical)
                        bar.style.secureInput = state.locked
                        bar.style.backgrounds = state.backgrounds
                        bar.style.keyboardMode = state.mode.rawValue
                        widget.render(bar)
                        XCTAssertGreaterThan(widget.surface.size.width, 0, context)
                        XCTAssertGreaterThan(widget.surface.size.height, 0, context)
                        XCTAssertLessThanOrEqual(
                            vertical ? widget.surface.size.width : widget.surface.size.height,
                            height,
                            context
                        )
                        let buttons = widget.surface.layout.core.elements {
                            widget.text.string($0.action) == ShellRequest.statusMenuCommand
                        }
                        XCTAssertEqual(buttons.count, 1, context)
                        let button = try XCTUnwrap(buttons.first, context)
                        let content = widget.surface.layout.core.content(of: button)
                        XCTAssertEqual(
                            widget.text.string(content.secondaryAction),
                            ShellRequest.statusMenuCommand,
                            context
                        )
                        let help = ShellLocalizer.string(
                            state
                                .locked ? "Secure Input is on: Option shortcuts are paused" : "Window manager controls",
                            []
                        )
                        XCTAssertEqual(widget.text.string(content.help), help, context)
                        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                        let point = CGPoint(x: frame.midX, y: frame.midY)
                        let firstClick = widget.clicks.count
                        for mouseButton in [ShellEvent.Button.left, .right] {
                            widget.surface.press(at: point, button: mouseButton)
                            widget.surface.release(at: point, event: ShellEvent(button: mouseButton))
                        }
                        let clicks = widget.clicks.dropFirst(firstClick)
                        XCTAssertEqual(
                            clicks.map(\.action),
                            [ShellRequest.statusMenuCommand, ShellRequest.statusMenuCommand],
                            context
                        )
                        XCTAssertEqual(clicks.map(\.button), [.left, .right], context)
                        let tree = widget.tree()
                        let symbols = tree.filter { $0.kind == .symbol }.map { widget.text.string($0.content.text) }
                        let labels = tree.filter { $0.kind == .label }.map { widget.text.string($0.content.text) }
                        let logos = tree.filter {
                            $0.kind == .symbol && ["omniwm", "omniwm.lock"]
                                .contains(widget.text.string($0.content.text))
                        }
                        XCTAssertEqual(
                            logos.map { widget.text.string($0.content.text) },
                            [state.locked ? "omniwm.lock" : "omniwm"],
                            context
                        )
                        XCTAssertEqual(logos.first?.content.color, Color(packed: 0xB665_45FF), context)
                        if ["default", "lake", "matrix", "sakura"].contains(profile) {
                            XCTAssertEqual(frame.width, height - 4, accuracy: 0.001, context)
                            XCTAssertEqual(frame.height, height - 4, accuracy: 0.001, context)
                        } else if ["wayline", "nocturne"].contains(profile) {
                            XCTAssertEqual(frame.width, 32 * height / 40, accuracy: 0.001, context)
                            XCTAssertEqual(frame.height, 32 * height / 40, accuracy: 0.001, context)
                        }
                        if profile == "wayline" {
                            XCTAssertTrue(widget.surface.layout.core.paint(of: button).fill.isVisible, context)
                            XCTAssertEqual(content.hoverOpacity, 0.85, accuracy: 0.001, context)
                        } else if profile == "nocturne" {
                            XCTAssertEqual(
                                widget.surface.layout.core.paint(of: button).fill.isVisible,
                                state.backgrounds,
                                context
                            )
                            XCTAssertEqual(content.hoverScale, 1.06, accuracy: 0.001, context)
                        }
                        let modeLabel: String
                        let modeHelp: String
                        switch state.mode {
                        case .normal:
                            XCTAssertFalse(symbols.contains("keyboard") || symbols.contains("pause.fill"), context)
                            continue
                        case .paused:
                            modeLabel = "Paused"
                            modeHelp = "OmniWM shortcuts are paused."
                        case .prefix:
                            modeLabel = "Prefix"
                            modeHelp = "Prefix: the next key runs an OmniWM command. Escape cancels."
                        case .window:
                            modeLabel = "Window Mode"
                            modeHelp = "Window mode: keys run OmniWM commands until you press Escape."
                        }
                        XCTAssertTrue(symbols.contains(state.mode == .paused ? "pause.fill" : "keyboard"), context)
                        XCTAssertEqual(labels.contains(ShellLocalizer.string(modeLabel, [])), !vertical, context)
                        let chip = try XCTUnwrap(widget.surface.layout.core.elements {
                            widget.text.string($0.help) == ShellLocalizer.string(modeHelp, [])
                        }.first, context)
                        let chipFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: chip))
                        XCTAssertEqual(
                            vertical ? chipFrame.minY - frame.maxY : chipFrame.minX - frame.maxX,
                            4,
                            accuracy: 0.001,
                            context
                        )
                    }
                }
            }
        }
    }

    func testSharedHiddenBarsKeepNativeGeometryAndActivationAcrossSkins() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let widget = try makeWidget(
                "hidden-bar", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/hidden-bar/init.luau")
            )
            for vertical in [false, true] {
                widget.render(fixture(config, height: 32, vertical: vertical))
                for cell in [20.0, 24.0] {
                    let context = "\(profile) vertical=\(vertical) cell=\(cell)"
                    var hidden = ShellHiddenBarData(cell: cell, vertical: vertical)
                    widget.set("hiddenBar") { hidden.write(into: &$0) }
                    widget.layoutPopout()
                    XCTAssertEqual(widget.surface.size, CGSize(width: 140, height: cell + 4), context)
                    XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
                        "No hidden items",
                        []
                    )))
                    hidden.items = (0 ..< 3).map { index in
                        ShellHiddenBarItem(
                            id: "app#\(index)", name: "Hidden App \(index)",
                            image: index == 0 ? "hidden-bar/fixture" : nil, width: 30, height: 16
                        )
                    }
                    for constrained in [false, true] {
                        hidden.maxWidth = constrained ? 70 : 600
                        hidden.maxHeight = constrained ? cell * 2 : 600
                        widget.set("hiddenBar") { hidden.write(into: &$0) }
                        widget.layoutPopout()
                        let expected = vertical
                            ? CGSize(width: constrained ? 66 : 34, height: constrained ? cell * 2 + 8 : cell * 3 + 8)
                            : CGSize(width: constrained ? 68 : 98, height: constrained ? cell * 2 + 6 : cell + 4)
                        XCTAssertEqual(widget.surface.size, expected, "\(context) constrained=\(constrained)")
                        let actions = widget.surface.layout.core.elements { $0.action != 0 }.sorted { left, right in
                            let a = widget.surface.layout.core.absoluteFrame(of: left)
                            let b = widget.surface.layout.core.absoluteFrame(of: right)
                            return vertical
                                ? (a.x == b.x ? a.y < b.y : a.x < b.x)
                                : (a.y == b.y ? a.x < b.x : a.y < b.y)
                        }
                        XCTAssertEqual(actions.count, 3, context)
                        let firstClick = widget.clicks.count
                        for (index, action) in actions.enumerated() {
                            let content = widget.surface.layout.core.content(of: action)
                            XCTAssertEqual(widget.text.string(content.help), "Hidden App \(index)", context)
                            let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: action))
                            let point = CGPoint(x: frame.midX, y: frame.midY)
                            widget.surface.press(at: point)
                            widget.surface.release(at: point)
                        }
                        XCTAssertEqual(
                            widget.clicks.dropFirst(firstClick).map(\.action),
                            (0 ..< 3).map { "hidden-bar activate app#\($0)" }, context
                        )
                        let tree = widget.renderPopout()
                        XCTAssertEqual(tree.filter { $0.kind == .bitmap }.count, 1, context)
                        XCTAssertEqual(tree.filter {
                            $0.kind == .symbol && widget.text.string($0.content.text) == "app.dashed"
                        }.count, 2, context)
                    }
                }
            }
        }
    }

    func testSharedHiddenMenusKeepContentDisabledRowsAndDeliveredActionsAcrossSkins() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let widget = try makeWidget(
                "hidden-bar-menu", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/hidden-bar-menu/init.luau")
            )
            widget.render(fixture(config, height: 32, vertical: false))
            var hidden = hiddenBarFixture(vertical: false, menu: true)
            widget.set("hiddenBar") { hidden.write(into: &$0) }
            widget.layoutPopout()
            XCTAssertEqual(widget.surface.size, CGSize(width: 240, height: 165), profile)
            let tree = widget.renderPopout()
            let scroll = try XCTUnwrap(tree.first { $0.content.scrolls }, profile)
            XCTAssertEqual(scroll.layout.padding, 8, profile)
            XCTAssertEqual(scroll.layout.gap, 0, profile)
            let strings = widget.strings(OMNI_VIEW_POPOUT)
            for string in [
                "Checked item",
                "Disabled item",
                "More options",
                "✓",
                "⌘K",
                ShellLocalizer.string("Back", [])
            ] {
                XCTAssertTrue(strings.contains(string), "\(profile): \(string)")
            }
            XCTAssertTrue(strings.contains(profile == "wayline" ? "OPTIONS" : "Options"), profile)
            XCTAssertTrue(
                tree.contains { $0.kind == .symbol && widget.text.string($0.content.text) == "chevron.right" },
                profile
            )
            XCTAssertTrue(
                tree.contains { $0.kind == .symbol && widget.text.string($0.content.text) == "chevron.left" },
                profile
            )
            XCTAssertTrue(tree.contains { $0.layout.height == 9 }, profile)
            let actions = widget.surface.layout.core.elements { $0.action != 0 }.sorted {
                widget.surface.layout.core.absoluteFrame(of: $0).y < widget.surface.layout.core.absoluteFrame(of: $1).y
            }
            XCTAssertEqual(actions.map {
                widget.text.string(widget.surface.layout.core.content(of: $0).action)
            }, ["hidden-bar-menu back", "hidden-bar-menu checked", "hidden-bar-menu submenu"], profile)
            for action in actions {
                let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: action))
                let point = CGPoint(x: frame.midX, y: frame.midY)
                widget.surface.press(at: point)
                widget.surface.release(at: point)
            }
            XCTAssertEqual(
                widget.clicks.map(\.action),
                ["hidden-bar-menu back", "hidden-bar-menu checked", "hidden-bar-menu submenu"], profile
            )
            let disabled = try XCTUnwrap(widget.surface.layout.core.elements {
                widget.text.string($0.text) == "Disabled item"
            }.first, profile)
            let disabledRow = widget.surface.layout.core.parent(of: disabled)
            let disabledContent = widget.surface.layout.core.content(of: disabledRow)
            XCTAssertEqual(disabledContent.action, 0, profile)
            XCTAssertFalse(disabledContent.hasHoverEffect, profile)
            let disabledFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: disabledRow))
            let disabledPoint = CGPoint(x: disabledFrame.midX, y: disabledFrame.midY)
            widget.surface.press(at: disabledPoint)
            widget.surface.release(at: disabledPoint)
            XCTAssertEqual(widget.clicks.count, 3, profile)
            if profile == "wayline" {
                let shortcut = try XCTUnwrap(tree.first { widget.text.string($0.content.text) == "⌘K" }, profile)
                XCTAssertEqual(shortcut.content.style & OMNI_STYLE_BASE_MASK, 2, profile)
                let mark = try XCTUnwrap(tree.first { widget.text.string($0.content.text) == "✓" }, profile)
                XCTAssertEqual(mark.content.color.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1), profile)
            }
            hidden.menu = HiddenBarMenuPage(title: "Réglages", rows: [], backID: nil)
            widget.set("hiddenBar") { hidden.write(into: &$0) }
            widget.layoutPopout()
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Réglages"), profile)
            XCTAssertTrue(
                widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("No menu items available", [])),
                profile
            )
            XCTAssertTrue(widget.surface.layout.core.elements { $0.action != 0 }.isEmpty, profile)
            hidden.menu = nil
            widget.set("hiddenBar") { hidden.write(into: &$0) }
            widget.layoutPopout()
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])), profile)
        }
    }

    func testSharedHiddenMenusScrollToTheLastActionWithinScreenBoundsAcrossSkins() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ([ShellDefaults.profile] + (try ShellStyleFixture.names())).sorted() {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell))
            let config = ShellConfig.resolve(shellDirectory: shell)
            let widget = try makeWidget(
                "hidden-bar-menu", config: config, shell: shell,
                source: shell.appendingPathComponent("default/widgets/hidden-bar-menu/init.luau")
            )
            widget.render(fixture(config, height: 32, vertical: false))
            let hidden = ShellHiddenBarData(maxWidth: 240, maxHeight: 140, menu: HiddenBarMenuPage(
                title: nil,
                rows: (0 ..< 30).map {
                    hiddenMenuFixtureRow("item-\($0)", title: "Item \($0)")
                }, backID: nil
            ))
            widget.set("hiddenBar") { hidden.write(into: &$0) }
            widget.layoutPopout()
            XCTAssertEqual(widget.surface.size, CGSize(width: 240, height: 140), profile)
            let first = CGPoint(x: 60, y: 18)
            widget.surface.press(at: first)
            widget.surface.release(at: first)
            XCTAssertEqual(widget.clicks.last?.action, "hidden-bar-menu item-0", profile)
            XCTAssertTrue(widget.surface.scroll(
                at: first, event: ShellEvent(button: .none), content: CGPoint(x: 0, y: 10000)
            ), profile)
            let last = CGPoint(x: 60, y: 121)
            widget.surface.press(at: last)
            widget.surface.release(at: last)
            XCTAssertEqual(widget.clicks.last?.action, "hidden-bar-menu item-29", profile)
        }
    }

    func testDefaultCompactWorkspacesKeepButtonsAndTargetsAcrossOrientations() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let config = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(config.profile, "default")
        XCTAssertNil(config.widgetSettings["workspaces"])
        for vertical in [false, true] {
            for labels in [false, true] {
                let widget = try makeWidget("workspaces", config: config, shell: shell)
                widget.set("settings") {
                    $0.map(1)
                    $0.key("compact")
                    $0.bool(true)
                }
                var bar = fixture(config, height: 32, vertical: vertical)
                bar.style.labels = labels
                widget.render(bar)
                let size = widget.surface.size
                XCTAssertTrue(size.width.isFinite && size.height.isFinite)
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(vertical ? size.width : size.height, 32)
                let tree = widget.tree()
                XCTAssertFalse(tree.contains { $0.kind == .image && $0.content.iconSource == .window })
                XCTAssertEqual(Set(widget.surface.targetFrames().map { widget.text.string($0.target) }), [
                    "workspace 1", "workspace 2", "workspace 3"
                ])
                for workspace in bar.workspaces {
                    XCTAssertEqual(tree.contains {
                        $0.kind == .label && widget.text.string($0.content.text) == workspace.name
                    }, labels)
                    let button = try XCTUnwrap(widget.surface.layout.core.elements {
                        $0.menu && $0.drop && widget.text.string($0.target) == "workspace \(workspace.id)"
                    }.first)
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                    XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite)
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThan(frame.height, 0)
                    let point = CGPoint(x: frame.midX, y: frame.midY)
                    widget.surface.press(at: point)
                    widget.surface.release(at: point)
                    XCTAssertEqual(widget.clicks.last?.action, "switch-workspace \(workspace.id)")
                }
            }
        }
    }

    func testWorkspaceGroupsKeepTheirTargetsAndPickerAcrossProfilesAndOrientations() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in try barHostingProfiles(in: shell) {
            _ = try ShellProfiles.select(profile, in: shell)
            let config = ShellConfig.resolve(shellDirectory: shell)
            for vertical in [false, true] {
                for labels in [false, true] {
                    let widget = try makeWidget("workspaces", config: config, shell: shell)
                    if profile == "sakura" {
                        widget.set("settings") {
                            $0.map(1)
                            $0.key("compact")
                            $0.bool(false)
                        }
                    }
                    var bar = fixture(config, height: config.barOverride?.settings.height ?? 24, vertical: vertical)
                    bar.style.labels = labels
                    widget.render(bar)
                    let targets = widget.surface.targetFrames()
                    XCTAssertEqual(Set(targets.map { widget.text.string($0.target) }), [
                        "workspace 1", "workspace 2", "workspace 3", "window 0", "window 1", "window 2", "window 3"
                    ], "\(profile) vertical=\(vertical) labels=\(labels)")
                    let group = try XCTUnwrap(widget.tree()
                        .first { widget.text.string($0.content.target) == "window 1" })
                    XCTAssertTrue(group.content.menu && group.content.preview && group.content.drag && group.content
                        .opensPopout)
                    if profile == "wayline", labels {
                        let label = try XCTUnwrap(widget.surface.layout.core.elements {
                            widget.text.string($0.text) == "1"
                        }.first)
                        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: label))
                        let window = try XCTUnwrap(widget.surface.layout.core.elements {
                            $0.drag && widget.text.string($0.target) == "window 0"
                        }.first)
                        let icon = CGRect(widget.surface.layout.core.absoluteFrame(of: window))
                        XCTAssertLessThanOrEqual(vertical ? frame.maxY : frame.maxX, vertical ? icon.minY : icon.minX)
                    }
                    widget.invoke(group.content.action)
                    widget.layoutPopout()
                    if profile == "default" {
                        XCTAssertEqual(widget.surface.chrome, ShellPopoutChrome(glass: true, radius: 20))
                        if ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] != nil {
                            try write(
                                [("workspaces", raster(widget.surface, scale: 2), widget.surface.size)],
                                name: "default-workspaces-picker-\(vertical ? "vertical" : "horizontal")-labels-\(labels)",
                                scale: 2, dark: false, solidBlack: false
                            )
                        }
                    }
                    for window in bar.workspaces[0].windows[1].windows {
                        let row = try XCTUnwrap(widget.surface.layout.core.elements {
                            widget.text.string($0.action) == "window focus \(window.id)"
                        }.first)
                        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: row))
                        let point = CGPoint(x: frame.midX, y: frame.midY)
                        widget.surface.press(at: point)
                        widget.surface.release(at: point)
                        XCTAssertEqual(widget.clicks.last?.action, "window focus \(window.id)")
                    }
                    let close = try XCTUnwrap(widget.surface.layout.core.elements { $0.action == OMNI_ACTION_POPOUT }
                        .first)
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: close))
                    let point = CGPoint(x: frame.midX, y: frame.midY)
                    widget.surface.press(at: point)
                    widget.surface.release(at: point)
                    XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT)
                    if profile == "wayline", !labels {
                        bar.style.accents = false
                        bar.style.backgrounds = true
                        widget.render(bar)
                        let selected = try XCTUnwrap(widget.tree()
                            .first { $0.content.drop && widget.text.string($0.content.target) == "workspace 1" })
                        let inactive = try XCTUnwrap(widget.tree()
                            .first { $0.content.drop && widget.text.string($0.content.target) == "workspace 2" })
                        XCTAssertTrue(selected.paint.stroke.isVisible)
                        XCTAssertNotEqual(selected.paint.stroke, inactive.paint.stroke)
                    }
                    bar.workspaces.removeFirst()
                    widget.render(bar)
                    XCTAssertFalse(widget.renderPopout().contains { $0.content.action != 0 })
                }
            }
        }
    }

    func testUnderlineSpansTheWorkspaceWithOrWithoutLabelsAndRespectsAccents() throws {
        let widget = try ShellRenderedWidget("workspaces")
        widget.set("settings") {
            $0.map(1)
            $0.key("indicator")
            $0.string("underline")
        }
        for vertical in [false, true] {
            for labels in [false, true] {
                for accents in [false, true] {
                    var bar = fixture(ShellConfig(), height: 32, vertical: vertical)
                    bar.style.labels = labels
                    bar.style.accents = accents
                    widget.render(bar)
                    let paths = widget.surface.layout.core.elements { _ in true }.filter {
                        widget.surface.layout.core.kind(of: $0) == .path
                    }
                    XCTAssertEqual(paths.count, accents ? 1 : 0)
                    guard let path = paths.first else { continue }
                    let line = CGRect(widget.surface.layout.core.absoluteFrame(of: path))
                    let workspace = try XCTUnwrap(widget.surface.targetFrames().first {
                        widget.text.string($0.target) == "workspace 1"
                    }).frame
                    XCTAssertEqual(
                        vertical ? line.height : line.width,
                        vertical ? workspace.height : workspace.width,
                        accuracy: 0.01
                    )
                }
            }
        }
    }

    func testSolidBlackWorkspaceLabelsStayReadableInLightAndDarkAppearances() throws {
        let widget = try ShellRenderedWidget("workspaces")
        let black = ShellRGBA(CGColor(gray: 0, alpha: 1))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            widget.resources.palette.refresh(theme: .native, appearance: try XCTUnwrap(NSAppearance(named: appearance)))
            for accents in [false, true] {
                var bar = fixture(ShellConfig(), height: 32, vertical: false)
                bar.style.solidBlack = true
                bar.style.accents = accents
                widget.render(bar)
                for name in accents ? ["2", "3"] : ["1", "2", "3"] {
                    let label = try XCTUnwrap(widget.tree().first {
                        widget.text.string($0.content.text) == name
                            && widget.text.string($0.content.target) == "workspace \(name)"
                            && $0.kind == .label
                    })
                    let color = try ShellRGBA(XCTUnwrap(widget.resources.palette.color(label.content.color)))
                    XCTAssertGreaterThanOrEqual(color.contrast(black), 4.5, "\(appearance.rawValue) workspace \(name)")
                }
            }
        }
    }

    private func render(
        _ config: ShellConfig,
        shell: URL,
        height: Double,
        vertical: Bool,
        scale: CGFloat,
        dark: Bool
    ) throws {
        let resources = ShellResources(
            motion: MotionPolicy(animationsEnabled: false),
            windowIcon: { [applications] id in
                guard let index = Int(id), applications.indices.contains(index),
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: applications[index])
                else { return nil }
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        )
        var theme = config.theme
        for (role, color) in [
            (ShellRole.accent, config.barOverride?.accentColor),
            (.foreground, config.barOverride?.textColor)
        ] {
            guard let color else { continue }
            let value = NSColor(deviceRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
            theme.light[role.rawValue] = value
            theme.dark[role.rawValue] = value
        }
        resources.palette.refresh(
            theme: theme,
            appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        )
        let bar = fixture(config, height: height, vertical: vertical)
        var previews: [(String, CGImage, CGSize)] = []
        for name in ["workspaces", "scratchpads", "clock", "system-stats"] {
            let widget = try makeWidget(name, config: config, shell: shell, scale: scale, resources: resources)
            widget.set("clock") { $0.string("9:41 AM") }
            widget.set("date") { $0.string("Sat, Oct 10") }
            widget.set("cpu") { $0.number(42) }
            widget.set("memory") { $0.number(61) }
            widget.set("gpu") { $0.number(18) }
            widget.render(bar)
            let size = widget.surface.size
            XCTAssertGreaterThan(size.width, 0, "\(config.profile)/\(name)")
            XCTAssertGreaterThan(size.height, 0, "\(config.profile)/\(name)")
            XCTAssertLessThanOrEqual(
                vertical ? size.width : size.height,
                height,
                "\(config.profile)/\(name) \(height) vertical=\(vertical): \(size)"
            )
            if ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] != nil {
                previews.append((name, try raster(widget.surface, scale: scale), size))
            }
        }
        if !previews.isEmpty {
            let name = "\(config.profile)-\(Int(height))-\(vertical ? "vertical" : "horizontal")-\(dark ? "dark" : "light")-\(Int(scale))x"
            try write(previews, name: name, scale: scale, dark: dark, solidBlack: bar.style.solidBlack)
        }
    }

    private func exportSystemStatsState(_ widget: ShellRenderedWidget, profile: String, state: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNIWM_STEP_RENDERS"] else { return }
        try ShellBundledWidgetTests.writeSnapshot(
            widget.surface, name: "system-stats-\(profile)-\(state)", dark: false,
            directory: URL(fileURLWithPath: directory).appendingPathComponent("states").path,
            background: widget.resources.palette.color(.clear, default: .background)
        )
    }

    private func useSharedLibraries(_ names: String, in shell: URL) throws {
        for library in names.split(separator: ",", omittingEmptySubsequences: false) {
            guard !library.isEmpty, library != ".", !library.contains("/"), !library.contains("\\"),
                  !library.contains("..") else { continue }
            var removed = false
            for profile in ShellProfiles.names(in: shell) where profile != "default" {
                let path = shell.appendingPathComponent("\(profile)/lib/\(library).luau")
                if FileManager.default.fileExists(atPath: path.path) {
                    try FileManager.default.removeItem(at: path)
                    removed = true
                }
            }
            guard removed else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "lib/\(library).luau"])
            }
        }
    }

    private func useZeroLocalOffset(_ widget: ShellRenderedWidget) {
        omni_vm_set_formatter(
            widget.vm,
            { context, kind, value, digits, pattern, patternLength, zone, zoneLength, out, capacity in
                if UInt32(kind) == OMNI_FORMAT_OFFSET, zone == nil, let out {
                    return ShellLocalizer.copy("0", into: out, capacity: capacity)
                }
                return ShellFormatter.callback(
                    context,
                    kind,
                    value,
                    digits,
                    pattern,
                    patternLength,
                    zone,
                    zoneLength,
                    out,
                    capacity
                )
            },
            nil
        )
    }

    private func useUnavailableLocalOffset(_ widget: ShellRenderedWidget) {
        omni_vm_set_formatter(
            widget.vm,
            { context, kind, value, digits, pattern, patternLength, zone, zoneLength, out, capacity in
                if UInt32(kind) == OMNI_FORMAT_OFFSET, zone == nil { return 0 }
                return ShellFormatter.callback(
                    context,
                    kind,
                    value,
                    digits,
                    pattern,
                    patternLength,
                    zone,
                    zoneLength,
                    out,
                    capacity
                )
            },
            nil
        )
    }

    private func sharedAudioShell() throws -> URL {
        try sharedLibraryShell("audio")
    }

    private func sharedLibraryShell(_ library: String) throws -> URL {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ShellProfiles.names(in: shell) where profile != "default" {
            let audio = shell.appendingPathComponent("\(profile)/lib/\(library).luau")
            if FileManager.default.fileExists(atPath: audio.path) {
                try FileManager.default.removeItem(at: audio)
            }
        }
        return shell
    }

    private func selectMediaTab(_ widget: ShellRenderedWidget, name: String) throws {
        if name == "control-center" {
            widget.set("settings") { ShellServiceValue.object(["tab": .text("media")]).write(to: &$0) }
        } else if name == "dashboard" {
            widget.set("clock") { $0.string("9:41 AM") }
            widget.layoutPopout()
            let label = try XCTUnwrap(widget.surface.layout.core.elements {
                widget.text.string($0.text) == ShellLocalizer.string("Media", [])
            }.first)
            let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: label))
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let before = widget.actions.count
            widget.surface.press(at: point)
            widget.surface.release(at: point)
            XCTAssertEqual(widget.actions.count, before + 1)
            let action = try XCTUnwrap(widget.actions.last)
            XCTAssertEqual(widget.invoke(action, view: OMNI_VIEW_POPOUT), [])
        }
    }

    private func clickCommand(_ command: String, widget: ShellRenderedWidget, context: String) throws {
        let element = try XCTUnwrap(
            widget.surface.layout.core.elements { widget.text.string($0.action) == command }.first,
            context + ": " + command
        )
        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: element))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let before = widget.clicks.count
        widget.surface.press(at: point)
        widget.surface.release(at: point)
        XCTAssertEqual(widget.clicks.count, before + 1, context + ": " + command)
        XCTAssertEqual(widget.clicks.last?.action, command, context)
    }

    private func assertCelestialPreloads(_ name: String, allModules: Bool) throws {
        let shell = try stepShell([:])
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        let source = try ShellWidgetSourceLoader.build(.init(
            name: name, shellDirectory: shell, sourceURL: XCTUnwrap(config.widget(name)),
            directories: config.directories, profile: config.profile
        ))
        let models = name == "dashboard" ? ["calendar", "media", "weather"]
            : ["audio", "battery", "bluetooth", "input-source", "wifi"]
        let modules = source.modules.filter { module in
            allModules || models.contains { module.path.hasSuffix("/\($0).luau") }
        }
        if !allModules {
            for model in models {
                XCTAssertEqual(source.modules.filter { $0.path.hasSuffix("/\(model).luau") }.count, 1, model)
            }
        }
        let parts = name == "dashboard" ? ["Dashboard", "Media", "Performance", "Weather"]
            : ["network", "bluetooth", "battery", "keyboard", "audio"]
        for part in parts {
            let widget = try ShellRenderedWidget(
                name: name, source: source.main, directories: config.directories,
                modules: source.modules, chunk: source.chunk
            )
            for module in modules {
                let sentinel = "error(\"unexpected render-time module compile: \(module.path)\")"
                XCTAssertEqual(omni_vm_add_module(
                    widget.vm, module.path, module.path.utf8.count, sentinel, sentinel.utf8.count
                ), OMNI_OK, module.path)
            }
            calendarFixture(widget)
            weatherFixture(widget)
            mediaFixture(widget)
            systemStatsFixture(widget)
            audioFixture(widget, access: .granted)
            wifiFixture(widget)
            bluetoothFixture(widget)
            statusFixture(widget, name: "input-source")
            widget.set("settings") {
                ShellServiceValue.object(Dictionary(uniqueKeysWithValues:
                    ["audio", "keyboard", "network", "bluetooth", "battery"].map { ($0, .bool(true)) }
                )).write(to: &$0)
            }
            widget.set("bar") { fixture(config, height: 60, vertical: false).write(to: &$0) }
            let context = "\(name)/\(part)/\(allModules ? "all" : "models")"
            try renderAndLayout(widget, view: OMNI_VIEW_BAR, context: context)
            if name == "dashboard" {
                try renderAndLayout(widget, view: OMNI_VIEW_POPOUT, context: context)
            }
            let labels = [
                "network": "Wi-Fi",
                "bluetooth": "Bluetooth",
                "battery": "Battery",
                "keyboard": "ABC",
                "audio": "Volume"
            ]
            let view = name == "dashboard" ? OMNI_VIEW_POPOUT : OMNI_VIEW_BAR
            let title = ShellLocalizer.string(labels[part] ?? part, [])
            let entry = try XCTUnwrap(widget.surface.layout.core.elements {
                widget.text.string(view == OMNI_VIEW_BAR ? $0.help : $0.text) == title
            }.first, context)
            let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: entry))
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let previous = widget.actions.count
            widget.surface.press(at: point)
            widget.surface.release(at: point)
            XCTAssertEqual(widget.actions.count, previous + 1, context)
            XCTAssertEqual(widget.invoke(try XCTUnwrap(widget.actions.last), view: view), [], context)
            for missing in [false, true] {
                if missing {
                    for key in ShellDataKey.allCases where ![.bar, .settings, .clock].contains(key) {
                        widget.set(key.rawValue) { $0.null() }
                    }
                }
                let expected = celestialPreloadExpectations(name, part: part, missing: missing)
                let deps = try renderAndLayout(widget, view: OMNI_VIEW_POPOUT, context: context)
                XCTAssertEqual(deps, expected.keys.reduce(0) { $0 | $1.bit }, context + " missing=\(missing)")
                let strings = widget.strings(OMNI_VIEW_POPOUT)
                for text in expected.content {
                    XCTAssertTrue(strings.contains(ShellLocalizer.string(text, [])), context + ": " + text)
                }
                let barDeps = try renderAndLayout(widget, view: OMNI_VIEW_BAR, context: context)
                let barKeys: [ShellDataKey] = name == "dashboard" ? [] : missing
                    ? [.bar, .settings, .volume, .inputSource, .wifi, .bluetooth, .battery]
                    : [.bar, .settings, .volume, .muted, .inputSource, .wifi, .bluetooth, .battery, .charging]
                XCTAssertEqual(barDeps, barKeys.reduce(0) { $0 | $1.bit }, context + " bar missing=\(missing)")
                if name == "status" {
                    XCTAssertTrue(widget.strings().contains(ShellLocalizer.string("Wi-Fi", [])), context)
                    XCTAssertEqual(widget.strings().contains("EN"), !missing, context)
                }
            }
        }
    }

    @discardableResult
    private func renderAndLayout(
        _ widget: ShellRenderedWidget,
        view: omni_view,
        context: String
    ) throws -> UInt64 {
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 512)
        let status = omni_instance_render(widget.instance, view, 100_000_000, &stats, &error, error.count)
        let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let deps = try XCTUnwrap(status == OMNI_OK ? stats.deps : nil, context + ": " + message)
        let output = widget.output(view)
        widget.text.ingest(wire: output)
        XCTAssertTrue(widget.surface.apply(output, text: widget.text), context)
        return deps
    }

    private func celestialPreloadExpectations(
        _ name: String,
        part: String,
        missing: Bool
    ) -> (keys: [ShellDataKey], content: [String]) {
        switch (name, part) {
        case ("dashboard", "Dashboard"):
            return (
                [.weather, .user, .system, .clock, .calendar, .cpu, .memory, .disk, .media]
                    + (missing ? [] : [.seconds, .tempo]),
                missing ? ["Unavailable", "Nothing is playing"] : ["October 2026", "Northern Lights", "Partly cloudy"]
            )
        case ("dashboard", "Media"):
            return (
                [.media, .appearance] + (missing ? [] : [.seconds, .lyrics]),
                missing ? ["Nothing is playing"] : ["Northern Lights", "Sample Artist", "Sample Album"]
            )
        case ("dashboard", "Performance"):
            return (
                [.battery, .system, .thermal, .cpu, .gpu, .networkHistory, .network]
                    + (missing ? [.disk, .memory] : [.charging, .power]),
                missing ? ["CPU", "GPU", "Storage", "Collecting data…"]
                    : ["Apple M4 Max", "Apple M4 Max GPU", "Storage", "Battery"]
            )
        case ("dashboard", "Weather"):
            return (
                [.weather] + (missing ? [] : [.settings]),
                missing ? ["Unavailable"] : ["Toronto", "7-day forecast", "Partly cloudy"]
            )
        case (_, "network"):
            return (
                [.wifi, .network],
                missing ? ["Unavailable", "Wi-Fi Settings…"] : ["Harbour Home", "Download", "Upload"]
            )
        case (_, "bluetooth"):
            return ([.bluetooth], missing ? ["Bluetooth", "Unavailable"] : ["AirPods Pro", "Magic Keyboard"])
        case (_, "battery"):
            return (
                missing ? [.battery] : [.battery, .charging, .settings, .power],
                missing ? ["Battery", "Unavailable"] : [percent(0.76), "On battery", "Battery Settings…"]
            )
        case (_, "keyboard"):
            return (
                [.inputSource],
                missing ? ["Unavailable", "Keyboard Settings…"] : ["ABC", "German", "Keyboard Settings…"]
            )
        default:
            return (
                [.volume, .muted, .outputs, .audioApps],
                missing ? ["Volume", "Unavailable"] : ["MacBook Pro Speakers", percent(0.62)]
            )
        }
    }

    private func assertCelestialWeatherLayout(
        _ widget: ShellRenderedWidget,
        weather: ShellWeather,
        context: String
    ) throws {
        widget.layoutPopout()
        let scroll = try XCTUnwrap(widget.surface.layout.core.elements { $0.scrolls }.first, context)
        let viewport = CGRect(widget.surface.layout.core.absoluteFrame(of: scroll))
        XCTAssertEqual(viewport.height, 530, context)
        func frame(_ element: ElementHandle, relativeTo ancestor: ElementHandle) -> CGRect {
            var result = CGRect(widget.surface.layout.core.layoutFrame(of: element))
            var parent = widget.surface.layout.core.parent(of: element)
            while parent != .none, parent != ancestor {
                let position = widget.surface.layout.core.layoutFrame(of: parent)
                result.origin.x += CGFloat(position.x)
                result.origin.y += CGFloat(position.y)
                parent = widget.surface.layout.core.parent(of: parent)
            }
            XCTAssertEqual(parent, ancestor, context)
            return result
        }
        let elements = widget.surface.layout.core.elements { _ in true }
        for day in weather.days {
            let label = try XCTUnwrap(elements.first {
                widget.text.string(widget.surface.layout.core.content(of: $0).text) == day.label
            }, context + ": " + day.label)
            let card = widget.surface.layout.core.parent(of: label)
            let bounds = CGRect(widget.surface.layout.core.absoluteFrame(of: card))
            XCTAssertEqual(bounds.height, 162, context + ": " + day.label)
            let local = frame(card, relativeTo: scroll)
            XCTAssertTrue(
                CGRect(origin: .zero, size: viewport.size).contains(local),
                context + ": \(day.label) \(local) outside \(viewport.size)"
            )
            for child in elements {
                var parent = widget.surface.layout.core.parent(of: child)
                while parent != .none, parent != card {
                    parent = widget.surface.layout.core.parent(of: parent)
                }
                if parent == card {
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: child))
                    XCTAssertTrue(bounds.contains(frame), context + ": \(day.label) child \(frame) outside \(bounds)")
                }
            }
        }
        if weather.stale {
            let stale = ShellLocalizer.string("Last update failed", [])
            let cue = try XCTUnwrap(elements.first {
                widget.text.string(widget.surface.layout.core.content(of: $0).help) == stale
            }, context)
            let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: cue))
            XCTAssertGreaterThan(frame.width, 0, context)
            XCTAssertGreaterThan(frame.height, 0, context)
            XCTAssertTrue(viewport.contains(frame), context + ": stale cue \(frame) outside \(viewport)")
        }
        let attribution = try XCTUnwrap(widget.surface.layout.core.elements {
            widget.text.string($0.text) == ShellLocalizer.string("Weather by %@", [.text("Open-Meteo.com")])
        }.first, context)
        let before = CGRect(widget.surface.layout.core.absoluteFrame(of: attribution))
        XCTAssertGreaterThanOrEqual(before.minY, viewport.maxY, context)
        XCTAssertTrue(
            widget.surface.scroll(
                at: CGPoint(x: viewport.midX, y: viewport.midY),
                event: ShellEvent(button: .none),
                content: CGPoint(x: 0, y: 10_000)
            ),
            context
        )
        let after = CGRect(widget.surface.layout.core.absoluteFrame(of: attribution))
        XCTAssertTrue(viewport.contains(after), context + ": \(after) outside \(viewport)")
    }

    private func audioFixture(_ widget: ShellRenderedWidget, access: AppVolumeAccess) {
        widget.set("volume") { $0.number(62) }
        widget.set("muted") { $0.bool(false) }
        let outputs = [
            ShellAudioOutput(id: 41, name: "MacBook Pro Speakers", transport: "builtin", isDefault: true),
            ShellAudioOutput(id: 42, name: "AirPods Pro", transport: "bluetooth", isDefault: false),
            ShellAudioOutput(id: 43, name: "Studio Display Speakers", transport: "usb", isDefault: false)
        ]
        widget.set("outputs") { writer in
            writer.array(outputs.count)
            outputs.forEach { $0.write(into: &writer) }
        }
        let apps = access == .granted ? [
            ShellAudioApp(id: "com.apple.Music", name: "Music", playing: true, volume: 80, muted: false),
            ShellAudioApp(id: "com.apple.Safari", name: "Safari", playing: true, volume: 100, muted: false),
            ShellAudioApp(id: "com.apple.Podcasts", name: "Podcasts", playing: false, volume: 45, muted: true)
        ] : []
        widget.set("audioApps") { ShellAudioApps(access: access, apps: apps).write(into: &$0) }
    }

    private func calendarFixture(_ widget: ShellRenderedWidget, access: String = "full", month: Bool = true) {
        let now = 1_000_000.0
        let events = access == "full" ? [
            ShellCalendarEvent(
                id: "standup", title: "Team standup", calendar: "Work", color: "#0A84FF",
                start: now - 600, end: now + 900, allDay: false, location: nil, time: "9:30 AM", day: "Today"
            ),
            ShellCalendarEvent(
                id: "review", title: "Design review", calendar: "Work", color: "#FF9F0A",
                start: now + 1500, end: now + 4200, allDay: false, location: "Room 4", time: "10:05 AM", day: "Today"
            ),
            ShellCalendarEvent(
                id: "holiday", title: "Team offsite", calendar: "Home", color: "#30D158",
                start: now + 7200, end: now + 93600, allDay: true, location: nil, time: "", day: "Tomorrow"
            ),
            ShellCalendarEvent(
                id: "dinner", title: "Dinner with friends", calendar: "Home", color: "#BF5AF2",
                start: now + 90000, end: now + 97200, allDay: false, location: nil, time: "7:00 PM", day: "Tomorrow"
            )
        ] : []
        let calendar = ShellCalendar(access: access, events: events, month: month ? ShellCalendarMonth(
            title: "October 2026", year: 2026, month: 10, days: 31, offset: 4, today: 23,
            weekdays: ["S", "M", "T", "W", "T", "F", "S"], marked: [5, 12, 23, 24]
        ) : nil)
        widget.set("calendar") { calendar.write(into: &$0) }
        widget.set("seconds") { $0.number(now) }
        widget.set("clock") { $0.string("9:41 AM") }
        widget.set("date") { $0.string("Fri Oct 23") }
    }

    private func percent(_ value: Double) -> String {
        ShellFormatter.string(kind: OMNI_FORMAT_PERCENT, value, digits: 0)
    }

    private func radioStates(_ name: String) -> [String] {
        name == "wifi" ? ["full", "off", "disconnected", "weak", "hidden"] : ["full", "off", "denied", "empty"]
    }

    private func radioFixture(_ widget: ShellRenderedWidget, name: String, state: String) {
        if state == "unavailable" {
            widget.set(name) { $0.null() }
        } else if name == "wifi" {
            switch state {
            case "off": wifiFixture(widget, ShellWiFi(power: false))
            case "disconnected": wifiFixture(widget, ShellWiFi(power: true, location: "authorized"))
            case "weak": wifiFixture(widget, ShellWiFi(
                    power: true, connected: true, ssid: "Harbour Home", rssi: -82, band: "2.4 GHz", channel: 6,
                    security: "WPA2 Personal", location: "authorized"
                ))
            case "hidden": wifiFixture(widget, ShellWiFi(
                    power: true, connected: true, rssi: -64, band: "5 GHz", channel: 149, security: "WPA3 Personal"
                ))
            default: wifiFixture(widget)
            }
        } else {
            switch state {
            case "off": bluetoothFixture(widget, ShellBluetooth(power: false, access: "granted"))
            case "denied": bluetoothFixture(widget, ShellBluetooth(power: true, access: "denied"))
            case "empty": bluetoothFixture(widget, ShellBluetooth(power: true, access: "granted"))
            default: bluetoothFixture(widget)
            }
        }
    }

    private func radioHelp(_ name: String, state: String) -> String {
        if name == "wifi" {
            switch state {
            case "off": return ShellLocalizer.string("Wi-Fi: Off", [])
            case "disconnected": return ShellLocalizer.string("Wi-Fi: Not Connected", [])
            case "hidden": return ShellLocalizer.string("Wi-Fi: Connected", [])
            default: return "Harbour Home"
            }
        }
        switch state {
        case "off": return ShellLocalizer.string("Bluetooth: Off", [])
        case "denied": return ShellLocalizer.string("Bluetooth", [])
        default: return ShellLocalizer.string("Bluetooth: %lld connected", [.number(state == "empty" ? 0 : 2)])
        }
    }

    private func statusFixture(_ widget: ShellRenderedWidget, name: String) {
        switch name {
        case "input-source":
            let entries = [
                ShellInputSourceEntry(id: "com.apple.keylayout.ABC", name: "ABC", short: "EN"),
                ShellInputSourceEntry(id: "com.apple.inputmethod.SCIM.ITABC", name: "Pinyin – Simplified", short: "ZH"),
                ShellInputSourceEntry(id: "com.apple.keylayout.German", name: "German", short: "DE")
            ]
            widget.set("inputSource") { ShellInputSource(current: entries[0], sources: entries).write(into: &$0) }
        case "privacy":
            widget.set("privacy") { ShellPrivacy(microphone: true, camera: true).write(into: &$0) }
        case "world-clock":
            widget.set("seconds") { $0.number(1_791_924_120) }
        case "stats":
            for (key, value) in [("cpu", 38.0), ("memory", 64.0), ("gpu", 12.0), ("disk", 34.0)] {
                widget.set(key) { $0.number(value) }
            }
            networkFixture(widget)
        default:
            break
        }
    }

    private func feedStatsHistory(_ widget: ShellRenderedWidget, bar: ShellBarData) {
        for cpu in [12.0, 38, 22, 64, 47, 93] {
            widget.set("cpu") { $0.number(cpu) }
            widget.render(bar)
        }
    }

    private func exportStatusVariants(
        _ widget: ShellRenderedWidget,
        name: String,
        profile: String,
        bar: ShellBarData,
        vertical: Bool,
        dark: Bool,
        directory: String,
        background: CGColor?
    ) throws {
        let suffix = "\(profile)-\(vertical ? "vertical" : "horizontal")"
        let variants: [(String, ShellServiceValue)] = switch name {
        case "stats": [("graph", .object(["variant": .text("graph")])), ("gauge", .object(["variant": .text("gauge")]))]
        case "privacy": [("icons", .object(["icons": .bool(true)]))]
        case "world-clock": [("two", .object(["bar": .number(2)]))]
        case "launcher": [("mode", .object(["mode": .text("windows"), "symbol": .text("macwindow")]))]
        default: []
        }
        for (variant, settings) in variants {
            statusFixture(widget, name: name)
            widget.set("settings") { settings.write(to: &$0) }
            if variant == "graph" { feedStatsHistory(widget, bar: bar) }
            widget.render(bar)
            try ShellBundledWidgetTests.writeSnapshot(
                widget.surface, name: "\(name)-\(suffix)-\(variant)\(dark ? "-dark" : "")",
                dark: dark, directory: directory, background: background
            )
            if variant == "graph", !vertical {
                widget.layoutPopout()
                try ShellBundledWidgetTests.writeSnapshot(
                    widget.surface, name: "\(name)-\(profile)-popout-graph\(dark ? "-dark" : "")",
                    dark: dark, directory: directory, background: background
                )
            }
        }
        if !variants.isEmpty {
            widget.set("settings") { ShellServiceValue.object([:]).write(to: &$0) }
            statusFixture(widget, name: name)
            widget.render(bar)
        }
        guard ["input-source", "world-clock", "stats"].contains(name), !vertical else { return }
        widget.layoutPopout()
        try ShellBundledWidgetTests.writeSnapshot(
            widget.surface, name: "\(name)-\(profile)-popout-\(dark ? "dark" : "light")",
            dark: dark, directory: directory, background: background
        )
        if name == "input-source", !dark {
            widget.set("inputSource") { $0.null() }
            widget.layoutPopout()
            try ShellBundledWidgetTests.writeSnapshot(
                widget.surface, name: "\(name)-\(profile)-popout-unavailable",
                dark: false, directory: directory, background: background
            )
            statusFixture(widget, name: name)
        }
    }

    private func wifiFixture(
        _ widget: ShellRenderedWidget,
        _ wifi: ShellWiFi = ShellWiFi(
            power: true, connected: true, ssid: "Harbour Home", rssi: -55, band: "5 GHz", channel: 36,
            security: "WPA3 Personal", location: "authorized"
        )
    ) {
        widget.set("wifi") { wifi.write(into: &$0) }
    }

    private func bluetoothFixture(
        _ widget: ShellRenderedWidget,
        _ bluetooth: ShellBluetooth = ShellBluetooth(power: true, access: "granted", devices: [
            ShellBluetoothDevice(id: "airpods", name: "AirPods Pro", kind: "headphones", connected: true, battery: 80),
            ShellBluetoothDevice(
                id: "keyboard",
                name: "Magic Keyboard",
                kind: "keyboard",
                connected: true,
                battery: 15
            ),
            ShellBluetoothDevice(id: "mouse", name: "Magic Mouse", kind: "mouse", connected: false)
        ])
    ) {
        widget.set("bluetooth") { bluetooth.write(into: &$0) }
    }

    private func batteryFixture(
        _ widget: ShellRenderedWidget,
        level: Double = 76,
        charging: Bool = false,
        power: ShellPower = ShellPower(source: "battery", remaining: 254)
    ) {
        widget.set("battery") { $0.number(level) }
        widget.set("charging") { $0.bool(charging) }
        widget.set("power") { power.write(into: &$0) }
    }

    @discardableResult
    private func weatherFixture(
        _ widget: ShellRenderedWidget,
        stale: Bool = false,
        unit: String = "°C",
        flatRange: Bool = false
    ) -> ShellWeather {
        let codes = [2, 1, 2, 3, 61, 63, 80, 95, 3, 2, 1, 0, 0, 1]
        let weather = ShellWeather(
            temp: 18.4, feels: 17, high: 21, low: 11, rain: 30, wind: 14, humidity: 64, sunrise: 999_000,
            sunset: 1_040_000, code: 2, day: true, unit: unit, place: "Toronto", stale: stale,
            hours: (0 ..< 14).map { index in ShellWeatherHour(
                time: 1_000_000 + Double(index) * 3600, label: index == 0 ? "Now" : "\((9 + index) % 24)",
                temp: 18 + sin(Double(index) / 3) * 3, code: codes[index], day: index < 10, rain: Double(index * 5)
            ) },
            days: ["Today", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu"].enumerated().map { index, label in
                ShellWeatherDay(
                    time: 1_000_000 + Double(index) * 86400, label: label,
                    high: flatRange ? 10 : [21, 19, 23, 17, 15, 18, 22][index],
                    low: flatRange ? 10 : [11, 10, 13, 9, 7, 8, 12][index],
                    code: [2, 61, 0, 63, 95, 3, 1][index], rain: [30, 80, 0, 60, 90, 20, 10][index]
                )
            }
        )
        widget.set("weather") { weather.write(into: &$0) }
        return weather
    }

    private func mediaFixture(
        _ widget: ShellRenderedWidget,
        playing: Bool = true,
        title: String = "Northern Lights",
        elapsed: Double? = 87,
        duration: Double? = 243,
        shuffle: Bool? = false,
        repeatMode: ShellMedia.Repeat? = .all,
        lyrics: ShellLyrics = ShellLyrics(status: .synced, lines: [
            .init(time: 80, text: "Lights across the harbour"),
            .init(time: 86, text: "Waiting for the morning train"),
            .init(time: 92, text: ""),
            .init(time: 98, text: "Every window holds a song"),
            .init(time: 104, text: "Carried on the evening rain"),
            .init(time: 110, text: "Until the city sings along")
        ])
    ) {
        var media = ShellMedia()
        media.title = title
        media.artist = "Sample Artist"
        media.album = "Sample Album"
        media.app = "Music"
        media.bundle = "com.apple.Music"
        media.playing = playing
        media.duration = duration
        media.elapsed = elapsed
        media.rate = playing ? 1 : 0
        media.sampledAt = 1000
        media.shuffle = shuffle
        media.repeatMode = repeatMode
        widget.set("media") { media.write(into: &$0) }
        widget.set("seconds") { $0.number(1012) }
        widget.set("lyrics") { lyrics.write(into: &$0) }
    }

    private func networkFixture(_ widget: ShellRenderedWidget) {
        widget.set("network") {
            ShellServiceValue.object(["down": .number(1_840_000), "up": .number(312_000)]).write(to: &$0)
        }
    }

    private func systemStatsFixture(_ widget: ShellRenderedWidget) {
        widget.set("system") { writer in
            ShellSystemData(
                memoryUsed: 21 << 30,
                memoryTotal: 36 << 30,
                pressure: .normal,
                diskUsed: 612_000_000_000,
                diskTotal: 994_000_000_000,
                uptime: 273_840,
                host: SystemStatsHostInfo(
                    chip: "Apple M4 Max",
                    modelIdentifier: "Mac16,9",
                    osVersion: "Version 27.2",
                    hostname: "studio"
                ),
                displays: [
                    ShellSystemDisplay(width: 5120, height: 2880, refresh: 120),
                    ShellSystemDisplay(width: 3024, height: 1964, refresh: 120)
                ]
            ).write(into: &writer)
        }
        widget.set("cpu") { $0.number(37) }
        widget.set("gpu") { $0.number(18) }
        widget.set("memory") { $0.number(58) }
        widget.set("disk") { $0.number(62) }
        widget.set("thermal") { ShellThermal(cpu: 61, gpu: 48, gpuName: "Apple M4 Max GPU").write(into: &$0) }
        networkFixture(widget)
        var history = ShellNetworkHistory(received: 18_400_000_000, sent: 2_100_000_000)
        for index in 0 ..< ShellNetworkHistory.length {
            let phase = Double(index) / 4
            history.append(ShellNetworkRate(down: 900_000 + sin(phase) * 700_000, up: 200_000 + cos(phase) * 120_000))
        }
        widget.set("networkHistory") { history.write(into: &$0) }
        batteryFixture(widget)
    }

    private func hiddenBarFixture(vertical: Bool, menu: Bool) -> ShellHiddenBarData {
        ShellHiddenBarData(
            enabled: true, available: true,
            items: (0 ..< 5).map {
                ShellHiddenBarItem(id: "app#\($0)", name: "Hidden App \($0)", image: nil, width: 24, height: 16)
            },
            maxWidth: 240, maxHeight: menu ? 220 : 60, cell: 24, vertical: vertical,
            menu: menu ? HiddenBarMenuPage(title: "Options", rows: [
                hiddenMenuFixtureRow("checked", title: "Checked item", mark: "✓", shortcut: "⌘K"),
                hiddenMenuFixtureRow("disabled", title: "Disabled item", enabled: false),
                hiddenMenuFixtureRow("separator", title: "", enabled: false, separator: true),
                hiddenMenuFixtureRow("submenu", title: "More options", submenu: true)
            ], backID: "back") : nil
        )
    }

    private func hiddenMenuFixtureRow(
        _ id: String,
        title: String,
        enabled: Bool = true,
        mark: String? = nil,
        shortcut: String? = nil,
        submenu: Bool = false,
        separator: Bool = false
    ) -> HiddenBarMenuRow {
        HiddenBarMenuRow(
            id: id, title: title, enabled: enabled, mark: mark,
            shortcut: shortcut, submenu: submenu, separator: separator
        )
    }

    private func stepShell(_ environment: [String: String]) throws -> URL {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(try ShellStyleFixture.prepare(
            into: shell,
            from: environment["OMNIWM_STEP_FROM"].map { URL(fileURLWithPath: $0) } ?? ShellDefaults.bundled,
            styles: environment["OMNIWM_STEP_STYLES"].map { URL(fileURLWithPath: $0) } ?? ShellStyleFixture.directory
        ), [])
        return shell
    }

    private func renderDependencies(_ widget: ShellRenderedWidget, view: omni_view) -> UInt64 {
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_instance_render(widget.instance, view, 100_000_000, &stats, &error, error.count), OMNI_OK
        )
        return stats.deps
    }

    private func makeWidget(
        _ name: String,
        config: ShellConfig,
        shell: URL,
        scale: CGFloat = 2,
        resources: ShellResources? = nil,
        source override: URL? = nil
    ) throws -> ShellRenderedWidget {
        let source = try override ?? XCTUnwrap(config.widget(name))
        let chunk = String(source.path.dropFirst(shell.path.count + 1))
        let profile = chunk.split(separator: "/").first.map(String.init) ?? config.profile
        var modules: [ShellWidgetSource.Module] = []
        var seen: Set<String> = []
        for directory in config.directories {
            let library = directory.appendingPathComponent("lib")
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
                where entry.hasSuffix(".luau") && seen.insert(entry).inserted
            {
                modules.append(try ShellWidgetSource.Module(
                    path: "\(profile)/lib/\(entry)",
                    source: String(contentsOf: library.appendingPathComponent(entry), encoding: .utf8)
                ))
            }
        }
        let widget = try ShellRenderedWidget(
            name: name, source: String(contentsOf: source, encoding: .utf8), directories: config.directories,
            modules: modules, chunk: "@" + chunk, scale: scale, resources: resources
        )
        if let settings = config.widgetSettings[name] {
            XCTAssertEqual(settings.withUnsafeBufferPointer {
                omni_instance_set_value(widget.instance, "settings", $0.baseAddress, $0.count)
            }, OMNI_OK)
        }
        return widget
    }

    private func scratchpadFixture(_ config: ShellConfig, height: Double, vertical: Bool) -> ShellBarData {
        var bar = fixture(config, height: height, vertical: vertical)
        bar.style.accents = true
        let members = (0 ..< 5).map { index in
            ShellBarItem(
                id: "\(index)",
                bundle: applications[index % applications.count],
                name: "App \(index)",
                focused: index == 0,
                count: index == 1 ? 2 : 1,
                hidden: 0,
                badge: ["7", "42", "999+", "3", ""][index],
                windows: [
                    ShellBarWindow(
                        id: "scratch-\(index)",
                        title: "Window \(index)",
                        focused: index == 0,
                        hidden: false
                    )
                ]
            )
        }
        bar.scratchpads = [
            ShellBarScratchpad(
                id: 1,
                name: "Terminal sessions",
                focused: true,
                revealed: true,
                visible: true,
                windows: members
            ),
            ShellBarScratchpad(
                id: 2,
                name: "Chat",
                focused: false,
                revealed: false,
                visible: false,
                windows: [members[3]],
                compact: true
            ),
            ShellBarScratchpad(
                id: 3,
                name: "Music",
                focused: false,
                revealed: false,
                visible: true,
                windows: [members[4]]
            )
        ]
        return bar
    }

    private func fixture(_ config: ShellConfig, height: Double, vertical: Bool) -> ShellBarData {
        var bar = ShellBarData(badges: "text")
        let settings = config.barOverride?.settings
        bar.style.labels = settings?.showLabels ?? bar.style.labels
        bar.style.backgrounds = settings?.showItemBackgrounds ?? bar.style.backgrounds
        bar.style.accents = settings?.showAccentHighlights ?? bar.style.accents
        bar.style.transparent = settings?.transparentBackground ?? bar.style.transparent
        bar.style.solidBlack = settings?.solidBlackBackground ?? bar.style.solidBlack
        bar.style.height = height
        bar.style.vertical = vertical
        bar.style.statsButton = true
        bar.style.position = vertical ? "left" : "top"
        let items = applications.enumerated().map { index, bundle in
            ShellBarItem(
                id: "\(index)", bundle: bundle, name: ["Safari", "Terminal", "Finder", "Notes"][index],
                focused: index == 0, count: index == 1 ? 2 : 1, hidden: index == 1 || index == 2 ? 1 : 0,
                badge: index == 0 ? "3" : "", floating: index == 3,
                windows: (0 ..< (index == 1 ? 2 : 1)).map { window in
                    ShellBarWindow(
                        id: "\(index)_\(window)", title: "Window \(index)-\(window)",
                        focused: index == 0, hidden: index == 2 || index == 1 && window == 0
                    )
                }
            )
        }
        bar.workspaces = [
            ShellBarWorkspace(id: "1", name: "1", focused: true, windows: Array(items.prefix(2))),
            ShellBarWorkspace(id: "2", name: "2", focused: false, windows: Array(items.suffix(2))),
            ShellBarWorkspace(id: "3", name: "3", focused: false, windows: [])
        ]
        bar.scratchpads = [
            ShellBarScratchpad(id: 1, name: "Chat", focused: false, revealed: true, visible: true, windows: [items[3]])
        ]
        return bar
    }

    private func raster(_ surface: ShellWidgetSurface, scale: CGFloat) throws -> CGImage {
        ShellLayerScene.engineQueue.sync {}
        let size = surface.size
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        try XCTUnwrap(surface.view.layer).render(in: context)
        return try XCTUnwrap(context.makeImage())
    }

    private func write(
        _ previews: [(String, CGImage, CGSize)],
        name: String,
        scale: CGFloat,
        dark: Bool,
        solidBlack: Bool
    ) throws {
        let spacing: CGFloat = 24
        let width = previews.reduce(spacing) { $0 + $1.2.width + spacing }
        let height = (previews.map { $0.2.height }.max() ?? 0) + spacing * 2
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil(width * scale)), height: Int(ceil(height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: solidBlack ? 0 : dark ? 0.09 : 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = spacing
        for (_, image, size) in previews {
            context.draw(
                image,
                in: CGRect(x: x, y: height - spacing - size.height, width: size.width, height: size.height)
            )
            x += size.width + spacing
        }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            directory.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

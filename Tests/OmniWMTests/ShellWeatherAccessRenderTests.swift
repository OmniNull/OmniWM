// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellWeatherAccessRenderTests: XCTestCase {
    func testControlCenterWeatherContentShowsTheAccessReason() throws {
        try withWidget("control-center", profile: "default") { widget in
            widget.set("settings") { ShellServiceValue.object(["tab": .text("weather")]).write(to: &$0) }
            for access in [ShellServiceAccess.off, .blocked] {
                try assertAccessReason(access, in: widget)
                XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])))
            }
        }
    }

    func testCelestialDashboardWeatherCardShowsTheAccessReason() throws {
        try withWidget("dashboard", profile: "celestial") { widget in
            for access in [ShellServiceAccess.off, .blocked] {
                try assertAccessReason(access, in: widget)
            }
        }
    }

    func testCelestialDashboardWeatherTabShowsTheAccessReason() throws {
        try withWidget("dashboard", profile: "celestial") { widget in
            widget.set("weather") { ShellWeather.unavailable(.off).write(into: &$0) }
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
            let action = try XCTUnwrap(widget.actions.last)
            XCTAssertEqual(widget.invoke(action, view: OMNI_VIEW_POPOUT), [])
            for access in [ShellServiceAccess.off, .blocked] {
                try assertAccessReason(access, in: widget)
                XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Unavailable", [])))
            }
        }
    }

    private func assertAccessReason(_ access: ShellServiceAccess, in widget: ShellRenderedWidget) throws {
        widget.set("weather") { ShellWeather.unavailable(access).write(into: &$0) }
        _ = widget.renderPopout()
        let reason = access == .off ? "Turned off in Settings" : "Blocked by your organization"
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(reason, [])), access.rawValue)
    }

    private func withWidget(
        _ name: String,
        profile: String,
        body: (ShellRenderedWidget) throws -> Void
    ) throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        if profile != "default" { XCTAssertTrue(try ShellProfiles.select(profile, in: shell)) }
        let config = ShellConfig.resolve(shellDirectory: shell)
        let source = try ShellWidgetSourceLoader.build(.init(
            name: name,
            shellDirectory: shell,
            sourceURL: try XCTUnwrap(config.widget(name)),
            directories: config.directories,
            profile: profile
        ))
        let widget = try ShellRenderedWidget(
            name: name,
            source: source.main,
            directories: config.directories,
            modules: source.modules,
            chunk: source.chunk
        )
        widget.set("clock") { $0.string("9:41 AM") }
        widget.render(ShellBarData())
        try body(widget)
    }
}

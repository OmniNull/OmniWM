// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarFullWidthTests: XCTestCase {
    private func monitor(notch: ClosedRange<CGFloat>? = nil) -> Monitor {
        Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 100, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 160, y: 60, width: 1452, height: 890),
            hasNotch: notch != nil,
            notchRange: notch,
            name: "Built-in"
        )
    }

    private func settings(_ configure: (WorkspaceBarSettings) -> Void = { _ in }) -> WorkspaceBarSettings {
        let settings = WorkspaceBarSettings()
        settings.fullWidth = true
        settings.height = 24
        configure(settings)
        return settings
    }

    private func frame(_ settings: WorkspaceBarSettings, on monitor: Monitor) -> CGRect {
        let resolved = settings.resolved(for: monitor)
        return WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            .frame(fittingLength: 100, monitor: monitor, resolved: resolved)
    }

    func testFullWidthFramesSpanEachEdge() {
        let monitor = monitor()
        let expected: [(WorkspaceBarPosition, CGRect)] = [
            (.overlappingMenuBar, CGRect(x: 100, y: 958, width: 1512, height: 24)),
            (.belowMenuBar, CGRect(x: 160, y: 926, width: 1452, height: 24)),
            (.bottom, CGRect(x: 160, y: 60, width: 1452, height: 24)),
            (.left, CGRect(x: 160, y: 60, width: 24, height: 890)),
            (.right, CGRect(x: 1588, y: 60, width: 24, height: 890))
        ]
        for (position, rect) in expected {
            XCTAssertEqual(frame(settings { $0.position = position }, on: monitor), rect, "\(position)")
        }
        let pill = frame(settings { $0.fullWidth = false }, on: monitor)
        XCTAssertEqual(pill.width, 100)
        XCTAssertEqual(frame(settings { $0.yOffset = -4 }, on: monitor).minY, 954)
    }

    func testFullWidthReplacesThePillNotchModes() {
        let notched = monitor(notch: 756 ... 956)
        let bar = settings {
            $0.notchMode = .splitActiveLeft
            $0.fullWidthNotchMode = .rightOfNotch
        }
        XCTAssertTrue(bar.resolved(for: notched).fullWidth)
        XCTAssertEqual(bar.resolved(for: notched).notchMode, .off)
        XCTAssertEqual(frame(bar, on: notched).width, 1512)

        bar.fullWidthNotchMode = .moveBelowMenuBar
        XCTAssertEqual(bar.resolved(for: notched).notchMode, .moveBelowMenuBar)
        XCTAssertEqual(frame(bar, on: notched), CGRect(x: 160, y: 926, width: 1452, height: 24))
        XCTAssertEqual(frame(bar, on: monitor()).minY, 958)

        bar.update(MonitorBarSettings(monitorName: "Built-in", monitorDisplayId: 7, fullWidth: false), for: notched)
        XCTAssertFalse(bar.resolved(for: notched).fullWidth)
        XCTAssertEqual(bar.resolved(for: notched).notchMode, .splitActiveLeft)
    }

    func testZonesCarryTheNotchInBarCoordinatesOnlyAtTheMenuBar() {
        let notched = monitor(notch: 756 ... 956)
        let bar = settings { $0.fullWidthNotchMode = .splitAroundNotch }
        func zones(_ bar: WorkspaceBarSettings) -> WorkspaceBarZones? {
            let resolved = bar.resolved(for: notched)
            let geometry = WorkspaceBarGeometry.resolve(monitor: notched, resolved: resolved, isVisible: true)
            return geometry.zones(frame: frame(bar, on: notched), monitor: notched, resolved: resolved)
        }
        XCTAssertEqual(zones(bar), WorkspaceBarZones(notch: 656 ... 856, mode: .splitAroundNotch))
        bar.position = .bottom
        XCTAssertEqual(zones(bar), WorkspaceBarZones(notch: nil, mode: .splitAroundNotch))
        bar.fullWidth = false
        XCTAssertNil(zones(bar))
    }

    func testCenterWidgetsFollowTheNotchModeAndEdgesStayPinned() {
        let items: [(lane: ShellLane, length: CGFloat)] = [
            (.leading, 50), (.leading, 30), (.center, 40), (.center, 20), (.center, 10), (.trailing, 60)
        ]
        func offsets(_ mode: WorkspaceBarFullWidthNotchMode, notch: ClosedRange<CGFloat>? = 400 ... 600) -> [CGFloat] {
            WorkspaceBarZoneLayout.offsets(
                of: items,
                length: 1000,
                zones: WorkspaceBarZones(notch: notch, mode: mode),
                spacing: 8,
                inset: 4
            )
        }
        XCTAssertEqual(offsets(.rightOfNotch), [4, 62, 608, 656, 684, 936])
        XCTAssertEqual(offsets(.leftOfNotch), [4, 62, 306, 354, 382, 936])
        XCTAssertEqual(offsets(.splitAroundNotch), [4, 62, 324, 372, 608, 936])
        XCTAssertEqual(offsets(.off), [4, 62, 457, 505, 533, 936])
        XCTAssertEqual(offsets(.rightOfNotch, notch: nil), [4, 62, 457, 505, 533, 936])
    }

    func testTheBarViewPlacesWidgetsInTheirZones() {
        let names = ["left", "middle", "right"]
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: 0.1,
            barHeight: 24,
            shellWidgets: zip(names, [ShellLane.leading, .center, .trailing]).map {
                WorkspaceBarShellWidget(id: $0, size: CGSize(width: 40, height: 20), lane: $1)
            }
        )
        let views = Dictionary(uniqueKeysWithValues: names.map { ($0, NSView()) })
        func minX(zones: WorkspaceBarZones?) -> [CGFloat] {
            let model = WorkspaceBarModel(snapshot: snapshot)
            model.zones = zones
            let host = NSHostingView(rootView: WorkspaceBarView(
                model: model,
                motionPolicy: MotionPolicy(animationsEnabled: false),
                shellSurface: { views[$0] }
            ))
            host.frame = CGRect(x: 0, y: 0, width: 1000, height: 24)
            host.layoutSubtreeIfNeeded()
            defer { names.forEach { views[$0]?.removeFromSuperview() } }
            return names.map { views[$0]!.convert(views[$0]!.bounds, to: host).minX.rounded() }
        }
        XCTAssertEqual(minX(zones: WorkspaceBarZones(notch: 400 ... 600, mode: .rightOfNotch)), [4, 608, 956])
        XCTAssertEqual(minX(zones: WorkspaceBarZones(notch: nil, mode: .rightOfNotch)), [4, 480, 956])
        XCTAssertEqual(minX(zones: nil), [432, 480, 528])
    }

    func testFullWidthRoundTripsAndProfilesCanSetIt() throws {
        XCTAssertFalse(SettingsExport.defaults().workspaceBar.fullWidth)
        XCTAssertEqual(SettingsExport.defaults().workspaceBar.fullWidthNotchMode, .rightOfNotch)

        var export = SettingsExport.defaults()
        export.workspaceBar.fullWidth = true
        export.workspaceBar.fullWidthNotchMode = .splitAroundNotch
        export.monitorBarSettings = [
            MonitorBarSettings(monitorName: "Built-in", fullWidth: false, fullWidthNotchMode: .leftOfNotch),
            MonitorBarSettings(monitorName: "External")
        ]
        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("fullWidthNotchMode = \"splitAroundNotch\""))
        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded.workspaceBar, export.workspaceBar)
        XCTAssertEqual(decoded.monitorBarSettings[0].fullWidth, false)
        XCTAssertEqual(decoded.monitorBarSettings[0].fullWidthNotchMode, .leftOfNotch)
        XCTAssertNil(decoded.monitorBarSettings[1].fullWidth)

        let stripped = toml.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("fullWidth") }
            .joined(separator: "\n")
        XCTAssertFalse(try SettingsTOMLCodec.decode(Data(stripped.utf8)).workspaceBar.fullWidth)

        let applied = WorkspaceBarSettings()
        applied.applyIdentity(decoded.workspaceBar)
        XCTAssertTrue(applied.fullWidth)
        XCTAssertEqual(applied.export().fullWidthNotchMode, .splitAroundNotch)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[profiles.default.workspaceBar]\nfullWidth = true\nfullWidthNotchMode = \"leftOfNotch\"\n".utf8)
            .write(to: root.appendingPathComponent("shell.toml"))
        let override = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertEqual(override.overriddenKeys, ["accentColor", "fullWidth", "fullWidthNotchMode", "textColor"])
        let bar = WorkspaceBarSettings()
        bar.profileOverride = override
        XCTAssertTrue(bar.resolved(for: monitor()).fullWidth)
        XCTAssertEqual(bar.resolved(for: monitor()).fullWidthNotchMode, .leftOfNotch)
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarRevealSettingsTests: XCTestCase {
    func testDefaultsRoundTrip() throws {
        XCTAssertEqual(SettingsExport.defaults().workspaceBar.revealModifier, .off)
        XCTAssertEqual(SettingsExport.defaults().workspaceBar.revealHoldMilliseconds, 200)

        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("revealModifier = \"off\""))
        XCTAssertTrue(toml.contains("revealHoldMilliseconds = 200"))

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded.workspaceBar.revealModifier, .off)
        XCTAssertEqual(decoded.workspaceBar.revealHoldMilliseconds, 200)
    }

    func testNonDefaultRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.workspaceBar.revealModifier = .controlOptionCommand
        export.workspaceBar.revealHoldMilliseconds = 350

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("revealModifier = \"controlOptionCommand\""))
        XCTAssertTrue(toml.contains("revealHoldMilliseconds = 350"))

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded.workspaceBar.revealModifier, .controlOptionCommand)
        XCTAssertEqual(decoded.workspaceBar.revealHoldMilliseconds, 350)
    }

    func testAutoHideDefaultsAndLegacyModifierSettingsRoundTrip() throws {
        var export = SettingsExport.defaults()
        XCTAssertFalse(export.workspaceBar.autoHide)
        export.workspaceBar.autoHide = true
        export.workspaceBar.revealModifier = .option
        export.monitorBarSettings = [MonitorBarSettings(monitorName: "External", autoHide: false)]
        let data = try SettingsTOMLCodec.encode(export)
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
        let legacy = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "autoHide = true\n", with: "")
            .replacingOccurrences(of: "[[monitorBarOverrides]]\nautoHide = false\n", with: "[[monitorBarOverrides]]\n")
        let decoded = try SettingsTOMLCodec.decode(Data(legacy.utf8))
        XCTAssertFalse(decoded.workspaceBar.autoHide)
        XCTAssertEqual(decoded.workspaceBar.revealModifier, .option)
        XCTAssertNil(decoded.monitorBarSettings[0].autoHide)
    }

    @MainActor
    func testAutoHideOverridesReserveNoSpaceAtAnyEdge() {
        let settings = makeSettingsStore()
        settings.workspaceBar.autoHide = true
        settings.workspaceBar.reserveLayoutSpace = true
        let controller = WMController(settings: settings)
        let monitor = Monitor(
            id: .init(displayId: 1), displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false, name: "Test"
        )
        for position in WorkspaceBarPosition.allCases {
            settings.workspaceBar.position = position
            XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
            XCTAssertEqual(WorkspaceBarGeometry.resolve(
                monitor: monitor, resolved: settings.workspaceBar.resolved(for: monitor), isVisible: true
            ).reservedInsets, .zero)
            let before = controller.layoutFrames(for: monitor, scale: 1)
            controller.setWorkspaceBarRevealHeld(true)
            XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
            XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 1).workingFrame, before.workingFrame)
            XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), monitor.visibleFrame)
            controller.setWorkspaceBarRevealHeld(false)
        }
        settings.workspaceBar.update(MonitorBarSettings(monitorName: monitor.name, autoHide: false), for: monitor)
        XCTAssertFalse(settings.workspaceBar.resolved(for: monitor).autoHide)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        settings.workspaceBar.remove(for: monitor)
        XCTAssertTrue(settings.workspaceBar.resolved(for: monitor).autoHide)
        XCTAssertTrue(settings.workspaceBar.export().autoHide)
        let restored = makeSettingsStore()
        restored.applyExport(settings.toExport())
        XCTAssertTrue(restored.workspaceBar.autoHide)
    }

    @MainActor
    func testApplyExportClampsDelay() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()

        export.workspaceBar.revealModifier = .option
        export.workspaceBar.revealHoldMilliseconds = -50
        settings.applyExport(export)
        XCTAssertEqual(settings.workspaceBar.revealModifier, .option)
        XCTAssertEqual(settings.workspaceBar.revealHoldMilliseconds, 0)

        export.workspaceBar.revealHoldMilliseconds = 5000
        settings.applyExport(export)
        XCTAssertEqual(settings.workspaceBar.revealHoldMilliseconds, 1000)
    }

    @MainActor
    func testRevealModeIsOverlayOnlyAndOffModePreservesReservation() {
        let settings = makeSettingsStore()
        settings.workspaceBar.enabled = true
        settings.workspaceBar.reserveLayoutSpace = true
        settings.workspaceBar.height = 24
        settings.workspaceBar.position = .belowMenuBar
        settings.workspaceBar.revealModifier = .option
        let controller = WMController(settings: settings)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Built-in"
        )

        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertEqual(
            controller.insetWorkingFrame(for: monitor),
            CGRect(x: 5, y: 5, width: 1430, height: 850)
        )
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), monitor.visibleFrame)

        controller.setWorkspaceBarRevealHeld(true)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertEqual(
            controller.insetWorkingFrame(for: monitor),
            CGRect(x: 5, y: 5, width: 1430, height: 850)
        )
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), monitor.visibleFrame)

        settings.workspaceBar.revealModifier = .off
        controller.setWorkspaceBarRevealHeld(false)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertEqual(
            controller.insetWorkingFrame(for: monitor),
            CGRect(x: 5, y: 5, width: 1430, height: 831)
        )
        XCTAssertEqual(
            controller.fullscreenLayoutFrame(for: monitor),
            CGRect(x: 0, y: 0, width: 1440, height: 836)
        )
    }

    @MainActor
    func testRevealModeKeepsFullscreenOuterGapsButDropsReservation() {
        let settings = makeSettingsStore()
        settings.gaps.outerGapLeft = 12
        settings.gaps.outerGapRight = 12
        settings.gaps.outerGapTop = 46
        settings.gaps.outerGapBottom = 14
        settings.gaps.fullscreenUsesOuterGaps = true
        settings.workspaceBar.enabled = true
        settings.workspaceBar.reserveLayoutSpace = true
        settings.workspaceBar.height = 24
        settings.workspaceBar.position = .belowMenuBar
        settings.workspaceBar.revealModifier = .option
        let controller = WMController(settings: settings)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Built-in"
        )

        let overlayFrame = CGRect(x: 12, y: 14, width: 1416, height: 840)
        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), overlayFrame)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), overlayFrame)

        controller.setWorkspaceBarRevealHeld(true)
        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), overlayFrame)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), overlayFrame)

        settings.workspaceBar.revealModifier = .off
        controller.setWorkspaceBarRevealHeld(false)
        let reservedFrame = CGRect(x: 12, y: 14, width: 1416, height: 816)
        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), reservedFrame)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), reservedFrame)
    }

    private func defaultsDroppingLines(containing fragments: String...) throws -> Data {
        let toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let lines = toml.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            !fragments.contains { line.contains($0) }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceBarRevealTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}

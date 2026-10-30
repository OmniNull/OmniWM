// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarRevealSettingsTests: XCTestCase {
    func testDefaultAndCustomRevealSettingsRoundTrip() throws {
        XCTAssertEqual(SettingsExport.defaults().workspaceBar.revealModifier, .off)
        XCTAssertEqual(SettingsExport.defaults().workspaceBar.revealHoldMilliseconds, 200)
        let cases: [(WorkspaceBarRevealModifier, Double, String)] = [
            (.off, 200, "off"), (.controlOptionCommand, 350, "controlOptionCommand")
        ]
        for (modifier, delay, literal) in cases {
            var export = SettingsExport.defaults()
            export.workspaceBar.revealModifier = modifier
            export.workspaceBar.revealHoldMilliseconds = delay
            let data = try SettingsTOMLCodec.encode(export)
            let toml = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(toml.contains("revealModifier = \"\(literal)\""))
            XCTAssertTrue(toml.contains("revealHoldMilliseconds = \(delay)"))
            let decoded = try SettingsTOMLCodec.decode(data)
            XCTAssertEqual(decoded.workspaceBar.revealModifier, modifier)
            XCTAssertEqual(decoded.workspaceBar.revealHoldMilliseconds, delay)
        }
    }

    func testAutoHideDefaultsAndLegacyModifierSettingsRoundTrip() throws {
        var export = SettingsExport.defaults()
        XCTAssertFalse(export.workspaceBar.autoHide)
        export.workspaceBar.autoHide = true
        export.workspaceBar.autoHideRevealDelayMilliseconds = 300
        export.workspaceBar.autoHideHideDelayMilliseconds = 450
        export.workspaceBar.revealModifier = .option
        export.monitorBarSettings = [MonitorBarSettings(monitorName: "External", autoHide: false)]
        let data = try SettingsTOMLCodec.encode(export)
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
        let legacy = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "autoHide = true\n", with: "")
            .replacingOccurrences(of: "autoHideRevealDelayMilliseconds = 300.0\n", with: "")
            .replacingOccurrences(of: "autoHideHideDelayMilliseconds = 450.0\n", with: "")
            .replacingOccurrences(of: "[[monitorBarOverrides]]\nautoHide = false\n", with: "[[monitorBarOverrides]]\n")
        let decoded = try SettingsTOMLCodec.decode(Data(legacy.utf8))
        XCTAssertFalse(decoded.workspaceBar.autoHide)
        XCTAssertEqual(decoded.workspaceBar.autoHideRevealDelayMilliseconds, 0)
        XCTAssertEqual(decoded.workspaceBar.autoHideHideDelayMilliseconds, 0)
        XCTAssertEqual(decoded.workspaceBar.revealModifier, .option)
        XCTAssertNil(decoded.monitorBarSettings[0].autoHide)
    }

    @MainActor
    func testAutoHideOverridesReserveNoSpaceAtAnyEdge() {
        let settings = makeSettingsStore()
        settings.workspaceBar.revealModifier = .off
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
            XCTAssertEqual(controller.workspaceBarReservedInsets(for: monitor), .zero)
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
    func testRevealModifierRespectsAutoHideOnEachMonitor() throws {
        let builtIn = Monitor(
            id: .init(displayId: 1), displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false, name: "Built-in Retina Display"
        )
        let external = Monitor(
            id: .init(displayId: 2), displayId: 2,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1040),
            hasNotch: false, name: "External"
        )
        for autoHide in [false, true] {
            let settings = makeSettingsStore()
            var export = SettingsExport.defaults()
            export.workspaceBar.enabled = true
            export.workspaceBar.autoHide = autoHide
            export.workspaceBar.revealModifier = .controlShift
            export.workspaceBar.reserveLayoutSpace = true
            export.workspaceBar.position = .belowMenuBar
            export.workspaceBar.height = 24
            export.monitorBarSettings = [MonitorBarSettings(
                monitorName: builtIn.name, monitorDisplayUUID: builtIn.displayUUID,
                monitorDisplayId: builtIn.displayId, autoHide: !autoHide
            )]
            settings.applyExport(try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export)))
            XCTAssertEqual(settings.workspaceBar.resolved(for: builtIn).autoHide, !autoHide)
            XCTAssertEqual(settings.workspaceBar.resolved(for: external).autoHide, autoHide)
            let controller = WMController(settings: settings)
            for held in [false, true, false] {
                controller.setWorkspaceBarRevealHeld(held)
                for monitor in [builtIn, external] {
                    let hides = monitor.id == builtIn.id ? !autoHide : autoHide
                    XCTAssertEqual(controller.isWorkspaceBarVisible(on: monitor), !hides || held, monitor.name)
                    XCTAssertEqual(
                        controller.workspaceBarReservedInsets(for: monitor), hides ? .zero : Struts(top: 24),
                        monitor.name
                    )
                }
            }
        }
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

        export.workspaceBar.autoHideRevealDelayMilliseconds = -50
        export.workspaceBar.autoHideHideDelayMilliseconds = 5000
        settings.applyExport(export)
        XCTAssertEqual(settings.workspaceBar.autoHideRevealDelayMilliseconds, 0)
        XCTAssertEqual(settings.workspaceBar.autoHideHideDelayMilliseconds, 1000)

        export.workspaceBar.autoHideRevealDelayMilliseconds = .nan
        settings.applyExport(export)
        XCTAssertEqual(settings.workspaceBar.autoHideRevealDelayMilliseconds, 0)
    }

    @MainActor
    func testAutoHideIsOverlayOnlyAndAlwaysVisibleBarPreservesReservation() {
        let cases: [(
            customGaps: Bool,
            overlayWorking: CGRect,
            overlayFullscreen: CGRect,
            reservedWorking: CGRect,
            reservedFullscreen: CGRect
        )] = [
            (
                false,
                CGRect(x: 5, y: 5, width: 1430, height: 850),
                CGRect(x: 0, y: 0, width: 1440, height: 860),
                CGRect(x: 5, y: 5, width: 1430, height: 831),
                CGRect(x: 0, y: 0, width: 1440, height: 836)
            ),
            (
                true,
                CGRect(x: 12, y: 14, width: 1416, height: 840),
                CGRect(x: 12, y: 14, width: 1416, height: 840),
                CGRect(x: 12, y: 14, width: 1416, height: 816),
                CGRect(x: 12, y: 14, width: 1416, height: 816)
            )
        ]
        for entry in cases {
            let settings = makeSettingsStore()
            if entry.customGaps {
                settings.gaps.outerGapLeft = 12
                settings.gaps.outerGapRight = 12
                settings.gaps.outerGapTop = 46
                settings.gaps.outerGapBottom = 14
            }
            settings.gaps.fullscreenUsesOuterGaps = entry.customGaps
            settings.workspaceBar.enabled = true
            settings.workspaceBar.reserveLayoutSpace = true
            settings.workspaceBar.height = 24
            settings.workspaceBar.position = .belowMenuBar
            settings.workspaceBar.revealModifier = .option
            settings.workspaceBar.autoHide = true
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
            XCTAssertEqual(controller.insetWorkingFrame(for: monitor), entry.overlayWorking)
            XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), entry.overlayFullscreen)
            controller.setWorkspaceBarRevealHeld(true)
            XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
            XCTAssertEqual(controller.workspaceBarReservedInsets(for: monitor), .zero)
            XCTAssertEqual(controller.insetWorkingFrame(for: monitor), entry.overlayWorking)
            XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), entry.overlayFullscreen)
            settings.workspaceBar.autoHide = false
            controller.setWorkspaceBarRevealHeld(false)
            XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
            XCTAssertEqual(controller.workspaceBarReservedInsets(for: monitor), Struts(top: 24))
            XCTAssertEqual(controller.insetWorkingFrame(for: monitor), entry.reservedWorking)
            XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), entry.reservedFullscreen)
            settings.workspaceBar.revealModifier = .off
            XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
            XCTAssertEqual(controller.workspaceBarReservedInsets(for: monitor), Struts(top: 24))
        }
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

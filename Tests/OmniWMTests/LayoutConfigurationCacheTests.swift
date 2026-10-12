// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class LayoutConfigurationCacheTests: XCTestCase {
    func testLayoutTracksDirectSettingsAndDisplayGeometryChanges() {
        let controller = makeController()
        let monitor = makeMonitor()
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame, monitor.visibleFrame)
        controller.settings.gaps.outerGapLeft = 17
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 17)
        controller.settings.borders.enabled = true
        controller.settings.borders.width = 2.25
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 1).workingFrame.minY, 3)
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minY, 2.5)
        let changed = makeMonitor(frame: CGRect(x: 1000, y: 100, width: 800, height: 700))
        XCTAssertEqual(controller.layoutFrames(for: changed, scale: 2).workingFrame.minX, 1017)
        let dock = makeMonitor(visibleFrame: CGRect(x: 0, y: 40, width: 1000, height: 760))
        XCTAssertEqual(controller.layoutFrames(for: dock, scale: 2).workingFrame.minY, 42.5)
        controller.settings.gaps.fullscreenUsesOuterGaps = true
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).fullscreenLayoutFrame.minX, 17)
        controller.settings.gaps.fullscreenUsesOuterGaps = false
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).fullscreenLayoutFrame.minX, 0)
    }

    func testLayoutTracksWorkspaceBarSettingsAndRuntimeVisibilityToggle() {
        let controller = makeController()
        let monitor = makeMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.settings.workspaceBar.enabled = true
        controller.settings.workspaceBar.reserveLayoutSpace = true
        controller.settings.workspaceBar.position = .left
        controller.settings.workspaceBar.height = 30
        controller.settings.workspaceBar.revealModifier = .off
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 30)
        XCTAssertTrue(controller.toggleWorkspaceBarVisibility())
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 0)
        XCTAssertTrue(controller.toggleWorkspaceBarVisibility())
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 30)
        controller.settings.workspaceBar.height = 40
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 40)
        controller.settings.workspaceBar.reserveLayoutSpace = false
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 0)
    }

    func testMonitorOverridesRemainDistinctAndUpdateWithoutAutosave() {
        let controller = makeController()
        let monitor = makeMonitor()
        let other = Monitor(
            id: .init(displayId: 95_802), displayId: 95_802,
            frame: monitor.frame, visibleFrame: monitor.visibleFrame, hasNotch: false, name: "Other"
        )
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 0)
        controller.settings.gaps.update(
            MonitorGapSettings(monitorName: monitor.name, outerGapLeft: 11), for: monitor
        )
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 11)
        controller.settings.workspaceBar.enabled = true
        controller.settings.workspaceBar.update(
            MonitorBarSettings(
                monitorName: monitor.name, enabled: true, reserveLayoutSpace: true, position: .left, height: 30
            ),
            for: monitor
        )
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 41)
        XCTAssertEqual(controller.layoutFrames(for: other, scale: 2).workingFrame.minX, 0)
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 41)
    }

    func testSettingsImportRefreshesCachedValuesWithAutosaveDisabled() {
        let controller = makeController()
        let monitor = makeMonitor()
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 0)
        XCTAssertFalse(WorldView(controller: controller).borderConfig.enabled)
        var imported = controller.settings.toExport()
        imported.gaps.outer.left = 27
        imported.borders.enabled = true
        imported.borders.width = 6
        controller.settings.applyExport(imported)
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, 27)
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minY, 6)
        XCTAssertEqual(WorldView(controller: controller).borderConfig.width, 6)
        XCTAssertTrue(WorldView(controller: controller).borderConfig.enabled)
    }

    func testInnerGapTracksRuntimeGapOverridesBordersAndScale() {
        let controller = makeController()
        let monitor = makeMonitor()
        controller.workspaceManager.setGaps(to: 13)
        XCTAssertEqual(controller.innerGap(for: monitor, scale: 2), 13)
        controller.workspaceManager.setGaps(to: 19)
        XCTAssertEqual(controller.innerGap(for: monitor, scale: 2), 19)
        controller.settings.gaps.update(MonitorGapSettings(monitorName: monitor.name, innerGap: 7), for: monitor)
        XCTAssertEqual(controller.innerGap(for: monitor, scale: 2), 7)
        controller.settings.gaps.remove(for: monitor)
        controller.workspaceManager.setGaps(to: 0)
        controller.settings.borders.enabled = true
        controller.settings.borders.width = 2.25
        XCTAssertEqual(controller.innerGap(for: monitor, scale: 1), 3)
        XCTAssertEqual(controller.innerGap(for: monitor, scale: 2), 2.5)
        controller.settings.borders.enabled = false
        XCTAssertEqual(controller.innerGap(for: monitor, scale: 2), 0)
    }

    func testBorderConfigTracksDirectColorGradientGlowAndAppearanceChanges() {
        let controller = makeController()
        let world = WorldView(controller: controller)
        let red = SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = SettingsColor(red: 0, green: 0, blue: 1, alpha: 1)
        controller.settings.borders.enabled = true
        controller.settings.borders.color = red
        controller.settings.borders.darkColor = blue
        controller.borderUsesDarkAppearance = false
        XCTAssertEqual(world.borderConfig.color, red)
        controller.borderUsesDarkAppearance = true
        XCTAssertEqual(world.borderConfig.color, blue)
        controller.settings.borders.darkColor = red
        XCTAssertEqual(world.borderConfig.color, red)
        controller.settings.borders.gradient = BorderGradient(
            enabled: true, start: red, end: red, direction: .topLeftToBottomRight,
            dark: BorderGradientColors(start: blue, end: blue)
        )
        XCTAssertEqual(world.borderConfig.gradient?.start, blue)
        controller.settings.borders.glow = BorderGlow(
            enabled: true, radius: 8, opacity: 0.6, color: red, darkColor: blue
        )
        XCTAssertEqual(world.borderConfig.glow?.color, blue)
        controller.borderUsesDarkAppearance = false
        XCTAssertEqual(world.borderConfig.gradient?.start, red)
        XCTAssertEqual(world.borderConfig.glow?.color, red)
        controller.settings.borders.width = 6
        XCTAssertEqual(world.borderConfig.width, 6)
        controller.settings.borders.enabled = false
        XCTAssertFalse(world.borderConfig.enabled)
    }

    func testBackingScaleSnapshotRefreshesOnScreenNotificationAndClearsOnReset() async {
        let controller = makeController()
        let refresh = controller.layoutRefreshController
        let missing = makeMonitor()
        XCTAssertEqual(refresh.backingScale(for: missing), 2)
        refresh.setup()
        XCTAssertEqual(refresh.backingScale(for: missing), 2)
        for screen in NSScreen.screens {
            guard let displayId = screen.displayId else { continue }
            XCTAssertEqual(refresh.layoutState.backingScaleByDisplay?[displayId], screen.backingScaleFactor)
        }
        refresh.layoutState.backingScaleByDisplay = [missing.displayId: 3]
        XCTAssertEqual(refresh.backingScale(for: missing), 3)
        let updated = expectation(description: "Screen notification refreshes backing scales")
        let watcher = Task { @MainActor in
            while refresh.layoutState.backingScaleByDisplay?[missing.displayId] == 3 {
                if Task.isCancelled { return }
                await Task.yield()
            }
            updated.fulfill()
        }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await fulfillment(of: [updated], timeout: 2)
        watcher.cancel()
        XCTAssertEqual(refresh.backingScale(for: missing), 2)
        refresh.resetState()
        XCTAssertNil(refresh.layoutState.backingScaleByDisplay)
        XCTAssertEqual(refresh.backingScale(for: missing), 2)
    }

    private func makeMonitor(
        frame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect? = nil
    ) -> Monitor {
        Monitor(
            id: .init(displayId: 95_801), displayId: 95_801,
            frame: frame, visibleFrame: visibleFrame ?? frame, hasNotch: false, name: "Cache Test"
        )
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LayoutCacheTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.borders.enabled = false
        settings.workspaceBar.enabled = false
        settings.gaps.outerGapLeft = 0
        settings.gaps.outerGapRight = 0
        settings.gaps.outerGapTop = 0
        settings.gaps.outerGapBottom = 0
        return WMController(settings: settings)
    }
}
